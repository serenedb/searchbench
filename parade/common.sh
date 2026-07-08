#!/usr/bin/env bash
# Shared defaults/helpers for the ParadeDB adapter, sourced by per-engine scripts.
#
# NOT part of the SearchBench adapter contract; internal DRY only.
#
# Optional env below: all overridable to retarget port/image/container.

# --- Postgres wire connection (ParadeDB speaks plain Postgres) ----------------
# Port 5456 avoids collision with SereneDB adapter (owns 5455).
: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5456}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

# --- Docker deployment --------------------------------------------------------
# Pinned 0.24.1 (has `simple` tokenizer / pdb.simple cast). Index uses JSON
# tokenizer `default` (== SimpleTokenizer; pg_search maps pdb.simple -> default)
# since only JSON field API supports indexed:false for stored-but-not-indexed
# cols; see create_index.sql. Tokenization = lowercase + split-on-non-alphanum,
# matching ClickHouse splitByNonAlpha and SereneDB ts_split_by_non_alpha.
: "${PARADE_IMAGE:=paradedb/paradedb:0.24.1}"
: "${PARADE_CONTAINER:=searchbench-paradedb}"
# Host bind-mount under repo (/mnt/data, 1.5 TB), NOT a docker named volume
# (those land on /var/lib/docker on small root disk). Named volume on root is
# why 100m ran out of space: heap + WAL + ~120 GB BM25 index overflowed 96 GB /.
: "${PARADE_DATA_DIR:=${PWD}/paradedb_data}"
export PARADE_IMAGE PARADE_CONTAINER PARADE_DATA_DIR

# Public corpus bucket (same as lib/download-otel-logs); ./load streams smoke
# scale's first 100k rows over HTTPS via serened.
: "${SEARCHBENCH_BASE_URL:=https://public-pme.s3.eu-west-3.amazonaws.com/text_bench}"

# --- serened parquet reader (docker) ------------------------------------------
# ParadeDB can't read parquet; a throwaway serened container reads it (embeds
# DuckDB) and streams rows over the PG wire via its postgres connector. Corpus is
# identity-mounted; --network host reaches this adapter's PG on $PGPORT.
: "${SERENED_IMAGE:=serenedb/serenedb:26.07.1}"
export SERENED_IMAGE
serened_shell() {
    docker run --rm --network host \
        -v "${SEARCHBENCH_DATA_DIR}:${SEARCHBENCH_DATA_DIR}:ro" \
        --entrypoint serened "$SERENED_IMAGE" shell -c "$1"
}

# Shared psql invocation. ON_ERROR_STOP added per-call where failure must abort
# (load); bare array fine for probes.
PSQL=(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
