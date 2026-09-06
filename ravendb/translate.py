#!/usr/bin/env python3
"""Generate ravendb/queries.rql from elastic/queries.dsl.

Same approach as cratedb/ and victorialogs/translate.py: the Elasticsearch DSL is
parseable JSON and the most explicit statement of what each query means, so it
drives the translation. Anything unrecognised raises -- a silently mistranslated
query is worse than no query.

SEMANTICS, all verified against a running 7.2.5 server:

* search() is case-insensitive both ways (the Search analyzer lowercases), so
  unlike the VictoriaLogs adapter nothing needs a case wrapper.
* The analyzer splits on '_' exactly like the reference analyzer --
  search(Body,'order') matches "send_order_confirmation". No tokenizer
  divergence to correct for.
* search(f,'a b') is OR across terms; search(f,'a b', and) is AND;
  search(f,'"a b"') is an ordered phrase (verified: reversing the words -> 0).
* search(f,'x*') is a term prefix.
* regex(f,'p') is an UNANCHORED match over the whole field value and is
  case-insensitive, so ES's term-level regexp/wildcard become boundary-anchored
  patterns over [a-z0-9] runs -- explicit classes, not \\b, because \\b treats
  '_' as a word character while the analyzer does not.
* count = `limit 0`; the answer is TotalResults (./query emits it).
* group-by is NOT expressible as `where ... group by ...` ("group by can be used
  only when querying on collections"). The query-time equivalent of an ES terms
  aggregation is a facet, which computes over the filtered result set.

UNSUPPORTED, emitted as sentinels so ./query exits non-zero and the driver
records null rather than timing a different question:
  - fuzzy: Corax reports "Method 'Fuzzy' is not supported" (the older Lucene
    engine does support it -- see README for that trade-off)
  - date_histogram: RQL facets bucket by explicit ranges, not by a calendar
    interval; a per-minute histogram is not expressible as one query
  - joins (Q84-Q92): RavenDB has no join
  - match_phrase with slop: no proximity operator
"""
import json
import re
import sys
from itertools import combinations

ES_DSL = sys.argv[1] if len(sys.argv) > 1 else "../elastic/queries.dsl"
OUT = sys.argv[2] if len(sys.argv) > 2 else "queries.rql"

INDEX = "Logs/Search"
FIELD = {"Timestamp": "Timestamp", "Body": "Body", "ServiceName": "ServiceName",
         "SeverityText": "SeverityText", "SeverityNumber": "SeverityNumber",
         "ScopeName": "ScopeName"}
PROJ_DEFAULT = ["Timestamp", "ServiceName", "Body"]
_META = re.compile(r"[.*+?\[\]()|\\^${}]")


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
    return s.replace("'", "\\'")


def search(terms, op=None):
    body = esc(" ".join(terms) if isinstance(terms, (list, tuple)) else terms)
    return f"search(Body, '{body}', and)" if op == "and" else f"search(Body, '{body}')"


def rx(pattern):
    return "regex(Body, '%s')" % esc(pattern)


def leaf(node):
    (kind, arg), = node.items()

    if kind == "match":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, str):
            return search(v.split())
        terms = v["query"].split()
        msm = int(v.get("minimum_should_match", 1))
        if msm > 1:
            # "at least K of N" has no RQL operator; expand to an OR over every
            # K-subset, reproducing ES exactly.
            cl = [" and ".join(search([t]) for t in combo) for combo in combinations(terms, msm)]
            return "(" + " or ".join(f"({c})" for c in cl) + ")"
        return search(terms, "and" if v.get("operator", "or").lower() == "and" else None)

    if kind == "match_phrase":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, str):
            return f"search(Body, '\"{esc(v)}\"')"
        if "slop" in v:
            raise Unsupported("match_phrase with slop: RQL has no proximity operator")
        return f"search(Body, '\"{esc(v['query'])}\"')"

    if kind == "fuzzy":
        raise Unsupported("fuzzy: Corax reports \"Method 'Fuzzy' is not supported\"")

    if kind in ("regexp", "prefix", "wildcard"):
        (f, v), = arg.items()
        assert f == "Body", f
        v = v if isinstance(v, str) else v["value"]
        if kind == "prefix":
            return search([v + "*"])
        if kind == "wildcard":
            if v.endswith("*") and not v.startswith("*") and "*" not in v[:-1] and "?" not in v:
                return search([v])                       # x*  -> index-backed prefix
            if v.startswith("*") and v.endswith("*"):
                stem = v[1:-1]
                if stem.isalnum():
                    # An alphanumeric stem cannot straddle a token boundary, so a
                    # plain substring regex is exactly the term-level test.
                    return rx(stem)
                raise Unsupported(f"wildcard {v}: non-alphanumeric infix stem")
            if v.startswith("*"):
                stem = v[1:]
                if stem.isalnum():
                    return rx(stem + "([^a-z0-9]|$)")    # token ENDS with stem
                raise Unsupported(f"wildcard {v}: non-alphanumeric suffix stem")
            raise Unsupported(f"wildcard {v}: unhandled shape")
        if v.endswith(".*"):                             # regexp x.* -> prefix
            stem = v[:-2]
            if not _META.search(stem):
                return search([stem + "*"])
        return rx("(^|[^a-z0-9])" + v + "([^a-z0-9]|$)")

    if kind == "term":
        (f, v), = arg.items()
        v = v if not isinstance(v, dict) else v["value"]
        return f"{FIELD[f]} = '{esc(str(v))}'"

    if kind == "range":
        (f, v), = arg.items()
        col = FIELD[f]
        if f == "Timestamp":
            lo, hi = v.get("gte") or v.get("gt"), v.get("lte") or v.get("lt")
            return f"{col} between '{lo}.0000000Z' and '{hi}.0000000Z'"
        parts = []
        for op, sym in (("gte", ">="), ("gt", ">"), ("lte", "<="), ("lt", "<")):
            if op in v:
                parts.append(f"{col} {sym} {v[op]}")
        return "(" + " and ".join(parts) + ")" if len(parts) > 1 else parts[0]

    if kind == "bool":
        return boolean(arg)
    raise ValueError(f"unhandled leaf: {kind}")


