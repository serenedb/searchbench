#!/usr/bin/env bash
# Elasticsearch in columnar index mode (9.5 tech preview, GA in 9.6).
#
# Same engine, same corpus, same workload and same mapping as ../elastic -- the
# ONLY difference is `"mode": "columnar"` in config/index_mapping.json. A delta
# against the Elasticsearch columns therefore isolates the storage mode and
# nothing else.
#
# Every mechanic (install/start/stop/check/load/query/ingest.py/...) is a
# symlink to the elastic adapter: those scripts cd to their own $(dirname $0),
# which for a symlink is THIS directory, so config/ and es-data/ resolve here.
# Only the engine identity and the instance overrides live in this file, so
# there is no second copy of the adapter to keep in sync.
#
# queries.dsl and queries.esql are symlinks too, so a workload fix lands in
# both engines at once. Because two queries.* files are present, the shared
# driver auto-labels the column with the dialect actually run:
#   ./benchmark.sh                          -> Elasticsearch-columnar (dsl)
#   SEARCHBENCH_QUERIES=queries.esql ...    -> Elasticsearch-columnar (esql)
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="Elasticsearch-columnar"
: "${ENGINE_TAGS:=[\"Java\",\"Lucene\",\"Elasticsearch\",\"REST\",\"columnar\"]}"
export ENGINE_TAGS
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.dsl}"

# Own port/container/data dir so this coexists with the standard adapter rather
# than overwriting its index -- both can stay loaded on the same box.
export ES_PORT="${ES_PORT:-9203}"
export ES_CONTAINER="${ES_CONTAINER:-searchbench-es-columnar}"
export ES_DATA_DIR="${ES_DATA_DIR:-${PWD}/es-data}"

exec ../lib/benchmark.sh "$@"
