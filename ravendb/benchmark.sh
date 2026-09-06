#!/usr/bin/env bash
# RavenDB entrypoint: RQL posted to /databases/<db>/queries
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="RavenDB"
export ENGINE_TAGS='["C#",".NET","Corax","RQL","Document"]'

export SEARCHBENCH_QUERIES=queries.rql
exec ../lib/benchmark.sh "$@"
