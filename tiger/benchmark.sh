#!/usr/bin/env bash
# TigerData entrypoint: set engine identity, hand off to ../lib/benchmark.sh.
# TigerData = Postgres 18.4 + TimescaleDB 2.29.2 + pg_textsearch 1.4.0 (BM25
# inverted index on Postgres pages).
# ./load reads parquet via a serened container since Postgres can't read parquet.
# Hybrid: pg_textsearch BM25 for relevance ranking (top-K), Postgres' own
# tsvector GIN for the boolean and aggregating families -- `<@>` is an
# ORDER-BY-only operator and cannot serve a predicate. See README.md; queries.sql
# documents which index answers each query.
#
# ROWSTORE variant. ../tiger-columnstore is the same adapter over TimescaleDB's
# columnstore -- it symlinks every script here and differs only in
# create_table.sql (which declares the columnstore) and create_index.sql (which
# converts the chunks instead of building indexes).
set -e
cd "$(dirname "$0")"

export ENGINE_NAME="TigerData"
export ENGINE_TAGS='["C","TigerData","pg_textsearch","Postgres-extension","BM25","tsvector","GIN"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"

exec ../lib/benchmark.sh "$@"
