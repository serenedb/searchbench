#!/usr/bin/env bash
# Apache Pinot entrypoint: set engine identity, hand off to ../lib/benchmark.sh
set -e
export ENGINE_NAME="Pinot"
export ENGINE_TAGS='["Java","Pinot","Lucene","columnar","REST"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"
exec ../lib/benchmark.sh "$@"
