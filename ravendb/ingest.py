#!/usr/bin/env python3
# Parquet -> RavenDB ingest, same per-row-group parallel shape as this repo's
# elasticsearch/opensearch/victorialogs ingest scripts.
#
# Transport is /databases/<db>/bulk_docs with a batch of PUT commands. RavenDB
# has no ES-style bulk NDJSON endpoint; bulk_docs is the documented HTTP batch
# write and takes a JSON envelope, so the body is one JSON object per request
# rather than newline-delimited docs.
"""High-throughput Parquet -> RavenDB ingest."""

import argparse
import os
import queue
import threading
import time
from multiprocessing import Pool

import orjson
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq
import requests

RAVEN_URL = os.environ.get("RAVEN_URL", "http://localhost:8080")
RAVEN_DB = os.environ.get("RAVEN_DB", "otel_logs")
COLLECTION = "Logs"

# Map Parquet lowercase OTel names -> CamelCase; unmapped columns DROPPED.
# "timestamptime" (redundant ms twin) omitted, matching every other adapter.
_FIELD_RENAME = {
    "timestamp": "Timestamp",
    "traceid": "TraceId",
    "spanid": "SpanId",
    "traceflags": "TraceFlags",
    "severitytext": "SeverityText",
    "severitynumber": "SeverityNumber",
    "servicename": "ServiceName",
    "body": "Body",
    "resourceschemaurl": "ResourceSchemaUrl",
    "resourceattributes": "ResourceAttributes",
    "scopeschemaurl": "ScopeSchemaUrl",
    "scopename": "ScopeName",
    "scopeversion": "ScopeVersion",
    "scopeattributes": "ScopeAttributes",
    "logattributes": "LogAttributes",
}
_FIELD_TARGETS = set(_FIELD_RENAME.values())

# RavenDB infers DateTime from an ISO-8601 string. Formatted vectorially in
# Arrow (pc.strftime) rather than per row -- at 100M rows a Python-level
# strftime is the whole budget.
#
# NO %f HERE. Arrow's strftime does not implement %f and passes it through
# LITERALLY, producing "2025-09-23T00:00:00.000000000.%fZ". RavenDB cannot parse
# that as a date, so it silently indexes the column as a lowercased STRING --
# every `Timestamp between ...` predicate then degenerates to a lexicographic
# comparison that matches essentially the whole corpus (measured: a 30-minute
# window returned 99,999,969 of 100,000,000 rows). Wrong answers, not just slow.
#
# Arrow's %S already emits the fractional part for sub-second types, so the cast
# to microseconds below fixes the precision and %S supplies the digits:
#   ns + "%...%SZ"  -> 2025-09-23T00:00:00.000000000Z   (9 digits, .NET wants <=7)
#   us + "%...%SZ"  -> 2025-09-23T00:00:00.000000Z      (parses, indexes as date)
# Verified end-to-end: indexed terms come back as 2025-09-23T00:10:00.0000000Z
# and a 30-minute window correctly selects 1 of 2 documents.
_TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
_TS_UNIT = "us"


def _canonical_field(name: str):
    if name in _FIELD_RENAME:
        return _FIELD_RENAME[name]
    if name in _FIELD_TARGETS:
        return name
    return None


def batch_to_commands(batch: pa.RecordBatch, id_prefix: str, start: int) -> bytes:
    """RecordBatch -> a bulk_docs request body."""
    cols = {}
    for name in batch.schema.names:
        out = _canonical_field(name)
        if out is None:
            continue
        col = batch.column(name)
        t = col.type
        if pa.types.is_timestamp(t):
            cols[out] = pc.strftime(col.cast(pa.timestamp(_TS_UNIT), safe=False),
                                    format=_TS_FORMAT).to_pylist()
        elif pa.types.is_map(t):
            cols[out] = [dict(v) if v is not None else None for v in col.to_pylist()]
        else:
            cols[out] = col.to_pylist()

    names = list(cols.keys())
    values = list(cols.values())
    meta = {"@collection": COLLECTION}
    cmds = []
    for i, row in enumerate(zip(*values)):
        doc = dict(zip(names, row))
        doc["@metadata"] = meta
        cmds.append({"Id": f"{id_prefix}{start + i}", "Type": "PUT", "Document": doc})
    return orjson.dumps({"Commands": cmds}, option=orjson.OPT_NON_STR_KEYS)


