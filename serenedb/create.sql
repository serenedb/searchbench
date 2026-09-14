-- Don't preserve parquet row order while ingesting. The search table reads the
-- whole otel_logs view (read_parquet) and doesn't need rows in file order;
-- letting the engine process/insert out of order cuts memory and speeds up the
-- large loads. Applies for the whole psql session below.
SET preserve_insertion_order = false;

-- otel_logs_idx may exist as either a TABLE (from a prior `load` run) or an
-- INDEX (left by the older create_view.sql schema). `DROP TABLE IF EXISTS` errors with
-- "is not a table" when the relation is an index, and vice versa — IF EXISTS
-- only suppresses the missing-relation case, not the wrong-kind case.
-- Temporarily disabling ON_ERROR_STOP lets whichever DROP applies actually run.
\set ON_ERROR_STOP off
DROP INDEX IF EXISTS otel_logs_idx;
DROP TABLE IF EXISTS otel_logs_idx;
DROP VIEW IF EXISTS otel_logs CASCADE;
\set ON_ERROR_STOP on

DROP TEXT SEARCH DICTIONARY IF EXISTS en;

-- Tokenization is done by the ENGINE, through the `en` dictionary: split on
-- runs of non-alphanumeric characters, lowercased via case='lower'. The index
-- is on the plain column -- `inverted(Body en)` -- so queries read
-- `Body @@ ...` and no SQL function appears on either side.
--
-- This replaced an expression index over ts_split_by_non_alpha(Body, true)
-- paired with a `keyword` dictionary. That arrangement was dropped for two
-- reasons, the first of which is a correctness bug:
--
--   * `keyword` does no analysis on the QUERY side, and when two multi-term
--     predicates were conjoined it lost rows. Q24 (fuzzy AND prefix) returned
--     19,520,309 at 1b where Elasticsearch returns 19,520,322; Q29 was short by
--     one. Isolated repro: a row holding 'connmmm cannection' satisfies
--     levenshtein('connection',2) via one token and starts_with('conn') via
--     another, and the keyword form dropped it -- 1 row instead of 2. Swapping
--     only the dictionary to split_by_non_alpha fixed it with the expression
--     index still in place, so the dictionary was the fault, not the index.
--   * it cost ~3% on ingest: the function ran per row on the way in.
--
-- A consequence worth knowing: the analyzer now runs query-side too, so a
-- needle is lowercased before lookup and `Body @@ 'FAILED'` matches. Under
-- `keyword` it did not, which is why that schema needed pre-split,
-- pre-lowercased tokens in every multi-token operator.
CREATE TEXT SEARCH DICTIONARY en (
    template  = 'split_by_non_alpha',  -- engine-side tokenizer
    case      = 'lower',               -- fold to lowercase at index and query time
    frequency = true,        -- term frequency + field norms are
    norm      = true,        -- required for BM25 scoring (top_k queries)
    position  = true         -- token positions (phrase queries; enlarges the index)
);

-- The parquet is only the source to ingest FROM -- unlike create_view.sql, where
-- this view is what the index is built on and what queries read. Column aliases
-- are identical to that file so both schemas present the same names to
-- queries.sql and the workload never has to change.
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
