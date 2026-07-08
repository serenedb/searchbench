-- BM25 (pg_search) index over otel_logs. Built after the data load so the build
-- can be progress-polled (pg_stat_progress_create_index) and planner stats are
-- fresh (VACUUM ANALYZE in ./load).
--
-- Design (mirrors the SereneDB adapter's index surface):
--   * EVERY column is included in the index and stored as a `fast` (columnar)
--     field, so the index doubles as a column store -- retrieval, ORDER BY, and
--     aggregation run index-only and on-disk size compares like-for-like.
--   * Only the columns SereneDB indexes are actually INDEXED (searchable):
--       body            -- full-text, simple tokenizer (split-on-non-alnum)
--       service_name    -- literal (exact-match keyword equality push-down)
--       severity_number -- numeric (range/equality)
--       timestamp       -- datetime (range windows)
--     Every other column is indexed:false, fast:true -- stored in the columnar
--     store for retrieval / filter / join / group-by, but with NO inverted-index
--     postings (matches SereneDB's INCLUDE-but-not-indexed set). Verified via
--     paradedb.schema(): body/service_name/severity_number/timestamp -> indexed=t,
--     all 11 others -> indexed=f, fast=t.
--   * No primary key: `id` is a plain row-id used only as pg_search's key_field.
--
-- Tokenizer: body uses `pdb.simple` -- lowercase + split on runs of
-- non-alphanumeric characters (docs: "splits on any non-alphanumeric character
-- (whitespace, punctuation, symbols)"). Matches ClickHouse splitByNonAlpha and
-- SereneDB ts_split_by_non_alpha(body, true). 'columnar=true' makes it a fast
-- field too. Verified live on pg_search 0.24.1:
--   'A_b dog_runs 3.14 e.f'::pdb.simple -> {a,b,dog,runs,3,14,e,f}
-- (record defaults to `position`, so phrase queries keep working.)
-- NB: paradedb.schema() reports this tokenizer as `default` -- pg_search's
-- SimpleTokenizer is registered under the name `default`, and `pdb.simple`
-- resolves to it (NOT to `unicode_words`, which is the tokenizer applied to an
-- unconfigured column). Docs: .../tokenizers/available-tokenizers/simple
--
-- NOTE (pg_search 0.24.1): `datetime_fields` was removed -- `timestamp` is
-- auto-detected as a datetime field from the column list (indexed + fast).

-- Parallelize the BM25 build: pg_search honors Postgres parallel-maintenance
-- workers, so give it workers + memory. (Capped by the server's
-- max_parallel_workers / max_worker_processes; see ./start if you need > default.)
SET max_parallel_maintenance_workers = 8;
SET maintenance_work_mem = '2GB';

CREATE INDEX otel_logs_idx ON otel_logs USING bm25 (
    id,
    timestamp,
    trace_id,
    span_id,
    trace_flags,
    severity_text,
    severity_number,
    (service_name::pdb.literal),
    (body::pdb.simple('columnar=true')),
    resource_schema_url,
    resource_attributes,
    scope_schema_url,
    scope_name,
    scope_version,
    scope_attributes,
    log_attributes
) WITH (
    key_field = 'id',
    -- Stored-only text columns: columnar (fast) but not indexed.
    text_fields = '{
        "trace_id":            {"indexed": false, "fast": true},
        "span_id":             {"indexed": false, "fast": true},
        "severity_text":       {"indexed": false, "fast": true},
        "resource_schema_url": {"indexed": false, "fast": true},
        "scope_schema_url":    {"indexed": false, "fast": true},
        "scope_name":          {"indexed": false, "fast": true},
        "scope_version":       {"indexed": false, "fast": true}
    }',
    -- INDEXED numeric: severity_number. trace_flags stored fast only.
    numeric_fields = '{
        "severity_number":     {"fast": true},
        "trace_flags":         {"indexed": false, "fast": true}
    }',
    -- JSONB attribute maps: stored fast (columnar) only, never indexed.
    json_fields = '{
        "resource_attributes": {"indexed": false, "fast": true},
        "scope_attributes":    {"indexed": false, "fast": true},
        "log_attributes":      {"indexed": false, "fast": true}
    }'
);
