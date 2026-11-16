#!/usr/bin/env python3
"""Publish the Quickwit main runs of 2026-11-15 from the per-box evidence.

    publish.py <evidence-root> [dataset ...]

<evidence-root>/<box>/<dataset>/ is the evidence/<dataset>/ directory of each box
(box = local | s3), as written by production.sh. For every (box, dataset) with
three query rounds this writes, relative to the repository's quickwit/ directory:

  results/quickwit_main-<box>_<dataset>.json    per-query, per-try MEDIAN of the rounds
  results/load/<dataset>.main-<box>.json        the load record of that index
  runs/main-20261115/<box>/<dataset>/           rounds (r1..rN results + logs, gzipped),
                                                check-recent output, load samples, splits,
                                                corpus check, load environment

A query is null in the median if it was null in any round (it never is here:
the 15 nulls are the unsupported queries, null in every round). Account, bucket,
instance and role names are replaced with placeholders in everything copied.
"""
import glob, gzip, json, os, re, shutil, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
QW = os.path.abspath(os.path.join(HERE, "..", ".."))
# Targeted, not pattern-wide: the corpus itself is full of IPs and 12-digit numbers
# (byte counts), which must stay. The names to replace are not in this file: they
# are read from <evidence-root>/redact.txt (lines "<literal> <placeholder>", e.g.
# the bucket and the account id) and <evidence-root>/hosts.txt (one address of
# the benchmark hosts per line).
REDACT = [
    (re.compile(r"\bi-0[0-9a-f]{8,17}\b"), "<instance>"),
    (re.compile(r"\bvol-?0[0-9a-f]{8,17}\b"), "<volume>"),
    (re.compile(r"\bsb-qwmain-(local|s3)-\d{8}T\d{6}Z(-host|-stop)?\b"), r"<run-\1>"),
    (re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"), "<access-key>"),
]


def add_hosts(root):
    r = os.path.join(root, "redact.txt")
    for line in (open(r).read().splitlines() if os.path.exists(r) else []):
        if line.strip():
            lit, rep = line.split()
            REDACT.insert(0, (re.compile(r"\b" + re.escape(lit) + r"\b"), rep))
    f = os.path.join(root, "hosts.txt")
    for ip in (open(f).read().split() if os.path.exists(f) else []):
        REDACT.append((re.compile(r"(?<![\d.])" + re.escape(ip) + r"(?![\d.])"), "<host-ip>"))
        dashed = "ip-" + ip.replace(".", "-")
        REDACT.append((re.compile(re.escape(dashed)), "<host>"))

SYSTEM = {"local": "Quickwit (main-local)", "s3": "Quickwit (main-s3)"}


def redact(text):
    for rx, rep in REDACT:
        text = rx.sub(rep, text)
    return text


def copy_redacted(src, dst, gz=False):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    data = redact(open(src, encoding="utf-8", errors="replace").read())
    if gz:
        # mtime=0: the archive changes only when its content does.
        with open(dst + ".gz", "wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as f:
            f.write(data.encode("utf-8"))
    else:
        open(dst, "w", encoding="utf-8").write(data)


def median_rows(rounds):
    out = []
    for q in range(len(rounds[0])):
        row = []
        for t in range(len(rounds[0][q])):
            v = [r[q][t] for r in rounds]
            row.append(None if any(x is None for x in v) else round(statistics.median(v), 6))
        out.append(row)
    return out


def publish(root, box, ds):
    ev = os.path.join(root, box, ds)
    rfiles = sorted(glob.glob(f"{ev}/r[0-9]/quickwit_main-{box}-r[0-9]_{ds}.json"))
    if not rfiles:
        print(f"skip {box}/{ds}: no rounds", file=sys.stderr); return
    rounds = [json.load(open(f)) for f in rfiles]
    base = rounds[0]
    starts = [open(os.path.join(os.path.dirname(f), "query-window-start.txt")).read().strip() for f in rfiles]
    ends = [open(os.path.join(os.path.dirname(f), "query-window-end.txt")).read().strip() for f in rfiles]
    res = {k: v for k, v in base.items() if k not in ("result", "cpu")}
    res["system"] = SYSTEM[box]
    res["comment"] = (f"Per-query, per-try median of {len(rounds)} rounds ({starts[0]} to {ends[-1]} UTC); "
                      f"rounds in runs/main-20261115/{box}/{ds}/. Quickwit main 961c871 "
                      f"(quickwit/quickwit:edge@sha256:34b9552e...), m8g.4xlarge, "
                      + ("index on a 3,000 GiB gp3 volume (20k IOPS, 625 MiB/s)." if box == "local"
                         else "index on S3 (same region), WAL and split cache on a 3,000 GiB gp3 volume."))
    res["result"] = median_rows([r["result"] for r in rounds])
    if all("cpu" in r for r in rounds):
        res["cpu"] = median_rows([r["cpu"] for r in rounds])
    json.dump(res, open(f"{QW}/results/quickwit_main-{box}_{ds}.json", "w"), indent=2)
    lr = json.load(open(glob.glob(f"{ev}/load-records/{ds}.main-961c871-{box}.json")[0]))
    lr["loaded_by"] = "empty query file (load only); queries run in separate rounds"
    json.dump(lr, open(f"{QW}/results/load/{ds}.main-{box}.json", "w"), indent=2)
    out = os.path.join(HERE, box, ds)
    shutil.rmtree(out, ignore_errors=True)
    for f in rfiles:
        rd = os.path.dirname(f); rn = os.path.basename(rd)
        copy_redacted(f, f"{out}/{rn}/{os.path.basename(f)}")
        copy_redacted(f.replace(".json", ".results.log"), f"{out}/{rn}/{os.path.basename(f).replace('.json', '.results.log')}", gz=True)
        copy_redacted(f"{rd}/benchmark.log", f"{out}/{rn}/benchmark.log")
        for small in ("environment.txt", "queries-sha256.txt", "query-window-start.txt", "query-window-end.txt", "exit-code"):
            if os.path.exists(f"{rd}/{small}"):
                copy_redacted(f"{rd}/{small}", f"{out}/{rn}/{small}")
        if os.path.exists(f"{rd}/storage-requests.jsonl"):
            copy_redacted(f"{rd}/storage-requests.jsonl", f"{out}/{rn}/storage-requests.jsonl", gz=True)
    for f in sorted(glob.glob(f"{ev}/check-recent-*.txt")) + [f"{ev}/{n}" for n in (
            "corpus.json", "load-environment.txt", "load-benchmark.log", "storage-units.json",
            "df-before-load.txt", "df-after-load.txt")]:
        if os.path.exists(f):
            copy_redacted(f, f"{out}/{os.path.basename(f)}")
    for n in ("load.samples", "splits.json"):
        if os.path.exists(f"{ev}/{n}") and os.path.getsize(f"{ev}/{n}") > 0:
            copy_redacted(f"{ev}/{n}", f"{out}/{n}", gz=True)
    print(f"published {box}/{ds}: {len(rounds)} rounds")


if __name__ == "__main__":
    root = sys.argv[1]
    add_hosts(root)
    dss = sys.argv[2:] or ["otel_logs_100m", "otel_logs_1b", "otel_logs_10b"]
    for box in ("local", "s3"):
        for ds in dss:
            publish(root, box, ds)
