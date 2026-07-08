#!/usr/bin/env bash
# Postgres FTS entrypoint
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="Postgres"
export ENGINE_TAGS='["C","Postgres","tsvector","GIN"]'
# 92-query tagged workload (mirrors serenedb/queries.sql)
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"

exec ../lib/benchmark.sh "$@"
