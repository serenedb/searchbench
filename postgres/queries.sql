-- Vanilla Postgres FTS tagged workload over otel_logs -- 92 queries mirroring
-- serenedb/queries.sql Q01-Q92 one-for-one (same task/filter/freq tags,
-- same filters, windows, GROUP BY, ORDER BY and LIMIT) so the numbers line up.
-- One runnable statement per line; the preceding `-- Qnn ...` comment carries
-- the tags verbatim (lib/benchmark.sh skips -- and blank lines).
--
-- DIALECT MAPPING (SereneDB ts_* -> vanilla Postgres FTS), what maps and what
-- vanilla Postgres genuinely cannot do as an inverted-index lookup:
--   term/and/or/phrase/proximity/minmatch/negation/prefix  -> to_tsquery /
--       phraseto_tsquery over to_tsvector('simple', body) (GIN-accelerated). `word:*` = prefix,
--       `a <N> b` = proximity, `a & !b` = negation. minmatch(>=2 of 4) is
--       expanded to the 6-way OR of its pairs.
--   prefix-anchored regexp (charg.*, ord.*, conn.*) -> `charg:*` prefix (GIN).
--   fuzzy (levenshtein) -> fuzzystrmatch levenshtein() over the split-on-non-
--       alpha tokens of Body (regexp_split_to_array(lower(body),'[^a-z0-9]+')).
--       Faithful to SereneDB's tokenizer, but SEQ-SCAN: vanilla PG FTS has no
--       fuzzy term lookup. (Q22-24, Q48-49, Q59.)
--   mid/suffix wildcard & mid-char regexp (c.che, %tion, %nnec%) -> raw `body
--       ~*` regex, also SEQ-SCAN: a GIN tsvector cannot answer infix/suffix
--       patterns. (Q19, Q26-27.)
-- NOTE: the FTS expression is to_tsvector('simple', body) -> the `simple` dictionary only
-- lowercases: NO stemming and NO stopword removal (e.g. 'failed' stays 'failed',
-- 'to' is kept). to_tsquery/phraseto_tsquery('simple',...) tokenise the query
-- the same way, so this matches SereneDB's raw-token model much more closely
-- than 'english' did. Residual gap vs Serene: the default PARSER still keeps
-- emails/URLs/hosts/decimals whole (not a pure split-on-non-alnum).

-- ============================ COUNT ============================
-- Q01 task=count filter=term freq=hi
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error');
-- Q02 task=count filter=term freq=lo
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'payment');
-- Q03 task=count filter=and freq=hi (AND, 2 tokens)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & order');
-- Q04 task=count filter=and freq=hi (AND, 4 tokens)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & charge & card & cache');
-- Q05 task=count filter=and freq=lo (AND, 8 tokens)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & send & order & confirmation & email & service & expected & post');
-- Q06 task=count filter=or freq=hi (OR, 2 tokens)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error | failed');
-- Q07 task=count filter=or freq=hi (OR, 4 tokens)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'connection | request | conversion | post');
-- Q08 task=count filter=or freq=mid (OR, 8 tokens)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'payment | exception | refused | send | confirmation | email | expected | deadline');
-- Q09 task=count filter=or,minmatch freq=hi (>=2 of 4)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', '(error&failed)|(error&charge)|(error&cache)|(failed&charge)|(failed&cache)|(charge&cache)');
-- Q10 task=count filter=phrase freq=mid (phrase, 2 tokens)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'place order');
-- Q11 task=count filter=phrase freq=mid (phrase, 4 tokens)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'failed to place order');
-- Q12 task=count filter=phrase freq=lo (phrase, 8 tokens)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'post to email service expected 200 got 500');
-- Q13 task=count filter=phrase,proximity freq=hi (failed within 2 of order)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'failed <2> order');
-- Q14 task=count filter=phrase,or freq=hi (phrase OR term)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'failed to place order') OR to_tsvector('simple', body) @@ to_tsquery('simple', 'charge');
-- Q15 task=count filter=phrase,and freq=mid (phrase AND term)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'failed to place order') AND to_tsvector('simple', body) @@ to_tsquery('simple', 'charge');
-- Q16 task=count filter=regexp freq=hi (charg.*)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'charg:*');
-- Q17 task=count filter=regexp freq=hi (ord.*)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'ord:*');
-- Q18 task=count filter=regexp freq=mid (conn.*)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'conn:*');
-- Q19 task=count filter=regexp freq=hi (single-char wildcard mid: c.che -> cache)
SELECT count(*) FROM otel_logs WHERE body ~* '\yc.che\y';
-- Q20 task=count filter=prefix freq=mid (conn)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'conn:*');
-- Q21 task=count filter=prefix freq=hi (charg)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'charg:*');
-- Q22 task=count filter=fuzzy freq=mid (levenshtein distance 1)
SELECT count(*) FROM otel_logs WHERE EXISTS (SELECT 1 FROM unnest(regexp_split_to_array(lower(body), '[^a-z0-9]+')) t WHERE levenshtein(t, 'connection') <= 1);
-- Q23 task=count filter=fuzzy freq=mid (levenshtein distance 2)
SELECT count(*) FROM otel_logs WHERE EXISTS (SELECT 1 FROM unnest(regexp_split_to_array(lower(body), '[^a-z0-9]+')) t WHERE levenshtein(t, 'connection') <= 2);
-- Q24 task=count filter=fuzzy,prefix freq=mid (levenshtein-2 AND prefix, same 'conn' root)
SELECT count(*) FROM otel_logs WHERE EXISTS (SELECT 1 FROM unnest(regexp_split_to_array(lower(body), '[^a-z0-9]+')) t WHERE levenshtein(t, 'connection') <= 2) AND to_tsvector('simple', body) @@ to_tsquery('simple', 'conn:*');
-- Q25 task=count filter=like freq=mid (prefix wildcard conn%)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'conn:*');
-- Q26 task=count filter=like freq=hi (suffix wildcard %tion)
SELECT count(*) FROM otel_logs WHERE body ~* '[a-z0-9]tion\y';
-- Q27 task=count filter=like freq=mid (middle wildcard %nnec%)
SELECT count(*) FROM otel_logs WHERE body ~* 'nnec';
-- Q28 task=count filter=and,negation freq=hi (error but NOT cache)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error & !cache');
-- Q29 task=count filter=or,negation freq=hi (error/failed, excluding charge)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', '(error | failed) & !charge');
-- Q30 task=count filter=term,window freq=hi (term + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00';
-- Q31 task=count filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs WHERE service_name = 'frontend' AND to_tsvector('simple', body) @@ to_tsquery('simple', 'failed') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00';
-- Q32 task=count filter=or,window freq=mid (8-token OR within a BETWEEN 6h window)
SELECT count(*) FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'payment | exception | refused | send | confirmation | email | expected | deadline') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00';

