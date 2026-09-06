#!/usr/bin/env bash
# Typesense entrypoint: search query-strings posted to /collections/<c>/documents/search
set -e
cd "$(dirname "$0")"
export ENGINE_NAME="Typesense"
export ENGINE_TAGS='["C++","REST","Search-as-you-type"]'
export SEARCHBENCH_QUERIES=queries.ts
exec ../lib/benchmark.sh "$@"
