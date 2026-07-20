# SearchBench — vector (ANN) track

A stand-alone vector-search benchmark that reuses SearchBench's bash harness
conventions. Where the text track measures latency-per-query, the vector track
measures the standard ANN surface: **recall@k vs QPS** (a search-effort sweep),
plus build time and on-disk index size, over three distances × three size tiers.

- **Distances:** Cosine, L2 (euclidean), Inner Product.
- **Tiers:** small (~1 GB), medium (10–20 GB), giant (50–500 GB, opt-in).
- **Engines:** SereneDB (IVF index) and pgvector (HNSW / IVFFlat).
- **Output:** `<engine>/results-vector/<engine>_<dataset>.json`, rendered by
  the stand-alone `vector-ui/` page (recall-vs-QPS Pareto + build/size panels).

It runs as a **parallel track** to the text harness: the same adapter
verb-scripts (`install`/`start`/`stop`/`check`/`data-size` are reused verbatim),
a shared driver `lib/benchmark-vector.sh` mirroring `lib/benchmark.sh`, and the
`vector-ui/build`→static-page flow mirroring `ui/`. The one piece that can't fit
the text `./query` (one-query-in, one-latency-out) contract — the recall+QPS
sweep over binary-bound query vectors against exact-KNN ground truth — lives in
Python helpers the bash driver calls, exactly as the text track calls
`lib/slice_parquet.py` / `lib/check_results.py`.

## Layout

```
lib/benchmark-vector.sh     shared vector driver (bash)         <- mirrors lib/benchmark.sh
lib/download-vectors        registry-driven dataset fetch       <- mirrors lib/download-otel-logs
lib/vector_common.py        dataset registry + loaders + per-metric ground truth
lib/vector_metrics.py       recall@k + latency percentiles (pure stdlib)
lib/vector_ingest.py        ingest base vectors + build one index config (per engine)
lib/vector_query.py         the recall-vs-QPS sweep (binary-bound KNN, concurrent)
serenedb/benchmark-vector.sh, serenedb/load-vector       SereneDB adapter (reuses its lifecycle scripts)
pgvector/                   pgvector adapter (Docker, mirrors postgres/); HNSW and
                            IVFFlat run as SEPARATE identities via two entrypoints:
                            benchmark-hnsw.sh + benchmark-ivfflat.sh
vector-ui/{build,index.html}  stand-alone recall-vs-QPS page
```

## Prerequisites

- `docker`, `psql`, `jq` (same as the text track).
- Python 3.10+ with the vector deps:
  `pip install -r lib/requirements.txt -r lib/requirements-vector.txt`
  (numpy, h5py, psycopg, pyarrow).
- **SereneDB image with the IVF index.** The adapter uses the same
  `serenedb/serenedb` image as the text track (`SERENED_IMAGE` to override).
  **Verify it exposes the `ivf` opclass** before a real run:
  ```sql
  CREATE TABLE t (id BIGINT, emb FLOAT[3]);
  CREATE INDEX i ON t USING inverted(id, emb ivf (metric='l2'));
  ```
  If the released image lacks it, point `SERENED_IMAGE` at a build that has it.
- pgvector uses the stock `pgvector/pgvector:pg17` image (auto-pulled).

## Quick start — offline smoke (no downloads)

The `synthetic` dataset generates random vectors in-process and runs in seconds
— use it to validate the plumbing end-to-end for both engines:

```bash
export SEARCHBENCH_DATA_DIR=/path/to/vecdata      # a scratch root; synthetic needs no files

cd serenedb && SEARCHBENCH_VECTOR_DATASET=synthetic ./benchmark-vector.sh   --index && cd ..
cd pgvector && SEARCHBENCH_VECTOR_DATASET=synthetic ./benchmark-hnsw.sh     --index && cd ..
cd pgvector && SEARCHBENCH_VECTOR_DATASET=synthetic ./benchmark-ivfflat.sh  --index && cd ..

./vector-ui/build && open vector-ui/index.html
```

(Recall on synthetic gaussian data is only a smoke signal — IVF/HNSW need real
cluster structure. Use the real datasets below for meaningful recall.)

## Real datasets

`SEARCHBENCH_VECTOR_DATASET` selects a registry key (`python3
lib/vector_common.py list`). The driver roots data under
`$SEARCHBENCH_DATA_DIR/<dataset>/`, exactly like the text track.

