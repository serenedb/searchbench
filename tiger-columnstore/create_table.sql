-- TigerData COLUMNSTORE schema. Mirror of ../tiger/create_table.sql -- same 15
-- OTel columns, same extensions, same hypertable -- with the columnstore declared
-- inline. A schema change has to land in both files; that duplication is the
-- price of the two adapters differing in a table property rather than a script,
-- and it is the same shape as ../elastic-columnar's copy of index_mapping.json.
--
-- THE HYPERTABLE IS NOT OPTIONAL. TimescaleDB's columnstore is a per-chunk
-- property of a hypertable: enable_columnstore, segmentby/orderby and
-- compress_chunk() all operate on chunks, and there is no columnstore for a plain
-- Postgres table. So this file still declares one -- what differs from the
-- rowstore adapter is that the chunks are told, at birth, to be columnar.
--
-- No id/PRIMARY KEY: pg_textsearch indexes a text column directly and needs no
-- key_field (unlike ParadeDB's pg_search, hence parade's extra `id`). No stored
-- tsvector column either -- a STORED generated column can't be COPYed into, and
-- serened's connector writes every column positionally.
--
-- fuzzystrmatch supplies levenshtein_less_equal() for the fuzzy queries (Q22-24,
-- Q48-49, Q59); no index can serve them, so they seq-scan behind a pigeonhole
-- prefilter (see queries.sql).
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

DROP TABLE IF EXISTS otel_logs CASCADE;

-- HYPERTABLE + COLUMNSTORE, both declared inline via WITH (tsdb.*) -- the form
-- the docs prefer over follow-up create_hypertable() / ALTER TABLE calls
-- (2.23.0+).
-- :chunk_iv comes from ./load as `psql -v chunk_iv='<n> milliseconds'`, n =
-- corpus span / $TIGER_CHUNKS from parquet metadata: the span scales with the
-- dataset (1.77s at 1M, minutes at 1B) so no fixed interval fits every scale.
-- Side effect: this file is not runnable standalone -- run ./load.
--
-- segmentby = service_name: the workload's one low-cardinality equality key
-- (Q31, Q53, Q66, Q68, Q72-Q73, Q76, Q80-Q81, and `b.service_name` in every join
-- Q84-Q92). Rows are grouped by it, so those filters skip whole compressed
-- batches instead of decompressing them.
-- orderby = timestamp DESC: the partition column and the sort of every `recent`
-- query (Q68-Q75). It puts a minmax sparse index on timestamp, so the BETWEEN
-- windows in Q30-Q32, Q53 and Q68-Q83 prune, and newest-first LIMIT reads batches
-- in order. The default would also pick timestamp; spelling it out keeps the two
-- adapters' intent reviewable side by side.
-- NOT set: tsdb.sparse_index. The defaults already cover the orderby column, and
-- the only other filter column that is not the segmentby key (severity_number,
-- Q69/Q77) is reached only after a text predicate has already forced the batch to
-- decompress.
-- NOT set: tsdb.direct_compress, which would compress on INSERT and skip the
-- rewrite in create_index.sql. It is new in 2.29 and changes the ingest path, so
-- this adapter takes the documented load-then-convert route instead; the rewrite
-- cost stays visible in load_time either way.
--
-- Declaring the columnstore here does NOT compress anything by itself: rows still
-- land in the rowstore and the chunks are converted in create_index.sql, which is
-- the phase ./load times.
--
-- Accepted caveat, same as the rowstore adapter: pg_textsearch keeps corpus stats
-- per relation, so each chunk normalises over its own ~1/8.
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
    tsdb.chunk_interval = :'chunk_iv',
    tsdb.enable_columnstore = true,
    tsdb.segmentby = 'service_name',
    tsdb.orderby = 'timestamp DESC'
);
