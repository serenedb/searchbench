-- GIN over the to_tsvector('simple', body) EXPRESSION for full-text predicates
-- (queries use the identical expression, so the planner matches this index),
-- B-tree over (service_name, timestamp) for the structured filters.
CREATE INDEX otel_logs_idx_tsv ON otel_logs USING GIN (to_tsvector('simple', body));
CREATE INDEX otel_logs_idx_svc_ts ON otel_logs (service_name, timestamp);
