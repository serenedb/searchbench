-- Out-of-order insert: cuts memory on the large loads.
SET preserve_insertion_order = false;

-- otel_logs_idx may be a TABLE or an INDEX; IF EXISTS does not cover the
-- wrong-kind case, so let the inapplicable DROP fail.
\set ON_ERROR_STOP off
DROP INDEX IF EXISTS otel_logs_idx;
DROP TABLE IF EXISTS otel_logs_idx;
DROP VIEW IF EXISTS otel_logs CASCADE;
\set ON_ERROR_STOP on

DROP TEXT SEARCH DICTIONARY IF EXISTS en;

-- Engine-side tokenizer, applied at index AND query time. Query-side analysis
-- is required for correctness: without it, conjoined multi-term predicates lose
-- rows ('connmmm cannection' matches levenshtein+starts_with via two different
-- tokens and must still count once).
CREATE TEXT SEARCH DICTIONARY en (
    template  = 'split_by_non_alpha',
    case      = 'lower',
    frequency = true,        -- frequency + norm: BM25 scoring (top_k)
    norm      = true,
    position  = true         -- phrase queries; enlarges the index
);

-- Ingest source only; queries read otel_logs_idx.
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

CREATE TABLE otel_logs_idx
WITH (
    storage = 'search',
    refresh_interval    = 10000,
    compaction_interval = 5000,
    optimize_top_k = 'bm25(1.2, 0.75)'
) AS
SELECT * FROM otel_logs WHERE false;

CREATE INDEX otel_logs_search_inv ON otel_logs_idx USING inverted(
    Body en
);

INSERT INTO otel_logs_idx SELECT * FROM otel_logs;

VACUUM (REFRESH_TABLE) otel_logs_idx;
