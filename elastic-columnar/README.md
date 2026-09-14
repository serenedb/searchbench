# SearchBench / Elasticsearch (columnar index mode)

Elasticsearch 9.5 added [columnar index mode](https://www.elastic.co/docs/manage-data/data-store/columnar)
(tech preview; GA in 9.6): fields are stored as doc values only — no inverted
index or BKD tree — except text fields, which stay indexed so full-text search
still works. That leaves an inverted index on `Body` and columnar storage for
everything else. This adapter measures that mode against the stock one.

## Relationship to `../elastic`

Everything mechanical is a **symlink** to the elastic adapter (`install`,
`start`, `stop`, `check`, `load`, `query`, `data-size`, `version`, `ingest.py`,
`build_lookup.py`, and both query sets). Those scripts `cd` to their own
`$(dirname $0)`, which for a symlink is *this* directory, so `config/` and
`es-data/` resolve locally. Nothing is duplicated, and a workload fix lands in
both engines at once.

Two local files only: `benchmark.sh` (identity + port/container/data-dir) and
`config/index_mapping.json`, which is elastic's mapping plus one line —
`"mode": "columnar"` — so a delta against the Elasticsearch columns isolates the
storage mode and nothing else. After changing the elastic mapping, re-derive it:

```bash
cp ../elastic/config/index_mapping.json config/index_mapping.json
sed -i 's|^  "settings": {$|  "settings": {\n    "mode":               "columnar",|' \
    config/index_mapping.json
```

## Run

```bash
# DSL workload   -> Elasticsearch-columnar (dsl)
SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh --index

# ES|QL workload -> Elasticsearch-columnar (esql), reuses the loaded index
SEARCHBENCH_QUERIES=queries.esql SEARCHBENCH_DATA_DIR=/path/to/data ./benchmark.sh
```

Two `queries.*` files are present, so the driver labels each column with the
dialect that produced it and gives each its own results file.

## Env

Defaults differ from `../elastic` so both can stay loaded at once:

| Var | Default | Meaning |
|---|---|---|
| `ES_PORT` | `9203` | HTTP port (elastic uses 9201) |
| `ES_CONTAINER` | `searchbench-es-columnar` | container |
| `ES_DATA_DIR` | `${PWD}/es-data` | data + logs |
| `ES_IMAGE` | inherited from `../elastic/start` | image |

## Notes

`index.mode` is fixed at index creation, so changing it requires a reload.

Use `columnar`, not `logsdb_columnar` — the latter's logging defaults require a
`@timestamp` field this corpus does not have, and it rejects every document with
`data stream timestamp field [@timestamp] is missing`.

On a basic licence `_source` is `COLUMNAR_STORED`; requesting
`mapping.source.mode: synthetic` is silently ignored.
