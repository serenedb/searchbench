# YDB adapter

[YDB](https://ydb.tech) 26.3.1.8, queried through YQL over the native gRPC API.

```
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_10m \
  ./benchmark.sh --index      # prep + load + index + query
```

## Turning full-text search on

The public docs do not mention it and `CREATE INDEX` documents only `secondary`
and `vector_kmeans_tree`, but YDB **does** have a full-text index. Three things
have to line up:

| | |
|---|---|
| image | **26.3.1.8**. `local-ydb:latest` is 26.1.1.22, where `FulltextMatch` exists but the index type is rejected |
| flag | `--enable-feature-flag enable_fulltext_index` — **snake_case**. The CamelCase `EnableFulltextIndex` is accepted by the CLI and then kills the server: `unknown field "EnableFulltextIndex" for NKikimrConfig.TFeatureFlags` |
| syntax | `INDEX idx GLOBAL USING fulltext_relevance ON (col) WITH (tokenizer="whitespace", use_filter_lowercase=true)` |

`fulltext_plain` also exists; `fulltext_relevance` is used here because
`FulltextScore` (BM25) needs it and the 19 `_score`-sorted top_k queries rank by
it. `FulltextMatch` works on either.

## Row tables only

`STORE = COLUMN` **silently drops the fulltext index**: the table is created
with no error and no warning, `scheme describe` shows no `Indexes` section, and
queries then fail with `No global indexes for table`. Adding it afterwards is at
least explicit:

```
ALTER TABLE ... ADD INDEX ... USING fulltext_relevance
  -> Only local_bloom_filter_index, local_bloom_ngram_filter_index and
     local_min_max_index ... are supported for column tables
```

So full-text search implies row storage, and row storage is what bounds the
corpus (see below). Column tables can take bloom/ngram/min-max skip indexes
(gated behind `EnableLocalBloomNgramFilterIndex` and friends), which would
compress far better but give scans rather than an inverted index -- no
`FulltextMatch`, no relevance ranking.

## Scale is capped at 64 GiB, which is why this runs at 10M

`local_ydb deploy` always formats a **64 GiB** PDisk file and exposes no size
knob. Measured footprint is **~5.3 GB per million rows** (52.6 GB at 10M), so
100M would need roughly 500 GB -- about 8x what the image allows. The expansion
is ~60x over the source parquet: `Body` plus the duplicate `BodyNorm`, three
JSON-encoded attribute maps, per-row overhead, and the index.

Everything tried, and why it does not lift the cap:

| attempt | outcome |
|---|---|
| `YDB_TINY_MODE=false` | still 64 GiB |
| pre-create a larger PDisk file | deploy truncates it back |
| pre-create + `chattr +i` | deploy dies with `PermissionError` |
| grow the file after format | server still reports 64 GiB — capacity lives in the format record |
| grow + `ydbd admin bs disk obliterate` + restart | **reformats at 400 GiB**, but destroys the domain's storage pools |
| run `ydbd` directly against a large file | **400 GiB**, same storage-pool loss |

After any reformat the database rejects every `CREATE TABLE` with
`database doesn't have storage pools at all`, and it cannot be repaired:
`/local` is the domain root rather than a tenant, so
`ydbd admin database /local pools add hdd:1` answers
`Database '/local' doesn't exist`, and `DefineStoragePool` fails with
`no group options PDisks# <empty>` because the single PDisk is already consumed
by the static group. Only `local_ydb deploy` knows how to bootstrap those pools,
and it only does so on a 64 GiB disk.

Lifting this needs a hand-authored multi-PDisk static config run against `ydbd`
directly. **Do not reintroduce an obliterate-based resize in `./start`**: it
yields a cluster that looks healthy and cannot create tables.

## The analyzer is materialised at ingest

The reference analyzer is lowercase + split on **every** non-alphanumeric, so
`order_id=55` must yield `order`, `id`. No YDB tokenizer does this: `standard`
keeps `order_id` whole (it misses the term), `whitespace` splits only on spaces,
`keyword` not at all, and `lowercase_subword` is named in the binary but is not
a valid tokenizer value.

`prep.py` therefore writes a `BodyNorm` column -- lowercase, every
non-alphanumeric run collapsed to one space -- and the index uses `whitespace`
over it. Same approach as the victorialogs adapter. Because `BodyNorm` is
single-space delimited, a token test is a substring test on a padded copy and a
token regex anchors on `" "`, which also turns prefix/suffix/infix patterns into
`String::Contains` rather than RE2 (8 queries -> 1 still needs RE2).

## Loading

Three stages, in this order, because they cannot be reordered:

1. `prep.py` rewrites the parquet into YDB's schema in parallel (map columns
   JSON-encoded, us timestamps, `BodyNorm` computed), emitting many files.
