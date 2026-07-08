#!/usr/bin/env bash
# OpenSearch entrypoint: DSL bodies POSTed to _search
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="OpenSearch"
export ENGINE_TAGS='["Java","Lucene","OpenSearch","REST"]'

export SEARCHBENCH_QUERIES=queries.dsl
exec ../lib/benchmark.sh "$@"
