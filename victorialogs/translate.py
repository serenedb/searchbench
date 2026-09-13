#!/usr/bin/env python3
"""Generate victorialogs/queries.logsql from elastic/queries.dsl.

The Elasticsearch DSL is parseable JSON and the most explicit statement of what
each query means, so it drives the translation (same approach as
cratedb/translate.py). Anything unrecognised raises -- a silently mistranslated
query is worse than no query.

SEMANTIC NOTES

* LogsQL word matching is CASE-SENSITIVE and there is no analyzer stage, so
  ingest.py feeds _msg a LOWERCASED copy of Body (the original stays in the Body
  field). Filters therefore use plain case-sensitive forms against already-lower
  terms, which is exactly ES `match` semantics AND bloom-filterable. The
  alternative -- wrapping every filter in i(...) -- cannot use the per-block
  bloom filters: measured at 100M, i(payment) 4.108s vs payment 0.098s for the
  identical 200,335 rows.

* LogsQL tokenises on most non-alphanumerics ('.', '/', '-', space) but KEEPS
  '_' inside a token, where the reference analyzer splits on it. So i(word) ==
  ES `match` only for terms that never appear inside an underscore-joined token;
  see word() for the measured divergence and the VL_TERM_MODE=exact escape
  hatch. i("a b c") == `match_phrase` and i(word*) == `prefix` hold either way.

* ES `regexp`/`wildcard` match a TERM in the inverted index. LogsQL's ~"re"
  matches anywhere in the whole _msg value, so those become boundary-anchored
  regexes over [a-z0-9] runs. Explicit classes, NOT \\b: Go's \\b counts '_' as a
  word character but the analyzer splits on it, which silently shifts counts.

* Three constructs have no LogsQL form at all and are emitted as UNSUPPORTED
  sentinels (./query exits non-zero, lib/benchmark.sh records null):
    - relevance ranking (sort by _score): LogsQL has no BM25 / scoring pipe
    - fuzzy matching: no edit-distance operator
    - joins (Q84-Q92): no join support
  Marking them beats substituting a different question and reporting the time.
"""
import json
import os
import re
import sys
from itertools import combinations

ES_DSL = sys.argv[1] if len(sys.argv) > 1 else "../elastic/queries.dsl"
OUT = sys.argv[2] if len(sys.argv) > 2 else "queries.logsql"

