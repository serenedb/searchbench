# SearchBench / TigerData engine

[TigerData](https://www.tigerdata.com/) (formerly Timescale) is Postgres plus
[`pg_textsearch`](https://github.com/timescale/pg_textsearch), a BM25 index built
on Postgres' own pages. Adapter runs the official `timescaledb-ha` image, which
ships the extension prebuilt; needs `docker`, `psql`, `jq`. `./load` reads parquet
via a `serened` container, same path as Postgres adapter.

## Run

```bash
# Smoke (streams first 1M rows over HTTPS, no full download)
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index

# Full benchmark
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index
# -> results/tigerdata_otel_logs_1b.json
```

`--index` triggers download + load + index build; omit it to re-run queries only.

## Design

Two text indexes on one table. `pg_textsearch`'s `<@>` is an ORDER-BY-only
operator, the single strategy the `bm25` AM exposes, so it serves
`ORDER BY body <@> q LIMIT k` and nothing else. Top-K (Q33-Q53) uses BM25; every
boolean and aggregating query uses tsvector GIN, with the same SQL as the Postgres
adapter.

`otel_logs` is a hypertable of rowstore chunks, interval = corpus span /
`TIGER_CHUNKS` computed from parquet metadata at load time. Per-chunk indexes let
the GIN families use a Parallel Append, and time-ordered `LIMIT` queries exit
early off the automatic per-chunk time index. Two consequences: index builds cost
more at load, and BM25 scores are normalised per chunk rather than globally
(1-2% score drift, same rows returned).

Indexed columns are `body` and `timestamp`. The other 13 live only in the heap.

Fuzzy queries (Q22-24, Q48-49, Q59) have no index path and seq-scan behind a
pigeonhole prefilter: with the pattern split into d+1 parts, one part survives d
edits, so an alternation over them cannot produce a false negative.

## Env

| Var | Default | Meaning |
|---|---|---|
| `SERENED_IMAGE` | `serenedb/serenedb:26.07.5` | parquet reader |
| `PGPORT` | `5458` | host port |
| `TIGER_IMAGE` | `timescale/timescaledb-ha:pg17.10-ts2.29.0` | PG 17.10 / TS 2.29.0 / pg_textsearch 1.3.0 |
| `TIGER_CONTAINER` | `searchbench-tiger` | container name |
| `TIGER_DATA_DIR` | `$PWD/tiger_data` | bind-mount data dir; wiped by `./install` |
| `TIGER_CHUNKS` | `8` | hypertable chunk-count target |
| `TIGER_LOAD_JOBS` | `16` | parallel ingest streams |
| `TIGER_SHM_SIZE` | `2g` | `/dev/shm`; the 64 MB default breaks parallel joins |

`pg_textsearch` must be in `shared_preload_libraries`; [`start`](start) passes
`-c shared_preload_libraries=timescaledb,pg_textsearch`.

Schema in [`create_table.sql`](create_table.sql) +
[`create_index.sql`](create_index.sql); workload and dialect notes in
[`queries.sql`](queries.sql); ingest parallelism in
[`../lib/pg-parallel-ingest.sh`](../lib/pg-parallel-ingest.sh).
