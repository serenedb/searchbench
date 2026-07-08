# SearchBench / Elasticsearch engine

Mirrors [TextBench](https://github.com/ClickHouse/TextBench)'s ES setup
(ES|QL via `_query`, v3-style index mapping).

`Body` keeps default `index_options: positions` + `norms: true`
(diverges from TextBench v3) so BM25 ranking on the top-k relevance
queries (Q33–Q53) is honest. (`positions` also enables the
phrase/proximity count queries Q10–Q14.)

## Run

Docker is the only supported backend:
```bash
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_100k ./benchmark.sh --index
```

`--index` triggers the corpus download + load + index build; omit it to
re-run queries only against an already-loaded engine. `SEARCHBENCH_DATA_DIR`
(required, no default) is the root data directory.

## Prerequisites

`python3` with `pyarrow`/`orjson`/`requests`
(`pip3 install --user pyarrow orjson requests`), `jq`, `curl`, `docker`,
`sudo sysctl -w vm.max_map_count=262144`. `./start` sets memlock
automatically via `--ulimit memlock=-1:-1`.

## Env

| Var | Default | Meaning |
|---|---|---|
| `ES_PORT` | `9201` | HTTP port |
| `ES_HEAP` | `30g` | JVM heap (via `ES_JAVA_OPTS`) |
| `ES_DATA_DIR` | `${PWD}/es-data` | data + logs |
| `ES_IMAGE` | `…/elasticsearch:9.3.2` | image |
| `ES_CONTAINER` | `searchbench-es` | container |

## Hand-running queries

`./query` auto-detects: lines starting with `{` → DSL POST to `_search`,
anything else → ES|QL POST to `_query`. Stdout = rows, last stderr line
= client round-trip seconds from curl's `%{time_total}` (not the
server-side `took`).

Index mapping in [`config/index_mapping.json`](config/index_mapping.json);
workload in [`queries.dsl`](queries.dsl) — 92 queries (Q01–Q92): native
DSL `_search` for Q01–Q83, ES|QL LOOKUP JOIN for Q84–Q92. Ingest is
[TextBench's `ingest.py`](ingest.py) vendored verbatim.