-- ============================ TOP-K (ts_rank_cd DESC, LIMIT 100) ============================
-- Q33 task=top_k filter=term freq=hi
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'charge')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'charge') ORDER BY score DESC LIMIT 100;
-- Q34 task=top_k filter=term freq=mid
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'connection')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'connection') ORDER BY score DESC LIMIT 100;
-- Q35 task=top_k filter=term freq=lo
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'payment')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'payment') ORDER BY score DESC LIMIT 100;
-- Q36 task=top_k filter=and freq=hi (AND, 2 tokens)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'failed & order')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & order') ORDER BY score DESC LIMIT 100;
-- Q37 task=top_k filter=and freq=hi (AND, 4 tokens)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'failed & charge & card & cache')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & charge & card & cache') ORDER BY score DESC LIMIT 100;
-- Q38 task=top_k filter=and freq=lo (AND, 8 tokens)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'failed & send & order & confirmation & email & service & expected & post')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & send & order & confirmation & email & service & expected & post') ORDER BY score DESC LIMIT 100;
-- Q39 task=top_k filter=or freq=hi (OR, 2 tokens)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'error | failed')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error | failed') ORDER BY score DESC LIMIT 100;
-- Q40 task=top_k filter=or freq=hi (OR, 4 tokens)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'connection | request | conversion | post')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'connection | request | conversion | post') ORDER BY score DESC LIMIT 100;
-- Q41 task=top_k filter=or freq=mid (OR, 8 tokens)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'payment | exception | refused | send | confirmation | email | expected | deadline')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'payment | exception | refused | send | confirmation | email | expected | deadline') ORDER BY score DESC LIMIT 100;
-- Q42 task=top_k filter=or,minmatch freq=hi (>=2 of 4)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', '(error&failed)|(error&charge)|(error&cache)|(failed&charge)|(failed&cache)|(charge&cache)')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', '(error&failed)|(error&charge)|(error&cache)|(failed&charge)|(failed&cache)|(charge&cache)') ORDER BY score DESC LIMIT 100;
-- Q43 task=top_k filter=phrase freq=mid (phrase, 2 tokens)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), phraseto_tsquery('simple', 'place order')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'place order') ORDER BY score DESC LIMIT 100;
-- Q44 task=top_k filter=phrase freq=mid (phrase, 4 tokens)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), phraseto_tsquery('simple', 'failed to place order')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'failed to place order') ORDER BY score DESC LIMIT 100;
-- Q45 task=top_k filter=phrase freq=lo (phrase, 8 tokens)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), phraseto_tsquery('simple', 'post to email service expected 200 got 500')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'post to email service expected 200 got 500') ORDER BY score DESC LIMIT 100;
-- Q46 task=top_k filter=regexp freq=mid (conn.*)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'conn:*')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'conn:*') ORDER BY score DESC LIMIT 100;
-- Q47 task=top_k filter=prefix freq=hi (charg)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'charg:*')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'charg:*') ORDER BY score DESC LIMIT 100;
-- Q48 task=top_k filter=fuzzy freq=mid (levenshtein distance 1)
SELECT timestamp, service_name, body FROM otel_logs WHERE EXISTS (SELECT 1 FROM unnest(regexp_split_to_array(lower(body), '[^a-z0-9]+')) t WHERE levenshtein(t, 'connection') <= 1) ORDER BY timestamp DESC LIMIT 100;
-- Q49 task=top_k filter=fuzzy freq=mid (levenshtein distance 2)
SELECT timestamp, service_name, body FROM otel_logs WHERE EXISTS (SELECT 1 FROM unnest(regexp_split_to_array(lower(body), '[^a-z0-9]+')) t WHERE levenshtein(t, 'connection') <= 2) ORDER BY timestamp DESC LIMIT 100;
-- Q50 task=top_k filter=like freq=mid (prefix wildcard conn%)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'conn:*')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'conn:*') ORDER BY score DESC LIMIT 100;
-- Q51 task=top_k filter=phrase,or freq=hi (phrase OR term)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), phraseto_tsquery('simple', 'failed to place order') || to_tsquery('simple', 'charge')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'failed to place order') OR to_tsvector('simple', body) @@ to_tsquery('simple', 'charge') ORDER BY score DESC LIMIT 100;
-- Q52 task=top_k filter=and,negation freq=hi (error but NOT cache)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'error & !cache')) AS score FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error & !cache') ORDER BY score DESC LIMIT 100;
-- Q53 task=top_k filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT timestamp, service_name, body, ts_rank_cd(to_tsvector('simple', body), to_tsquery('simple', 'charge')) AS score FROM otel_logs WHERE service_name = 'payment' AND to_tsvector('simple', body) @@ to_tsquery('simple', 'charge') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY score DESC LIMIT 100;

