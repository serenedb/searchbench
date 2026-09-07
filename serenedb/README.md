# SearchBench / SereneDB engine

Runs the official SereneDB Docker image (`serenedb/serenedb:26.09.0`).
Prereqs: `docker`, `psql`, `jq`.

`SEARCHBENCH_DATA_DIR` is the root data dir; the driver roots each scale
under `.../<dataset>/` and the download step materializes the parquet there
(full parts for real scales, a sliced part_000.parquet for smoke).

```bash
# Full benchmark (otel_logs_1b) — --index does download + load + index build
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index
# -> results/serenedb_otel_logs_1b.json

# Smoke (1M rows, sliced + streamed by the download step in seconds)
SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index
```

`--index` (or `SEARCHBENCH_INDEX=1`) triggers the download + load + index
build; omit it to re-run queries only against an already-loaded engine.

The container runs with `--network host` (native latency); the corpus is
identity-mounted read-only so `create.sql`'s `read_parquet` resolves inside it.

## Version history

| version | measured | 92/92 hot | load | on disk |
|---|---|---:|---:|---:|
| 26.07.5 | 2026-07-29 | 3.26s | 49.8s | 11.23G |
| 26.07.5 | 2026-08-14 | 4.21s | 52.3s | 11.23G |
| 26.08.1 | 2026-08-14 | 4.09s | 54.0s | 11.22G |
| **26.09.0** | **2026-09-07** | **3.30s** | **56.6s** | **12.00G** |

The 26.09.0 row is not comparable with the rows above it: it is the first
measured on a search table (create.sql) rather than an index over a view of
read_parquet (now create_view.sql), and it ran on a different data disk
(pd-SSD rather than pd-balanced). Schema, version and hardware all move at
once, so the 4.09s -> 3.30s gap cannot be attributed to any one of them.

**Compare versions only within a measurement day.** 26.07.5 measures 3.26s in
July and 4.21s today on the same box and corpus — a 29% spread from environment
drift alone. Read against the July figure, 26.08.1 looks like a 25% regression;
read against a same-day 26.07.5 baseline it is **~4% faster**, improving in
every task category (top_k -22%, recent -10%, count -8%, join -4%, group_by
-3%). Run-to-run spread within a day is 5ms over four runs, so the same-day
comparison is the trustworthy one.

## Known intentional divergence from Elasticsearch

Q24 (`ts_levenshtein('connection', 2)` AND `ts_starts_with('conn')`) returns
1,340,425 against Elasticsearch's 1,340,428. This is a deliberate behaviour
change in SereneDB, not a defect, and it is **not** version-specific — 26.07.5
and 26.08.1 both return 1,340,425. Q22 and Q23, the same fuzzy term without the
prefix clause, match Elasticsearch exactly. Automated count comparisons will
flag this one query; it is expected.

## Env

| Var | Default | Meaning |
|---|---|---|
| `SERENED_IMAGE` | `serenedb/serenedb:26.09.0` | image |
| `SERENED_CONTAINER` | `searchbench-serenedb` | container |
| `SERENED_DATA_DIR` | `$PWD/serened_data` | host bind-mount data dir (→ `/var/lib/serenedb`); wiped by `./install` |
| `PGPORT` | `5499` | pg-wire host port |

Schema + indexed expression in [`create.sql`](create.sql);
workload in [`queries.sql`](queries.sql).
