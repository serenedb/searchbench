-- BM25 (pg_search) index over otel_logs. Built after the data load so the build
-- can be progress-polled (pg_stat_progress_create_index) and planner stats are
-- fresh (VACUUM ANALYZE in ./load).
--
-- Only columns some query references are in the index; the other 8 (span_id,
-- trace_flags, scope_version, both schema URLs, the 3 JSONB attribute maps) live
-- in the heap alone. Measured at 1M vs the previous all-16-column variant:
-- index 126->78 MB, build 3.0->1.3s, identical results and plans on the 92-query
-- workload.
--   INDEXED (searchable, matching the SereneDB adapter's searched set):
--     body            -- full-text, simple tokenizer (split-on-non-alnum)
--     service_name    -- literal (exact-match equality push-down)
--     severity_number -- numeric (range/equality)
--     timestamp       -- datetime (range windows; auto-detected, pg_search
--                        0.24.1 removed datetime_fields)
--   STORED-ONLY (indexed:false, fast:true -- columnar for projections and the
--   ParadeDB Aggregate Scan push-down):
--     severity_text, scope_name -- GROUP BY keys (Q54-Q60, Q66-67); without fast
--       fields those group-bys lose the push-down and run 8-10x slower at 1M
--     trace_id -- join key (Q84-92); no measurable effect at 1M (joins read the
--       heap either way) but kept as insurance for plan shifts at scale
--   * No primary key: `id` is a plain row-id used only as pg_search's key_field.
--
-- Tokenizer: body uses `pdb.simple` -- lowercase + split on runs of
-- non-alphanumeric characters, matching ClickHouse splitByNonAlpha and SereneDB
-- ts_split_by_non_alpha(body, true). 'columnar=true' makes it a fast field too.
-- Verified on pg_search 0.24.1: 'A_b dog_runs 3.14 e.f'::pdb.simple ->
-- {a,b,dog,runs,3,14,e,f}; record defaults to `position`, so phrase queries
-- work. paradedb.schema() reports this tokenizer as `default` (pg_search's
-- SimpleTokenizer registered name), not `unicode_words`.

-- Build settings (max_parallel_maintenance_workers, maintenance_work_mem) are
-- set server-side from lib/pg-tuning.sh, the single source of truth shared by the
-- postgres/parade/tiger adapters. Deliberately NOT re-SET here: a session SET
-- silently overrides the server value, which is exactly the drift that made these
-- two disagree before.

CREATE INDEX otel_logs_idx ON otel_logs USING bm25 (
    id,
    timestamp,
    trace_id,
    severity_text,
    severity_number,
    (service_name::pdb.literal),
    (body::pdb.simple('columnar=true')),
    scope_name
) WITH (
    key_field = 'id',
    -- Stored-only text columns: columnar (fast) but not indexed.
    text_fields = '{
        "trace_id":      {"indexed": false, "fast": true},
        "severity_text": {"indexed": false, "fast": true},
        "scope_name":    {"indexed": false, "fast": true}
    }',
    numeric_fields = '{
        "severity_number": {"fast": true}
    }'
);
