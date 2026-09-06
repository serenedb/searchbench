#!/usr/bin/env python3
"""Generate typesense/queries.ts from elastic/queries.dsl.

One JSON object of search parameters per line; ./query turns it into the
query-string the search endpoint expects.

SEMANTICS, all verified against a running 30.2 server:

* `token_separators: ["_","-","/","."]` on the collection makes tokenization
  match the reference analyzer. Without it "order_id" is one token and exact
  `order` misses it -- the same divergence VictoriaLogs has no fix for. With it,
  `order` matches both, and `orders` still does not.
* Exact term = `num_typos=0` + `prefix=false`. Both are PER-QUERY, unlike
  Meilisearch where typo tolerance is an index-level setting.
* ES prefix   -> `prefix=true`.
* ES wildcard *stem*/`*stem` -> `infix=always` on the infix-enabled Body field.
  Measured free at ingest: 8,896 docs/s without infix, 8,891 with.
* ES fuzzy    -> `num_typos=N`, again per-query. Typesense is the only engine in
  this repo that can express fuzzy without a global setting change.
* Multi-term `q` is AND.
* OR is exact and token-level through filter_by: `Body:a || Body:b`. Verified on
  500k rows -- error 53,789, failed 63,047, both 40,318, OR 76,518, which
  reconciles exactly. (Meilisearch's only OR is substring-based and over-matches.)
* Counts: `per_page=0` -> `found`, which is exact.
* group_by -> `facet_by`.
* Time predicates use TimestampMs (int64). Typesense has no date type, so a
  range over the ISO string would be a lexicographic comparison.

UNSUPPORTED, emitted as sentinels so ./query exits non-zero and the driver
records null:
  - joins (Q84-Q92)
  - date_histogram: facet_by buckets by value, not by time interval
  - non-prefix regexp (e.g. `c.che`): no regex anywhere in the API
  - match_phrase with slop: no proximity operator
"""
import datetime as _dt
import json
import re
import sys
from itertools import combinations

ES_DSL = sys.argv[1] if len(sys.argv) > 1 else "../elastic/queries.dsl"
OUT = sys.argv[2] if len(sys.argv) > 2 else "queries.ts"

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


def iso_ms(s):
    return int(_dt.datetime.fromisoformat(s).replace(tzinfo=_dt.timezone.utc).timestamp() * 1000)


class Q:
    def __init__(self):
        self.q_terms = []          # ANDed terms / phrases in `q`
        self.filters = []          # filter_by clauses
        self.prefix = False
        self.infix = False
        self.num_typos = 0

    def body(self):
        b = {"q": " ".join(self.q_terms) if self.q_terms else "*",
             "query_by": "Body",
             "num_typos": self.num_typos,
             "prefix": "true" if self.prefix else "false"}
        if self.prefix or self.num_typos:
            # max_candidates defaults to 4: only four token expansions are
            # considered, so a prefix with many expansions is silently
            # truncated. `conn*` returned 20 instead of 6,493; at 10000 it is
            # exact. Applies to typo expansion for the same reason.
            b["max_candidates"] = 10000
        if self.infix:
            b["infix"] = "always"
        if self.filters:
            b["filter_by"] = " && ".join(f"({f})" if "||" in f else f for f in self.filters)
        return b


def tfilter(term):
    return f"Body:{term}"


