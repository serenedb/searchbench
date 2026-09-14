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

    -- Inverted index only: no set()/minmax skip indexes, so non-Body predicates
    -- scan. support_phrase_search=1 plus the table setting below are BOTH
    -- required for positions; text_index_serialization_version only names the
    -- on-disk format and writes nothing positional on its own.
    INDEX text_idx(Body) TYPE text(tokenizer = 'splitByNonAlpha', preprocessor = lower(Body), support_phrase_search = 1)
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS allow_experimental_text_index_phrase_search = 1;
