# Sourced by both ./start and ./load. Explicit QW_* overrides still win.
# Leave other datasets on the adapter defaults.
# This process-wide Quickwit flag must be set before the server/CLI starts.
# On by default for every dataset (measured +21% at 100M); set false to opt out.
: "${QW_ENABLE_IN_MEMORY_INDEXING:=true}"
export QW_ENABLE_IN_MEMORY_INDEXING
case "$QW_ENABLE_IN_MEMORY_INDEXING" in
    true|false) ;;
    *) echo "QW_ENABLE_IN_MEMORY_INDEXING must be true or false" >&2; return 1 ;;
esac
if [[ "${SEARCHBENCH_DATASET:-otel_logs_1b}" == otel_logs_100m ]]; then
    : "${QW_SPLIT_NUM_DOCS:=1000000}"
    : "${QW_MIN_SHARDS:=64}"
    : "${QW_VALIDATE_DOCS:=off}"
    : "${QW_COMMIT_TIMEOUT_SECS:=30}"
    : "${QW_MERGE_POLICY:=stable_log}"
fi
