-- Q01 task=count filter=term freq=hi
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'error');
-- Q02 task=count filter=term freq=lo
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'payment');
-- Q03 task=count filter=and freq=hi (AND, 2 tokens)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'failed AND order');
-- Q04 task=count filter=and freq=hi (AND, 4 tokens)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'failed AND charge AND card AND cache');
-- Q05 task=count filter=and freq=lo (AND, 8 tokens)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'failed AND send AND order AND confirmation AND email AND service AND expected AND post');
-- Q06 task=count filter=or freq=hi (OR, 2 tokens)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'error OR failed');
-- Q07 task=count filter=or freq=hi (OR, 4 tokens)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'connection OR request OR conversion OR post');
-- Q08 task=count filter=or freq=mid (OR, 8 tokens)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'payment OR exception OR refused OR send OR confirmation OR email OR expected OR deadline');
-- Q09 task=count filter=or,minmatch freq=hi (>=2 of 4)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'error failed charge cache', 'parser=MATCH,minimumShouldMatch=2');
-- Q10 task=count filter=phrase freq=mid (phrase, 2 tokens)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '"place order"');
-- Q11 task=count filter=phrase freq=mid (phrase, 4 tokens)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '"failed to place order"');
-- Q12 task=count filter=phrase freq=lo (phrase, 8 tokens)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '"post to email service expected 200 got 500"');
-- Q13 task=count filter=phrase,proximity freq=hi (failed within 2 of order)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '"failed order"~2');
-- Q14 task=count filter=phrase,or freq=hi (phrase OR term)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '"failed to place order" OR charge');
-- Q15 task=count filter=phrase,and freq=mid (phrase AND term)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '"failed to place order" AND charge');
-- Q16 task=count filter=regexp freq=hi (charg.*)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '/charg.*/');
-- Q17 task=count filter=regexp freq=hi (ord.*)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '/ord.*/');
-- Q18 task=count filter=regexp freq=mid (conn.*)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '/conn.*/');
-- Q19 task=count filter=regexp freq=hi (single-char wildcard mid: c.che -> cache)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '/c.che/');
-- Q20 task=count filter=prefix freq=mid (conn)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'conn*');
-- Q21 task=count filter=prefix freq=hi (charg)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'charg*');
-- Q22 task=count filter=fuzzy freq=mid (levenshtein distance 1)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'connection~1');
-- Q23 task=count filter=fuzzy freq=mid (levenshtein distance 2)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'connection~2');
-- Q24 task=count filter=fuzzy,prefix freq=mid (levenshtein-2 AND prefix, same 'conn' root)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'connection~2') AND TEXT_MATCH(Body, 'conn*');
-- Q25 task=count filter=like freq=mid (prefix wildcard conn%)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'conn*');
-- Q26 task=count filter=like freq=hi (suffix wildcard %tion)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '*tion', 'allowLeadingWildcard=true');
-- Q27 task=count filter=like freq=mid (middle wildcard %nnec%)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, '*nnec*', 'allowLeadingWildcard=true');
-- Q28 task=count filter=and,negation freq=hi (error but NOT cache)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'error') AND NOT TEXT_MATCH(Body, 'cache');
-- Q29 task=count filter=or,negation freq=hi (error/failed, excluding charge)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'error OR failed') AND NOT TEXT_MATCH(Body, 'charge');
-- Q30 task=count filter=term,window freq=hi (term + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'error') AND "Timestamp" BETWEEN 1758585600000 AND 1758607200000;
-- Q31 task=count filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT count(*) FROM otel_logs WHERE ServiceName = 'frontend' AND TEXT_MATCH(Body, 'failed') AND "Timestamp" BETWEEN 1758585600000 AND 1758607200000;
-- Q32 task=count filter=or,window freq=mid (8-token OR within a BETWEEN 6h window)
SELECT count(*) FROM otel_logs WHERE TEXT_MATCH(Body, 'payment OR exception OR refused OR send OR confirmation OR email OR expected OR deadline') AND "Timestamp" BETWEEN 1758585600000 AND 1758607200000;
-- Q33 task=top_k filter=term freq=hi
UNSUPPORTED: top_k BM25 -- Pinot text index returns an unscored docId bitmap; no relevance ranking
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
SELECT SeverityText, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'error OR failed') GROUP BY SeverityText ORDER BY cnt DESC;
-- Q55 task=group_by filter=term freq=hi (key=SeverityText, ordered)
SELECT SeverityText, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'charge') GROUP BY SeverityText ORDER BY cnt DESC;
-- Q56 task=group_by filter=and freq=hi (key=SeverityText, NO order by)
SELECT SeverityText, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'failed AND order') GROUP BY SeverityText;
-- Q57 task=group_by filter=or freq=hi (key=ScopeName, top 20 ordered)
SELECT ScopeName, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'error OR failed') GROUP BY ScopeName ORDER BY cnt DESC LIMIT 20;
-- Q58 task=group_by filter=regexp freq=hi (key=ScopeName)
SELECT ScopeName, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, '/charg.*/') GROUP BY ScopeName ORDER BY cnt DESC LIMIT 20;
-- Q59 task=group_by filter=fuzzy freq=mid (key=ScopeName)
SELECT ScopeName, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'connection~1') GROUP BY ScopeName ORDER BY cnt DESC LIMIT 20;
-- Q60 task=group_by filter=or freq=hi (key=ScopeName, NO order by)
SELECT ScopeName, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'error OR failed') GROUP BY ScopeName;
-- Q61 task=group_by filter=term freq=hi (key=minute)
SELECT DATETRUNC('MINUTE', "Timestamp") AS minute, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'error') GROUP BY minute ORDER BY minute LIMIT 100000;
-- Q62 task=group_by filter=and freq=hi (key=minute)
SELECT DATETRUNC('MINUTE', "Timestamp") AS minute, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'failed AND order') GROUP BY minute ORDER BY minute LIMIT 100000;
-- Q63 task=group_by filter=phrase freq=mid (key=minute)
SELECT DATETRUNC('MINUTE', "Timestamp") AS minute, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, '"failed to place order"') GROUP BY minute ORDER BY minute LIMIT 100000;
-- Q64 task=group_by filter=or freq=hi (key=minute)
SELECT DATETRUNC('MINUTE', "Timestamp") AS minute, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'error OR failed OR charge') GROUP BY minute ORDER BY minute LIMIT 100000;
-- Q65 task=group_by filter=term freq=hi (key=minute, NO order by)
SELECT DATETRUNC('MINUTE', "Timestamp") AS minute, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'error') GROUP BY minute LIMIT 100000;
-- Q66 task=group_by filter=and freq=hi (key=SeverityText, Body term + indexed service)
SELECT SeverityText, count(*) AS cnt FROM otel_logs WHERE ServiceName = 'frontend' AND TEXT_MATCH(Body, 'failed') GROUP BY SeverityText ORDER BY cnt DESC;
-- Q67 task=group_by filter=or freq=hi (two keys: SeverityText, ScopeName)
SELECT SeverityText, ScopeName, count(*) AS cnt FROM otel_logs WHERE TEXT_MATCH(Body, 'error OR failed') GROUP BY SeverityText, ScopeName ORDER BY cnt DESC LIMIT 20;
-- Q68 task=recent filter=and,window freq=hi (recent failed-order logs from checkout)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'checkout' AND TEXT_MATCH(Body, 'failed AND order') AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 ORDER BY "Timestamp" DESC LIMIT 100;
-- Q69 task=recent filter=or,window freq=hi (recent error/failed/charge, severity>=warn)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, 'error OR failed OR charge') AND SeverityNumber >= 13 AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 ORDER BY "Timestamp" DESC LIMIT 100;
-- Q70 task=recent filter=term,window freq=hi (recent error logs in a 6h window)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, 'error') AND "Timestamp" BETWEEN 1758585600000 AND 1758607200000 ORDER BY "Timestamp" DESC LIMIT 100;
-- Q71 task=recent filter=phrase,window freq=mid (recent 'failed to place order')
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, '"failed to place order"') AND "Timestamp" BETWEEN 1758585600000 AND 1758607200000 ORDER BY "Timestamp" DESC LIMIT 100;
-- Q72 task=recent filter=and,window freq=hi (recent payment charges)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'payment' AND TEXT_MATCH(Body, 'charge') AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 ORDER BY "Timestamp" DESC LIMIT 100;
-- Q73 task=recent filter=window (pure time-series tail: recent cart logs, no text search)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'cart' AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 ORDER BY "Timestamp" DESC LIMIT 100;
-- Q74 task=recent filter=regexp,window freq=hi (recent charg* logs in a 6h window)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, '/charg.*/') AND "Timestamp" BETWEEN 1758585600000 AND 1758607200000 ORDER BY "Timestamp" DESC LIMIT 100;
-- Q75 task=recent filter=or,window freq=mid (recent connection/request/conversion logs)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, 'connection OR request OR conversion') AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 ORDER BY "Timestamp" DESC LIMIT 100;
-- Q76 task=recent filter=and,window freq=hi (checkout failed&order, NO order by)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'checkout' AND TEXT_MATCH(Body, 'failed AND order') AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 LIMIT 100;
-- Q77 task=recent filter=or,window freq=hi (error/failed/charge sev>=warn, NO order by)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, 'error OR failed OR charge') AND SeverityNumber >= 13 AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 LIMIT 100;
-- Q78 task=recent filter=term,window freq=hi (error 6h, NO order by)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, 'error') AND "Timestamp" BETWEEN 1758585600000 AND 1758607200000 LIMIT 100;
-- Q79 task=recent filter=phrase,window freq=mid (failed to place order 6h, NO order by)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, '"failed to place order"') AND "Timestamp" BETWEEN 1758585600000 AND 1758607200000 LIMIT 100;
-- Q80 task=recent filter=and,window freq=hi (payment charges, NO order by)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'payment' AND TEXT_MATCH(Body, 'charge') AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 LIMIT 100;
-- Q81 task=recent filter=window (cart tail, NO order by, no text search)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'cart' AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 LIMIT 100;
-- Q82 task=recent filter=regexp,window freq=hi (charg.* 6h, NO order by)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, '/charg.*/') AND "Timestamp" BETWEEN 1758585600000 AND 1758607200000 LIMIT 100;
-- Q83 task=recent filter=or,window freq=mid (connection/request/conversion, NO order by)
SELECT "Timestamp", ServiceName, SeverityText, Body FROM otel_logs WHERE TEXT_MATCH(Body, 'connection OR request OR conversion') AND "Timestamp" BETWEEN 1758585600000 AND 1758587400000 LIMIT 100;
-- Q84 task=join filter=term freq=hi (frontend 'failed' traces that also involve payment)
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId <> '' AND a.ServiceName = 'frontend' AND TEXT_MATCH(a.Body, 'failed') AND b.ServiceName = 'payment';
-- Q85 task=join filter=or freq=hi
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId <> '' AND TEXT_MATCH(a.Body, 'error OR failed') AND b.ServiceName = 'payment';
-- Q86 task=join filter=phrase freq=mid
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId <> '' AND TEXT_MATCH(a.Body, '"failed to place order"') AND b.ServiceName = 'payment';
-- Q87 task=join filter=regexp freq=hi
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId <> '' AND TEXT_MATCH(a.Body, '/charg.*/') AND b.ServiceName = 'frontend';
-- Q88 task=join filter=and freq=hi (failed&order traces that also involve cart)
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId <> '' AND TEXT_MATCH(a.Body, 'failed AND order') AND b.ServiceName = 'cart';
-- Q89 task=join filter=or freq=mid
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId <> '' AND TEXT_MATCH(a.Body, 'connection OR request') AND b.ServiceName = 'frontend';
-- Q90 task=join filter=and freq=hi
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId <> '' AND TEXT_MATCH(a.Body, 'charge AND request') AND b.ServiceName = 'frontend';
-- Q91 task=join filter=term freq=hi
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId <> '' AND TEXT_MATCH(a.Body, 'order') AND b.ServiceName = 'payment';
-- Q92 task=join filter=prefix freq=hi
SELECT count(DISTINCT a.TraceId) FROM otel_logs a JOIN otel_logs b ON a.TraceId = b.TraceId WHERE a.TraceId <> '' AND TEXT_MATCH(a.Body, 'charg*') AND b.ServiceName = 'frontend';
