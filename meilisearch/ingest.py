#!/usr/bin/env python3
# Parquet -> Meilisearch ingest, same per-row-group parallel shape as this repo's
# elasticsearch/opensearch/victorialogs/ravendb/surrealdb ingest scripts.
#
# Transport is POST /indexes/<uid>/documents with application/x-ndjson.
#
# Meilisearch indexes ASYNCHRONOUSLY through a single task queue: the POST
# returns a taskUid immediately and the work happens later, serialised. So
# posting from many processes only fills the queue faster -- it does not
# parallelise indexing -- and the load is not finished until the queue drains.
# ./load waits for that; the wait is part of load_time, the same accounting as
# the ES adapters charging refresh+flush to the load.
"""High-throughput Parquet -> Meilisearch ingest."""

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

MEILI_URL = os.environ.get("MEILI_URL", "http://localhost:7700")
MEILI_KEY = os.environ.get("MEILI_KEY", "searchbench-meili-master-key-01")
INDEX = os.environ.get("MEILI_INDEX", "otel_logs")

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

# Meilisearch filters and sorts on numbers, not on date strings, so the time
# column is carried twice: TimestampMs (epoch millis -- filterable and sortable)
# and Timestamp (ISO string -- returned in projections, matching what the other
# adapters show). Storing only the string would make every range predicate a
# lexicographic comparison, which is the trap that broke the RavenDB run.
_TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

# ~40MB per request. A 50,000-row batch of this corpus is ~63MB and is accepted,
# but smaller batches keep the task queue moving and bound the retry cost.
MAX_BODY_BYTES = 40_000_000
_HEADERS = {"Authorization": f"Bearer {MEILI_KEY}", "Content-Type": "application/x-ndjson"}


def _canonical_field(name: str):
    if name in _FIELD_RENAME:
        return _FIELD_RENAME[name]
    if name in _FIELD_TARGETS:
        return name
    return None


def batch_to_ndjson(batch: pa.RecordBatch, id_base: int) -> tuple[bytes, int]:
    cols = {}
    for name in batch.schema.names:
        out = _canonical_field(name)
        if out is None:
            continue
        col = batch.column(name)
        t = col.type
        if pa.types.is_timestamp(t):
            us = col.cast(pa.timestamp("us"), safe=False)
            cols["Timestamp"] = pc.strftime(us, format=_TS_FORMAT).to_pylist()
            cols["TimestampMs"] = pc.divide(col.cast(pa.int64()), 1_000_000).to_pylist()
        elif pa.types.is_map(t):
            cols[out] = [dict(v) if v is not None else None for v in col.to_pylist()]
        else:
            cols[out] = col.to_pylist()
    names = list(cols.keys())
    parts = []
    for i, row in enumerate(zip(*cols.values())):
        d = dict(zip(names, row))
        # Explicit id: Meilisearch's primary-key inference FAILS on this corpus
        # ("found 3 fields ending with `id`: 'SpanId' and 'TraceId'") and the
        # whole batch is rejected with the task marked failed.
        d["id"] = id_base + i
        parts.append(orjson.dumps(d, option=orjson.OPT_NON_STR_KEYS))
    return b"\n".join(parts), len(parts)


def post_docs(session: requests.Session, body: bytes, n: int) -> tuple[int, int, int]:
    backoff, retries = 1.0, 0
    url = f"{MEILI_URL}/indexes/{INDEX}/documents?primaryKey=id"
    while True:
        try:
            resp = session.post(url, data=body, headers=_HEADERS, timeout=1200)
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
        return n, retries, resp.json().get("taskUid", -1)


