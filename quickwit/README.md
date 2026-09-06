# Quickwit adapter

[Quickwit](https://quickwit.io) 0.9.0, queried through its
**Elasticsearch-compatible API** at `/api/v1/_elastic`.

```
./benchmark.sh --index      # load + run
./benchmark.sh              # query-only
```

## ⚠ Ingest v2 silently drops documents under concurrency

**This is the most serious defect found in any engine in this batch, and it is
invisible to the client.** Every dropped batch returns `HTTP 200` with
`"errors": false` and no per-item error. The only signal is a line in the
*server* log, and even that does not appear in every case.

Measured on `otel_logs_1m`, identical data, identical index config, varying only
the number of concurrent bulk requests:

| concurrent requests | indexed | lost | notes |
|---:|---:|---:|---|
| 1 | 1,000,000 | — | lossless, 14,923 docs/s |
| 4 | 858,000 | **14.2%** | permanent; count unchanged after 160s |
| 4 (32GiB ingest queue) | 830,000 | **17.0%** | and **zero** "failed to fetch" errors |
| 4 (sub-1MB batches) | 864,200 | **13.6%** | |
| 16 | 896,000 | **10.4%** | 7 × "failed to fetch records from ingester" |

The loss is **permanent**, not a commit lag: the count was still 858,000 after
160 seconds of polling, and the settle curve for a healthy load is visible and
short (975,311 → 998,400 → 1,000,000 over 45s).

### What causes it

The server prints the real constraint at startup:

```
INFO quickwit_config::node_config: ingestion shard throughput limit: 5.2 MB
```

Ingest v2 distributes documents into WAL shards, each rate-limited. Exceed the
limit and Quickwit **discards the excess instead of applying backpressure or
returning an error**. No shard-throughput or shard-count setting is exposed —
not in the node config, not in the index config, and not on the CLI (`QW_CONFIG`
is the only environment variable).

### What does not fix it

- **A bigger ingest queue.** Raising `ingest_api.max_queue_memory_usage` from
  2GiB to 32GiB made it *worse* (830,000) and eliminated the
  "failed to fetch records" errors entirely — proving the queue was never the
  bottleneck. Those settings are still in `config/quickwit.yaml`, which `./start`
  mounts, because they are what the published numbers were measured under — not
  because they help. They are irrelevant to the serial ingest that is actually
  used.
- **Sub-1MB batches.** The community workaround for ingest-v2 stalls
  ([Journey to v9](https://github.com/quickwit-oss/quickwit/discussions/5961)
  reports that cutting messages below 1MB resolved indexing stalls) does not
  apply here: 700-document batches at ~0.9MB still lost 13.6%.
- **`?refresh=wait_for` on the bulk endpoint.** Accepted (HTTP 200) but has no
  effect on the loss.

### What does fix it

**Serial ingest — one connection.** `ingest.py` therefore defaults to
`--processes 1 --bulk-workers 1`. That still does ~15k docs/s, which is faster
than Meilisearch and far faster than Typesense, so the cost is modest.

The native `/api/v1/<index>/ingest?commit=wait_for` endpoint *does* apply real
backpressure and is lossless, but collapses throughput to roughly 16,000
documents in five minutes (~50× slower) — unusable at this scale.

### Why `./load` counts afterwards

Because the response cannot be trusted, `./load` compares the final indexed
count against the parquet row count and **fails loudly** on a mismatch rather
than benchmarking a partial corpus. Any adapter for this engine needs that
check; without it a 14% shortfall looks exactly like a successful load.

This is consistent with publicly reported ingest-v2 problems — dropped
documents, indexing stalls, and throughput regressions against v1, with users
reporting they *"could not reach even half the throughput they had with
ingest_v1"* — see
[ingest-v2 internals](https://github.com/quickwit-oss/quickwit/blob/main/docs/internals/ingest-v2.md).

## Query coverage — 77 of 92, the best in this batch

Quickwit speaks the ES query DSL, so `queries.dsl` is
`../elastic/queries.dsl` with **three constructs rewritten**, not a translation
into another language. 45 of the 92 run byte-identical to the ES file.

| rewritten | why |
|---|---|
| `match` object form (`operator`, `minimum_should_match`) | HTTP 400 → expanded to a `bool` over single-term `match` clauses |
| `date_histogram` `calendar_interval` | HTTP 500 → `fixed_interval` (minute → 60s). The corpus has no DST or leap seconds, so the buckets coincide |

| unsupported | why |
|---|---|
| 9 (Q84–Q92) | no join |
| 6 (Q22–Q24, Q48, Q49, Q59) | **fuzzy** — verified absent on *both* APIs: `{"fuzzy":…}` → 400, `match`+`fuzziness` → 400, `query_string "term~1"` → 0 hits, native `Body:term~1` → 0 hits. `term~` returns the exact-match count only, so `~` is parsed and ignored |

Compare: Typesense 74, RavenDB 71, Meilisearch 69, VictoriaLogs 57.

### Q67 is not equivalent across engines

Q67 is a **nested** aggregation here (top-100 severities, then each one's top-20
scopes), but a **flat** `GROUP BY (SeverityText, ScopeName) ... LIMIT 20` in the
SQL adapters, and single-key `GROUP BY SeverityText` in cratedb, victorialogs,
ravendb, surrealdb, meilisearch and typesense — which drop the ScopeName
dimension entirely. These compute different things: the flat form can be
swallowed by the largest severity while rare severities vanish, whereas the
nested form guarantees each severity its own top-20.

They coincide on this corpus only because cardinality is tiny (5 severities, 7
distinct pairs), so all three shapes return the same 7 pairs. That is luck, not
equivalence, and it would break on a corpus with more scopes. Q60 and Q66 differ
more mildly: `terms size:100` caps and orders by count, while the SQL forms have
no `LIMIT` (and Q60 no `ORDER BY`).

Quickwit needs **no workarounds** for `regexp`, `wildcard` (infix *and* suffix),
`prefix` with many expansions, `minimum_should_match`, or `must_not` — every
other engine in this batch needed a rewrite, an approximation, or an exclusion
for at least one of those. It is also the only one that can express
`date_histogram`.

## Results at 100m

| | |
|---|---|
| load | 6747s (1.9h), 14,731 docs/s — no degradation from 1M's 14,923 |
| on disk | 22.7 GB |
| queries | 77/92 ran, **3.63s total hot**, 0 timeouts |
| by task | count 1.61s/29 · group_by 0.39s/13 · top_k 1.22s/19 · recent 0.40s/16 |
| memory | flat ~1.5 GiB throughout |

## ⚠ The result cache must be disabled or the numbers are meaningless

`searcher.partial_request_cache_capacity` (default **64M**) caches whole
aggregation and search *results*, keyed on the exact query body. The driver runs
each query three times and reports `min(try2, try3)`, so with the cache on
**every reported number is a cache lookup, not a query**.

Measured on Q67 (nested terms aggregation over 11.7M matching docs):

| | |
|---|---|
| first execution | 115ms |
| every execution after | **2ms** |
| same query, `should` clauses reordered | 29ms, then 2ms |
| same query, `size` 100 → 99 | 42ms, then 2ms |
| cache disabled | 26–47ms, stable |

2ms for aggregating 11.7M documents is 5.8 billion docs/sec — the giveaway that
no work was being done.

Suite-wide the cache inflated Quickwit by **10.2×**: 0.40s reported vs 3.63s
real, with a cold/hot ratio of 10.2x against 1.2x for an engine with no such
cache. `count` queries were the worst hit at 26x (1.84s cold → 0.07s hot).
With the cache off the ratio is 1.1x, as expected.

`config/quickwit.yaml` therefore sets `partial_request_cache_capacity: 0`. Any
comparison against engines that do not cache results is invalid without it.

**Quickwit is the only engine in this suite found to have such a cache.** An
earlier version of this note claimed Elasticsearch (1.7x), OpenSearch (3.0x) and
Elasticsearch-columnar ES|QL (3.3x) shared the signature and needed
`?request_cache=false`. That was wrong: all three already set
`index.requests.cache.enable=false` and `index.queries.cache.enabled=false` in
`config/index_mapping.json`, and re-running OpenSearch at 1b with the parameter
changed no timing beyond run-to-run noise. Their residual cold/hot ratios are OS
page cache and JVM warm-up -- the query executes every time -- which is a
different thing from a cache that returns a precomputed result without doing the
work.

An earlier recording measured 0.52s; it both used the cache and overlapped a
concurrent Typesense load. Discarded.

## Verified against ground truth

**All 77 runnable queries are verified, not a sample.** Row counts agreeing is
not evidence — a `size: 100` cap makes every hit-returning query return exactly
100 rows whether the underlying match set is right or wrong. Each query shape is
therefore checked differently:

| shape | n | method | result |
|---|---:|---|---|
| count | 29 | exact integer vs Elasticsearch | all identical |
| group_by | 13 | every bucket key **and** doc_count vs ES | all identical |
| top_k / recent | 35 | full match total (`size:0`, `track_total_hits`) — 18 share a predicate with an already-verified count query, 17 checked against parquet ground truth | all identical |
| returned docs | 3,500 | every returned document re-evaluated against its own predicate | 0 false positives |
| sorted queries | 8 | top-100 timestamp window vs ES | all identical |

**Counts are exact, not estimated.** `hits.total.relation` is `eq` (not `gte`),
and the terms aggregation reports `doc_count_error_upper_bound: 0` with
`sum_other_doc_count: 0`; its buckets sum to exactly 100,000,000. This matters
because Tantivy's terms aggregation is approximate in the general case — it does
not bite here only because the corpus has 17 services, well inside the exact
regime. A high-cardinality grouping field would need `shard_size` scrutiny.

The 19 `_score`-sorted top_k queries are compared by match total only: Tantivy
and Lucene compute BM25 differently, so which 100 documents tie into the page is
a legitimate engine difference, not an error.

The 10 predicates without a verified twin were recomputed from the 100m parquet
in a single vectorised pass, and every one matched Quickwit exactly:

| predicate | Quickwit | truth |
|---|---:|---:|
| `charge` | 7,301,803 | 7,301,803 |
| `connection` | 1,340,416 | 1,340,416 |
| charge + payment + 6h | 1,831,881 | 1,831,881 |
| failed + order + checkout + 30m | 123,480 | 123,480 |
| (error\|failed\|charge) + sev≥13 + 30m | 7,039,396 | 7,039,396 |
| phrase "failed to place order" + 6h | 2,664,716 | 2,664,716 |
| charge + payment + 30m | 1,831,881 | 1,831,881 |
| cart + 30m | 44,161,325 | 44,161,325 |
| `regexp charg.*` + 6h | 7,301,803 | 7,301,803 |
| (connection\|request\|conversion) + 30m | 5,066,633 | 5,066,633 |

`regexp charg.*` returning exactly the `charge` count looks like a bug and is
not: the parquet confirms no other `charg`-prefixed token occurs in the corpus.

Additionally, 15 probes at 1m scale, computed from the parquet with the
reference analyzer (lowercase, split on non-alphanumerics):

| case | Quickwit | truth |
|---|---:|---:|
| term `error` | 101,481 | 101,481 |
| term `cache` | 57,206 | 57,206 |
| underscore: `order` | 65,611 | 65,611 |
| AND `failed`+`order` | 62,029 | 62,029 |
| OR `error`\|`failed` | 137,116 | 137,116 |
| ≥2 of 4 (`minimum_should_match`) | 93,367 | 93,367 |
| phrase | 31,323 | 31,323 |
| prefix `ord*` | 68,706 | 68,706 |
| prefix `conn*` | 30,448 | 30,448 |
| regexp `c.che` | 57,206 | 57,206 |
| wildcard `*tion` | 113,086 | 113,086 |
| wildcard `*nnec*` | 30,127 | 30,127 |
| `must_not`: error !cache | 50,683 | 50,683 |
| `term` ServiceName=cart | 416,919 | 416,919 |
| range severity>=13 | 83,382 | 83,382 |

`prefix conn*` is worth singling out: Typesense returned 20 of 6,493 for the
equivalent query because its prefix expansion is capped at 4 candidates by
default. Quickwit needs no such tuning.

## Other operational notes

- **No parquet ingest.** The CLI reads *"NDJSON documents from a file or
  streamed from stdin"*, and the source config supports only `json`,
  `otlp_logs_*`, `otlp_traces_*` and `plain_text`. The parquet → NDJSON
  conversion in `ingest.py` is unavoidable.
- **Bulk bodies are capped at 10MB** (`ingest_api.content_length_limit`);
  20,000-document batches returned HTTP 413. Default batch size is 2,000.
- **Commits are on a timer** (`commit_timeout_secs`, set to 30 in
  `config/index_config.json`), so documents are not searchable the instant the
  bulk call returns. `./load` waits for the count to be stable across six
  consecutive polls — two equal readings are not enough, because a commit
  landing between polls produces a false plateau that reported 858,000 of
  1,000,000 as "settled".
- **`--ulimit nofile=65535`** is set from the outset, after the typesense
  adapter lost 7.5 hours to descriptor exhaustion presenting as a hang.

## Environment

| var | default | meaning |
|---|---|---|
| `QW_PORT` | `7280` | HTTP port |
| `QW_IMAGE` | `quickwit/quickwit:0.9.0` | pinned image |
| `QW_CONTAINER` | `searchbench-quickwit` | container name |
| `QW_DATA_DIR` | `./qw-data` | data path (gitignored) |
| `QW_INDEX` | `otel_logs` | index id |
