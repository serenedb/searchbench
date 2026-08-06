-- Build settings (max_parallel_maintenance_workers, maintenance_work_mem) are
-- set server-side from lib/pg-tuning.sh, the single source of truth shared by the
-- postgres/parade/tiger adapters. Deliberately NOT re-SET here: a session SET
-- silently overrides the server value, which is exactly the drift that made these
-- two disagree before.

-- GIN over the to_tsvector('simple', body) EXPRESSION for full-text predicates
-- (queries use the identical expression, so the planner matches this index),
CREATE INDEX otel_logs_idx_tsv ON otel_logs USING GIN (to_tsvector('simple', body));
