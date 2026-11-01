# SearchBench / Apache Pinot engine

Apache Pinot built from source, running as a single-node cluster (ZooKeeper +
controller + broker + server) started by `./start`. Text search uses Pinot's
Lucene text index via `TEXT_MATCH`; the 21 BM25 `top_k` queries (Q33–Q53) are
marked `UNSUPPORTED` because Pinot's text index returns an unscored docId set
and has no relevance scoring, the same reason ClickHouse marks them.

The published results were measured on a GCP n2-standard-32 (32 vCPU, 128 GB, Ubuntu 24.04) with
a 1 TB pd-ssd attached. On a fresh box of that shape, `./provision-gcp.sh` does all of the below:
mounts the data disk at `/data`, installs the toolchain (JDK 25 via Corretto, since Ubuntu 24.04
has no package for it), builds Pinot from `master` with `-Pbin-dist`, and writes
`~/.searchbench-env` pinning the runtime JDK to the build JDK. Source that file before running.

`./provision-ec2.sh` does the same on Amazon Linux 2023, where the toolchain comes from `dnf` and
`/data` is the instance's local NVMe. It is kept because ingestion behaves differently there:
n2-standard-32 has no local disk, so all I/O goes to the network-attached pd-ssd and disk
throughput gates segment build in a way it does not on an m6id.

Needs: a JDK **at least as new as the one the distribution was built with**, `jq`, `curl`, and a
Python with `pyarrow` (the corpus is resharded
before ingestion). Set `PINOT_DIST` to an unpacked distribution, or let `./start`
find one under `/data/pinot-dist`, `~/pinot-dist`, `/opt/pinot`, or a local
`pinot-distribution/target/apache-pinot-*-bin/`.

## Configuration

| | |
|---|---|
| Analyzer | `luceneAnalyzerClass = SimpleAnalyzer` (LetterTokenizer + lowercase). Pinot's default `StandardAnalyzer` follows UAX#29, which keeps `send_email` and `email_server.rb` as single tokens; on this corpus that drops 54–78% of matches for `email`, `confirmation` and `send` against the reference engines. `SimpleAnalyzer` is the equivalent of ClickHouse/SereneDB's `splitByNonAlpha` + lowercase, and with it every scalar result matches SereneDB |
| Indexes | Lucene text on `Body`; inverted on `ServiceName`; range on `Timestamp` and `SeverityNumber`. Those are the three non-text predicate shapes the workload actually uses: `ServiceName` is the low-cardinality equality filter in 27 of the 71 answerable queries, and `Timestamp`/`SeverityNumber` carry the range and window predicates (Q30–Q32 and Q68–Q83). Inverted indexes are built during segment generation (`createInvertedIndexDuringSegmentGeneration`) rather than on load |
| Column encoding | `Body`, `SpanId` and the three JSON attribute maps are `noDictionaryColumns` (RAW): all are high-cardinality, so a dictionary costs build time and memory and buys no lookup. `TraceId` is left dictionary-encoded on purpose — the nine self-joins (Q84–Q92) equi-join on it, and the dictionary gives the join an integer key instead of a string one |
| Compression | `ZSTANDARD` on `ResourceAttributes`, `ScopeAttributes` and `LogAttributes`. In a sampled 10B segment these three columns are 54% of all column index bytes (`ResourceAttributes` 31%, `LogAttributes` 21%, `ScopeAttributes` 3%), and 58% of forward-index bytes alone, and no query in the workload projects any of them — so the size saving applies to every segment while the decompression cost is never paid |
| Segments | One segment per input file, so `./load` reshards the corpus to ~4M rows/segment (`PINOT_ROWS_PER_SEGMENT`). A segment is both the unit of intra-query parallelism and of Lucene index build, so a single 1B-row input would serialise the scan onto one thread. The resharding happens inside the timed load |
| Build parallelism | capped at core count, not segment count: each concurrent segment build holds a Lucene buffer |
| Scratch | `-Djava.io.tmpdir` is pointed under `$PINOT_WORK`. Many systemd distributions mount `/tmp` as a tmpfs sized at 50% of RAM — Amazon Linux 2023 always does, Ubuntu 24.04 may — and segment build needed 74 GB of scratch at 1B, which both exceeds that and competes with the JVM heaps. Both provisioners redirect it regardless |
| Stats collection | `optimizeNoDictStatsCollection = true`. Without it Pinot builds and sorts a distinct-value set for every column including the six declared `noDictionaryColumns`, where neither the cardinality nor the sorted dictionary is used. Measured at 100M: 677 s → 528 s load, same on-disk size, same row count. The flag makes RAW-column cardinality approximate (HLL++), which nothing in this workload consumes |
| Query engine | the single-stage engine serves scan/filter/aggregate; only joins go to the multi-stage engine, which is how Pinot is deployed |
| Query options | `numGroupsLimit=50000000` and, for joins, `maxRowsInJoin=200000000` and `timeoutMs=600000`. Pinot's defaults truncate or reject this workload: `numGroupsLimit` defaults to 100,000 and a `DISTINCT` over more distinct values than that returns a **wrong** answer with HTTP 200, flagged only in a `numGroupsLimitReached` field, and `maxRowsInJoin` defaults to 1,048,576 so every self-join on `TraceId` fails outright at log scale. `./query` fails the run if `numGroupsLimitReached` is set, rather than recording a truncated count. `timeoutMs` is derived from the driver's own ceiling plus its 10 s SIGKILL grace, so the driver's `timeout` is always what stops a slow query: Pinot's broker default is 10 s (`CommonConstants.DEFAULT_BROKER_TIMEOUT_MS`), far under that ceiling, and a cold query crossing it returns broker error 427 rather than a result — which the driver records as a `null`, a measurement silently dropped instead of a visible capped cell |
| Server heap | 25% of RAM. Pinot serves mmap'd segments from the page cache, so a large heap costs more than it buys |

