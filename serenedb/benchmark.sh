#!/usr/bin/env bash
# SereneDB entrypoint: set engine identity, hand off to ../lib/benchmark.sh
set -e

export ENGINE_NAME="SereneDB"
export ENGINE_TAGS='["C++","SereneDB","Postgres-wire","DuckDB-engine"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"

exec ../lib/benchmark.sh "$@"