-- ============================ GROUP BY ============================
-- Q54 task=group_by filter=or freq=hi (key=SeverityText, ordered)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error | failed') GROUP BY severity_text ORDER BY cnt DESC;
-- Q55 task=group_by filter=term freq=hi (key=SeverityText, ordered)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'charge') GROUP BY severity_text ORDER BY cnt DESC;
-- Q56 task=group_by filter=and freq=hi (key=SeverityText, NO order by)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & order') GROUP BY severity_text;
-- Q57 task=group_by filter=or freq=hi (key=ScopeName, top 20 ordered)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error | failed') GROUP BY scope_name ORDER BY cnt DESC LIMIT 20;
-- Q58 task=group_by filter=regexp freq=hi (key=ScopeName)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'charg:*') GROUP BY scope_name ORDER BY cnt DESC LIMIT 20;
-- Q59 task=group_by filter=fuzzy freq=mid (key=ScopeName)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE EXISTS (SELECT 1 FROM unnest(regexp_split_to_array(lower(body), '[^a-z0-9]+')) t WHERE levenshtein(t, 'connection') <= 1) GROUP BY scope_name ORDER BY cnt DESC LIMIT 20;
-- Q60 task=group_by filter=or freq=hi (key=ScopeName, NO order by)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error | failed') GROUP BY scope_name;
-- Q61 task=group_by filter=term freq=hi (key=minute)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error') GROUP BY minute ORDER BY minute;
-- Q62 task=group_by filter=and freq=hi (key=minute)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & order') GROUP BY minute ORDER BY minute;
-- Q63 task=group_by filter=phrase freq=mid (key=minute)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'failed to place order') GROUP BY minute ORDER BY minute;
-- Q64 task=group_by filter=or freq=hi (key=minute)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error | failed | charge') GROUP BY minute ORDER BY minute;
-- Q65 task=group_by filter=term freq=hi (key=minute, NO order by)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error') GROUP BY minute;
-- Q66 task=group_by filter=and freq=hi (key=SeverityText, Body term + indexed service)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE service_name = 'frontend' AND to_tsvector('simple', body) @@ to_tsquery('simple', 'failed') GROUP BY severity_text ORDER BY cnt DESC;
-- Q67 task=group_by filter=or freq=hi (two keys: SeverityText, ScopeName)
SELECT severity_text, scope_name, count(*) AS cnt FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error | failed') GROUP BY severity_text, scope_name ORDER BY cnt DESC LIMIT 20;

