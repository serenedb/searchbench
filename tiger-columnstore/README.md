# SearchBench / TigerData columnstore

[TigerData](https://www.tigerdata.com/) over TimescaleDB's **columnstore**
(hypercore) instead of rowstore chunks. Same engine, same image, same corpus,
same 92 queries and the same 15-column schema as [`../tiger`](../tiger) — the
only differences are [`create_table.sql`](create_table.sql), which declares the
columnstore, and [`create_index.sql`](create_index.sql), which converts the chunks
instead of building text indexes. A delta against the TigerData column therefore
isolates the storage engine and nothing else.

## Run

```bash
# Smoke (streams first 1M rows over HTTPS, no full download)
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index

# Full benchmark
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index
# -> results/tigerdata-columnstore_otel_logs_1b.json
```

## Shape

Every mechanic — `install`, `start`, `stop`, `check`, `load`, `query`,
`data-size`, `version`, `common.sh`, `queries.sql` — is a **symlink** to the tiger
adapter. Those scripts resolve paths against their own
`$(dirname $0)`, which for a symlink invoked from here is *this* directory, so
`create_index.sql` and `tiger_data/` resolve locally. There is no second copy of
the adapter to keep in sync, and a workload fix lands in both engines at once.

`benchmark.sh` gives this adapter its own port (`5459`), container
(`searchbench-tiger-columnstore`) and data dir, so it coexists with `../tiger`
rather than overwriting its PGDATA — both hold a table called `otel_logs`, and
both can stay loaded on the same box.

**The hypertable is not optional.** TimescaleDB's columnstore is a per-chunk
property of a hypertable — `enable_columnstore`, `segmentby`/`orderby` and
`compress_chunk()` all operate on chunks, and there is no columnstore for a plain
Postgres table. So `create_table.sql` still declares one; what differs is that it
declares the chunks columnar at birth:

```sql
) WITH (
    tsdb.hypertable,
    tsdb.partition_column   = 'timestamp',
    tsdb.chunk_interval     = :'chunk_iv',
    tsdb.enable_columnstore = true,
    tsdb.segmentby          = 'service_name',
    tsdb.orderby            = 'timestamp DESC'
);
```

`segmentby = service_name` is the workload's one low-cardinality equality key
(Q31, Q53, Q66, Q68, Q72-Q73, Q76, Q80-Q81, and `b.service_name` in every join
Q84-Q92), so those filters skip whole batches. `orderby = timestamp DESC` is the
partition column and the sort of every `recent` query, which puts a minmax sparse
index on timestamp so the `BETWEEN` windows prune.

Declaring the columnstore does not compress anything by itself — rows still land
in the rowstore. Load runs the same four phases as tiger (schema, ingest, analyze,
then `create_index.sql`), and `create_index.sql` does the conversion:

```sql
SELECT compress_chunk(c) FROM show_chunks('otel_logs') c;
```

so `load_time` covers the columnstore rewrite exactly as tiger's covers its index
builds. `tsdb.direct_compress` (2.29, compress on INSERT) would skip the rewrite
but changes the ingest path, so this adapter takes the documented
load-then-convert route.

## No secondary index survives the conversion

That is what this column measures, not a misconfiguration. Converting a chunk
drops its indexes; only the columnstore's own sparse indexes (minmax / bloom /
firstlast) remain, and those skip ~1000-row batches rather than locating rows.
The hypercore table access method — the one form that carried B-tree indexes over
columnstore chunks — shipped in TimescaleDB 2.18 and was **removed in 2.22**
("btrees were not the right architecture"), so on 2.29.2 no configuration puts a
BM25 or GIN index in front of a columnstore chunk. Every text predicate in
[`queries.sql`](../tiger/queries.sql) therefore decompresses batches and filters:
slow, but correct.

`CREATE INDEX` on a converted hypertable does not *fail* — it succeeds and
indexes nothing, because the rows now live in an internal compressed relation
while the chunk the index hangs off is empty. Measured at 1M with the BM25 index
built exactly as the rowstore adapter builds it:

| Q33 (top-K, `<@>` on a term) | rows | time |
|---|---:|---:|
| rowstore | 100 | 0.017s |
| columnstore | **0** | 13.2s |

Zero rows, no error. Scores collapse to 0.0 for want of corpus statistics, so the
`(body <@> q) < 0` guard discards everything — and in the Q36-Q45 shapes, where a
tsquery filters and `<@>` only ranks, all-zero scores turn `ORDER BY` into one big
tie and `LIMIT 100` returns an arbitrary slice. Fast, silent and wrong is the worst
thing a benchmark can publish, so **no index is built here at all**.

That has a deliberate, visible consequence. `queries.sql` resolves the BM25 index
*by name* (`to_bm25query('charge', 'otel_logs_bm25')`), so with no such index
Q33-Q45 and Q51-Q53 fail outright; the driver records them as errors and the UI
shows them as gaps, the same as any query an engine cannot answer. That is the
honest report: pg_textsearch's BM25 index has no implementation over columnstore
chunks. The other 76 queries return results identical to the rowstore adapter's,
just slower.

## Env

Identical to [`../tiger`](../tiger/README.md#env), with three defaults changed
here:

| Var | Default | Meaning |
|---|---|---|
| `PGPORT` | `5459` | host port (tiger uses 5458) |
| `TIGER_CONTAINER` | `searchbench-tiger-columnstore` | container name |
| `TIGER_DATA_DIR` | `$PWD/tiger_data` | resolves to `tiger-columnstore/tiger_data` |
