-- OTel-logs schema, adopted verbatim from TextBench's clickhouse/create.sql.
-- DROP first so a re-run after a partial load starts clean (./install also
-- wipes the datadir, but this keeps the DDL self-contained).
DROP TABLE IF EXISTS otel_logs;

CREATE TABLE otel_logs
(
    `Timestamp`          DateTime,
    `TraceId`            String CODEC(ZSTD(1)),
    `SpanId`             String CODEC(ZSTD(1)),
    `TraceFlags`         UInt8,
    `SeverityText`       LowCardinality(String) CODEC(ZSTD(1)),
    `SeverityNumber`     UInt8,
    `ServiceName`        LowCardinality(String) CODEC(ZSTD(1)),
    `Body`               String CODEC(ZSTD(1)),
    `ResourceSchemaUrl`  LowCardinality(String) CODEC(ZSTD(1)),
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ScopeSchemaUrl`     LowCardinality(String) CODEC(ZSTD(1)),
    `ScopeName`          String CODEC(ZSTD(1)),
    `ScopeVersion`       LowCardinality(String) CODEC(ZSTD(1)),
    `ScopeAttributes`    Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `LogAttributes`      Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- INVERTED INDEX ONLY. The `text` index over Body is a true inverted index
    -- (token -> posting list) -- the analog of SereneDB's inverted index and the
    -- only thing under test here. splitByNonAlpha + lower(Body) matches the
    -- tokenization SereneDB applies (ts_split_by_non_alpha(Body, true)).
    --
    -- We deliberately do NOT add set()/minmax data-skipping indexes on
    -- ServiceName / SeverityNumber / Timestamp: those are secondary skip indexes
    -- (granule pruning), NOT inverted indexes, and ClickHouse has no inverted
    -- index for categorical/numeric columns. So those predicates scan the
    -- columnstore unindexed -- the honest inverted-index-only setup. (Note:
    -- SereneDB *does* invert those columns; ClickHouse simply cannot.)
    -- positions=1 stores positional postings, so matchPhrase is resolved by the
    -- index alone. Without it the plan falls back to a hasPhrase() re-check on
    -- the raw column (visible as a Prewhere filter in EXPLAIN indexes=1).
    INDEX text_idx(Body) TYPE text(tokenizer = 'splitByNonAlpha', preprocessor = lower(Body), positions = 1)
)
ENGINE = MergeTree
-- No primary key: order by nothing, so rows keep insertion (row-id) order and
-- there is no sorting key. Acceleration comes from the skip indexes above, not
-- from a primary key on ServiceName/Timestamp.
ORDER BY tuple()
SETTINGS allow_experimental_text_index_positions = 1;
