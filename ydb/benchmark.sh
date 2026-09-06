#!/usr/bin/env bash
set -e
export ENGINE_NAME="YDB"
export ENGINE_TAGS='["C++","Distributed SQL","YQL","Fulltext index"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"
exec ../lib/benchmark.sh "$@"
