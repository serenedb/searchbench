# SearchBench results UI

A single self-contained static page (no framework, no CDN, no build toolchain)
that presents every engine's `results/*.json` ClickBench-style.

## Build & view

```bash
./ui/build          # scans */results/*.json -> ui/data.js
open ui/index.html  # or just double-click it
```

`ui/build` (bash + jq) inlines all result docs into `ui/data.js`, which
`index.html` loads via `<script src>` — so the page works opened straight off
disk (`file://`) and from any static host (GitHub Pages). Re-run `./ui/build`
whenever an engine produces new results.

## Viewing on a remote machine

The page is fully static, so serve the `ui/` directory and forward the port
over SSH:

```bash
# on the remote box
python3 -m http.server 8080 --directory ui --bind 127.0.0.1

# from your laptop
ssh -L 8080:localhost:8080 user@remote
# then open http://localhost:8080/
```

## What it shows

- **Dataset** selector (`otel_logs_100k`, `otel_logs_1b`, …).
- **Cold / Hot** toggle — cold = first run after a page-cache drop; hot = best
  of the two subsequent runs.
- **Table** (default): rows = metrics (load time, on-disk size, geomean, then
  Q01–Q92 — fewer for engines that omit shapes they can't express, e.g.
  OpenSearch runs 83), columns = engines. Query cells show the ratio to the
  fastest engine
  for that query (toggle to absolute seconds), colored green→red; `—` means the
  engine can't express that shape. Ratios follow ClickBench:
  `(10 ms + t) / (10 ms + fastest)`, summarized by geometric mean — the 10 ms
  term keeps sub-millisecond queries from showing wild ratios. **Click any query
  cell** to open a panel with that engine's *exact executed query* (the real
  SQL / ES|QL / DSL, pulled from each adapter's query file by `ui/build`).
  Click a row label to sort the engine columns by that metric.
- **Charts**: per-query latency (grouped bars), load time, and on-disk size,
  with a **log / linear scale toggle** (log by default). Note ClickBench itself
  has no charts — it's a relative-ratio table; the charts here are a SearchBench
  addition.

`ui/data.js` is generated — don't edit it by hand.
