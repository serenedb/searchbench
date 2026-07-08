-- ParadeDB (pg_search) tagged workload, aligned 1:1 with serenedb (Q01-Q92).

-- Q01 task=count filter=term freq=hi
SELECT count(*) FROM otel_logs WHERE body @@@ 'error';
-- Q02 task=count filter=term freq=lo
SELECT count(*) FROM otel_logs WHERE body @@@ 'payment';
-- Q03 task=count filter=and freq=hi (AND, 2 tokens)
SELECT count(*) FROM otel_logs WHERE body @@@ 'failed' AND body @@@ 'order';
-- Q04 task=count filter=and freq=hi (AND, 4 tokens)
SELECT count(*) FROM otel_logs WHERE body @@@ 'failed' AND body @@@ 'charge' AND body @@@ 'card' AND body @@@ 'cache';
-- Q05 task=count filter=and freq=lo (AND, 8 tokens)
SELECT count(*) FROM otel_logs WHERE body @@@ 'failed' AND body @@@ 'send' AND body @@@ 'order' AND body @@@ 'confirmation' AND body @@@ 'email' AND body @@@ 'service' AND body @@@ 'expected' AND body @@@ 'post';
-- Q06 task=count filter=or freq=hi (OR, 2 tokens)
SELECT count(*) FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed');
-- Q07 task=count filter=or freq=hi (OR, 4 tokens)
SELECT count(*) FROM otel_logs WHERE (body @@@ 'connection' OR body @@@ 'request' OR body @@@ 'conversion' OR body @@@ 'post');
-- Q08 task=count filter=or freq=mid (OR, 8 tokens)
SELECT count(*) FROM otel_logs WHERE (body @@@ 'payment' OR body @@@ 'exception' OR body @@@ 'refused' OR body @@@ 'send' OR body @@@ 'confirmation' OR body @@@ 'email' OR body @@@ 'expected' OR body @@@ 'deadline');
-- Q09 task=count filter=or,minmatch freq=hi (>=2 of 4)
SELECT count(*) FROM otel_logs WHERE ((body @@@ 'error' AND body @@@ 'failed') OR (body @@@ 'error' AND body @@@ 'charge') OR (body @@@ 'error' AND body @@@ 'cache') OR (body @@@ 'failed' AND body @@@ 'charge') OR (body @@@ 'failed' AND body @@@ 'cache') OR (body @@@ 'charge' AND body @@@ 'cache'));
-- Q10 task=count filter=phrase freq=mid (phrase, 2 tokens)
SELECT count(*) FROM otel_logs WHERE body @@@ '"place order"';
-- Q11 task=count filter=phrase freq=mid (phrase, 4 tokens)
SELECT count(*) FROM otel_logs WHERE body @@@ '"failed to place order"';
-- Q12 task=count filter=phrase freq=lo (phrase, 8 tokens)
SELECT count(*) FROM otel_logs WHERE body @@@ '"post to email service expected 200 got 500"';
-- Q13 task=count filter=phrase,proximity freq=hi (failed within 2 of order)
SELECT count(*) FROM otel_logs WHERE body @@@ '"failed order"~2';
-- Q14 task=count filter=phrase,or freq=hi (phrase OR term)
SELECT count(*) FROM otel_logs WHERE (body @@@ '"failed to place order"' OR body @@@ 'charge');
-- Q15 task=count filter=phrase,and freq=mid (phrase AND term)
SELECT count(*) FROM otel_logs WHERE body @@@ '"failed to place order"' AND body @@@ 'charge';
-- Q16 task=count filter=regexp freq=hi (charg.*)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.regex('body', 'charg.*');
-- Q17 task=count filter=regexp freq=hi (ord.*)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.regex('body', 'ord.*');
-- Q18 task=count filter=regexp freq=mid (conn.*)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.regex('body', 'conn.*');
-- Q19 task=count filter=regexp freq=hi (single-char wildcard mid: c.che -> cache)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.regex('body', 'c.che');
-- Q20 task=count filter=prefix freq=mid (conn)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.regex('body', 'conn.*');
-- Q21 task=count filter=prefix freq=hi (charg)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.regex('body', 'charg.*');
-- Q22 task=count filter=fuzzy freq=mid (levenshtein distance 1)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.fuzzy_term('body', 'connection', distance => 1);
-- Q23 task=count filter=fuzzy freq=mid (levenshtein distance 2)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.fuzzy_term('body', 'connection', distance => 2);
-- Q24 task=count filter=fuzzy,prefix freq=mid (levenshtein-2 AND prefix, same 'conn' root)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.fuzzy_term('body', 'connection', distance => 2) AND id @@@ paradedb.regex('body', 'conn.*');
-- Q25 task=count filter=like freq=mid (prefix wildcard conn%)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.regex('body', 'conn.*');
-- Q26 task=count filter=like freq=hi (suffix wildcard %tion)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.regex('body', '.*tion');
-- Q27 task=count filter=like freq=mid (middle wildcard %nnec%)
SELECT count(*) FROM otel_logs WHERE id @@@ paradedb.regex('body', '.*nnec.*');
-- Q28 task=count filter=and,negation freq=hi (error but NOT cache)
SELECT count(*) FROM otel_logs WHERE body @@@ 'error' AND NOT body @@@ 'cache';
-- Q29 task=count filter=or,negation freq=hi (error/failed, excluding charge)
SELECT count(*) FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed') AND NOT body @@@ 'charge';
-- Q30 task=count filter=term,window freq=hi (term + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs WHERE body @@@ 'error' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00';
-- Q31 task=count filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs WHERE service_name = 'frontend' AND body @@@ 'failed' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00';
-- Q32 task=count filter=or,window freq=mid (8-token OR within a BETWEEN 6h window)
SELECT count(*) FROM otel_logs WHERE (body @@@ 'payment' OR body @@@ 'exception' OR body @@@ 'refused' OR body @@@ 'send' OR body @@@ 'confirmation' OR body @@@ 'email' OR body @@@ 'expected' OR body @@@ 'deadline') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00';
-- Q33 task=top_k filter=term freq=hi
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ 'charge' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q34 task=top_k filter=term freq=mid
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ 'connection' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q35 task=top_k filter=term freq=lo
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ 'payment' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q36 task=top_k filter=and freq=hi (AND, 2 tokens)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ 'failed' AND body @@@ 'order' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q37 task=top_k filter=and freq=hi (AND, 4 tokens)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ 'failed' AND body @@@ 'charge' AND body @@@ 'card' AND body @@@ 'cache' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q38 task=top_k filter=and freq=lo (AND, 8 tokens)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ 'failed' AND body @@@ 'send' AND body @@@ 'order' AND body @@@ 'confirmation' AND body @@@ 'email' AND body @@@ 'service' AND body @@@ 'expected' AND body @@@ 'post' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q39 task=top_k filter=or freq=hi (OR, 2 tokens)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed') ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q40 task=top_k filter=or freq=hi (OR, 4 tokens)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE (body @@@ 'connection' OR body @@@ 'request' OR body @@@ 'conversion' OR body @@@ 'post') ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q41 task=top_k filter=or freq=mid (OR, 8 tokens)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE (body @@@ 'payment' OR body @@@ 'exception' OR body @@@ 'refused' OR body @@@ 'send' OR body @@@ 'confirmation' OR body @@@ 'email' OR body @@@ 'expected' OR body @@@ 'deadline') ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q42 task=top_k filter=or,minmatch freq=hi (>=2 of 4)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE ((body @@@ 'error' AND body @@@ 'failed') OR (body @@@ 'error' AND body @@@ 'charge') OR (body @@@ 'error' AND body @@@ 'cache') OR (body @@@ 'failed' AND body @@@ 'charge') OR (body @@@ 'failed' AND body @@@ 'cache') OR (body @@@ 'charge' AND body @@@ 'cache')) ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q43 task=top_k filter=phrase freq=mid (phrase, 2 tokens)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ '"place order"' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q44 task=top_k filter=phrase freq=mid (phrase, 4 tokens)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ '"failed to place order"' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q45 task=top_k filter=phrase freq=lo (phrase, 8 tokens)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ '"post to email service expected 200 got 500"' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q46 task=top_k filter=regexp freq=mid (conn.*)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE id @@@ paradedb.regex('body', 'conn.*') ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q47 task=top_k filter=prefix freq=hi (charg)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE id @@@ paradedb.regex('body', 'charg.*') ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q48 task=top_k filter=fuzzy freq=mid (levenshtein distance 1)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE id @@@ paradedb.fuzzy_term('body', 'connection', distance => 1) ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q49 task=top_k filter=fuzzy freq=mid (levenshtein distance 2)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE id @@@ paradedb.fuzzy_term('body', 'connection', distance => 2) ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q50 task=top_k filter=like freq=mid (prefix wildcard conn%)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE id @@@ paradedb.regex('body', 'conn.*') ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q51 task=top_k filter=phrase,or freq=hi (phrase OR term)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE (body @@@ '"failed to place order"' OR body @@@ 'charge') ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q52 task=top_k filter=and,negation freq=hi (error but NOT cache)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE body @@@ 'error' AND NOT body @@@ 'cache' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q53 task=top_k filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT timestamp, service_name, body, pdb.score(id) AS score FROM otel_logs WHERE service_name = 'payment' AND body @@@ 'charge' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY pdb.score(id) DESC LIMIT 100;
-- Q54 task=group_by filter=or freq=hi (key=SeverityText, ordered)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed') GROUP BY severity_text ORDER BY cnt DESC;
-- Q55 task=group_by filter=term freq=hi (key=SeverityText, ordered)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE body @@@ 'charge' GROUP BY severity_text ORDER BY cnt DESC;
-- Q56 task=group_by filter=and freq=hi (key=SeverityText, NO order by)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE body @@@ 'failed' AND body @@@ 'order' GROUP BY severity_text;
-- Q57 task=group_by filter=or freq=hi (key=ScopeName, top 20 ordered)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed') GROUP BY scope_name ORDER BY cnt DESC LIMIT 20;
-- Q58 task=group_by filter=regexp freq=hi (key=ScopeName)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE id @@@ paradedb.regex('body', 'charg.*') GROUP BY scope_name ORDER BY cnt DESC LIMIT 20;
-- Q59 task=group_by filter=fuzzy freq=mid (key=ScopeName)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE id @@@ paradedb.fuzzy_term('body', 'connection', distance => 1) GROUP BY scope_name ORDER BY cnt DESC LIMIT 20;
-- Q60 task=group_by filter=or freq=hi (key=ScopeName, NO order by)
SELECT scope_name, count(*) AS cnt FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed') GROUP BY scope_name;
-- Q61 task=group_by filter=term freq=hi (key=minute)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE body @@@ 'error' GROUP BY minute ORDER BY minute;
-- Q62 task=group_by filter=and freq=hi (key=minute)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE body @@@ 'failed' AND body @@@ 'order' GROUP BY minute ORDER BY minute;
-- Q63 task=group_by filter=phrase freq=mid (key=minute)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE body @@@ '"failed to place order"' GROUP BY minute ORDER BY minute;
-- Q64 task=group_by filter=or freq=hi (key=minute)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed' OR body @@@ 'charge') GROUP BY minute ORDER BY minute;
-- Q65 task=group_by filter=term freq=hi (key=minute, NO order by)
SELECT date_trunc('minute', timestamp) AS minute, count(*) AS cnt FROM otel_logs WHERE body @@@ 'error' GROUP BY minute;
-- Q66 task=group_by filter=and freq=hi (key=SeverityText, Body term + indexed service)
SELECT severity_text, count(*) AS cnt FROM otel_logs WHERE service_name = 'frontend' AND body @@@ 'failed' GROUP BY severity_text ORDER BY cnt DESC;
-- Q67 task=group_by filter=or freq=hi (two keys: SeverityText, ScopeName)
SELECT severity_text, scope_name, count(*) AS cnt FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed') GROUP BY severity_text, scope_name ORDER BY cnt DESC LIMIT 20;
-- Q68 task=recent filter=and,window freq=hi (recent failed-order logs from checkout)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'checkout' AND body @@@ 'failed' AND body @@@ 'order' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- Q69 task=recent filter=or,window freq=hi (recent error/failed/charge, severity>=warn)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed' OR body @@@ 'charge') AND severity_number >= 13 AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- Q70 task=recent filter=term,window freq=hi (recent error logs in a 6h window)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE body @@@ 'error' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY timestamp DESC LIMIT 100;
-- Q71 task=recent filter=phrase,window freq=mid (recent 'failed to place order')
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE body @@@ '"failed to place order"' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY timestamp DESC LIMIT 100;
-- Q72 task=recent filter=and,window freq=hi (recent payment charges)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'payment' AND body @@@ 'charge' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- Q73 task=recent filter=window (pure time-series tail: recent cart logs, no text search)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'cart' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- Q74 task=recent filter=regexp,window freq=hi (recent charg* logs in a 6h window)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE id @@@ paradedb.regex('body', 'charg.*') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY timestamp DESC LIMIT 100;
-- Q75 task=recent filter=or,window freq=mid (recent connection/request/conversion logs)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE (body @@@ 'connection' OR body @@@ 'request' OR body @@@ 'conversion') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY timestamp DESC LIMIT 100;
-- Q76 task=recent filter=and,window freq=hi (checkout failed&order, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'checkout' AND body @@@ 'failed' AND body @@@ 'order' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q77 task=recent filter=or,window freq=hi (error/failed/charge sev>=warn, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE (body @@@ 'error' OR body @@@ 'failed' OR body @@@ 'charge') AND severity_number >= 13 AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q78 task=recent filter=term,window freq=hi (error 6h, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE body @@@ 'error' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' LIMIT 100;
-- Q79 task=recent filter=phrase,window freq=mid (failed to place order 6h, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE body @@@ '"failed to place order"' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' LIMIT 100;
-- Q80 task=recent filter=and,window freq=hi (payment charges, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'payment' AND body @@@ 'charge' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q81 task=recent filter=window (cart tail, NO order by, no text search)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE service_name = 'cart' AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q82 task=recent filter=regexp,window freq=hi (charg.* 6h, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE id @@@ paradedb.regex('body', 'charg.*') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' LIMIT 100;
-- Q83 task=recent filter=or,window freq=mid (connection/request/conversion, NO order by)
SELECT timestamp, service_name, severity_text, body FROM otel_logs WHERE (body @@@ 'connection' OR body @@@ 'request' OR body @@@ 'conversion') AND timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q84 task=join filter=term freq=hi (frontend 'failed' traces that also involve payment)
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND a.service_name = 'frontend' AND a.body @@@ 'failed' AND b.service_name = 'payment';
-- Q85 task=join filter=or freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND (a.body @@@ 'error' OR a.body @@@ 'failed') AND b.service_name = 'payment';
-- Q86 task=join filter=phrase freq=mid
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND a.body @@@ '"failed to place order"' AND b.service_name = 'payment';
-- Q87 task=join filter=regexp freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND a.id @@@ paradedb.regex('body', 'charg.*') AND b.service_name = 'frontend';
-- Q88 task=join filter=and freq=hi (failed&order traces that also involve cart)
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND a.body @@@ 'failed' AND a.body @@@ 'order' AND b.service_name = 'cart';
-- Q89 task=join filter=or freq=mid
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND (a.body @@@ 'connection' OR a.body @@@ 'request') AND b.service_name = 'frontend';
-- Q90 task=join filter=and freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND a.body @@@ 'charge' AND a.body @@@ 'request' AND b.service_name = 'frontend';
-- Q91 task=join filter=term freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND a.body @@@ 'order' AND b.service_name = 'payment';
-- Q92 task=join filter=prefix freq=hi
SELECT count(DISTINCT a.trace_id) FROM otel_logs a JOIN otel_logs b ON a.trace_id = b.trace_id WHERE a.trace_id <> '' AND a.id @@@ paradedb.regex('body', 'charg.*') AND b.service_name = 'frontend';
