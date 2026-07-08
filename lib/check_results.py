#!/usr/bin/env python3
"""Cross-engine result comparison + agreement verdict for SearchBench.

Loads every engine's result artifacts for a dataset:
  <engine>/results/<name>_<dataset>.json        -> query_tags[].id/.task + result[] timings
  <engine>/results/<name>_<dataset>.results.log -> per-query row count + result body
query_tags[] runs parallel to both, so each query is keyed by its tag id.

Engines are discovered from the result files on disk -- there is no hardcoded
engine list. Writes one comparison report to --out and prints the verdict at the
end; exit code is non-zero if any issue is found, so it is CI-usable.

Per-task content normalization (for the content diff vs --ref):
  count           -> count scalar
  group_by        -> {key: count} multiset (order/key-format independent)
  top_k | recent  -> row cardinality only (content is order/format/tie sensitive)

Usage:
  lib/check_results.py [dataset]              # default otel_logs_1m
  lib/check_results.py 100m --ref SereneDB
  lib/check_results.py 1m --out report.txt
"""
import argparse
import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECTION_RE = re.compile(r"^===== Q(\d+) \(rows: (\S+)\) =====$")
SPLIT_RE = re.compile(r"[\t|]")
INT_RE = re.compile(r"-?\d+")


def parse_log(path):
    """Ordered list of (rows_raw, [body_line,...]) per query section."""
    out = []
    if not os.path.exists(path):
        return out
    rows, body, in_body = None, [], False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            m = SECTION_RE.match(line)
            if m:
                if rows is not None:
                    out.append((rows, [b for b in body if b != ""]))
                rows, body, in_body = m.group(2), [], False
                continue
            if line == "----- result -----":
                in_body = True
                continue
            if in_body:
                body.append(line)
    if rows is not None:
        out.append((rows, [b for b in body if b != ""]))
    return out


def rows_to_int(rows):
    try:
        return int(rows)
    except (ValueError, TypeError):
        return None


def parse_group_line(line):
    """One group_by row -> (key, count) across engine formats:
       SQL 'error|125916' / 'error\t125916' / two-key 'a||5';
       ES|QL '[125916,"error"]'; OS/Solr '{"key":"error","doc_count":125916}'."""
    s = line.strip()
    if not s:
        return None
    if s[0] == "{":
        try:
            o = json.loads(s)
        except ValueError:
            return None
        cnt = o.get("doc_count", o.get("count"))
        return (str(o.get("key", o.get("val", ""))), int(cnt)) if cnt is not None else None
    if s[0] == "[":
        try:
            a = json.loads(s)
        except ValueError:
            return None
        ints = [x for x in a if isinstance(x, int) and not isinstance(x, bool)]
        strs = [str(x) for x in a if not (isinstance(x, int) and not isinstance(x, bool))]
        return ("|".join(strs), ints[0]) if ints else None
    parts = SPLIT_RE.split(line)  # split ORIGINAL line: keep a leading-empty group key
    if len(parts) < 2:
        return None
    try:
        return "|".join(parts[:-1]), int(parts[-1])
    except ValueError:
        return None


def normalize(task, body):
    if task == "count":
        m = INT_RE.search(body[0]) if body else None
        return {"count": int(m.group())} if m else {"count": None}
    if task == "group_by":
        groups = {}
        for ln in body:
            kv = parse_group_line(ln)
            if kv:
                groups[kv[0]] = kv[1]
        return {"groups": groups}
    return {"rows": len(body)}


def load_engine(json_path):
    with open(json_path, encoding="utf-8") as fh:
        data = json.load(fh)
    system = data.get("system") or os.path.basename(json_path).split("_")[0]
    tags = data.get("query_tags") or []
    timings = data.get("result") or []
    sections = parse_log(json_path[:-5] + ".results.log")
    has_log = bool(sections)
    if has_log and len(sections) != len(tags):
        print(f"  WARN {system}: {len(sections)} log sections vs {len(tags)} query_tags "
              f"(stale log? re-run the benchmark)", file=sys.stderr)
    byid = {}
    for i, tag in enumerate(tags):
        qid = (tag.get("id") or f"#{i+1}").upper()
        task = tag.get("task") or ""
        rows_raw, body = sections[i] if i < len(sections) else ("err", [])
        timing = timings[i] if i < len(timings) else None
        skipped = (isinstance(timing, list) and (not timing or timing[0] is None)) \
            or (bool(body) and body[0].upper().startswith("UNSUPPORTED"))
        byid[qid] = {
            "task": task,
            "rows": rows_to_int(rows_raw),
            "skipped": bool(skipped),
            "value": None if skipped else normalize(task, body),
        }
    return system, data.get("date", "?"), has_log, byid


def resolve(name, engines):
    """Map a user token (e.g. 'es', 'parade', 'pg') to a present engine."""
    if not name:
        return None
    n = name.lower()
    for e in engines:
        if e.lower() == n:
            return e
    for e in engines:
        if e.lower().startswith(n) or n in e.lower():
            return e
    aliases = {"es": "Elasticsearch", "os": "OpenSearch", "pg": "Postgres",
               "parade": "ParadeDB", "serene": "SereneDB"}
    for k, v in aliases.items():
        if n.startswith(k) and v in engines:
            return v
    return None


