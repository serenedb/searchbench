#!/usr/bin/env bash
# Shared defaults + helpers for vanilla Postgres FTS adapter.
#
# Optional env: all below overridable.

# Port 5457 avoids collision with SereneDB (5455) and ParadeDB (5456).
: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5457}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

# --- Docker deployment ---
: "${PG_IMAGE:=postgres:16-alpine}"
: "${PG_CONTAINER:=searchbench-postgres}"
: "${PG_PASSWORD:=postgres}"
# Host bind-mount under repo (/mnt/data), not a docker named volume: named volumes
# live on small root disk and overflow at larger scales (cf. parade/common.sh).
: "${PG_DATA_DIR:=${PWD}/postgres_data}"
export PG_IMAGE PG_CONTAINER PG_PASSWORD PG_DATA_DIR

# Public corpus bucket (cf. lib/download-otel-logs); ./load streams smoke scale's
# first 100k rows over HTTPS via serened.
: "${SEARCHBENCH_BASE_URL:=https://public-pme.s3.eu-west-3.amazonaws.com/text_bench}"

# --- serened parquet reader (docker) ------------------------------------------
# Postgres can't read parquet; a throwaway serened container reads it (embeds
# DuckDB) and streams rows over the PG wire via its postgres connector. Corpus is
# identity-mounted; --network host reaches this adapter's PG on $PGPORT.
: "${SERENED_IMAGE:=serenedb/serenedb:26.07.1}"
export SERENED_IMAGE
serened_shell() {
    docker run --rm --network host \
        -v "${SEARCHBENCH_DATA_DIR}:${SEARCHBENCH_DATA_DIR}:ro" \
        --entrypoint serened "$SERENED_IMAGE" shell -c "$1"
}

# psql, no-password auth (./start sets POSTGRES_HOST_AUTH_METHOD=trust).
PSQL=(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
