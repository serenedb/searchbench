#!/usr/bin/env python3
"""Generate cratedb/queries.sql from elastic/queries.dsl (Q01-Q83) and
postgres/queries.sql (Q84-Q92, the self-joins).

The Elasticsearch DSL is parseable JSON and is the most explicit statement of
what each query means, so it drives the translation. Anything this script does
not recognise raises -- a silently mistranslated query is worse than no query.

Token-level semantics matter: ES `regexp`/`prefix`/`wildcard` match TERMS in the
inverted index, not the whole field. CrateDB's `~` matches the whole string, so
those become word-boundary regexes over the plain index (which is why body keeps
one). Our analyzer emits [a-z0-9]+ tokens, so `\\b<pat>\\b` is equivalent.
"""
import json, re, sys
from itertools import combinations

ES_DSL = sys.argv[1]
PG_SQL = sys.argv[2]

COL = {"Timestamp": "ts", "ServiceName": "service_name", "SeverityText": "severity_text",
       "SeverityNumber": "severity_number", "ScopeName": "scope_name", "Body": "body"}
PROJ = "ts, service_name, body"


def parse(path):
    out, tag = {}, None
    for line in open(path, encoding="utf-8"):
        s = line.rstrip("\n")
        m = re.match(r"^--\s+(Q\d+)\s+(.*)$", s.strip())
        if m:
            tag = (m.group(1), m.group(2)); continue
        if s.strip() and not s.strip().startswith("--") and tag:
            out[tag[0]] = (tag[1], s.strip()); tag = None
    return out


def q(s):
    return "'" + s.replace("'", "''") + "'"


MAX_EXPANSIONS = 50000

# Regex metacharacters that would make a literal not a plain prefix.
_META = re.compile(r"[.*+?\[\]()|\\^${}]")


def infix_literal(kind, pat):
    """Return X if this pattern means 'token CONTAINS X' for an alphanumeric X,
    else None.

    For such an X, `body LIKE '%X%'` is exactly equivalent to the token-level
    test: X cannot straddle a token boundary (boundaries are non-alphanumeric),
    so any occurrence of X in the line is necessarily inside one token. The
    word-boundary regex adds nothing and costs 2x -- measured 19.4s vs 9.5s on
    Q27, both returning Elasticsearch's 1,342,557.

    This does NOT hold for suffix (*X) or prefix-anchored patterns, where the
    boundary is what distinguishes 'ends with' from 'contains'.
    """
    if kind == "wildcard" and pat.startswith("*") and pat.endswith("*"):
        stem = pat[1:-1]
        if stem and stem.isalnum():
            return stem
    return None


def prefix_literal(kind, pat):
    """Return the literal X if this pattern means 'token starts with X',
    else None. ES expresses that three ways -- prefix X, regexp X.*, and
    wildcard X* -- and all three map onto one index operation."""
    if kind == "prefix":
        return pat if not _META.search(pat) else None
    if kind == "wildcard":
        stem = pat[:-1]
        if pat.endswith("*") and not pat.startswith("*") \
           and "*" not in stem and "?" not in stem:
            return stem
        return None
    if kind == "regexp" and pat.endswith(".*"):
        stem = pat[:-2]
        return stem if not _META.search(stem) else None
    return None


def tok_regex(pat):
    """ES term-level pattern -> CrateDB whole-string regex with word bounds."""
    # Branch on the ORIGINAL pattern: substituting first would let the inserted
    # [a-z0-9]* be re-read as a trailing wildcard and doubled.
    if pat.endswith(".*"):                                # regexp charg.*
        body = pat[:-2] + "[a-z0-9]*"
    elif pat.startswith("*") and pat.endswith("*"):       # wildcard *x*
        body = "[a-z0-9]*" + pat.strip("*") + "[a-z0-9]*"
    elif pat.endswith("*"):                               # wildcard x*
        body = pat[:-1] + "[a-z0-9]*"
    elif pat.startswith("*"):                             # wildcard *x
        body = "[a-z0-9]*" + pat[1:]
    else:
        body = pat
    # Lookarounds, not \b: Java's \b counts '_' as a word character, but our
    # analyzer splits on it, so \b would miss a token inside e.g. "order_id".
    # Measured: that alone cost 350 rows on Q17 against Elasticsearch.
    return f"body ~ {q('(?i).*(?<![a-z0-9])' + body + '(?![a-z0-9]).*')}"


