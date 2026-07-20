#!/usr/bin/env bash
# Shared defaults + helpers for the pgvector adapter (vector track).
# Mirrors postgres/common.sh; the pgvector/pgvector image is stock Postgres with
# the `vector` extension preinstalled.

# Port 5458 avoids SereneDB (5499), Postgres-FTS (5457), ParadeDB (5456).
: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5458}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

# --- Docker deployment ---
: "${PGV_IMAGE:=pgvector/pgvector:pg17}"
: "${PGV_CONTAINER:=searchbench-pgvector}"
: "${PGV_DATA_DIR:=${PWD}/pgvector_data}"
export PGV_IMAGE PGV_CONTAINER PGV_DATA_DIR

# psql, no-password auth (./start sets POSTGRES_HOST_AUTH_METHOD=trust).
PSQL=(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
