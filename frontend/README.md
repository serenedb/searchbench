# SearchBench frontend

The React UI exports `ProductApp` through `@searchbench/frontend`. It has two
entry points and one set of components:

- `src/standalone.tsx` supplies `results.json`, mounts React and owns the theme.
- `src/index.ts` exports the product for a host such as SereneDB Playground.
  It does not import the standalone JSON or mount a second React root.

All npm configuration, dependencies and commands live in `frontend/`. The
design-kit submodule is pinned at `frontend/deps/serene-design`.

```bash
git submodule update --init --recursive
cd frontend
npm ci
npm run dev
npm run build
```

`dev.html` is Vite's development entry. The dev server also serves it at `/`
and `/index.html`, so development never displays an old committed build.

`npm run build` creates **one self-contained `frontend/index.html`**, including
JS, CSS, fonts and the current `frontend/results.json`. Commit the HTML. It can
be opened with a double click, copied by itself, or hosted as a static page.
No CDN, module fetch or JSON fetch is needed to render it. URL filters and the
theme toggle work in both modes.

## Stable embed links

Use `?dataset=otel_logs_100m&include=SereneDB,ArangoDB&theme=dark` to pin the
engines in an embed. `include` matches exact `system` names, takes precedence
over legacy `hidden` exclusions, and stays an allowlist when the URL is
canonicalized to `?s=` (packed key `i`). New engines are excluded automatically.
An empty or unknown-only list shows no engines. Legacy `hidden` / packed `h`
links still work. Pin `theme=light` or `theme=dark` explicitly in each themed
iframe; an omitted theme uses the visitor's saved preference.

## Refresh results

With Bash and jq installed, run `./frontend/build_results` from the repository
root (or `./build_results` from this directory). It reads `../<engine>/results/`
and writes `results.json` atomically, using the same query selection as the
original assembler on main. Then run `npm run build` in
`frontend/` and commit the JSON and HTML together. The script does not run benchmarks.

## Playground integration

The host provides results before dynamically importing the product:

```ts
const { provideResults } = await import('@searchbench/frontend/results');
provideResults(rows);
const { ProductApp } = await import('@searchbench/frontend');
```

The host supplies `ThemeProvider` and its React Router context. Inside that
context, header links use the host router; standalone links use ordinary anchors
and absolute service URLs. There is no dependency on `@playground/web-kit`.

After this PR is approved, `products/searchbench` can become a submodule. The
playground's data-copy plugin and Docker/ignore rules must then read
`products/searchbench/frontend/results.json` instead of `data/results.json`.
Its `web` build continues importing the frontend's source export. Keep any
private benchmark variants in the host, separate from this public snapshot.

## Checks

From `frontend/`:

```bash
npm run typecheck
npx playwright install chromium   # once, for browser checks
npm test
```

Tests exercise result assembly, failure handling and the committed HTML opened
over `file://` with the network disabled. Rebuild before running browser tests
after changing source or results.
