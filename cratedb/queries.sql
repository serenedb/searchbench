-- CrateDB tagged workload over otel_logs -- 92 queries mirroring
-- serenedb/queries.sql Q01-Q92 one-for-one. Generated from
-- elastic/queries.dsl (Q01-Q83) and postgres/queries.sql (Q84-Q92 joins)
-- by cratedb/translate.py; see that file for the semantics.

-- Q01 task=count filter=term freq=hi
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'error');
-- Q02 task=count filter=term freq=lo
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'payment');
-- Q03 task=count filter=and freq=hi (AND, 2 tokens)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'failed order') USING best_fields WITH (operator='and');
-- Q04 task=count filter=and freq=hi (AND, 4 tokens)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'failed charge card cache') USING best_fields WITH (operator='and');
-- Q05 task=count filter=and freq=lo (AND, 8 tokens)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'failed send order confirmation email service expected post') USING best_fields WITH (operator='and');
-- Q06 task=count filter=or freq=hi (OR, 2 tokens)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'error failed');
-- Q07 task=count filter=or freq=hi (OR, 4 tokens)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'connection request conversion post');
-- Q08 task=count filter=or freq=mid (OR, 8 tokens)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'payment exception refused send confirmation email expected deadline');
-- Q09 task=count filter=or,minmatch freq=hi (>=2 of 4)
SELECT count(*) FROM otel_logs WHERE ((MATCH(body_ft, 'error') AND MATCH(body_ft, 'failed')) OR (MATCH(body_ft, 'error') AND MATCH(body_ft, 'charge')) OR (MATCH(body_ft, 'error') AND MATCH(body_ft, 'cache')) OR (MATCH(body_ft, 'failed') AND MATCH(body_ft, 'charge')) OR (MATCH(body_ft, 'failed') AND MATCH(body_ft, 'cache')) OR (MATCH(body_ft, 'charge') AND MATCH(body_ft, 'cache')));
-- Q10 task=count filter=phrase freq=mid (phrase, 2 tokens)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'place order') USING phrase;
-- Q11 task=count filter=phrase freq=mid (phrase, 4 tokens)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'failed to place order') USING phrase;
-- Q12 task=count filter=phrase freq=lo (phrase, 8 tokens)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'post to email service expected 200 got 500') USING phrase;
-- Q13 task=count filter=phrase,proximity freq=hi (failed within 2 of order)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'failed order') USING phrase WITH (slop=2);
-- Q14 task=count filter=phrase,or freq=hi (phrase OR term)
SELECT count(*) FROM otel_logs WHERE (MATCH(body_ft, 'failed to place order') USING phrase OR MATCH(body_ft, 'charge'));
-- Q15 task=count filter=phrase,and freq=mid (phrase AND term)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'failed to place order') USING phrase AND MATCH(body_ft, 'charge');
-- Q16 task=count filter=regexp freq=hi (charg.*)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'charg') USING phrase_prefix WITH (max_expansions = 50000);
-- Q17 task=count filter=regexp freq=hi (ord.*)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'ord') USING phrase_prefix WITH (max_expansions = 50000);
-- Q18 task=count filter=regexp freq=mid (conn.*)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'conn') USING phrase_prefix WITH (max_expansions = 50000);
-- Q19 task=count filter=regexp freq=hi (single-char wildcard mid: c.che -> cache)
SELECT count(*) FROM otel_logs WHERE body ~ '(?i).*(?<![a-z0-9])c.che(?![a-z0-9]).*';
-- Q20 task=count filter=prefix freq=mid (conn)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'conn') USING phrase_prefix WITH (max_expansions = 50000);
-- Q21 task=count filter=prefix freq=hi (charg)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'charg') USING phrase_prefix WITH (max_expansions = 50000);
-- Q22 task=count filter=fuzzy freq=mid (levenshtein distance 1)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'connection') USING best_fields WITH (fuzziness=1);
-- Q23 task=count filter=fuzzy freq=mid (levenshtein distance 2)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'connection') USING best_fields WITH (fuzziness=2);
-- Q24 task=count filter=fuzzy,prefix freq=mid (levenshtein-2 AND prefix, same 'conn' root)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'connection') USING best_fields WITH (fuzziness=2) AND MATCH(body_ft, 'conn') USING phrase_prefix WITH (max_expansions = 50000);
-- Q25 task=count filter=like freq=mid (prefix wildcard conn%)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'conn') USING phrase_prefix WITH (max_expansions = 50000);
-- Q26 task=count filter=like freq=hi (suffix wildcard %tion)
SELECT count(*) FROM otel_logs WHERE body ~ '(?i).*(?<![a-z0-9])[a-z0-9]*tion(?![a-z0-9]).*';
-- Q27 task=count filter=like freq=mid (middle wildcard %nnec%)
SELECT count(*) FROM otel_logs WHERE body LIKE '%nnec%';
-- Q28 task=count filter=and,negation freq=hi (error but NOT cache)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'error') AND NOT (MATCH(body_ft, 'cache'));
-- Q29 task=count filter=or,negation freq=hi (error/failed, excluding charge)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'error failed') AND NOT (MATCH(body_ft, 'charge'));
-- Q30 task=count filter=term,window freq=hi (term + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'error') AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00';
-- Q31 task=count filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'failed') AND service_name = 'frontend' AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00';
-- Q32 task=count filter=or,window freq=mid (8-token OR within a BETWEEN 6h window)
SELECT count(*) FROM otel_logs WHERE MATCH(body_ft, 'payment exception refused send confirmation email expected deadline') AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00';
-- Q33 task=top_k filter=term freq=hi
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'charge') ORDER BY _score DESC LIMIT 100;
-- Q34 task=top_k filter=term freq=mid
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'connection') ORDER BY _score DESC LIMIT 100;
-- Q35 task=top_k filter=term freq=lo
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'payment') ORDER BY _score DESC LIMIT 100;
-- Q36 task=top_k filter=and freq=hi (AND, 2 tokens)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'failed order') USING best_fields WITH (operator='and') ORDER BY _score DESC LIMIT 100;
-- Q37 task=top_k filter=and freq=hi (AND, 4 tokens)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'failed charge card cache') USING best_fields WITH (operator='and') ORDER BY _score DESC LIMIT 100;
-- Q38 task=top_k filter=and freq=lo (AND, 8 tokens)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'failed send order confirmation email service expected post') USING best_fields WITH (operator='and') ORDER BY _score DESC LIMIT 100;
-- Q39 task=top_k filter=or freq=hi (OR, 2 tokens)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'error failed') ORDER BY _score DESC LIMIT 100;
-- Q40 task=top_k filter=or freq=hi (OR, 4 tokens)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'connection request conversion post') ORDER BY _score DESC LIMIT 100;
-- Q41 task=top_k filter=or freq=mid (OR, 8 tokens)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'payment exception refused send confirmation email expected deadline') ORDER BY _score DESC LIMIT 100;
-- Q42 task=top_k filter=or,minmatch freq=hi (>=2 of 4)
SELECT ts, service_name, body, _score FROM otel_logs WHERE ((MATCH(body_ft, 'error') AND MATCH(body_ft, 'failed')) OR (MATCH(body_ft, 'error') AND MATCH(body_ft, 'charge')) OR (MATCH(body_ft, 'error') AND MATCH(body_ft, 'cache')) OR (MATCH(body_ft, 'failed') AND MATCH(body_ft, 'charge')) OR (MATCH(body_ft, 'failed') AND MATCH(body_ft, 'cache')) OR (MATCH(body_ft, 'charge') AND MATCH(body_ft, 'cache'))) ORDER BY _score DESC LIMIT 100;
-- Q43 task=top_k filter=phrase freq=mid (phrase, 2 tokens)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'place order') USING phrase ORDER BY _score DESC LIMIT 100;
-- Q44 task=top_k filter=phrase freq=mid (phrase, 4 tokens)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'failed to place order') USING phrase ORDER BY _score DESC LIMIT 100;
-- Q45 task=top_k filter=phrase freq=lo (phrase, 8 tokens)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'post to email service expected 200 got 500') USING phrase ORDER BY _score DESC LIMIT 100;
-- Q46 task=top_k filter=regexp freq=mid (conn.*)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'conn') USING phrase_prefix WITH (max_expansions = 50000) ORDER BY _score DESC LIMIT 100;
-- Q47 task=top_k filter=prefix freq=hi (charg)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'charg') USING phrase_prefix WITH (max_expansions = 50000) ORDER BY _score DESC LIMIT 100;
-- Q48 task=top_k filter=fuzzy freq=mid (levenshtein distance 1)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'connection') USING best_fields WITH (fuzziness=1) ORDER BY _score DESC LIMIT 100;
-- Q49 task=top_k filter=fuzzy freq=mid (levenshtein distance 2)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'connection') USING best_fields WITH (fuzziness=2) ORDER BY _score DESC LIMIT 100;
-- Q50 task=top_k filter=like freq=mid (prefix wildcard conn%)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'conn') USING phrase_prefix WITH (max_expansions = 50000) ORDER BY _score DESC LIMIT 100;
-- Q51 task=top_k filter=phrase,or freq=hi (phrase OR term)
SELECT ts, service_name, body, _score FROM otel_logs WHERE (MATCH(body_ft, 'failed to place order') USING phrase OR MATCH(body_ft, 'charge')) ORDER BY _score DESC LIMIT 100;
-- Q52 task=top_k filter=and,negation freq=hi (error but NOT cache)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'error') AND NOT (MATCH(body_ft, 'cache')) ORDER BY _score DESC LIMIT 100;
-- Q53 task=top_k filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT ts, service_name, body, _score FROM otel_logs WHERE MATCH(body_ft, 'charge') AND service_name = 'payment' AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00' ORDER BY _score DESC LIMIT 100;
-- Q54 task=group_by filter=or freq=hi (key=SeverityText, ordered)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'error failed') GROUP BY severity_text ORDER BY cnt DESC LIMIT 100;
-- Q55 task=group_by filter=term freq=hi (key=SeverityText, ordered)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'charge') GROUP BY severity_text ORDER BY cnt DESC LIMIT 100;
-- Q56 task=group_by filter=and freq=hi (key=SeverityText, NO order by)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'failed order') USING best_fields WITH (operator='and') GROUP BY severity_text ORDER BY cnt DESC LIMIT 100;
-- Q57 task=group_by filter=or freq=hi (key=ScopeName, top 20 ordered)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'error failed') GROUP BY scope_name ORDER BY cnt DESC LIMIT 20;
-- Q58 task=group_by filter=regexp freq=hi (key=ScopeName)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'charg') USING phrase_prefix WITH (max_expansions = 50000) GROUP BY scope_name ORDER BY cnt DESC LIMIT 20;
-- Q59 task=group_by filter=fuzzy freq=mid (key=ScopeName)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'connection') USING best_fields WITH (fuzziness=1) GROUP BY scope_name ORDER BY cnt DESC LIMIT 20;
-- Q60 task=group_by filter=or freq=hi (key=ScopeName, NO order by)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'error failed') GROUP BY scope_name ORDER BY cnt DESC LIMIT 100;
-- Q61 task=group_by filter=term freq=hi (key=minute)
SELECT date_trunc('minute', ts) AS bucket, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'error') GROUP BY bucket ORDER BY bucket;
-- Q62 task=group_by filter=and freq=hi (key=minute)
SELECT date_trunc('minute', ts) AS bucket, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'failed order') USING best_fields WITH (operator='and') GROUP BY bucket ORDER BY bucket;
-- Q63 task=group_by filter=phrase freq=mid (key=minute)
SELECT date_trunc('minute', ts) AS bucket, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'failed to place order') USING phrase GROUP BY bucket ORDER BY bucket;
-- Q64 task=group_by filter=or freq=hi (key=minute)
SELECT date_trunc('minute', ts) AS bucket, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'error failed charge') GROUP BY bucket ORDER BY bucket;
-- Q65 task=group_by filter=term freq=hi (key=minute, NO order by)
SELECT date_trunc('minute', ts) AS bucket, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'error') GROUP BY bucket ORDER BY bucket;
-- Q66 task=group_by filter=and freq=hi (key=SeverityText, Body term + indexed service)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'failed') AND service_name = 'frontend' GROUP BY severity_text ORDER BY cnt DESC LIMIT 100;
-- Q67 task=group_by filter=or freq=hi (two keys: SeverityText, ScopeName)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE MATCH(body_ft, 'error failed') GROUP BY severity_text ORDER BY cnt DESC LIMIT 100;
-- Q68 task=recent filter=and,window freq=hi (recent failed-order logs from checkout)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'failed order') USING best_fields WITH (operator='and') AND service_name = 'checkout' AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' ORDER BY ts DESC LIMIT 100;
-- Q69 task=recent filter=or,window freq=hi (recent error/failed/charge, severity>=warn)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'error failed charge') AND severity_number >= 13 AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' ORDER BY ts DESC LIMIT 100;
-- Q70 task=recent filter=term,window freq=hi (recent error logs in a 6h window)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'error') AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00' ORDER BY ts DESC LIMIT 100;
-- Q71 task=recent filter=phrase,window freq=mid (recent 'failed to place order')
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'failed to place order') USING phrase AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00' ORDER BY ts DESC LIMIT 100;
-- Q72 task=recent filter=and,window freq=hi (recent payment charges)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'charge') AND service_name = 'payment' AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' ORDER BY ts DESC LIMIT 100;
-- Q73 task=recent filter=window (pure time-series tail: recent cart logs, no text search)
SELECT ts, service_name, body FROM otel_logs WHERE service_name = 'cart' AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' ORDER BY ts DESC LIMIT 100;
-- Q74 task=recent filter=regexp,window freq=hi (recent charg* logs in a 6h window)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'charg') USING phrase_prefix WITH (max_expansions = 50000) AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00' ORDER BY ts DESC LIMIT 100;
-- Q75 task=recent filter=or,window freq=mid (recent connection/request/conversion logs)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'connection request conversion') AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' ORDER BY ts DESC LIMIT 100;
-- Q76 task=recent filter=and,window freq=hi (checkout failed&order, NO order by)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'failed order') USING best_fields WITH (operator='and') AND service_name = 'checkout' AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' LIMIT 100;
-- Q77 task=recent filter=or,window freq=hi (error/failed/charge sev>=warn, NO order by)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'error failed charge') AND severity_number >= 13 AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' LIMIT 100;
-- Q78 task=recent filter=term,window freq=hi (error 6h, NO order by)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'error') AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00' LIMIT 100;
-- Q79 task=recent filter=phrase,window freq=mid (failed to place order 6h, NO order by)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'failed to place order') USING phrase AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00' LIMIT 100;
-- Q80 task=recent filter=and,window freq=hi (payment charges, NO order by)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'charge') AND service_name = 'payment' AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' LIMIT 100;
-- Q81 task=recent filter=window (cart tail, NO order by, no text search)
SELECT ts, service_name, body FROM otel_logs WHERE service_name = 'cart' AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' LIMIT 100;
-- Q82 task=recent filter=regexp,window freq=hi (charg.* 6h, NO order by)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'charg') USING phrase_prefix WITH (max_expansions = 50000) AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T06:00:00' LIMIT 100;
-- Q83 task=recent filter=or,window freq=mid (connection/request/conversion, NO order by)
SELECT ts, service_name, body FROM otel_logs WHERE MATCH(body_ft, 'connection request conversion') AND ts >= '2025-09-23T00:00:00' AND ts <= '2025-09-23T00:30:00' LIMIT 100;
-- Q84 task=join filter=term freq=hi (frontend 'failed' traces that also involve payment)
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND a.service_name = 'frontend' AND MATCH(a.body_ft, 'failed') AND b.service_name = 'payment';
-- Q85 task=join filter=or freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND MATCH(a.body_ft, 'error failed') AND b.service_name = 'payment';
-- Q86 task=join filter=phrase freq=mid
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND MATCH(a.body_ft, 'failed to place order') USING phrase AND b.service_name = 'payment';
-- Q87 task=join filter=regexp freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND MATCH(a.body_ft, 'charg') USING phrase_prefix WITH (max_expansions = 50000) AND b.service_name = 'frontend';
-- Q88 task=join filter=and freq=hi (failed&order traces that also involve cart)
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND MATCH(a.body_ft, 'failed order') USING best_fields WITH (operator='and') AND b.service_name = 'cart';
-- Q89 task=join filter=or freq=mid
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND MATCH(a.body_ft, 'connection request') AND b.service_name = 'frontend';
-- Q90 task=join filter=and freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND MATCH(a.body_ft, 'charge request') USING best_fields WITH (operator='and') AND b.service_name = 'frontend';
-- Q91 task=join filter=term freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND MATCH(a.body_ft, 'order') AND b.service_name = 'payment';
-- Q92 task=join filter=prefix freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND MATCH(a.body_ft, 'charg') USING phrase_prefix WITH (max_expansions = 50000) AND b.service_name = 'frontend';
