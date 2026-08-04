#!/usr/bin/env bash
# Parallel parquet -> Postgres-wire ingest, shared by the adapters whose engine
# speaks the Postgres protocol (postgres, parade, tiger). Sourced from their
# ./load; not part of the SearchBench adapter contract.
#
# WHY PARALLEL: Postgres has no parallel DML. INSERT ... SELECT parallelises the
# select side, but the insert itself runs entirely in the leader backend, so one
# connection is one process is one CORE. Measured single-stream on a 32-core box,
# the receiving backend pins 90-100% of a core while the serened reader only
# reaches 45-80%: the write side is the ceiling, and the only way to use more of
# the machine is more connections.
#
# Measured wall-clock for the whole ingest (32 cores, 10M rows):
#   K=1 105.9s | K=4 38.5s | K=8 29.4s | K=16 33.0s | K=24 34.4s | K=32 41.9s
# The plateau is 8-16, then it regresses: the streams contend on the write side
# (WAL insert locks, relation extension, buffer manager), NOT on parquet decode.
# The optimum moves with scale because every stream pays a fixed container
# startup -- at 1M rows K=4 wins (3.7s) and K=16 is twice as slow (7.4s), while
# by 10M that has reversed. Tune per run with the caller's *_LOAD_JOBS var.
#
# WHY SLICE BY ROW RANGE: file_row_number is the parquet reader's per-file row
# counter, so [lo, hi) deals every row to exactly one stream with no assumption
# about column values -- unlike hash(col), where skew or NULLs could lose or
# unbalance rows. A range predicate is also ROW-GROUP PRUNED by the reader, so a
# stream decodes only its own share of the file: verified on the 100M part (163
# row groups), summing a column over the LAST row group costs 0.28s, the same as
# the first and well under the 1.57s full scan. That is why ranges beat
# mod(file_row_number, K) by ~7% -- a modulo matches rows in every group, so
# every stream would have to decode everything.
# Bounds are NOT snapped to row-group boundaries: an unaligned cut makes the one
# group it lands in get decoded by both neighbours (~9% extra decode at K=16 over
# 163 groups), but decode is not the bottleneck. A/B at 10M rows over 4 samples
# each: 33.2s unaligned vs 31.8s aligned, identical best cases -- inside the
# run-to-run noise.
#
# Requires the caller to have already provided:
#   serened_shell()  -- runs one throwaway serened container (per-adapter)
#   PGHOST PGPORT PGDATABASE PGUSER
#   SEARCHBENCH_DATA_DIR  -- dir holding part_*.parquet
#   log()            -- stderr logger

# pg_parallel_ingest <jobs> <table> <insert_cols> <select_proj>
#
# <select_proj> is the projection, in <insert_cols> order, evaluated against
# read_parquet(..., file_row_number=true) -- so it may reference file_row_number
# (ParadeDB uses it as the BM25 key_field; see parade/load).
#
# Returns non-zero if any stream fails or if the final row count doesn't match
# the corpus. Echoes nothing; logs progress via log().
pg_parallel_ingest() {
    local jobs="$1" table="$2" insert_cols="$3" select_proj="$4"
    local glob="${SEARCHBENCH_DATA_DIR}/part_*.parquet"
    local src="read_parquet('${glob}', file_row_number=true)"
    local attach="ATTACH 'host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER}' AS pg (TYPE postgres);"
    local total="" nfiles j lo hi pids=() p failed=0 loaded

    shopt -s nullglob
    local parts=( ${glob} )
    shopt -u nullglob
    nfiles=${#parts[@]}

    # file_row_number restarts at 0 for every file, so a global row range would
    # match the same band in each file -- duplicating some rows and dropping
    # others. Every corpus this suite ships is a single part_000.parquet; if that
    # ever changes, slicing needs per-file offsets. Refuse to guess: fall back to
    # one stream, which is always correct.
    if (( nfiles > 1 && jobs > 1 )); then
        log "[ingest] WARNING: ${nfiles} part files found; file_row_number is per-file so row-range slicing would double-count. Falling back to a single stream."
        jobs=1
    fi

    if (( jobs > 1 )); then
        # Parquet metadata only -- no scan (0.27s even for the 100M part).
        total=$(serened_shell \
            "COPY (SELECT count(*) FROM read_parquet('${glob}')) TO '/dev/stdout' (FORMAT csv);" \
            2>/dev/null | tail -1 | tr -d '[:space:]')
        if [[ ! "$total" =~ ^[0-9]+$ ]] || (( total == 0 )); then
            echo "pg_parallel_ingest: could not read row count from parquet metadata (got '${total}')" >&2
            return 1
        fi
        log "[ingest] ${jobs} parallel streams over ${total} rows (${nfiles} part file)"
    else
        log "[ingest] single stream (${nfiles} part file)"
    fi

    for (( j = 0; j < jobs; j++ )); do
        local where=""
        if (( jobs > 1 )); then
            # Consecutive bounds share one expression, so slices tile the whole
            # range with no gap and no overlap whatever the remainder.
            lo=$(( total * j / jobs ))
            hi=$(( total * (j + 1) / jobs ))
            where=" WHERE file_row_number >= ${lo} AND file_row_number < ${hi}"
        fi
        serened_shell "
${attach}
INSERT INTO pg.${table} (${insert_cols})
SELECT ${select_proj} FROM ${src}${where};
" &
        pids+=($!)
    done
    for p in "${pids[@]}"; do
        wait "$p" || failed=1
    done
    (( failed == 0 )) || { echo "pg_parallel_ingest: one or more streams failed" >&2; return 1; }

    # Exact count check: a slicing bug shows up as a gap or a double-count, and
    # both are invisible to a >0 test.
    loaded=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tA \
        -c "SELECT count(*) FROM ${table};" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$total" && "$loaded" != "$total" ]]; then
        echo "pg_parallel_ingest: ${table} has ${loaded} rows, corpus has ${total}" >&2
        return 1
    fi
    [[ "${loaded:-0}" -gt 0 ]] || { echo "pg_parallel_ingest: ${table} is empty after ingest" >&2; return 1; }
    log "[ingest] ${table} row count: ${loaded}"
}
