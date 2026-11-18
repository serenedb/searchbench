#!/usr/bin/env bash
# HOST. m8gd.4xlarge, index on S3, instance-store NVMe for corpus + WAL: the published Datadog BYOC setup.
# Quickwit main ce4b23e (built in setup.sh) through the ingest API, same settings at every scale, $DATASETS in order.
#   0) smoke: one 1B row group, local disk, exact count, clustering + in-memory indexing active.
#   per scale: corpus to the data volume (size + ETag) -> load (empty query file; exact count, merges settled)
#              -> $ROUNDS query-only rounds (restart + page-cache drop per query, 3 tries, 60 s cap)
#              -> recent-query ground truth (lib/check_recent.py) -> evidence pushed to S3.
# A failed scale is recorded and the next one still runs.
# Second pass (production-2): SKIP_SMOKE=yes, REUSE_LOAD_SCALES lists scales whose S3 index (and load
# records in $E/<ds>/load-records) are reused (query rounds only), EVIDENCE_SUFFIX names the rounds' dir.
set -Eeuo pipefail
cd /srv/qw
source ./run.env
source ./remote.env
E=/srv/qw/evidence
P=$E/progress.log
note() { echo "$(date -u +%FT%TZ) $*" | tee -a "$P"; }
push() { timeout 900 aws s3 sync --only-show-errors "$E" "s3://$BUCKET/${S3_PREFIX}evidence/" || true; }
REPO=/srv/qw/source
cd "$REPO/quickwit"
mkdir -p results/load
: > "$E/empty.queries"
stopall() { docker ps -q | xargs -r docker stop -t 60 >/dev/null 2>&1 || true; }
save_container() {   # $1 container, $2 dest dir
    docker logs --timestamps "$1" > "$2/server.log" 2>&1 || true
    docker inspect "$1" > "$2/container.json" 2>&1 || true
}
sampler() {   # $1 out file, $2 container: every 10 s ingest/indexing counters, open shards, memory
    while sleep 10; do
        m=$(curl -fsS --max-time 5 http://127.0.0.1:7280/metrics 2>/dev/null | awk '
            /^quickwit_ingest_docs_total/ {i+=$NF} /^quickwit_indexing_processed_docs_total.*valid/ {p+=$NF}
            /^quickwit_indexing_published_split_docs_total/ {s+=$NF} /^quickwit_ingest_shards\{.*state="open"/ {o+=$NF}
            END {printf "%d %d %d open_shards=%d", i, p, s, o}')
        mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$2" 2>/dev/null | awk '{print $1}')
        echo "$(date +%s) ${m:-?} ${mem:-?} $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) $(df -B1 --output=used $DATA_MNT | tail -1)"
    done > "$1"
}

: "${SKIP_SMOKE:=no}" "${REUSE_LOAD_SCALES:=}" "${EVIDENCE_SUFFIX:=}"
# ---------- 0) smoke ----------
if [[ $SKIP_SMOKE != yes ]]; then
note "smoke start"
S=$E/smoke; mkdir -p "$S"
SMK=$DATA_MNT/corpus-smoke/otel_logs_1b; mkdir -p "$SMK"
aws s3api head-object --bucket "$BUCKET" --key searchbench/data/otel_logs_1b/part_000.parquet > "$S/corpus-head.json"
# First row group only (range read via pyarrow's S3 filesystem: no full download for the smoke).
$SEARCHBENCH_PYTHON - "$SMK/part_000.parquet" "$BUCKET" <<'PY'
import sys, pyarrow.parquet as pq, pyarrow.fs as fs
f = fs.S3FileSystem(region="us-east-1")
t = pq.ParquetFile(f.open_input_file(sys.argv[2] + "/searchbench/data/otel_logs_1b/part_000.parquet")).read_row_group(0)
pq.write_table(t, sys.argv[1], row_group_size=t.num_rows, compression="zstd"); print("smoke rows", t.num_rows)
PY
smoke_rows=$($SEARCHBENCH_PYTHON -c "import pyarrow.parquet as pq;print(pq.ParquetFile('$SMK/part_000.parquet').metadata.num_rows)")
( export QW_STORAGE=local QW_CONTAINER=searchbench-qw-smoke QW_DATA_DIR=$DATA_MNT/qw-smoke QW_MERGE_POLICY=no_merge QW_WAIT_MERGES=no
  export SEARCHBENCH_DATASET=otel_logs_1b SEARCHBENCH_DATA_DIR=$SMK
  ./install > "$S/install.log" 2>&1
  ./start > "$S/start.log" 2>&1; echo "start rc=$?" >> "$S/start.log"
  ./load > "$S/load.log" 2>&1; echo "load rc=$?" >> "$S/load.log"
  curl -fsS http://127.0.0.1:7280/api/v1/version > "$S/version.json" || true
  save_container "$QW_CONTAINER" "$S"
  docker rm -f "$QW_CONTAINER" >/dev/null 2>&1; true )
ok=1
grep -q '^start rc=0$' "$S/start.log" || ok=0
grep -q '^load rc=0$' "$S/load.log" || ok=0
grep -q "otel_logs documents=${smoke_rows}\$" "$S/load.log" || ok=0
jq -e --arg rev "$QW_EXPECTED_REVISION" '(.build // .).commit_hash == $rev' "$S/version.json" >/dev/null || ok=0
grep -Eq 'docs_clustering(_config)?: Some\(' "$S/server.log" || ok=0   # NodeConfig dump at startup
jq -e '.[0].Config.Env | index("QW_ENABLE_IN_MEMORY_INDEXING=true")' "$S/container.json" >/dev/null || ok=0
jq -e '.[0].Config.Env | index("QW_DISABLE_DOCUMENT_VALIDATION=true")' "$S/container.json" >/dev/null || ok=0
(( ok == 1 )) || { note "SMOKE FAILED"; push; exit 1; }
rm -rf $DATA_MNT/qw-smoke $DATA_MNT/corpus-smoke
note "smoke ok (${smoke_rows} docs)"; push
fi

# ---------- per scale ----------
fetch_corpus() {   # $1 dataset -> $SEARCHBENCH_DATA_ROOT/$1/part_*.parquet, each checked against S3 size + ETag
    local ds=$1 dir=$SEARCHBENCH_DATA_ROOT/$1 k
    mkdir -p "$dir"
    aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "searchbench/data/$ds/part_" --no-paginate > "$E/$ds$EVIDENCE_SUFFIX/corpus-listing.json"
    local t0=$(date +%s)
    for k in $(jq -r '.Contents[].Key' "$E/$ds$EVIDENCE_SUFFIX/corpus-listing.json"); do
        aws s3 cp --only-show-errors "s3://$BUCKET/$k" "$dir/${k##*/}"
    done
    local t1=$(date +%s)
    jq -c '.Contents[] | [.Key, .Size, .ETag]' "$E/$ds$EVIDENCE_SUFFIX/corpus-listing.json" | while read -r row; do
        k=$(jq -r '.[0]' <<<"$row"); n=$(jq -r '.[1]' <<<"$row"); etag=$(jq -r '.[2]' <<<"$row")
        [[ $(stat -c %s "$dir/${k##*/}") == "$n" ]] || { echo "size mismatch $k"; exit 1; }
        aws s3api head-object --bucket "$BUCKET" --key "$k" | jq -e --arg e "$etag" --argjson n "$n" '.ETag==$e and .ContentLength==$n' >/dev/null
    done
    rows=$($SEARCHBENCH_PYTHON -c "import glob,pyarrow.parquet as pq;print(sum(pq.ParquetFile(f).metadata.num_rows for f in glob.glob('$dir/part_*.parquet')))")
    jq -n --arg ds "$ds" --argjson dl $((t1 - t0)) --argjson rows "$rows" --argjson files "$(jq '.Contents|length' "$E/$ds$EVIDENCE_SUFFIX/corpus-listing.json")" \
        '{dataset:$ds, files:$files, rows:$rows, download_seconds:$dl, size_etag_verified:true}' > "$E/$ds$EVIDENCE_SUFFIX/corpus.json"
    echo "$rows"
}

run_scale() {   # $1 dataset
    local ds=$1 short=${1#otel_logs_}
    local D=$DATA_MNT/qw-$BOX-$short
    local C=searchbench-qw-$BOX-$short
    local BUILD=main-${QW_EXPECTED_REVISION:0:7}-$BOX
    local LE=$E/$ds SE=$E/$ds$EVIDENCE_SUFFIX; mkdir -p "$LE" "$SE"
    local reuse=no; [[ " $REUSE_LOAD_SCALES " == *" $ds "* ]] && reuse=yes
    # lib/benchmark.sh appends the dataset to SEARCHBENCH_DATA_DIR: pass the root, keep the full path in CORPUS.
    export SEARCHBENCH_DATASET=$ds SEARCHBENCH_DATA_DIR=$SEARCHBENCH_DATA_ROOT
    local CORPUS=$SEARCHBENCH_DATA_ROOT/$ds
    export QW_STORAGE=$BOX QW_CONTAINER=$C QW_DATA_DIR=$D
    [[ $BOX == s3 ]] && export QW_S3_ROOT=s3://$BUCKET/${DATA_PREFIX}$short
    note "$ds: corpus fetch"
    local rows; rows=$(fetch_corpus "$ds")
    export EXPECTED_ROWS=$rows
    if [[ $reuse == yes ]]; then
    note "$ds: corpus ok ($rows rows); reusing the S3 index and load records of $LE (build $BUILD)"
    mkdir -p "$D" results/load
    cp -a "$LE/load-records/." results/load/
    ls results/load/*."$BUILD".json >/dev/null
    else
    note "$ds: corpus ok ($rows rows); load (build $BUILD)"
    df -B1 $DATA_MNT > "$LE/df-before-load.txt"
    env | grep -E '^(SEARCHBENCH_|QW_|EXPECTED_ROWS|AWS_REGION)' | sort > "$LE/load-environment.txt"
    sync; echo 3 > /proc/sys/vm/drop_caches
    sampler "$LE/load.samples" "$C" & local smp=$!
    set +e
    SEARCHBENCH_QUERIES=$E/empty.queries SEARCHBENCH_BUILD=$BUILD \
        SEARCHBENCH_RESULTS=$LE/load-run.json \
        bash ./benchmark.sh --index --version "$BUILD" > "$LE/load-benchmark.log" 2>&1
    local brc=$?; set -e
    kill "$smp" 2>/dev/null || true
    df -B1 $DATA_MNT > "$LE/df-after-load.txt"
    docker stop -t 60 "$C" >/dev/null 2>&1 || true
    save_container "$C" "$LE"; mv "$LE/server.log" "$LE/load-server.log"
    cp -a results/load/. "$LE/load-records/" 2>/dev/null || { mkdir -p "$LE/load-records"; cp -a results/load/. "$LE/load-records/"; }
    note "$ds: load rc=$brc"; push
    (( brc == 0 )) || return 1
    # Published splits from the metastore (the load's container is already stopped here).
    if [[ $BOX == s3 ]]; then
        aws s3 cp --only-show-errors "$QW_S3_ROOT/indexes/otel_logs/metastore.json" "$LE/metastore.json" || true
        jq -c '[.splits[] | select(.split_state=="Published")] | {count: length, unit: "splits", docs: (map(.split_metadata.num_docs // .num_docs) | add)}' "$LE/metastore.json" > "$LE/storage-units.json" 2>&1 || true
    fi
    fi
    touch "$D/.searchbench-loaded"   # ./start: searcher + metastore from now on
    local rounds_done=0
    for r in $(seq 1 "$ROUNDS"); do
        # r1 always runs. Later rounds only if a worst case (every query at the 60 s cap, 3 tries, restart
        # included: ~5 h for 92 queries) still ends before the workload cutoff; otherwise recorded, not run.
        if (( r > 1 && WORK_CUTOFF_EPOCH - $(date +%s) < 5 * 3600 )); then
            note "$ds: round $r skipped (budget)"; echo "$ds r$r skipped: $(( (WORK_CUTOFF_EPOCH - $(date +%s)) / 60 )) min left" >> "$E/skipped-rounds.txt"; break
        fi
        local V=main-${QW_EXPECTED_REVISION:0:7}-$BOX${EVIDENCE_SUFFIX}-r$r R=$SE/r$r; mkdir -p "$R"
        note "$ds: round $r"
        env | grep -E '^(SEARCHBENCH_|QW_|AWS_REGION)' | sort > "$R/environment.txt"
        sha256sum queries.dsl > "$R/queries-sha256.txt"
        date -u '+%F %T' > "$R/query-window-start.txt"
        set +e
        SEARCHBENCH_QUERIES=queries.dsl SEARCHBENCH_BUILD=$BUILD SEARCHBENCH_QW_METRICS_LOG=$R/storage-requests.jsonl \
            SEARCHBENCH_RESULTS=$R/quickwit_${V}_${ds}.json \
            bash ./benchmark.sh --version "$V" > "$R/benchmark.log" 2>&1
        local qrc=$?; set -e
        date -u '+%F %T' > "$R/query-window-end.txt"
        docker stop -t 60 "$C" >/dev/null 2>&1 || true
        save_container "$C" "$R"
        echo "$qrc" > "$R/exit-code"
        note "$ds: round $r rc=$qrc"; push
        rounds_done=$r
    done
    # Ground truth for the time-sorted recent queries: every corpus file can hold the newest documents.
    local logs=(); for r in $(seq 1 "$rounds_done"); do logs+=("$SE/r$r/quickwit_main-${QW_EXPECTED_REVISION:0:7}-$BOX${EVIDENCE_SUFFIX}-r${r}_${ds}.results.log"); done
    for f in "$CORPUS"/part_*.parquet; do
        $SEARCHBENCH_PYTHON ../lib/check_recent.py "$f" "${logs[@]}" > "$SE/check-recent-$(basename "$f" .parquet).txt" 2>&1 || true
    done
    note "$ds: done"; push
}

cleanup_scale() {   # $1 dataset: free the data volume for the next scale (the S3 index stays in its prefix)
    local short=${1#otel_logs_}
    stopall; docker rm -f "searchbench-qw-$BOX-$short" >/dev/null 2>&1 || true
    rm -rf "$DATA_MNT/qw-$BOX-$short" "$SEARCHBENCH_DATA_ROOT/$1"
    rm -f results/load/*.json
    df -B1 $DATA_MNT >> "$E/df-after-cleanup.txt"
}

failed=0
for ds in $DATASETS; do
    if run_scale "$ds"; then :; else note "$ds: FAILED"; echo "$ds" >> "$E/failed-scales.txt"; failed=1; fi
    cleanup_scale "$ds"
done
note "all scales finished (failed=$failed)"; push
exit "$failed"
