# SearchBench / ClickHouse engine

Reproduces [TextBench](https://github.com/ClickHouse/TextBench)'s
ClickHouse setup (same schema, same `text` index, same Q1–Q9) wired to
SearchBench's shared driver. Numbers line up with both TextBench's
leaderboard and SereneDB's `results/`.

Needs: `jq`, `wget`/`curl`, and `ss`/`fuser`/`lsof`. `./install` fetches
the ClickHouse binary automatically if `$CLICKHOUSE_BIN` isn't set and
`./clickhouse` doesn't exist (runs `curl https://clickhouse.com/ | sh`).

## Run

```bash
# Smoke (streams first 100k rows over HTTPS)
SEARCHBENCH_DATASET=otel_logs_100k ./benchmark.sh

# Full benchmark (~100 GB free disk + sudo for drop_caches)
./benchmark.sh
# -> results/clickhouse_otel_logs_1b.json
```

## Env

| Var | Default | Meaning |
|---|---|---|
| `CLICKHOUSE_BIN` | `./clickhouse` | binary |
| `CH_HOST` / `CH_TCP_PORT` / `CH_HTTP_PORT` | `127.0.0.1` / `9000` / `8123` | server endpoint |
| `CH_DATA_DIR` | `./clickhouse_data` | datadir |
| `CH_LOAD_WORKERS` | `min(nproc,4)` | parallel parquet INSERTs |
| `CH_INDEX_SETTING` | `enable_full_text_index=1` | text-index session flag |

`CH_INDEX_SETTING` is the only version-sensitive knob — override if a
non-26.x build names the flag differently.

## Q10–Q14

ClickHouse's `text` index does boolean token matching only — no BM25
ranking. Those slots are `UNSUPPORTED:` sentinel lines that `./query`
short-circuits to `null`, keeping the result array 14 rows long.

Schema in [`create.sql`](create.sql); workload in
[`queries.sql`](queries.sql). `./data-size` returns
`sum(bytes_on_disk)` over active parts.

## Phrase search (`matchPhrase`)

ClickHouse 26.7 has `matchPhrase`, and it is served by the text index:

```
EXPLAIN indexes = 1 SELECT count() FROM otel_logs
WHERE matchPhrase(Body, 'failed to place order');
  Prewhere filter: hasPhrase(lower(Body), '…', 'splitByNonAlpha')
                   AND __text_index_text_idx_hasPhrase_…
  Indexes: Skip / Name: text_idx
```

That plan is the **non-positional** build: the index narrows to candidate
granules by token and `hasPhrase` re-checks the raw column for adjacency.

The text index *can* store positions — `positions = 1`, gated behind the
MergeTree setting `allow_experimental_text_index_positions = 1`. With it the
`hasPhrase` prewhere disappears entirely and the index resolves the phrase
itself. `create.sql` enables it. Measured at 100M:

| | positions off | positions = 1 |
|---|---:|---:|
| total hot (52 queries) | 8.85s | **5.46s** |
| load | 221s | 277s |
| active parts on disk | 7.9 GB | 20.1 GB |

Phrase queries are 50–90% faster (Q10 -90%, Q12 -87%, Q15 -76%, Q11 -71%,
Q86 -53%), paid for with **2.5x the index size and 25% more ingest time**. The
two exceptions are Q71 (+89%) and Q79 (+347%): time-windowed `LIMIT 100`
lookups already down at 30–80ms, where reading the larger index costs more than
phrase resolution saves.

Semantics are exact adjacency either way: it matches `failed to place order` but
not `order failed to place` nor `failed to place the order`.

This moved 9 queries off the `UNSUPPORTED` list — Q10, Q11, Q12, Q14, Q15, Q63,
Q71, Q79, Q86 — taking coverage from **43/92 to 52/92**. All five count-shaped
ones match Elasticsearch exactly (Q10/Q11 2,664,716; Q12 123,480; Q14 9,185,085;
Q15 781,434), and 19 of 19 count-shaped queries overall are identical to ES.

**Q13 stays unsupported**: it is `match_phrase` with `slop: 2`, and
`matchPhrase` is adjacency-only with no proximity form.

Still unsupported (40): 21 BM25 top_k (the text index does boolean matching, no
ranking), 8 regexp, 4 fuzzy, 3 prefix, 3 like, 1 proximity.

### Loading natively

`./load` ingests with `INSERT … FROM file('parquet/part_*.parquet')`, which
resolves relative to `user_files_path`. `./start` bind-mounts the corpus there
only on its **docker** path; run against a local binary there is no mount, so
the INSERT matched nothing, inserted **0 rows and reported success** — the whole
suite then "passed" in 20s against an empty table. `./load` now creates that
symlink itself.

Note that `du` on the data directory overshoots badly mid-load (22 GB while
ingesting 100M) because each INSERT block lands as its own part with its own
index; background merges collapse them. `./data-size` reports active parts,
which settle at 7.9 GB.
