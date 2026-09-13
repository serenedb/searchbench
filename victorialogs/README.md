# VictoriaLogs adapter

[VictoriaLogs](https://docs.victoriametrics.com/victorialogs/) v1.52.0 — a Go log
database from the VictoriaMetrics team, queried with LogsQL over HTTP.

```
./benchmark.sh --index      # load + run
./benchmark.sh              # query-only
```

## Data model

VictoriaLogs is schemaless: there is no `CREATE TABLE` / mapping step. Field
roles are URL parameters on the insert endpoint (`ingest.py`):

| corpus column        | VictoriaLogs role                                  |
|----------------------|----------------------------------------------------|
| `Timestamp`          | `_time` (sent as epoch **nanoseconds**, the corpus's native resolution) |
| `Body`               | `_msg`, the full-text-indexed message field         |
| `ServiceName`        | `_stream` field **and** an ordinary field           |
| everything else      | ordinary indexed fields                             |
| attribute maps       | flattened to `ResourceAttributes.host.name` etc.    |

`ServiceName` is the only stream field. VictoriaLogs partitions storage by
stream, and stream fields must be **low** cardinality (~10 services here).
`TraceId`/`SpanId` are deliberately left as ordinary fields — making them stream
fields would create one stream per trace and wreck the storage layout.

Ingest reuses the Elasticsearch bulk wire format
(`/insert/elasticsearch/_bulk`), so `ingest.py` is the repo's ES ingest pipeline
retargeted rather than a new tool.

## Retention: required, and silent if wrong

The corpus is timestamped 2025-09-23. VictoriaLogs **drops** entries older than
`-retentionPeriod` (default **7d**) at ingest — every HTTP call still returns
`200`, and the only signal is a warn line plus
`vl_rows_dropped_total{reason="too_small_timestamp"}`. Loading with the default
retention ingests **zero rows** and looks like a success.

`./start` therefore passes `-retentionPeriod=10y` (`VL_RETENTION`), and `./load`
fails loudly if the drop counter moved. Retention is an operational knob, not a
query or index tunable, so widening it does not flatter the engine.

## What LogsQL cannot express — 35 of 92

`translate.py` generates `queries.logsql` from `../elastic/queries.dsl` and emits
an `UNSUPPORTED: <reason>` sentinel where no LogsQL form exists. `./query` exits
non-zero on those, so `lib/benchmark.sh` records a null latency and logs the
reason instead of timing a substituted question.

| queries | why |
|---|---|
| 21 (Q33–Q47, Q50–Q53) | **no relevance scoring.** LogsQL has no BM25/TF-IDF, no score field, no sort-by-relevance. Confirmed against the LogsQL reference. |
| 6 (Q22–Q24, Q48, Q49, Q59) | no edit-distance / fuzzy operator |
| 9 (Q84–Q92) | no join support |
| 1 (Q13) | `match_phrase` with `slop` — no proximity operator |

The 57 that do run cover the workload VictoriaLogs is built for: counting,
filtering, time windows, `stats by` aggregation and recent-first tails.

## Tokenizer divergence — `_` is not a separator

VictoriaLogs splits on `.`, `/`, `-` and whitespace but **keeps `_` inside a
token**; the reference analyzer every other engine uses splits on it. So
`send_order_confirmation` is one token here and three elsewhere, and `i(order)`
misses those rows. Measured on `otel_logs_1m`, 5 of the workload's 24 distinct
terms diverge:

| term | `i(term)` | reference | delta |
|---|---:|---:|---:|
| email | 2,367 | 6,655 | −4,288 |
| send | 1,092 | 4,957 | −3,865 |
| confirmation | 3,439 | 5,160 | −1,721 |
| order | 63,890 | 65,611 | −1,721 |
| deadline | 23 | 24 | −1 |

`VL_TERM_MODE` selects how term filters are generated:

- **`word`** (default) — `i(term)`. The engine's own tokenization, index-backed,
  ~0.04 s/term at 1M. What a VictoriaLogs user would actually write. Row counts
  diverge from the other engines on the terms above (24 of the 92 queries touch
  one).
- **`exact`** — a boundary-anchored regex whose word class excludes `_`,
  reproducing the reference analyzer exactly (verified: 6,655 and 65,611).
  ~0.5 s/term at 1M (**12×**), because it scans `_msg` instead of consulting the
  token index.

Neither is free: the default measures the engine as used, the alternative
measures the same question as the other engines. Regenerate after switching:

```
VL_TERM_MODE=exact python translate.py ../elastic/queries.dsl queries.logsql
```

Everything else is exact. Verified against ground truth computed directly from
the parquet on `otel_logs_1m` — term, AND, ≥2-of-4, phrase, regex, suffix and
infix wildcards, service+time window, and numeric range all match to the row.

## Hand-applied optimizations (and what they hide)

Two rewrites in `translate.py` do work a query planner would normally do. Both
are recorded here because they flatter the engine relative to what it does out
of the box.

**Literal prefilter on scan-regexes.** A bare `~"c.che"` gives the per-block
bloom filters nothing to test, so it reads all 100M messages. Every match must
contain the pattern's longest literal run, so `translate.py` ANDs a substring
filter on it. Measured at 100M on Q19, both returning 6,153,906 rows:

```
_msg:~"(^|[^a-z0-9])c.che([^a-z0-9]|$)"              21.64s
*che* AND _msg:~"(^|[^a-z0-9])c.che([^a-z0-9]|$)"     3.61s    6.0x
```

That is 54% of the entire query suite in one query. Lucene extracts required
literals from a regex automatically, which is why Elasticsearch answers the same
question in 0.014s with no hand-tuning. VictoriaLogs' planner does not, though
its own bloom filters support it — so this is a planner gap, not an index
limitation. (Q26/Q27 already contain a literal run, so the prefilter is a no-op
there: 0.63s and 0.53s either way.)

**"at least K of N" expansion.** LogsQL has no `minimum_should_match`, so
Q09-style queries expand to an OR over every K-subset (the same shape the CrateDB
adapter needs).

Net effect: the recorded suite total is **22.05s**. Without the prefilter it is
**39.95s**. Both are honest; the first is "best query the language can express",
which is the standard every adapter here is held to, and the second is what a
user gets from the obvious translation.

## Case sensitivity

LogsQL word matching is case-sensitive: bare `cache` does not match `"CACHE
miss"`. Every other engine lowercases in its analyzer, so all word, phrase and
prefix filters are wrapped in `i(...)`.

## Environment

| var | default | meaning |
|---|---|---|
| `VL_PORT` | `9428` | HTTP listen port |
| `VL_IMAGE` | `victoriametrics/victoria-logs:v1.52.0` | pinned image |
| `VL_CONTAINER` | `searchbench-vl` | container name |
| `VL_DATA_DIR` | `./vl-data` | `-storageDataPath` bind mount |
| `VL_RETENTION` | `10y` | `-retentionPeriod`; must cover the corpus |
| `VL_TERM_MODE` | `word` | `word` \| `exact` (translate-time) |

`data-size` sums `vl_data_size_bytes{type="storage"}` +
`{type="indexdb"}` — data plus inverted index, the direct analogue of
Elasticsearch's `_cat/indices` store size. There is no helper structure here (no
equivalent of the ES `trace_lookup` index) because the join queries are not
expressible at all.