def values_match(task, fv, rv):
    """group_by: compare the COUNT multiset (order/key-format independent).
    Others: exact."""
    if fv is None or rv is None:
        return False
    if task == "group_by":
        return sorted((fv.get("groups") or {}).values()) == sorted((rv.get("groups") or {}).values())
    return fv == rv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset", nargs="?", default="otel_logs_1m")
    ap.add_argument("--ref", default="SereneDB", help="reference engine (default SereneDB)")
    ap.add_argument("--out", default=None, help="report file (default results_report_<dataset>.txt)")
    args = ap.parse_args()
    ds = args.dataset if args.dataset.startswith("otel_logs_") else f"otel_logs_{args.dataset}"
    out_path = args.out or os.path.join(REPO, f"results_report_{ds}.txt")

    paths = sorted(glob.glob(os.path.join(REPO, "*", "results", f"*_{ds}.json")))
    if not paths:
        print(f"no result JSONs found for dataset '{ds}' under */results/", file=sys.stderr)
        return 2

    engines, dates, has_log = {}, {}, {}
    for p in paths:
        system, date, hl, byid = load_engine(p)
        engines[system] = byid
        dates[system] = date
        has_log[system] = hl

    names = list(engines)                       # every engine present -- no hardcoded list
    logged = [n for n in names if has_log[n]]   # only these can be content-compared
    ref = resolve(args.ref, engines)
    all_ids = sorted({q for b in engines.values() for q in b},
                     key=lambda q: int(re.sub(r"\D", "", q) or 0))

    out = []
    out.append("SearchBench result comparison")
    out.append(f"dataset  : {ds}")
    out.append("engines  : " + ", ".join(f"{n} ({dates[n]})" for n in names))
    out.append(f"reference: {ref or '(absent: ' + args.ref + ')'}")
    nolog = [n for n in names if not has_log[n]]
    if nolog:
        out.append(f"no .results.log (row bodies unavailable, not compared): {', '.join(nolog)}")
    out.append("")

    w = max(12, *(len(n) for n in names))
    header = f"{'Q':<5} {'task':<10} " + "".join(f"{n:>{w}}" for n in names) + "   vs-ref"
    out.append(header)
    out.append("-" * len(header))

    issues = []
    for qid in all_ids:
        task = next((engines[n][qid]["task"] for n in names
                     if qid in engines[n] and engines[n][qid]["task"]), "")
        cells, present = [], []
        for n in names:
            e = engines[n].get(qid)
            if e is None:
                cells.append("-")
            elif not has_log[n]:
                cells.append("no-log")
            elif e["skipped"]:
                cells.append("skip")
            elif e["rows"] is None:
                cells.append("ERR")
            else:
                cells.append(str(e["rows"]))
                present.append((n, e["rows"]))

        # EMPTY: some engine ran and got data, this one ran but got 0 rows
        max_rows = max((r for _, r in present), default=0)
        if max_rows > 0:
            for n, r in present:
                if r == 0:
                    issues.append(f"EMPTY  {qid} ({task}): {n} returned 0 rows (others up to {max_rows})")
        # ERROR (only for engines that have a log)
        for n in logged:
            e = engines[n].get(qid)
            if e and not e["skipped"] and e["rows"] is None:
                issues.append(f"ERROR  {qid} ({task}): {n} errored")

        # content diff vs ref (non-count tasks; counts handled by COUNT check below)
        vcell = ""
        if ref and has_log.get(ref) and qid in engines[ref] and not engines[ref][qid]["skipped"]:
            rv = engines[ref][qid]["value"]
            diffs = []
            for n in logged:
                if n == ref:
                    continue
                e = engines[n].get(qid)
                if not e or e["skipped"] or e["value"] is None:
                    continue
                if task != "count" and not values_match(task, e["value"], rv):
                    diffs.append(n)
                    issues.append(f"DIFF   {qid} ({task}): {n}={json.dumps(e['value'])} "
                                  f"{ref}={json.dumps(rv)}")
            vcell = "OK" if not diffs else "DIFF:" + ",".join(diffs)
        elif ref:
            vcell = "no-ref"

        out.append(f"{qid:<5} {task:<10} " + "".join(f"{c:>{w}}" for c in cells) + f"   {vcell}")

        # COUNT cross-engine agreement (ref-independent)
        if task == "count":
            vals = {}
            for n in logged:
                e = engines[n].get(qid)
                if e and not e["skipped"] and e["value"] is not None:
                    s = e["value"].get("count")
                    if s is not None:
                        vals[n] = s
            if len(set(vals.values())) > 1:
                detail = ", ".join(f"{n}={v}" for n, v in sorted(vals.items()))
                issues.append(f"COUNT  {qid}: disagreement -> {detail}")

    out.append("")
    out.append("ISSUES")
    out.append("------")
    out.extend("  " + m for m in issues) if issues else out.append("  (none)")
    out.append("")

    if not logged:
        verdict = "NO DATA: no .results.log found — run a benchmark first (nothing compared)."
    elif issues:
        verdict = f"FAIL: {len(issues)} issue(s)."
    else:
        verdict = "OK: engines agree (no empty results, errors, or disagreements)."
    out.append(f"VERDICT: {verdict}")

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")

    print(f"wrote {out_path}")
    print(f"VERDICT: {verdict}")
    return 1 if (logged and issues) else 0


if __name__ == "__main__":
    sys.exit(main())
