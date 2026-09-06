# Manticore Search

Manticore Search adapter (Docker, HTTP JSON API on `/search` + `/bulk`).

## Run

```bash
SERENED_BIN=/path/to/serened \
SEARCHBENCH_DATASET=otel_logs_100k \
./benchmark.sh
```

## Env

| Var | Default | Notes |
| --- | --- | --- |
| `MANTICORE_HTTP_PORT` | `9308` | host port mapped to container :9308 |
| `MANTICORE_IMAGE`     | `manticoresearch/manticore:7.4.6` | |
| `MANTICORE_DATA_DIR`  | `${PWD}/manticore-data` | bind-mounted to `/var/lib/manticore` |
| `MANTICORE_CONTAINER` | `searchbench-manticore` | |
| `MANTICORE_TABLE`     | `otel_logs` | |
| `SERENED_BIN`         | (required) | parquet reader |

## Shape

- `./load` creates the RT table via SQL on `/cli`, streams `serened shell
  -jsonlines` into `ingest.py`, which POSTs `/bulk` batches. Final phase
  is `OPTIMIZE TABLE` so on-disk size is steady.
- `./query` reads one JSON body per line from stdin, POSTs `/search`,
  parses `took` (ms) for the timing.
  (Manticore's `timestamp` type) rather than ISO strings.

## Known issue

Manticore 7.4.6 has a bug in the HTTP JSON `range` filter: putting `gte`
and `lt` in the same range object returns 0 hits. Splitting them into
two range clauses (`{range:{ts:{gte:X}}}, {range:{ts:{lt:Y}}}`) works,
which is what Q1/Q2/Q14 do. The SQL `BETWEEN` form is also unaffected.

## Row vs columnar storage

Both storage engines are benchmarked. Select with `SEARCHBENCH_VERSION=columnar`,
which also labels the UI column "Manticore (columnar)" and writes a separate
results file, so the two coexist:

```bash
SERENED_BIN=... ./benchmark.sh --index                      # row
SEARCHBENCH_VERSION=columnar SERENED_BIN=... ./benchmark.sh --index
```

Measured at 100m, same corpus, same schema:

| | row | columnar |
|---|---:|---:|
| queries | 82/92 | 82/92 |
| total hot | 6.09s | 5.59s |
| load | 1230s | 1215s |
| on disk | 38.1 GB | 36.0 GB |

Columnar buys roughly 5% disk and is within noise on query time (per task the
two runs differ by -2% to +2%, and repeat runs of the same variant move by a
similar amount). The full-text index and the lz4hc docstore are identical either
way; only attribute storage changes, and this workload's filters are cheap
relative to the text matching.

`DROP TABLE` leaves `/var/lib/manticore/<table>` behind, so `CREATE` then fails
with `directory is not empty`. Harmless when re-running the same schema, fatal
when switching engine, so `./load` removes the directory explicitly.

## Fuzzy queries must not carry a field operator

Manticore's fuzzy search is a query-level `OPTION`, and its `MATCH` clause must
contain no full-text operators. With the field restriction in place the query
silently returns near-nothing instead of erroring:

| query | result |
|---|---:|
| `MATCH('@body connection') OPTION fuzzy=1, distance=1` | **2** |
| `MATCH('connection') OPTION fuzzy=1, distance=1` | **1,340,425** |
| Elasticsearch `fuzziness=1` | 1,340,425 |

All five fuzzy queries (Q22, Q23, Q48, Q49, Q59) therefore drop `@body`. Dropping
it does not widen the search in practice: the count matches Elasticsearch
exactly, which searches Body alone.

Q23 (`distance=2`) returns 1,340,425 against Elasticsearch's 1,340,443 — 18 rows
in 1.34M, 0.001%. Manticore's `distance=2` returns the same set as `distance=1`,
so its edit-distance expansion is slightly narrower than Lucene's. Left as an
engine difference rather than worked around.

## Query cache

Manticore ships a query cache **on** by default (`qcache_max_bytes` = 16MB). It
only stores result sets for queries slower than `qcache_thresh_msec` (3000ms),
and at this workload's ~70ms per query nothing ever qualified —
`qcache_cached_queries` read 0 after a full 92-query run, and the cold/hot ratio
is 1.0-1.1x. `./start` sets `qcache_max_bytes=0` anyway on every launch, so a
future query, scale or threshold change cannot silently turn the benchmark into
a cache-lookup measurement.