# ES field -> VictoriaLogs field. Body is the message field (_msg), Timestamp the
# time field (_time); both are set at ingest (see ingest.py).
FIELD = {"Timestamp": "_time", "Body": "_msg", "ServiceName": "ServiceName",
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
            tag = (m.group(1), m.group(2))
            continue
        if s.strip() and not s.strip().startswith("--") and tag:
            out[tag[0]] = (tag[1], s.strip())
            tag = None
    return out


class Unsupported(Exception):
    pass


TERM_MODE = os.environ.get("VL_TERM_MODE", "word")


def word(w):
    """One analyzer token -> LogsQL term filter.

    VictoriaLogs' tokenizer KEEPS '_' inside a token, while the reference
    analyzer used by every other engine here splits on it. So
    "send_order_confirmation" is one token to VictoriaLogs and three to
    everyone else, and i(order) misses those rows. Measured on otel_logs_1m,
    5 of the workload's 24 distinct terms diverge:

        term          i(term)   reference    delta
        email           2,367       6,655   -4,288
        send            1,092       4,957   -3,865
        confirmation    3,439       5,160   -1,721
        order          63,890      65,611   -1,721
        deadline           23          24       -1

    (Counts above were measured with the i(...) form; the ratio is what matters,
    and it is unchanged now that _msg is lowercased at ingest.)

    Two modes, because neither is free:

      word  (default) a plain word filter against the lowercased _msg --
            the engine's own tokenization, bloom-filterable, sub-100ms/term at
            100M. What a VictoriaLogs user would actually write. Row counts
            diverge from the other engines on the terms above.

      exact VL_TERM_MODE=exact -- a boundary-anchored regex whose word class
            excludes '_', reproducing the reference analyzer exactly (verified:
            6,655 and 65,611). Much slower: it scans _msg instead of consulting
            the token index.

    Explicit classes, NOT \\b: Go's \\b counts '_' as a word character, which is
    the very difference being corrected for.

    A trailing '*' must stay UNQUOTED -- "conn*" is a literal phrase, conn* is a
    prefix filter.
    """
    if TERM_MODE == "exact":
        return '_msg:~"(^|[^a-z0-9])%s([^a-z0-9]|$)"' % w
    if w.endswith("*"):
        return w
    return f'"{w}"'


def phrase(p):
    return '"%s"' % p.replace('"', '\\"')


def tok_regex(body, literal=None):
    """Boundary-anchored regex over _msg, with a literal prefilter when possible.

    A bare regex has nothing for the per-block bloom filters to test, so it reads
    all 100M messages. But every match of a pattern necessarily contains that
    pattern's longest literal run, so ANDing a substring filter on that run is
    semantically free and lets the bloom filters skip most blocks first.

    Measured at 100M on Q19 (`c.che`), both returning 6,153,906 rows:
        bare regex                21.66s
        *che* AND regex            3.62s      6.0x
    The prefilter itself is only mildly selective (12.6M rows, 0.57s) -- the win
    is that the expensive regex then runs over 12.6M rows instead of 100M.
    """
    esc = body.replace('"', '\\"')
    rx = '_msg:~"%s"' % esc
    if literal and len(literal) >= 3:
        return f'*{literal}* AND {rx}'
    return rx


def longest_literal(pat):
    """Longest alphanumeric run in an ES term pattern -- the substring every
    match must contain. '' when the pattern has no run of >=3."""
    runs = re.findall(r"[a-z0-9]+", pat.lower())
    return max(runs, key=len) if runs else ""


def leaf(node):
    (kind, arg), = node.items()

    if kind == "match":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, str):
            terms = v.split()
            # ES `match` defaults to OR across the analyzed terms.
            return "(" + " OR ".join(word(t) for t in terms) + ")" if len(terms) > 1 else word(v)
        terms = v["query"].split()
        msm = int(v.get("minimum_should_match", 1))
        if msm > 1:
            # "at least K of N" has no LogsQL operator; expand to an OR over
            # every K-subset, which reproduces ES exactly (same shape the
            # CrateDB adapter needs).
            clauses = [" AND ".join(word(t) for t in combo) for combo in combinations(terms, msm)]
            return "(" + " OR ".join(f"({c})" for c in clauses) + ")"
        op = v.get("operator", "or").lower()
        joiner = " AND " if op == "and" else " OR "
        return "(" + joiner.join(word(t) for t in terms) + ")" if len(terms) > 1 else word(terms[0])

    if kind == "match_phrase":
        (f, v), = arg.items()
        assert f == "Body", f
        if isinstance(v, str):
            return phrase(v)
        if "slop" in v:
            raise Unsupported("match_phrase with slop: LogsQL has no proximity/slop operator")
        return phrase(v["query"])

    if kind == "fuzzy":
        raise Unsupported("fuzzy matching: LogsQL has no edit-distance operator")

    if kind in ("regexp", "prefix", "wildcard"):
        (f, v), = arg.items()
        assert f == "Body", f
        v = v if isinstance(v, str) else v["value"]

        if kind == "prefix":
            return word(v + "*")
        if kind == "wildcard":
            if v.endswith("*") and not v.startswith("*") and "*" not in v[:-1] and "?" not in v:
                return word(v)                       # x*  -> index-backed prefix
            if v.startswith("*") and v.endswith("*"):
                stem = v[1:-1]
                if stem.isalnum():
                    # An alphanumeric stem cannot straddle a token boundary, so a
                    # plain substring regex is exactly the term-level test.
                    return tok_regex(stem, stem)
                raise Unsupported(f"wildcard {v}: non-alphanumeric infix stem")
            if v.startswith("*"):
                stem = v[1:]
                if stem.isalnum():
                    return tok_regex(stem + "([^a-z0-9]|$)", stem)  # token ENDS with stem
                raise Unsupported(f"wildcard {v}: non-alphanumeric suffix stem")
            raise Unsupported(f"wildcard {v}: unhandled shape")
        # regexp
        if v.endswith(".*"):
            stem = v[:-2]
            if not _META.search(stem):
                return word(stem + "*")              # x.* -> index-backed prefix
        return tok_regex("(^|[^a-z0-9])" + v + "([^a-z0-9]|$)", longest_literal(v))

    if kind == "term":
        (f, v), = arg.items()
        v = v if not isinstance(v, dict) else v["value"]
        return f"{FIELD[f]}:={v}"

    if kind == "range":
        (f, v), = arg.items()
        if f == "Timestamp":
            lo, hi = v.get("gte") or v.get("gt"), v.get("lte") or v.get("lt")
            # Corpus is UTC; the DSL writes naive ISO strings.
            return f"_time:[{lo}Z, {hi}Z]"
        col = FIELD[f]
        parts = []
        for op, sql in (("gte", ">="), ("gt", ">"), ("lte", "<="), ("lt", "<")):
            if op in v:
                parts.append(f"{col}:{sql}{v[op]}")
        return "(" + " AND ".join(parts) + ")" if len(parts) > 1 else parts[0]

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
        out.append("(" + " OR ".join(shoulds) + ")")
    for c in b.get("must_not", []):
        out.append("-(" + leaf(c) + ")")
    unknown = set(b) - {"must", "filter", "should", "must_not", "minimum_should_match"}
    if unknown:
        raise ValueError(f"unhandled bool keys: {unknown}")
    return " AND ".join(x for x in out if x)


