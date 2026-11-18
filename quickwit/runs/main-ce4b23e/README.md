# Quickwit main ce4b23e · m8gd.4xlarge · S3 · 100M / 1B

Quickwit main at commit
[`ce4b23e`](https://github.com/quickwit-oss/quickwit/commit/ce4b23eb52ba063bb72c22adc8226bfd42bc09ca)
(2026-11-17, "Ignore empty and null-only arrays for object fields when mapping documents (#7026)"),
run on 2026-11-18 with the setup of the published Datadog BYOC column
([`runs/hippo-20261105`](../../../runs/hippo-20261105/README.md)): same machine, same storage, same
index and query settings. One box, 100M then 1B.

| Column | Scales | Storage cache |
|---|---|---|
| `Quickwit (main-ce4b23e-s3)` | 100M, 1B | off (`QW_STORAGE_CACHE=0/0`) |
| `Quickwit (main-ce4b23e-s3-cache500m)` | 100M | this build's default with the adapter's cache keys (500 MB) |

## Results (median of 3 rounds, the 77 supported queries)

Cold is try 1 after the restart; hot is the better of tries 2 and 3. Geometric means floor each time
at 10 ms. The 15 unsupported queries (Q22-24, 48, 49, 59: fuzzy; Q84-92: joins) are null in every
round, as in every other Quickwit row. No try reached the 60 s cap (slowest: 3.4 s at 1B).

| | Load | Index | Splits | Cold sum | Hot sum | Cold geomean | Hot geomean |
|---|--:|--:|--:|--:|--:|--:|--:|
| 100M, cache off | 463 s | 4.5 GB | 13 | 27.69 s | 21.97 s | 313 ms | 236 ms |
| 100M, cache 500 MB | (same index) | | | 27.10 s | 3.11 s | 310 ms | 22 ms |
| 1B, cache off | 2,524 s | 45.2 GB | 65 | 57.35 s | 51.60 s | 548 ms | 467 ms |

Against the published Datadog BYOC 0.1.36 column (1B, same machine, storage and settings), over the
57 queries the page compares:

| 1B, S3 | Cold geomean | Hot geomean |
|---|--:|--:|
| Datadog BYOC 0.1.36 | 515 ms | 344 ms |
| Quickwit main `ce4b23e`, storage cache off | 457 ms | 382 ms |

- **Cold is comparable**: the restart before every query empties every cache in both runs.
- **Hot is not**: BYOC 0.1.36 kept split footers and hotcaches (split metadata, tens of MB at 1B;
  14 MiB for this run's 65 splits) in its footer cache between tries; this column caches nothing, so hot tries read footers from S3 again.
  This build cannot cache split metadata alone (see below).
- Load: 2,524 s for 1B (BYOC 2,364 s), exact 1,000,000,000 count, merges settled, 65 published splits
  (BYOC 64). Engine CPU during the load: 28,551 s.

Round-to-round spread of the cold sum: ±5 % with the cache off. In the cache-500m 100M rounds, Q62
took 26.3 s cold in round 3 (0.5 s in rounds 1-2), an isolated slow S3 read the median removes.

## The storage cache on this build

Quickwit [#6962](https://github.com/quickwit-oss/quickwit/pull/6962) (merged 2026-11-17, in `ce4b23e`,
not in `961c871`) replaces the fast-field and split-footer caches with one `storage_cache` for footers,
hotcache, fast fields and every other split range. With the adapter's legacy keys
(`fast_field_cache_capacity: 0`, footer cache unset) it is created with their sum, 0 + the 500 MB
footer default, and keeps split data: at 100M, hot tries made **no S3 requests** (S3 request counters
in `<dir>/r*/storage-requests.jsonl.gz`):

| 100M, round 1 | S3 GETs cold | hot (try 2) | hot (try 3) |
|---|--:|--:|--:|
| cache 500 MB (`otel_logs_100m/`) | 7,716 | 0 | 0 |
| cache off (`otel_logs_100m-sc0/`) | 7,769 | 7,771 | 7,768 |
| 1B, cache off (`otel_logs_1b-sc0/`) | 38,279 | 38,278 | 38,278 |
| BYOC 0.1.36, 1B (published) | 37,589 | 32,658 | 32,658 |

The first pass (100M load and three rounds, default cache) was stopped at the start of 1B. The second
pass set `QW_STORAGE_CACHE=0/0` (`quickwit/start` writes `searcher.storage_cache` with both capacities
at 0), re-queried the same 100M S3 index three times and then loaded and queried 1B. The cache-500m
column is kept to show the effect; the cache-off column is the comparable one.

## Build

No published image contains this commit (the `edge` tag is main `961c871`, 2026-11-09), so `setup.sh`
builds it on the benchmark box (500 s), before any measured phase, with the repository's own
`Dockerfile` and the build arguments of its publish workflow: `CARGO_FEATURES=release-feature-set`,
release profile, `QW_COMMIT_HASH`/`QW_COMMIT_DATE`/`QW_COMMIT_TAGS` from the checkout. Setup checked
the commit, the arm64 architecture, the revision label and `quickwit --version`
(`Quickwit 0.9.3 (aarch64-unknown-linux-gnu 2026-11-17T20:25:23Z ce4b23e)`); the smoke test checked
that `/api/v1/version` reports the same commit.

## Machine and storage (as Datadog BYOC)

| | |
|---|---|
| Instance | AWS `m8gd.4xlarge`, us-east-1: 16 Graviton4 cores, 64 GiB |
| Index + metastore | S3, same region |
| Local disk | instance-store NVMe (870 GB): corpus, WAL, ingest queue, Docker data root and image build |
| OS | Ubuntu 24.04, Docker, engine containers in a CPU-accounting slice |

## Settings (as Datadog BYOC, both scales)

| | |
|---|---|
| Ingest | native ingest API, Rust client, 16 processes, 2,000 docs/request |
| Shards | `min_shards` 48, `shard_throughput_limit` 20mb |
| Indexing | commit 30 s, `split_num_docs_target` 10M, `stable_log` merges, validation off |
| Ingest queue | 32 GiB memory, 80 GiB disk |
| In-memory indexing | on |
| Document clustering | on |
| Caches | partial request and predicate caches off; storage cache as in the column (see above) |
| Queries | 3 rounds; per round 3 tries per query (cold, hot, hot), engine restart + `drop_caches` before every query, 60 s cap |

## Correctness

`lib/check_recent.py` compared the time-sorted "recent" queries with the parquet ground truth in every
round of every column: all match (`<dir>/check-recent-part_000.txt`).

## Evidence

| Directory | Contents |
|---|---|
| `otel_logs_100m/` | 100M load (environment, log, samples, df) and the three cache-500m rounds |
| `otel_logs_100m-sc0/` | the three cache-off rounds on the same 100M index |
| `otel_logs_1b/` | 1B load: environment, log, samples, df, published splits (`metastore.json.gz`) |
| `otel_logs_1b-sc0/` | the three cache-off 1B rounds |

Each round: result file, query outputs (`*.results.log.gz`), driver log, environment, query file hash,
query window and S3 request counters. `publish.py` builds the median result files, load records and
these directories from the box's evidence, replacing the bucket, account, instance, run and host
names with placeholders. Server logs, container inspection output and host logs are not committed.

## Run

`scripts/` is the control plane (`provision.sh`, `connect.sh`, `poll.sh`, `finish.sh`, run locally) and
the host side (`run.sh` → `setup.sh` → `production.sh` → `collect.sh`; `run-2.sh` for the second pass).
Account, bucket, VPC, subnet, AMI and profile come from `scripts/local.env`, which is not committed.
The box had a 14 h hard stop (EventBridge Scheduler), an OS shutdown timer 5 min earlier and a
workload cutoff 20 min earlier; it finished in 2 h and powered itself off.

```sh
cd quickwit/runs/main-ce4b23e/scripts
date -u +%Y%m%dT%H%M%SZ > STAMP
git -C ../../../.. archive --format=tar.gz -o "$PWD/source.tar.gz" HEAD
shasum -a 256 source.tar.gz > source.sha256; git rev-parse HEAD > source.commit
APPROVED_RUN=YES ./provision.sh && ./connect.sh
./poll.sh            # status
./finish.sh          # after "done": fetch evidence, stop, clean up IAM/schedule/SG ingress
```

### Run notes

- The first pass ran the original `production.sh` (sources `1e8710f`): smoke test, 100M load and
  three rounds with the default storage cache. It was stopped by the controller at 13:07 UTC, during
  the 1B corpus fetch, once the hot tries were found to make no S3 reads. Its scripts are kept in the
  box evidence (`pass1-scripts/`).
- The second pass (`run-2.sh`, sources `d2ae392`) ran the updated `production.sh` and `quickwit/start`
  with `QW_STORAGE_CACHE=0/0`: 100M rounds on the existing S3 index (load reused), then 1B load and
  rounds. Its file hashes are in the box evidence (`pass2-files.sha256`).
- `./storage-units` returned no split count (it ran after the load container had stopped, as in the
  2026-11-15 run); the 1B split count comes from the S3 metastore.
