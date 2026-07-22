# SearchBench: An open benchmarks for search and analytics

https://serenedb.com/searchbench

## Overview 

This benchmark measures how well different systems handle search and analytics over high-volume of semi-structured records that applications and infrastructure spit out constantly. Think OpenTelemetry logs, structured events and machine-generated telemetry. The core of it is the two things observability and log-analytics tools do all day and have to do well at the same time: find the rows that matter (keyword and phrase search, filtering, relevance ranking) and make sense of them in bulk (aggregations, grouping, joins across log streams). A system that's fast at one but slow at the other doesn't get you very far, so the benchmark leans on both.

The data is a generated OpenTelemetry logs corpus that scales up to about a billion rows. The workload is 92 queries (Q01–Q92), spanning the full range of what a log platform gets asked to do:

- **Term and phrase search**: finding the rows that contain a word, a phrase or a combination of conditions, the bread-and-butter "where is this in my logs" case.
- **Relevance ranking**: BM25-scored top-K queries that return the best matches rather than just any matches, a regime a lot of search benchmarks skip entirely.
- **Aggregations**: counting, grouping and summarizing over the rows that match, which is where the analytics side gets stressed.
- **Filtered analytics**: search and aggregation combined in one query: narrow down first, then crunch what's left, the pattern most real dashboards actually run.
- **Joins**: correlating across log streams, the part that separates a search index from a real query engine.

## Goals

- **Same result every time**: Run it yourself and get the numbers we got. Every system hooks into the harness the same way, and the driver handles the rest: load, index, query and save.
- **Bring your own query language**: Nothing here assumes SQL. Systems plug in through a thin adapter, so a SQL database and a DSL-based engine fit side by side without either bending to the other.
- **Search and analytics together**: The workload doesn't treat them as separate problems. It's built for systems that have to find the right rows and crunch them in the same breath, which is where most real log work lives.
- **Honest measurement**: Cold and hot runs, caches dropped between queries and load time and index size reported on their own, so nothing hides behind a warm page cache or a slow ingest.

## How to contribute
 
### Add an engine

This is the most useful contribution. Create `<engine>/` with an executable script per verb the driver calls, plus a
`benchmark.sh` that sets the engine identity and hands off to the shared driver:

```bash
# <engine>/benchmark.sh
export ENGINE_NAME="MyEngine"
export ENGINE_TAGS='["Tag1","Tag2"]'
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.sql}"  # or queries.dsl
exec ../lib/benchmark.sh "$@"
```

Required scripts (run from the engine dir; non-zero exit = failure):

| Script | Contract |
|---|---|
| `install` | pull image / check deps; wipe stale datadir |
| `start` / `stop` | bring the engine up / down (idempotent) |
| `check` | exit 0 once the engine answers a trivial query |
| `load` | ingest `$SEARCHBENCH_DATA_DIR/part_*.parquet`, build the index |
| `query` | one query on stdin → rows on stdout; **last stderr line = elapsed seconds**; optional `SEARCHBENCH_ROWS=<n>` on stderr |
| `data-size` | print on-disk bytes of the dataset + index |
| `queries.sql` \| `queries.dsl` | the 92 `-- QNN task=…`-tagged queries, in result-row order |

Optional: `version` (prints the engine version, recorded in results) and
`watch-load` (live load progress). Easiest start: copy an existing adapter
(e.g. `postgres/`) and adapt it.
 
### Start from a working adapter

Don't build from scratch. Copy an existing folder — `postgres/` is the simplest — and adapt it. Point `SEARCHBENCH_DATA_DIR` at a data directory, run it in smoke mode against a small slice to check the plumbing, then do a full run once it's green.
 
### Improve what's there

New adapters aren't the only thing that helps. Fix a bug, correct an unfair query translation or flag a result that looks off. If you know a system better than we do, we'd rather hear it — the benchmark is only as good as the care that goes into each setup.
 
### Open an issue or PR

Corrections are as welcome as additions. Bring the change or bring the problem; either moves things forward.

## Run

```bash
cd <engine>
# --index downloads the corpus, loads it, builds the index, then queries.
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index
# -> results/<engine>_otel_logs_1b.json

# Omit --index to re-run queries only against the already-loaded engine.
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh
```

`SEARCHBENCH_DATA_DIR` (required, no default) is a **root** directory for
corpus data. Each scale gets its own subdirectory under it
(`.../<dataset>/part_*.parquet`), so a smoke slice never clobbers a full
part and scales never share files. The shared download step
(`lib/download-otel-logs`) is the one place that materializes parquet on
disk; every engine's `./load` then reads `part_*.parquet` from there.
Each engine's `README.md` lists its other required env vars.

## Smoke mode

`SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index` (with
`SEARCHBENCH_DATA_DIR` set) slices the first 1M rows of `part_000.parquet`
into `$SEARCHBENCH_DATA_DIR/otel_logs_1m/` and runs in seconds — the
slice/download happens only under `--index`. The slice is streamed
row-group-by-row-group over HTTPS
(`lib/slice_parquet.py`), so only ~50 MB is fetched — not the full ~40 GB
part. Smoke scales: `otel_logs_100k`, `otel_logs_1m`, `otel_logs_100m`. Use
it to validate an adapter against a freshly-built engine binary before a
real run.

## Methodology

- 3 tries per query: `[cold, hot, hot]`. Real datasets restart the
  engine + `drop_caches` between queries; smoke mode keeps the engine
  warm.
- **Client round-trip timing**: each `./query` reports its own request→response
  time on its last stderr line (psql `\timing` for the Postgres-wire engines,
  curl `%{time_total}` for the HTTP engines) — the driver records that. It
  excludes the per-query client spawn/connect overhead.
- `load_time` and `data_size` are reported separately, measured by
  `lib/benchmark.sh` around each engine's `./load` (synchronous; live
  progress goes to an optional `./watch-load` sidecar in a second
  terminal).
- No cross-engine correctness validation.

## License

Apache-2.0. See [NOTICE](NOTICE).