def ingest_segment(args: tuple) -> dict:
    file_path, rg_start, rg_end, batch_size, workers_n = args
    tag = f"[rg {rg_start:04d}-{rg_end:04d}]"
    pf = pq.ParquetFile(file_path)
    q: queue.Queue = queue.Queue(maxsize=workers_n * 2)
    stats = {"sent": 0, "retries": 0, "last_task": -1}
    lock = threading.Lock()

    def worker():
        session = requests.Session()
        while True:
            item = q.get()
            if item is None:
                q.task_done(); break
            body, n = item
            sent, r, task = post_docs(session, body, n)
            with lock:
                stats["sent"] += sent; stats["retries"] += r
                stats["last_task"] = max(stats["last_task"], task)
            q.task_done()

    ws = [threading.Thread(target=worker, daemon=True) for _ in range(workers_n)]
    for w in ws:
        w.start()
    for rg_idx in range(rg_start, rg_end):
        for off, batch in enumerate(pf.read_row_group(rg_idx).to_batches(max_chunksize=batch_size)):
            # Ids must be globally unique; row-group index gives each worker a
            # disjoint range with no coordination. Row groups hold 614,400 rows,
            # comfortably inside the 10M stride.
            body, n = batch_to_ndjson(batch, rg_idx * 10_000_000 + off * batch_size)
            q.put((body, n))
    for _ in ws:
        q.put(None)
    for w in ws:
        w.join()
    print(f"{tag} queued — {stats['sent']:,} docs", flush=True)
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
    total = sum(r["sent"] for r in results)
    print(f"File queued: {total:,} docs in {el:.1f}s  ({total/el:,.0f} docs/s posted)", flush=True)
    return total


def max_task_uid() -> int:
    """Highest task uid right now -- the baseline for 'failures from this run'."""
    hdr = {"Authorization": f"Bearer {MEILI_KEY}"}
    r = requests.get(f"{MEILI_URL}/tasks?limit=1", headers=hdr, timeout=60).json()
    res = r.get("results") or []
    return res[0]["uid"] if res else -1


def wait_for_queue(baseline: int = -1, poll: int = 10) -> None:
    """Block until no enqueued/processing tasks remain; report failures loudly.

    Only failures from THIS run count. Checking every failed task ever recorded
    flags harmless unrelated ones -- notably ./load's own DELETE of an index that
    does not exist yet, which fails by design on a first run.
    """
    hdr = {"Authorization": f"Bearer {MEILI_KEY}"}
    t0 = time.monotonic()
    while True:
        r = requests.get(f"{MEILI_URL}/tasks?statuses=enqueued,processing&limit=1",
                         headers=hdr, timeout=60).json()
        pending = r.get("total", 0)
        if not pending:
            break
        print(f"  [queue] {pending:,} tasks pending after {time.monotonic()-t0:.0f}s", flush=True)
        time.sleep(poll)
    f = requests.get(f"{MEILI_URL}/tasks?statuses=failed&indexUids={INDEX}"
                     f"&types=documentAdditionOrUpdate,settingsUpdate,indexCreation&limit=20",
                     headers=hdr, timeout=60).json()
    mine = [t for t in f.get("results", []) if t.get("uid", -1) > baseline]
    if mine:
        print(f"  ERROR: {len(mine)} task(s) FAILED in this run", flush=True)
        for t in mine[:5]:
            print(f"    uid={t.get('uid')} {t.get('error', {}).get('message', '')[:200]}", flush=True)
        raise SystemExit(1)
    print(f"  [queue] drained after {time.monotonic()-t0:.0f}s", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--files", type=int, required=True)
    p.add_argument("--start-file", type=int, default=0)
    p.add_argument("--processes", type=int,
                   default=int(os.environ.get("SEARCHBENCH_LOAD_PROCESSES", max(1, (os.cpu_count() or 4) // 4))))
    p.add_argument("--workers", type=int, default=2)
    p.add_argument("--batch-size", type=int, default=20000)
    p.add_argument("--local-dir", default="/tmp")
    args = p.parse_args()
    t0 = time.monotonic()
    baseline = max_task_uid()
    grand = 0
    for fn in range(args.start_file, args.start_file + args.files):
        grand += process_file(os.path.join(args.local_dir, f"part_{fn:03d}.parquet"),
                              args.batch_size, args.processes, args.workers)
    print("waiting for the Meilisearch task queue to drain", flush=True)
    wait_for_queue(baseline)
    el = time.monotonic() - t0
    print(f"\nGrand total: {grand:,} docs in {el:.1f}s  ({grand/el:,.0f} docs/s end-to-end)")


if __name__ == "__main__":
    main()
