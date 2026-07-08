#!/usr/bin/env bash
# Elasticsearch entrypoint. Hybrid queries.dsl: DSL _search for Q01-Q83, ES|QL
# LOOKUP JOIN for joins Q84-Q92 (DSL ~2x faster on search/agg; joins ES|QL-only).
# elastic/query auto-detects dialect per line (leading '{' => DSL, else ES|QL).
# Pure ES|QL set in queries.esql for A-B runs (SEARCHBENCH_QUERIES=...esql).
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="Elasticsearch"
export ENGINE_TAGS='["Java","Lucene","Elasticsearch","REST","DSL"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.dsl}"
exec ../lib/benchmark.sh "$@"
