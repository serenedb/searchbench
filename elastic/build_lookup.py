#!/usr/bin/env python3
"""Build the `trace_lookup` dimension index for ES|QL LOOKUP JOIN.

One doc per TraceId (keyed by _id=TraceId) with boolean flags for the B-side
services used by the join queries (Q42-Q50): payment, frontend, cart. ES|QL
LOOKUP JOIN matches otel_logs rows to this index on TraceId (equality) and
enriches them with the flags; the join query then filters on a single-valued
boolean (e.g. has_payment == true) -- ES|QL can't compare a multivalued field
with ==, hence flags rather than a `services` array.

Built directly from the parquet corpus in ONE streamed pass (row group by row
group) rather than paginating a composite aggregation over the just-loaded ES
index. The old aggregation approach was the 100m load bottleneck: ~6250
sequential search+bulk round-trips over ~12.5M unique traces (~4.4h). Reading
two columns (TraceId, ServiceName) straight from parquet is I/O-bound and
finishes in minutes.

Correctness note: every join query filters `has_<B> == true`, so a trace that
touches NONE of the flag services can never survive the join -- we therefore
emit a doc ONLY for traces containing at least one flag service. A missing
TraceId in a lookup index yields null flags (== true is false), which is the
same drop. This shrinks the index from every trace to just the relevant ones.
"""
import os, sys, glob, json, requests
import pyarrow.parquet as pq
import pyarrow.compute as pc

ES  = os.environ.get("ES_URL", "http://127.0.0.1:9201")
DST = os.environ.get("LOOKUP_INDEX", "trace_lookup")
DATA_DIR = os.environ.get("SEARCHBENCH_DATA_DIR")
FLAG_SERVICES = ["payment", "frontend", "cart"]   # B-side join services

if not DATA_DIR or not os.path.isdir(DATA_DIR):
    sys.exit(f"SEARCHBENCH_DATA_DIR not set or not a dir: {DATA_DIR!r}")
files = sorted(glob.glob(os.path.join(DATA_DIR, "part_*.parquet")))
if not files:
    sys.exit(f"no part_*.parquet in {DATA_DIR}")

S = requests.Session()
S.delete(f"{ES}/{DST}")
props = {"TraceId": {"type": "keyword"}}
for s in FLAG_SERVICES:
    props[f"has_{s}"] = {"type": "boolean"}
r = S.put(f"{ES}/{DST}", json={
    "settings": {"index": {"mode": "lookup"}},
    "mappings": {"properties": props},
})
r.raise_for_status()

# tid -> bitmask over FLAG_SERVICES (bit i == service i present).
# Streamed per batch: only flag-service rows materialise to Python, so work
# scales with the relevant subset, not the whole corpus.
BIT = {s: 1 << i for i, s in enumerate(FLAG_SERVICES)}
flags = {}
for path in files:
    pf = pq.ParquetFile(path)
    for batch in pf.iter_batches(columns=["TraceId", "ServiceName"], batch_size=1_000_000):
        svc = batch.column("ServiceName")
        tid = batch.column("TraceId")
        for s, bit in BIT.items():
            sel = pc.equal(svc, s)
            if not pc.any(sel).as_py():
                continue
            for t in pc.unique(pc.filter(tid, sel)).to_pylist():
                if t:                       # skip empty
                    flags[t] = flags.get(t, 0) | bit

# Bulk-index one doc per relevant trace.
def flush(lines):
    if not lines:
        return
    br = S.post(f"{ES}/{DST}/_bulk", data="\n".join(lines) + "\n",
                headers={"Content-Type": "application/x-ndjson"})
    br.raise_for_status()
    if br.json().get("errors"):
        sys.exit(f"bulk errors building {DST}")

lines, total = [], 0
for tid, mask in flags.items():
    doc = {"TraceId": tid}
    for i, s in enumerate(FLAG_SERVICES):
        doc[f"has_{s}"] = bool(mask & (1 << i))
    lines.append(json.dumps({"index": {"_id": tid}}))
    lines.append(json.dumps(doc))
    total += 1
    if len(lines) >= 20000:
        flush(lines)
        lines = []
flush(lines)

S.post(f"{ES}/{DST}/_refresh")
print(f"{DST}: {total} traces", file=sys.stderr)
