#!/usr/bin/env python3
"""
NDJSON (stdin) -> Manticore /bulk ingest, parallelized across HTTP worker threads.

serened's `COPY ... (FORMAT json)` streams NDJSON far faster than a single
synchronous HTTP poster can drain it, so the server indexes one batch at a time
and most CPU sits idle. Here a single reader thread (the pipe has one consumer)
slices stdin into BATCH-sized chunks and hands them to a bounded queue; INGEST_THREADS
worker threads each POST to /bulk concurrently, so Manticore indexes many batches in
parallel. Each worker validates its own lines (a line that won't parse = a truncated
/ partial record -> skipped with a warning, not a crash) and splices the raw JSON
straight into the bulk action (no json.loads/dumps round-trip on the hot path).

Env:
  MANTICORE_URL     (default http://127.0.0.1:9308)
  MANTICORE_TABLE   (default otel_logs)
  BATCH_SIZE        (default 5000 docs per /bulk request)
  INGEST_THREADS    (default min(8, cpu_count) -- concurrent /bulk posters)
  INGEST_QUEUE      (default INGEST_THREADS*4 -- max batches buffered = backpressure)
  PROGRESS_EVERY    (default 100000 docs)
"""

import json
import os
import queue
import sys
import threading

import requests

URL = os.environ.get("MANTICORE_URL", "http://127.0.0.1:9308").rstrip("/")
TABLE = os.environ.get("MANTICORE_TABLE", "otel_logs")
BATCH = int(os.environ.get("BATCH_SIZE", "5000"))
THREADS = int(os.environ.get("INGEST_THREADS", str(min(8, (os.cpu_count() or 4)))))
QUEUE_MAX = int(os.environ.get("INGEST_QUEUE", str(THREADS * 4)))
PROGRESS = int(os.environ.get("PROGRESS_EVERY", "100000"))

PREFIX = b'{"insert":{"index":"' + TABLE.encode() + b'","doc":'

_q: "queue.Queue" = queue.Queue(maxsize=QUEUE_MAX)
_lock = threading.Lock()
_good = 0            # docs successfully queued for indexing
_bad = 0             # unparseable lines skipped
_fatal = []          # first fatal bulk error (stops the load)


def _worker() -> None:
    sess = requests.Session()
    global _good, _bad
    while True:
        batch = _q.get()
        if batch is None:                       # sentinel: no more work
            _q.task_done()
            return
        actions = []
        skipped = 0
        for line in batch:
            try:
                json.loads(line)                # validate; a bad line is a partial record
            except ValueError as e:
                skipped += 1
                with _lock:
                    if _bad < 5:
                        sys.stderr.write(f"[ingest] WARN: skipping unparseable line: {e}: {line[:120]!r}\n")
                    _bad += 1
                continue
            actions.append(PREFIX + line + b"}}")
        if actions and not _fatal:
            body = b"\n".join(actions) + b"\n"
            try:
                r = sess.post(f"{URL}/bulk", data=body,
                              headers={"Content-Type": "application/x-ndjson"}, timeout=600)
                if r.status_code != 200:
                    raise RuntimeError(f"bulk {r.status_code}: {r.text[:300]}")
                j = r.json()
                if j.get("errors"):
                    raise RuntimeError(f"bulk errors: {str(j)[:300]}")
            except Exception as e:              # noqa: BLE001 -- record first, keep draining
                with _lock:
                    if not _fatal:
                        _fatal.append(str(e))
            else:
                with _lock:
                    before = _good
                    _good += len(actions)
                    if before // PROGRESS != _good // PROGRESS:
                        sys.stderr.write(f"[ingest] {_good:,} docs\n")
        _q.task_done()


def main() -> None:
    workers = [threading.Thread(target=_worker, daemon=True) for _ in range(THREADS)]
    for w in workers:
        w.start()

    batch = []
    for raw in sys.stdin.buffer:
        line = raw.strip()
        if not line:
            continue
        batch.append(line)
        if len(batch) >= BATCH:
            _q.put(batch)                       # blocks when full -> bounded memory
            batch = []
            if _fatal:                          # a worker failed -> stop feeding
                break
    if batch and not _fatal:
        _q.put(batch)

    for _ in workers:                           # tell every worker to stop
        _q.put(None)
    for w in workers:
        w.join()

    if _fatal:
        sys.stderr.write(f"[ingest] ERROR: {_fatal[0]}\n")
        sys.exit(1)
    sys.stderr.write(
        f"[ingest] done, {_good:,} docs via {THREADS} threads"
        + (f", {_bad:,} skipped (unparseable)" if _bad else "") + "\n"
    )
    # Tolerate a stray truncated line, but fail loudly on a genuinely corrupt stream.
    if _bad > max(10, _good // 1000):
        sys.stderr.write(f"[ingest] ERROR: {_bad:,} unparseable lines exceeds tolerance -- failing\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