-- ============================ RECENT (Timestamp BETWEEN window + ORDER BY Timestamp DESC LIMIT 100) ============================
-- Q68 task=recent filter=and,window freq=hi (recent failed-order logs from checkout)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'checkout' AND to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & order') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- Q69 task=recent filter=or,window freq=hi (recent error/failed/charge, severity>=warn)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error | failed | charge') AND severity_number >= 13 AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- Q70 task=recent filter=term,window freq=hi (recent error logs in a 6h window)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY timestamp DESC LIMIT 100;
-- Q71 task=recent filter=phrase,window freq=mid (recent 'failed to place order')
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'failed to place order') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY timestamp DESC LIMIT 100;
-- Q72 task=recent filter=and,window freq=hi (recent payment charges)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'payment' AND to_tsvector('simple', body) @@ to_tsquery('simple', 'charge') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- Q73 task=recent filter=window (pure time-series tail: recent cart logs, no text search)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'cart' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- Q74 task=recent filter=regexp,window freq=hi (recent charg* logs in a 6h window)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'charg:*') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY timestamp DESC LIMIT 100;
-- Q75 task=recent filter=or,window freq=mid (recent connection/request/conversion logs)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'connection | request | conversion') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- ---- RECENT without ORDER BY (windowed filter + LIMIT only; mirrors Q68-Q75, no sort) ----
-- Q76 task=recent filter=and,window freq=hi (checkout failed&order, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'checkout' AND to_tsvector('simple', body) @@ to_tsquery('simple', 'failed & order') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q77 task=recent filter=or,window freq=hi (error/failed/charge sev>=warn, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error | failed | charge') AND severity_number >= 13 AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q78 task=recent filter=term,window freq=hi (error 6h, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'error') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' LIMIT 100;
-- Q79 task=recent filter=phrase,window freq=mid (failed to place order 6h, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ phraseto_tsquery('simple', 'failed to place order') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' LIMIT 100;
-- Q80 task=recent filter=and,window freq=hi (payment charges, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'payment' AND to_tsvector('simple', body) @@ to_tsquery('simple', 'charge') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q81 task=recent filter=window (cart tail, NO order by, no text search)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'cart' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q82 task=recent filter=regexp,window freq=hi (charg.* 6h, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'charg:*') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' LIMIT 100;
-- Q83 task=recent filter=or,window freq=mid (connection/request/conversion, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE to_tsvector('simple', body) @@ to_tsquery('simple', 'connection | request | conversion') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;

-- ============================ JOIN (self-join on TraceId; count(DISTINCT a.TraceId); TraceId<>'' drops the empty bucket) ============================
-- Q84 task=join filter=term freq=hi (frontend 'failed' traces that also involve payment)
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND a.service_name = 'frontend' AND to_tsvector('simple', a.body) @@ to_tsquery('simple', 'failed') AND b.service_name = 'payment';
-- Q85 task=join filter=or freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND to_tsvector('simple', a.body) @@ to_tsquery('simple', 'error | failed') AND b.service_name = 'payment';
-- Q86 task=join filter=phrase freq=mid
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND to_tsvector('simple', a.body) @@ phraseto_tsquery('simple', 'failed to place order') AND b.service_name = 'payment';
-- Q87 task=join filter=regexp freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND to_tsvector('simple', a.body) @@ to_tsquery('simple', 'charg:*') AND b.service_name = 'frontend';
-- Q88 task=join filter=and freq=hi (failed&order traces that also involve cart)
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND to_tsvector('simple', a.body) @@ to_tsquery('simple', 'failed & order') AND b.service_name = 'cart';
-- Q89 task=join filter=or freq=mid
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND to_tsvector('simple', a.body) @@ to_tsquery('simple', 'connection | request') AND b.service_name = 'frontend';
-- Q90 task=join filter=and freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND to_tsvector('simple', a.body) @@ to_tsquery('simple', 'charge & request') AND b.service_name = 'frontend';
-- Q91 task=join filter=term freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND to_tsvector('simple', a.body) @@ to_tsquery('simple', 'order') AND b.service_name = 'payment';
-- Q92 task=join filter=prefix freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND to_tsvector('simple', a.body) @@ to_tsquery('simple', 'charg:*') AND b.service_name = 'frontend';
