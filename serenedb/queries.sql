-- Q01 task=count filter=term freq=hi
SELECT count(*) FROM otel_logs_idx WHERE Body @@ 'error';
-- Q02 task=count filter=term freq=lo
SELECT count(*) FROM otel_logs_idx WHERE Body @@ 'payment';
-- Q03 task=count filter=and freq=hi (AND, 2 tokens)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_all(['failed', 'order']);
-- Q04 task=count filter=and freq=hi (AND, 4 tokens)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_all(['failed', 'charge', 'card', 'cache']);
-- Q05 task=count filter=and freq=lo (AND, 8 tokens)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_all(['failed', 'send', 'order', 'confirmation', 'email', 'service', 'expected', 'post']);
-- Q06 task=count filter=or freq=hi (OR, 2 tokens)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed']);
-- Q07 task=count filter=or freq=hi (OR, 4 tokens)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_any(['connection', 'request', 'conversion', 'post']);
-- Q08 task=count filter=or freq=mid (OR, 8 tokens)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_any(['payment', 'exception', 'refused', 'send', 'confirmation', 'email', 'expected', 'deadline']);
-- Q09 task=count filter=or,minmatch freq=hi (>=2 of 4)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed', 'charge', 'cache'], 2);
-- Q10 task=count filter=phrase freq=mid (phrase, 2 tokens)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_phrase('place', 'order');
-- Q11 task=count filter=phrase freq=mid (phrase, 4 tokens)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_phrase('failed', 'to', 'place', 'order');
-- Q12 task=count filter=phrase freq=lo (phrase, 8 tokens)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_phrase('post', 'to', 'email', 'service', 'expected', '200', 'got', '500');
-- Q13 task=count filter=phrase,proximity freq=hi (failed within 2 of order)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ (ts_phrase('failed') ## 2 ## 'order');
-- Q14 task=count filter=phrase,or freq=hi (phrase OR term)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_phrase('failed', 'to', 'place', 'order') OR Body @@ 'charge';
-- Q15 task=count filter=phrase,and freq=mid (phrase AND term)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_phrase('failed', 'to', 'place', 'order') AND Body @@ 'charge';
-- Q16 task=count filter=regexp freq=hi (charg.*)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_regexp('charg.*');
-- Q17 task=count filter=regexp freq=hi (ord.*)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_regexp('ord.*');
-- Q18 task=count filter=regexp freq=mid (conn.*)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_regexp('conn.*');
-- Q19 task=count filter=regexp freq=hi (single-char wildcard mid: c.che -> cache)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_regexp('c.che');
-- Q20 task=count filter=prefix freq=mid (conn)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_starts_with('conn');
-- Q21 task=count filter=prefix freq=hi (charg)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_starts_with('charg');
-- Q22 task=count filter=fuzzy freq=mid (levenshtein distance 1)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_levenshtein('connection', 1);
-- Q23 task=count filter=fuzzy freq=mid (levenshtein distance 2)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_levenshtein('connection', 2);
-- Q24 task=count filter=fuzzy,prefix freq=mid (levenshtein-2 AND prefix, same 'conn' root)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_levenshtein('connection', 2) AND Body @@ ts_starts_with('conn');
-- Q25 task=count filter=like freq=mid (prefix wildcard conn%)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_like('conn%');
-- Q26 task=count filter=like freq=hi (suffix wildcard %tion)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_like('%tion');
-- Q27 task=count filter=like freq=mid (middle wildcard %nnec%)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_like('%nnec%');
-- Q28 task=count filter=and,negation freq=hi (error but NOT cache)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ 'error' AND NOT Body @@ 'cache';
-- Q29 task=count filter=or,negation freq=hi (error/failed, excluding charge)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed']) AND NOT Body @@ 'charge';
-- Q30 task=count filter=term,window freq=hi (term + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ 'error' AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00';
-- Q31 task=count filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs_idx WHERE ServiceName = 'frontend' AND Body @@ 'failed' AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00';
-- Q32 task=count filter=or,window freq=mid (8-token OR within a BETWEEN 6h window)
SELECT count(*) FROM otel_logs_idx WHERE Body @@ ts_any(['payment', 'exception', 'refused', 'send', 'confirmation', 'email', 'expected', 'deadline']) AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00';

-- Q33 task=top_k filter=term freq=hi
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ 'charge' ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q34 task=top_k filter=term freq=mid
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ 'connection' ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q35 task=top_k filter=term freq=lo
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ 'payment' ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q36 task=top_k filter=and freq=hi (AND, 2 tokens)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_all(['failed', 'order']) ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q37 task=top_k filter=and freq=hi (AND, 4 tokens)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_all(['failed', 'charge', 'card', 'cache']) ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q38 task=top_k filter=and freq=lo (AND, 8 tokens)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_all(['failed', 'send', 'order', 'confirmation', 'email', 'service', 'expected', 'post']) ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q39 task=top_k filter=or freq=hi (OR, 2 tokens)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed']) ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q40 task=top_k filter=or freq=hi (OR, 4 tokens)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_any(['connection', 'request', 'conversion', 'post']) ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q41 task=top_k filter=or freq=mid (OR, 8 tokens)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_any(['payment', 'exception', 'refused', 'send', 'confirmation', 'email', 'expected', 'deadline']) ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q42 task=top_k filter=or,minmatch freq=hi (>=2 of 4)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed', 'charge', 'cache'], 2) ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q43 task=top_k filter=phrase freq=mid (phrase, 2 tokens)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_phrase('place', 'order') ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q44 task=top_k filter=phrase freq=mid (phrase, 4 tokens)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_phrase('failed', 'to', 'place', 'order') ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q45 task=top_k filter=phrase freq=lo (phrase, 8 tokens)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_phrase('post', 'to', 'email', 'service', 'expected', '200', 'got', '500') ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q46 task=top_k filter=regexp freq=mid (conn.*)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_regexp('conn.*') ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q47 task=top_k filter=prefix freq=hi (charg)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_starts_with('charg') ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q48 task=top_k filter=fuzzy freq=mid (levenshtein distance 1)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_levenshtein('connection', 1) ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q49 task=top_k filter=fuzzy freq=mid (levenshtein distance 2)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_levenshtein('connection', 2) ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q50 task=top_k filter=like freq=mid (prefix wildcard conn%)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_like('conn%') ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q51 task=top_k filter=phrase,or freq=hi (phrase OR term)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ ts_phrase('failed', 'to', 'place', 'order') OR Body @@ 'charge' ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q52 task=top_k filter=and,negation freq=hi (error but NOT cache)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE Body @@ 'error' AND NOT Body @@ 'cache' ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;
-- Q53 task=top_k filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT Timestamp, ServiceName, Body, BM25(otel_logs_idx.tableoid) AS score FROM otel_logs_idx WHERE ServiceName = 'payment' AND Body @@ 'charge' AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY BM25(otel_logs_idx.tableoid) DESC LIMIT 100;

