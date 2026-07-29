#!/usr/bin/env bash
# Shared config + helpers for the ArangoDB adapter (docker only). Sourced by
# install/start/stop/check/load/query/data-size/version. Not part of the
# SearchBench adapter contract -- the driver only execs the named scripts and
# reads queries.aql, so this helper is invisible to it. All below is overridable.

# --- HTTP connection ----------------------------------------------------------
# 8529 is ArangoDB's default; no collision with SereneDB (5455)/ParadeDB (5456).
# --network host binds it directly on the host -- no port mapping.
: "${ARANGO_HOST:=127.0.0.1}"
: "${ARANGO_PORT:=8529}"
: "${ARANGO_DB:=_system}"

# --- docker deployment --------------------------------------------------------
# Enterprise image: optimizeTopK (top-k queries) is Enterprise-only <=3.12.4;
# free from 3.12.5, published only under arangodb/enterprise (no license key).
: "${ARANGO_IMAGE:=arangodb/enterprise:3.12}"
: "${ARANGO_CONTAINER:=searchbench-arango}"
# Host bind-mount data dir (mirrors ParadeDB's ${PWD}/paradedb_data), mounted at
# the container data root; wiped by ./install.
: "${ARANGO_DATA_DIR:=${PWD}/arango_data}"
: "${ARANGO_CONTAINER_DATA_DIR:=/var/lib/arangodb3}"

# --- serened parquet reader (docker) ------------------------------------------
# ArangoDB can't read parquet; a throwaway serened container reads it (embeds
# DuckDB) and emits NDJSON on stdout for arangoimport. Corpus identity-mounted.
: "${SERENED_IMAGE:=serenedb/serenedb:26.07.5}"
serened_shell() {
    docker run --rm --network host --log-driver none \
        -v "${SEARCHBENCH_DATA_DIR}:${SEARCHBENCH_DATA_DIR}:ro" \
        --entrypoint serened "$SERENED_IMAGE" shell -c "$1"
}

# --- catalog names ------------------------------------------------------------
: "${ARANGO_COLLECTION:=otel_logs}"
: "${ARANGO_VIEW:=otel_logs_view}"
: "${ARANGO_ANALYZER:=seg}"

ARANGO_BASE="http://${ARANGO_HOST}:${ARANGO_PORT}"
ARANGO_API="${ARANGO_BASE}/_db/${ARANGO_DB}/_api"

# curl wrapper for the ArangoDB HTTP API (auth disabled on the server).
arango_api() {
    local method="$1" path="$2"; shift 2
    curl -fsS -X "$method" "${ARANGO_API}${path}" "$@"
}

# Run one AQL statement; emit the raw cursor JSON on stdout.
arango_aql() {
    local query="$1"
    jq -nc --arg q "$query" '{query:$q,batchSize:1000}' \
        | curl -fsS -X POST "${ARANGO_API}/cursor" -d @-
}

# Docs in the base collection (always a number, so callers' arithmetic stays
# safe under set -e even on a transient HTTP error).
arango_collection_count() {
    local n
    n=$(arango_api GET "/collection/${ARANGO_COLLECTION}/count" 2>/dev/null \
        | jq -r '.count // 0' 2>/dev/null) || true
    printf '%s' "${n:-0}"
}

# Docs currently indexed in the view (lags the collection while the link catches
# up after a bulk import). Same always-a-number guarantee.
arango_view_count() {
    local n
    n=$(arango_aql "FOR d IN ${ARANGO_VIEW} COLLECT WITH COUNT INTO c RETURN c" 2>/dev/null \
        | jq -r '.result[0] // 0' 2>/dev/null) || true
    printf '%s' "${n:-0}"
}