| key | distance | tier | fetch |
|---|---|---|---|
| `glove_cosine_small` | cosine | small | auto (ann-benchmarks HDF5) |
| `dbpedia_cosine_medium` | cosine | medium | stage a ≥3M dbpedia-openai parquet (see registry note) |
| `cohere_cosine_giant` | cosine | giant | stage Cohere/wikipedia-22-12 parquet |
| `gist_l2_small` | l2 | small | auto (ann-benchmarks HDF5) |
| `deep_l2_medium` | l2 | medium | big-ann Deep1B `.fbin`, 40M slice (GT recomputed) |
| `deep_l2_giant` | l2 | giant | big-ann Deep1B (official 1B GT) |
| `t2i_ip_small` | ip | small | big-ann text2image `.fbin`, 1M slice (GT recomputed) |
| `t2i_ip_medium` | ip | medium | big-ann text2image-10M (official GT) |
| `t2i_ip_giant` | ip | giant | big-ann text2image-100M (official GT) |

HDF5 tiers auto-download. `fbin`/`hf` tiers are staged externally (too large /
auth'd) — `lib/download-vectors` verifies presence and prints how to stage them
(big-ann-benchmarks `create_dataset.py` for fbin; a HuggingFace parquet for hf).
Giant tiers are `opt_in` — wired but not part of default runs.

```bash
# small tier, all three series (GloVe cosine shown; swap the dataset key)
DS=glove_cosine_small
cd serenedb && SEARCHBENCH_VECTOR_DATASET=$DS ./benchmark-vector.sh   --index && cd ..
cd pgvector && SEARCHBENCH_VECTOR_DATASET=$DS ./benchmark-hnsw.sh     --index && cd ..
cd pgvector && SEARCHBENCH_VECTOR_DATASET=$DS ./benchmark-ivfflat.sh  --index && cd ..
./vector-ui/build
```

## Knobs (env)

| var | default | meaning |
|---|---|---|
| `VECTOR_K` | 10 | recall@k (rerun with 100 for recall@100) |
| `VECTOR_SEARCH_EFFORT` | `8,16,32,64,128` | sweep list — nprobe (SereneDB) / ef_search (pgvector) |
| `VECTOR_CLIENTS` | 1 | concurrency sweep (QPS is closed-loop across N connections) |
| `VECTOR_NB` / `VECTOR_NQ` | registry | override base/query slice sizes |
| `VECTOR_QUANT` | `none` | SereneDB: comma list of `none,sq8,sq4,pq,rabitq` (build sweep) |
| `VECTOR_NLIST` | `auto` | SereneDB: comma list of IVF cluster counts |
| `VECTOR_RERANK` | unset | SereneDB quantized: `sdb_rerank_factor` |
| `VECTOR_HNSW_M` / `VECTOR_EF_CONSTRUCTION` | `16` / `64` | pgvector HNSW build sweep (`benchmark-hnsw.sh`) |
| `VECTOR_LISTS` | `1000` | pgvector IVFFlat build sweep — comma list of cell counts (`benchmark-ivfflat.sh`) |

The pgvector index algorithm is chosen by the entrypoint (HNSW vs IVFFlat are
distinct engine identities, separate results files and UI series), not an env
var. Each build config (a point in the SereneDB quant×nlist grid, the pgvector
HNSW m×ef_construction grid, or the IVFFlat lists sweep) is one `./load-vector`
+ a full search-effort×clients sweep; all points land in that identity's results
file.

## Result schema

Top level: `{system, engine, dataset, distance, tier, dim, nb, nq, k, version,
os, date, tags, results:[…]}`. Each `results[]` record = build-config identity +
build metrics + one sweep point:

```
build_algo, quant|m, nlist|ef_construction,
load_s, index_build_s, build_total_s, index_disk_bytes, datadir_bytes, ddl,
search_effort, clients, k, recall_at_k, qps,
lat_ms_mean, lat_ms_p50, lat_ms_p95, lat_ms_p99, lat_ms_min, lat_ms_max, n_queries
```

`search_effort` is the **unified knob** (nprobe for SereneDB, ef_search for
pgvector) — compare recall-vs-QPS *curves*, not points at equal effort.

## Ground truth & recall

Exact top-k neighbors per metric (`lib/vector_common.py`): HDF5 ships its own GT;
big-ann fbin uses the official `.ibin` when it fits the loaded slice, else
recomputes brute-force and caches (`gt_cache_*.npy`). Two guards refuse to report
meaningless recall: `k` larger than the GT file, and official GT ids beyond the
loaded `nb`. Default k=10 (ann-benchmarks standard).

## Notes

- SereneDB runs the same Docker image as the text track; pgvector runs
  `pgvector/pgvector:pg17`. Both are queried over pgwire with binary-bound query
  vectors (pgvector uses a text-cast param unless the `pgvector` python package
  is installed for binary binding).
- Peak RAM is not recorded (the text track measures only load time + on-disk
  size); add it later via cgroup accounting if needed.
- The DDL is generated in `lib/vector_ingest.py` (not a static `create-*.sql`)
  because it is parametric across the build sweep — the per-engine SQL is the
  `serenedb_index_ddl` / `pgvector_index_ddl` builders there.
