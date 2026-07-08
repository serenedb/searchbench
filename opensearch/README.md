# SearchBench / OpenSearch engine

ES-API-compatible fork of Elasticsearch. Single-pass adapter: of the 92
queries (Q01–Q92, aligned 1:1 with `serenedb`), 83 are native DSL
`_search` bodies and the 9 join queries map to NULL (OpenSearch has no
self-join and no ES|QL).

## Run

Docker is the only supported backend:
```bash
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_100k ./benchmark.sh --index
# -> results/opensearch_otel_logs_100k.json
```

`--index` triggers the corpus download + load + index build; omit it to
re-run queries only. `SEARCHBENCH_DATA_DIR` (required, no default) is the
root data directory.

Prerequisites: `python3` with `pyarrow`/`orjson`/`requests`, `jq`, `curl`,
`docker`, `sudo sysctl -w vm.max_map_count=262144`. `./start` adds `--ulimit
memlock=-1:-1` automatically.

## Env

| Var | Default | Meaning |
|---|---|---|
| `OS_PORT` | `9200` | HTTP port |
| `OS_HEAP` | `30g` | JVM heap |
| `OS_DATA_DIR` | `${PWD}/os-data` | data + logs |
| `OS_IMAGE` | `opensearchproject/opensearch:2.18.0` | image |
| `OS_CONTAINER` | `searchbench-os` | container |

Index mapping in [`config/index_mapping.json`](config/index_mapping.json)
(same v3+positions shape as `elastic/`); workload in
[`queries.dsl`](queries.dsl). Ingest is the same vendored TextBench
`ingest.py`.
