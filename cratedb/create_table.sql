-- body is indexed twice: the default plain index plus body_ft. The plain one
-- exists only for `~`, which silently returns zero rows against an INDEX OFF
-- column (LIKE and MATCH work either way). Only Q19 and Q26 use it.
-- Shard count is CrateDB's default (4 here); replicas pinned to 0 because the
-- 0-1 default would auto-expand if a node were added.

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
