#!/usr/bin/env bash
# ClickHouse with the TextBench sorting key.
#
# Same engine, same corpus, same workload as ../clickhouse -- the ONLY difference
# is ORDER BY (ServiceName, Timestamp) instead of ORDER BY tuple() in create.sql.
# A delta against the ClickHouse column therefore isolates the sorting key.
#
# Every mechanic (install/start/stop/check/load/query/ch-exec/...) is a symlink
# to the clickhouse adapter: those scripts cd to their own $(dirname $0), which
# for a symlink is THIS directory, so create.sql and config.xml resolve here.
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="ClickHouse-sorted"
: "${ENGINE_TAGS:=[\"C++\",\"column-oriented\",\"ClickHouse\",\"sorted\"]}"
export ENGINE_TAGS
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"

export CH_BACKEND="${CH_BACKEND:-docker}"
export CH_IMAGE="${CH_IMAGE:-clickhouse/clickhouse-server:26.8.2.7}"
# Own container and datadir so this coexists with the standard adapter.
export CH_CONTAINER="${CH_CONTAINER:-searchbench-clickhouse-sorted}"
export CH_DATA_DIR="${CH_DATA_DIR:-/mnt/data/clickhouse_sorted_data}"
if [[ "$CH_BACKEND" == docker ]]; then
    export CLICKHOUSE_BIN="$(cd "$(dirname "$0")" && pwd)/ch-exec"
fi

exec ../lib/benchmark.sh "$@"
