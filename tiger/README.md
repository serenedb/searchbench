# SearchBench / TigerData engine

[TigerData](https://www.tigerdata.com/) (formerly Timescale) is Postgres plus
[`pg_textsearch`](https://github.com/timescale/pg_textsearch), a BM25
relevance-ranking index built on Postgres' own storage (memtable + spilled
segments, Block-Max WAND for top-k). Adapter runs the official
`timescaledb-ha` image, which ships the extension prebuilt; needs `docker`,
`psql`, `jq`. `./load` reads parquet via a `serened` container (Postgres has no
parquet path of its own), the same ingest path as the ParadeDB and Postgres
adapters.

## Run

```bash
# Smoke (streams first 1M rows over HTTPS, no full download)
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index

# Full benchmark
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index
# -> results/tigerdata_otel_logs_1b.json
```

`--index` triggers the download + load + index build; omit it to re-run
queries only. `SEARCHBENCH_DATA_DIR` (required, no default) is the root data
directory.

## What runs on pg_textsearch, and what doesn't

This adapter is a **hybrid**: pg_textsearch BM25 for relevance ranking, Postgres'
own tsvector GIN for everything else. Both indexes sit on the same table and each
query uses whichever can answer it.

pg_textsearch gives you one index (`USING bm25(body)`) and one operator,
`text <@> bm25query`. Per `pg_amop` on 1.3.0 that operator is strategy 1 of the
`bm25` access method and the **only** strategy it has: an ORDER-BY-only distance
operator (the shape of pgvector's `<->`). There is no boolean match operator, so
`ORDER BY body <@> 'terms' LIMIT k` is index-accelerated and a `WHERE` clause over
`<@>` is a seq scan even with `enable_seqscan=off`. Running the entire workload
through pg_textsearch alone was measured at **5.6× the total query time** (392 s
vs 70 s at 1M), which is why GIN carries the boolean and aggregating families.

| Query family | Index used |
|---|---|
| top-K, Q33–Q35 / Q39–Q41 (term, OR) | BM25, fully native — multi-word `<@>` is disjunctive and matches the `tsquery` `\|` set row for row |
| top-K, Q36–Q38 / Q42–Q45 / Q51–Q53 | GIN filter + BM25 ranking (AND, min-match, phrase, negation, window are beyond pg_textsearch) |
| top-K, Q46–Q47 / Q50 (prefix) | GIN + `ts_rank_cd` — BM25 cannot score prefix expansions |
| top-K, Q48–Q49 (fuzzy) | seq scan + `levenshtein_less_equal` behind a pigeonhole prefilter |
| count / group-by / recent / join (Q01–Q32, Q54–Q92) | tsvector GIN, same SQL as the vanilla Postgres adapter |

[`queries.sql`](queries.sql) documents the mapping per query. Both indexes use the
`simple` text configuration (lowercase, no stemming, no stopwords) so they agree
on what a term is.

## Indexed columns

Only the four columns the workload actually searches, filters, groups, orders or
joins on are indexed. The other eleven live **only in the heap** — no index
carries a copy:

| column | why it is indexed |
|---|---|
| `body` | searched (BM25 for top-K, GIN for boolean predicates) |
| `timestamp` | hypertable partition column — chunk exclusion plus the automatic per-chunk `(timestamp DESC)` index |

`service_name` is an equality filter and GROUP BY key but needs no index of its
own — chunk exclusion narrows the time window first and it is then a cheap Filter.
`trace_id` is the self-join key and a B-tree on it *does* help at 1M (Q86: 60 s
cap → 0.58 s), but it is deliberately **not** built: neither the vanilla Postgres
nor the ParadeDB adapter has an equivalent, so keeping it would hand TigerData an
advantage on the join column that its sibling adapters lack. At 100M it changes
nothing — all nine joins cap at 60 s for ParadeDB, Postgres and ArangoDB, and
measured on the loaded 100M set the one query that had completed (Q90) runs
~18.7 s with the index and ~17.2 s warm without, capping on a cold first try
either way. `severity_text` and `scope_name` appear only as GROUP BY keys over an
already-narrowed row set, and `severity_number` only as a secondary filter inside
a time window. `span_id`, `trace_flags`, the three attribute maps, both schema
URLs and `scope_version` are never referenced by any query. Index usage from a
full 1M run (before the `trace_id` index was removed):

| index | scans | size |
|---|---|---|
| `otel_logs_idx_trace` (B-tree) | 3,145,752 | 17 MB |
| `otel_logs_idx_tsv` (GIN) | 1,623 | 56 MB |
| `otel_logs_bm25` | 324 | 56 MB |
| `otel_logs_timestamp_idx` (auto, per chunk) | 138 | 34 MB |

All are used. A `(service_name, timestamp)` B-tree was also built at first and
then **removed**: it did register 120 scans, but dropping it changed nothing
(Q30 0.078→0.074 s, Q53 0.016→0.016 s, Q73 0.007→0.006 s, Q76 0.541→0.539 s,
Q84 0.298→0.301 s — all inside noise) because on a hypertable a time-range
predicate is answered by chunk exclusion and the `ORDER BY timestamp DESC`
families ride the automatic per-chunk time index. That saved 31 MB and ~3 s of
load. `WITH (timescaledb.transaction_per_chunk)` on the builds was also tried and
dropped — 1.431 s vs 1.374 s; it trades one long lock for per-chunk locks, which
helps concurrent writers, not a bulk load.

## Fuzzy queries

The six fuzzy queries (Q22–24, Q48–49, Q59) have no index path in either engine,
so they seq-scan — but three exact-preserving tricks cut them hard, verified to
return identical results (30,112 rows either way):

1. **Pigeonhole prefilter.** Split the pattern into `d+1` disjoint parts; a token
   within edit distance `d` must leave at least one part intact, and the token is
   a substring of `body`, so an alternation over the parts cannot produce a false
   negative — only false positives, which the exact `EXISTS` then drops.
   `d≤1 → '(conne|ction)'`, `d≤2 → '(conn|ecti|on)'`. This keeps the expensive
   `regexp_split_to_array` off almost every row.
2. **`levenshtein_less_equal`**, which short-circuits once the bound is exceeded.
3. A **length window** on the token, implied by the distance bound.

Measured at 1M: `d≤1` 11.3 s → 2.3 s (5.0×), `d≤2` 11.3 s → 5.0 s (2.3×). Total
query time for the whole workload dropped from 70.0 s to **30.3 s (2.3×)**.

A `pg_trgm` GIN index on `body` was tried and **rejected**: it took `d≤1` to 1.3 s
but made `d≤2` *worse* (4.9 s → 6.7 s, because the `on` part matches most rows so
the bitmap scan is wasted), was mixed on the raw-regex queries, and cost 141 MB
plus a 17 s build at 1M.

## Hypertable layout (and why not columnstore)

`otel_logs` is a **TimescaleDB hypertable** declared inline in
[`create_table.sql`](create_table.sql):

```sql
CREATE TABLE otel_logs (...) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'timestamp',
    tsdb.chunk_interval = :'chunk_iv'
);
```

This is the form the docs prefer over a follow-up `create_hypertable()` call
("Use `CREATE TABLE` for new hypertables", 2.23.0+; the image ships 2.29.0).
`:chunk_iv` is injected by `./load` as `psql -v chunk_iv='<n> milliseconds'`,
where n = corpus span / `TIGER_CHUNKS` (default 8) read from parquet metadata
(0.4 s even at 100M) — the span scales with the dataset (1.77 s at 1M, minutes at
1B), so no fixed interval works at every scale. Side effect: `create_table.sql`
is no longer runnable standalone; run `./load`.

Rowstore chunks. All three indexes exist per chunk, and
`create_hypertable` adds its automatic `(timestamp DESC)` index per chunk
(`otel_logs_timestamp_idx`), which turns out to matter below. The heap version's
`(service_name, timestamp)` B-tree is NOT built here — chunk exclusion replaces
it; see create_index.sql.

Measured at 1M against an identical plain heap (same indexes, same data):

| effect | heap | hypertable | why |
|---|---|---|---|
| count(term) via GIN | 0.127 s | 0.075 s | Parallel Append across per-chunk GINs — parallelism a single monolithic GIN can't get |
| histogram group-by | 0.131 s | 0.083 s | same |
| recent tails (Q69/70/74) | 0.10–0.14 s | 0.009–0.016 s | ChunkAppend walks the auto time index newest-first, stops at LIMIT 100 |
| fuzzy top-K Q48/Q49 | 2.3 / 5.0 s | **0.015 / 0.023 s** | same ordered-scan effect: the fuzzy filter is evaluated only until 100 rows pass |
| BM25 top-K | 0.007 s | 0.012 s | Merge Append over per-chunk BM25 scans — slightly worse, negligible |
| joins | 0.14 s | 0.26 s | per-chunk append on both join sides — the one regression |
| load_time | 24.0 s | 40.1 s | per-chunk index builds + insert routing |
| **total hot query time** | 30.3 s | **23.2 s** | 1.3× |

(Both columns include the fuzzy pigeonhole optimisation; against the original
unoptimised heap the total is 70.0 s → 23.2 s, 3.0×.)

**Per-chunk BM25 stats, quantified.** pg_textsearch keeps corpus statistics per
relation, so each chunk's BM25 index normalises scores over its own ~1/8 of the
corpus. On this uniform corpus that shifts absolute scores by ±1–2 % (Q38's
single tie class scores −24.58 on the heap vs −25.21 on the hypertable) and can
swap which members of a large tie class surface at the LIMIT-100 boundary —
body-level top-100 overlap across the 16 BM25-ranked queries ranges from 100/100
(most) down to 2/100 where the entire top-100 sits inside one huge tie (Q35).
Every returned row is a true match and the score classes are preserved; on a
corpus whose text distribution drifts over time this could genuinely reorder
results, but this benchmark's does not.

**Columnstore (hypercore) was measured and rejected** for the searched data. The
docs are explicit: *"Once chunks are converted to the columnstore, regular B-tree
indexes don't apply."* What remains is **sparse indexes** (minmax, bloom,
firstlast) — per-batch summaries that answer only "can I skip this whole ~1000-row
batch?", never "which rows contain this term".

Measured at 1M: converting drops every chunk index, BM25 top-K becomes impossible
(`ERROR: no BM25 index found`), GIN counts go 0.08 s → 1.66 s (ColumnarScan
re-evaluates `to_tsvector` per row), histograms 0.08 s → 5.9 s. Creating the
indexes *after* conversion "succeeds" but builds **empty** ones — 16 kB GIN and
8 kB bm25 versus 56 MB each on rowstore — because the user-facing chunk holds no
rows: data lives in a separate `_compressed` relation with ~1000 original rows
packed into one stored row, so there are no per-row TIDs for an index to point at.

The 2.18 blog feature *["PostgreSQL indexes for the
columnstore"](https://www.tigerdata.com/blog/postgresql-indexes-for-columnstore)*
does not change this, for two independent reasons: it covered **B-tree and hash
only** (never GIN, never a custom AM like bm25), and it required the experimental
**hypercore table access method**, which was deprecated in 2.21 and **removed in
2.22**. Verified on this build — `ALTER TABLE … SET ACCESS METHOD hypercore` fails
with `access method "hypercore" does not exist`, and `pg_am` lists only `heap`.

What columnstore wins is spectacular but irrelevant here: **1173 MB → 53 MB
(22×)** and 5.5× on pure structured aggregates (`GROUP BY service_name` with no
text predicate) — of which the workload has none. A production logs system would
compress *old* chunks and keep searched ones in rowstore; in this benchmark every
chunk is searched by every query.

Also evaluated and not applicable: **`enable_chunk_skipping()`** — it tracks
per-chunk min/max for `smallint, int, bigint, serial, bigserial, date, timestamp,
timestamptz` only, and requires a compressed hypertable. Our non-time filters are
`service_name` (text, and present in every chunk) and `trace_id` (text, random),
so there is nothing for it to skip.

The five histogram queries (Q61–Q65) use `time_bucket('1 minute', …)` — verified
to produce output identical to `date_trunc('minute', …)`, marginally faster on
the hypertable (73 vs 87 ms).

## Ingest parallelism

`./load` fans the corpus out over `TIGER_LOAD_JOBS` serened containers, each
holding its own Postgres connection and inserting a contiguous row range
(`file_row_number >= lo AND < hi`, bounds computed from the parquet row count —
metadata only, 0.27 s even for the 100M part).

This is worth doing because Postgres has **no parallel DML**: `INSERT … SELECT`
parallelises the select side, but the insert runs entirely in the leader backend,
so one connection is one process is one core. Measured single-stream, the
receiving backend pins 90–100 % of a core while serened's reader only reaches
45–80 % — the write side is the ceiling, and more connections is the only way to
use more of the box.

Measured wall-clock for the whole ingest on this box (32 cores):

| streams | 1M rows | 10M rows |
|---|---|---|
| 1 | 10.4 s | 105.9 s |
| 4 | **3.7 s** | 38.5 s |
| 8 | 4.0 s | **29.4 s** |
| 16 | 7.4 s | 33.0 s |
| 24 | — | 34.4 s |
| 32 | — | 41.9 s |

The plateau is 8–16 streams and then it regresses: past that the streams contend
on the **write** side — WAL-insert locks, relation extension, buffer manager —
not on reading the parquet. The optimum moves with scale because each stream pays
a fixed container startup: at 1M rows 4 wins and 16 is twice as slow, while by
10M that has reversed. 16 is the default; drop it for smoke-scale runs.

Each stream decodes only its own share of the file, because the reader
**row-group-prunes** the `file_row_number` range predicate. Verified on the 100M
part (163 row groups): summing a column over the *last* row group costs 0.28 s —
the same as the first, and well under the 1.57 s full scan. That is also why
contiguous ranges beat `mod(file_row_number, K)` by ~7 %: a modulo matches rows in
every group, so every stream has to decode everything.

Slice bounds are deliberately *not* snapped to row-group boundaries. An unaligned
cut makes the single group it lands in get decoded by both neighbouring streams
(~9 % extra decode at K=16 over 163 groups), but decode is not the bottleneck: an
A/B at 10M rows over 4 samples each gave 33.2 s unaligned vs 31.8 s aligned with
identical best cases — inside the run-to-run noise, and not worth the extra
metadata round-trip.

Schema in [`create_table.sql`](create_table.sql) +
[`create_index.sql`](create_index.sql); workload in
[`queries.sql`](queries.sql).
