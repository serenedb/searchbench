#!/usr/bin/env bash
# SearchBench shared VECTOR driver — the ANN counterpart of lib/benchmark.sh.
#
# A per-engine ./benchmark-vector.sh sets identity + connection and exec's this
# from the engine dir, so ./install ./start ./stop ./check ./data-size ./load-vector
# resolve engine-local (the lifecycle verbs are shared verbatim with the text track).
#
# Unlike the text driver, the inner loop is NOT one-query-on-stdin: for each
# build config it runs ./load-vector (ingest + build index -> build metrics JSON)
# then lib/vector_query.py (recall-vs-QPS sweep -> per-search-point records). All
# records land in results-vector/<engine>_<dataset>.json for vector-ui/.
#
# Per-engine env (set before exec):
#   ENGINE_NAME     e.g. "SereneDB"
#   ENGINE_TAGS     JSON array string
#   VECTOR_ENGINE   serenedb | pgvector  (selects helper code paths)
#   VECTOR_TARGET   relation to query (serenedb: vec_idx ; pgvector: vec)
#   PGPORT          engine pgwire port (adapter default)
#
# Runtime env (operator-supplied):
#   SEARCHBENCH_DATA_DIR        root data dir (REQUIRED); rooted per-dataset below.
#   SEARCHBENCH_VECTOR_DATASET  registry key (default synthetic)
#   VECTOR_K                    recall@k (default 10)
#   VECTOR_SEARCH_EFFORT        sweep list; nprobe (serenedb) / ef_search (pgvector). default 8,16,32,64,128
#   VECTOR_CLIENTS              concurrency sweep list (default 1)
#   VECTOR_NB / VECTOR_NQ       override registry base/query slice sizes
#   -- SereneDB build configs (comma lists -> cartesian build sweep) --
#   VECTOR_QUANT (none) VECTOR_NLIST (auto) VECTOR_RERANK (unset) VECTOR_SETTLE (compact) VECTOR_LOAD_VIA (copy)
#   -- pgvector build configs --
#   VECTOR_PG_INDEX_TYPE (hnsw) VECTOR_HNSW_M (16) VECTOR_EF_CONSTRUCTION (64) VECTOR_LISTS (1000)
#   SEARCHBENCH_RESULTS         output JSON (default results-vector/<engine>_<dataset>.json)
#   SEARCHBENCH_PYTHON          python with vector deps (default python3)

set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "ERROR: bash 4+ required" >&2; exit 1; }

: "${ENGINE_NAME:?ENGINE_NAME must be set by the per-engine benchmark-vector.sh}"
: "${VECTOR_ENGINE:?VECTOR_ENGINE must be set (serenedb|pgvector)}"
: "${ENGINE_TAGS:=[\"$ENGINE_NAME\"]}"
: "${VECTOR_TARGET:=vec}"
: "${SEARCHBENCH_VECTOR_DATASET:=synthetic}"
: "${SEARCHBENCH_DATA_DIR:?SEARCHBENCH_DATA_DIR must be set to a root data directory (no default)}"
SEARCHBENCH_DATA_DIR="${SEARCHBENCH_DATA_DIR%/}/${SEARCHBENCH_VECTOR_DATASET}"
: "${VECTOR_K:=10}"
: "${VECTOR_SEARCH_EFFORT:=8,16,32,64,128}"
: "${VECTOR_CLIENTS:=1}"
: "${VECTOR_NB:=}"
: "${VECTOR_NQ:=}"
: "${VECTOR_QUANT:=none}"
: "${VECTOR_NLIST:=auto}"
: "${VECTOR_RERANK:=}"
: "${VECTOR_SETTLE:=compact}"
: "${VECTOR_LOAD_VIA:=copy}"
: "${VECTOR_PG_INDEX_TYPE:=hnsw}"
: "${VECTOR_HNSW_M:=16}"
: "${VECTOR_EF_CONSTRUCTION:=64}"
: "${VECTOR_LISTS:=1000}"
: "${SEARCHBENCH_PYTHON:=python3}"
: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
: "${PGPORT:?PGPORT must be set by the engine adapter}"
# Slugify the (possibly labelled) engine name for the filename, e.g.
# "pgvector (HNSW)" -> pgvector_hnsw, "SereneDB" -> serenedb.
_eslug=$(printf '%s' "$ENGINE_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_' | sed 's/_\+/_/g; s/^_//; s/_$//')
: "${SEARCHBENCH_RESULTS:=results-vector/${_eslug}_${SEARCHBENCH_VECTOR_DATASET}.json}"

DO_INDEX=no
[[ "${SEARCHBENCH_INDEX:-}" =~ ^(1|yes|true|on)$ ]] && DO_INDEX=yes
for a in "$@"; do [[ "$a" == "--index" ]] && DO_INDEX=yes; done

export SEARCHBENCH_DATA_DIR SEARCHBENCH_VECTOR_DATASET PGHOST PGPORT PGUSER PGDATABASE
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] [INFO]  %s\n' "$(ts)" "$*" >&2; }
warn() { printf '[%s] [WARN]  %s\n' "$(ts)" "$*" >&2; }
die()  { printf '[%s] [ERROR] %s\n' "$(ts)" "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required binary: $1"; }
require jq
require "$SEARCHBENCH_PYTHON"

