#!/usr/bin/env bash
# TigerData over TimescaleDB's COLUMNSTORE (hypercore).
#
# Same engine, same image, same corpus, same 92 queries and same hypertable
# schema as ../tiger -- the ONLY difference is create_index.sql, which converts
# every chunk to the compressed columnar format instead of building the two text
# indexes. A delta against the TigerData column therefore isolates the storage
# engine and nothing else.
#
# Every mechanic (install/start/stop/check/load/query/common.sh/create_table.sql/
# queries.sql) is a symlink to the tiger adapter: those scripts resolve paths
# against their own $(dirname $0), which for a symlink invoked from here is THIS
# directory, so create_index.sql and tiger_data/ resolve locally. There is no
# second copy of the adapter to keep in sync, and a workload fix lands in both
# engines at once.
#
# THE POINT OF THIS COLUMN: no secondary index survives the conversion. Chunk
# indexes are dropped, only the columnstore's own sparse indexes (minmax / bloom
# / firstlast) remain, and the hypercore table access method -- the one form that
# carried B-tree indexes over columnstore chunks -- shipped in TimescaleDB 2.18
# and was removed in 2.22 ("btrees were not the right architecture"). So on
# 2.29.2 every text predicate in queries.sql decompresses batches and filters.
# The trade being measured is disk footprint against query latency.
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="TigerData-columnstore"
# Deliberately not tagged BM25/tsvector/GIN: none of them serve a query here.
: "${ENGINE_TAGS:=[\"C\",\"TigerData\",\"TimescaleDB\",\"Postgres-extension\",\"columnstore\",\"hypercore\"]}"
export ENGINE_TAGS
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"

# Own port/container/data dir so this coexists with ../tiger rather than
# overwriting its PGDATA -- both hold a table called otel_logs, and both can stay
# loaded on the same box. 5455 SereneDB, 5456 ParadeDB, 5457 Postgres, 5458 tiger
# are taken.
export PGPORT="${PGPORT:-5459}"
export TIGER_CONTAINER="${TIGER_CONTAINER:-searchbench-tiger-columnstore}"
export TIGER_DATA_DIR="${TIGER_DATA_DIR:-${PWD}/tiger_data}"

exec ../lib/benchmark.sh "$@"
