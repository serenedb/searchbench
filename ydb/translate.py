#!/usr/bin/env python3
"""Generate ydb/queries.sql (YQL) from elastic/queries.dsl.

YDB reaches its fulltext index through a narrow door, and every shape here
follows from one of its rules:

  * A read carries exactly ONE fulltext predicate, reachable by conjunction.
    `FulltextMatch(..) OR FulltextMatch(..)` and `NOT FulltextMatch(..)` are
    rejected at compile time.
      -> OR and minimum_should_match become a UNION of single-predicate reads.
  * FulltextMatch and FulltextScore cannot share a read ("Multiple fulltext
    predicates in a single read are not supported").
      -> score-ranked queries use `FulltextScore(..) > 0` as the matcher and
         sort by the same expression; it selects the same rows as FulltextMatch.
  * Multi-term FulltextMatch is AND. No operator argument turns it into OR:
    `Mode` is accepted and then silently matches nothing.

CRITICAL: every filter is pushed INTO each UNION arm. The obvious alternative,
`SELECT count(*) FROM otel_logs WHERE Id IN (<union>)`, is correct but forces a
full scan of the base table -- measured at 30.5s against 0.34s for the same
answer on 1M rows, a 90x penalty that would make the OR queries unusable at
100M. Nothing outside a UNION ever references the base table.

Anything the index cannot express (regexp, wildcard, prefix, fuzzy, phrase
adjacency, must_not) is a scalar predicate over BodyNorm, evaluated as a scan.
BodyNorm is space-delimited by construction, so a token test is a substring test
on a padded copy and a token regex anchors on ` `.
"""
import itertools
import json
import re
import sys

ES_DSL = sys.argv[1] if len(sys.argv) > 1 else "../elastic/queries.dsl"
OUT = sys.argv[2] if len(sys.argv) > 2 else "queries.sql"

TABLE = "otel_logs"
VIEW = "idx_rel"
FT = "BodyNorm"
HIT_COLS = ["Timestamp", "ServiceName", "SeverityText", "Body"]
MINUTE = ('DateTime::MakeTimestamp(DateTime::StartOf('
          'DateTime::Split(Timestamp), Interval("PT1M")))')


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


