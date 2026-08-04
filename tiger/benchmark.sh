#!/usr/bin/env bash
# TigerData entrypoint: set engine identity, hand off to ../lib/benchmark.sh.
# TigerData = Postgres 17 + pg_textsearch (BM25 inverted index on Postgres pages).
# ./load reads parquet via a serened container since Postgres can't read parquet.
# Hybrid: pg_textsearch BM25 for relevance ranking (top-K), Postgres' own
# tsvector GIN for the boolean and aggregating families -- `<@>` is an
# ORDER-BY-only operator and cannot serve a predicate. See README.md; queries.sql
# documents which index answers each query.
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="TigerData"
export ENGINE_TAGS='["C","TigerData","pg_textsearch","Postgres-extension","BM25","tsvector","GIN"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"

exec ../lib/benchmark.sh "$@"
