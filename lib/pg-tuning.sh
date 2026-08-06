#!/usr/bin/env bash
# Single source of truth for Postgres server tuning, sourced by every
# Postgres-wire adapter's ./start. Applied as -c flags, which override the image's
# postgresql.conf: paradedb and timescaledb-ha self-tune to the host at initdb
# while postgres:18-alpine ships stock defaults, so without this the engines would
# differ by image packaging. Sized for 128 GB / 32 cores; override per run, e.g.
# PG_TUNE_SHARED_BUFFERS=8GB ./benchmark.sh --index.
# Measurements behind every value: ../OPTIMIZATIONS.md.
# NOTE: only reaches a (re)created container. ./install removes it, so real runs
# pick changes up; after a manual edit, `docker rm -f <container>` first.

# --- memory -------------------------------------------------------------------
# Page cache (~25% of RAM), in anonymous shared mmap -- unrelated to --shm-size.
: "${PG_TUNE_SHARED_BUFFERS:=32GB}"
# Per sort/hash node PER WORKER, so per_gather=16 multiplies it by ~17 processes.
: "${PG_TUNE_WORK_MEM:=374MB}"
# Planner hint only (~75% of RAM); allocates nothing.
: "${PG_TUNE_EFFECTIVE_CACHE_SIZE:=94GB}"

# --- parallelism --------------------------------------------------------------
# Cluster-wide background worker pool: parallel query, parallel maintenance and
# extension workers (TimescaleDB launcher/scheduler, pg_cron) all draw from it.
: "${PG_TUNE_MAX_WORKER_PROCESSES:=16}"
# How much of that pool parallel QUERY execution may use.
: "${PG_TUNE_MAX_PARALLEL_WORKERS:=16}"
# Cap per Gather node (that branch = this many workers + the leader). Stock is 2,
# which had vanilla Postgres on 3 processes where the tuned images used 17.
: "${PG_TUNE_MAX_PARALLEL_WORKERS_PER_GATHER:=16}"

# --- index builds -------------------------------------------------------------
# Per utility command (CREATE INDEX, VACUUM). 10M sweep: workers 4/8/16 ->
# 52.5/34.2/24.5s; mem 1G/2G/4G -> 40.9/34.2/34.3s (6GB = headroom for 1b).
: "${PG_TUNE_MAX_PARALLEL_MAINTENANCE_WORKERS:=16}"
: "${PG_TUNE_MAINTENANCE_WORK_MEM:=6GB}"
# Defaults to maintenance_work_mem, i.e. 6GB per autovacuum worker. Capped here.
: "${PG_TUNE_AUTOVACUUM_WORK_MEM:=512MB}"

# --- read path (PG 18+) -------------------------------------------------------
# PG 18's AIO pool defaults to 3 workers that ALL backends funnel reads through:
# an 11x cold-path penalty here (100M cold Q08 16.2s at 3 vs 1.44s at 16), which
# pushed 7 tiger queries over the 60s cap. Hot is unaffected. PG 18+ ONLY -- an
# older major refuses to start with this flag.
: "${PG_TUNE_IO_WORKERS:=16}"

# --- write path ---------------------------------------------------------------
# Fewer checkpoint stalls during bulk ingest.
: "${PG_TUNE_MAX_WAL_SIZE:=8GB}"

# --- container ----------------------------------------------------------------
# /dev/shm, for the DYNAMIC shared memory parallel workers allocate per query
# (not shared_buffers). Docker's 64 MB default vs ~48 MB per worker took out 48 of
# 92 queries at 100M with "could not resize shared memory segment".
: "${PG_TUNE_SHM_SIZE:=8g}"

# Splice into docker run after the image name:
#   "$IMAGE" -c port="${PGPORT}" "${PG_TUNE_FLAGS[@]}"
PG_TUNE_FLAGS=(
    -c shared_buffers="$PG_TUNE_SHARED_BUFFERS"
    -c work_mem="$PG_TUNE_WORK_MEM"
    -c effective_cache_size="$PG_TUNE_EFFECTIVE_CACHE_SIZE"
    -c max_worker_processes="$PG_TUNE_MAX_WORKER_PROCESSES"
    -c max_parallel_workers="$PG_TUNE_MAX_PARALLEL_WORKERS"
    -c max_parallel_workers_per_gather="$PG_TUNE_MAX_PARALLEL_WORKERS_PER_GATHER"
    -c max_parallel_maintenance_workers="$PG_TUNE_MAX_PARALLEL_MAINTENANCE_WORKERS"
    -c maintenance_work_mem="$PG_TUNE_MAINTENANCE_WORK_MEM"
    -c autovacuum_work_mem="$PG_TUNE_AUTOVACUUM_WORK_MEM"
    -c io_workers="$PG_TUNE_IO_WORKERS"
    -c max_wal_size="$PG_TUNE_MAX_WAL_SIZE"
)
export PG_TUNE_SHARED_BUFFERS PG_TUNE_WORK_MEM PG_TUNE_EFFECTIVE_CACHE_SIZE \
       PG_TUNE_MAX_WORKER_PROCESSES PG_TUNE_MAX_PARALLEL_WORKERS \
       PG_TUNE_MAX_PARALLEL_WORKERS_PER_GATHER \
       PG_TUNE_MAX_PARALLEL_MAINTENANCE_WORKERS PG_TUNE_MAINTENANCE_WORK_MEM \
       PG_TUNE_AUTOVACUUM_WORK_MEM PG_TUNE_IO_WORKERS PG_TUNE_MAX_WAL_SIZE \
       PG_TUNE_SHM_SIZE
