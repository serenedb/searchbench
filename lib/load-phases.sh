# Load-phase accounting shared by adapters whose index keeps merging after the
# data is in (Quickwit, ClickHouse). Source it from ./load:
#
#   source ../lib/load-phases.sh
#   phases_start "<command printing the number of merges running now>"
#   ... ingest ...                        ; phases_mark ingest_end [<epoch>]
#   ... settle detection (overhead)       ; phases_mark merges_start
#   ... merges finish                     ; phases_mark merges_end [<epoch>]
#   phases_finish <check_seconds>         # writes $SEARCHBENCH_LOAD_PHASES_FILE
#
# Reported, in seconds of wall clock from the start of ./load. ingest + merge_after
# + check add up to the load (minus schema setup), with no overlap:
#   ingest      -> until the data is in and searchable (INSERT returned /
#                  documents committed)
#   merge_after -> after that, until merges stop (settle windows excluded)
#   check       -> settle-detection windows: measurement overhead, the engine
#                  was already idle
#   merge_busy  -> time with >= 1 merge running over the whole load, including
#                  merges that overlap ingestion (Quickwit merges while it
#                  ingests, which merge_after cannot show)
#   merge_work  -> sum of (merges running x sample interval): merge-thread
#                  seconds, a proxy for total merge work
#   samples / failed_samples -> a failed sample is NOT counted as "0 merges"
# Sampling: every PHASES_SAMPLE_SECS (5s), in the background.

phases_now() { date +%s.%N; }

phases_start() {
    _PH_T0=$(phases_now)
    _PH_SAMPLES=$(mktemp)
    _PH_CMD="$1"
    ( trap 'exit 0' TERM
      while :; do
          out=$(eval "$_PH_CMD" 2>/dev/null) && [[ "$out" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]] \
              && echo "$(phases_now) ${BASH_REMATCH[1]}" || echo "$(phases_now) fail"
          sleep "${PHASES_SAMPLE_SECS:-5}"
      done ) >> "$_PH_SAMPLES" &
    _PH_PID=$!
}

# phases_mark <name> [epoch]  -- defaults to now
phases_mark() { local v="${2:-$(phases_now)}"; printf -v "_PH_$1" '%s' "$v"; }

phases_finish() {
    local check="${1:-0}"
    [[ -n "${_PH_PID:-}" ]] && { kill "$_PH_PID" 2>/dev/null; wait "$_PH_PID" 2>/dev/null; }
    if [[ -z "${SEARCHBENCH_LOAD_PHASES_FILE:-}" ]]; then rm -f "$_PH_SAMPLES"; return 0; fi
    local ie="${_PH_ingest_end:-$_PH_T0}" ms="${_PH_merges_start:-${_PH_ingest_end:-$_PH_T0}}"
    local me="${_PH_merges_end:-$ms}"
    awk -v t0="$_PH_T0" -v ie="$ie" -v ms="$ms" -v me="$me" -v chk="$check" -v dt="${PHASES_SAMPLE_SECS:-5}" '
        $2 == "fail" { failed++; next }
        { n++; if ($2 > 0) { busy += dt; work += $2 * dt } }
        END {
            ingest = ie - t0; after = me - ms; if (after < 0) after = 0
            printf "{\"ingest\":%.1f,\"merge_after\":%.1f,\"check\":%.1f,\"merge_busy\":%.1f,\"merge_work\":%.1f,\"samples\":%d,\"failed_samples\":%d,\"sample_secs\":%s}\n",
                   ingest, after, chk, busy, work, n, failed, dt }' "$_PH_SAMPLES" > "$SEARCHBENCH_LOAD_PHASES_FILE"
    echo "[load] phases: $(cat "$SEARCHBENCH_LOAD_PHASES_FILE")"
    rm -f "$_PH_SAMPLES"
}
