#!/usr/bin/env python3
# Parquet -> Quickwit ingest through the native ingest endpoint
# (/api/v1/<index>/ingest), not /api/v1/_elastic/_bulk (see README, Load).
#
# The native endpoint takes bare NDJSON -- one document per line, no action
# line -- and commits on the index's commit_timeout_secs. Do not add
# ?commit=wait_for: that forces a commit per request and collapses throughput.
"""High-throughput Parquet -> Quickwit ingest (native /ingest endpoint)."""

import argparse
import mmap
import os
import queue
import random
import threading
import time
from multiprocessing import Pool, Value

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
            # Epoch MILLIseconds, matching the index config's fast_precision:
            # milliseconds (enough for log search; documents sharing a
            # millisecond keep index order). unix_timestamp input infers the
            # unit from magnitude (1.7e12 -> ms).
            cols[out] = pc.divide(col.cast(pa.int64()), 1_000_000).to_pylist()
        elif pa.types.is_map(t):
            cols[out] = [dict(v) if v is not None else None for v in col.to_pylist()]
        else:
            cols[out] = col.to_pylist()
    names = list(cols.keys())
    parts = []
    for row in zip(*cols.values()):
        parts.append(orjson.dumps(dict(zip(names, row)), option=orjson.OPT_NON_STR_KEYS) + b"\n")
    return b"".join(parts), batch.num_rows


# Retry on 429/503 with exponential backoff, capped at SEARCHBENCH_LOAD_BACKOFF_MAX
# seconds (default 30, the published runs). Quickwit answers 503 while it opens
# shards for a growing load; with a 30 s cap all the senders end up waiting
# together and the server idles. Jitter keeps them from retrying in lockstep.
_BACKOFF_MAX = float(os.environ.get("SEARCHBENCH_LOAD_BACKOFF_MAX", 30.0))
_LOGGED_REJECTIONS = [0]


def bulk_post(session: requests.Session, body: bytes, n: int) -> tuple[int, int]:
    backoff, retries = min(1.0, _BACKOFF_MAX), 0
    url = f"{QW_URL}/api/v1/{QW_INDEX}/ingest"
    while True:
        try:
            resp = session.post(url, data=body, headers=_HEADERS, timeout=600)
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout) as e:
            retries += 1
            print(f"  connect error ({type(e).__name__}); retry {retries}", flush=True)
            time.sleep(min(backoff, _BACKOFF_MAX)); backoff *= 2
            session = requests.Session()
            continue
        if resp.status_code in (429, 503):
            retries += 1
            if _LOGGED_REJECTIONS[0] < 3:
                _LOGGED_REJECTIONS[0] += 1
                print(f"  HTTP {resp.status_code}: {resp.text[:300]!r}", flush=True)
            time.sleep(min(backoff, _BACKOFF_MAX) * random.uniform(0.5, 1.0)); backoff *= 2
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


def _prebuilt_paths(out_dir: str, rg_idx: int) -> tuple[str, str]:
    base = os.path.join(out_dir, f"rg_{rg_idx:05d}")
    return base + ".ndjson", base + ".idx"


def convert_row_group(args: tuple) -> int:
    """Write the exact request bodies ingest_* would send for one row group
    (batch_to_ndjson, same batch size) plus an index of (offset, length, docs)."""
    file_path, rg_idx, batch_size, out_dir = args
    pf = pq.ParquetFile(file_path)
    data_path, idx_path = _prebuilt_paths(out_dir, rg_idx)
    entries, off, n_docs = [], 0, 0
    with open(data_path + ".tmp", "wb") as f:
        for batch in pf.read_row_group(rg_idx).to_batches(max_chunksize=batch_size):
            body, n = batch_to_ndjson(batch)
            f.write(body); entries.append((off, len(body), n)); off += len(body); n_docs += n
    with open(idx_path + ".tmp", "w") as f:
        f.write("\n".join(f"{o} {l} {n}" for o, l, n in entries) + "\n")
    os.replace(data_path + ".tmp", data_path); os.replace(idx_path + ".tmp", idx_path)
    return n_docs


def convert_file(file_path: str, batch_size: int, num_processes: int, out_dir: str) -> int:
    os.makedirs(out_dir, exist_ok=True)
    total_rg = pq.ParquetFile(file_path).metadata.num_row_groups
    t0 = time.monotonic()
    with Pool(processes=num_processes) as pool:
        n = sum(pool.map(convert_row_group, [(file_path, i, batch_size, out_dir) for i in range(total_rg)]))
    el = time.monotonic() - t0
    print(f"{file_path}: converted {n:,} docs / {total_rg} row groups to {out_dir} in {el:.1f}s "
          f"({n/el:,.0f} docs/s)", flush=True)
    return n


