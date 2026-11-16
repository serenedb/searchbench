# Quickwit main, 2026-11-15: local disk and S3, 100M / 1B / 10B

Two runs of the same Quickwit build with the same settings, one per storage
backend, on identical machines started at the same time:

| Column | Index storage | Machine |
|---|---|---|
| `Quickwit (main-local)` | 3,000 GiB gp3 EBS volume, 20,000 IOPS, 625 MiB/s | AWS `m8g.4xlarge`, us-east-1 |
| `Quickwit (main-s3)` | S3 (index and metastore), same region; WAL and split cache on the same gp3 volume | AWS `m8g.4xlarge`, us-east-1 |

Each box runs 100M, then 1B, then 10B: fetch the corpus, load, three query rounds,
check the time-sorted queries against the parquet, clean up, next scale.

## Build

- Image `quickwit/quickwit:edge@sha256:34b9552eb09fa85785f529d888ed2a64df68d3e2241213710b74accf4023e8ff`,
  built 2026-11-09 from main commit `961c8718dc19e6eb3948b1eae98d6a3f1b9e455b`
  (`/api/v1/version` reports `0.9.3-nightly (961c871)`). Setup checks the arm64
  architecture and the revision label before any load.
- Includes the timestamp split-pruning fix (#6865, #6966). The time-sorted
  "recent" queries Q68, Q70, Q72, Q73 match the parquet ground truth on every
  round at both scales (`<box>/<dataset>/check-recent-*.txt`).

## Hardware

| | |
|---|---|
| Instance | AWS `m8g.4xlarge`: 16 Graviton4 cores (no SMT), 64 GiB |
| Data volume | 3,000 GiB gp3, 20,000 IOPS, 625 MiB/s: the instance's sustained (non-burst) EBS limit |
| Measured (fio, before the runs) | 16 KiB random read ~20.2k IOPS; 1 MiB sequential read ~655 MB/s |
| OS | Ubuntu 24.04.5, Docker, engine containers in a CPU-accounting slice |

**Not the repository's reference machine.** The other published engines ran on
GCP `n2-standard-32` (16 cores × 2 hyperthreads, 128 GB, 3 TB `pd-ssd`). This
run matches its 16 physical cores, has half the memory (64 GiB), and a slower
disk: about 20k IOPS and 625 MiB/s
against the `pd-ssd`'s nominal ~90k IOPS and 1.2 GB/s. Cold local-disk queries
that read a whole column across every split are bandwidth-bound on this volume
(see below).

## Settings

The same settings at every scale (`scripts/remote.env`); the adapter README
describes each one:

| | |
|---|---|
| Ingest | native `/api/v1/otel_logs/ingest`, Rust client, 16 processes, 2,000 docs/request |
| Shards | `min_shards` 48, `shard_throughput_limit` 20mb |
| Indexing | commit 30 s, `split_num_docs_target` 10M, `stable_log` merge policy, document validation off |
| Ingest queue | 32 GiB memory, 80 GiB disk |
| In-memory indexing | on (`QW_ENABLE_IN_MEMORY_INDEXING=true`) |
| Document clustering | on: structure, `ServiceName`, `SeverityText`, tokenized `Body` |
| Caches | fast field, partial request and predicate caches off (split footer cache at its default; no split cache on S3) |
| Queries | 3 tries per query (cold, hot, hot); engine restart + `drop_caches` before every query; 60 s cap |

100M uses these settings rather than the adapter's 100M preset (1M-document
splits, 64 shards), so all scales are loaded the same way.

## Results (median of 3 rounds, the 77 supported queries)

Cold is try 1 after the restart; hot is the better of tries 2 and 3. Geometric
means floor each time at 10 ms. The 15 unsupported queries (Q22-24, 48, 49, 59:
fuzzy; Q84-92: joins) are null in every round, as in every other Quickwit row.

| | Load (ingest) | Index | Splits | Cold sum | Hot sum | Cold geomean | Hot geomean |
|---|--:|--:|--:|--:|--:|--:|--:|
| 100M local | 478 s (285 s) | 4.5 GB | 10 | 7.99 s | 3.49 s | 79 ms | 26 ms |
| 100M S3 | 453 s (254 s) | 4.5 GB | 15 | 25.91 s | 18.67 s | 289 ms | 181 ms |
| 1B local | 2,544 s (2,358 s) | 45.2 GB | 72 | 60.51 s | 12.98 s | 297 ms | 79 ms |
| 1B S3 | 2,439 s (2,237 s) | 45.2 GB | 67 | 53.32 s | 46.85 s | 502 ms | 390 ms |

