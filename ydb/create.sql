-- YDB schema for SearchBench.
--
-- Row table, not STORE = COLUMN: a column-oriented table ACCEPTS the fulltext
-- index in CREATE TABLE and then silently drops it -- no error, no warning, and
-- `scheme describe` shows no Indexes section at all. Queries then fail with
-- "No global indexes for table". Row storage is the only option that indexes.
--
-- BodyNorm is the reference analyzer materialised at ingest: lowercase, every
-- run of non-alphanumerics collapsed to one space. YDB's tokenizers cannot
-- express "split on every non-alphanumeric" -- `standard` keeps order_id whole,
-- `whitespace` splits only on spaces, `keyword` not at all -- so the split is
-- done in prep.py and the index uses `whitespace` over the result. Verified to
-- reproduce the reference counts exactly (see README).
--
-- The index is created AFTER the load, in ./load: BulkUpsert and the parallel
-- parquet importer both refuse a table carrying a synchronous index
-- ("Only async-indexed tables are supported by BulkUpsert").
CREATE TABLE otel_logs (
    Id                 Uint64 NOT NULL,
    Timestamp          Timestamp,
    TraceId            String,
    SpanId             String,
    TraceFlags         Uint8,
    SeverityText       String,
    SeverityNumber     Uint8,
    ServiceName        String,
    Body               String,
    BodyNorm           String,
    ResourceSchemaUrl  String,
    ResourceAttributes String,
    ScopeSchemaUrl     String,
    ScopeName          String,
    ScopeVersion       String,
    ScopeAttributes    String,
    LogAttributes      String,
    PRIMARY KEY (Id)
) WITH (
    AUTO_PARTITIONING_BY_LOAD = ENABLED,
    AUTO_PARTITIONING_MIN_PARTITIONS_COUNT = 32,
    AUTO_PARTITIONING_MAX_PARTITIONS_COUNT = 256
);