def _prebuilt_bodies(out_dir: str, rg_idx: int):
    """Yield (body, n_docs) for one row group from the files convert_row_group wrote."""
    data_path, idx_path = _prebuilt_paths(out_dir, rg_idx)
    with open(idx_path) as f:
        entries = [tuple(int(x) for x in line.split()) for line in f if line.strip()]
    with open(data_path, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        for off, length, n in entries:
            yield bytes(mm[off:off + length]), n


_NEXT_RG = None


def _init_queue(counter):
    global _NEXT_RG
    _NEXT_RG = counter


def ingest_from_queue(args: tuple) -> dict:
    """Lease the next row group from a counter shared by all processes, until
    none is left. The processes stay on adjacent row groups, so documents reach
    Quickwit in near time order (the corpus is sorted by Timestamp)."""
    file_path, total_rg, batch_size, workers_n, prebuilt_dir = args
    pf = None if prebuilt_dir else pq.ParquetFile(file_path)
    q: queue.Queue = queue.Queue(maxsize=workers_n * 4)
    stats = {"indexed": 0, "retries": 0, "row_groups": 0}
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
    while True:
        with _NEXT_RG.get_lock():
            rg_idx = _NEXT_RG.value
            _NEXT_RG.value += 1
        if rg_idx >= total_rg:
            break
        stats["row_groups"] += 1
        if prebuilt_dir:
            for item in _prebuilt_bodies(prebuilt_dir, rg_idx):
                q.put(item)
        else:
            for batch in pf.read_row_group(rg_idx).to_batches(max_chunksize=batch_size):
                q.put(batch_to_ndjson(batch))
    for _ in ws:
        q.put(None)
    for w in ws:
        w.join()
    return stats


def process_file(file_path: str, batch_size: int, num_processes: int, workers_n: int,
                 order: str = "slices", prebuilt_dir: str | None = None) -> int:
    pf = pq.ParquetFile(file_path)
    total_rows, total_rg = pf.metadata.num_rows, pf.metadata.num_row_groups
    print(f"{file_path}: {total_rows:,} rows / {total_rg} row groups -> "
          f"{num_processes} processes x {workers_n} bulk workers, order={order}"
          f"{', prebuilt bodies from ' + prebuilt_dir if prebuilt_dir else ''}", flush=True)
    if prebuilt_dir and order != "queue":
        raise SystemExit("--prebuilt-dir requires --order queue")
    t0 = time.monotonic()
    if order == "queue":
        counter = Value("q", 0)
        with Pool(processes=num_processes, initializer=_init_queue, initargs=(counter,)) as pool:
            results = pool.map(ingest_from_queue, [(file_path, total_rg, batch_size, workers_n, prebuilt_dir)] * num_processes)
    else:
        rg_per = (total_rg + num_processes - 1) // num_processes
        segs = [(file_path, i * rg_per, min((i + 1) * rg_per, total_rg), batch_size, workers_n)
                for i in range(num_processes) if i * rg_per < total_rg]
        with Pool(processes=len(segs)) as pool:
            results = pool.map(ingest_segment, segs)
    el = time.monotonic() - t0
    total = sum(r["indexed"] for r in results)
    retries = sum(r.get("retries", 0) for r in results)
    print(f"File done: {total:,} docs in {el:.1f}s  ({total/el:,.0f} docs/s), {retries:,} retried requests", flush=True)
    return total


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--files", type=int, required=True)
    p.add_argument("--start-file", type=int, default=0)
    # 16 processes indexed all 100M documents at ~134k docs/s on the native endpoint.
    p.add_argument("--processes", type=int,
                   default=int(os.environ.get("SEARCHBENCH_LOAD_PROCESSES", 16)))
    # Concurrent senders per reader process. --processes 1 --bulk-workers N reads
    # the file in order and keeps N requests in flight: documents reach Quickwit
    # in near time order (out of order by at most ~N batches), so splits stay
    # narrow in time. --processes N sends N file slices in parallel instead, and
    # every split then mixes N time ranges.
    p.add_argument("--bulk-workers", type=int,
                   default=int(os.environ.get("SEARCHBENCH_LOAD_BULK_WORKERS", 1)))
    # Quickwit rejects large bulk bodies with HTTP 413; its limit is not
    # configurable through the ES layer. 2000 rows of this corpus is ~2.5MB
    # and is accepted; 20000 was not.
    # slices: process i sends a contiguous 1/N of the file (the published runs);
    # every split then mixes N time ranges. queue: the processes lease the next
    # row group from a shared counter, so they stay on adjacent row groups and
    # splits stay narrow in time, at the same throughput.
    p.add_argument("--order", choices=["slices", "queue"],
                   default=os.environ.get("SEARCHBENCH_LOAD_ORDER", "slices"))
    p.add_argument("--batch-size", type=int, default=2000)
    p.add_argument("--local-dir", default="/tmp")
    # Client-cost isolation (tests): --convert-to DIR writes, once, the exact
    # request bodies a load would send (per row group: <rg>.ndjson + <rg>.idx)
    # and exits; --prebuilt-dir DIR (with --order queue) sends those bytes
    # instead of converting Parquet rows in Python, so the load measures the
    # ingest API rather than this client's ~20k docs/s per process.
    p.add_argument("--convert-to", default=os.environ.get("SEARCHBENCH_LOAD_CONVERT_TO"))
    p.add_argument("--prebuilt-dir", default=os.environ.get("SEARCHBENCH_LOAD_PREBUILT_DIR"))
    args = p.parse_args()
    t0 = time.monotonic()
    grand = 0
    for fn in range(args.start_file, args.start_file + args.files):
        part = os.path.join(args.local_dir, f"part_{fn:03d}.parquet")
        sub = lambda d: os.path.join(d, f"part_{fn:03d}")
        if args.convert_to:
            grand += convert_file(part, args.batch_size, args.processes, sub(args.convert_to))
            continue
        grand += process_file(part, args.batch_size, args.processes, args.bulk_workers, args.order,
                              sub(args.prebuilt_dir) if args.prebuilt_dir else None)
    el = time.monotonic() - t0
    print(f"\nGrand total: {grand:,} docs in {el:.1f}s  ({grand/el:,.0f} docs/s)")


if __name__ == "__main__":
    main()
