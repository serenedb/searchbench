#!/usr/bin/env python3
# Derived from this repo's opensearch/ingest.py (itself from ClickHouse/TextBench
# elasticsearch/ingest.py, Apache-2.0), retargeted at VictoriaLogs:
#   * posts to /insert/elasticsearch/_bulk -- VictoriaLogs implements the ES bulk
#     wire format, so the same per-row-group parallel pipeline is reused verbatim
#   * action line is {"create":{}} (what VictoriaLogs documents) rather than
#     {"index":{}}, and the response's per-item key is "create"
#   * Timestamp -> epoch NANOSECONDS. VictoriaLogs infers the unit from the
#     magnitude, and ns is the corpus's native resolution, so unlike the ES
#     adapter (which narrows to epoch_millis) nothing is thrown away.
#   * the field mapping (_time/_msg/_stream) is a URL parameter, not a mapping
#     document -- VictoriaLogs is schemaless, there is no CREATE INDEX step.
"""High-throughput Parquet -> VictoriaLogs ingest."""

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

VL_URL = os.environ.get("VL_URL", "http://localhost:9428")

# Field roles, passed to the insert endpoint. ServiceName is the stream field:
# VictoriaLogs partitions storage by log stream, and stream fields must be
# LOW cardinality (it is ~10 services here). TraceId/SpanId are high-cardinality
# and are deliberately left as ordinary fields -- making them stream fields would
# create one stream per trace and wreck the storage layout.
TIME_FIELD = "Timestamp"
# _msg is fed a LOWERCASED copy of Body, not Body itself.
#
# LogsQL word matching is case-sensitive and VictoriaLogs has no analyzer stage,
# so the only case-insensitive filter is i(...) -- which cannot use the per-block
# bloom filters and degrades every term query to a scan. Measured at 100M:
# i(payment) 4.108s vs payment 0.098s for the IDENTICAL 200,335 rows (42x).
#
# Every other engine here lowercases at index time in its analyzer. Doing that
# lowercasing at ingest is the faithful equivalent, not a shortcut: a
# case-sensitive match of a lowercased term against lowercased text is exactly
# ES `match` semantics, and it is bloom-filterable.
#
# The original Body is still shipped as its own field, so the corpus is stored
# with the same information every other engine keeps (ES retains original text
# in _source while indexing lowercased tokens). That costs storage; it is the
# honest trade.
MSG_FIELD = "BodyLower"
STREAM_FIELDS = "ServiceName"

_INSERT_PATH = (
    f"/insert/elasticsearch/_bulk"
    f"?_time_field={TIME_FIELD}&_msg_field={MSG_FIELD}&_stream_fields={STREAM_FIELDS}"
)

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


def _canonical_field(name: str):
    if name in _FIELD_RENAME:
        return _FIELD_RENAME[name]
    if name in _FIELD_TARGETS:
        return name
    return None


def _ts_epoch_ns(col):
    """Vectorized timestamp -> epoch-nanoseconds int64, any unit; nulls preserved."""
    i64 = col.cast(pa.int64())
    unit = col.type.unit
    mult = {"ns": 1, "us": 1_000, "ms": 1_000_000, "s": 1_000_000_000}[unit]
    if mult == 1:
        return i64
    return pc.multiply(i64, mult)


def batch_to_ndjson(batch: pa.RecordBatch) -> bytes:
    """RecordBatch -> bulk NDJSON (action + doc per row)."""
    cols = {}
    for name in batch.schema.names:
        out = _canonical_field(name)
        if out is None:
            continue
        col = batch.column(name)
        t = col.type
        if pa.types.is_timestamp(t):
            cols[out] = _ts_epoch_ns(col).to_pylist()
        elif pa.types.is_map(t):
            # VictoriaLogs flattens nested objects into dot-separated field names
            # (ResourceAttributes.host.name), so the maps stay queryable.
            cols[out] = [dict(v) if v is not None else None for v in col.to_pylist()]
        else:
            cols[out] = col.to_pylist()

    # Lowercased search copy -> _msg (see MSG_FIELD). Vectorized in Arrow rather
    # than per-row .lower(), because ingest is already client-CPU-bound.
    if "Body" in cols:
        body_col = batch.column(batch.schema.get_field_index(
            "body" if "body" in batch.schema.names else "Body"))
        cols["BodyLower"] = pc.utf8_lower(body_col).to_pylist()

    names = list(cols.keys())
    values = list(cols.values())
    action = b'{"create":{}}\n'
    parts = []
    for row in zip(*values):
        parts.append(action)
        parts.append(orjson.dumps(dict(zip(names, row)), option=orjson.OPT_NON_STR_KEYS) + b"\n")
    return b"".join(parts)


def bulk_post(session: requests.Session, body: bytes, n_docs: int) -> tuple[int, int]:
    backoff, retries = 1.0, 0
    while True:
        try:
            resp = session.post(
                f"{VL_URL}{_INSERT_PATH}",
                data=body,
                headers={"Content-Type": "application/x-ndjson"},
                timeout=300,
            )
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout) as e:
            retries += 1
            print(f"  connect error ({type(e).__name__}); retry {retries}", flush=True)
            time.sleep(min(backoff, 30.0)); backoff *= 2
            session = requests.Session()
            continue
        if resp.status_code == 429:
            retries += 1
            time.sleep(min(backoff, 30.0)); backoff *= 2
            continue
        resp.raise_for_status()
        errors = 0
        # VictoriaLogs answers with the ES-shaped envelope; be tolerant if a
        # future version returns an empty body for a fully successful bulk.
        try:
            result = resp.json()
        except Exception:
            return n_docs, retries
        for it in result.get("items", []):
            entry = it.get("create") or it.get("index") or {}
            if entry.get("error"):
                errors += 1
        if errors:
            print(f"  WARNING: {errors}/{n_docs} indexing errors", flush=True)
        return n_docs - errors, retries


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

    for rg_idx in range(rg_start, rg_end):
        for batch in pf.read_row_group(rg_idx).to_batches(max_chunksize=batch_size):
            ndjson_q.put((batch_to_ndjson(batch), batch.num_rows))

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
                   default=int(os.environ.get("SEARCHBENCH_LOAD_PROCESSES", max(1, (os.cpu_count() or 4) // 2))),
                   help="Parallel converter processes per file (default: cpu/2)")
    p.add_argument("--bulk-workers", type=int, default=4, help="Bulk HTTP threads per process")
    p.add_argument("--batch-size", type=int, default=50000)
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