check_loop() { local i; for i in $(seq 1 60); do ./check >/dev/null 2>&1 && return 0; sleep 1; done; die "./check did not succeed within 60s"; }

# Registry metadata for the top-level result fields.
META=$("$SEARCHBENCH_PYTHON" "${LIB_DIR}/vector_common.py" meta "$SEARCHBENCH_VECTOR_DATASET")
DISTANCE=$(printf '%s' "$META" | jq -r '.distance')
TIER=$(printf '%s' "$META" | jq -r '.tier')
NB_SPEC=$(printf '%s' "$META" | jq -r '.nb')
NQ_SPEC=$(printf '%s' "$META" | jq -r '.nq')
DIM_SPEC=$(printf '%s' "$META" | jq -r '.dim')

# Build-config list -> newline-separated "label|<ingest-args>|<extra-json-fragment>".
build_configs() {
    local q nl m efc
    if [[ "$VECTOR_ENGINE" == "serenedb" ]]; then
        for q in ${VECTOR_QUANT//,/ }; do
            for nl in ${VECTOR_NLIST//,/ }; do
                local args=(--quant "$q" --settle "$VECTOR_SETTLE" --load-via "$VECTOR_LOAD_VIA")
                local frag; frag=$(jq -nc --arg algo ivf --arg quant "$q" --arg nlist "$nl" \
                    '{build_algo:$algo,quant:$quant,nlist:$nlist}')
                [[ "$nl" != "auto" ]] && args+=(--nlist "$nl")
                printf '%s\t%s\t%s\n' "ivf/${q}/nlist=${nl}" "${args[*]}" "$frag"
            done
        done
    elif [[ "$VECTOR_PG_INDEX_TYPE" == "ivfflat" ]]; then
        # IVFFlat build param is `lists` (one inverted-file cell count per build).
        local ls
        for ls in ${VECTOR_LISTS//,/ }; do
            local args=(--pg-index-type ivfflat --lists "$ls")
            local frag; frag=$(jq -nc --arg algo ivfflat --arg lists "$ls" '{build_algo:$algo,lists:$lists}')
            printf '%s\t%s\t%s\n' "ivfflat/lists=${ls}" "${args[*]}" "$frag"
        done
    else
        # HNSW build params are m x ef_construction.
        for m in ${VECTOR_HNSW_M//,/ }; do
            for efc in ${VECTOR_EF_CONSTRUCTION//,/ }; do
                local args=(--pg-index-type hnsw --hnsw-m "$m" --ef-construction "$efc")
                local frag; frag=$(jq -nc --arg algo hnsw --arg m "$m" --arg efc "$efc" \
                    '{build_algo:$algo,m:$m,ef_construction:$efc}')
                printf '%s\t%s\t%s\n' "hnsw/m=${m}/efc=${efc}" "${args[*]}" "$frag"
            done
        done
    fi
}

# --- accumulate records[] across build configs, write crash-safe partial ------
ALL_RECORDS="[]"
os_name=$( [[ -r /etc/os-release ]] && awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2);print $2}' /etc/os-release || uname -sr )
date_str=$(date +%F)
version=$( [[ -x ./version ]] && (./version 2>/dev/null || echo unknown) || echo unknown )

write_json() {
    local target="$1"
    jq -n \
        --arg system "$ENGINE_NAME" --arg engine "$VECTOR_ENGINE" \
        --arg dataset "$SEARCHBENCH_VECTOR_DATASET" --arg distance "$DISTANCE" \
        --arg tier "$TIER" --argjson dim "${DIM_CUR:-$DIM_SPEC}" \
        --argjson nb "${NB_CUR:-$NB_SPEC}" --argjson nq "${NQ_SPEC}" \
        --argjson k "$VECTOR_K" --arg version "$version" --arg os "$os_name" \
        --arg date "$date_str" --argjson tags "$ENGINE_TAGS" \
        --argjson results "$ALL_RECORDS" \
        '{system:$system, engine:$engine, dataset:$dataset, distance:$distance,
          tier:$tier, dim:$dim, nb:$nb, nq:$nq, k:$k, version:$version, os:$os,
          date:$date, tags:$tags, results:$results}' > "$target"
}

main() {
    log "engine     : $ENGINE_NAME ($VECTOR_ENGINE)"
    log "dataset    : $SEARCHBENCH_VECTOR_DATASET (distance=$DISTANCE tier=$TIER dim=$DIM_SPEC)"
    log "data dir   : $SEARCHBENCH_DATA_DIR"
    log "port       : $PGPORT"
    log "k          : $VECTOR_K   search effort: $VECTOR_SEARCH_EFFORT   clients: $VECTOR_CLIENTS"
    log "mode       : $([[ $DO_INDEX == yes ]] && echo 'LOAD+BUILD+SWEEP (--index)' || echo 'sweep-only')"
    log "results    : $SEARCHBENCH_RESULTS"

    [[ -x ./load-vector ]] || die "no ./load-vector in this adapter"

    if [[ "$DO_INDEX" == yes ]]; then
        log "==> install"; ./install
    fi
    log "==> start"; ./start >/dev/null 2>&1 || true
    check_loop

    if [[ "$DO_INDEX" == yes ]]; then
        log "==> download"
        "${LIB_DIR}/download-vectors"
    fi

    mkdir -p "$(dirname "$SEARCHBENCH_RESULTS")"
    local partial="${SEARCHBENCH_RESULTS%.json}.partial.json"
    local logfile="${SEARCHBENCH_RESULTS%.json}.build.log"; : > "$logfile"

    local nb_arg=() nq_arg=()
    [[ -n "$VECTOR_NB" ]] && nb_arg=(--nb "$VECTOR_NB")
    [[ -n "$VECTOR_NQ" ]] && nq_arg=(--nq "$VECTOR_NQ")

    local label ingest_args frag
    while IFS=$'\t' read -r label ingest_args frag; do
        [[ -z "$label" ]] && continue
        log "==> build config: $label"

        # ./load-vector prints ONLY the build-metrics JSON on stdout (logs -> stderr).
        local build_json
        if ! build_json=$( \
            VECTOR_INGEST_ARGS="$ingest_args" \
            VECTOR_K="$VECTOR_K" VECTOR_NB="$VECTOR_NB" VECTOR_NQ="$VECTOR_NQ" \
            ./load-vector 2>>"$logfile" ); then
            warn "build failed for $label — see $logfile; skipping"
            continue
        fi

        DIM_CUR=$(printf '%s' "$build_json" | jq -r '.dim')
        NB_CUR=$(printf '%s' "$build_json" | jq -r '.nb')
        local datadir_bytes; datadir_bytes=$( ./data-size 2>/dev/null || echo 0 )

        # extra-json merged into every search-point record: build-config identity + build metrics.
        local extra
        extra=$(jq -nc --argjson f "$frag" --argjson b "$build_json" --argjson dd "$datadir_bytes" \
            '$f + {load_s:$b.load_s, index_build_s:$b.index_build_s, build_total_s:$b.build_total_s,
                   index_disk_bytes:$b.index_disk_bytes, datadir_bytes:$dd, ddl:$b.ddl}')

        local rr_arg=()
        [[ -n "$VECTOR_RERANK" && "$VECTOR_ENGINE" == "serenedb" ]] && rr_arg=(--rerank-factor "$VECTOR_RERANK")

        log "    sweeping recall-vs-QPS ..."
        local records
        if ! records=$("$SEARCHBENCH_PYTHON" "${LIB_DIR}/vector_query.py" \
            --engine "$VECTOR_ENGINE" --dataset "$SEARCHBENCH_VECTOR_DATASET" \
            --data-dir "$SEARCHBENCH_DATA_DIR" --port "$PGPORT" \
            --target "$VECTOR_TARGET" --k "$VECTOR_K" \
            --search-effort "$VECTOR_SEARCH_EFFORT" --clients "$VECTOR_CLIENTS" \
            --pg-index-type "$VECTOR_PG_INDEX_TYPE" \
            "${rr_arg[@]}" "${nb_arg[@]}" "${nq_arg[@]}" \
            --extra-json "$extra" 2>>"$logfile"); then
            warn "sweep failed for $label — see $logfile; skipping"
            continue
        fi
        [[ -z "$records" ]] && records="[]"

        ALL_RECORDS=$(jq -nc --argjson a "$ALL_RECORDS" --argjson b "$records" '$a + $b')
        write_json "$partial"
        log "    records so far: $(printf '%s' "$ALL_RECORDS" | jq 'length')"
    done < <(build_configs)

    log "==> stop"; ./stop >/dev/null 2>&1 || true
    write_json "$partial"
    cp "$partial" "$SEARCHBENCH_RESULTS"; rm -f "$partial"
    log "wrote $SEARCHBENCH_RESULTS ($(printf '%s' "$ALL_RECORDS" | jq 'length') records)"
}

main "$@"
