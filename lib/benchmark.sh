#!/usr/bin/env bash
# SearchBench shared engine-agnostic driver.
#
# A per-engine ./benchmark.sh sets env vars and exec's this from the engine
# dir, so relative paths (./query, ./start, ...) resolve engine-local.
#
# Adapter contract — scripts next to ./benchmark.sh:
#   ./install      one-time setup (build/install). May no-op.
#   ./start        start daemon (no-op for embedded engines).
#   ./stop         stop daemon.
#   ./check        exit 0 when engine answers queries.
#   ./load         ingest corpus from $SEARCHBENCH_DATA_DIR.
#   ./data-size    print "<bytes>" (data + index footprint).
#   ./query        SQL query on stdin; result on stdout; elapsed seconds on
#                  LAST stderr line; exit 0 on success.
#
# Per-engine env (set before exec):
#   ENGINE_NAME       e.g. "SereneDB"
#   ENGINE_TAGS       JSON array string, e.g. '["C++","SereneDB"]'
#
# Runtime env (operator-supplied):
#   SEARCHBENCH_DATA_DIR     download/load dir (REQUIRED, no default).
#   SEARCHBENCH_DATASET      otel_logs_1b|10b|50b (default 1b)
#   SEARCHBENCH_TRIES        runs per query (default 3: cold, hot, hot)
#   SEARCHBENCH_QUERIES      queries file (default queries.sql; one per line)
#   SEARCHBENCH_RESTART      yes|no — stop+drop_caches+start between queries
#                            (default yes)
#   SEARCHBENCH_SKIP_DOWNLOAD  yes|no — skip corpus fetch (default no; fetch is
#                              idempotent, only skip if data mounted externally).
#   SEARCHBENCH_RESULTS      output JSON path
#                            (default results/<engine>_<dataset>.json).

set -euo pipefail

# ${var,,} lowercasing below needs bash 4+.
(( BASH_VERSINFO[0] >= 4 )) || { echo "ERROR: bash 4+ required" >&2; exit 1; }

: "${ENGINE_NAME:?ENGINE_NAME must be set by the per-engine benchmark.sh}"
: "${ENGINE_TAGS:=[\"$ENGINE_NAME\"]}"
: "${SEARCHBENCH_DATASET:=otel_logs_1b}"
# Required root dir, no $HOME fallback. Each scale gets its own subdir
# (.../<dataset>) so a smoke slice never clobbers a full part_000.parquet and
# scales never share files. Download writes part_*.parquet here; ./load reads it.
: "${SEARCHBENCH_DATA_DIR:?SEARCHBENCH_DATA_DIR must be set to a root data directory (no default)}"
SEARCHBENCH_DATA_DIR="${SEARCHBENCH_DATA_DIR%/}/${SEARCHBENCH_DATASET}"
: "${SEARCHBENCH_TRIES:=3}"
: "${SEARCHBENCH_QUERIES:=queries.sql}"
# Per-try wall-clock ceiling (seconds). A ./query launch running longer is
# killed and its latency rounded up to the ceiling, so one pathological query
# can't stall the run for minutes. Capped value is a real number so the UI shows
# it as the (slowest) latency. 0 disables; default 60. Once a try hits the cap,
# run_one_query skips remaining tries (a timed-out try won't get faster) — see
# below. Keep ui/index.html's TIMEOUT_CAP in sync so the UI flags capped cells.
: "${SEARCHBENCH_QUERY_TIMEOUT:=60}"
# Smoke scales (100k/1m/100m) validate plumbing, not cold-vs-hot perf: download
# slices a bounded corpus prefix to a small part_000.parquet (lib/download-otel-logs).
case "$SEARCHBENCH_DATASET" in
    otel_logs_100k|otel_logs_1m|otel_logs_100m) is_smoke=yes ;;
    *)                                          is_smoke=no  ;;
esac

# Smoke skips the stop+flush+start cycle by default; real datasets keep it.
if [[ "$is_smoke" == "yes" ]]; then
    : "${SEARCHBENCH_RESTART:=no}"
else
    : "${SEARCHBENCH_RESTART:=yes}"
fi
: "${SEARCHBENCH_SKIP_DOWNLOAD:=no}"
# Min bytes on disk for a successful load: 5 GB for real (1B+) scales, ~0 for
# smoke. Override explicitly; 0 disables the guard.
if [[ "$is_smoke" == "yes" ]]; then
    : "${SEARCHBENCH_MIN_DATA_SIZE:=0}"
