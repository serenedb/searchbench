#!/usr/bin/env bash
# Quickwit entrypoint: ES-compatible DSL posted to /api/v1/_elastic/<index>/_search
set -e
cd "$(dirname "$0")"
export ENGINE_NAME="Quickwit"
export ENGINE_TAGS='["Rust","Tantivy","REST","ES-compatible"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.dsl}"
# Process-wide indexing mode, exported here so the driver, ./start, ./load and the
# run's recorded environment all see the same value (default true; see config/dataset-defaults.sh).
export QW_ENABLE_IN_MEMORY_INDEXING="${QW_ENABLE_IN_MEMORY_INDEXING:-true}"
exec ../lib/benchmark.sh "$@"
