-- Schema for the ParadeDB adapter: the pg_search extension plus an empty
-- otel_logs heap table holding the full 15-column OTel schema -- including the
-- Resource/Scope/Log attribute maps as JSONB -- so on-disk data_size compares
-- like-for-like with the other adapters (which all store the maps). Data is
-- loaded separately (./load); the BM25 index is built afterward from
-- create_index.sql so the build can be progress-polled.

CREATE EXTENSION IF NOT EXISTS pg_search;

DROP TABLE IF EXISTS otel_logs CASCADE;

-- id is the BM25 key_field: pg_search requires a unique, non-null column to
-- identify rows. It is a plain BIGINT row id (NOT a PRIMARY KEY -- pg_search
-- only needs uniqueness, and we deliberately keep no primary key so the table
-- is just row-id-keyed).
-- ./load supplies it explicitly via row_number() OVER () in the SELECT; it is
-- NOT a GENERATED IDENTITY, because serened's DuckDB->Postgres connector does a
-- positional, all-columns COPY and ships a NULL for any column omitted from the
-- INSERT list (violating NOT NULL) instead of letting the server generate it.
-- `timestamp` is a legal column name in Postgres.
-- Body is the BM25-indexed/scored field (create_index.sql). The three OTel
-- attribute maps (resource/scope/log) are stored as JSONB for schema parity
-- with the other adapters; no query (Q1-Q14) references them, so they sit in
-- the heap purely for fidelity (and they dominate on-disk size at ~825 B/row,
-- uncompressible across rows -> roughly half the table).
CREATE TABLE otel_logs (
    id                  BIGINT NOT NULL,
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
