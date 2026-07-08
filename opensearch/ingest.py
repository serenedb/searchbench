#!/usr/bin/env python3
# Derived from ClickHouse/TextBench@main elasticsearch/ingest.py (Apache-2.0), modified for SearchBench:
#   * Vectorized Timestamp -> epoch-millis via pyarrow compute (ES parses numeric as epoch_millis)
#   * TimestampTime (redundant ms twin) dropped to match SQL engines
# Parallelism: upstream per-row-group model — N processes each own a slice of row groups, M bulk-HTTP threads each.
"""High-throughput Parquet -> Elasticsearch ingest."""

import argparse
import os
import queue
import random
import threading
import time
from multiprocessing import Pool

import orjson
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq
import requests

ES_URL = os.environ.get("ES_URL", "http://localhost:9200")

# Map Parquet lowercase OTel names -> CamelCase; unmapped columns DROPPED.
# "timestamptime" (redundant ms twin) omitted so ES schema matches single-Timestamp SQL engines.
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


def _ts_epoch_ms(col):
    """Vectorized timestamp -> epoch-millis int64, any unit; nulls preserved."""
    i64 = col.cast(pa.int64())
    unit = col.type.unit
    if unit == "ns":
        return pc.divide(i64, 1_000_000)
    if unit == "us":
        return pc.divide(i64, 1_000)
    if unit == "ms":
        return i64
    return pc.multiply(i64, 1_000)  # s


def batch_to_ndjson(batch: pa.RecordBatch) -> bytes:
    """RecordBatch -> ES bulk NDJSON (action + doc per row)."""
    cols = {}
    for name in batch.schema.names:
        out = _canonical_field(name)
        if out is None:
            continue
        col = batch.column(name)
        t = col.type
        if pa.types.is_timestamp(t):
            cols[out] = _ts_epoch_ms(col).to_pylist()   # epoch_millis
        elif pa.types.is_map(t):
            cols[out] = [dict(v) if v is not None else None for v in col.to_pylist()]
        else:
            cols[out] = col.to_pylist()

    names = list(cols.keys())
    values = list(cols.values())
    action = b'{"index":{}}\n'
    parts = []
    for row in zip(*values):
        parts.append(action)
        parts.append(orjson.dumps(dict(zip(names, row)), option=orjson.OPT_NON_STR_KEYS) + b"\n")
    return b"".join(parts)


def bulk_post(session: requests.Session, index: str, body: bytes, n_docs: int) -> tuple[int, int]:
    backoff, retries = 1.0, 0
    while True:
        try:
            resp = session.post(
                f"{ES_URL}/{index}/_bulk",
                data=body,
                headers={"Content-Type": "application/x-ndjson"},
                timeout=120,
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
        result = resp.json()
        errors = sum(1 for it in result.get("items", []) if it.get("index", {}).get("error"))
        if errors:
            print(f"  WARNING: {errors}/{n_docs} indexing errors in {index}", flush=True)
        return n_docs - errors, retries


def ingest_segment(args: tuple) -> dict:
    """Worker: read row groups [rg_start, rg_end), post via `bulk_workers` HTTP threads."""
    file_path, indices, rg_start, rg_end, batch_size, bulk_workers = args
    tag = f"[rg {rg_start:04d}-{rg_end:04d}]"
    pf = pq.ParquetFile(file_path)

    ndjson_q: queue.Queue = queue.Queue(maxsize=bulk_workers * 4)
    stats = {"indexed": 0, "retries": 0}
    lock = threading.Lock()

    def bulk_worker():
        sessions = {idx: requests.Session() for idx in indices}
        while True:
            item = ndjson_q.get()
            if item is None:
                ndjson_q.task_done()
                break
            body, n_docs = item
            if len(indices) == 1:
                ok, retries = bulk_post(sessions[indices[0]], indices[0], body, n_docs)
            else:
                fan: dict = {}

                def post_to(idx):
                    fan[idx] = bulk_post(sessions[idx], idx, body, n_docs)

                ts = [threading.Thread(target=post_to, args=(idx,)) for idx in indices]
                for t in ts:
                    t.start()
                for t in ts:
                    t.join()
                ok = fan[indices[0]][0]
                retries = sum(r[1] for r in fan.values())
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


def process_file(file_path: str, indices: list, batch_size: int, num_processes: int, bulk_workers: int) -> int:
    pf = pq.ParquetFile(file_path)
    total_rows, total_rg = pf.metadata.num_rows, pf.metadata.num_row_groups
    print(f"{file_path}: {total_rows:,} rows / {total_rg} row groups -> "
          f"{num_processes} processes x {bulk_workers} bulk workers x {len(indices)} indices", flush=True)

    rg_per_proc = (total_rg + num_processes - 1) // num_processes
    segments = [
        (file_path, indices, i * rg_per_proc, min((i + 1) * rg_per_proc, total_rg), batch_size, bulk_workers)
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
    p.add_argument("--index", required=True, help="Index name(s), comma-separated")
    p.add_argument("--files", type=int, required=True)
    p.add_argument("--start-file", type=int, default=0)
    p.add_argument("--processes", type=int,
                   default=int(os.environ.get("SEARCHBENCH_LOAD_PROCESSES", max(1, (os.cpu_count() or 4) // 2))),
                   help="Parallel converter processes per file (default: cpu/2)")
    p.add_argument("--bulk-workers", type=int, default=4, help="Bulk HTTP threads per process")
    p.add_argument("--batch-size", type=int, default=50000)
    p.add_argument("--local-dir", default="/tmp")
    args = p.parse_args()

    indices = [i.strip() for i in args.index.split(",")]
    t0 = time.monotonic()
    grand = 0
    for fn in range(args.start_file, args.start_file + args.files):
        path = os.path.join(args.local_dir, f"part_{fn:03d}.parquet")
        grand += process_file(path, indices, args.batch_size, args.processes, args.bulk_workers)
    elapsed = time.monotonic() - t0
    print(f"\nGrand total: {grand:,} docs in {elapsed:.1f}s  ({grand/elapsed:,.0f} docs/s)")


if __name__ == "__main__":
    main()
