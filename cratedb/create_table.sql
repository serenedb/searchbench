-- CrateDB schema for the OTel-logs corpus.
--
-- Mirrors elastic/config/index_mapping.json and serenedb/create.sql so the
-- numbers compare like-for-like:
--   * body is tokenized by a char_group tokenizer on whitespace/punctuation/
--     symbol plus lowercase -- the same split as Elasticsearch's body_analyzer
--     and SereneDB's ts_split_by_non_alpha(Body, true). Deliberately NOT an
--     `english` analyzer: stemming and stopword removal would change which
--     rows match, not just how fast.
--   * body ALSO keeps its plain index. CrateDB's `~` regex operator silently
--     returns zero rows against an INDEX OFF column (no error), and eight
--     queries are regex-based, so INDEX OFF would make them look instant and
--     be wrong. The extra index is a documented cost of running the full
--     workload; see README.
--   * columns nothing filters or groups on are INDEX OFF, and the three
--     attribute maps are OBJECT(IGNORED) -- stored, never indexed. Same intent
--     as ES's `index: false` / OpenSearch's `enabled: false`.
--   * INDEX OFF still leaves the columnstore, so scope_name remains groupable
--     (Q57-Q60, Q67) exactly as ES aggregates on an index:false keyword.
--
-- One shard, no replicas, 30s refresh and best_compression all match the
-- Elasticsearch settings. CrateDB has no equivalent of ES index sorting.

CREATE TABLE otel_logs (
    ts                  TIMESTAMP WITH TIME ZONE,
    trace_id            STRING INDEX OFF,
    span_id             STRING INDEX OFF,
    trace_flags         SMALLINT,
    severity_text       STRING,
    severity_number     SMALLINT,
    service_name        STRING,
    body                STRING,
    INDEX body_ft USING FULLTEXT (body) WITH (analyzer = 'sb_body'),
    resource_schema_url STRING INDEX OFF,
    resource_attributes OBJECT(IGNORED),
    scope_schema_url    STRING INDEX OFF,
    scope_name          STRING INDEX OFF,
    scope_version       STRING INDEX OFF,
    scope_attributes    OBJECT(IGNORED),
    log_attributes      OBJECT(IGNORED)
) CLUSTERED INTO 1 SHARDS
  WITH (number_of_replicas = 0, refresh_interval = 30000, codec = 'best_compression')
