-- Vanilla Postgres FTS schema.
--
-- No id / PRIMARY KEY (mirrors the other adapters' row-only tables) and NO
-- stored generated tsvector column. The full-text GIN index is built on the
-- expression to_tsvector('simple', body) (see create_index.sql) and queries use
-- that same expression, so @@ predicates are index-accelerated. This is what
-- lets ./load bulk-COPY the corpus in through serened's postgres connector: a
-- STORED generated column cannot be COPYed into (the connector writes every
-- column positionally), which is why the old body_tsv schema forced the slower
-- serened -> CSV -> psql \copy path. NOTE: top_k (ts_rank) queries stay slow
-- regardless -- vanilla PG has no top-k short-circuit, so ts_rank scores every
-- match; a stored column only saved the re-tokenization (~13%), not worth the
-- full-table rewrite it costs at load.
--
-- fuzzystrmatch supplies levenshtein() for the fuzzy queries (Q22-24,48-49,59):
-- vanilla PG FTS has no fuzzy term lookup, so those run levenshtein() over the
-- split-on-non-alpha tokens of Body (seq-scan, faithful to SereneDB's tokens).
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

DROP TABLE IF EXISTS otel_logs;

-- All 15 OTel columns are stored and queryable on demand; Body is the
-- full-text-indexed/scored field (GIN over to_tsvector('simple', body) +
-- ts_rank). The three attribute maps are kept as JSONB so they're queryable as
-- structured maps. `timestamp` is a legal column name in Postgres.
CREATE TABLE otel_logs (
    timestamp           TIMESTAMP,
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
);