def leaf(node, out: Q):
    (kind, arg), = node.items()

    if kind == "match":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, str):
            terms = v.split()
            if len(terms) == 1:
                out.q_terms.append(terms[0]); return
            out.filters.append(" || ".join(tfilter(t) for t in terms)); return
        terms = v["query"].split()
        msm = int(v.get("minimum_should_match", 1))
        if msm > 1:
            cl = [" && ".join(tfilter(t) for t in combo) for combo in combinations(terms, msm)]
            out.filters.append(" || ".join(f"({c})" for c in cl)); return
        if v.get("operator", "or").lower() == "and":
            out.q_terms.extend(terms); return
        if len(terms) == 1:
            out.q_terms.append(terms[0]); return
        out.filters.append(" || ".join(tfilter(t) for t in terms)); return

    if kind == "match_phrase":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, dict) and "slop" in v:
            raise Unsupported("match_phrase with slop: no proximity operator")
        p = v if isinstance(v, str) else v["query"]
        out.q_terms.append(f'"{p}"'); return

    if kind == "fuzzy":
        (f, v), = arg.items()
        assert f == "Body", f
        val, fz = (v, 1) if isinstance(v, str) else (v["value"], int(v.get("fuzziness", 1)))
        out.q_terms.append(val)
        out.num_typos = max(out.num_typos, min(int(fz), 2))   # Typesense caps at 2
        return

    if kind in ("regexp", "prefix", "wildcard"):
        (f, v), = arg.items()
        assert f == "Body", f
        v = v if isinstance(v, str) else v["value"]
        if kind == "prefix":
            if out.num_typos:
                raise Unsupported("prefix combined with fuzzy in one bool: `q` "
                                  "applies num_typos to every term and prefix only "
                                  "to the last, so the two cannot be merged")
            out.q_terms.append(v); out.prefix = True; return
        if kind == "wildcard":
            if v.endswith("*") and not v.startswith("*") and "*" not in v[:-1] and "?" not in v:
                out.q_terms.append(v[:-1]); out.prefix = True; return
            if v.startswith("*") and v.endswith("*"):
                stem = v.strip("*")
                if stem.isalnum():
                    # Infix == "token contains stem", which is exactly ES *stem*.
                    out.q_terms.append(stem); out.infix = True; return
                raise Unsupported(f"wildcard {v}: non-alphanumeric stem")
            if v.startswith("*"):
                # SUFFIX (*stem) has no exact form: infix matches the stem
                # anywhere in a token, not only at its end, and there is no way
                # to anchor. Measured over-count: 29,165 vs 22,542 truth (+29%).
                raise Unsupported(f"wildcard {v}: suffix match cannot be anchored; "
                                  "infix matches the stem anywhere in a token")
            raise Unsupported(f"wildcard {v}: unhandled shape")
        if v.endswith(".*"):
            stem = v[:-2]
            if not _META.search(stem):
                out.q_terms.append(stem); out.prefix = True; return
        raise Unsupported(f"regexp {v}: no regex support in the API")

    if kind == "term":
        (f, v), = arg.items()
        v = v if not isinstance(v, dict) else v["value"]
        out.filters.append(f"{FILT[f]}:={v}"); return

    if kind == "range":
        (f, v), = arg.items()
        if f == "Timestamp":
            for op, sym in (("gte", ">="), ("gt", ">"), ("lte", "<="), ("lt", "<")):
                if op in v:
                    out.filters.append(f"TimestampMs:{sym}{iso_ms(v[op])}")
            return
        col = FILT[f]
        for op, sym in (("gte", ">="), ("gt", ">"), ("lte", "<="), ("lt", "<")):
            if op in v:
                out.filters.append(f"{col}:{sym}{v[op]}")
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
            leaf(c, sub)
            if sub.q_terms:
                # Push the text side into filter_by so it can participate in OR.
                subs.append(" && ".join(tfilter(t.strip('"')) for t in sub.q_terms)
                            + ("" if not sub.filters else " && " + " && ".join(sub.filters)))
            else:
                subs.append(" && ".join(sub.filters))
        out.filters.append(" || ".join(f"({s})" for s in subs))
    for c in b.get("must_not", []):
        sub = Q()
        leaf(c, sub)
        if sub.q_terms:
            for t in sub.q_terms:
                # `Body:!term` excludes documents containing the token.
                # `Body:!=term` looks plausible but is a NO-OP on a text field:
                # it returned the unfiltered count (Q28 came back identical to
                # Q01, 8,866,117, instead of 3,396,391).
                out.filters.append(f"Body:!{t.strip(chr(34))}")
        for fl in sub.filters:
            out.filters.append(fl.replace(":=", ":!=", 1) if ":=" in fl else f"!({fl})")
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
            body["facet_by"] = FILT[agg["terms"]["field"]]
            body["per_page"] = 0
            body["max_facet_values"] = int(agg["terms"].get("size", 100))
            return body
        if "date_histogram" in agg:
            raise Unsupported("date_histogram: facet_by buckets by value, not time interval")
        raise ValueError(f"{qid}: unhandled agg {set(agg)}")

    size = d.get("size", 10)
    if size == 0:
        body["per_page"] = 0
        return body
    body["per_page"] = size
    body["include_fields"] = ",".join(d.get("_source", PROJ_DEFAULT))
    sort = d.get("sort", [])
    if sort:
        (f, dirn), = sort[0].items()
        if f != "_score":
            body["sort_by"] = f"TimestampMs:{dirn}"
        # _score: Typesense's default order is relevance.
    return body


dsl = parse(ES_DSL)
out, unsup, failed = [], [], []
out += ["-- Typesense search parameters over the OTel-logs corpus -- 92 queries",
        "-- mirroring serenedb/queries.sql Q01-Q92 one-for-one. Generated from",
        "-- elastic/queries.dsl by typesense/translate.py; see that file for the",
        "-- semantics (token_separators, per-query num_typos/prefix/infix).", ""]
for i in range(1, 93):
    qid = f"Q{i:02d}"
    if qid not in dsl:
        out += [f"-- {qid} (missing from source)", f"UNSUPPORTED: {qid} absent from elastic/queries.dsl"]
        continue
    tag, body = dsl[qid]
    out.append(f"-- {qid} {tag}")
    if not body.startswith("{"):
        out.append("UNSUPPORTED: join queries -- Typesense has no join")
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
