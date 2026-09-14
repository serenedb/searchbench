-- BACKUP. This was the schema before the corpus moved into a search table;
-- create.sql is what runs now and ./load is hardwired to it. Kept for reference
-- -- point ./load here by hand to run it.
--
-- Don't preserve parquet row order while building the index. The inverted-index
-- build reads the whole otel_logs view (read_parquet) and doesn't need rows in
-- file order; letting the engine process/insert out of order cuts memory and
-- speeds up the large index builds. Applies for the whole psql session below.
SET preserve_insertion_order = false;

-- otel_logs may exist as either a TABLE (from a prior `load` run) or a VIEW
-- (from a prior `load_view` run). `DROP TABLE IF EXISTS` errors with "is not
-- a table" when the relation is a view, and vice versa — IF EXISTS only
-- suppresses the missing-relation case, not the wrong-kind case. Temporarily
-- disabling ON_ERROR_STOP lets whichever DROP applies actually run.
\set ON_ERROR_STOP off
DROP INDEX IF EXISTS otel_logs_idx;
DROP VIEW IF EXISTS otel_logs CASCADE;
\set ON_ERROR_STOP on

DROP TEXT SEARCH DICTIONARY IF EXISTS en;
DROP TEXT SEARCH DICTIONARY IF EXISTS alnum_lower;

-- Tokenization is done by the ENGINE through the `en` dictionary, matching
-- create.sql: split on runs of non-alphanumerics, lowercased via case='lower',
-- applied at index AND query time. The ts_split_by_non_alpha(Body, true)
-- expression index with a `keyword` dictionary that this file used to carry was
-- dropped along with create.sql's -- `keyword` does no query-side analysis and
-- silently lost rows when two multi-term predicates were conjoined (Q24, Q29;
-- see create.sql for the repro).
CREATE TEXT SEARCH DICTIONARY en (
    template  = 'split_by_non_alpha',  -- engine-side tokenizer
    case      = 'lower',               -- fold to lowercase at index and query time
    frequency = true,        -- term frequency + field norms are
    norm      = true,        -- required for BM25 scoring (top_k queries)
    position  = true         -- token positions (phrase queries; enlarges the index)
);

CREATE VIEW otel_logs AS
SELECT
    timestamp as Timestamp,
    traceid as TraceId,
    spanid as SpanId,
    traceflags as TraceFlags,
    severityText as SeverityText,
    severityNumber::INTEGER as SeverityNumber,
    serviceName as ServiceName,
    body as Body,
    resourceschemaurl as ResourceSchemaUrl,
    resourceattributes as ResourceAttributes,
    scopeschemaurl as ScopeSchemaUrl,
    scopename as ScopeName,
    scopeversion as ScopeVersion,
    scopeattributes as ScopeAttributes,
    logattributes as LogAttributes
FROM read_parquet(:'parquet_glob');

-- Body is tokenized by the `en` dictionary at index-build time. Queries read
-- `Body @@ ...` against the index relation otel_logs_idx (an IRESEARCH_SCAN
-- binds the @@ to the indexed column; a plain scan of the otel_logs view would
-- seq-scan).
--
-- NOTE: this file is a BACKUP of the index-over-parquet-view arrangement and is
-- not what ./load runs -- that is create.sql. It was carried forward to the
-- dictionary form so it stays consistent with queries.sql, but it has not been
-- re-measured since the switch.
CREATE INDEX otel_logs_idx ON otel_logs USING inverted(
    Body en
)
INCLUDE (
    Timestamp,
    TraceId,
    SpanId,
    TraceFlags,
    SeverityText,
    SeverityNumber,
    ServiceName,
    Body,
    ResourceSchemaUrl,
    ResourceAttributes,
    ScopeSchemaUrl,
    ScopeName,
    ScopeVersion,
    ScopeAttributes,
    LogAttributes)
WITH (
    store_pk = 'none',
    optimize_top_k = 'bm25(1.2, 0.75)',
    refresh_interval   = 10000,
    compaction_interval = 5000
);
