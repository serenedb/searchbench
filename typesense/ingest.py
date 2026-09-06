#!/usr/bin/env python3
# Parquet -> Typesense ingest.
#
# Typesense imports SYNCHRONOUSLY: the HTTP call returns once the documents are
# indexed, so wall-clock around the import is the ingest time. There is no task
# queue to drain (unlike Meilisearch) and no async index build to wait for
# (unlike RavenDB).
#
# Client parallelism helps only a little and saturates fast -- measured on this
# box: 1 client 9,205 docs/s, 4 clients 12,235 (1.33x), 8 clients 12,022, and 16
# clients CRASHED the server with connection resets. Default is 4.
"""High-throughput Parquet -> Typesense ingest."""

import argparse
import json
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

TS_URL = os.environ.get("TS_URL", "http://localhost:8108")
TS_KEY = os.environ.get("TS_KEY", "searchbench")
COLLECTION = os.environ.get("TS_COLLECTION", "otel_logs")

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
_TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
_HEADERS = {"X-TYPESENSE-API-KEY": TS_KEY, "Content-Type": "text/plain"}


def _canonical_field(name: str):
    if name in _FIELD_RENAME:
        return _FIELD_RENAME[name]
    if name in _FIELD_TARGETS:
        return name
    return None


def batch_to_jsonl(batch: pa.RecordBatch, id_base: int) -> tuple[bytes, int]:
    cols = {}
    for name in batch.schema.names:
        out = _canonical_field(name)
        if out is None:
            continue
        col = batch.column(name)
        t = col.type
        if pa.types.is_timestamp(t):
            # Two representations: TimestampMs (int64) is what filter_by and
            # sort_by work on -- Typesense has no date type, so a range predicate
            # on an ISO string would be a lexicographic comparison. Timestamp is
            # kept as an unindexed string for projections.
            cols["Timestamp"] = pc.strftime(col.cast(pa.timestamp("us"), safe=False),
                                            format=_TS_FORMAT).to_pylist()
            cols["TimestampMs"] = pc.divide(col.cast(pa.int64()), 1_000_000).to_pylist()
        elif pa.types.is_map(t):
            # Typesense has no free-form map type; store as a JSON string so the
            # data is retained (parity with the other adapters), unindexed.
            cols[out] = [json.dumps(dict(v)) if v is not None else "{}"
                         for v in col.to_pylist()]
        else:
            cols[out] = col.to_pylist()
    names = list(cols.keys())
    parts = []
    for i, row in enumerate(zip(*cols.values())):
        d = dict(zip(names, row))
        d["id"] = str(id_base + i)
        parts.append(orjson.dumps(d, option=orjson.OPT_NON_STR_KEYS))
    return b"\n".join(parts), len(parts)


def post_docs(session: requests.Session, body: bytes, n: int) -> tuple[int, int]:
    backoff, retries = 1.0, 0
    url = f"{TS_URL}/collections/{COLLECTION}/documents/import?action=create"
    while True:
        try:
            resp = session.post(url, data=body, headers=_HEADERS, timeout=1800)
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
        # The import endpoint returns 200 with a per-document result line even
        # when individual documents fail; count them rather than assume success.
        bad = resp.text.count('"success":false')
        if bad:
            first = next((l for l in resp.text.split("\n") if '"success":false' in l), "")
            print(f"  WARNING: {bad}/{n} docs failed, first: {first[:180]}", flush=True)
        return n - bad, retries


def ingest_segment(args: tuple) -> dict:
    file_path, rg_start, rg_end, batch_size, workers_n = args
    tag = f"[rg {rg_start:04d}-{rg_end:04d}]"
    pf = pq.ParquetFile(file_path)
    q: queue.Queue = queue.Queue(maxsize=workers_n * 2)
    stats = {"indexed": 0, "retries": 0}
    lock = threading.Lock()

    def worker():
        session = requests.Session()
        while True:
            item = q.get()
            if item is None:
                q.task_done(); break
            body, n = item
            ok, r = post_docs(session, body, n)
            with lock:
                stats["indexed"] += ok; stats["retries"] += r
            q.task_done()

    ws = [threading.Thread(target=worker, daemon=True) for _ in range(workers_n)]
    for w in ws:
        w.start()
    for rg_idx in range(rg_start, rg_end):
        for off, batch in enumerate(pf.read_row_group(rg_idx).to_batches(max_chunksize=batch_size)):
            body, n = batch_to_jsonl(batch, rg_idx * 10_000_000 + off * batch_size)
            q.put((body, n))
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
          f"{num_processes} processes x {workers_n} HTTP workers", flush=True)
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
    # 4 total connections is the measured sweet spot; 16 crashed the server.
    p.add_argument("--processes", type=int,
                   default=int(os.environ.get("SEARCHBENCH_LOAD_PROCESSES", 2)))
    p.add_argument("--workers", type=int, default=2)
    p.add_argument("--batch-size", type=int, default=10000)
    p.add_argument("--local-dir", default="/tmp")
    args = p.parse_args()
    t0 = time.monotonic()
    grand = 0
    for fn in range(args.start_file, args.start_file + args.files):
        grand += process_file(os.path.join(args.local_dir, f"part_{fn:03d}.parquet"),
                              args.batch_size, args.processes, args.workers)
    el = time.monotonic() - t0
    print(f"\nGrand total: {grand:,} docs in {el:.1f}s  ({grand/el:,.0f} docs/s)")


if __name__ == "__main__":
    main()
