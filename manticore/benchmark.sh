#!/usr/bin/env bash
# Manticore engine entrypoint. Sets engine identity and hands off to the
# shared driver in ../lib/benchmark.sh.
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="Manticore"
export ENGINE_TAGS='["C++","Manticore","Lucene-alt"]'
: "${SEARCHBENCH_QUERIES:=queries.manticore}"
export SEARCHBENCH_QUERIES

exec ../lib/benchmark.sh "$@"
