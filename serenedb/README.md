# SearchBench / SereneDB engine

Runs the official SereneDB Docker image (`serenedb/serenedb:26.07.1`).
Prereqs: `docker`, `psql`, `jq`.

`SEARCHBENCH_DATA_DIR` is the root data dir; the driver roots each scale
under `.../<dataset>/` and the download step materializes the parquet there
(full parts for real scales, a sliced part_000.parquet for smoke).

```bash
# Full benchmark (otel_logs_1b) — --index does download + load + index build
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index
# -> results/serenedb_otel_logs_1b.json

# Smoke (1M rows, sliced + streamed by the download step in seconds)
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index
```

`--index` (or `SEARCHBENCH_INDEX=1`) triggers the download + load + index
build; omit it to re-run queries only against an already-loaded engine.

The container runs with `--network host` (native latency); the corpus is
identity-mounted read-only so `create.sql`'s `read_parquet` resolves inside it.

## Env

| Var | Default | Meaning |
|---|---|---|
| `SERENED_IMAGE` | `serenedb/serenedb:26.07.1` | image |
| `SERENED_CONTAINER` | `searchbench-serenedb` | container |
| `SERENED_DATA_DIR` | `$PWD/serened_data` | host bind-mount data dir (→ `/var/lib/serenedb`); wiped by `./install` |
| `PGPORT` | `5499` | pg-wire host port |

Schema + indexed expression in [`create.sql`](create.sql);
workload in [`queries.sql`](queries.sql).
