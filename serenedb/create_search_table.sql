-- SereneDB schema variant: a SEARCH TABLE (storage='search') instead of an
-- inverted index over a view of read_parquet.
--
-- create.sql (the default) keeps the rows in parquet and builds an inverted
-- index over a VIEW of them, so queries read the index relation and its INCLUDE'd
-- columns. Here the rows are ingested into SereneDB's own iresearch columnstore
-- and the index is built on that table. Same corpus, same 92 queries, same
-- tokenizer -- what changes is where the data lives and which scan serves it
-- (SearchFullScan / SereneDBSearchInsert rather than a scan of the index
-- relation).
--
-- Selected with SERENEDB_SCHEMA=create_search_table.sql; ./load runs whichever
-- file that names.
--
-- THE INDEX MUST EXIST BEFORE THE ROWS. A search table has no backfill path
-- today -- CREATE INDEX on an already-populated search table is not the
-- supported order -- so the sequence is: create empty, index, insert, refresh.
-- scripts/perf/run_search_table_perf.sh in the serenedb repo does the same.
--
-- The table is named otel_logs_idx so queries.sql runs against it verbatim: the
-- workload must not change between the two variants or the comparison measures
-- the queries rather than the storage.

SET preserve_insertion_order = false;

-- Either variant may have run before, and the relation kinds differ between them
-- (index vs table), so IF EXISTS alone is not enough -- it suppresses "missing"
-- but not "wrong kind". Drop both shapes with errors tolerated.
\set ON_ERROR_STOP off
DROP INDEX IF EXISTS otel_logs_idx;
DROP TABLE IF EXISTS otel_logs_idx;
DROP VIEW IF EXISTS otel_logs CASCADE;
\set ON_ERROR_STOP on

DROP TEXT SEARCH DICTIONARY IF EXISTS en;

-- Identical to create.sql: keyword template (verbatim array elements), with
-- frequency/norm/position so BM25 top_k and phrase queries work.
CREATE TEXT SEARCH DICTIONARY en (
    template  = 'keyword',
    frequency = true,
    norm      = true,
    position  = true
);

-- Source view over the parquet, same column aliasing as create.sql so both
-- variants expose the same names to queries.sql.
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

-- 1. Empty search table with the view's schema.
--    The maintenance cadence belongs HERE, not on the index: a search-backed
--    index shares the table's own store rather than creating its own
--    (catalog/ddl/indexes.cpp), so SearchTableOptions --
--    refresh_interval_ms / compaction_interval_ms / cleanup_interval_step /
--    segment_memory_max -- is what actually governs it. Values match
--    create.sql's index so the two variants differ in storage, not tuning.
--
--    CAUTION: the table WITH clause does NOT validate option names -- a bogus
--    key is accepted silently (verified). So an option misplaced here fails
--    quietly rather than erroring, which is how the earlier
--    compaction_interval = 0 slipped through. The index WITH clause does
--    validate ("unrecognized parameter"), so misplaced options are caught there.
CREATE TABLE otel_logs_idx
WITH (
    storage = 'search',
    refresh_interval    = 10000,
    compaction_interval = 5000
) AS
SELECT * FROM otel_logs WHERE false;

-- 2. Index BEFORE the rows (see the note above). Same indexed expression and
--    opclass as create.sql so the two variants tokenize identically, and the
--    same BM25 parameters so top_k scoring matches.
CREATE INDEX otel_logs_search_inv ON otel_logs_idx USING inverted(
    (ts_split_by_non_alpha(Body, true)) en
)
WITH (
    -- Scorer only. store_pk is irrelevant on a search table (the table owns the
    -- rows, so the index makes no separate PK-storage decision), and the
    -- refresh/compaction intervals live on the table above.
    optimize_top_k = 'bm25(1.2, 0.75)'
);

-- 3. Ingest. No INCLUDE list: a search table stores every column itself, which
--    is the substantive difference from create.sql.
INSERT INTO otel_logs_idx SELECT * FROM otel_logs;

-- 4. Commit the iresearch writer. There is no background commit thread during a
--    load, so without this the data is not durable and data-size is understated.
VACUUM (REFRESH_TABLE) otel_logs_idx;
