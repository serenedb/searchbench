# SearchBench / ArangoDB engine

[ArangoDB](https://www.arangodb.com/) arangosearch view engine (IResearch
under the hood) on the OTel-logs / 92-query (Q01–Q92) workload.

Runs the official image `arangodb/enterprise:3.12` (Enterprise features are
free from 3.12.5; needed for `optimizeTopK`). Prereqs: `docker`, `jq`, `curl`.
`./load` converts parquet → NDJSON via a throwaway `serened` container — no
local `serened` binary required.

## Run

```bash
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index

# Smoke (1M rows, sliced over HTTPS)
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index
```

`--index` triggers download + load + index build; omit it to re-run queries
only. The arangosearch link is async, so `./load` waits for
`view_count == collection_count` (stable 2 ticks) before returning — that wait
is the load-completion signal, decoupled from print cadence so `load_time` is
unaffected by `SEARCHBENCH_PROGRESS_INTERVAL`.

## Env

| Var | Default | Meaning |
|---|---|---|
| `SERENED_IMAGE` | `serenedb/serenedb:26.07.2` | serened image (parquet→NDJSON reader) |
| `ARANGO_PORT` | `8529` | listen port |
| `ARANGO_IMAGE` | `arangodb/enterprise:3.12` | image |
| `ARANGO_CONTAINER` | `searchbench-arango` | container |
| `ARANGO_DATA_DIR` | `$PWD/arango_data` | host bind-mount data dir; wiped by `./install` |
| `ARANGOIMPORT_THREADS` | `4` | import parallelism |

Index + analyzer in [`load`](load); workload in [`queries.aql`](queries.aql).
Query latencies come from each cursor's `extra.stats.executionTime`.
