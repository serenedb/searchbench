#!/usr/bin/env bash
# Meilisearch entrypoint: JSON search bodies POSTed to /indexes/<uid>/search
set -e
cd "$(dirname "$0")"
export ENGINE_NAME="Meilisearch"
export ENGINE_TAGS='["Rust","LMDB","REST","Search-as-you-type"]'
export SEARCHBENCH_QUERIES=queries.meili
exec ../lib/benchmark.sh "$@"
