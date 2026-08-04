-- Indexes for TigerData, built after the load (fresh stats, bulk BM25 build).
-- otel_logs is a hypertable, so each index is propagated per chunk; the
-- automatic per-chunk (timestamp DESC) index from create_hypertable is what lets
-- ChunkAppend serve ORDER BY timestamp DESC LIMIT 100 newest-first, stopping
-- early (fuzzy top-K Q48: 2.3s -> 0.015s at 1M).
--
-- HYBRID, because pg_textsearch's `<@>` is an ORDER-BY-only operator (the only
-- strategy the bm25 AM exposes): it serves `ORDER BY body <@> q LIMIT k` and
-- nothing else, so a predicate over it is a seq scan. Running the whole workload
-- through BM25 alone measured 5.6x slower (392s vs 70s at 1M), hence GIN for the
-- boolean/aggregating families. queries.sql maps each query to its index.
--
-- INDEXED: body (searched) and timestamp (partition column). The other 13
-- columns live only in the heap. service_name is a filter/GROUP BY key but needs
-- no index -- chunk exclusion narrows the window first, then it is a cheap
-- Filter. severity_text/scope_name are GROUP BY keys over already-narrow sets.
--
-- text_config='simple' on both: lowercase, no stemming, no stopwords, so the two
-- indexes agree on what a term is. k1/b left at BM25 defaults (1.2/0.75).
--
-- NOT built, deliberately:
--   * (trace_id, service_name) for the self-joins. Helps at 1M (Q86 60s cap ->
--     0.58s) but neither the Postgres nor ParadeDB adapter has an equivalent, so
--     it gave TigerData an unfair edge on the join column. At 100M it changes
--     nothing: all 9 joins cap at 60s for every engine, and Q90 measured ~18.7s
--     with vs ~17.2s warm without. Re-add only if the siblings get it too.
--   * (service_name, timestamp). Dead weight on a hypertable -- dropping it moved
--     nothing (Q30 0.078->0.074s, Q53/Q73/Q76/Q84 all within noise) for 31 MB.
--   * WITH (timescaledb.transaction_per_chunk) -- 1.431s vs 1.374s; it trades one
--     long lock for per-chunk locks, which helps concurrent writers, not a load.
--   * pg_trgm GIN on body -- fuzzy d<=1 2.2->1.3s but d<=2 WORSE (4.9->6.7s),
--     mixed on the regex queries, +141 MB and a 17s build.

SET max_parallel_maintenance_workers = 8;
SET maintenance_work_mem = '2GB';

CREATE INDEX otel_logs_bm25 ON otel_logs USING bm25 (body) WITH (text_config = 'simple');

CREATE INDEX otel_logs_idx_tsv ON otel_logs USING GIN (to_tsvector('simple', body));

-- Fresh stats for the planner after the index builds.
ANALYZE otel_logs;
