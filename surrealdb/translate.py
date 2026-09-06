#!/usr/bin/env python3
"""Generate surrealdb/queries.surql from elastic/queries.dsl.

Same approach as the cratedb/victorialogs/ravendb translators: the Elasticsearch
DSL is parseable JSON and the most explicit statement of what each query means,
so it drives the translation. Anything unrecognised raises.

SEMANTICS, all verified against a running 3.2.4 server:

* DEFINE ANALYZER otel TOKENIZERS class FILTERS lowercase reproduces the
  reference analyzer: search::analyze('otel','Failed to place order') ->
  ['failed','to','place','order'].
* `@@` is an order-insensitive AND over terms ('order reset' -> 0 here);
  `@OR@` is the OR form. There is no phrase or prefix support in the operator:
  '"failed to place"' -> 0 (the quotes become literal tokens) and 'conn*' -> 0.
* PHRASE is rebuilt as `@@ terms AND string::matches(Body, '(?i)phrase')`. The
  `@@` half is index-backed and narrows to documents holding all the terms; the
  regex then checks adjacency on that much smaller set. Verified order-sensitive:
  'failed to place' -> 1, 'place to failed' -> 0. See README -- this is a
  hand-applied optimisation, not something the engine does for you.
* regex is `string::matches()`, a scalar function, so it SCANS. ES's term-level
  regexp/wildcard become boundary-anchored patterns over [a-z0-9] runs; explicit
  classes rather than \\b, because \\b counts '_' as a word character while the
  analyzer splits on it.
* date_histogram maps onto GROUP BY time::floor(Timestamp, 1m).
* count is `SELECT count() ... GROUP ALL`; relevance is search::score(1) with
  the numbered `@1@` operator.

UNSUPPORTED, emitted as sentinels so ./query exits non-zero and the driver
records null rather than timing a different question:
  - fuzzy: the `~` family was removed in 3.0; the replacements
    (string::similarity::*) are unindexed scalar functions AND a different
    algorithm from ES's edit distance
  - joins (Q84-Q92)
  - match_phrase with slop: no proximity operator
"""
import json
import re
import sys
from itertools import combinations

ES_DSL = sys.argv[1] if len(sys.argv) > 1 else "../elastic/queries.dsl"
OUT = sys.argv[2] if len(sys.argv) > 2 else "queries.surql"

TABLE = "otel_logs"
FIELD = {"Timestamp": "Timestamp", "Body": "Body", "ServiceName": "ServiceName",
         "SeverityText": "SeverityText", "SeverityNumber": "SeverityNumber",
         "ScopeName": "ScopeName"}
PROJ_DEFAULT = ["Timestamp", "ServiceName", "Body"]
_META = re.compile(r"[.*+?\[\]()|\\^${}]")
_INTERVAL = {"minute": "1m", "hour": "1h", "day": "1d", "second": "1s"}


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


class Unsupported(Exception):
    pass


def esc(s):
    return s.replace("\\", "\\\\").replace("'", "\\'")


def match(terms, op="and"):
    joined = esc(" ".join(terms))
    return f"Body @@ '{joined}'" if op == "and" else f"Body @OR@ '{joined}'"


def rx(pattern):
    return f"string::matches(Body, '{esc(pattern)}')"


def leaf(node):
    (kind, arg), = node.items()

    if kind == "match":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, str):
            terms = v.split()
            return match(terms, "or") if len(terms) > 1 else match(terms)
        terms = v["query"].split()
        msm = int(v.get("minimum_should_match", 1))
        if msm > 1:
            cl = [match(list(combo)) for combo in combinations(terms, msm)]
            return "(" + " OR ".join(f"({c})" for c in cl) + ")"
        return match(terms, "and" if v.get("operator", "or").lower() == "and" else "or")

    if kind == "match_phrase":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, dict) and "slop" in v:
            raise Unsupported("match_phrase with slop: no proximity operator")
        p = v if isinstance(v, str) else v["query"]
        # Index-backed AND over the terms, then adjacency checked on the survivors.
        return f"({match(p.split())} AND {rx('(?i)' + re.escape(p))})"

    if kind == "fuzzy":
        raise Unsupported("fuzzy: ~ operators removed in 3.0; string::similarity::* "
                          "is unindexed and a different algorithm than ES edit distance")

    if kind in ("regexp", "prefix", "wildcard"):
        (f, v), = arg.items()
        assert f == "Body", f
        v = v if isinstance(v, str) else v["value"]
        if kind == "prefix":
            # No index-backed prefix: @@ has no prefix form and the only
            # alternative is an edgengram analyzer, which would change
            # tokenization for every other query. Falls back to the same
            # unindexed boundary regex used for regexp/wildcard -- correct, and
            # slow for the same reason. Marking it unsupported instead would
            # understate coverage, since the question IS expressible.
            return rx("(?i)(^|[^a-z0-9])" + v)
        if kind == "wildcard":
            if v.endswith("*") and not v.startswith("*") and "*" not in v[:-1] and "?" not in v:
                return rx("(?i)(^|[^a-z0-9])" + v[:-1])   # x* -> token starts with x
            if v.startswith("*") and v.endswith("*"):
                stem = v[1:-1]
                if stem.isalnum():
                    return rx("(?i)" + stem)
                raise Unsupported(f"wildcard {v}: non-alphanumeric infix stem")
            if v.startswith("*"):
                stem = v[1:]
                if stem.isalnum():
                    return rx("(?i)" + stem + "([^a-z0-9]|$)")
                raise Unsupported(f"wildcard {v}: non-alphanumeric suffix stem")
            raise Unsupported(f"wildcard {v}: unhandled shape")
        if v.endswith(".*"):
            stem = v[:-2]
            if not _META.search(stem):
                return rx("(?i)(^|[^a-z0-9])" + stem)     # regexp x.* -> prefix
        return rx("(?i)(^|[^a-z0-9])" + v + "([^a-z0-9]|$)")

    if kind == "term":
        (f, v), = arg.items()
        v = v if not isinstance(v, dict) else v["value"]
        return f"{FIELD[f]} = '{esc(str(v))}'"

    if kind == "range":
        (f, v), = arg.items()
        col = FIELD[f]
        parts = []
        for op, sym in (("gte", ">="), ("gt", ">"), ("lte", "<="), ("lt", "<")):
            if op in v:
                val = v[op]
                parts.append(f"{col} {sym} <datetime>'{val}Z'" if f == "Timestamp"
                             else f"{col} {sym} {val}")
        return "(" + " AND ".join(parts) + ")" if len(parts) > 1 else parts[0]

    if kind == "bool":
        return boolean(arg)
    raise ValueError(f"unhandled leaf: {kind}")


