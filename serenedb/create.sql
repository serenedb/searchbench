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

-- Tokenization is done by the SQL function ts_split_by_non_alpha(Body, true):
-- it lowercases (the `true` = to_lower) and splits on runs of non-alphanumeric
-- characters, returning text[]. The index is built over that expression, so
-- each token becomes a searchable term. The `en` dictionary is `keyword`
-- (verbatim: each array element is indexed as-is, no further analysis) with
-- frequency/norm/position enabled so BM25 scoring (top_k) and phrase/position
-- queries work.
--
-- NOTE: because the analyzer is `keyword`, the *query* side does not re-split
-- multi-word strings. Multi-token operators must be given pre-split tokens:
-- ts_all/ts_any take token arrays, and ts_phrase takes one token per argument
-- (ts_phrase('failed','to','place','order'), NOT ts_phrase('failed to ...')).
CREATE TEXT SEARCH DICTIONARY en (
    template  = 'keyword',   -- verbatim: index each token array element as-is
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

-- Body is tokenized by ts_split_by_non_alpha(Body, true) at index-build time.
-- Queries match the SAME expression: `ts_split_by_non_alpha(Body, true) @@ ...`
-- against the index relation otel_logs_idx (an IRESEARCH_SCAN binds the @@ to
-- this indexed expression; a plain scan of the otel_logs view would seq-scan).
CREATE INDEX otel_logs_idx ON otel_logs USING inverted(
    (ts_split_by_non_alpha(Body, true)) en,
    ServiceName,
    SeverityNumber,
    Timestamp
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
