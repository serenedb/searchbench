#!/usr/bin/env python3
# Parquet -> Quickwit ingest through the ELASTICSEARCH-COMPATIBLE bulk API.
#
# Quickwit exposes /api/v1/_elastic/_bulk, so this is the repo's ES ingest
# pipeline pointed at a different URL rather than a new transport. Only the
# `create` action is supported (delete/update are ignored), which is what the ES
# adapters already emit... except they emit {"index":{}}, so the action line is
# switched here.
"""High-throughput Parquet -> Quickwit ingest (ES bulk API)."""

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

QW_URL = os.environ.get("QW_URL", "http://localhost:7280")
QW_INDEX = os.environ.get("QW_INDEX", "otel_logs")

_FIELD_RENAME = {
    "timestamp": "Timestamp", "traceid": "TraceId", "spanid": "SpanId",
    "traceflags": "TraceFlags", "severitytext": "SeverityText",
    "severitynumber": "SeverityNumber", "servicename": "ServiceName",
    "body": "Body", "resourceschemaurl": "ResourceSchemaUrl",
    "resourceattributes": "ResourceAttributes", "scopeschemaurl": "ScopeSchemaUrl",
    "scopename": "ScopeName", "scopeversion": "ScopeVersion",
    "scopeattributes": "ScopeAttributes", "logattributes": "LogAttributes",
}
_FIELD_TARGETS = set(_FIELD_RENAME.values())
_HEADERS = {"Content-Type": "application/x-ndjson"}


def _canonical_field(name: str):
    if name in _FIELD_RENAME:
        return _FIELD_RENAME[name]
    if name in _FIELD_TARGETS:
        return name
    return None


def batch_to_ndjson(batch: pa.RecordBatch) -> tuple[bytes, int]:
    cols = {}
    for name in batch.schema.names:
        out = _canonical_field(name)
        if out is None:
            continue
        col = batch.column(name)
        t = col.type
        if pa.types.is_timestamp(t):
            # epoch millis: the index config declares unix_timestamp input.
            cols[out] = pc.divide(col.cast(pa.int64()), 1_000_000).to_pylist()
        elif pa.types.is_map(t):
            cols[out] = [dict(v) if v is not None else None for v in col.to_pylist()]
        else:
            cols[out] = col.to_pylist()
    names = list(cols.keys())
    action = b'{"create":{}}\n'
    parts = []
    for row in zip(*cols.values()):
        parts.append(action)
        parts.append(orjson.dumps(dict(zip(names, row)), option=orjson.OPT_NON_STR_KEYS) + b"\n")
    return b"".join(parts), batch.num_rows


def bulk_post(session: requests.Session, body: bytes, n: int) -> tuple[int, int]:
    backoff, retries = 1.0, 0
    url = f"{QW_URL}/api/v1/_elastic/{QW_INDEX}/_bulk"
    while True:
        try:
            resp = session.post(url, data=body, headers=_HEADERS, timeout=600)
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
        return n, retries


def ingest_segment(args: tuple) -> dict:
    file_path, rg_start, rg_end, batch_size, workers_n = args
    tag = f"[rg {rg_start:04d}-{rg_end:04d}]"
    pf = pq.ParquetFile(file_path)
    q: queue.Queue = queue.Queue(maxsize=workers_n * 4)
    stats = {"indexed": 0, "retries": 0}
    lock = threading.Lock()

    def worker():
        session = requests.Session()
        while True:
            item = q.get()
            if item is None:
                q.task_done(); break
            body, n = item
            ok, r = bulk_post(session, body, n)
            with lock:
                stats["indexed"] += ok; stats["retries"] += r
            q.task_done()

    ws = [threading.Thread(target=worker, daemon=True) for _ in range(workers_n)]
    for w in ws:
        w.start()
    for rg_idx in range(rg_start, rg_end):
        for batch in pf.read_row_group(rg_idx).to_batches(max_chunksize=batch_size):
            q.put(batch_to_ndjson(batch))
    for _ in ws:
        q.put(None)
    for w in ws:
        w.join()
    print(f"{tag} done — {stats['indexed']:,} docs", flush=True)
    return stats


def process_file(file_path: str, batch_size: int, num_processes: int, workers_n: int) -> int:
    pf = pq.ParquetFile(file_path)
    total_rows, total_rg = pf.metadata.num_rows, pf.metadata.num_row_groups
    print(f"{file_path}: {total_rows:,} rows / {total_rg} row groups -> "
          f"{num_processes} processes x {workers_n} bulk workers", flush=True)
    rg_per = (total_rg + num_processes - 1) // num_processes
    segs = [(file_path, i * rg_per, min((i + 1) * rg_per, total_rg), batch_size, workers_n)
            for i in range(num_processes) if i * rg_per < total_rg]
    t0 = time.monotonic()
    with Pool(processes=len(segs)) as pool:
        results = pool.map(ingest_segment, segs)
    el = time.monotonic() - t0
    total = sum(r["indexed"] for r in results)
    print(f"File done: {total:,} docs in {el:.1f}s  ({total/el:,.0f} docs/s)", flush=True)
    return total


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--files", type=int, required=True)
    p.add_argument("--start-file", type=int, default=0)
    # SERIAL BY DEFAULT. Quickwit's ingest v2 pipeline silently drops records
    # under concurrent bulk load: measured on otel_logs_1m, 4 concurrent
    # requests indexed 858,000 of 1,000,000 (-14.2%) and 16 indexed 896,000
    # (-10.4%), both permanent (the count was still 858,000 after 160s). Every
    # request returned HTTP 200 with errors:false and no per-item error; the
    # only signal is "failed to fetch records from ingester" in the server log.
    # One connection is lossless and still does ~15k docs/s.
    p.add_argument("--processes", type=int,
                   default=int(os.environ.get("SEARCHBENCH_LOAD_PROCESSES", 1)))
    # Quickwit drops records under concurrent bulk load (silently, HTTP 200).
    # 16 concurrent requests lost 10.4%; keep the total low.
    p.add_argument("--bulk-workers", type=int, default=1)
    # Quickwit rejects large bulk bodies with HTTP 413; its limit is not
    # configurable through the ES layer. 2000 rows of this corpus is ~2.5MB
    # and is accepted; 20000 was not.
    p.add_argument("--batch-size", type=int, default=2000)
    p.add_argument("--local-dir", default="/tmp")
    args = p.parse_args()
    t0 = time.monotonic()
    grand = 0
    for fn in range(args.start_file, args.start_file + args.files):
        grand += process_file(os.path.join(args.local_dir, f"part_{fn:03d}.parquet"),
                              args.batch_size, args.processes, args.bulk_workers)
    el = time.monotonic() - t0
    print(f"\nGrand total: {grand:,} docs in {el:.1f}s  ({grand/el:,.0f} docs/s)")


if __name__ == "__main__":
    main()
