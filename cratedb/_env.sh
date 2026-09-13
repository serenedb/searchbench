# CrateDB adapter env defaults. Sourced, not executed.

: "${CRATE_HTTP_PORT:=4200}"
: "${CRATE_IMAGE:=crate:6.4.1}"
: "${CRATE_CONTAINER:=searchbench-cratedb}"
: "${CRATE_DATA_DIR:=${PWD}/crate_data}"
: "${CRATE_TABLE:=otel_logs}"
# CrateDB sizes its own heap from CRATE_HEAP_SIZE; keep it in step with the
# other JVM engines so the comparison is not a memory comparison.
: "${CRATE_HEAP:=${SEARCHBENCH_HEAP:-30g}}"

CRATE_URL="http://127.0.0.1:${CRATE_HTTP_PORT}"

die() { echo "ERROR: $*" >&2; exit 1; }

# One statement per request -- CrateDB's /_sql takes exactly one.
crate_sql() {
    curl -fsS -X POST "${CRATE_URL}/_sql" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg stmt "$1" '{stmt:$stmt}')"
}

# --- serened parquet reader (docker) ------------------------------------------
# CrateDB cannot read parquet; a throwaway serened container reads it (embeds
# DuckDB) and streams NDJSON on stdout. Corpus identity-mounted read-only.
: "${SERENED_IMAGE:=serenedb/serenedb:26.07.5}"
serened_shell() {
    docker run --rm --network host --log-driver none \
        -v "${SEARCHBENCH_DATA_DIR}:${SEARCHBENCH_DATA_DIR}:ro" \
        --entrypoint serened "$SERENED_IMAGE" shell -c "$1"
}