def boolean(b):
    out = []
    for c in b.get("must", []) + b.get("filter", []):
        out.append(leaf(c))
    if "should" in b:
        sh = [leaf(c) for c in b["should"]]
        if int(b.get("minimum_should_match", 1)) > 1:
            raise Unsupported("bool.minimum_should_match>1 across clauses")
        out.append("(" + " OR ".join(sh) + ")")
    for c in b.get("must_not", []):
        out.append("!(" + leaf(c) + ")")
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
    w = f" WHERE {where}" if where else ""

    if "aggs" in d:
        (name, agg), = d["aggs"].items()
        if "terms" in agg:
            t = agg["terms"]; col = FIELD[t["field"]]
            lim = f" LIMIT {int(t['size'])}" if "size" in t else ""
            order = (" ORDER BY c DESC" if t.get("order", {}).get("_count") == "desc"
                     else (f" ORDER BY {col}" if t.get("order", {}).get("_key") == "asc"
                           else " ORDER BY c DESC"))
            return f"SELECT {col}, count() AS c FROM {TABLE}{w} GROUP BY {col}{order}{lim}"
        if "date_histogram" in agg:
            iv = _INTERVAL[agg["date_histogram"]["calendar_interval"]]
            return (f"SELECT time::floor(Timestamp, {iv}) AS bucket, count() AS c "
                    f"FROM {TABLE}{w} GROUP BY bucket ORDER BY bucket")
        raise ValueError(f"{qid}: unhandled agg {set(agg)}")

    size = d.get("size", 10)
    if size == 0:
        return f"SELECT count() FROM {TABLE}{w} GROUP ALL"
    proj = ", ".join(FIELD.get(c, c) for c in d.get("_source", PROJ_DEFAULT))
    sort = d.get("sort", [])
    if sort:
        (f, dirn), = sort[0].items()
        if f == "_score":
            # search::score(N) pairs with the numbered @N@ operator, so the match
            # clause has to carry the same reference number.
            w2 = w.replace("Body @@ ", "Body @1@ ", 1).replace("Body @OR@ ", "Body @1@ ", 1)
            if "@1@" not in w2:
                # The filter is a string::matches regex (prefix/wildcard), not a
                # match operator, so there is nothing for search::score to
                # reference -- BM25 is only defined against the FULLTEXT index.
                raise Unsupported("relevance ranking over a regex filter: "
                                  "search::score needs a numbered @N@ match operator, "
                                  "and prefix/wildcard have no index-backed match form")
            return (f"SELECT {proj}, search::score(1) AS score FROM {TABLE}{w2} "
                    f"ORDER BY score DESC LIMIT {size}")
        return f"SELECT {proj} FROM {TABLE}{w} ORDER BY {FIELD[f]} {dirn.upper()} LIMIT {size}"
    return f"SELECT {proj} FROM {TABLE}{w} LIMIT {size}"


dsl = parse(ES_DSL)
out, unsup, failed = [], [], []
out += ["-- SurrealDB SurrealQL workload over the OTel-logs corpus -- 92 queries",
        "-- mirroring serenedb/queries.sql Q01-Q92 one-for-one. Generated from",
        "-- elastic/queries.dsl by surrealdb/translate.py; see that file for the",
        "-- semantics and what is unsupported.", ""]
for i in range(1, 93):
    qid = f"Q{i:02d}"
    if qid not in dsl:
        out += [f"-- {qid} (missing from source)", f"UNSUPPORTED: {qid} absent from elastic/queries.dsl"]
        continue
    tag, body = dsl[qid]
    out.append(f"-- {qid} {tag}")
    if not body.startswith("{"):
        out.append("UNSUPPORTED: join queries -- SurrealQL has no join over a flat table")
        unsup.append((qid, "join")); continue
    try:
        out.append(translate(qid, body))
    except Unsupported as e:
        out.append(f"UNSUPPORTED: {e}"); unsup.append((qid, str(e)))
    except Exception as e:
        out.append(f"UNSUPPORTED: TRANSLATION FAILED: {e}"); failed.append((qid, str(e)))

open(OUT, "w").write("\n".join(out) + "\n")
runnable = sum(1 for l in out if l and not l.startswith(("--", "UNSUPPORTED")))
print(f"wrote {OUT}: {runnable}/92 runnable, {len(unsup)} unsupported, {len(failed)} failed")
by = {}
for qid, why in unsup:
    by.setdefault(why.split(":")[0], []).append(qid)
for why, qs in sorted(by.items()):
    print(f"  {why}: {len(qs)} -> {' '.join(qs)}")
if failed:
    print("FAILED (translator bugs):")
    for qid, why in failed:
        print(f"  {qid}: {why}")
