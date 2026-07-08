# SearchBench / ParadeDB engine

[ParadeDB](https://www.paradedb.com/) is Postgres + the `pg_search` BM25
extension. Adapter runs the official Docker image; needs `docker`, `psql`,
`jq`. `./load` reads parquet via a `serened` container (ParadeDB has no
parquet path of its own).

## Run

```bash
# Smoke (streams first 1M rows over HTTPS, no full download)
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index

# Full benchmark
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index
# -> results/paradedb_otel_logs_1b.json
```

`--index` triggers the download + load + index build; omit it to re-run
queries only. `SEARCHBENCH_DATA_DIR` (required, no default) is the root
data directory.

For live progress during a long index build, run `./watch-load` in a
second terminal.

## Env

| Var | Default | Meaning |
|---|---|---|
| `SERENED_IMAGE` | `serenedb/serenedb:26.07.1` | serened image used as parquet reader |
| `PGPORT` | `5456` | host port (5455 is SereneDB's) |
| `PARADE_IMAGE` | `paradedb/paradedb:0.24.1` | image tag (pinned; provides the `simple` tokenizer / `pdb.simple` cast used by `create_index.sql`) |
| `PARADE_CONTAINER` | `searchbench-paradedb` | container name |
| `PARADE_DATA_DIR` | `$PWD/paradedb_data` | host bind-mount data dir; wiped by `./install` |

Schema in [`create_table.sql`](create_table.sql) +
[`create_index.sql`](create_index.sql); workload in
[`queries.sql`](queries.sql).
