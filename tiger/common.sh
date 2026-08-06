#!/usr/bin/env bash
# Shared defaults/helpers for the TigerData adapter, sourced by per-engine scripts.
#
# NOT part of the SearchBench adapter contract; internal DRY only.
#
# TigerData (formerly Timescale) = Postgres + pg_textsearch, a BM25 inverted index
# on Postgres' own storage (memtable + spilled segments, Block-Max WAND). Its
# `<@>` is an ORDER-BY-only operator, so it accelerates top-k ranking and nothing
# else -- see queries.sql for the dialect mapping.

# --- Postgres wire connection -------------------------------------------------
# Port 5458: 5455 SereneDB, 5456 ParadeDB, 5457 Postgres are taken.
: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5458}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

# --- Docker deployment --------------------------------------------------------
# timescaledb-ha ships pg_textsearch prebuilt (it needs PG >= 17 and
# shared_preload_libraries, so a vanilla postgres image cannot run it). Pinned to
# PG 18.4 / TS 2.29.1 / pg_textsearch 1.3.0; the pg18 line is -all/-oss tags only.
: "${TIGER_IMAGE:=timescale/timescaledb-ha:pg18.4-ts2.29.1-all}"
: "${TIGER_CONTAINER:=searchbench-tiger}"
# Host bind-mount under repo (/mnt/data), NOT a docker named volume: named volumes
# live on the small root disk and overflow at larger scales (cf. parade/common.sh).
: "${TIGER_DATA_DIR:=${PWD}/tiger_data}"
# The image is Patroni-flavoured: PGDATA is $PGROOT/pgdata/data, so mount the
# *parent* and let initdb create data/ inside it.
: "${TIGER_CONTAINER_DATA_DIR:=/home/postgres/pgdata}"
# Image runs as uid 1000 (postgres) and does NOT chown the mount, so the host dir
# must be owned by / writable for that uid.
: "${TIGER_UID:=1000}"
export TIGER_IMAGE TIGER_CONTAINER TIGER_DATA_DIR TIGER_CONTAINER_DATA_DIR TIGER_UID

# Public corpus bucket (same as lib/download-otel-logs); ./load streams smoke
# scale's first rows over HTTPS via serened.
: "${SEARCHBENCH_BASE_URL:=https://public-pme.s3.eu-west-3.amazonaws.com/text_bench}"

# --- serened parquet reader (docker) ------------------------------------------
# Postgres can't read parquet; a throwaway serened container reads it (embeds
# DuckDB) and streams rows over the PG wire via its postgres connector. Corpus is
# identity-mounted; --network host reaches this adapter's PG on $PGPORT.
: "${SERENED_IMAGE:=serenedb/serenedb:26.07.5}"
export SERENED_IMAGE
serened_shell() {
    docker run --rm --network host --log-driver none \
        -v "${SEARCHBENCH_DATA_DIR}:${SEARCHBENCH_DATA_DIR}:ro" \
        --entrypoint serened "$SERENED_IMAGE" shell -c "$1"
}

# Shared psql invocation. ON_ERROR_STOP added per-call where failure must abort
# (load); bare array fine for probes.
PSQL=(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
