#!/usr/bin/env bash
# VictoriaLogs entrypoint: LogsQL queries POSTed to /select/logsql/query
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="VictoriaLogs"
export ENGINE_TAGS='["Go","VictoriaMetrics","LogsQL","REST"]'

export SEARCHBENCH_QUERIES=queries.logsql
exec ../lib/benchmark.sh "$@"
