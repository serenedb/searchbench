#!/usr/bin/env bash
# ParadeDB entrypoint: set engine identity, hand off to ../lib/benchmark.sh.
# ParadeDB = Postgres + pg_search BM25 (Tantivy). ./load reads parquet via a
# serened container since Postgres can't read parquet. See README.md.
set -e

export ENGINE_NAME="ParadeDB"
export ENGINE_TAGS='["Rust","ParadeDB","pg_search","Postgres-extension","BM25","Tantivy"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"

exec ../lib/benchmark.sh "$@"
