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
-- Shard count is left at CrateDB's own default (4 on a single node) rather than
-- pinned. It used to be CLUSTERED INTO 1 SHARDS "to match the Elasticsearch
-- settings", but that was not the even-handed choice it looked like: 1 IS the
-- default for Elasticsearch 9 and OpenSearch 3, so those two run as they ship
-- while only CrateDB was being overridden away from its default.
--
-- Measured at 10m across 1/4/8/16 shards, the aggregate is unchanged --
-- sum(hot) 19.37 / 20.15 / 18.21 / 20.57s, a +/-6% spread with no trend -- so
-- the override bought nothing. The per-query profile does shift: scans fan out
-- and win (Q26 5.0x, Q11 6.7x, Q19 3.7x faster at 16 shards) while joins and
-- top-k pay cross-shard coordination and lose (Q84-Q92 1.2-1.4x, Q54 8.8x).
--
-- replicas stays pinned at 0: the default 0-1 auto-expands, which resolves to 0
-- on one node but would silently change the measurement if a node were added.
-- 30s refresh and best_compression still match the Elasticsearch settings.
-- CrateDB has no equivalent of ES index sorting.

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
) WITH (number_of_replicas = 0, refresh_interval = 30000, codec = 'best_compression')
