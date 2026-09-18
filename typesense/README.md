# Typesense adapter

[Typesense](https://typesense.org) 30.2, queried through its own REST API.

```
./benchmark.sh --index      # load + run
./benchmark.sh              # query-only
```

## Four silent-wrong-answer traps

Every one of these returned a plausible number with no error, and all four were
caught by comparing per-query counts against Elasticsearch after a full 100m run
-- not by anything the engine reported.

| trap | symptom | fix |
|---|---|---|
| `max_candidates` defaults to **4** | a prefix with many expansions is silently truncated: `conn*` returned **20** instead of 6,493, while `ord*` happened to be exact because it has few expansions | set `max_candidates=10000` whenever prefix or typo expansion is in play |
| `Body:!=term` on a text field | a **no-op**. Q28 came back identical to Q01 (8,866,117) instead of 3,396,391 | `Body:!term` |
| suffix wildcard `*stem` via infix | infix matches the stem **anywhere** in a token, not only at its end: 29,165 vs 22,542 truth (+29%) | unsupported -- there is no anchor |
| fuzzy AND prefix merged into one `q` | `q` applies `num_typos` to every term and `prefix` only to the last, so the two clauses cannot share a query: Q24 returned **4** vs 1,340,428 | unsupported |

The lesson that generalises: `max_candidates` is the dangerous one, because
whether it bites depends on how many tokens share the prefix. A spot check on a
low-cardinality prefix passes and the same code silently under-counts elsewhere.

## Query coverage — 74 of 92

`translate.py` generates `queries.ts` from `../elastic/queries.dsl`, one JSON
object of search parameters per line; `./query` turns it into the query string
the search endpoint expects. `UNSUPPORTED: <reason>` sentinels make `./query`
exit non-zero so the driver records null rather than timing a different
question.

| queries | why |
|---|---|
| 9 (Q84–Q92) | no join |
| 5 (Q61–Q65) | `date_histogram`: `facet_by` buckets by value, not by time interval |
| 1 (Q13) | `match_phrase` with `slop` — no proximity operator |
| 1 (Q19) | non-prefix regexp (`c.che`) — no regex anywhere in the API |
| 1 (Q24) | fuzzy combined with prefix in one bool (see traps above) |
| 1 (Q26) | suffix wildcard `*tion` (see traps above) |

For comparison on the same workload: RavenDB 71, Meilisearch 69,
VictoriaLogs 57.

After the fixes, all 12 ground-truth probes match to the row, including the
three previously-broken shapes (prefix 6,493; must_not 9,303; infix 6,185).

**Fuzzy is covered here**, unlike everywhere else in this batch: `num_typos` is a
per-query parameter, so ES `fuzzy` maps directly. Meilisearch's typo tolerance is
an index-level setting that has to be off globally; Corax has no fuzzy at all;
SurrealDB removed its fuzzy operators in 3.0.

## Everything is per-query, which is why the semantics line up

| ES construct | Typesense |
|---|---|
| `match` (exact term) | `num_typos=0` + `prefix=false` |
| `prefix` / `x*` | `prefix=true` |
| `wildcard` `*stem*`, `*stem` | `infix=always` (needs `"infix": true` on the field) |
| `fuzzy` | `num_typos=N` |
| `match_phrase` | quoted `q`, order-sensitive |
| OR across terms | `filter_by: Body:a || Body:b` — exact and token-level |
| ranges, AND/OR/NOT | `filter_by` with `&&`, `||`, `:>=` |
| terms aggregation | `facet_by` |
| count | `per_page=0` → `found` (exact) |

The OR is worth calling out: it is a **token-level** match, not a substring one.
Verified on 500k rows — `error` 53,789, `failed` 63,047, both 40,318, OR 76,518,
which reconciles exactly. Meilisearch's only OR is `CONTAINS`, which is
substring-based and over-matches by ~0.8%.

## token_separators must list EVERY non-alphanumeric character

This is the one setting that silently produces wrong answers if you get it
half-right, and it cost a full ground-truth run to find.

The reference analyzer splits on every non-alphanumeric. Typesense splits on
whitespace plus whatever `token_separators` lists. With a plausible-looking
partial list — `["_","-","/","."]` — a body like

```
{"code":13,"details":"failed to charge card: ... rpc error: code = Unknown ..."}
```

keeps `error:` as one token, so an exact search for `error` misses it. Measured
on 614,400 rows: **19,410 expected, 12% under-counted**, and every text query was
wrong in the same direction while filter-only queries matched perfectly — which
is the tell.

`config/collection_schema.json` therefore lists all 32 punctuation/symbol
characters. Whitespace is already a separator and is rejected if listed.

With the full set, all nine ground-truth probes match to the row:

| case | Typesense | truth |
|---|---:|---:|
| term `error` | 19,410 | 19,410 |
| term `order` | 11,231 | 11,231 |
| term `cache` | 11,383 | 11,383 |
| term `failed` | 23,869 | 23,869 |
| AND `failed`+`order` | 10,542 | 10,542 |
| phrase | 5,740 | 5,740 |
| prefix `ord*` | 11,911 | 11,911 |
| infix `*nnec*` | 6,185 | 6,185 |
| OR `error`\|`failed` | 25,340 | 25,340 |

Ground truth is computed directly from the parquet with the reference analyzer,
not by comparing against another engine.

## Ingest

Typesense imports **synchronously** — the HTTP call returns once the documents
are indexed. There is no task queue to drain (Meilisearch) and no asynchronous
index build to wait for (RavenDB), so wall-clock around the import is the ingest
time and there is nothing to mis-sample.

Client parallelism helps a little and saturates fast:

| clients | docs/s | speedup |
|---|---:|---:|
| 1 | 9,205 | 1.00x |
| 4 | 12,235 | 1.33x |
| 8 | 12,022 | 1.31x |
| 16 | — | **crashed the server** (connection resets) |

`infix` indexing is effectively free at ingest: 8,896 docs/s without it, 8,891
with.

## `--ulimit nofile=65535` is mandatory

With Docker's default 1024 descriptors the server exhausts them partway through a
large load and then **spins at 100% CPU** logging

```
Fail to open /proc/self/fd: Too many open files
```

while refusing new connections. It does not crash, so a process-liveness check
still passes: a 100m load sat wedged for **7.5 hours** at 2.5M documents before
this was noticed. `./start` sets the limit, matching the elastic and opensearch
adapters.

## Restarting costs a full index rebuild

Typesense reconstructs its in-memory index from disk on every start, at roughly
17k docs/s -- about **1.6 hours for 100m**, during which every request returns
`Not Ready or Lagging`, including requests to unrelated collections. That rules
out any benchmark mode that restarts the engine between queries.

## Memory is the binding resource, not disk

Typesense keeps its index in RAM and persists documents to RocksDB, so its
on-disk figure **understates** what it needs to serve the workload and is not
directly comparable to the engines that keep their index on disk. Marginal cost
measured during the 100m load rose from ~495 B/doc early to ~775 B/doc, i.e.
roughly 78 GB of RAM at 100m.

## Environment

| var | default | meaning |
|---|---|---|
| `TS_PORT` | `8108` | HTTP port |
| `TS_IMAGE` | `typesense/typesense:30.2` | pinned image |
| `TS_CONTAINER` | `searchbench-typesense` | container name |
| `TS_DATA_DIR` | `./ts-data` | RocksDB path (gitignored) |
| `TS_KEY` | `searchbench` | API key |
| `TS_COLLECTION` | `otel_logs` | collection name |

There is **no Elasticsearch-compatible API**: `/_search`, `/_bulk` and
`/_cat/indices` all 404, and the search route rejects an ES DSL body. Of the
engines added in this batch only VictoriaLogs accepts the ES `_bulk` format.