_INTERVAL = {"minute": "1m", "hour": "1h", "day": "1d", "second": "1s"}


def translate(qid, dsl):
    d = json.loads(dsl)
    where = boolean(d["query"]["bool"]) if "bool" in d["query"] else leaf(d["query"])
    where = where or "*"
    unknown = set(d) - {"query", "size", "sort", "_source", "track_total_hits", "aggs"}
    if unknown:
        raise ValueError(f"{qid}: unhandled top-level keys {unknown}")

    if "aggs" in d:
        (name, agg), = d["aggs"].items()
        if "terms" in agg:
            t = agg["terms"]
            col = FIELD[t["field"]]
            lim = f" | limit {int(t['size'])}" if "size" in t else ""
            order = t.get("order", {})
            if order.get("_key") == "asc":
                srt = f" | sort by ({col})"
            else:
                srt = " | sort by (cnt) desc"
            return f"{where} | stats by ({col}) count() as cnt{srt}{lim}"
        if "date_histogram" in agg:
            h = agg["date_histogram"]
            iv = _INTERVAL[h["calendar_interval"]]
            return f"{where} | stats by (_time:{iv}) count() as cnt | sort by (_time)"
        raise ValueError(f"{qid}: unhandled agg {set(agg)}")

    size = d.get("size", 10)
    if size == 0:
        return f"{where} | stats count() as cnt"

    proj = d.get("_source", PROJ_DEFAULT)
    fields = " | fields " + ",".join(FIELD.get(c, c) for c in proj)
    sort = d.get("sort", [])
    if sort:
        (f, dirn), = sort[0].items()
        if f == "_score":
            raise Unsupported("sort by _score: LogsQL has no relevance scoring (no BM25 pipe)")
        col = FIELD[f]
        return f"{where} | sort by ({col}) {dirn}{fields} | limit {size}"
    return f"{where} | limit {size}{fields}"


dsl = parse(ES_DSL)
out, unsupported, failed = [], [], []
out.append("-- VictoriaLogs LogsQL workload over the OTel-logs corpus -- 92 queries")
out.append("-- mirroring serenedb/queries.sql Q01-Q92 one-for-one. Generated from")
out.append("-- elastic/queries.dsl by victorialogs/translate.py; see that file for")
out.append("-- the semantics (case-insensitivity, term-level regex boundaries).")
out.append("")
for i in range(1, 93):
    qid = f"Q{i:02d}"
    if qid not in dsl:
        out.append(f"-- {qid} (missing from source)")
        out.append(f"UNSUPPORTED: {qid} absent from elastic/queries.dsl")
        continue
    tag, body = dsl[qid]
    out.append(f"-- {qid} {tag}")
    if not body.startswith("{"):
        # Q84-Q92 are the self-join queries, expressed as ES|QL upstream.
        out.append("UNSUPPORTED: join queries -- LogsQL has no join support")
        unsupported.append((qid, "join"))
        continue
    try:
        out.append(translate(qid, body))
    except Unsupported as e:
        out.append(f"UNSUPPORTED: {e}")
        unsupported.append((qid, str(e)))
    except Exception as e:
        out.append(f"UNSUPPORTED: TRANSLATION FAILED: {e}")
        failed.append((qid, str(e)))

open(OUT, "w").write("\n".join(out) + "\n")
runnable = sum(1 for l in out if l and not l.startswith(("--", "UNSUPPORTED")))
print(f"wrote {OUT}: {runnable}/92 runnable, {len(unsupported)} unsupported, {len(failed)} failed")
if unsupported:
    print("unsupported:")
    for qid, why in unsupported:
        print(f"  {qid}: {why}")
if failed:
    print("FAILED (bugs in the translator, fix these):")
    for qid, why in failed:
        print(f"  {qid}: {why}")
