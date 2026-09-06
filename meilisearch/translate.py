#!/usr/bin/env python3
"""Generate meilisearch/queries.meili from elastic/queries.dsl.

Same approach as the cratedb/victorialogs/ravendb/surrealdb translators: the
Elasticsearch DSL drives the translation; anything unrecognised raises.

Output is one JSON search body per line, posted to /indexes/<uid>/search.

SEMANTICS, all verified against a running 1.53.1 server:

* A BARE query word is a PREFIX (Meilisearch is search-as-you-type: the last
  word of `q` is always treated as a prefix). `conn` matches "connection".
  A QUOTED word is an exact term: `"conn"` -> 0, `"order"` -> 2 while bare
  `order` -> 3 (it also caught "orders"). So:
      ES match  -> quoted   "term"
      ES prefix -> bare      term
  Both are therefore expressible, which is unusual -- most engines here give one
  or the other.
* Multi-word `q` is AND-ish under every matchingStrategy ("last", "all",
  "frequency" all return 0 for two terms living in different documents), so
  ES's default OR-across-terms is NOT expressible through `q` at all.
* It IS expressible through the FILTER language, which has real AND/OR/NOT:
      Body CONTAINS "a" OR Body CONTAINS "b"
  This needs the `containsFilter` experimental flag (./configure-features) and
  Body in filterableAttributes.
* CONTAINS is a SUBSTRING test over the whole field, and case-insensitive.
  - For an ES infix wildcard `*stem*` with an ALPHANUMERIC stem this is exactly
    equivalent: the stem cannot contain a token separator, so any occurrence in
    the field necessarily lies inside one token.
  - For OR-of-terms it OVER-MATCHES: `CONTAINS "error"` also hits "errors".
    That divergence is measured in the README; there is no token-level OR in
    Meilisearch, so the choice is an over-matching OR or no OR at all.
* Counts come from hitsPerPage:0 -> totalHits (exact). estimatedTotalHits is
  NOT used: it is explicitly approximate.
* group_by uses facets -> facetDistribution.

UNSUPPORTED, emitted as sentinels so ./query exits non-zero and the driver
records null rather than timing a different question:
  - joins (Q84-Q92)
  - fuzzy: typo tolerance is an INDEX-level setting, not per-query, and it has
    to be disabled globally or every term matches its typo neighbours
  - date_histogram: facets bucket by term, not by date interval
  - suffix wildcards `*stem`: CONTAINS would match the stem anywhere in a token,
    not only at its end, and there is no regex to anchor with
  - non-prefix regexp (e.g. `c.che`): no regex support in queries or filters
"""
import json
import re
import sys
from itertools import combinations

ES_DSL = sys.argv[1] if len(sys.argv) > 1 else "../elastic/queries.dsl"
OUT = sys.argv[2] if len(sys.argv) > 2 else "queries.meili"

FILT = {"ServiceName": "ServiceName", "SeverityText": "SeverityText",
        "SeverityNumber": "SeverityNumber", "ScopeName": "ScopeName"}
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


def contains(term):
    return 'Body CONTAINS "%s"' % term.replace('"', '\\"')


def iso_to_ms(s):
    # The DSL writes naive ISO strings; the corpus is UTC.
    import datetime as _dt
    return int(_dt.datetime.fromisoformat(s).replace(tzinfo=_dt.timezone.utc).timestamp() * 1000)


class Q:
    """Accumulates the two halves of a Meilisearch request: `q` (full-text,
    index-backed) and `filter` (boolean, CONTAINS-based)."""

    def __init__(self):
        self.q_terms = []       # quoted exact terms / phrases, ANDed by Meilisearch
        self.q_prefix = None    # at most one bare trailing prefix word
        self.filters = []

    def body(self):
        parts = list(self.q_terms)
        if self.q_prefix:
            parts.append(self.q_prefix)   # must be LAST: only the last word prefixes
        b = {"q": " ".join(parts)}
        if len(parts) > 1:
            b["matchingStrategy"] = "all"
        if self.filters:
            b["filter"] = " AND ".join(f"({f})" if " OR " in f else f for f in self.filters)
        return b


