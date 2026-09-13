# SurrealDB adapter

[SurrealDB](https://surrealdb.com) v3.2.4 on RocksDB, queried with SurrealQL over
HTTP `/sql`.

```
./benchmark.sh --index      # load + run
./benchmark.sh              # query-only
```

## Status: no results at 100m — the full-text index cannot be built at that scale

This adapter is complete and validated, but **there is no 100m run**, because
building the full-text index over the corpus would take roughly two days.

Measured on this box (32 cores, real corpus rows, not synthetic text):

| configuration | docs/s | vs unindexed |
|---|---:|---:|
| no indexes | 5,148 | 100% |
| 3 secondary indexes only | 4,114 | 80% |
| FULLTEXT + HIGHLIGHTS | 578 | 11% |
| FULLTEXT, no HIGHLIGHTS | 573 | 11% |
| FULLTEXT (no HL) + 3 secondary | 553 | 11% |

The `FULLTEXT` index costs **89% of ingest throughput** on its own. `HIGHLIGHTS`
is ~free (573 vs 578), and the secondary indexes cost 20% — neither is the
problem. Throughout, SurrealDB uses **about one core** of 32.

Building the index after the load instead of during it does not help:

| ordering | rate |
|---|---:|
| index during load | 603 docs/s |
| index after load (200,000 rows in 317s) | 631 docs/s |

So the index builds at ~630 docs/s regardless of when it is built. Projected:

```
100M   ~5.4 h ingest + ~44 h index  =  ~49 hours
 10M   ~32 min       + ~4.4 h       =  ~5 hours
  1M   ~3.5 min      + ~26 min      =  ~30 minutes
```

For scale, the same 100m corpus loads in 525s in VictoriaLogs and 841s in
OpenSearch. 1M is the only scale that finishes in reasonable time, and it yields
query latencies that cannot be compared to the 100m table on load or size.

## Query coverage — 73 of 92

`translate.py` generates `queries.surql` from `../elastic/queries.dsl` and emits
`UNSUPPORTED: <reason>` where no SurrealQL form exists; `./query` exits non-zero
on those so the driver records null rather than timing a different question.

| queries | why |
|---|---|
| 9 (Q84–Q92) | no join |
| 6 (Q22–Q24, Q48, Q49, Q59) | fuzzy: the `~` family was **removed in 3.0** "to avoid implicitly preferring one algorithm over another". The replacements (`string::similarity::*`) are unindexed scalar functions *and* a different algorithm from ES's edit distance |
| 3 (Q46, Q47, Q50) | relevance ranking over a regex filter: `search::score` needs a numbered `@N@` match operator, and prefix/wildcard have no index-backed match form |
| 1 (Q13) | `match_phrase` with `slop` — no proximity operator |

## What the match operator does and does not do

Verified against a running 3.2.4 server:

- `@@` is an order-insensitive **AND** over terms; `@OR@` is the OR form.
- **No phrase support.** `'"failed to place"'` returns 0 — the quotes become
  literal tokens. Adding `HIGHLIGHTS` (which stores term positions) does not
  change this.
- **No prefix support.** `'conn*'` returns 0.
- `regex` is `string::matches()`, a scalar function, so it **scans**.
- BM25 relevance works via `search::score(1)` with the numbered `@1@` operator.
- `date_histogram` maps cleanly onto `GROUP BY time::floor(Timestamp, 1m)`.

The analyzer reproduces the reference exactly:
`search::analyze('otel','Failed to place order')` → `['failed','to','place','order']`.

## Hand-applied optimizations

**Phrase is rebuilt from primitives**, since the operator has none:

```
Body @@ 'failed to place' AND string::matches(Body, '(?i)failed\ to\ place')
```

The `@@` half is index-backed and narrows to documents holding all the terms;
the regex then checks adjacency on that much smaller set. Verified
order-sensitive: `'failed to place'` → 1, `'place to failed'` → 0.

**Prefix and wildcard fall back to unindexed boundary regexes.** There is no
index-backed prefix; the only alternative would be an `edgengram(2,10)` filter in
the analyzer, which would change tokenization for every other query. Marking them
unsupported would understate coverage — the questions *are* expressible, just
slow — so they are translated and will be slow.

## Two traps worth knowing

**Timestamps must be coerced, and the parser is positional about it.** A plain
JSON string stays a string and every range predicate then compares text.
`TYPE datetime` rejects the insert outright. The working form is:

```sql
DEFINE FIELD Timestamp ON otel_logs VALUE <datetime>$value;
```

and it **must be on its own line** — on a single line with other statements the
parser reads `<datetime>` as chained `<`/`>` relational operators and returns
`Chained relational operators have no defined associativity`. (`type::datetime()`
does not exist.) Verified: with the cast, `type::is_datetime(Timestamp)` is true
and a 30-minute window selects 1 of 2 rows.

**The HTTP body limit is not configurable.** There is no `--max-body` flag; 10,000
real rows returned HTTP 413. `ingest.py` therefore caps batches by *bytes*
(500 KB), not row count.

## Environment

| var | default | meaning |
|---|---|---|
| `SURREAL_PORT` | `8000` | HTTP port |
| `SURREAL_IMAGE` | `surrealdb/surrealdb:v3.2.4` | pinned image |
| `SURREAL_CONTAINER` | `searchbench-surreal` | container name |
| `SURREAL_DATA_DIR` | `./surreal-data` | RocksDB path (gitignored) |
| `SURREAL_NS` / `SURREAL_DB` | `bench` / `logs` | namespace / database |

`data-size` is a `du` of the RocksDB directory: SurrealDB exposes no size API
(`INFO FOR DB` lists definitions, not bytes), so the footprint is measured from
the filesystem — data plus indexes, the same accounting as the other adapters.
