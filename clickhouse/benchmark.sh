#!/usr/bin/env bash
# ClickHouse engine entrypoint. Sets engine identity and hands off to the
# shared driver in ../lib/benchmark.sh.
set -e

export ENGINE_NAME="ClickHouse"
export ENGINE_TAGS='["C++","column-oriented","ClickHouse"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"

# Backend: docker (default, official image -- every other engine in this suite
# is containerised, so ClickHouse must be too or it skips overhead they pay) or
# binary (local ./clickhouse, for ad-hoc work only).
# In docker mode, CLICKHOUSE_BIN points at ch-exec (a `docker exec -i` shim), so
# check/load/query/data-size/version run the client inside the container with no
# changes. install/start/stop branch on CH_BACKEND to manage the container.
export CH_BACKEND="${CH_BACKEND:-docker}"
export CH_IMAGE="${CH_IMAGE:-clickhouse/clickhouse-server:head}"
export CH_CONTAINER="${CH_CONTAINER:-searchbench-clickhouse}"
if [[ "$CH_BACKEND" == docker ]]; then
    export CLICKHOUSE_BIN="$(cd "$(dirname "$0")" && pwd)/ch-exec"
fi

exec ../lib/benchmark.sh "$@"
