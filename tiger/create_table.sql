-- TigerData schema: pg_textsearch (BM25) + fuzzystrmatch, and otel_logs holding
-- the full 15-column OTel schema -- including the JSONB attribute maps -- so
-- data_size compares like-for-like with the other adapters. Data and indexes come
-- from ./load and create_index.sql (building BM25 after the load is faster).
--
-- No id/PRIMARY KEY: pg_textsearch indexes a text column directly and needs no
-- key_field (unlike ParadeDB's pg_search, hence parade's extra `id`). No stored
-- tsvector column either -- a STORED generated column can't be COPYed into, and
-- serened's connector writes every column positionally, so the GIN index is an
-- EXPRESSION index over to_tsvector('simple', body) and the queries repeat that
-- expression verbatim so the planner matches it.
--
-- fuzzystrmatch supplies levenshtein_less_equal() for the fuzzy queries (Q22-24,
-- Q48-49, Q59); no index can serve them, so they seq-scan behind a pigeonhole
-- prefilter (see queries.sql).
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

DROP TABLE IF EXISTS otel_logs CASCADE;

-- HYPERTABLE, declared inline via WITH (tsdb.*) -- the form the docs prefer over
-- a follow-up create_hypertable() call (2.23.0+; image ships 2.29.0).
-- :chunk_iv comes from ./load as `psql -v chunk_iv='<n> milliseconds'`, n =
-- corpus span / $TIGER_CHUNKS from parquet metadata: the span scales with the
-- dataset (1.77s at 1M, minutes at 1B) so no fixed interval fits every scale.
-- Side effect: this file is not runnable standalone -- run ./load.
-- Worth it because per-chunk indexes give the GIN families a Parallel Append
-- (count 0.127->0.075s vs a plain heap) and time-ordered LIMIT queries an early
-- exit (Q48 2.3s->0.015s); top-K pays a small Merge Append cost (0.007->0.012s).
--
-- ROWSTORE, not columnstore. Docs: "Once chunks are converted to the columnstore,
-- regular B-tree indexes don't apply" -- only sparse indexes (minmax/bloom/
-- firstlast) remain, which skip whole ~1000-row batches but cannot locate rows
-- containing a term. Measured: converting drops every chunk index, BM25 top-K
-- becomes impossible ("no BM25 index found"), GIN counts 0.08->1.66s, histograms
-- 0.08->5.9s. Re-creating indexes after conversion "succeeds" but builds empty
-- ones (16 kB vs 56 MB) -- the rows live in a separate _compressed relation with
-- ~1000 packed per stored row, so there are no per-row TIDs to index. The 2.18
-- "indexes in the columnstore" feature does not help: B-tree/hash only, and its
-- hypercore TAM was removed in 2.22 (verified: no such access method here).
-- Columnstore would win 22x on size and 5.5x on text-free aggregates, of which
-- this workload has none.
--
-- Accepted caveat: pg_textsearch keeps corpus stats per relation, so each chunk's
-- BM25 index normalises over its own ~1/8 -- absolute scores shift ~1-2% and
-- members of a large tie class can swap at the LIMIT boundary. Every returned row
-- is a true match. A time-drifting corpus could reorder more; this one does not.
-- `timestamp` is NOT NULL as the partition column.
CREATE TABLE otel_logs (
    timestamp           TIMESTAMP NOT NULL,
    trace_id            TEXT,
    span_id             TEXT,
    trace_flags         INTEGER,
    severity_text       TEXT,
    severity_number     INTEGER,
    service_name        TEXT,
    body                TEXT,
    resource_schema_url TEXT,
    resource_attributes JSONB,
    scope_schema_url    TEXT,
    scope_name          TEXT,
    scope_version       TEXT,
    scope_attributes    JSONB,
    log_attributes      JSONB
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'timestamp',
    tsdb.chunk_interval = :'chunk_iv'
);