else
    : "${SEARCHBENCH_MIN_DATA_SIZE:=5000000000}"
fi
# --- CLI options from "$@" (forwarded by each engine's benchmark.sh) ---------
#   --index            full load + index build (else query-only). Env: SEARCHBENCH_INDEX.
#   --version <label>  named version: folded into `system` -> "<Engine>
#                      (<label>)" (own UI column) and into the results filename
#                      so versions don't overwrite. Env: SEARCHBENCH_VERSION.
#                      Supports "--version L" and "--version=L".
#   --explain          capture EXPLAIN plans (adapters with ./explain, currently
#                      SereneDB) into results `explains[]`, shown in UI panel.
#   --explain-analyze  same via ./explain-analyze into `explain_analyzes[]` (real
#                      per-operator timings, extra run per query); UI prefers it.
#                      Env: SEARCHBENCH_EXPLAIN, SEARCHBENCH_EXPLAIN_ANALYZE.
DO_INDEX=no
[[ "${SEARCHBENCH_INDEX:-}" =~ ^(1|yes|true|on)$ ]] && DO_INDEX=yes
DO_EXPLAIN=no
[[ "${SEARCHBENCH_EXPLAIN:-}" =~ ^(1|yes|true|on)$ ]] && DO_EXPLAIN=yes
DO_EXPLAIN_ANALYZE=no
[[ "${SEARCHBENCH_EXPLAIN_ANALYZE:-}" =~ ^(1|yes|true|on)$ ]] && DO_EXPLAIN_ANALYZE=yes
: "${SEARCHBENCH_VERSION:=}"
# Did the operator NAME a version, or is one about to be derived from the query
# dialect below? The distinction matters for load records: "9.3.2" or a SereneDB
# branch is a different index build, whereas "dsl" vs "esql" is two dialects over
# ONE build. Only an operator-supplied version implies a separate build.
_version_explicit=no
[[ -n "$SEARCHBENCH_VERSION" ]] && _version_explicit=yes
_bargs=("$@")
for (( _bi=0; _bi<${#_bargs[@]}; _bi++ )); do
    case "${_bargs[_bi]}" in
        --index)           DO_INDEX=yes ;;
        --explain)         DO_EXPLAIN=yes ;;
        --explain-analyze) DO_EXPLAIN_ANALYZE=yes ;;
        --version)         SEARCHBENCH_VERSION="${_bargs[_bi+1]:-}"; _bi=$((_bi+1)); _version_explicit=yes ;;
        --version=*)       SEARCHBENCH_VERSION="${_bargs[_bi]#--version=}"; _version_explicit=yes ;;
    esac
done

