#!/usr/bin/env python3
# Parquet -> SurrealDB ingest, same per-row-group parallel shape as this repo's
# elasticsearch/opensearch/victorialogs/ravendb ingest scripts.
#
# Transport is `INSERT INTO otel_logs <json-array>` posted to /sql. SurrealDB has
# no dedicated bulk endpoint, and its HTTP body limit is not configurable (no
# --max-body flag exists), so batches are capped by BYTES rather than row count:
# 10,000 real rows exceeded the limit and returned HTTP 413.
#
# Timestamps go in as plain ISO strings and are coerced to real `datetime` by
# `DEFINE FIELD Timestamp ON otel_logs VALUE <datetime>$value` (see ./load).
# That coercion is not optional: with Timestamp left a string, every range
# predicate silently compares text. Verified at setup time -- with the VALUE
# cast, type::is_datetime(Timestamp) is true and a 30-minute window selects 1 of
# 2 rows; `TYPE datetime` alone rejects the insert outright.
"""High-throughput Parquet -> SurrealDB ingest."""

import argparse
import base64
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

SURREAL_URL = os.environ.get("SURREAL_URL", "http://localhost:8000")
SURREAL_NS = os.environ.get("SURREAL_NS", "bench")
SURREAL_DB = os.environ.get("SURREAL_DB", "logs")
SURREAL_USER = os.environ.get("SURREAL_USER", "root")
SURREAL_PASS = os.environ.get("SURREAL_PASS", "root")
TABLE = "otel_logs"

# ~500KB of JSON per request. The server's limit sits between 0.3MB (accepted)
# and 1.5MB (413); this leaves headroom for the widest rows in the corpus.
MAX_BODY_BYTES = 500_000

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

# Arrow's %S already emits fractional seconds for sub-second types; %f is NOT
# implemented and would be passed through literally (that bug silently turned the
# RavenDB timestamps into unparseable strings). Cast to microseconds so the
# fractional part is 6 digits.
_TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
_TS_UNIT = "us"

_AUTH = "Basic " + base64.b64encode(f"{SURREAL_USER}:{SURREAL_PASS}".encode()).decode()
_HEADERS = {
    "Authorization": _AUTH,
    "Accept": "application/json",
    "Content-Type": "text/plain",
    "surreal-ns": SURREAL_NS,
    "surreal-db": SURREAL_DB,
}


def _canonical_field(name: str):
    if name in _FIELD_RENAME:
        return _FIELD_RENAME[name]
    if name in _FIELD_TARGETS:
        return name
    return None


def batch_to_docs(batch: pa.RecordBatch) -> list:
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
    return [dict(zip(names, row)) for row in zip(*cols.values())]


def post_sql(session: requests.Session, sql: bytes, n_docs: int) -> tuple[int, int]:
    backoff, retries = 1.0, 0
    url = f"{SURREAL_URL}/sql"
    while True:
        try:
            resp = session.post(url, data=sql, headers=_HEADERS, timeout=600)
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
        if resp.status_code == 413:
            raise RuntimeError("HTTP 413: batch too large; lower MAX_BODY_BYTES")
        resp.raise_for_status()
        # A 200 can still carry a per-statement error; surface it rather than
        # counting the rows as ingested.
        try:
            body = resp.json()
            if isinstance(body, list) and body and body[-1].get("status") != "OK":
                print(f"  WARNING: {str(body[-1].get('result'))[:120]}", flush=True)
                return 0, retries
        except Exception:
            pass
        return n_docs, retries


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
            sql, n = item
            ok, r = post_sql(session, sql, n)
            with lock:
                stats["indexed"] += ok; stats["retries"] += r
            q.task_done()

    ws = [threading.Thread(target=worker, daemon=True) for _ in range(workers_n)]
    for w in ws:
        w.start()

    prefix = f"INSERT INTO {TABLE} ".encode()
    for rg_idx in range(rg_start, rg_end):
        for batch in pf.read_row_group(rg_idx).to_batches(max_chunksize=batch_size):
            docs = batch_to_docs(batch)
            # Split by encoded size: the body limit is fixed and not raisable.
            chunk, size = [], 2
            for d in docs:
                enc = orjson.dumps(d)
                if chunk and size + len(enc) + 1 > MAX_BODY_BYTES:
                    q.put((prefix + orjson.dumps(chunk) + b";", len(chunk)))
                    chunk, size = [], 2
                chunk.append(d); size += len(enc) + 1
            if chunk:
                q.put((prefix + orjson.dumps(chunk) + b";", len(chunk)))

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
    p.add_argument("--processes", type=int,
                   default=int(os.environ.get("SEARCHBENCH_LOAD_PROCESSES", max(1, (os.cpu_count() or 4) // 2))))
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--batch-size", type=int, default=10000)
    p.add_argument("--local-dir", default="/tmp")
    args = p.parse_args()
    t0 = time.monotonic(); grand = 0
    for fn in range(args.start_file, args.start_file + args.files):
        grand += process_file(os.path.join(args.local_dir, f"part_{fn:03d}.parquet"),
                              args.batch_size, args.processes, args.workers)
    el = time.monotonic() - t0
    print(f"\nGrand total: {grand:,} docs in {el:.1f}s  ({grand/el:,.0f} docs/s)")


if __name__ == "__main__":
    main()
