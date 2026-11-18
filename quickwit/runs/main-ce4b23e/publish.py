#!/usr/bin/env python3
"""Publish the Quickwit main ce4b23e run (2026-11-18) from the box's evidence.

    publish.py <evidence-root>

<evidence-root>/s3/<dir>/ is evidence/<dir>/ of the box, as written by production.sh:
  otel_logs_100m/       pass 1: 100M load + 3 rounds, Quickwit's default storage cache
                        (500 MB, legacy keys: fast_field_cache_capacity 0 + footer default)
  otel_logs_100m-sc0/   pass 2: 3 rounds on the same S3 index, storage_cache 0/0
  otel_logs_1b/         pass 2: 1B load
  otel_logs_1b-sc0/     pass 2: 3 rounds, storage_cache 0/0

Writes, relative to the repository's quickwit/ directory:

  results/quickwit_main-ce4b23e-s3_<dataset>.json           storage_cache 0/0 (100M, 1B)
  results/quickwit_main-ce4b23e-s3-cache500m_<dataset>.json default storage cache (100M)
  results/load/<dataset>.main-ce4b23e-s3.json               the load record of the index
  runs/main-ce4b23e/<dir>/                                  rounds (results + logs, gzipped),
                                                            check-recent output, load evidence

Each result is the per-query, per-try MEDIAN of the rounds. A query is null if it
was null in any round (only the 15 unsupported queries, null in every round).
Names to replace are read from <evidence-root>/redact.txt ("<literal> <placeholder>")
and <evidence-root>/hosts.txt (host addresses); they are not in this file.
"""
import glob, gzip, json, os, re, shutil, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
QW = os.path.abspath(os.path.join(HERE, "..", ".."))
REV = "ce4b23e"
REDACT = [
    (re.compile(r"\bi-0[0-9a-f]{8,17}\b"), "<instance>"),
    (re.compile(r"\bvol-?0[0-9a-f]{8,17}\b"), "<volume>"),
    (re.compile(r"\bsb-qwce4b-\d{8}T\d{6}Z(-host|-stop)?\b"), "<run>"),
    (re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"), "<access-key>"),
]
MACHINE = ("Quickwit main ce4b23e (2026-11-17), built on the box from Quickwit's Dockerfile; "
           "m8gd.4xlarge, index and metastore on S3 (same region), WAL on the instance-store NVMe; "
           "settings of the published Datadog BYOC run (runs/hippo-20261105).")
# (evidence dir of the rounds, evidence dir of the load, dataset, column, results slug, cache note)
COLUMNS = [
    ("otel_logs_100m-sc0", "otel_logs_100m", "otel_logs_100m", f"Quickwit (main-{REV}-s3)", f"main-{REV}-s3",
     "storage_cache 0/0: no storage cache, every try reads the splits from S3."),
    ("otel_logs_1b-sc0", "otel_logs_1b", "otel_logs_1b", f"Quickwit (main-{REV}-s3)", f"main-{REV}-s3",
     "storage_cache 0/0: no storage cache, every try reads the splits from S3."),
    ("otel_logs_100m", "otel_logs_100m", "otel_logs_100m", f"Quickwit (main-{REV}-s3-cache500m)", f"main-{REV}-s3-cache500m",
     "Default storage cache (500 MB from the legacy keys: fast_field_cache_capacity 0 + footer default), "
     "which on this build also holds split data: hot tries make no S3 reads."),
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
        REDACT.append((re.compile(re.escape("ip-" + ip.replace(".", "-"))), "<host>"))


def redact(text):
    for rx, rep in REDACT:
        text = rx.sub(rep, text)
    return text


def copy_redacted(src, dst, gz=False):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    data = redact(open(src, encoding="utf-8", errors="replace").read())
    if gz:
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


def copy_rounds(ev, out, rfiles):
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
    for f in sorted(glob.glob(f"{ev}/check-recent-*.txt")) + [f"{ev}/corpus.json"]:
        if os.path.exists(f):
            copy_redacted(f, f"{out}/{os.path.basename(f)}")


def copy_load(ev, out):
    for n in ("corpus.json", "load-environment.txt", "load-benchmark.log", "storage-units.json",
              "df-before-load.txt", "df-after-load.txt"):
        if os.path.exists(f"{ev}/{n}"):
            copy_redacted(f"{ev}/{n}", f"{out}/{n}")
    for n in ("load.samples", "metastore.json"):
        if os.path.exists(f"{ev}/{n}") and os.path.getsize(f"{ev}/{n}") > 0:
            copy_redacted(f"{ev}/{n}", f"{out}/{n}", gz=True)


def publish(root, rdir, ldir, ds, system, slug, cache):
    ev = os.path.join(root, "s3", rdir)
    rfiles = sorted(glob.glob(f"{ev}/r[0-9]/quickwit_main-{REV}-s3*-r[0-9]_{ds}.json"))
    assert len(rfiles) == 3, (rdir, rfiles)
    rounds = [json.load(open(f)) for f in rfiles]
    starts = [open(os.path.join(os.path.dirname(f), "query-window-start.txt")).read().strip() for f in rfiles]
    ends = [open(os.path.join(os.path.dirname(f), "query-window-end.txt")).read().strip() for f in rfiles]
    res = {k: v for k, v in rounds[0].items() if k not in ("result", "cpu")}
    res["system"] = system
    res["comment"] = (f"Per-query, per-try median of {len(rounds)} rounds ({starts[0]} to {ends[-1]} UTC); "
                      f"rounds in runs/main-{REV}/{rdir}/. {MACHINE} {cache}")
    res["result"] = median_rows([r["result"] for r in rounds])
    if all("cpu" in r for r in rounds):
        res["cpu"] = median_rows([r["cpu"] for r in rounds])
    json.dump(res, open(f"{QW}/results/quickwit_{slug}_{ds}.json", "w"), indent=2)
    lev = os.path.join(root, "s3", ldir)
    lr = json.load(open(f"{lev}/load-records/{ds}.main-{REV}-s3.json"))
    lr["loaded_by"] = "empty query file (load only); queries run in separate rounds"
    json.dump(lr, open(f"{QW}/results/load/{ds}.{slug}.json", "w"), indent=2)
    out = os.path.join(HERE, rdir)
    copy_rounds(ev, out, rfiles)
    if rdir == ldir:
        copy_load(lev, out)
    else:
        copy_load(lev, os.path.join(HERE, ldir))
    print(f"published {system} {ds}: {len(rounds)} rounds from {rdir}, load from {ldir}")


if __name__ == "__main__":
    root = sys.argv[1]
    add_hosts(root)
    for d in {c[0] for c in COLUMNS} | {c[1] for c in COLUMNS}:
        shutil.rmtree(os.path.join(HERE, d), ignore_errors=True)
    for c in COLUMNS:
        publish(root, *c)