# Multi-dialect adapters: when an engine ships more than one queries.* file, the
# extension of the one actually being run IS the variant slug. That way each
# column states which dialect produced it ("Elasticsearch (dsl)" vs
# "Elasticsearch (esql)") and each variant lands in its own results file instead
# of silently overwriting the other. Single-dialect engines stay unlabelled --
# "Postgres" needs no "(sql)" because there is nothing to disambiguate.
# ui/build maps a results filename back to its query file by this same
# convention, so the two stay in step. An explicit --version always wins.
if [[ -z "$SEARCHBENCH_VERSION" ]]; then
    _qfiles=()
    for _q in queries.*; do
        [[ -f "$_q" && "$_q" != *.bak* ]] && _qfiles+=("$_q")
    done
    if (( ${#_qfiles[@]} > 1 )); then
        SEARCHBENCH_VERSION="${SEARCHBENCH_QUERIES##*.}"
    fi
fi

# Column identity + results path. --version label -> distinct UI column and
# distinct results file (so old/new coexist).
if [[ -n "$SEARCHBENCH_VERSION" ]]; then
    DISPLAY_SYSTEM="${ENGINE_NAME} (${SEARCHBENCH_VERSION})"
    _vslug=$(printf '%s' "$SEARCHBENCH_VERSION" | tr -c 'A-Za-z0-9._-' '_')
    : "${SEARCHBENCH_RESULTS:=results/${ENGINE_NAME,,}_${_vslug}_${SEARCHBENCH_DATASET}.json}"
else
    DISPLAY_SYSTEM="$ENGINE_NAME"
    : "${SEARCHBENCH_RESULTS:=results/${ENGINE_NAME,,}_${SEARCHBENCH_DATASET}.json}"
fi

# --- index-build identity: where load_time/data_size live --------------------
# Those two numbers describe an INDEX BUILD, not a query run, so they get their
# own file rather than being copied into every variant's results JSON. One
# writer (a --index run), many readers -- so adding a query variant can neither
# lose the number nor silently duplicate it against a different build.
#
#   results/load/<dataset>.json            the engine's default build
#   results/load/<dataset>.<build>.json    a named build, for side-by-side runs
#
# SEARCHBENCH_BUILD names the build. It defaults to an operator-supplied
# --version (ES image tag, SereneDB branch, a tuning label -- all genuinely
# different indexes) but NOT to an auto-derived query dialect, because dsl and
# esql share one index and must therefore share one load record.
: "${SEARCHBENCH_BUILD:=}"
if [[ -z "$SEARCHBENCH_BUILD" && "$_version_explicit" == yes ]]; then
    SEARCHBENCH_BUILD="$SEARCHBENCH_VERSION"
fi
LOAD_DIR="results/load"
LOAD_DEFAULT="${LOAD_DIR}/${SEARCHBENCH_DATASET}.json"
if [[ -n "$SEARCHBENCH_BUILD" ]]; then
    _bslug=$(printf '%s' "$SEARCHBENCH_BUILD" | tr -c 'A-Za-z0-9._-' '_')
    LOAD_RECORD="${LOAD_DIR}/${SEARCHBENCH_DATASET}.${_bslug}.json"
else
    LOAD_RECORD="$LOAD_DEFAULT"
fi

export SEARCHBENCH_DATA_DIR SEARCHBENCH_DATASET

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] [INFO]  %s\n' "$(ts)" "$*" >&2; }
warn() { printf '[%s] [WARN]  %s\n' "$(ts)" "$*" >&2; }
die()  { printf '[%s] [ERROR] %s\n' "$(ts)" "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required binary: $1"; }
require jq

check_loop() {
    local i
    for i in $(seq 1 60); do
        ./check >/dev/null 2>&1 && return 0
        sleep 1
    done
    die "./check did not succeed within 60s"
}

# Wait until ./check fails — daemon really gone, not just told to stop.
# mmap-backed engines pin pagecache until the process exits, so drop_caches
# has no effect before that.
wait_stopped() {
    local i
    for i in $(seq 1 60); do
        ./check >/dev/null 2>&1 || return 0
        sleep 1
    done
    warn "engine did not stop within 60s; proceeding anyway"
    return 0
}

flush_caches() {
    sync
    if [[ -w /proc/sys/vm/drop_caches ]]; then
        echo 3 > /proc/sys/vm/drop_caches
    elif sudo -n true 2>/dev/null; then
        echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null
    else
        # Can't flush — cold tries run hot, but smoke/dev still work without sudo.
        warn "cannot drop /proc/sys/vm/drop_caches (no root, no NOPASSWD sudo) — cold tries will run hot"
    fi
}

cold_cycle() {
    if [[ "$SEARCHBENCH_RESTART" != "yes" ]]; then
        flush_caches
        return 0
    fi
    ./stop >/dev/null 2>&1 || true
    wait_stopped
    flush_caches
    ./start >/dev/null 2>&1 || true
    check_loop
}

# Last bare-numeric line from ./query's stderr -- the client-reported latency
# (psql \timing / curl %{time_total}). `|| true` keeps it safe under pipefail
# when no numeric line exists (caller substitutes `null` on empty).
parse_timing() {
    printf '%s\n' "$1" \
        | tr '\r' '\n' \
        | grep -E '^[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*$' \
        | tail -n1 \
        | tr -d '[:space:]' || true
}

run_one_query() {
    local query="$1" qnum="$2"
    local i raw timing rows="-" err_out=""
    local results=()
    local stdout_file
    stdout_file=$(mktemp)

    cold_cycle

    for i in $(seq 1 "$SEARCHBENCH_TRIES"); do
        # Result rows (stdout) -> file; stderr -> $raw (timing + row-count tag).
        # Tries are identical so $stdout_file holds the last try's result.
        # Latency = client-reported time on ./query's last stderr line
        # (psql \timing / curl %{time_total}), extracted by parse_timing.
        # Cap each launch at SEARCHBENCH_QUERY_TIMEOUT: `timeout` sends SIGTERM
        # at the ceiling (psql/curl exit, server cancels), SIGKILL 10s later.
        local runner=(./query)
        if [[ "${SEARCHBENCH_QUERY_TIMEOUT:-0}" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
            runner=(timeout -k 10 "${SEARCHBENCH_QUERY_TIMEOUT}s" ./query)
        fi
        local rc
        if raw=$(printf '%s\n' "$query" | "${runner[@]}" 2>&1 1>"$stdout_file"); then
            timing=$(parse_timing "$raw")
            [[ -z "$timing" ]] && timing="null"
            # Prefer exact row count from ./query's SEARCHBENCH_ROWS=<n> stderr
            # tag; else count output lines (approx if a field has newlines).
            rows=$(printf '%s\n' "$raw" \
                | grep -oE 'SEARCHBENCH_ROWS=[0-9]+' | tail -n1 | cut -d= -f2)
            # grep -c prints 0 but exits 1 on empty; `|| rows=0` normalizes the
            # exit, doesn't append a second number.
            if [[ -z "$rows" ]]; then
                rows=$(grep -c '' "$stdout_file" 2>/dev/null) || rows=0
            fi
        elif rc=$?; [[ "${SEARCHBENCH_QUERY_TIMEOUT:-0}" -gt 0 && ( $rc -eq 124 || $rc -eq 137 ) ]]; then
            # timeout(1): 124 = SIGTERM at ceiling, 137 = escalated to SIGKILL;
            # either way over the cap. Record the ceiling as latency, not null.
            timing="$SEARCHBENCH_QUERY_TIMEOUT"
            rows="timeout"
            warn "Q${qnum} try ${i}: exceeded ${SEARCHBENCH_QUERY_TIMEOUT}s — killed; recording ${SEARCHBENCH_QUERY_TIMEOUT}s (capped)"
        else
            timing="null"
            rows="err"
            err_out="$raw"
            printf '%s\n' "$raw" >&2
        fi
        results+=("$timing")

        # A capped try won't get faster on retry; don't burn TRIES * cap. Pad
        # remaining tries with the cap (keeps SEARCHBENCH_TRIES entries, renders
        # as timed-out) and stop. Triggered by any try.
        if [[ "$rows" == "timeout" ]]; then
            while (( ${#results[@]} < SEARCHBENCH_TRIES )); do
                results+=("$SEARCHBENCH_QUERY_TIMEOUT")
            done
            warn "Q${qnum}: cap hit on try ${i} — skipping the remaining tries"
            break
        fi
    done

    # Append full result (or error) to the query-output log.
    if [[ -n "${QUERY_LOG:-}" ]]; then
        {
            printf '===== Q%s (rows: %s) =====\n%s\n----- result -----\n' \
                "$qnum" "$rows" "$query"
            if [[ "$rows" == "err" ]]; then
                printf '%s\n' "$err_out"
            else
                cat "$stdout_file"
            fi
            printf '\n'
        } >> "$QUERY_LOG"
    fi
    rm -f "$stdout_file"
    log "    Q${qnum}: rows=${rows} (full result -> ${QUERY_LOG##*/})"

    local out="[" j
    for j in "${!results[@]}"; do
        out+="${results[$j]}"
        [[ "$j" -lt $((${#results[@]} - 1)) ]] && out+=","
    done
    out+="]"
    printf '%s' "$out"
}

get_version() {
    [[ -x ./version ]] && (./version 2>/dev/null || echo unknown) || echo unknown
}

get_os_name() {
    if [[ -r /etc/os-release ]]; then
        awk -F= '$1=="PRETTY_NAME" { gsub(/"/, "", $2); print $2 }' /etc/os-release
    else
        uname -sr
    fi
}

# Assemble results JSON to $1 from main()'s (possibly partial) accumulators.
# Called after load and after EVERY query so a mid-run crash leaves valid JSON
# (main writes .partial.json, copies to final only at the end). Reads main()'s
# locals via dynamic scoping. `explains` only when --explain is on.
# Persist an index build's cost to its own file (see LOAD_RECORD above), with
# enough provenance to tell two builds apart after the fact. Deliberately no
# absolute paths: these records are committed to a public repo, and the corpus
# root is operator-specific noise -- `dataset` already says which corpus it was.
write_load_record() {
    local secs="$1" size="$2" ver="$3" os="$4" day="$5"
    mkdir -p "$LOAD_DIR"
    jq -n --arg engine   "$ENGINE_NAME"           --arg dataset "$SEARCHBENCH_DATASET" \
          --arg build    "${SEARCHBENCH_BUILD:-}" --arg ev      "$ver" \
          --arg os       "$os"                    --arg date    "$day" \
          --arg loaded_by "$SEARCHBENCH_QUERIES" \
          --argjson load_time "$secs"             --argjson data_size "$size" \
          '{engine:$engine, dataset:$dataset, build:$build, engine_version:$ev,
            load_time:$load_time, data_size:$data_size,
            os:$os, date:$date, loaded_by:$loaded_by}' \
        > "$LOAD_RECORD"
    log "load record -> $LOAD_RECORD"
}

# Read back a build's cost. Prefer this build's own record; fall back to the
# engine's default build, which is the case that matters for a query-only
# variant (esql over the index dsl built). Echoes "<load_time> <data_size>".
read_load_record() {
    local f
    for f in "$LOAD_RECORD" "$LOAD_DEFAULT"; do
        [[ -f "$f" ]] || continue
        local lt ds
        lt=$(jq -c '.load_time // null' "$f" 2>/dev/null || echo null)
        ds=$(jq -c '.data_size // null' "$f" 2>/dev/null || echo null)
        [[ "$lt" == "null" ]] && continue
        log "load record: inherited load_time=${lt}s data_size=${ds} bytes from ${f#results/}"
        printf '%s %s' "$lt" "$ds"
        return 0
    done
    return 1
}

write_json() {
    local target="$1"
    local rj="${result_json}"$'\n    ]'
    local qj="${qtags_json}"$'\n    ]'
    # Encode only small scalars with jq (tiny argv). Big prebuilt arrays
    # (result/query_tags/explains) go via printf (builtin, no ARG_MAX limit) --
    # `jq --argjson` on 92 multiline EXPLAIN plans overflowed the command line.
    local sys ver os dt dset
    sys=$(jq -n --arg s "$DISPLAY_SYSTEM"       '$s')
    ver=$(jq -n --arg s "$version"              '$s')
    os=$(jq  -n --arg s "$os_name"              '$s')
    dt=$(jq  -n --arg s "$date_str"             '$s')
    dset=$(jq -n --arg s "$SEARCHBENCH_DATASET" '$s')
    {
        printf '{\n'
        printf '  "system": %s,\n'    "$sys"
        printf '  "version": %s,\n'   "$ver"
        printf '  "os": %s,\n'        "$os"
        printf '  "date": %s,\n'      "$dt"
        printf '  "dataset": %s,\n'   "$dset"
        printf '  "tags": %s,\n'      "$ENGINE_TAGS"
        printf '  "load_time": %s,\n' "$load_secs"
        printf '  "data_size": %s,\n' "$data_size"
        printf '  "result": %s,\n'    "$rj"
        printf '  "query_tags": %s'   "$qj"      # no trailing comma; optionals prepend ",\n"
        [[ "$DO_EXPLAIN" == yes ]] && \
            printf ',\n  "explains": %s'         "${explains_json}"$'\n    ]'
        [[ "$DO_EXPLAIN_ANALYZE" == yes ]] && \
            printf ',\n  "explain_analyzes": %s' "${explain_analyzes_json}"$'\n    ]'
        printf '\n}\n'
    } > "$target"
}

main() {
    log "engine            : $ENGINE_NAME"
    [[ -n "$SEARCHBENCH_VERSION" ]] && log "version (--version): $SEARCHBENCH_VERSION  -> column '$DISPLAY_SYSTEM'"
    log "dataset           : $SEARCHBENCH_DATASET"
    log "data dir          : $SEARCHBENCH_DATA_DIR"
    log "queries           : $SEARCHBENCH_QUERIES"
    log "tries/query       : $SEARCHBENCH_TRIES"
    log "timing            : client round-trip (psql \\timing / curl %{time_total})"
    log "restart between qs: $SEARCHBENCH_RESTART"
    log "results file      : $SEARCHBENCH_RESULTS"

    [[ -f "$SEARCHBENCH_QUERIES" ]] || die "queries file not found: $SEARCHBENCH_QUERIES"

    # ---- load + index build: gated by --index (or SEARCHBENCH_INDEX=1) ---------
    # ON  -> full pipeline: install, (re)start, download, load, measure
    #        load_time + data_size, partial guard.
    # OFF -> query-only: (re)start the loaded engine and carry over
    #        load_time/data_size from the existing results file (don't clobber).
    # ./install runs BEFORE ./start (some adapters wipe+recreate the container in
    # install); skipping it in query-only mode preserves the data.
    local do_index="$DO_INDEX"   # from --index / SEARCHBENCH_INDEX
    log "mode              : $([[ $do_index == yes ]] && echo 'LOAD + INDEX (--index)' || echo 'query-only (read already-indexed)')"

    if [[ "$do_index" == yes ]]; then
        log "==> install"
        ./install
    fi

    log "==> start"
    ./start >/dev/null 2>&1 || true
    check_loop

    # Determined before the load so the load record can carry it: which engine
    # build actually produced these numbers.
    local version os_name date_str
    version=$(get_version)
    os_name=$(get_os_name)
    date_str=$(date +%F)
    log "version: $version  os: $os_name  date: $date_str"
    [[ -n "$SEARCHBENCH_BUILD" ]] && log "build label       : $SEARCHBENCH_BUILD"

    local load_secs data_size
    if [[ "$do_index" == yes ]]; then
        if [[ "$SEARCHBENCH_SKIP_DOWNLOAD" != "yes" ]]; then
            log "==> download corpus"
            "${LIB_DIR}/download-otel-logs"
        fi

        log "==> load"
        local load_start load_end
        load_start=$(date +%s.%N)
        ./load
        sync
        load_end=$(date +%s.%N)
        load_secs=$(awk -v s="$load_start" -v e="$load_end" 'BEGIN{printf "%.3f", e-s}')
        log "load time: ${load_secs}s"

        data_size=$(./data-size)
        log "data size: ${data_size} bytes"

        # Guard silent partial loads (OOM-killed COPY, broken glob). 1B+ rows
        # are well above 5 GB on disk.
        if [[ "$SEARCHBENCH_MIN_DATA_SIZE" -gt 0 && "$data_size" -lt "$SEARCHBENCH_MIN_DATA_SIZE" ]]; then
            die "data size ${data_size} bytes < min ${SEARCHBENCH_MIN_DATA_SIZE}; treating as partial load"
        fi

        # This run built the index, so it owns the record.
        write_load_record "$load_secs" "$data_size" "$version" "$os_name" "$date_str"
    else
        # Query-only: this run built nothing, so it inherits the build's cost from
        # the load record rather than scavenging another variant's results file.
        local _lr
        if _lr=$(read_load_record); then
            load_secs="${_lr%% *}"
            data_size="${_lr##* }"
        else
            load_secs=null; data_size=null
            warn "no load record under ${LOAD_DIR}/ for ${SEARCHBENCH_DATASET}${SEARCHBENCH_BUILD:+ (build $SEARCHBENCH_BUILD)}; writing null load_time/data_size"
        fi
    fi

    mkdir -p "$(dirname "$SEARCHBENCH_RESULTS")"

    # Full per-query rows dumped here (one section each). Global so run_one_query
    # sees it. Override with SEARCHBENCH_QUERY_LOG.
    QUERY_LOG="${SEARCHBENCH_QUERY_LOG:-${SEARCHBENCH_RESULTS%.json}.results.log}"
    : > "$QUERY_LOG"
    log "query results -> $QUERY_LOG"

    # query_tags[] parallels result[]: {id,task,filter,freq} parsed from each
    # query's preceding `-- QNN task=... ...` tag (empty if none). The id lets
    # the UI align rows across engines that omit queries (e.g. OpenSearch joins).
    local result_json="[" first=1 qnum=1
    local qtags_json="[" qtfirst=1
    local explains_json="[" exfirst=1
    local explain_analyzes_json="[" exafirst=1
    local tg_id="" tg_task="" tg_filter="" tg_freq=""

    # Crash-safety: build JSON in .partial.json, rewrite after load and every
    # query, copy to final only at the end. A mid-run death leaves the partial.
    local partial="${SEARCHBENCH_RESULTS%.json}.partial.json"
    [[ "$DO_EXPLAIN" == yes ]] && [[ ! -x ./explain ]] && \
        warn "--explain set but no ./explain in this adapter; skipping explains"
    [[ "$DO_EXPLAIN_ANALYZE" == yes ]] && [[ ! -x ./explain-analyze ]] && \
        warn "--explain-analyze set but no ./explain-analyze in this adapter; skipping"
    write_json "$partial"        # post-load snapshot (no results yet)

    while IFS= read -r query; do
        # Tag line "-- Q42 task=join filter=term freq=hi": stash for the next
        # query, skip. Non-tag `--` lines fall through to the plain skip below.
        if [[ "$query" =~ ^[[:space:]]*--.*task= ]]; then
            # `|| true`: a tag may omit a field (e.g. Q56 has no freq=); a
            # failing grep under set -e/pipefail would otherwise abort.
            tg_id=$(printf '%s' "$query"     | grep -oE 'Q[0-9]+'         | head -1 || true)
            tg_task=$(printf '%s' "$query"   | grep -oE 'task=[a-z_]+'    | cut -d= -f2 || true)
            tg_filter=$(printf '%s' "$query" | grep -oE 'filter=[a-z,_]+' | cut -d= -f2 || true)
            tg_freq=$(printf '%s' "$query"   | grep -oE 'freq=[a-z]+'     | cut -d= -f2 || true)
            continue
        fi
        [[ -z "${query// }" ]] && continue
        [[ "$query" =~ ^[[:space:]]*-- ]] && continue
        log "==> Q${qnum}: ${query:0:80}..."
        local row
        row=$(run_one_query "$query" "$qnum")
        log "    Q${qnum} runs: $row"
        [[ $first -eq 0 ]] && result_json+=","
        first=0
        result_json+=$'\n        '"$row"
        [[ $qtfirst -eq 0 ]] && qtags_json+=","
        qtfirst=0
        qtags_json+=$'\n        '"$(jq -nc --arg id "$tg_id" --arg task "$tg_task" --arg filter "$tg_filter" --arg freq "$tg_freq" '{id:$id,task:$task,filter:$filter,freq:$freq}')"
        tg_id=""; tg_task=""; tg_filter=""; tg_freq=""

        # --explain: capture plan via ./explain (if present). Parallel to
        # result[]; separate call, doesn't affect recorded timing.
        if [[ "$DO_EXPLAIN" == yes ]]; then
            local exq=""
            [[ -x ./explain ]] && exq=$(printf '%s\n' "$query" | ./explain 2>&1 || true)
            [[ $exfirst -eq 0 ]] && explains_json+=","
            exfirst=0
            explains_json+=$'\n        '"$(jq -n --arg s "$exq" '$s')"
        fi
        # --explain-analyze: same but EXPLAIN ANALYZE (re-runs query). Stored
        # separately; UI prefers it over the plain plan.
        if [[ "$DO_EXPLAIN_ANALYZE" == yes ]]; then
            local exaq=""
            [[ -x ./explain-analyze ]] && exaq=$(printf '%s\n' "$query" | ./explain-analyze 2>&1 || true)
            [[ $exafirst -eq 0 ]] && explain_analyzes_json+=","
            exafirst=0
            explain_analyzes_json+=$'\n        '"$(jq -n --arg s "$exaq" '$s')"
        fi

        qnum=$((qnum + 1))
        write_json "$partial"    # flush after each query (crash-safe)
    done < "$SEARCHBENCH_QUERIES"

    # Optional adapter hook: runs once after all queries while the engine is
    # still up (a restart would reset in-memory stats). SereneDB uses it to
    # dump `select * from sdb_metrics` into sdb_metrics.txt.
    if [[ -x ./post-queries ]]; then
        log "==> post-queries"
        ./post-queries || warn "post-queries failed (ignored)"
    fi

    log "==> stop"
    ./stop >/dev/null 2>&1 || true

    # Final assembly -> partial, then promote to the real file. Copy-last means
    # an interrupted run never leaves a truncated results file.
    write_json "$partial"
    cp "$partial" "$SEARCHBENCH_RESULTS"
    rm -f "$partial"
    log "wrote $SEARCHBENCH_RESULTS"
}

main "$@"
