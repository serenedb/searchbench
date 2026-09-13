#!/usr/bin/env python3
"""Generate quickwit/queries.dsl from elastic/queries.dsl.

Quickwit speaks the Elasticsearch query DSL, so this is a REWRITER, not a
translator into another language: most queries pass through untouched. Measured
against a running 0.9.0 server, 45 of the 92 ES queries run verbatim; this
handles the three constructs that do not.

WHAT PASSES THROUGH UNCHANGED
    match (string form), match_phrase, term, bool, range, prefix, wildcard,
    regexp, terms aggregations, date_histogram with fixed_interval.
    regexp and wildcard working natively is worth noting -- Meilisearch,
    Typesense and SurrealDB all needed workarounds for those.

WHAT IS REWRITTEN
  * `match` OBJECT form -> HTTP 400. `{"match":{"Body":{"query":"a b",
    "operator":"and"}}}` becomes a bool over single-term match clauses:
        operator=and             -> bool.must   [match a, match b]
        operator=or (default)    -> bool.should [...] minimum_should_match 1
        minimum_should_match=K   -> bool.should [...] minimum_should_match K
    Quickwit accepts bool.minimum_should_match, so "at least K of N" needs no
    subset expansion -- unlike the cratedb, victorialogs, surrealdb, meilisearch
    and typesense adapters, which all have to enumerate K-subsets.
  * `date_histogram` with `calendar_interval` -> HTTP 500. Rewritten to
    `fixed_interval` (minute -> 60s, hour -> 3600s, day -> 86400s). The corpus
    has no DST or leap seconds in play, so fixed and calendar buckets coincide.

UNSUPPORTED
  * fuzzy -> HTTP 400, no edit-distance query in the ES-compatible layer
  * joins (Q84-Q92), which are ES|QL upstream and not JSON at all
"""
import json
import re
import sys

ES_DSL = sys.argv[1] if len(sys.argv) > 1 else "../elastic/queries.dsl"
OUT = sys.argv[2] if len(sys.argv) > 2 else "queries.dsl"

_INTERVAL = {"second": "1s", "minute": "60s", "hour": "3600s", "day": "86400s"}


class Unsupported(Exception):
    pass


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


def rewrite_node(n):
    """Recursively rewrite the query tree in place-ish, returning a new node."""
    if isinstance(n, list):
        return [rewrite_node(x) for x in n]
    if not isinstance(n, dict):
        return n
    out = {}
    for k, v in n.items():
        if k == "fuzzy":
            raise Unsupported("fuzzy: rejected with HTTP 400 by the "
                              "ES-compatible layer (no edit-distance query)")
        if k == "match" and isinstance(v, dict):
            (field, spec), = v.items()
            if isinstance(spec, dict):
                terms = spec["query"].split()
                if len(terms) == 1:
                    out["match"] = {field: terms[0]}
                    continue
                op = spec.get("operator", "or").lower()
                msm = int(spec.get("minimum_should_match", 1))
                clauses = [{"match": {field: t}} for t in terms]
                if op == "and":
                    out["bool"] = {"must": clauses}
                else:
                    out["bool"] = {"should": clauses, "minimum_should_match": msm}
                continue
            out["match"] = v
            continue
        out[k] = rewrite_node(v)
    return out


def rewrite(qid, dsl):
    d = json.loads(dsl)
    d["query"] = rewrite_node(d["query"])
    aggs = d.get("aggs")
    if aggs:
        for name, a in aggs.items():
            dh = a.get("date_histogram")
            if dh and "calendar_interval" in dh:
                ci = dh.pop("calendar_interval")
                if ci not in _INTERVAL:
                    raise Unsupported(f"date_histogram calendar_interval {ci}")
                dh["fixed_interval"] = _INTERVAL[ci]
                # min_doc_count/order are accepted; leave them as-is.
    return json.dumps(d)


dsl = parse(ES_DSL)
out, unsup, failed = [], [], []
out += ["-- Quickwit runs the Elasticsearch query DSL through /api/v1/_elastic,",
        "-- so this file is elastic/queries.dsl with three constructs rewritten:",
        "-- `match` object form, and date_histogram calendar_interval. See",
        "-- quickwit/translate.py for what passes through untouched.", ""]
for i in range(1, 93):
    qid = f"Q{i:02d}"
    if qid not in dsl:
        out += [f"-- {qid} (missing from source)", f"UNSUPPORTED: {qid} absent"]
        continue
    tag, body = dsl[qid]
    out.append(f"-- {qid} {tag}")
    if not body.startswith("{"):
        out.append("UNSUPPORTED: join queries -- Quickwit has no join")
        unsup.append((qid, "join")); continue
    try:
        out.append(rewrite(qid, body))
    except Unsupported as e:
        out.append(f"UNSUPPORTED: {e}"); unsup.append((qid, str(e)))
    except Exception as e:
        out.append(f"UNSUPPORTED: REWRITE FAILED: {e}"); failed.append((qid, str(e)))

open(OUT, "w").write("\n".join(out) + "\n")
runnable = sum(1 for l in out if l and not l.startswith(("--", "UNSUPPORTED")))
print(f"wrote {OUT}: {runnable}/92 runnable, {len(unsup)} unsupported, {len(failed)} failed")
by = {}
for qid, why in unsup:
    by.setdefault(why.split(":")[0], []).append(qid)
for why, qs in sorted(by.items()):
    print(f"  {why}: {len(qs)} -> {' '.join(qs)}")
if failed:
    print("FAILED:")
    for qid, why in failed:
        print(f"  {qid}: {why}")