def leaf(node):
    """One DSL leaf clause -> a CrateDB boolean expression."""
    (kind, arg), = node.items()
    if kind == "match":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, str):
            return f"MATCH(body_ft, {q(v)})"
        msm = int(v.get("minimum_should_match", 1))
        if msm > 1:
            # CrateDB SILENTLY IGNORES minimum_should_match -- it returns the
            # plain-OR count (verified: 30,112 vs Elasticsearch's 17,939 on
            # Q09). Expand "at least K of N" into an OR over every K-subset,
            # which reproduces ES exactly.
            terms = v["query"].split()
            clauses = [" AND ".join(f"MATCH(body_ft, {q(t)})" for t in combo)
                       for combo in combinations(terms, msm)]
            return "(" + " OR ".join(f"({c})" for c in clauses) + ")"
        opts = []
        if v.get("operator", "or").lower() == "and":
            opts.append("operator='and'")
        s = f"MATCH(body_ft, {q(v['query'])})"
        return s + (f" USING best_fields WITH ({', '.join(opts)})" if opts else "")
    if kind == "match_phrase":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, str):
            return f"MATCH(body_ft, {q(v)}) USING phrase"
        s = f"MATCH(body_ft, {q(v['query'])}) USING phrase"
        return s + (f" WITH (slop={int(v['slop'])})" if "slop" in v else "")
    if kind == "fuzzy":
        (f, v), = arg.items()
        assert f == "Body", f
        val, fz = (v, 1) if isinstance(v, str) else (v["value"], v.get("fuzziness", 1))
        return f"MATCH(body_ft, {q(val)}) USING best_fields WITH (fuzziness={int(fz)})"
    if kind in ("regexp", "prefix", "wildcard"):
        (f, v), = arg.items()
        assert f == "Body", f
        v = v if isinstance(v, str) else v["value"]
        inf = infix_literal(kind, v)
        if inf is not None:
            return f"body LIKE {q('%' + inf + '%')}"
        lit = prefix_literal(kind, v)
        if lit is not None:
            # Index-backed prefix, the same thing every other engine does here:
            # ES `prefix`/`regexp X.*` hit the terms dictionary, SereneDB uses
            # ts_starts_with, Postgres uses `X:*`. CrateDB's equivalent is
            # phrase_prefix. A raw `body ~ ...` scan gives identical answers but
            # reads all 100M strings -- it timed out on every one of these.
            #
            # max_expansions is NOT optional: it defaults to 50, which silently
            # truncates. 'conn' returned 79 rows against Elasticsearch's
            # 1,344,366 until it was raised. 0 is rejected, so it must be a
            # finite bound large enough for the widest prefix in the corpus.
            #
            # The flip side of an exhaustive expansion is that phrase_prefix
            # expands into BooleanQuery clauses, and Lucene caps those at 8192.
            # At 100m every prefix here stays under the cap; at 1b 'conn' and
            # 'charg' cross it and the query dies with
            #   TooManyClauses[maxClauseCount is set to 8192]
            # which the driver records as a null, i.e. a silent failure. So
            # cratedb/start raises indices.query.bool.max_clause_count above
            # MAX_EXPANSIONS. Keep the two in step: bumping MAX_EXPANSIONS past
            # that ceiling reintroduces the 1b failure.
            #
            # LIKE is not a substitute, despite looking like one. ES's
            # prefix/wildcard match any *token* with the prefix, while LIKE
            # anchors on the whole log line: at 1b `body LIKE 'conn%'` returns 0
            # and `body LIKE '%conn%'` returns 19,447,319, against ES's
            # 19,554,788 -- untokenized and case-sensitive where ES lowercases.
            return (f"MATCH(body_ft, {q(lit)}) USING phrase_prefix "
                    f"WITH (max_expansions = {MAX_EXPANSIONS})")
        # Infix/suffix patterns (c.che, *tion, *nnec*) have no index-backed form
        # in CrateDB, so they stay whole-string scans. That is an engine
        # limitation, not an adapter choice.
        return tok_regex(v + (".*" if kind == "prefix" else ""))
    if kind == "term":
        (f, v), = arg.items()
        v = v if not isinstance(v, dict) else v["value"]
        return f"{COL[f]} = {q(str(v))}"
    if kind == "range":
        (f, v), = arg.items()
        parts = []
        for op, sql in (("gte", ">="), ("gt", ">"), ("lte", "<="), ("lt", "<")):
            if op in v:
                val = v[op]
                parts.append(f"{COL[f]} {sql} " + (q(val) if isinstance(val, str) else str(val)))
        return " AND ".join(parts)
    if kind == "bool":
        return boolean(arg)
    raise ValueError(f"unhandled leaf: {kind}")