def boolean(b):
    out = []
    for c in b.get("must", []) + b.get("filter", []):
        out.append(leaf(c))
    if "should" in b:
        shoulds = [leaf(c) for c in b["should"]]
        if int(b.get("minimum_should_match", 1)) > 1:
            raise Unsupported("bool.minimum_should_match>1 across clauses")
        out.append("(" + " or ".join(shoulds) + ")")
    for c in b.get("must_not", []):
        out.append("not (" + leaf(c) + ")")
    unknown = set(b) - {"must", "filter", "should", "must_not", "minimum_should_match"}
    if unknown:
        raise ValueError(f"unhandled bool keys: {unknown}")
    return " and ".join(x for x in out if x)


def translate(qid, dsl):
    d = json.loads(dsl)
    where = boolean(d["query"]["bool"]) if "bool" in d["query"] else leaf(d["query"])
    unknown = set(d) - {"query", "size", "sort", "_source", "track_total_hits", "aggs"}
    if unknown:
        raise ValueError(f"{qid}: unhandled top-level keys {unknown}")
    head = f"from index '{INDEX}'" + (f" where {where}" if where else "")

    if "aggs" in d:
        (name, agg), = d["aggs"].items()
        if "terms" in agg:
            col = FIELD[agg["terms"]["field"]]
            # Facets compute over the filtered result set -- the query-time
            # equivalent of an ES terms aggregation. Bucket ORDER/size are not
            # applied (RQL takes those via QueryParameters, which the flat
            # queries file cannot carry); the bucket set is identical.
            return f"{head} select facet({col})"
        if "date_histogram" in agg:
            raise Unsupported("date_histogram: RQL facets bucket by explicit "
                              "ranges, not by calendar interval")
        raise ValueError(f"{qid}: unhandled agg {set(agg)}")

    size = d.get("size", 10)
    if size == 0:
        return f"{head} limit 0"
    proj = ", ".join(FIELD.get(c, c) for c in d.get("_source", PROJ_DEFAULT))
    sort = d.get("sort", [])
    if sort:
        (f, dirn), = sort[0].items()
        order = "score()" if f == "_score" else f"{FIELD[f]} {dirn}"
        return f"{head} order by {order} select {proj} limit {size}"
    return f"{head} select {proj} limit {size}"


dsl = parse(ES_DSL)
out, unsupported, failed = [], [], []
out += ["-- RavenDB RQL workload over the OTel-logs corpus -- 92 queries mirroring",
        "-- serenedb/queries.sql Q01-Q92 one-for-one. Generated from",
        "-- elastic/queries.dsl by ravendb/translate.py; see that file for the",
        "-- semantics (search/regex behaviour, facets, what is unsupported).", ""]
for i in range(1, 93):
    qid = f"Q{i:02d}"
    if qid not in dsl:
        out += [f"-- {qid} (missing from source)", f"UNSUPPORTED: {qid} absent from elastic/queries.dsl"]
        continue
    tag, body = dsl[qid]
    out.append(f"-- {qid} {tag}")
    if not body.startswith("{"):
        out.append("UNSUPPORTED: join queries -- RavenDB has no join")
        unsupported.append((qid, "join")); continue
    try:
        out.append(translate(qid, body))
    except Unsupported as e:
        out.append(f"UNSUPPORTED: {e}"); unsupported.append((qid, str(e)))
    except Exception as e:
        out.append(f"UNSUPPORTED: TRANSLATION FAILED: {e}"); failed.append((qid, str(e)))

open(OUT, "w").write("\n".join(out) + "\n")
runnable = sum(1 for l in out if l and not l.startswith(("--", "UNSUPPORTED")))
print(f"wrote {OUT}: {runnable}/92 runnable, {len(unsupported)} unsupported, {len(failed)} failed")
by = {}
for qid, why in unsupported:
    by.setdefault(why.split(":")[0], []).append(qid)
for why, qs in sorted(by.items()):
    print(f"  {why}: {len(qs)} -> {' '.join(qs)}")
if failed:
    print("FAILED (translator bugs, fix these):")
    for qid, why in failed:
        print(f"  {qid}: {why}")
