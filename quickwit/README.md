# Quickwit adapter

[Quickwit](https://quickwit.io), queried through its Elasticsearch-compatible API
(`/api/v1/_elastic`) and loaded through the native ingest API
(`/api/v1/<index>/ingest`).

The default image is a pinned build of Quickwit main:

```
quickwit/quickwit:edge@sha256:34b9552eb09fa85785f529d888ed2a64df68d3e2241213710b74accf4023e8ff
```

It was built on 2026-11-09 from commit `961c8718dc19e6eb3948b1eae98d6a3f1b9e455b`
for linux/amd64 and linux/arm64, and reports `0.9.3-nightly (961c871)`. Main is
needed for document clustering, in-memory indexing and the timestamp
split-pruning fix (#6865, #6966), none of which are in a 0.9.x release. Set
`QW_IMAGE` to run another build.

## Results

| Column | Files | Run |
|---|---|---|
| **Quickwit (main-local)** | `results/quickwit_main-local_<dataset>.json` | Quickwit main `961c871`, 2026-11-15, AWS `m8g.4xlarge` (16 cores, 64 GiB), index on a 3,000 GiB gp3 volume (20k IOPS, 625 MiB/s). Median of 3 rounds. |
| **Quickwit (main-s3)** | `results/quickwit_main-s3_<dataset>.json` | Same build, settings and machine type, with the index and metastore on S3. Median of 3 rounds. |
| **Quickwit (main-ce4b23e-s3)** | `results/quickwit_main-ce4b23e-s3_<dataset>.json` | Quickwit main `ce4b23e`, 2026-11-18, 100M and 1B, with the published Datadog BYOC setup: AWS `m8gd.4xlarge`, index and metastore on S3, WAL on the instance-store NVMe. Storage cache off (`QW_STORAGE_CACHE=0/0`, see [Caches](#caches)). Median of 3 rounds. |
| Quickwit (main-ce4b23e-s3-cache500m) | `results/quickwit_main-ce4b23e-s3-cache500m_otel_logs_100m.json` | Same box and 100M index with this build's default storage cache (500 MB, which holds split data too). 100M only. Median of 3 rounds. |
| Quickwit | `results/quickwit_otel_logs_{100m,1b}.json` | Quickwit 0.9.0, 2026-09-20, GCP `n2-standard-32` with `pd-ssd`, with the adapter settings of that time. |

[`runs/main-20261115/`](runs/main-20261115/README.md) and
[`runs/main-ce4b23e/`](runs/main-ce4b23e/README.md) have the method, the
per-round evidence and the scripts of the main runs.

The 0.9.0 `data_size` is not comparable with the main runs. It is `du` of the
whole data dir, which also counts the WAL, the ingest queues, the indexer split
cache and merged-away splits. The main runs report the bytes of the published
splits.

## Usage

```bash
./benchmark.sh --index      # create the index, load the corpus, run the queries
./benchmark.sh              # queries only, on the existing index
QW_STORAGE=s3 QW_S3_ROOT=s3://<bucket>/searchbench/<host> ./benchmark.sh --index
```

`QW_STORAGE=s3` uses `config/quickwit_s3.yaml`: the index and a file-backed
metastore live under `QW_S3_ROOT`, and the local data dir keeps only the ingest
WAL and the indexer's split store. `./install` empties `QW_S3_ROOT` and refuses
any URI that does not match `s3://*/searchbench/*`.

Settings take effect on a new index (`--index`). Use a new `--version` label for
each configuration so earlier results are not overwritten.

## Configuration

The published main runs used the settings below at every scale. The values in
the "Published runs" column are set from the run environment
(`runs/main-20261115/scripts/remote.env`); the adapter defaults differ where
noted.

### Index and ingest

| Setting | Published runs | Adapter default | Variable |
|---|---|---|---|
| Ingest client | Rust client, 16 processes, 2,000 docs/request | Python `ingest.py`, 16 processes | `SEARCHBENCH_LOAD_CLIENT=rust`, `SEARCHBENCH_LOAD_PROCESSES` |
| Minimum ingest shards (`min_shards`) | 48 | server default | `QW_MIN_SHARDS` |
| `shard_throughput_limit` | 20mb (the maximum the server accepts) | server default, 5 MiB | `QW_SHARD_THROUGHPUT_LIMIT` |
| Ingest queue | 32 GiB memory, 80 GiB disk | 32 GiB, 64 GiB | `QW_INGEST_QUEUE_MEMORY`, `QW_INGEST_QUEUE_DISK` |
| `commit_timeout_secs` | 30 | 30 | `QW_COMMIT_TIMEOUT_SECS` |
| `split_num_docs_target` | 10M | server default, 10M | `QW_SPLIT_NUM_DOCS` |
| Merge policy | `stable_log` with Quickwit's defaults | server default | `QW_MERGE_POLICY` |
| Document validation | off (index and server) | on | `QW_VALIDATE_DOCS=off` |
| In-memory indexing | on | on | `QW_ENABLE_IN_MEMORY_INDEXING` |
| Document clustering | on | on | `QW_CLUSTERING` |

- **Shards.** `min_shards` is a minimum: the ingest API opens that many shards
  from the start instead of scaling up under load. It is independent of the
  number of client processes.
- **Merge policy.** Quickwit's `stable_log` defaults are `min_level_num_docs`
  100,000, `merge_factor` 10, `max_merge_factor` 12 and `maturation_period`
  48 h.
- **Document validation.** `QW_VALIDATE_DOCS=off` sets
  `ingest_settings.validate_docs: false` in the index and
  `QW_DISABLE_DOCUMENT_VALIDATION=true` on the server. Documents are still
  parsed by the indexing pipeline.
- **In-memory indexing** keeps the temporary indexing files of an in-progress
  split in RAM and writes them to disk when the split is finalized. It does not
  keep the published index in RAM, and it does not skip the WAL, the merges or
  the final storage writes. Quickwit reads the variable once at startup, so
  `./start` recreates the container when it changes. It raised ingest throughput
  by about 21% at 100M, and raised peak engine memory from 19.5 to 32.9 GiB on a
  64 GiB machine.
- **Document clustering** is a node-level setting (`docs_clustering` in the node
  config). Documents in each fresh split are ordered by key structure, then
  `ServiceName`, then `SeverityText`, then the token pattern of `Body`. Merges
  keep that order. It changes only the document order, so query results are
  unchanged. `QW_CLUSTERING=off` sets `QW_DISABLE_DOCS_CLUSTERING=true` for the
  unclustered baseline.

`config/dataset-defaults.sh` adds a preset for `otel_logs_100m` (1M-document
splits, 64 shards, validation off, explicit `stable_log`). The published 100M
runs did not use it; they set the values above explicitly. Any non-empty `QW_*`
variable takes precedence over the preset.

### Index mapping

`config/index_config.json` indexes only what the queries use:

| Field | Indexed | Fast | Notes |
|---|---|---|---|
| `Body` | yes, with positions | no | `default` tokenizer; phrase queries need the positions |
| `ServiceName`, `SeverityText` | yes | yes | `raw` tokenizer |
| `SeverityNumber` | yes | yes | |
| `ScopeName` | no | yes | used only in terms aggregations |
| `Timestamp` | no | yes, millisecond precision | ranges, sorts and histograms run on the fast field; split pruning uses each split's time range from the metastore |
| `TraceId`, `SpanId`, dynamic fields | no | no | stored, so documents are returned whole |

`ingest.py` and the Rust client send timestamps as epoch milliseconds.
`lib/check_recent.py` compares each engine at the precision it returns.

### Caches

The driver restarts the engine and drops the OS page cache before every query.
Try 1 (cold) therefore starts with every in-memory cache empty. Tries 2 and 3
(hot) run against the same process, so whatever try 1 put in a cache can be
reused.

| Searcher cache | Quickwit default | Here | What it holds |
|---|---|---|---|
| `partial_request_cache_capacity` | 64 MB | **0** | Leaf search *results*, keyed on the query |
| `predicate_cache_capacity` | 256 MB | **0** | Per-split filter hit sets, keyed on the query |
| `fast_field_cache_capacity` | 1 GB | **0** | Decoded fast-field (columnar) data |
| `split_footer_cache_capacity` | 500 MB | default | Split footers and hotcaches (split metadata; about 33 MB for the whole 1B index) |
| `split_cache` | not set | not set | Local disk copy of whole splits downloaded from object storage |

- **Result caches must be off.** With the partial request cache at its default,
  hot tries return a stored result instead of running the query: a nested terms
  aggregation over 11.7M documents went from 115 ms to 2 ms, and the whole suite
  read 10× faster than it executes. The predicate cache has the same effect on
  count, group-by and recent queries. They are the equivalent of the
  Elasticsearch request and query caches, which the `elastic/` and
  `opensearch/` adapters also disable.
- **The fast field cache is off** so that hot tries read the columns through
  storage rather than from decoded data kept in the process.
  `QW_FAST_FIELD_CACHE` (for example `16GiB`) re-enables it.
- **The split footer cache stays on.** It holds split metadata only, the
  analogue of ClickHouse's mark cache, which stays on in the ClickHouse adapter.
- **No split cache.** On S3, every try reads the splits from S3; only the split
  footers are cached between tries. On local disk, hot tries also benefit from
  the OS page cache, which the driver drops only before try 1.

**Builds with #6962 (Quickwit main from 2026-11-17, e.g. `ce4b23e`).** The
fast-field and footer caches are replaced by one `storage_cache` that holds
footers, hotcaches, fast fields and every other split range. The table above
then no longer applies: with only the legacy keys, the storage cache gets their
sum (0 + the 500 MB footer default) and keeps split data, so at 100M hot tries
made no storage reads at all. Footers can no longer be cached on their own.
`QW_STORAGE_CACHE=<memory>/<disk>` writes `searcher.storage_cache`;
`QW_STORAGE_CACHE=0/0` (the `main-ce4b23e-s3` column) disables it, so every
try, footers included, reads from storage. Do not set it for older builds,
which do not know the key.

`request_timeout_secs` and `leaf_request_timeout_secs` are 300, so the
driver's 60 s cap, not Quickwit's 30 s defaults, decides when a cold try is too
slow. On a single node the leaf timeout covers the whole query: the published
local 10B run had it at the default, and 7 cold tries ended at 30 s (see the run
notes).

`config/quickwit.yaml` and `config/quickwit_s3.yaml` differ only in where the
data lives. Keep them in sync.

## Load

`./load` recreates the index and ingests the corpus through
`/api/v1/<index>/ingest`. It then waits until all the documents are searchable,
merges have settled, and the published split set has been unchanged for
`QW_MERGE_QUIET_SECS` (180 s; 45 s on smoke scales). The wait is part of
`load_time`.

- **Count check.** The load fails if the final document count differs from the
  parquet row count. The ingest response alone is not proof that every document
  landed. Do not point the loader at the `/api/v1/_elastic/_bulk` endpoint: the
  0.9.0 runs lost documents under concurrent load through it, while the native
  ingest API indexed every document at 16 processes.
- **Commits are on a timer.** Documents become searchable up to
  `commit_timeout_secs` after their request returns, so the count is polled
  until it matches.
- **Request size.** The node config raises `content_length_limit` to 32 MiB.
  2,000 documents of this corpus are about 2.5 MB.
- **Rust client** (`client/`). `./install` builds it with `--locked` before any
  timed phase, or checks a supplied `QW_CLIENT_BIN`. `QW_CLIENT_BUILD=auto|native|docker`
  picks the builder. Retries are bounded (`SEARCHBENCH_LOAD_MAX_RETRIES`, 8;
  `SEARCHBENCH_LOAD_REQUEST_TIMEOUT`, 60 s), and a fatal worker error stops the
  other workers.
- `QW_INGEST=parquet` loads with Quickwit's parquet bulk CLI
  (`quickwit tool local-ingest`), on builds that have it. The published runs
  used the ingest API.

## Queries

- **Searcher-only node.** After a load, `./start` runs the node with
  `QW_ENABLED_SERVICES=searcher,metastore`. An all-in-one node waits 15 s on
  shutdown for its ingester, which the per-query restarts would add 77 times per
  round. Results are identical.
- **Storage requests per query** (opt-in). With `SEARCHBENCH_QW_METRICS_LOG=<file>`,
  `./query` appends one JSON line per try with the object-storage GETs and the
  bytes downloaded during that try, read from `/metrics`.

### Coverage: 77 of 92

`queries.dsl` is the Elasticsearch query file with two constructs rewritten:

| Rewritten | Why |
|---|---|
| `match` object form (`operator`, `minimum_should_match`) | HTTP 400; expanded into a `bool` over single-term `match` clauses |
| `date_histogram` with `calendar_interval` | HTTP 500; replaced by `fixed_interval` (one minute = 60 s). The corpus has no DST change or leap second, so the buckets are the same |

| Unsupported | Why |
|---|---|
| Q84–Q92 (9) | joins |
| Q22–Q24, Q48, Q49, Q59 (6) | fuzzy matching: `fuzzy` and `match` with `fuzziness` return HTTP 400, and `term~1` in a query string matches the exact term only |

Q67 is a nested aggregation here (the top 100 severities, then the top 20 scopes
of each), while the SQL adapters use a flat `GROUP BY (SeverityText, ScopeName)
LIMIT 20` and some adapters group by severity only. The shapes return the same 7
pairs on this corpus only because it has 5 severities and 7 distinct pairs.

## Correctness

- **Recent queries.** `lib/check_recent.py --store-unit=ms` checks the
  time-sorted top-100 queries (Q68, Q70, Q72, Q73) against ground truth
  computed from every corpus file. `--store-unit=ms` matches the index's
  millisecond `Timestamp`: a document at 00:30:00.000400 is inside
  `lte 00:30:00` for Quickwit. The main runs pass on every round, on local disk
  and S3, at 100M, 1B and 10B.
- **Sort by timestamp.** In 0.9.x, a `Timestamp` descending sort could skip
  splits whose time range ended in the same second as the current worst hit,
  and return real but not-newest documents. It depends on split timing, so it
  shows up mostly on S3, but at 1B it also made Q70, Q72 and Q73 wrong on local
  disk. Main fixes it by rounding split time bounds outward in the metastore
  (#6865, with an overflow fix in #6966).
- **Counts and aggregations** were verified for 0.9.0 at 100M: every count and
  every group-by bucket matched Elasticsearch, hit-returning queries matched on
  their full match total, and every returned document satisfied its predicate.
  Counts are exact (`hits.total.relation: eq`), and terms aggregations report
  `doc_count_error_upper_bound: 0`; with 17 services, the corpus is well inside
  the range where Tantivy's terms aggregation is exact.
- `_score`-sorted top-k queries are compared by match total only: Tantivy and
  Lucene compute BM25 differently, so which documents tie into the page
  legitimately differs.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `QW_IMAGE` | pinned main build (above) | Quickwit image; a local image is used without pulling |
| `QW_PULL_IMAGE` | `auto` | `auto` pulls only if the image is missing; `yes` always pulls; `no` requires a local image |
| `QW_STORAGE` | `local` | `s3` stores the index and metastore under `QW_S3_ROOT` |
| `QW_S3_ROOT` | none | required with `QW_STORAGE=s3` |
| `QW_DATA_DIR` | `./qw-data` | node data dir (WAL, split store; the index with `local`) |
| `QW_PORT` | `7280` | HTTP port |
| `QW_CONTAINER` | `searchbench-quickwit` | container name |
| `QW_INDEX` | `otel_logs` | index id |
| `QW_SERVICES` | searcher + metastore after a load, all before | `QW_ENABLED_SERVICES` of the node |
| `QW_EXTRA_ENV` | none | extra container environment, space-separated `KEY=VALUE` |
| `QW_FAST_FIELD_CACHE` | `0` | `searcher.fast_field_cache_capacity` |
| `QW_WAIT_MERGES` / `QW_MERGE_QUIET_SECS` / `QW_MERGE_MAX_SECS` | `yes` / 180 / 14400 | merge-settle wait |
| `QW_DATA_SIZE` | `splits` | `du` reports the whole data dir instead of the published splits |
| `SEARCHBENCH_LOAD_CLIENT` | Python | `rust` uses `client/` |
| `SEARCHBENCH_LOAD_PROCESSES` | 16 | ingest processes |

The index and ingest variables are listed under [Configuration](#configuration).