## Run

```bash
# Provision a fresh box: mounts /data, installs the toolchain, builds Pinot
# from master with -Pbin-dist, writes ~/.searchbench-env. Use provision-ec2.sh
# on Amazon Linux 2023 instead.
./provision-gcp.sh
source ~/.searchbench-env

# Smoke (streams the first 1M rows over HTTPS)
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index

# Full benchmark (~500 GB free disk at 1B, ~1 TB at 10B, plus sudo for drop_caches)
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index
```

## Env

| Var | Default | Meaning |
|---|---|---|
| `PINOT_DIST` | discovered | unpacked Pinot distribution (the dir containing `bin/`) |
| `PINOT_JAVA_HOME` | `$JAVA_HOME`, else `java` on PATH | JDK to run the cluster with |
| `PINOT_MIN_JAVA` | `21` | lowest acceptable JDK major; set to the build JDK |
| `PINOT_WORK` | `$HOME/sb-pinot-work` | segments, deep store, resharded corpus, scratch; wiped by `./install` |
| `PINOT_ROWS_PER_SEGMENT` | `4000000` | target rows per segment |
| `SERVER_XMX` | 25% of RAM | server heap |
| `INGEST_XMX` | `32G` | segment-generation job heap |
| `SEARCHBENCH_MAX_EXEC_THREADS` | core count | `maxExecutionThreads` per query (single-stage) |
| `SEARCHBENCH_STAGE_PARALLELISM` | `8` | workers per intermediate join stage. Pinot's `WorkerManager` defaults this to 1, so on a single server the whole join stage runs on one worker; 8 measured fastest at 1B on 32 cores and plateaus rather than tracking core count |

`./data-size` reports the served footprint. Pinot also keeps a deep-store copy
of every segment in the controller directory, which no other engine here has an
equivalent of; `./data-size-deepstore` prints it separately.