| 10B local | 23,517 s (23,329 s) | 452.0 GB | 631 | 394.79 s ¹ | 53.94 s ¹ | 1,647 ms ¹ | 359 ms ¹ |
| 10B S3 | 21,969 s (21,760 s) | 451.6 GB | 587 | 284.52 s | 269.33 s | 1,986 ms | 1,639 ms |

¹ 70 of the 77 queries: on local disk at 10B, the cold try of Q26, Q27 and
Q61-Q65 ended at Quickwit's 30 s leaf timeout in every round (see Run notes).
Their hot tries completed, so those queries are in the result file with a
null cold time. The S3 row is over all 77.

Round-to-round spread of the cold sum: ±0.2 % on local disk at every scale,
±2 % on S3 at every scale.

- **Index size** is the sum of the published split files (metastore), the same
  number for both backends. The 0.9.0 row's `data_size` is `du` of the whole
  data dir and is not comparable: on the local 1B box the data dir grew by
  about 119 GB during the load for a 45.2 GB index.
- **Split count at 10B.** The 10M-document splits reach `stable_log`'s top
  merge level and stay there, so the 10B index has about 600 splits against
  about 70 at 1B. Every query fans out to all of them.
- **Local disk, cold, 1B:** about 15 queries that aggregate or sort on
  `Timestamp` (Q61-Q75, Q26) take ~2.3 s cold on local disk against ~1.4 s on
  S3; they take ~0.14 s hot. This looks like the gp3 volume's 625 MiB/s limit
  on a cold read of the timestamp column across 72 splits (S3 reads in parallel
  over a 15 Gbit/s network). That is why the local cold *sum* is higher than
  the S3 one at 1B while its geomean is lower.

- **Local disk, cold, 10B:** the same queries are the slowest cold tries. Seven
  of them (Q26, Q27, Q61-Q65) needed more than 30 s on the gp3 volume and hit
  the leaf timeout; on S3 they took 12-23 s.

## Evidence

`<box>/<dataset>/`:

- `r1/`, `r2/`, `r3/`: each round's result file, query outputs
  (`*.results.log.gz`), driver log, environment, query file hash, query window
  and storage request counters (`storage-requests.jsonl.gz`).
- `check-recent-all-parts.txt`: `lib/check_recent.py --store-unit=ms` over
  every corpus file of the scale, all three rounds of both boxes.
- `load-benchmark.log`, `load-environment.txt`, `load.samples.gz` (10 s ingest,
  indexing and memory samples), `storage-units.json`,
  `corpus.json` (rows, size + ETag check), `df-*.txt`.
- `scripts/`: the provisioning and host scripts as run, with the bucket,
  account, subnet and VPC replaced by placeholders.
- `publish.py`: builds the median result files, load records and this
  evidence directory from the raw per-box evidence.

Server logs and container inspection output are not committed (several MB per
round, and they name hosts and the bucket); they are kept with the raw evidence.

## Run notes

- **First attempt, all scales failed in `./load`** with `missing data dir
  .../otel_logs_100m/otel_logs_100m`: `production.sh` passed
  `SEARCHBENCH_DATA_DIR=<root>/<dataset>`, but `lib/benchmark.sh` appends the
  dataset itself. No load ran. The workload was stopped, the script fixed, and
  production re-run on the same boxes (`scripts/resume.sh`); setup (disk, image,
  client build and tests) had passed and was not repeated.
- **`lib/check_recent.py`** read its predicates from a query file that is not
  on this branch. Fixed to read `quickwit/queries.dsl`, patched on
  both hosts during 100M round 3; the 100M check was then re-run by hand on all
  three rounds.
- **Leaf timeout at 10B, local disk.** The node config raised
  `request_timeout_secs` to 300 but left `leaf_request_timeout_secs` at its 30 s
  default. On one node the leaf search covers every split of the query, so the
  cold tries of Q26, Q27 and Q61-Q65 failed with `request timed out` after 30 s,
  in all three rounds. Nothing else timed out (slowest successful try: 27.1 s
  local, 23.3 s S3). The adapter now sets `leaf_request_timeout_secs: 300`; the
  published local 10B row keeps the recorded nulls.
- **Recent-query check at 10B.** Two changes to `lib/check_recent.py`:
  - Truth is the top 100 across all ten corpus files. Run file by file, it
    reported every 10B run wrong, because the newest documents of a window
    are spread over several files.
  - `--store-unit=ms`: Quickwit stores `Timestamp` at millisecond precision, so
    a document at 00:30:00.000400 matches `lte 00:30:00`. Q73 at 10B returns
    100 such documents, and its parquet truth has to be computed on truncated
    timestamps.

  With both, Q68, Q70, Q72 and Q73 pass on every round, both boxes, at every scale.
- **Load at 10B.** All 10B documents were searchable when ingest ended, and
  merges settled within the 180 s quiet window: load time is ingest plus about
  3.5 minutes of count and merge checks on both boxes.