def leaf(node, out: Q, force_filter=False):
    (kind, arg), = node.items()

    if kind == "match":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, str):
            terms = v.split()
            if len(terms) == 1 and not force_filter:
                out.q_terms.append(f'"{terms[0]}"'); return
            out.filters.append(" OR ".join(contains(t) for t in terms)); return
        terms = v["query"].split()
        msm = int(v.get("minimum_should_match", 1))
        if msm > 1:
            cl = [" AND ".join(contains(t) for t in combo) for combo in combinations(terms, msm)]
            out.filters.append(" OR ".join(f"({c})" for c in cl)); return
        if v.get("operator", "or").lower() == "and":
            if force_filter:
                out.filters.append(" AND ".join(contains(t) for t in terms)); return
            out.q_terms.extend(f'"{t}"' for t in terms); return
        if len(terms) == 1 and not force_filter:
            out.q_terms.append(f'"{terms[0]}"'); return
        out.filters.append(" OR ".join(contains(t) for t in terms)); return

    if kind == "match_phrase":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, dict) and "slop" in v:
            raise Unsupported("match_phrase with slop: no proximity operator")
        p = v if isinstance(v, str) else v["query"]
        if force_filter:
            # A phrase inside should/must_not: CONTAINS on the whole phrase is
            # exact here, because the phrase text includes its separators.
            out.filters.append(contains(p)); return
        out.q_terms.append('"%s"' % p)      # a quoted multi-word string is a phrase
        return

    if kind == "fuzzy":
        raise Unsupported("fuzzy: typo tolerance is an index-level setting, not "
                          "per-query, and must be disabled globally for exact terms")

    if kind in ("regexp", "prefix", "wildcard"):
        (f, v), = arg.items()
        assert f == "Body", f
        v = v if isinstance(v, str) else v["value"]
        if kind == "prefix":
            if out.q_prefix:
                raise Unsupported("two prefix clauses: only the last word of q prefixes")
            out.q_prefix = v; return
        if kind == "wildcard":
            if v.endswith("*") and not v.startswith("*") and "*" not in v[:-1] and "?" not in v:
                if out.q_prefix:
                    raise Unsupported("two prefix clauses: only the last word of q prefixes")
                out.q_prefix = v[:-1]; return
            if v.startswith("*") and v.endswith("*"):
                stem = v[1:-1]
                if stem.isalnum():
                    # Exact: an alphanumeric stem cannot span a token boundary.
                    out.filters.append(contains(stem)); return
                raise Unsupported(f"wildcard {v}: non-alphanumeric infix stem")
            if v.startswith("*"):
                raise Unsupported(f"wildcard {v}: suffix match needs an anchor; "
                                  "CONTAINS matches the stem anywhere in a token")
            raise Unsupported(f"wildcard {v}: unhandled shape")
        if v.endswith(".*"):
            stem = v[:-2]
            if not _META.search(stem):
                if out.q_prefix:
                    raise Unsupported("two prefix clauses: only the last word of q prefixes")
                out.q_prefix = stem; return
        raise Unsupported(f"regexp {v}: no regex support in queries or filters")

    if kind == "term":
        (f, v), = arg.items()
        v = v if not isinstance(v, dict) else v["value"]
        out.filters.append(f'{FILT[f]} = "{v}"'); return

    if kind == "range":
        (f, v), = arg.items()
        if f == "Timestamp":
            for op, sym in (("gte", ">="), ("gt", ">"), ("lte", "<="), ("lt", "<")):
                if op in v:
                    out.filters.append(f"TimestampMs {sym} {iso_to_ms(v[op])}")
            return
        col = FILT[f]
        for op, sym in (("gte", ">="), ("gt", ">"), ("lte", "<="), ("lt", "<")):
            if op in v:
                out.filters.append(f"{col} {sym} {v[op]}")
        return

    if kind == "bool":
        boolean(arg, out); return
    raise ValueError(f"unhandled leaf: {kind}")


def boolean(b, out: Q):
    for c in b.get("must", []) + b.get("filter", []):
        leaf(c, out)
    if "should" in b:
        if int(b.get("minimum_should_match", 1)) > 1:
            raise Unsupported("bool.minimum_should_match>1 across clauses")
        subs = []
        for c in b["should"]:
            sub = Q()
            leaf(c, sub, force_filter=True)
            if sub.q_prefix:
                raise Unsupported("bool.should over a prefix clause: prefixes only "
                                  "exist in q, which has no OR")
            subs.append(" AND ".join(sub.filters))
        out.filters.append(" OR ".join(f"({s})" for s in subs))
    for c in b.get("must_not", []):
        sub = Q()
        leaf(c, sub, force_filter=True)
        if sub.q_prefix:
            raise Unsupported("must_not over a prefix clause: prefixes only exist "
                              "in q, which has no negation")
        out.filters.append("NOT (" + " AND ".join(sub.filters) + ")")
    unknown = set(b) - {"must", "filter", "should", "must_not", "minimum_should_match"}
    if unknown:
        raise ValueError(f"unhandled bool keys: {unknown}")


def translate(qid, dsl):
    d = json.loads(dsl)
    out = Q()
    if "bool" in d["query"]:
        boolean(d["query"]["bool"], out)
    else:
        leaf(d["query"], out)
    unknown = set(d) - {"query", "size", "sort", "_source", "track_total_hits", "aggs"}
    if unknown:
        raise ValueError(f"{qid}: unhandled top-level keys {unknown}")
    body = out.body()

    if "aggs" in d:
        (name, agg), = d["aggs"].items()
        if "terms" in agg:
            body["facets"] = [FILT[agg["terms"]["field"]]]
            body["hitsPerPage"] = 0
            return body
        if "date_histogram" in agg:
            raise Unsupported("date_histogram: facets bucket by term, not by date interval")
        raise ValueError(f"{qid}: unhandled agg {set(agg)}")

    size = d.get("size", 10)
    if size == 0:
        body["hitsPerPage"] = 0          # exact totalHits
        return body
    body["limit"] = size
    body["attributesToRetrieve"] = d.get("_source", PROJ_DEFAULT)
    sort = d.get("sort", [])
    if sort:
        (f, dirn), = sort[0].items()
        if f != "_score":
            body["sort"] = [f"TimestampMs:{dirn}"]
        # _score: Meilisearch's default order IS relevance, so nothing to add.
    return body


dsl = parse(ES_DSL)
out, unsup, failed = [], [], []
out += ["-- Meilisearch search bodies over the OTel-logs corpus -- 92 queries",
        "-- mirroring serenedb/queries.sql Q01-Q92 one-for-one. Generated from",
        "-- elastic/queries.dsl by meilisearch/translate.py; see that file for",
        "-- the semantics (quoted=exact, bare=prefix, CONTAINS for OR).", ""]
for i in range(1, 93):
    qid = f"Q{i:02d}"
    if qid not in dsl:
        out += [f"-- {qid} (missing from source)", f"UNSUPPORTED: {qid} absent from elastic/queries.dsl"]
        continue
    tag, body = dsl[qid]
    out.append(f"-- {qid} {tag}")
    if not body.startswith("{"):
        out.append("UNSUPPORTED: join queries -- Meilisearch has no join")
        unsup.append((qid, "join")); continue
    try:
        out.append(json.dumps(translate(qid, body)))
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