2. `ydb import file parquet --threads 31` loads the directory. This is **31,250
   rows/s against 6,606 rows/s** for the Python `BulkUpsert` path, which is why
   prep writes a directory rather than one file.
3. `ALTER TABLE ADD INDEX` builds the fulltext index afterwards.

The index **cannot** exist during the load: both bulk paths reject a table
carrying a synchronous index (`Only async-indexed tables are supported by
BulkUpsert`), and fulltext indexes cannot be async --
`FULLTEXT_RELEVANCE index can only be GLOBAL [SYNC]`. Ordinary `secondary`
indexes do support `GLOBAL ASYNC`; fulltext simply is not allowed to be one.

The build is asynchronous, so `./load` takes completion from
`ydb operation list buildindex`, not from `ALTER` returning, and verifies the
final row count against the parquet.

Two traps worth naming: `/ydb_data` must be a host mount on a large filesystem
(left inside the container it filled the docker root fs and the server died with
a PDisk `No space left on device`), and `install` must wipe that mount, because
`/ydb_certs` is *not* mounted -- a surviving deployment with a fresh container
skips deploy, never regenerates certs, and the server exits with
`File passed to --ca/ic-ca does not exist`.

## Query coverage — 92/92

The only non-SQL engine in this suite to express the entire workload, joins
included. YDB reaches the index through a narrow door and `translate.py` is
built around its rules:

| rule | consequence |
|---|---|
| one fulltext predicate per read, reachable by conjunction | `OR` / `minimum_should_match` become a `UNION` of single-predicate index reads |
| `NOT FulltextMatch(..)` rejected | `must_not` becomes a scalar `String::Contains` test |
| `FulltextMatch` and `FulltextScore` cannot share a read | score-ranked queries use `FulltextScore(..) > 0` as the matcher and sort by the same expression |
| multi-term `FulltextMatch` is AND, with no operator argument | (a `Mode` argument is accepted and then silently matches nothing) |

**Every filter is pushed into each UNION arm.** The natural alternative,
`SELECT count(*) FROM otel_logs WHERE Id IN (<union>)`, is correct but scans the
base table: **30.5s against 0.34s** for the same answer on 1M rows.

`regexp`, `wildcard`, `prefix`, `fuzzy` and phrase adjacency have no index path
and run as scans. Fuzzy uses `String::LevensteinDistance` per token, which is
exact but unindexed -- and the three fuzzy queries are the slowest in the suite
at ~9.4s each.

## Verified against ground truth

All 10 probes exact at 10M, recomputed from the parquet with the reference
analyzer rather than compared against another engine:

| case | YDB | truth |
|---|---:|---:|
| term `error` | 1,050,294 | 1,050,294 |
| term `cache` | 539,170 | 539,170 |
| underscore: `order` | 863,537 | 863,537 |
| AND `failed`+`order` | 826,852 | 826,852 |
| OR `error`\|`failed` (UNION) | 1,541,429 | 1,541,429 |
| phrase | 359,777 | 359,777 |
| prefix `charg*` | 639,274 | 639,274 |
| `must_not`: error !cache | 569,883 | 569,883 |
| `term` ServiceName=cart | 3,925,979 | 3,925,979 |
| range severity>=13 | 870,706 | 870,706 |

At 1M, all 41 count-shaped queries matched SereneDB's verified results exactly.

## Results at 10M

| | |
|---|---|
| load | 359.7s (prep + 31k rows/s import + index build), 10,000,000 rows verified |
| on disk | 52.6 GB — measured as allocated blocks, not `du -sb`, which reports the sparse 64 GiB PDisk file for every corpus |
| queries | **92/92 ran, 233.7s total hot**, 0 timeouts |
| by task | count 73.1s/32 · group_by 54.3s/14 · join 40.5s/9 · top_k 33.0s/21 · recent 32.7s/16 |

This is slow, and it is not a translation artifact: `EXPLAIN` confirms the plans
use `ReadFullTextIndex`. A plain term count over 1.05M matching rows costs
0.48s. For scale, SereneDB runs all 92 queries in 4.09s at **100M**.

## Environment

| var | default | meaning |
|---|---|---|
| `YDB_IMAGE` | `ydbplatform/local-ydb:26.3.1.8` | pinned image — `latest` has no fulltext index |
| `YDB_CONTAINER` | `searchbench-ydb` | container name |
| `YDB_DATA_DIR` | `/mnt/data/mkornaukhov/data/ydb-data` | host mount for `/ydb_data` — must be on a large filesystem |
| `YDB_STAGE_DIR` | `/mnt/data/mkornaukhov/data/ydb-stage` | staged YDB-schema parquet |
| `YDB_GRPC_PORT` | `2136` | gRPC port |
| `YDB_PREP_PROCS` | `30` | prep parallelism |
| `YDB_IMPORT_THREADS` | `31` | `ydb import` threads |