def bulk_post(session: requests.Session, body: bytes, n_docs: int) -> tuple[int, int]:
    backoff, retries = 1.0, 0
    url = f"{RAVEN_URL}/databases/{RAVEN_DB}/bulk_docs"
    while True:
        try:
            resp = session.post(url, data=body,
                                headers={"Content-Type": "application/json"},
                                timeout=600)
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout) as e:
            retries += 1
            print(f"  connect error ({type(e).__name__}); retry {retries}", flush=True)
            time.sleep(min(backoff, 30.0)); backoff *= 2
            session = requests.Session()
            continue
        if resp.status_code in (429, 503):
            retries += 1
            time.sleep(min(backoff, 30.0)); backoff *= 2
            continue
        resp.raise_for_status()
        return n_docs, retries


def ingest_segment(args: tuple) -> dict:
    """Worker: read row groups [rg_start, rg_end), post via `bulk_workers` HTTP threads."""
    file_path, rg_start, rg_end, batch_size, bulk_workers = args
    tag = f"[rg {rg_start:04d}-{rg_end:04d}]"
    pf = pq.ParquetFile(file_path)

    ndjson_q: queue.Queue = queue.Queue(maxsize=bulk_workers * 4)
    stats = {"indexed": 0, "retries": 0}
    lock = threading.Lock()

    def bulk_worker():
        session = requests.Session()
        while True:
            item = ndjson_q.get()
            if item is None:
                ndjson_q.task_done()
                break
            body, n_docs = item
            ok, retries = bulk_post(session, body, n_docs)
            with lock:
                stats["indexed"] += ok
                stats["retries"] += retries
            ndjson_q.task_done()

    workers = [threading.Thread(target=bulk_worker, daemon=True) for _ in range(bulk_workers)]
    for w in workers:
        w.start()

    seq = 0
    for rg_idx in range(rg_start, rg_end):
        for batch in pf.read_row_group(rg_idx).to_batches(max_chunksize=batch_size):
            # Ids must be unique across workers; row-group index makes them so
            # without any coordination.
            body = batch_to_commands(batch, f"logs/{rg_idx}-", seq)
            seq += batch.num_rows
            ndjson_q.put((body, batch.num_rows))

    for _ in workers:
        ndjson_q.put(None)
    for w in workers:
        w.join()

    print(f"{tag} done — {stats['indexed']:,} docs", flush=True)
    return stats


def process_file(file_path: str, batch_size: int, num_processes: int, bulk_workers: int) -> int:
    pf = pq.ParquetFile(file_path)
    total_rows, total_rg = pf.metadata.num_rows, pf.metadata.num_row_groups
    print(f"{file_path}: {total_rows:,} rows / {total_rg} row groups -> "
          f"{num_processes} processes x {bulk_workers} bulk workers", flush=True)

    rg_per_proc = (total_rg + num_processes - 1) // num_processes
    segments = [
        (file_path, i * rg_per_proc, min((i + 1) * rg_per_proc, total_rg), batch_size, bulk_workers)
        for i in range(num_processes)
        if i * rg_per_proc < total_rg
    ]

    t0 = time.monotonic()
    with Pool(processes=len(segments)) as pool:
        results = pool.map(ingest_segment, segments)
    elapsed = time.monotonic() - t0
    total = sum(r["indexed"] for r in results)
    print(f"File done: {total:,} docs in {elapsed:.1f}s  ({total/elapsed:,.0f} docs/s)", flush=True)
    return total


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--files", type=int, required=True)
    p.add_argument("--start-file", type=int, default=0)
    p.add_argument("--processes", type=int,
                   default=int(os.environ.get("SEARCHBENCH_LOAD_PROCESSES", max(1, (os.cpu_count() or 4) // 2))))
    p.add_argument("--bulk-workers", type=int, default=4)
    # Smaller than the ES adapters' 50000: bulk_docs builds one JSON envelope per
    # request, so an oversized batch is a single huge allocation on both ends.
    p.add_argument("--batch-size", type=int, default=10000)
    p.add_argument("--local-dir", default="/tmp")
    args = p.parse_args()

    t0 = time.monotonic()
    grand = 0
    for fn in range(args.start_file, args.start_file + args.files):
        path = os.path.join(args.local_dir, f"part_{fn:03d}.parquet")
        grand += process_file(path, args.batch_size, args.processes, args.bulk_workers)
    elapsed = time.monotonic() - t0
    print(f"\nGrand total: {grand:,} docs in {elapsed:.1f}s  ({grand/elapsed:,.0f} docs/s)")


if __name__ == "__main__":
    main()