def boolean(b):
    out = []
    for c in b.get("must", []) + b.get("filter", []):
        out.append(leaf(c))
    if "should" in b:
        shoulds = [leaf(c) for c in b["should"]]
        msm = int(b.get("minimum_should_match", 1))
        if msm > 1:
            raise ValueError("bool.minimum_should_match>1 across clauses")
        out.append("(" + " OR ".join(shoulds) + ")")
    for c in b.get("must_not", []):
        out.append("NOT (" + leaf(c) + ")")
    unknown = set(b) - {"must", "filter", "should", "must_not", "minimum_should_match"}
    if unknown:
        raise ValueError(f"unhandled bool keys: {unknown}")
    return " AND ".join(x for x in out if x)


def translate(qid, dsl):
    d = json.loads(dsl)
    where = boolean(d["query"]["bool"]) if "bool" in d["query"] else leaf(d["query"])
    unknown = set(d) - {"query", "size", "sort", "_source", "track_total_hits", "aggs"}
    if unknown:
        raise ValueError(f"{qid}: unhandled top-level keys {unknown}")

    if "aggs" in d:
        (name, agg), = d["aggs"].items()
        if "terms" in agg:
            t = agg["terms"]; col = COL[t["field"]]
            order = t.get("order", {})
            by = "cnt DESC" if order.get("_count") == "desc" else \
                 (f"{col} ASC" if order.get("_key") == "asc" else "cnt DESC")
            lim = f" LIMIT {int(t['size'])}" if "size" in t else ""
            return (f"SELECT {col}, count(*) AS cnt FROM otel_logs WHERE {where} "
                    f"GROUP BY {col} ORDER BY {by}{lim}")
        if "date_histogram" in agg:
            h = agg["date_histogram"]; col = COL[h["field"]]
            unit = h["calendar_interval"]
            return (f"SELECT date_trunc({q(unit)}, {col}) AS bucket, count(*) AS cnt "
                    f"FROM otel_logs WHERE {where} GROUP BY bucket ORDER BY bucket")
        raise ValueError(f"{qid}: unhandled agg {set(agg)}")

    size = d.get("size", 10)
    if size == 0:
        return f"SELECT count(*) FROM otel_logs WHERE {where}"
    sort = d.get("sort", [])
    if sort:
        (f, dirn), = sort[0].items()
        if f == "_score":
            return (f"SELECT {PROJ}, _score FROM otel_logs WHERE {where} "
                    f"ORDER BY _score {dirn.upper()} LIMIT {size}")
        return (f"SELECT {PROJ} FROM otel_logs WHERE {where} "
                f"ORDER BY {COL[f]} {dirn.upper()} LIMIT {size}")
    return f"SELECT {PROJ} FROM otel_logs WHERE {where} LIMIT {size}"


dsl = parse(ES_DSL)
pg = parse(PG_SQL)
out, failed = [], []
out.append("-- CrateDB tagged workload over otel_logs -- 92 queries mirroring")
out.append("-- serenedb/queries.sql Q01-Q92 one-for-one. Generated from")
out.append("-- elastic/queries.dsl (Q01-Q83) and postgres/queries.sql (Q84-Q92 joins)")
out.append("-- by cratedb/translate.py; see that file for the semantics.")
out.append("")
for i in range(1, 93):
    qid = f"Q{i:02d}"
    tag, body = dsl.get(qid, (None, None))
    if qid in dsl and body and body.startswith("{"):
        try:
            sql = translate(qid, body)
        except Exception as e:
            failed.append((qid, str(e))); sql = None
    else:
        tag = pg[qid][0] if qid in pg else tag
        sql = None                       # joins: filled in by hand below
    out.append(f"-- {qid} {tag}")
    out.append(sql + ";" if sql else "-- (TODO)")
open("/tmp/es-upgrade/crate/queries.generated.sql", "w").write("\n".join(out) + "\n")
print(f"translated: {sum(1 for l in out if l.endswith(';'))}/92")
if failed:
    print("FAILED:")
    for qid, e in failed:
        print(f"  {qid}: {e}")
