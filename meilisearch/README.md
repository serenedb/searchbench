# Meilisearch adapter

[Meilisearch](https://www.meilisearch.com) v1.53.1 on LMDB, queried through its
own REST API.

```
./benchmark.sh --index      # load + run
./benchmark.sh              # query-only
```

## No Elasticsearch compatibility

Unlike VictoriaLogs (which accepts the ES `_bulk` format, letting that adapter
reuse this repo's ES ingest pipeline), Meilisearch has no ES-compatible surface
at all. Every ES route 404s — `/_search`, `/indexes/<uid>/_search`, `/_bulk`,
`/_cat/indices` — and posting an ES DSL body to its own search route is rejected:

```
Unknown field `query`: expected one of `q`, `offset`, `limit`, `page`,
`hitsPerPage`, `attributesToRetrieve`, ...
```

So both the ingest path and the query translator are Meilisearch-specific.

## Ingest: linear, but only if the client does not outrun the queue

Two complete runs, same settings:

| scale | load | on disk | docs/s |
|---|---:|---:|---:|
| otel_logs_1m | 67.7s | 3.50 GB | 14,771 |
| otel_logs_10m | 659.3s | 33.23 GB | 15,338 |

10× the data for **9.7× the time and 9.5× the disk** — linear, no degradation.
100m therefore projects to ~1.8 h and ~330 GB.

That contradicts an earlier reading of "4.7× slower by 1.7% of the corpus",
which was wrong twice over and is recorded here because both mistakes are easy
to repeat:

1. **Client parallelism.** Meilisearch indexes through a SINGLE serial task
   queue, so extra client processes add no throughput — they only enqueue
   faster, and each pending task's payload is persisted as an update file. Eight
   ingest processes built a ~2,000-task backlog and ~100 GB of update files,
   whose I/O then competed with indexing: 4,268 docs/s at 1.7M documents versus
   13,600+ at a comparable index size with four processes. Keep
   `SEARCHBENCH_LOAD_PROCESSES` low; 4 is enough to saturate the queue.
2. **Sampling between commits.** Meilisearch commits in large batches, so
   `numberOfDocuments` is flat for minutes and then jumps (observed:
   3,154,432 → 8,268,608 in one step). Any rate sampled over a short window is
   either 0 or wildly inflated. Only end-to-end timing over a complete load is
   meaningful.

To watch a load in progress, use **`GET /batches`**, which reports the actual
step and its progress:

```
batch 47: processing tasks 0/2 -> indexing 3/4 -> finalizing
```

Document counts are the wrong signal; `/batches` is the right one.

Settings tuning changes little:

| configuration | docs/s | vs current |
|---|---:|---:|
| Body filterable + proximity (current) | 20,234 | 100% |
| Body filterable, NO proximity | 18,941 | 94% |
| no Body filterable, proximity | 25,227 | 125% |
| no Body filterable, NO proximity | 25,262 | 125% |

Removing the `proximity` ranking rule is free (its word-pair database is not the
cost). Removing `Body` from `filterableAttributes` buys 25% but costs the 21 OR
queries and the infix wildcards, since `CONTAINS` requires it — a bad trade.

## Query latency scales linearly with data

| scale | count (26) | top_k (19) | recent (16) | group_by (8) | total (69) |
|---|---:|---:|---:|---:|---:|
| 1m | 0.883s | 0.699s | 0.335s | 0.189s | 2.106s |
| 10m | 7.973s | 6.085s | 2.685s | 1.723s | 18.467s |
| ratio | 9.0x | 8.7x | 8.0x | 9.1x | **8.8x** |

10x the corpus for 8.8x the query time, uniformly across task types — the
signature of scanning rather than index lookups. 100m projects to ~180s for
these 69 queries, which would sit between CrateDB (138.75s) and RavenDB (610s)
on their comparable subsets, well behind the Lucene engines (ES 6.68s,
OpenSearch 6.45s) and SereneDB (1.16s).

## Query coverage — 69 of 92

`translate.py` generates `queries.meili` from `../elastic/queries.dsl`, one JSON
search body per line, and emits `UNSUPPORTED: <reason>` where nothing equivalent
exists; `./query` exits non-zero on those so the driver records null.

| queries | why |
|---|---|
| 9 (Q84–Q92) | no join |
| 6 (Q22–Q24, Q48, Q49, Q59) | fuzzy: typo tolerance is an **index-level** setting, not per-query, and it must be disabled globally or every term matches its typo neighbours |
| 5 (Q61–Q65) | `date_histogram`: facets bucket by term, not by date interval |
| 1 (Q13) | `match_phrase` with `slop` — no proximity operator |
| 1 (Q19) | non-prefix regexp (`c.che`) — no regex in queries or filters |
| 1 (Q26) | suffix wildcard (`*tion`) — `CONTAINS` matches the stem anywhere in a token and there is no way to anchor to a token end |

## Quoted vs bare: both exact terms and prefixes are expressible

Meilisearch is search-as-you-type, so **the last word of `q` is always a
prefix**. Quoting makes a term exact. Verified:

```
bare   order    3 hits   (also matches "orders")     -> use for ES prefix
quoted "order"  2 hits   (exact term)                -> use for ES match
bare   conn     1 hit    quoted "conn"  0 hits
```

Most engines here give one or the other; this gives both. A quoted multi-word
string is a real phrase, and it is order-sensitive.

## OR only exists in the filter language, and it over-matches

`q` is AND-ish under **every** `matchingStrategy` — `last`, `all` and
`frequency` all return 0 for two terms living in different documents. So ES's
default OR-across-terms is not expressible through `q` at all.

It is expressible through the filter language, which has real `AND`/`OR`/`NOT`:

```
Body CONTAINS "error" OR Body CONTAINS "failed"
```

This needs the `containsFilter` experimental flag (`./configure-features`) and
`Body` in `filterableAttributes`.

`CONTAINS` is a **substring** test, so:

- for an ES infix wildcard `*stem*` with an alphanumeric stem it is **exact** —
  the stem cannot contain a token separator, so any occurrence in the field lies
  inside one token (verified: 30,127, matching ground truth to the row);
- for OR-of-terms it **over-matches**: `CONTAINS "error"` also hits "errors".

Measured on `otel_logs_1m`, OR of `error|failed`: **138,188 vs 137,116 true —
+0.8%**. There is no token-level OR in Meilisearch, so the choice is an
over-matching OR or dropping 21 queries. The 21 affected queries are the ones
whose translation uses `Body CONTAINS`.

## Verified against ground truth

Computed directly from the parquet with the reference analyzer (lowercase, split
on non-alphanumerics) — not against another engine:

| case | Meilisearch | truth | |
|---|---:|---:|---|
| exact term `error` | 101,481 | 101,481 | ✓ |
| exact term `cache` | 57,206 | 57,206 | ✓ |
| AND `failed`+`order` | 62,029 | 62,029 | ✓ |
| phrase `failed to place order` | 31,323 | 31,323 | ✓ |
| prefix `ord*` (bare) | 68,706 | 68,706 | ✓ |
| infix `*nnec*` (CONTAINS) | 30,127 | 30,127 | ✓ |
| `ServiceName = cart` | 416,919 | 416,919 | ✓ |
| `SeverityNumber >= 13` | 83,382 | 83,382 | ✓ |
| OR `error`\|`failed` (CONTAINS) | 138,188 | 137,116 | +0.8% |

## Settings that are not optional

Three defaults would silently corrupt the comparison, and `./load` overrides all
three:

- **`typoTolerance: {enabled: false}`** — on by default. Left on, `error` also
  matches `eror`/`errors`. No other engine here does that.
- **`pagination.maxTotalHits: 1000000000`** — defaults to **1000**, which
  silently caps every count at 1000.
- **`faceting.maxValuesPerFacet: 100000`** — defaults to 100, truncating
  `group_by` on higher-cardinality keys.

Counts use `hitsPerPage: 0` → `totalHits` (exact). `estimatedTotalHits` is
explicitly approximate and is never used.

## Two traps

**Primary key inference fails on this corpus.** Meilisearch refuses:
*"found 3 fields ending with `id` in their names: 'SpanId' and 'TraceId'"*, and
the whole batch is rejected with the task marked failed while the HTTP POST
returns 200. `ingest.py` synthesises an explicit integer `id` and passes
`?primaryKey=id`.

**Time must be numeric.** Filters and sorts work on numbers, not date strings, so
the time column is carried twice: `TimestampMs` (epoch millis, filterable and
sortable) and `Timestamp` (ISO string, returned in projections). Storing only the
string would make every range predicate a lexicographic comparison — the trap
that invalidated the RavenDB run.

## Environment

| var | default | meaning |
|---|---|---|
| `MEILI_PORT` | `7700` | HTTP port |
| `MEILI_IMAGE` | `getmeili/meilisearch:v1.53.1` | pinned image |
| `MEILI_CONTAINER` | `searchbench-meili` | container name |
| `MEILI_DATA_DIR` | `./meili-data` | LMDB path (gitignored) |
| `MEILI_KEY` | `searchbench-meili-master-key-01` | master key — **must be ≥16 bytes** or the server exits 1 in production mode |
| `MEILI_INDEX` | `otel_logs` | index uid |

`data-size` is a `du` of the data directory. It uses actual blocks, not
`--apparent-size`: the LMDB map file is large, and although on this corpus the
two agreed (70.97 vs 70.52 GB), apparent size over-reports on a sparse store.
