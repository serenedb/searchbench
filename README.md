# SearchBench

A benchmark for full-text search engines on log-shaped data.

The workload is 92 queries (Q01–Q92): Q01–Q83 cover search and
aggregation, Q84–Q92 cover joins. Queries derived from
[TextBench](https://github.com/ClickHouse/TextBench) (Apache-2.0) let rows
compare against TextBench's leaderboard, and the added BM25-scored top-K
queries cover a regime TextBench skips.

The runner shape follows
[ClickBench](https://github.com/ClickHouse/ClickBench): each engine
implements `./install`, `./start`, `./stop`, `./check`, `./load`,
`./query`, `./data-size`; the shared `lib/benchmark.sh` orchestrates.

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

## Adding an engine

Create `<engine>/` with an executable script per verb the driver calls, plus a
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

## Vector search

A stand-alone **vector (ANN)** track lives alongside the text harness, reusing
the same adapter/driver/UI conventions. It measures **recall@k vs QPS** (plus
build time and index size) for **SereneDB** (IVF) vs **pgvector** — HNSW and
IVFFlat run as separate series (different algorithms) — across three distances
(Cosine / L2 / Inner-Product) × three size tiers. The shared
driver is `lib/benchmark-vector.sh` (mirrors `lib/benchmark.sh`); results land in
`<engine>/results-vector/` and render via `vector-ui/`. Offline smoke:

```bash
cd serenedb && SEARCHBENCH_DATA_DIR=/data SEARCHBENCH_VECTOR_DATASET=synthetic ./benchmark-vector.sh --index
```

See [VECTOR.md](VECTOR.md) for datasets, knobs, the result schema, and the runbook.

## License

Apache-2.0. OTel-logs corpus + TextBench-derived queries (Apache-2.0);
per-engine adapter contract patterned after ClickBench. See [NOTICE](NOTICE).
