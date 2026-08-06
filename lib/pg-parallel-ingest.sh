#!/usr/bin/env bash
# Parallel parquet -> Postgres-wire ingest, shared by the adapters whose engine
# speaks the Postgres protocol (postgres, parade, tiger). Sourced from their
# ./load; not part of the SearchBench adapter contract.
#
# WHY PARALLEL: Postgres has no parallel DML -- the insert runs entirely in the
# leader backend, so one connection is one process is one CORE (measured: the
# receiving backend pins a core while the reader idles at 45-80%). More
# connections is the only way to use more of the box.
# 10M wall-clock: K=1 105.9s | 4 38.5 | 8 29.4 | 16 33.0 | 24 34.4 | 32 41.9.
# Plateau 8-16, then write-side contention (WAL insert, relation extension). The
# optimum moves with scale because each stream pays a container startup: at 1M,
# K=4 wins and K=16 is twice as slow, so use *_LOAD_JOBS=4 for smoke runs.
#
# WHY ROW RANGES: file_row_number is the reader's per-file row counter, so [lo,hi)
# deals each row to exactly one stream with no assumption about column values
# (unlike hash(col), where skew or NULLs could unbalance it). Ranges also get
# ROW-GROUP PRUNED, so a stream decodes only its share -- verified on the 100M
# part, the last of 163 row groups costs 0.28s, same as the first, vs 1.57s for a
# full scan. Hence ranges beat mod(file_row_number,K) by ~7%: a modulo matches
# rows in every group. Bounds are not snapped to row-group boundaries; that was
# measured as noise (10M, 4 samples: 33.2s unaligned vs 31.8s aligned).
# Full details: ../OPTIMIZATIONS.md.
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

    # file_row_number restarts per file, so a global range would match the same
    # band in every file, duplicating some rows and dropping others. Every corpus
    # here is a single part_000.parquet; refuse to guess and fall back to 1 stream.
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
            # Consecutive bounds share one expression, so slices tile the range
            # with no gap or overlap whatever the remainder.
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

    # Exact count check: a slicing bug is a gap or a double-count, both invisible
    # to a >0 test.
    loaded=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tA \
        -c "SELECT count(*) FROM ${table};" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$total" && "$loaded" != "$total" ]]; then
        echo "pg_parallel_ingest: ${table} has ${loaded} rows, corpus has ${total}" >&2
        return 1
    fi
    [[ "${loaded:-0}" -gt 0 ]] || { echo "pg_parallel_ingest: ${table} is empty after ingest" >&2; return 1; }
    log "[ingest] ${table} row count: ${loaded}"
}