def q(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def pad(col=FT):
    return f'(" " || {col} || " ")'


def tok_contains(term, col=FT):
    return f'String::Contains({pad(col)}, {q(" " + term.lower() + " ")})'


def tok_regex(pattern, col=FT):
    return f'Re2::Grep({q("(^| )(" + pattern + ")( |$)")})({col})'


def esc_re(s):
    return re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", s)


def affix(lit, kind):
    """Token prefix/suffix/infix as a substring test rather than a regex.

    BodyNorm is single-space delimited and padded, so "token starts with X" is
    exactly "` X` occurs", "ends with X" is "`X ` occurs", and infix is a plain
    substring. This is an equivalence, not an approximation, and it replaces an
    RE2 call per row with a memmem scan.
    """
    if kind == "prefix":
        return f'String::Contains({pad()}, {q(" " + lit)})'
    if kind == "suffix":
        return f'String::Contains({pad()}, {q(lit + " ")})'
    return f"String::Contains({FT}, {q(lit)})"


def ts_lit(v):
    v = str(v).replace("Z", "")
    if "T" not in v:
        v += "T00:00:00"
    if len(v) == 16:
        v += ":00"
    return f'Timestamp("{v}Z")'


def terms_of(text):
    return [t for t in re.split(r"[^a-z0-9]+", str(text).lower()) if t]


class Branch:
    """One UNION arm: an AND-set of fulltext terms plus scalar predicates."""

    def __init__(self, terms=None, scalars=None):
        self.terms = list(terms or [])
        self.scalars = list(scalars or [])

    def plus(self, terms, scalars):
        return Branch(self.terms + list(terms), self.scalars + list(scalars))


class Pred:
    def __init__(self):
        self.and_terms = []
        self.scalars = []
        self.or_group = None          # list[Branch]; at most one per query


def build(node, p):
    if not isinstance(node, dict):
        return
    for k, v in node.items():
        if k == "bool":
            for c in v.get("must", []):
                build(c, p)
            for c in v.get("filter", []):
                build(c, p)
            should = v.get("should", [])
            if should:
                msm = int(v.get("minimum_should_match", 1))
                arms = []
                for c in should:
                    sub = Pred()
                    build(c, sub)
                    if sub.or_group:
                        raise Unsupported("nested should inside should")
                    arms.append(Branch(sub.and_terms, sub.scalars))
                p.or_group = combine(arms, msm)
            for c in v.get("must_not", []):
                sub = Pred()
                build(c, sub)
                if sub.or_group:
                    raise Unsupported("must_not over a should group")
                for t in sub.and_terms:
                    p.scalars.append("NOT " + tok_contains(t))
                for s in sub.scalars:
                    p.scalars.append(f"NOT ({s})")
        elif k == "match":
            (f, spec), = v.items()
            if f != "Body":
                raise Unsupported(f"match on {f}")
            if isinstance(spec, dict):
                ts = terms_of(spec["query"])
                op = spec.get("operator", "or").lower()
                msm = spec.get("minimum_should_match")
                if len(ts) == 1 or op == "and":
                    p.and_terms += ts
                else:
                    k_ = int(msm) if msm is not None else 1
                    p.or_group = combine([Branch([t]) for t in ts], k_)
            else:
                p.and_terms += terms_of(spec)
        elif k == "match_phrase":
            (f, spec), = v.items()
            if f != "Body":
                raise Unsupported(f"match_phrase on {f}")
            phrase = spec["query"] if isinstance(spec, dict) else spec
            slop = int(spec.get("slop", 0)) if isinstance(spec, dict) else 0
            ts = terms_of(phrase)
            p.and_terms += ts                       # index narrows to all terms
            if slop:
                # Proximity, not adjacency. Demanding adjacency for a slop query
                # returns 0 (Q13). This allows up to `slop` intervening tokens,
                # in order, which reproduces the reference count exactly.
                gap = f"( [a-z0-9]+){{0,{slop}}} "     # trailing space separates the next term
                p.scalars.append(tok_regex(gap.join(esc_re(t) for t in ts)))
            else:
                p.scalars.append(f'String::Contains({pad()}, {q(" " + " ".join(ts) + " ")})')
        elif k == "term":
            (f, spec), = v.items()
            val = spec["value"] if isinstance(spec, dict) else spec
            if f == "Body":
                p.and_terms.append(str(val).lower())
            else:
                p.scalars.append(f"{f} = " + (q(val) if isinstance(val, str) else str(val)))
        elif k == "terms":
            (f, vals), = v.items()
            joined = ", ".join(q(x) if isinstance(x, str) else str(x) for x in vals)
            p.scalars.append(f"{f} IN ({joined})")
        elif k == "range":
            (f, b), = v.items()
            for op, lim in b.items():
                sym = {"gte": ">=", "lte": "<=", "gt": ">", "lt": "<"}[op]
                p.scalars.append(f"{f} {sym} " + (ts_lit(lim) if f == "Timestamp" else str(lim)))
        elif k == "prefix":
            (f, spec), = v.items()
            val = (spec["value"] if isinstance(spec, dict) else spec).lower()
            p.scalars.append(affix(val, "prefix"))
        elif k == "wildcard":
            (f, spec), = v.items()
            val = (spec["value"] if isinstance(spec, dict) else spec).lower()
            m = re.fullmatch(r"\*([a-z0-9]+)\*", val)
            if m:
                p.scalars.append(affix(m.group(1), "infix"))
                continue
            m = re.fullmatch(r"\*([a-z0-9]+)", val)
            if m:
                p.scalars.append(affix(m.group(1), "suffix"))
                continue
            m = re.fullmatch(r"([a-z0-9]+)\*", val)
            if m:
                p.scalars.append(affix(m.group(1), "prefix"))
                continue
            rx = "".join("[a-z0-9]*" if c == "*" else ("[a-z0-9]" if c == "?" else esc_re(c))
                         for c in val)
            p.scalars.append(tok_regex(rx))
        elif k == "regexp":
            (f, spec), = v.items()
            val = (spec["value"] if isinstance(spec, dict) else spec).lower()
            m = re.fullmatch(r"([a-z0-9]+)\.\*", val)
            if m:
                p.scalars.append(affix(m.group(1), "prefix"))
                continue
            m = re.fullmatch(r"\.\*([a-z0-9]+)", val)
            if m:
                p.scalars.append(affix(m.group(1), "suffix"))
                continue
            p.scalars.append(tok_regex(val))
        elif k == "fuzzy":
            (f, spec), = v.items()
            val = (spec["value"] if isinstance(spec, dict) else spec).lower()
            d = int(spec.get("fuzziness", 1)) if isinstance(spec, dict) else 1
            # No fuzzy operator exists. String::LevensteinDistance is a real UDF,
            # so this is exact -- just a scan, since nothing indexes edit distance.
            p.scalars.append(
                f'ListLength(ListFilter(String::SplitToList({FT}, " "), '
                f'($t) -> (String::LevensteinDistance($t, {q(val)}) <= {d}))) > 0')
        elif k == "match_all":
            pass
        else:
            raise Unsupported(k)


def combine(arms, msm):
    """`msm` of N should-arms -> UNION arms, one per K-combination."""
    if msm <= 1:
        return arms
    out = []
    for combo in itertools.combinations(arms, msm):
        terms, scalars = [], []
        for a in combo:
            terms += a.terms; scalars += a.scalars
        out.append(Branch(terms, scalars))
    return out


def arm_sql(br, cols, scored=False):
    conds, src = [], TABLE
    if br.terms:
        src = f"{TABLE} VIEW {VIEW}"
        expr = f'{FT}, {q(" ".join(br.terms))}'
        conds.append(f"FulltextScore({expr}) > 0" if scored else f"FulltextMatch({expr})")
    conds += br.scalars
    where = (" WHERE " + " AND ".join(conds)) if conds else ""
    return f"SELECT {cols} FROM {src}{where}"


def arms_of(p):
    base = Branch(p.and_terms, p.scalars)
    if p.or_group is None:
        return [base]
    return [base.plus(a.terms, a.scalars) for a in p.or_group]


def body(p, cols, scored=False):
    """Return (sql_source, single) -- a plain source or a parenthesised UNION."""
    arms = arms_of(p)
    if len(arms) == 1:
        return arm_sql(arms[0], cols, scored), True
    return "(" + " UNION ".join(arm_sql(a, cols) for a in arms) + ")", False


def translate(dsl):
    d = json.loads(dsl)
    size = int(d.get("size", 0))
    aggs = d.get("aggs")
    sort = d.get("sort")
    p = Pred()
    build(d.get("query", {}), p)
    single = p.or_group is None

    if aggs:
        name, a = next(iter(aggs.items()))
        if "date_histogram" in a:
            dh = a["date_histogram"]
            iv = dh.get("calendar_interval") or dh.get("fixed_interval")
            if iv not in ("minute", "60s", "1m"):
                raise Unsupported(f"histogram interval {iv}")
            order = " ORDER BY minute" if dh.get("order") else ""
            if single:
                src = arm_sql(arms_of(p)[0], "Timestamp")
                return (f"SELECT minute, count(*) AS cnt FROM ({src}) "
                        f"GROUP BY {MINUTE} AS minute{order};")
            src, _ = body(p, "Id, Timestamp")
            return (f"SELECT minute, count(*) AS cnt FROM {src} "
                    f"GROUP BY {MINUTE} AS minute{order};")
        if "terms" in a:
            t = a["terms"]
            key = t["field"]
            sub = a.get("aggs")
            if sub:
                # ES nests (top-N of key, then top-M within each). YDB has no
                # nested aggregation; this is the flat two-key form the other SQL
                # adapters use. Non-equivalent -- see README.
                st = next(iter(sub.values()))["terms"]
                cols = f"{key}, {st['field']}"
                src, s1 = body(p, cols if single else f"Id, {cols}")
                src = src if not s1 else f"({src})"
                return (f"SELECT {key}, {st['field']}, count(*) AS cnt FROM {src} "
                        f"GROUP BY {key}, {st['field']} ORDER BY cnt DESC "
                        f"LIMIT {int(st.get('size', 20))};")
            order = " ORDER BY cnt DESC" if t.get("order", {}).get("_count") else ""
            src, s1 = body(p, key if single else f"Id, {key}")
            src = f"({src})" if s1 else src
            return (f"SELECT {key}, count(*) AS cnt FROM {src} GROUP BY {key}"
                    f"{order} LIMIT {int(t.get('size', 100))};")
        raise Unsupported("aggregation kind")

    if size == 0:
        if single:
            arms = arms_of(p)
            conds, src = [], TABLE
            if arms[0].terms:
                src = f"{TABLE} VIEW {VIEW}"
                conds.append(f'FulltextMatch({FT}, {q(" ".join(arms[0].terms))})')
            conds += arms[0].scalars
            where = (" WHERE " + " AND ".join(conds)) if conds else ""
            return f"SELECT count(*) AS c FROM {src}{where};"
        src, _ = body(p, "Id")
        return f"SELECT count(*) AS c FROM {src};"

    cols = ", ".join(HIT_COLS)
    scored = (sort == [{"_score": "desc"}]) and single and bool(p.and_terms)
    if scored:
        sc = f'FulltextScore({FT}, {q(" ".join(p.and_terms))})'
        src = arm_sql(arms_of(p)[0], f"{cols}, {sc} AS sc", scored=True)
        return f"SELECT * FROM ({src}) ORDER BY sc DESC LIMIT {size};"
    src, s1 = body(p, cols if single else f"Id, {cols}")
    src = f"({src})" if s1 else src
    if sort == [{"Timestamp": "desc"}]:
        return f"SELECT {cols} FROM {src} ORDER BY Timestamp DESC LIMIT {size};"
    # _score ordering needs one indexed fulltext predicate; a UNION query has
    # none, so it degrades to an unordered page (documented in README).
    return f"SELECT {cols} FROM {src} LIMIT {size};"


# --- joins -----------------------------------------------------------------
# Q84-Q92 are ES|QL upstream, not JSON, so they are specified here directly,
# mirroring the SQL adapters: a self-join on TraceId where side `a` carries the
# text predicate and side `b` a service filter. YDB does joins natively.
JOINS = {
    "Q84": ({"match": {"Body": "failed"}}, "frontend", "payment"),
    "Q85": ({"match": {"Body": {"query": "error failed", "operator": "or"}}}, None, "payment"),
    "Q86": ({"match_phrase": {"Body": "failed to place order"}}, None, "payment"),
    "Q87": ({"regexp": {"Body": "charg.*"}}, None, "frontend"),
    "Q88": ({"match": {"Body": {"query": "failed order", "operator": "and"}}}, None, "cart"),
    "Q89": ({"match": {"Body": {"query": "connection request", "operator": "or"}}}, None, "frontend"),
    "Q90": ({"match": {"Body": {"query": "charge request", "operator": "and"}}}, None, "frontend"),
    "Q91": ({"match": {"Body": "order"}}, None, "payment"),
    "Q92": ({"prefix": {"Body": "charg"}}, None, "frontend"),
}


def translate_join(spec):
    node, svc_a, svc_b = spec
    p = Pred()
    build(node, p)
    if svc_a:
        p.scalars.append(f"ServiceName = {q(svc_a)}")
    p.scalars.append('TraceId != ""')
    src, s1 = body(p, "TraceId")
    src = f"({src})" if s1 else src
    return (f"SELECT count(DISTINCT a.TraceId) AS c FROM {src} AS a "
            f"JOIN (SELECT DISTINCT TraceId FROM {TABLE} WHERE ServiceName = {q(svc_b)} "
            f'AND TraceId != "") AS b ON a.TraceId = b.TraceId;')


dsl = parse(ES_DSL)
out, unsup = [], []
out += ["-- Generated by ydb/translate.py from elastic/queries.dsl.",
        "-- One fulltext predicate per read, none under OR/NOT: OR and",
        "-- minimum_should_match are UNIONs of index reads with every filter",
        "-- pushed into each arm (an outer `Id IN (<union>)` costs 90x).",
        "-- regexp/wildcard/prefix/fuzzy/must_not are scalar scans.",
        ""]
for i in range(1, 93):
    qid = f"Q{i:02d}"
    if qid not in dsl:
        out += [f"-- {qid} (missing)", f"UNSUPPORTED: {qid} absent"]; continue
    tag, bodytxt = dsl[qid]
    out.append(f"-- {qid} {tag}")
    try:
        if qid in JOINS:
            out.append(translate_join(JOINS[qid]))
        elif not bodytxt.startswith("{"):
            raise Unsupported("non-JSON source and no join spec")
        else:
            out.append(translate(bodytxt))
    except Unsupported as e:
        out.append(f"UNSUPPORTED: {e}"); unsup.append((qid, str(e)))
    except Exception as e:                                     # noqa: BLE001
        out.append(f"UNSUPPORTED: TRANSLATE FAILED: {e}"); unsup.append((qid, f"failed: {e}"))

open(OUT, "w").write("\n".join(out) + "\n")
runnable = sum(1 for l in out if l and not l.startswith(("--", "UNSUPPORTED")))
print(f"wrote {OUT}: {runnable}/92 runnable, {len(unsup)} unsupported")
by = {}
for qid, why in unsup:
    by.setdefault(why.split(":")[0], []).append(qid)
for why, qs in sorted(by.items()):
    print(f"  {why}: {len(qs)} -> {' '.join(qs)}")
