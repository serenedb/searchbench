-- SurrealDB SurrealQL workload over the OTel-logs corpus -- 92 queries
-- mirroring serenedb/queries.sql Q01-Q92 one-for-one. Generated from
-- elastic/queries.dsl by surrealdb/translate.py; see that file for the
-- semantics and what is unsupported.

-- Q01 task=count filter=term freq=hi
SELECT count() FROM otel_logs WHERE Body @@ 'error' GROUP ALL
-- Q02 task=count filter=term freq=lo
SELECT count() FROM otel_logs WHERE Body @@ 'payment' GROUP ALL
-- Q03 task=count filter=and freq=hi (AND, 2 tokens)
SELECT count() FROM otel_logs WHERE Body @@ 'failed order' GROUP ALL
-- Q04 task=count filter=and freq=hi (AND, 4 tokens)
SELECT count() FROM otel_logs WHERE Body @@ 'failed charge card cache' GROUP ALL
-- Q05 task=count filter=and freq=lo (AND, 8 tokens)
SELECT count() FROM otel_logs WHERE Body @@ 'failed send order confirmation email service expected post' GROUP ALL
-- Q06 task=count filter=or freq=hi (OR, 2 tokens)
SELECT count() FROM otel_logs WHERE Body @OR@ 'error failed' GROUP ALL
-- Q07 task=count filter=or freq=hi (OR, 4 tokens)
SELECT count() FROM otel_logs WHERE Body @OR@ 'connection request conversion post' GROUP ALL
-- Q08 task=count filter=or freq=mid (OR, 8 tokens)
SELECT count() FROM otel_logs WHERE Body @OR@ 'payment exception refused send confirmation email expected deadline' GROUP ALL
-- Q09 task=count filter=or,minmatch freq=hi (>=2 of 4)
SELECT count() FROM otel_logs WHERE ((Body @@ 'error failed') OR (Body @@ 'error charge') OR (Body @@ 'error cache') OR (Body @@ 'failed charge') OR (Body @@ 'failed cache') OR (Body @@ 'charge cache')) GROUP ALL
-- Q10 task=count filter=phrase freq=mid (phrase, 2 tokens)
SELECT count() FROM otel_logs WHERE (Body @@ 'place order' AND string::matches(Body, '(?i)place\\ order')) GROUP ALL
-- Q11 task=count filter=phrase freq=mid (phrase, 4 tokens)
SELECT count() FROM otel_logs WHERE (Body @@ 'failed to place order' AND string::matches(Body, '(?i)failed\\ to\\ place\\ order')) GROUP ALL
-- Q12 task=count filter=phrase freq=lo (phrase, 8 tokens)
SELECT count() FROM otel_logs WHERE (Body @@ 'post to email service expected 200 got 500' AND string::matches(Body, '(?i)post\\ to\\ email\\ service\\ expected\\ 200\\ got\\ 500')) GROUP ALL
-- Q13 task=count filter=phrase,proximity freq=hi (failed within 2 of order)
UNSUPPORTED: match_phrase with slop: no proximity operator
-- Q14 task=count filter=phrase,or freq=hi (phrase OR term)
SELECT count() FROM otel_logs WHERE ((Body @@ 'failed to place order' AND string::matches(Body, '(?i)failed\\ to\\ place\\ order')) OR Body @@ 'charge') GROUP ALL
-- Q15 task=count filter=phrase,and freq=mid (phrase AND term)
SELECT count() FROM otel_logs WHERE (Body @@ 'failed to place order' AND string::matches(Body, '(?i)failed\\ to\\ place\\ order')) AND Body @@ 'charge' GROUP ALL
-- Q16 task=count filter=regexp freq=hi (charg.*)
SELECT count() FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])charg') GROUP ALL
-- Q17 task=count filter=regexp freq=hi (ord.*)
SELECT count() FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])ord') GROUP ALL
-- Q18 task=count filter=regexp freq=mid (conn.*)
SELECT count() FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])conn') GROUP ALL
-- Q19 task=count filter=regexp freq=hi (single-char wildcard mid: c.che -> cache)
SELECT count() FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])c.che([^a-z0-9]|$)') GROUP ALL
-- Q20 task=count filter=prefix freq=mid (conn)
SELECT count() FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])conn') GROUP ALL
-- Q21 task=count filter=prefix freq=hi (charg)
SELECT count() FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])charg') GROUP ALL
-- Q22 task=count filter=fuzzy freq=mid (levenshtein distance 1)
UNSUPPORTED: fuzzy: ~ operators removed in 3.0; string::similarity::* is unindexed and a different algorithm than ES edit distance
-- Q23 task=count filter=fuzzy freq=mid (levenshtein distance 2)
UNSUPPORTED: fuzzy: ~ operators removed in 3.0; string::similarity::* is unindexed and a different algorithm than ES edit distance
-- Q24 task=count filter=fuzzy,prefix freq=mid (levenshtein-2 AND prefix, same 'conn' root)
UNSUPPORTED: fuzzy: ~ operators removed in 3.0; string::similarity::* is unindexed and a different algorithm than ES edit distance
-- Q25 task=count filter=like freq=mid (prefix wildcard conn%)
SELECT count() FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])conn') GROUP ALL
-- Q26 task=count filter=like freq=hi (suffix wildcard %tion)
SELECT count() FROM otel_logs WHERE string::matches(Body, '(?i)tion([^a-z0-9]|$)') GROUP ALL
-- Q27 task=count filter=like freq=mid (middle wildcard %nnec%)
SELECT count() FROM otel_logs WHERE string::matches(Body, '(?i)nnec') GROUP ALL
-- Q28 task=count filter=and,negation freq=hi (error but NOT cache)
SELECT count() FROM otel_logs WHERE Body @@ 'error' AND !(Body @@ 'cache') GROUP ALL
-- Q29 task=count filter=or,negation freq=hi (error/failed, excluding charge)
SELECT count() FROM otel_logs WHERE Body @OR@ 'error failed' AND !(Body @@ 'charge') GROUP ALL
-- Q30 task=count filter=term,window freq=hi (term + Timestamp BETWEEN 6h)
SELECT count() FROM otel_logs WHERE Body @@ 'error' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') GROUP ALL
-- Q31 task=count filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT count() FROM otel_logs WHERE Body @@ 'failed' AND ServiceName = 'frontend' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') GROUP ALL
-- Q32 task=count filter=or,window freq=mid (8-token OR within a BETWEEN 6h window)
SELECT count() FROM otel_logs WHERE Body @OR@ 'payment exception refused send confirmation email expected deadline' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') GROUP ALL
-- Q33 task=top_k filter=term freq=hi
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'charge' ORDER BY score DESC LIMIT 100
-- Q34 task=top_k filter=term freq=mid
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'connection' ORDER BY score DESC LIMIT 100
-- Q35 task=top_k filter=term freq=lo
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'payment' ORDER BY score DESC LIMIT 100
-- Q36 task=top_k filter=and freq=hi (AND, 2 tokens)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'failed order' ORDER BY score DESC LIMIT 100
-- Q37 task=top_k filter=and freq=hi (AND, 4 tokens)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'failed charge card cache' ORDER BY score DESC LIMIT 100
-- Q38 task=top_k filter=and freq=lo (AND, 8 tokens)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'failed send order confirmation email service expected post' ORDER BY score DESC LIMIT 100
-- Q39 task=top_k filter=or freq=hi (OR, 2 tokens)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'error failed' ORDER BY score DESC LIMIT 100
-- Q40 task=top_k filter=or freq=hi (OR, 4 tokens)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'connection request conversion post' ORDER BY score DESC LIMIT 100
-- Q41 task=top_k filter=or freq=mid (OR, 8 tokens)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'payment exception refused send confirmation email expected deadline' ORDER BY score DESC LIMIT 100
-- Q42 task=top_k filter=or,minmatch freq=hi (>=2 of 4)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE ((Body @1@ 'error failed') OR (Body @@ 'error charge') OR (Body @@ 'error cache') OR (Body @@ 'failed charge') OR (Body @@ 'failed cache') OR (Body @@ 'charge cache')) ORDER BY score DESC LIMIT 100
-- Q43 task=top_k filter=phrase freq=mid (phrase, 2 tokens)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE (Body @1@ 'place order' AND string::matches(Body, '(?i)place\\ order')) ORDER BY score DESC LIMIT 100
-- Q44 task=top_k filter=phrase freq=mid (phrase, 4 tokens)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE (Body @1@ 'failed to place order' AND string::matches(Body, '(?i)failed\\ to\\ place\\ order')) ORDER BY score DESC LIMIT 100
-- Q45 task=top_k filter=phrase freq=lo (phrase, 8 tokens)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE (Body @1@ 'post to email service expected 200 got 500' AND string::matches(Body, '(?i)post\\ to\\ email\\ service\\ expected\\ 200\\ got\\ 500')) ORDER BY score DESC LIMIT 100
-- Q46 task=top_k filter=regexp freq=mid (conn.*)
UNSUPPORTED: relevance ranking over a regex filter: search::score needs a numbered @N@ match operator, and prefix/wildcard have no index-backed match form
-- Q47 task=top_k filter=prefix freq=hi (charg)
UNSUPPORTED: relevance ranking over a regex filter: search::score needs a numbered @N@ match operator, and prefix/wildcard have no index-backed match form
-- Q48 task=top_k filter=fuzzy freq=mid (levenshtein distance 1)
UNSUPPORTED: fuzzy: ~ operators removed in 3.0; string::similarity::* is unindexed and a different algorithm than ES edit distance
-- Q49 task=top_k filter=fuzzy freq=mid (levenshtein distance 2)
UNSUPPORTED: fuzzy: ~ operators removed in 3.0; string::similarity::* is unindexed and a different algorithm than ES edit distance
-- Q50 task=top_k filter=like freq=mid (prefix wildcard conn%)
UNSUPPORTED: relevance ranking over a regex filter: search::score needs a numbered @N@ match operator, and prefix/wildcard have no index-backed match form
-- Q51 task=top_k filter=phrase,or freq=hi (phrase OR term)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE ((Body @1@ 'failed to place order' AND string::matches(Body, '(?i)failed\\ to\\ place\\ order')) OR Body @@ 'charge') ORDER BY score DESC LIMIT 100
-- Q52 task=top_k filter=and,negation freq=hi (error but NOT cache)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'error' AND !(Body @@ 'cache') ORDER BY score DESC LIMIT 100
-- Q53 task=top_k filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
SELECT Timestamp, ServiceName, Body, search::score(1) AS score FROM otel_logs WHERE Body @1@ 'charge' AND ServiceName = 'payment' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') ORDER BY score DESC LIMIT 100
-- Q54 task=group_by filter=or freq=hi (key=SeverityText, ordered)
SELECT SeverityText, count() AS c FROM otel_logs WHERE Body @OR@ 'error failed' GROUP BY SeverityText ORDER BY c DESC LIMIT 100
-- Q55 task=group_by filter=term freq=hi (key=SeverityText, ordered)
SELECT SeverityText, count() AS c FROM otel_logs WHERE Body @@ 'charge' GROUP BY SeverityText ORDER BY c DESC LIMIT 100
-- Q56 task=group_by filter=and freq=hi (key=SeverityText, NO order by)
SELECT SeverityText, count() AS c FROM otel_logs WHERE Body @@ 'failed order' GROUP BY SeverityText ORDER BY c DESC LIMIT 100
-- Q57 task=group_by filter=or freq=hi (key=ScopeName, top 20 ordered)
SELECT ScopeName, count() AS c FROM otel_logs WHERE Body @OR@ 'error failed' GROUP BY ScopeName ORDER BY c DESC LIMIT 20
-- Q58 task=group_by filter=regexp freq=hi (key=ScopeName)
SELECT ScopeName, count() AS c FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])charg') GROUP BY ScopeName ORDER BY c DESC LIMIT 20
-- Q59 task=group_by filter=fuzzy freq=mid (key=ScopeName)
UNSUPPORTED: fuzzy: ~ operators removed in 3.0; string::similarity::* is unindexed and a different algorithm than ES edit distance
-- Q60 task=group_by filter=or freq=hi (key=ScopeName, NO order by)
SELECT ScopeName, count() AS c FROM otel_logs WHERE Body @OR@ 'error failed' GROUP BY ScopeName ORDER BY c DESC LIMIT 100
-- Q61 task=group_by filter=term freq=hi (key=minute)
SELECT time::floor(Timestamp, 1m) AS bucket, count() AS c FROM otel_logs WHERE Body @@ 'error' GROUP BY bucket ORDER BY bucket
-- Q62 task=group_by filter=and freq=hi (key=minute)
SELECT time::floor(Timestamp, 1m) AS bucket, count() AS c FROM otel_logs WHERE Body @@ 'failed order' GROUP BY bucket ORDER BY bucket
-- Q63 task=group_by filter=phrase freq=mid (key=minute)
SELECT time::floor(Timestamp, 1m) AS bucket, count() AS c FROM otel_logs WHERE (Body @@ 'failed to place order' AND string::matches(Body, '(?i)failed\\ to\\ place\\ order')) GROUP BY bucket ORDER BY bucket
-- Q64 task=group_by filter=or freq=hi (key=minute)
SELECT time::floor(Timestamp, 1m) AS bucket, count() AS c FROM otel_logs WHERE Body @OR@ 'error failed charge' GROUP BY bucket ORDER BY bucket
-- Q65 task=group_by filter=term freq=hi (key=minute, NO order by)
SELECT time::floor(Timestamp, 1m) AS bucket, count() AS c FROM otel_logs WHERE Body @@ 'error' GROUP BY bucket ORDER BY bucket
-- Q66 task=group_by filter=and freq=hi (key=SeverityText, Body term + indexed service)
SELECT SeverityText, count() AS c FROM otel_logs WHERE Body @@ 'failed' AND ServiceName = 'frontend' GROUP BY SeverityText ORDER BY c DESC LIMIT 100
-- Q67 task=group_by filter=or freq=hi (two keys: SeverityText, ScopeName)
SELECT SeverityText, count() AS c FROM otel_logs WHERE Body @OR@ 'error failed' GROUP BY SeverityText ORDER BY c DESC LIMIT 100
-- Q68 task=recent filter=and,window freq=hi (recent failed-order logs from checkout)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @@ 'failed order' AND ServiceName = 'checkout' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') ORDER BY Timestamp DESC LIMIT 100
-- Q69 task=recent filter=or,window freq=hi (recent error/failed/charge, severity>=warn)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @OR@ 'error failed charge' AND SeverityNumber >= 13 AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') ORDER BY Timestamp DESC LIMIT 100
-- Q70 task=recent filter=term,window freq=hi (recent error logs in a 6h window)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @@ 'error' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') ORDER BY Timestamp DESC LIMIT 100
-- Q71 task=recent filter=phrase,window freq=mid (recent 'failed to place order')
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE (Body @@ 'failed to place order' AND string::matches(Body, '(?i)failed\\ to\\ place\\ order')) AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') ORDER BY Timestamp DESC LIMIT 100
-- Q72 task=recent filter=and,window freq=hi (recent payment charges)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @@ 'charge' AND ServiceName = 'payment' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') ORDER BY Timestamp DESC LIMIT 100
-- Q73 task=recent filter=window (pure time-series tail: recent cart logs, no text search)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'cart' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') ORDER BY Timestamp DESC LIMIT 100
-- Q74 task=recent filter=regexp,window freq=hi (recent charg* logs in a 6h window)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])charg') AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') ORDER BY Timestamp DESC LIMIT 100
-- Q75 task=recent filter=or,window freq=mid (recent connection/request/conversion logs)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @OR@ 'connection request conversion' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') ORDER BY Timestamp DESC LIMIT 100
-- Q76 task=recent filter=and,window freq=hi (checkout failed&order, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @@ 'failed order' AND ServiceName = 'checkout' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') LIMIT 100
-- Q77 task=recent filter=or,window freq=hi (error/failed/charge sev>=warn, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @OR@ 'error failed charge' AND SeverityNumber >= 13 AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') LIMIT 100
-- Q78 task=recent filter=term,window freq=hi (error 6h, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @@ 'error' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') LIMIT 100
-- Q79 task=recent filter=phrase,window freq=mid (failed to place order 6h, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE (Body @@ 'failed to place order' AND string::matches(Body, '(?i)failed\\ to\\ place\\ order')) AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') LIMIT 100
-- Q80 task=recent filter=and,window freq=hi (payment charges, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @@ 'charge' AND ServiceName = 'payment' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') LIMIT 100
-- Q81 task=recent filter=window (cart tail, NO order by, no text search)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE ServiceName = 'cart' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') LIMIT 100
-- Q82 task=recent filter=regexp,window freq=hi (charg.* 6h, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE string::matches(Body, '(?i)(^|[^a-z0-9])charg') AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T06:00:00Z') LIMIT 100
-- Q83 task=recent filter=or,window freq=mid (connection/request/conversion, NO order by)
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE Body @OR@ 'connection request conversion' AND (Timestamp >= <datetime>'2025-09-23T00:00:00Z' AND Timestamp <= <datetime>'2025-09-23T00:30:00Z') LIMIT 100
-- Q84 task=join filter=term freq=hi (frontend 'failed' traces that also involve payment)
UNSUPPORTED: join queries -- SurrealQL has no join over a flat table
-- Q85 task=join filter=or freq=hi
UNSUPPORTED: join queries -- SurrealQL has no join over a flat table
-- Q86 task=join filter=phrase freq=mid
UNSUPPORTED: join queries -- SurrealQL has no join over a flat table
-- Q87 task=join filter=regexp freq=hi
UNSUPPORTED: join queries -- SurrealQL has no join over a flat table
-- Q88 task=join filter=and freq=hi (failed&order traces that also involve cart)
UNSUPPORTED: join queries -- SurrealQL has no join over a flat table
-- Q89 task=join filter=or freq=mid
UNSUPPORTED: join queries -- SurrealQL has no join over a flat table
-- Q90 task=join filter=and freq=hi
UNSUPPORTED: join queries -- SurrealQL has no join over a flat table
-- Q91 task=join filter=term freq=hi
UNSUPPORTED: join queries -- SurrealQL has no join over a flat table
-- Q92 task=join filter=prefix freq=hi
UNSUPPORTED: join queries -- SurrealQL has no join over a flat table
