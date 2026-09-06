#!/usr/bin/env bash
# Quickwit entrypoint: ES-compatible DSL posted to /api/v1/_elastic/<index>/_search
set -e
cd "$(dirname "$0")"
export ENGINE_NAME="Quickwit"
export ENGINE_TAGS='["Rust","Tantivy","REST","ES-compatible"]'
export SEARCHBENCH_QUERIES=queries.dsl
exec ../lib/benchmark.sh "$@"
