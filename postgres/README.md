# SearchBench / Postgres FTS engine

Vanilla Postgres 16, GIN over the expression `to_tsvector('simple', body)`
(no stored/generated column), plus the `fuzzystrmatch` extension for
`levenshtein()` (used by the fuzzy queries Q22–24, 48–49, 59).
`ts_rank_cd` is the closest analog to BM25 for the Q33–Q53 top-k ranking
queries (not actual BM25; results compare in intent, not score).

Same load shape as `parade/`: a `serened` container (DuckDB-backed) reads the
parquet corpus and INSERTs it straight into Postgres over the wire via its
postgres connector (`ATTACH … (TYPE postgres); INSERT INTO pg.otel_logs …
SELECT … FROM read_parquet(…)`) — no CSV/`\copy` round-trip.

## Run

```bash
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index

# Full
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index
# -> results/postgres_otel_logs_1b.json
```

`--index` triggers the download + load + index build; omit it to re-run
queries only.

Prerequisites: `docker`, `psql`, `jq`. `./load` reads parquet via a `serened`
container (`SERENED_IMAGE`, default `serenedb/serenedb:26.07.1`).

## Env

| Var | Default | Meaning |
|---|---|---|
| `SERENED_IMAGE` | `serenedb/serenedb:26.07.1` | serened image used as parquet reader |
| `SEARCHBENCH_DATA_DIR` | — | root data directory (required, no default) |
| `PGPORT` | `5457` | host port (avoids 5455/SereneDB + 5456/Parade) |
| `PG_IMAGE` | `postgres:16-alpine` | image |
| `PG_CONTAINER` | `searchbench-postgres` | container |
| `PG_DATA_DIR` | `$PWD/postgres_data` | host bind-mount data dir; wiped by `./install` |

Schema in [`create_table.sql`](create_table.sql) +
[`create_index.sql`](create_index.sql); workload in
[`queries.sql`](queries.sql).
