# SearchBench vector-search UI

A single self-contained static page (no framework, no CDN, no build toolchain)
that renders every engine's `results-vector/*.json` as the ANN recall-vs-QPS
surface — the vector-track counterpart of `ui/`.

## Build & view

```bash
./vector-ui/build          # scans */results-vector/*.json -> vector-ui/data.js
open vector-ui/index.html  # or serve the dir over HTTP
```

`vector-ui/build` (bash + jq) inlines all vector result docs into
`vector-ui/data.js`, loaded via `<script src>` so the page works over `file://`
and from any static host. Re-run after each new vector benchmark. It reuses
`../ui/fonts.css` for the shared look (falls back to system fonts if absent).

## What it shows

- **Distance** (Cosine / L2 / Inner-Product) and **size tier**
  (small / medium / giant) selectors pick the dataset; engine chips toggle series.
- **Recall vs QPS** — recall@k on x, QPS (log) on y; a bold line per engine
  through the best-QPS-per-recall-band points (the Pareto frontier), with every
  raw sweep point as faint dots. Up-and-right is better. The knob behind each
  point differs per series (SereneDB `nprobe`, pgvector HNSW `ef_search`,
  pgvector IVFFlat `ivfflat.probes`), so compare the *curves*, not points at
  equal effort. pgvector HNSW and IVFFlat appear as separate series.
- **Build cost & index size** — per build config, per engine.

`vector-ui/data.js` is generated — don't edit it by hand.
