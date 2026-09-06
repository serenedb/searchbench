#!/usr/bin/env bash
# CrateDB entrypoint. Sets engine identity and hands off to the shared driver.
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="CrateDB"
: "${ENGINE_TAGS:=[\"Java\",\"Lucene\",\"CrateDB\",\"SQL\",\"REST\"]}"
export ENGINE_TAGS
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"

exec ../lib/benchmark.sh "$@"
