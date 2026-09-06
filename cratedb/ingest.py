#!/usr/bin/env python3
"""NDJSON on stdin -> CrateDB, via concurrent bulk INSERTs.

CrateDB's documented bulk path is COPY FROM, but COPY only accepts a URI --
COPY FROM STDIN is unsupported over pg-wire, and it will not read a FIFO (it
returns rowcount 0 with no error). Using it would mean staging the whole corpus
as NDJSON first: ~93 GB gzipped at 1b, purely to be read once and deleted.

Concurrent bulk INSERT avoids that entirely and measured faster anyway on this
corpus (~68k rows/s at 8 workers vs ~54k for parallel COPY, and ~16k
single-threaded). Throughput peaks around 8 workers and falls off after -- the
table is CLUSTERED INTO 1 SHARDS, so extra writers only add contention.

Streamed: at most WORKERS * 2 batches are in flight, so memory stays bounded
regardless of corpus size.

Env:
  CRATE_URL       (default http://127.0.0.1:4200)
  CRATE_TABLE     (default otel_logs)
  BATCH_SIZE      rows per request (default 5000)
  WORKERS         concurrent requests (default 8)
  PROGRESS_EVERY  rows between progress lines (default 1000000)
"""
import json
import os
import sys
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait

import requests

URL = os.environ.get("CRATE_URL", "http://127.0.0.1:4200").rstrip("/")
TABLE = os.environ.get("CRATE_TABLE", "otel_logs")
BATCH = int(os.environ.get("BATCH_SIZE", "5000"))
WORKERS = int(os.environ.get("WORKERS", "8"))
PROGRESS = int(os.environ.get("PROGRESS_EVERY", "1000000"))

COLUMNS = [
    "ts", "trace_id", "span_id", "trace_flags",
    "severity_text", "severity_number", "service_name", "body",
    "resource_schema_url", "resource_attributes",
    "scope_schema_url", "scope_name", "scope_version", "scope_attributes",
    "log_attributes",
]
INSERT = (
    f"INSERT INTO {TABLE} (" + ",".join(COLUMNS) + ") "
    "VALUES (" + ",".join("?" * len(COLUMNS)) + ")"
)


def flush(session, rows):
    """POST one batch. Raises on any row-level failure so a partial load is
    never mistaken for a complete one."""
    r = session.post(f"{URL}/_sql", json={"stmt": INSERT, "bulk_args": rows},
                     timeout=1800)
    if r.status_code != 200:
        raise RuntimeError(f"insert HTTP {r.status_code}: {r.text[:500]}")
    # CrateDB reports per-row outcome; -2 means that row failed.
    failed = [i for i, x in enumerate(r.json().get("results", []))
              if x.get("rowcount") == -2]
    if failed:
        raise RuntimeError(f"{len(failed)} row(s) rejected, first at index {failed[0]}")
    return len(rows)


def main():
    session = requests.Session()
    # One pooled connection per worker, else requests serialises them.
    session.mount(URL, requests.adapters.HTTPAdapter(
        pool_connections=WORKERS, pool_maxsize=WORKERS))

    done = 0
    pending = set()
    batch = []

    def submit(pool, rows):
        nonlocal pending
        pending.add(pool.submit(flush, session, rows))
        # Bound in-flight work so stdin is consumed lazily, not slurped.
        while len(pending) >= WORKERS * 2:
            finished, pending = wait(pending, return_when=FIRST_COMPLETED)
            drain(finished)

    def drain(futures):
        nonlocal done
        for f in futures:
            done += f.result()          # re-raises worker exceptions here
            if PROGRESS and done % PROGRESS < BATCH:
                sys.stderr.write(f"[ingest] {done:,} rows\n")
                sys.stderr.flush()

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for raw in sys.stdin.buffer:
            raw = raw.strip()
            if not raw:
                continue
            d = json.loads(raw)
            batch.append([d.get(c) for c in COLUMNS])
            if len(batch) >= BATCH:
                submit(pool, batch)
                batch = []
        if batch:
            submit(pool, batch)
        drain(pending)

    sys.stderr.write(f"[ingest] done, {done:,} rows\n")


if __name__ == "__main__":
    main()
