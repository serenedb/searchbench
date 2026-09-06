#!/usr/bin/env bash
# SurrealDB entrypoint: SurrealQL posted to /sql
set -e
cd "$(dirname "$0")"
export ENGINE_NAME="SurrealDB"
export ENGINE_TAGS='["Rust","RocksDB","SurrealQL","Document"]'
export SEARCHBENCH_QUERIES=queries.surql
exec ../lib/benchmark.sh "$@"