-- Q54 task=group_by filter=or freq=hi (key=SeverityText, ordered)
SELECT SeverityText, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed']) GROUP BY SeverityText ORDER BY cnt DESC;
-- Q55 task=group_by filter=term freq=hi (key=SeverityText, ordered)
SELECT SeverityText, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ 'charge' GROUP BY SeverityText ORDER BY cnt DESC;
-- Q56 task=group_by filter=and freq=hi (key=SeverityText, NO order by)
SELECT SeverityText, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_all(['failed', 'order']) GROUP BY SeverityText;
-- Q57 task=group_by filter=or freq=hi (key=ScopeName, top 20 ordered)
SELECT ScopeName, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed']) GROUP BY ScopeName ORDER BY cnt DESC LIMIT 20;
-- Q58 task=group_by filter=regexp freq=hi (key=ScopeName)
SELECT ScopeName, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_regexp('charg.*') GROUP BY ScopeName ORDER BY cnt DESC LIMIT 20;
-- Q59 task=group_by filter=fuzzy freq=mid (key=ScopeName)
SELECT ScopeName, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_levenshtein('connection', 1) GROUP BY ScopeName ORDER BY cnt DESC LIMIT 20;
-- Q60 task=group_by filter=or freq=hi (key=ScopeName, NO order by)
SELECT ScopeName, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed']) GROUP BY ScopeName;
-- Q61 task=group_by filter=term freq=hi (key=minute)
SELECT date_trunc('minute', Timestamp::TIMESTAMP_NS) AS minute, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ 'error' GROUP BY minute ORDER BY minute;
-- Q62 task=group_by filter=and freq=hi (key=minute)
SELECT date_trunc('minute', Timestamp::TIMESTAMP_NS) AS minute, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_all(['failed', 'order']) GROUP BY minute ORDER BY minute;
-- Q63 task=group_by filter=phrase freq=mid (key=minute)
SELECT date_trunc('minute', Timestamp::TIMESTAMP_NS) AS minute, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_phrase('failed', 'to', 'place', 'order') GROUP BY minute ORDER BY minute;
-- Q64 task=group_by filter=or freq=hi (key=minute)
SELECT date_trunc('minute', Timestamp::TIMESTAMP_NS) AS minute, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed', 'charge']) GROUP BY minute ORDER BY minute;
-- Q65 task=group_by filter=term freq=hi (key=minute, NO order by)
SELECT date_trunc('minute', Timestamp::TIMESTAMP_NS) AS minute, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ 'error' GROUP BY minute;
-- Q66 task=group_by filter=and freq=hi (key=SeverityText, Body term + indexed service)
SELECT SeverityText, count(*) AS cnt FROM otel_logs_idx WHERE ServiceName = 'frontend' AND Body @@ 'failed' GROUP BY SeverityText ORDER BY cnt DESC;
-- Q67 task=group_by filter=or freq=hi (two keys: SeverityText, ScopeName)
SELECT SeverityText, ScopeName, count(*) AS cnt FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed']) GROUP BY SeverityText, ScopeName ORDER BY cnt DESC LIMIT 20;

