-- ClickHouse tagged workload, aligned 1:1 with serenedb (Q01-Q92).
-- Boolean-token index only: phrase/fuzzy/regexp/wildcard/BM25 -> UNSUPPORTED.

-- Q01 task=count filter=term freq=hi
SELECT count() FROM otel_logs WHERE hasToken(Body, 'error');
-- Q02 task=count filter=term freq=lo
SELECT count() FROM otel_logs WHERE hasToken(Body, 'payment');
-- Q03 task=count filter=and freq=hi (AND, 2 tokens)
SELECT count() FROM otel_logs WHERE hasAllTokens(Body, ['failed', 'order']);
-- Q04 task=count filter=and freq=hi (AND, 4 tokens)
SELECT count() FROM otel_logs WHERE hasAllTokens(Body, ['failed', 'charge', 'card', 'cache']);
-- Q05 task=count filter=and freq=lo (AND, 8 tokens)
SELECT count() FROM otel_logs WHERE hasAllTokens(Body, ['failed', 'send', 'order', 'confirmation', 'email', 'service', 'expected', 'post']);
-- Q06 task=count filter=or freq=hi (OR, 2 tokens)
SELECT count() FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'failed']);
-- Q07 task=count filter=or freq=hi (OR, 4 tokens)
SELECT count() FROM otel_logs WHERE hasAnyTokens(Body, ['connection', 'request', 'conversion', 'post']);
-- Q08 task=count filter=or freq=mid (OR, 8 tokens)
SELECT count() FROM otel_logs WHERE hasAnyTokens(Body, ['payment', 'exception', 'refused', 'send', 'confirmation', 'email', 'expected', 'deadline']);
-- Q09 task=count filter=or,minmatch freq=hi (>=2 of 4)
SELECT count() FROM otel_logs WHERE (hasAllTokens(Body, ['error', 'failed']) OR hasAllTokens(Body, ['error', 'charge']) OR hasAllTokens(Body, ['error', 'cache']) OR hasAllTokens(Body, ['failed', 'charge']) OR hasAllTokens(Body, ['failed', 'cache']) OR hasAllTokens(Body, ['charge', 'cache']));
-- Q10 task=count filter=phrase freq=mid (phrase, 2 tokens)
SELECT count() FROM otel_logs WHERE matchPhrase(Body, 'place order');
-- Q11 task=count filter=phrase freq=mid (phrase, 4 tokens)
SELECT count() FROM otel_logs WHERE matchPhrase(Body, 'failed to place order');
-- Q12 task=count filter=phrase freq=lo (phrase, 8 tokens)
SELECT count() FROM otel_logs WHERE matchPhrase(Body, 'post to email service expected 200 got 500');
-- Q13 task=count filter=phrase,proximity freq=hi (failed within 2 of order)
UNSUPPORTED: prox -- not expressible on ClickHouse text index
-- Q14 task=count filter=phrase,or freq=hi (phrase OR term)
SELECT count() FROM otel_logs WHERE matchPhrase(Body, 'failed to place order') OR hasToken(Body, 'charge');
-- Q15 task=count filter=phrase,and freq=mid (phrase AND term)
SELECT count() FROM otel_logs WHERE matchPhrase(Body, 'failed to place order') AND hasToken(Body, 'charge');
-- Q16 task=count filter=regexp freq=hi (charg.*)
UNSUPPORTED: regexp -- not expressible on ClickHouse text index
-- Q17 task=count filter=regexp freq=hi (ord.*)
UNSUPPORTED: regexp -- not expressible on ClickHouse text index
-- Q18 task=count filter=regexp freq=mid (conn.*)
UNSUPPORTED: regexp -- not expressible on ClickHouse text index
-- Q19 task=count filter=regexp freq=hi (single-char wildcard mid: c.che -> cache)
UNSUPPORTED: regexp -- not expressible on ClickHouse text index
-- Q20 task=count filter=prefix freq=mid (conn)
UNSUPPORTED: prefix -- not expressible on ClickHouse text index
-- Q21 task=count filter=prefix freq=hi (charg)
UNSUPPORTED: prefix -- not expressible on ClickHouse text index
-- Q22 task=count filter=fuzzy freq=mid (levenshtein distance 1)
UNSUPPORTED: fuzzy -- not expressible on ClickHouse text index
-- Q23 task=count filter=fuzzy freq=mid (levenshtein distance 2)
UNSUPPORTED: fuzzy -- not expressible on ClickHouse text index
-- Q24 task=count filter=fuzzy,prefix freq=mid (levenshtein-2 AND prefix, same 'conn' root)
UNSUPPORTED: fuzzy_prefix -- not expressible on ClickHouse text index
-- Q25 task=count filter=like freq=mid (prefix wildcard conn%)
UNSUPPORTED: like -- not expressible on ClickHouse text index
-- Q26 task=count filter=like freq=hi (suffix wildcard %tion)
UNSUPPORTED: like -- not expressible on ClickHouse text index
-- Q27 task=count filter=like freq=mid (middle wildcard %nnec%)
UNSUPPORTED: like -- not expressible on ClickHouse text index
-- Q28 task=count filter=and,negation freq=hi (error but NOT cache)
SELECT count() FROM otel_logs WHERE hasToken(Body, 'error') AND NOT hasToken(Body, 'cache');
-- Q29 task=count filter=or,negation freq=hi (error/failed, excluding charge)
SELECT count() FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'failed']) AND NOT hasToken(Body, 'charge');
-- Q30 task=count filter=term,window freq=hi (term + Timestamp BETWEEN 6h)
SELECT count() FROM otel_logs WHERE hasToken(Body, 'error') AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 06:00:00';
-- Q31 task=count filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT count() FROM otel_logs WHERE ServiceName = 'frontend' AND hasToken(Body, 'failed') AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 06:00:00';
-- Q32 task=count filter=or,window freq=mid (8-token OR within a BETWEEN 6h window)
SELECT count() FROM otel_logs WHERE hasAnyTokens(Body, ['payment', 'exception', 'refused', 'send', 'confirmation', 'email', 'expected', 'deadline']) AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 06:00:00';
-- Q33 task=top_k filter=term freq=hi
UNSUPPORTED: top_k BM25 -- no ranking
-- Q34 task=top_k filter=term freq=mid
UNSUPPORTED: top_k BM25 -- no ranking
-- Q35 task=top_k filter=term freq=lo
UNSUPPORTED: top_k BM25 -- no ranking
-- Q36 task=top_k filter=and freq=hi (AND, 2 tokens)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q37 task=top_k filter=and freq=hi (AND, 4 tokens)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q38 task=top_k filter=and freq=lo (AND, 8 tokens)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q39 task=top_k filter=or freq=hi (OR, 2 tokens)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q40 task=top_k filter=or freq=hi (OR, 4 tokens)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q41 task=top_k filter=or freq=mid (OR, 8 tokens)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q42 task=top_k filter=or,minmatch freq=hi (>=2 of 4)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q43 task=top_k filter=phrase freq=mid (phrase, 2 tokens)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q44 task=top_k filter=phrase freq=mid (phrase, 4 tokens)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q45 task=top_k filter=phrase freq=lo (phrase, 8 tokens)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q46 task=top_k filter=regexp freq=mid (conn.*)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q47 task=top_k filter=prefix freq=hi (charg)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q48 task=top_k filter=fuzzy freq=mid (levenshtein distance 1)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q49 task=top_k filter=fuzzy freq=mid (levenshtein distance 2)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q50 task=top_k filter=like freq=mid (prefix wildcard conn%)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q51 task=top_k filter=phrase,or freq=hi (phrase OR term)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q52 task=top_k filter=and,negation freq=hi (error but NOT cache)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q53 task=top_k filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
UNSUPPORTED: top_k BM25 -- no ranking
-- Q54 task=group_by filter=or freq=hi (key=SeverityText, ordered)
SELECT SeverityText, count() AS cnt FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'failed']) GROUP BY SeverityText ORDER BY cnt DESC;
-- Q55 task=group_by filter=term freq=hi (key=SeverityText, ordered)
SELECT SeverityText, count() AS cnt FROM otel_logs WHERE hasToken(Body, 'charge') GROUP BY SeverityText ORDER BY cnt DESC;
-- Q56 task=group_by filter=and freq=hi (key=SeverityText, NO order by)
SELECT SeverityText, count() AS cnt FROM otel_logs WHERE hasAllTokens(Body, ['failed', 'order']) GROUP BY SeverityText;
-- Q57 task=group_by filter=or freq=hi (key=ScopeName, top 20 ordered)
SELECT ScopeName, count() AS cnt FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'failed']) GROUP BY ScopeName ORDER BY cnt DESC LIMIT 20;
-- Q58 task=group_by filter=regexp freq=hi (key=ScopeName)
UNSUPPORTED: regexp -- not expressible on ClickHouse text index
-- Q59 task=group_by filter=fuzzy freq=mid (key=ScopeName)
UNSUPPORTED: fuzzy -- not expressible on ClickHouse text index
-- Q60 task=group_by filter=or freq=hi (key=ScopeName, NO order by)
SELECT ScopeName, count() AS cnt FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'failed']) GROUP BY ScopeName;
-- Q61 task=group_by filter=term freq=hi (key=minute)
SELECT toStartOfMinute(Timestamp) AS minute, count() AS cnt FROM otel_logs WHERE hasToken(Body, 'error') GROUP BY minute ORDER BY minute;
-- Q62 task=group_by filter=and freq=hi (key=minute)
SELECT toStartOfMinute(Timestamp) AS minute, count() AS cnt FROM otel_logs WHERE hasAllTokens(Body, ['failed', 'order']) GROUP BY minute ORDER BY minute;
-- Q63 task=group_by filter=phrase freq=mid (key=minute)
SELECT toStartOfMinute(Timestamp) AS minute, count() AS cnt FROM otel_logs WHERE matchPhrase(Body, 'failed to place order') GROUP BY minute ORDER BY minute;
-- Q64 task=group_by filter=or freq=hi (key=minute)
SELECT toStartOfMinute(Timestamp) AS minute, count() AS cnt FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'failed', 'charge']) GROUP BY minute ORDER BY minute;
-- Q65 task=group_by filter=term freq=hi (key=minute, NO order by)
SELECT toStartOfMinute(Timestamp) AS minute, count() AS cnt FROM otel_logs WHERE hasToken(Body, 'error') GROUP BY minute;
-- Q66 task=group_by filter=and freq=hi (key=SeverityText, Body term + indexed service)
SELECT SeverityText, count() AS cnt FROM otel_logs WHERE ServiceName = 'frontend' AND hasToken(Body, 'failed') GROUP BY SeverityText ORDER BY cnt DESC;
-- Q67 task=group_by filter=or freq=hi (two keys: SeverityText, ScopeName)
SELECT SeverityText, ScopeName, count() AS cnt FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'failed']) GROUP BY SeverityText, ScopeName ORDER BY cnt DESC LIMIT 20;
-- Q68 task=recent filter=and,window freq=hi (recent failed-order logs from checkout)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'checkout' AND hasAllTokens(Body, ['failed', 'order']) AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q69 task=recent filter=or,window freq=hi (recent error/failed/charge, severity>=warn)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'failed', 'charge']) AND SeverityNumber >= 13 AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q70 task=recent filter=term,window freq=hi (recent error logs in a 6h window)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE hasToken(Body, 'error') AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 06:00:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q71 task=recent filter=phrase,window freq=mid (recent 'failed to place order')
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE matchPhrase(Body, 'failed to place order') AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 06:00:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q72 task=recent filter=and,window freq=hi (recent payment charges)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'payment' AND hasToken(Body, 'charge') AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q73 task=recent filter=window (pure time-series tail: recent cart logs, no text search)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'cart' AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q74 task=recent filter=regexp,window freq=hi (recent charg* logs in a 6h window)
UNSUPPORTED: regexp -- not expressible on ClickHouse text index
-- Q75 task=recent filter=or,window freq=mid (recent connection/request/conversion logs)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE hasAnyTokens(Body, ['connection', 'request', 'conversion']) AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' ORDER BY Timestamp DESC LIMIT 100;
-- Q76 task=recent filter=and,window freq=hi (checkout failed&order, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'checkout' AND hasAllTokens(Body, ['failed', 'order']) AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' LIMIT 100;
-- Q77 task=recent filter=or,window freq=hi (error/failed/charge sev>=warn, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE hasAnyTokens(Body, ['error', 'failed', 'charge']) AND SeverityNumber >= 13 AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' LIMIT 100;
-- Q78 task=recent filter=term,window freq=hi (error 6h, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE hasToken(Body, 'error') AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 06:00:00' LIMIT 100;
-- Q79 task=recent filter=phrase,window freq=mid (failed to place order 6h, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE matchPhrase(Body, 'failed to place order') AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 06:00:00' LIMIT 100;
-- Q80 task=recent filter=and,window freq=hi (payment charges, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'payment' AND hasToken(Body, 'charge') AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' LIMIT 100;
-- Q81 task=recent filter=window (cart tail, NO order by, no text search)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'cart' AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' LIMIT 100;
-- Q82 task=recent filter=regexp,window freq=hi (charg.* 6h, NO order by)
UNSUPPORTED: regexp -- not expressible on ClickHouse text index
-- Q83 task=recent filter=or,window freq=mid (connection/request/conversion, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE hasAnyTokens(Body, ['connection', 'request', 'conversion']) AND Timestamp BETWEEN '2025-09-23 00:00:00' AND '2025-09-23 00:30:00' LIMIT 100;
-- Q84 task=join filter=term freq=hi (frontend 'failed' traces that also involve payment)
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId != '' AND a.ServiceName = 'frontend' AND hasToken(a.Body, 'failed') AND b.ServiceName = 'payment';
-- Q85 task=join filter=or freq=hi
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId != '' AND hasAnyTokens(a.Body, ['error', 'failed']) AND b.ServiceName = 'payment';
-- Q86 task=join filter=phrase freq=mid
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId != '' AND matchPhrase(a.Body, 'failed to place order') AND b.ServiceName = 'payment';
-- Q87 task=join filter=regexp freq=hi
UNSUPPORTED: regexp -- not expressible on ClickHouse text index
-- Q88 task=join filter=and freq=hi (failed&order traces that also involve cart)
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId != '' AND hasAllTokens(a.Body, ['failed', 'order']) AND b.ServiceName = 'cart';
-- Q89 task=join filter=or freq=mid
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId != '' AND hasAnyTokens(a.Body, ['connection', 'request']) AND b.ServiceName = 'frontend';
-- Q90 task=join filter=and freq=hi
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId != '' AND hasAllTokens(a.Body, ['charge', 'request']) AND b.ServiceName = 'frontend';
-- Q91 task=join filter=term freq=hi
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId != '' AND hasToken(a.Body, 'order') AND b.ServiceName = 'payment';
-- Q92 task=join filter=prefix freq=hi
UNSUPPORTED: prefix -- not expressible on ClickHouse text index
