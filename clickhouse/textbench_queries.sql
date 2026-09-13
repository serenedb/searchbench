-- ClickHouse FTS workload. One query per line (the SearchBench driver reads
-- queries.sql line by line). Q1-Q9 mirror TextBench's clickhouse/queries.sql
-- verbatim and line up index-for-index with serenedb/queries.sql Q1-Q9.
--
-- Q10-Q14 are SereneDB's BM25 scored top-K queries (WAND / MaxScore /
-- BlockMax-WAND). ClickHouse's text index does boolean token matching only --
-- no BM25 ranking -- so those slots are UNSUPPORTED sentinels: ./query
-- short-circuits them to a `null` timing, keeping the 14-row result array
-- aligned 1:1 with SereneDB's for direct comparison.
--
-- Q1: Fetch rows — AND, service filter + time-bounded 30 min
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'checkout' AND hasAllTokens(Body, ['failed', 'order']) AND Timestamp >= '2025-09-23 00:00:00' AND Timestamp < '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q2: Fetch rows — complex boolean, service + severity + time-bounded 30 min
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'frontend' AND (hasAllTokens(Body, ['connection', 'reset']) OR hasToken(Body, 'timeout')) AND SeverityNumber >= 13 AND Timestamp >= '2025-09-23 00:00:00' AND Timestamp < '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q3: Fetch rows — OR 5 tokens, full corpus
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'exception', 'failed', 'timeout', 'refused']) ORDER BY Timestamp DESC LIMIT 100;
-- Q4: count() — single token, full corpus
SELECT count() FROM otel_logs WHERE hasToken(Body, 'timeout');
-- Q5: count() — OR 5 high-frequency tokens, full corpus
SELECT count() FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'exception', 'failed', 'timeout', 'refused']);
-- Q6: GROUP BY service + count — OR, full corpus
SELECT ServiceName, count() AS cnt FROM otel_logs WHERE hasAnyTokens(Body, ['exception', 'timeout', 'failed']) GROUP BY ServiceName ORDER BY cnt DESC;
-- Q7: GROUP BY service + count — AND, full corpus
SELECT ServiceName, count() AS cnt FROM otel_logs WHERE hasAllTokens(Body, ['connection', 'reset']) GROUP BY ServiceName ORDER BY cnt DESC;
-- Q8: Date histogram + count — single token, service filter, full corpus
SELECT toStartOfHour(Timestamp) AS hour, count() AS cnt FROM otel_logs WHERE ServiceName = 'checkout' AND hasToken(Body, 'payment') GROUP BY hour ORDER BY hour;
-- Q9: Date histogram 1hr + count — AND, full corpus
SELECT toStartOfHour(Timestamp) AS hour, count() AS cnt FROM otel_logs WHERE hasAllTokens(Body, ['connection', 'reset']) GROUP BY hour ORDER BY hour;
-- Q10-Q14: BM25 scored top-K — no ClickHouse text-index equivalent (see header)
UNSUPPORTED: Q10 BM25 top-K, single term 'timeout', LIMIT 10
UNSUPPORTED: Q11 BM25 top-K, AND ['connection','reset'], LIMIT 10
UNSUPPORTED: Q12 BM25 top-K, AND ['connection','reset'], LIMIT 10
UNSUPPORTED: Q13 BM25 top-K, OR ['error','exception','failed','timeout','refused'], LIMIT 10
UNSUPPORTED: Q14 BM25 top-K, 'checkout' + 'payment' + time-bounded 6h, LIMIT 10