-- Q68 task=recent filter=and,window freq=hi (recent failed-order logs from checkout)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE ServiceName = 'checkout' AND Body @@ ts_all(['failed', 'order']) AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q69 task=recent filter=or,window freq=hi (recent error/failed/charge, severity>=warn)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed', 'charge']) AND SeverityNumber >= 13 AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q70 task=recent filter=term,window freq=hi (recent error logs in a 6h window)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ 'error' AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q71 task=recent filter=phrase,window freq=mid (recent 'failed to place order')
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ ts_phrase('failed', 'to', 'place', 'order') AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q72 task=recent filter=and,window freq=hi (recent payment charges)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE ServiceName = 'payment' AND Body @@ 'charge' AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q73 task=recent filter=window (pure time-series tail: recent cart logs, no text search)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE ServiceName = 'cart' AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q74 task=recent filter=regexp,window freq=hi (recent charg* logs in a 6h window)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ ts_regexp('charg.*') AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q75 task=recent filter=or,window freq=mid (recent connection/request/conversion logs)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ ts_any(['connection', 'request', 'conversion']) AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q76 task=recent filter=and,window freq=hi (checkout failed&order, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE ServiceName = 'checkout' AND Body @@ ts_all(['failed', 'order']) AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q77 task=recent filter=or,window freq=hi (error/failed/charge sev>=warn, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ ts_any(['error', 'failed', 'charge']) AND SeverityNumber >= 13 AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q78 task=recent filter=term,window freq=hi (error 6h, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ 'error' AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' LIMIT 100;
-- Q79 task=recent filter=phrase,window freq=mid (failed to place order 6h, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ ts_phrase('failed', 'to', 'place', 'order') AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' LIMIT 100;
-- Q80 task=recent filter=and,window freq=hi (payment charges, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE ServiceName = 'payment' AND Body @@ 'charge' AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q81 task=recent filter=window (cart tail, NO order by, no text search)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE ServiceName = 'cart' AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;
-- Q82 task=recent filter=regexp,window freq=hi (charg.* 6h, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ ts_regexp('charg.*') AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 06:00:00' LIMIT 100;
-- Q83 task=recent filter=or,window freq=mid (connection/request/conversion, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs_idx WHERE Body @@ ts_any(['connection', 'request', 'conversion']) AND Timestamp BETWEEN TIMESTAMP '2025-09-23 00:00:00' AND TIMESTAMP '2025-09-23 00:30:00' LIMIT 100;

-- Joins: TraceId <> '' drops the empty bucket. Deduped before the join, not
-- after: DISTINCT then EXISTS plans as HASH_GROUP_BY -> RIGHT_SEMI HASH_JOIN,
-- where count(DISTINCT a.TraceId) over the inner join materialises every
-- matching pair first.
-- Q84 task=join filter=term freq=hi (frontend 'failed' traces that also involve payment)
SELECT count(*) FROM (SELECT DISTINCT TraceId FROM otel_logs_idx WHERE TraceId <> '' AND ServiceName = 'frontend' AND Body @@ 'failed') a WHERE EXISTS (SELECT 1 FROM otel_logs_idx b WHERE b.TraceId = a.TraceId AND b.ServiceName = 'payment');
-- Q85 task=join filter=or freq=hi
SELECT count(*) FROM (SELECT DISTINCT TraceId FROM otel_logs_idx WHERE TraceId <> '' AND Body @@ ts_any(['error', 'failed'])) a WHERE EXISTS (SELECT 1 FROM otel_logs_idx b WHERE b.TraceId = a.TraceId AND b.ServiceName = 'payment');
-- Q86 task=join filter=phrase freq=mid
SELECT count(*) FROM (SELECT DISTINCT TraceId FROM otel_logs_idx WHERE TraceId <> '' AND Body @@ ts_phrase('failed', 'to', 'place', 'order')) a WHERE EXISTS (SELECT 1 FROM otel_logs_idx b WHERE b.TraceId = a.TraceId AND b.ServiceName = 'payment');
-- Q87 task=join filter=regexp freq=hi
SELECT count(*) FROM (SELECT DISTINCT TraceId FROM otel_logs_idx WHERE TraceId <> '' AND Body @@ ts_regexp('charg.*')) a WHERE EXISTS (SELECT 1 FROM otel_logs_idx b WHERE b.TraceId = a.TraceId AND b.ServiceName = 'frontend');
-- Q88 task=join filter=and freq=hi (failed&order traces that also involve cart)
SELECT count(*) FROM (SELECT DISTINCT TraceId FROM otel_logs_idx WHERE TraceId <> '' AND Body @@ ts_all(['failed', 'order'])) a WHERE EXISTS (SELECT 1 FROM otel_logs_idx b WHERE b.TraceId = a.TraceId AND b.ServiceName = 'cart');
-- Q89 task=join filter=or freq=mid
SELECT count(*) FROM (SELECT DISTINCT TraceId FROM otel_logs_idx WHERE TraceId <> '' AND Body @@ ts_any(['connection', 'request'])) a WHERE EXISTS (SELECT 1 FROM otel_logs_idx b WHERE b.TraceId = a.TraceId AND b.ServiceName = 'frontend');
-- Q90 task=join filter=and freq=hi
SELECT count(*) FROM (SELECT DISTINCT TraceId FROM otel_logs_idx WHERE TraceId <> '' AND Body @@ ts_all(['charge', 'request'])) a WHERE EXISTS (SELECT 1 FROM otel_logs_idx b WHERE b.TraceId = a.TraceId AND b.ServiceName = 'frontend');
-- Q91 task=join filter=term freq=hi
SELECT count(*) FROM (SELECT DISTINCT TraceId FROM otel_logs_idx WHERE TraceId <> '' AND Body @@ 'order') a WHERE EXISTS (SELECT 1 FROM otel_logs_idx b WHERE b.TraceId = a.TraceId AND b.ServiceName = 'payment');
-- Q92 task=join filter=prefix freq=hi
SELECT count(*) FROM (SELECT DISTINCT TraceId FROM otel_logs_idx WHERE TraceId <> '' AND Body @@ ts_starts_with('charg')) a WHERE EXISTS (SELECT 1 FROM otel_logs_idx b WHERE b.TraceId = a.TraceId AND b.ServiceName = 'frontend');
