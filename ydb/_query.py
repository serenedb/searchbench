#!/usr/bin/env python3
"""Run YQL from stdin against YDB.

Contract: stdout=tuple-only rows; stderr has SEARCHBENCH_ROWS=<n> and, as the
last line, fractional elapsed seconds. Exit non-zero on error.

The `ydb` CLI is not used for queries: it costs ~100ms of process startup per
invocation, which would be charged to every query in a suite where the fast
ones run in single-digit milliseconds. The SDK measures the round-trip only.
"""
import os
import sys
import time

import ydb

ENDPOINT = os.environ.get("YDB_ENDPOINT", "grpc://localhost:2136")
DATABASE = os.environ.get("YDB_DATABASE", "/local")

sql = sys.stdin.read()

driver = ydb.Driver(ydb.DriverConfig(ENDPOINT, DATABASE))
try:
    driver.wait(timeout=30)
    pool = ydb.QuerySessionPool(driver)

    t0 = time.perf_counter()
    result_sets = pool.execute_with_retries(sql)
    elapsed = time.perf_counter() - t0

    rows = []
    for rs in result_sets:
        for r in rs.rows:
            vals = []
            for v in r.values():
                if isinstance(v, bytes):
                    v = v.decode("utf-8", "replace")
                vals.append("" if v is None else str(v))
            rows.append("|".join(vals))
except Exception as exc:                                  # noqa: BLE001
    print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(1)
finally:
    try:
        driver.stop(timeout=5)
    except Exception:                                     # noqa: BLE001
        pass

print(f"SEARCHBENCH_ROWS={len(rows)}", file=sys.stderr)
for line in rows:
    print(line)
print(f"{elapsed:.3f}", file=sys.stderr)
