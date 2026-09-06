-- Typesense search parameters over the OTel-logs corpus -- 92 queries
-- mirroring serenedb/queries.sql Q01-Q92 one-for-one. Generated from
-- elastic/queries.dsl by typesense/translate.py; see that file for the
-- semantics (token_separators, per-query num_typos/prefix/infix).

-- Q01 task=count filter=term freq=hi
{"q": "error", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 0}
-- Q02 task=count filter=term freq=lo
{"q": "payment", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 0}
-- Q03 task=count filter=and freq=hi (AND, 2 tokens)
{"q": "failed order", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 0}
-- Q04 task=count filter=and freq=hi (AND, 4 tokens)
{"q": "failed charge card cache", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 0}
-- Q05 task=count filter=and freq=lo (AND, 8 tokens)
{"q": "failed send order confirmation email service expected post", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 0}
-- Q06 task=count filter=or freq=hi (OR, 2 tokens)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:error || Body:failed)", "per_page": 0}
-- Q07 task=count filter=or freq=hi (OR, 4 tokens)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:connection || Body:request || Body:conversion || Body:post)", "per_page": 0}
-- Q08 task=count filter=or freq=mid (OR, 8 tokens)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:payment || Body:exception || Body:refused || Body:send || Body:confirmation || Body:email || Body:expected || Body:deadline)", "per_page": 0}
-- Q09 task=count filter=or,minmatch freq=hi (>=2 of 4)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "((Body:error && Body:failed) || (Body:error && Body:charge) || (Body:error && Body:cache) || (Body:failed && Body:charge) || (Body:failed && Body:cache) || (Body:charge && Body:cache))", "per_page": 0}
-- Q10 task=count filter=phrase freq=mid (phrase, 2 tokens)
{"q": "\"place order\"", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 0}
-- Q11 task=count filter=phrase freq=mid (phrase, 4 tokens)
{"q": "\"failed to place order\"", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 0}
-- Q12 task=count filter=phrase freq=lo (phrase, 8 tokens)
{"q": "\"post to email service expected 200 got 500\"", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 0}
-- Q13 task=count filter=phrase,proximity freq=hi (failed within 2 of order)
UNSUPPORTED: match_phrase with slop: no proximity operator
-- Q14 task=count filter=phrase,or freq=hi (phrase OR term)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "((Body:failed to place order) || (Body:charge))", "per_page": 0}
-- Q15 task=count filter=phrase,and freq=mid (phrase AND term)
{"q": "\"failed to place order\" charge", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 0}
-- Q16 task=count filter=regexp freq=hi (charg.*)
{"q": "charg", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "per_page": 0}
-- Q17 task=count filter=regexp freq=hi (ord.*)
{"q": "ord", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "per_page": 0}
-- Q18 task=count filter=regexp freq=mid (conn.*)
{"q": "conn", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "per_page": 0}
-- Q19 task=count filter=regexp freq=hi (single-char wildcard mid: c.che -> cache)
UNSUPPORTED: regexp c.che: no regex support in the API
-- Q20 task=count filter=prefix freq=mid (conn)
{"q": "conn", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "per_page": 0}
-- Q21 task=count filter=prefix freq=hi (charg)
{"q": "charg", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "per_page": 0}
-- Q22 task=count filter=fuzzy freq=mid (levenshtein distance 1)
{"q": "connection", "query_by": "Body", "num_typos": 1, "prefix": "false", "max_candidates": 10000, "per_page": 0}
-- Q23 task=count filter=fuzzy freq=mid (levenshtein distance 2)
{"q": "connection", "query_by": "Body", "num_typos": 2, "prefix": "false", "max_candidates": 10000, "per_page": 0}
-- Q24 task=count filter=fuzzy,prefix freq=mid (levenshtein-2 AND prefix, same 'conn' root)
UNSUPPORTED: prefix combined with fuzzy in one bool: `q` applies num_typos to every term and prefix only to the last, so the two cannot be merged
-- Q25 task=count filter=like freq=mid (prefix wildcard conn%)
{"q": "conn", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "per_page": 0}
-- Q26 task=count filter=like freq=hi (suffix wildcard %tion)
UNSUPPORTED: wildcard *tion: suffix match cannot be anchored; infix matches the stem anywhere in a token
-- Q27 task=count filter=like freq=mid (middle wildcard %nnec%)
{"q": "nnec", "query_by": "Body", "num_typos": 0, "prefix": "false", "infix": "always", "per_page": 0}
-- Q28 task=count filter=and,negation freq=hi (error but NOT cache)
{"q": "error", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "Body:!cache", "per_page": 0}
-- Q29 task=count filter=or,negation freq=hi (error/failed, excluding charge)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:error || Body:failed) && Body:!charge", "per_page": 0}
-- Q30 task=count filter=term,window freq=hi (term + Timestamp BETWEEN 6h)
{"q": "error", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 0}
-- Q31 task=count filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
{"q": "failed", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "ServiceName:=frontend && TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 0}
-- Q32 task=count filter=or,window freq=mid (8-token OR within a BETWEEN 6h window)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:payment || Body:exception || Body:refused || Body:send || Body:confirmation || Body:email || Body:expected || Body:deadline) && TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 0}
-- Q33 task=top_k filter=term freq=hi
{"q": "charge", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q34 task=top_k filter=term freq=mid
{"q": "connection", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q35 task=top_k filter=term freq=lo
{"q": "payment", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q36 task=top_k filter=and freq=hi (AND, 2 tokens)
{"q": "failed order", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q37 task=top_k filter=and freq=hi (AND, 4 tokens)
{"q": "failed charge card cache", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q38 task=top_k filter=and freq=lo (AND, 8 tokens)
{"q": "failed send order confirmation email service expected post", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q39 task=top_k filter=or freq=hi (OR, 2 tokens)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:error || Body:failed)", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q40 task=top_k filter=or freq=hi (OR, 4 tokens)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:connection || Body:request || Body:conversion || Body:post)", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q41 task=top_k filter=or freq=mid (OR, 8 tokens)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:payment || Body:exception || Body:refused || Body:send || Body:confirmation || Body:email || Body:expected || Body:deadline)", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q42 task=top_k filter=or,minmatch freq=hi (>=2 of 4)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "((Body:error && Body:failed) || (Body:error && Body:charge) || (Body:error && Body:cache) || (Body:failed && Body:charge) || (Body:failed && Body:cache) || (Body:charge && Body:cache))", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q43 task=top_k filter=phrase freq=mid (phrase, 2 tokens)
{"q": "\"place order\"", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q44 task=top_k filter=phrase freq=mid (phrase, 4 tokens)
{"q": "\"failed to place order\"", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q45 task=top_k filter=phrase freq=lo (phrase, 8 tokens)
{"q": "\"post to email service expected 200 got 500\"", "query_by": "Body", "num_typos": 0, "prefix": "false", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q46 task=top_k filter=regexp freq=mid (conn.*)
{"q": "conn", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q47 task=top_k filter=prefix freq=hi (charg)
{"q": "charg", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q48 task=top_k filter=fuzzy freq=mid (levenshtein distance 1)
{"q": "connection", "query_by": "Body", "num_typos": 1, "prefix": "false", "max_candidates": 10000, "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q49 task=top_k filter=fuzzy freq=mid (levenshtein distance 2)
{"q": "connection", "query_by": "Body", "num_typos": 2, "prefix": "false", "max_candidates": 10000, "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q50 task=top_k filter=like freq=mid (prefix wildcard conn%)
{"q": "conn", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q51 task=top_k filter=phrase,or freq=hi (phrase OR term)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "((Body:failed to place order) || (Body:charge))", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q52 task=top_k filter=and,negation freq=hi (error but NOT cache)
{"q": "error", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "Body:!cache", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q53 task=top_k filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
{"q": "charge", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "ServiceName:=payment && TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 100, "include_fields": "Timestamp,ServiceName,Body"}
-- Q54 task=group_by filter=or freq=hi (key=SeverityText, ordered)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:error || Body:failed)", "facet_by": "SeverityText", "per_page": 0, "max_facet_values": 100}
-- Q55 task=group_by filter=term freq=hi (key=SeverityText, ordered)
{"q": "charge", "query_by": "Body", "num_typos": 0, "prefix": "false", "facet_by": "SeverityText", "per_page": 0, "max_facet_values": 100}
-- Q56 task=group_by filter=and freq=hi (key=SeverityText, NO order by)
{"q": "failed order", "query_by": "Body", "num_typos": 0, "prefix": "false", "facet_by": "SeverityText", "per_page": 0, "max_facet_values": 100}
-- Q57 task=group_by filter=or freq=hi (key=ScopeName, top 20 ordered)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:error || Body:failed)", "facet_by": "ScopeName", "per_page": 0, "max_facet_values": 20}
-- Q58 task=group_by filter=regexp freq=hi (key=ScopeName)
{"q": "charg", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "facet_by": "ScopeName", "per_page": 0, "max_facet_values": 20}
-- Q59 task=group_by filter=fuzzy freq=mid (key=ScopeName)
{"q": "connection", "query_by": "Body", "num_typos": 1, "prefix": "false", "max_candidates": 10000, "facet_by": "ScopeName", "per_page": 0, "max_facet_values": 20}
-- Q60 task=group_by filter=or freq=hi (key=ScopeName, NO order by)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:error || Body:failed)", "facet_by": "ScopeName", "per_page": 0, "max_facet_values": 100}
-- Q61 task=group_by filter=term freq=hi (key=minute)
UNSUPPORTED: date_histogram: facet_by buckets by value, not time interval
-- Q62 task=group_by filter=and freq=hi (key=minute)
UNSUPPORTED: date_histogram: facet_by buckets by value, not time interval
-- Q63 task=group_by filter=phrase freq=mid (key=minute)
UNSUPPORTED: date_histogram: facet_by buckets by value, not time interval
-- Q64 task=group_by filter=or freq=hi (key=minute)
UNSUPPORTED: date_histogram: facet_by buckets by value, not time interval
-- Q65 task=group_by filter=term freq=hi (key=minute, NO order by)
UNSUPPORTED: date_histogram: facet_by buckets by value, not time interval
-- Q66 task=group_by filter=and freq=hi (key=SeverityText, Body term + indexed service)
{"q": "failed", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "ServiceName:=frontend", "facet_by": "SeverityText", "per_page": 0, "max_facet_values": 100}
-- Q67 task=group_by filter=or freq=hi (two keys: SeverityText, ScopeName)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:error || Body:failed)", "facet_by": "SeverityText", "per_page": 0, "max_facet_values": 100}
-- Q68 task=recent filter=and,window freq=hi (recent failed-order logs from checkout)
{"q": "failed order", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "ServiceName:=checkout && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body", "sort_by": "TimestampMs:desc"}
-- Q69 task=recent filter=or,window freq=hi (recent error/failed/charge, severity>=warn)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:error || Body:failed || Body:charge) && SeverityNumber:>=13 && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body", "sort_by": "TimestampMs:desc"}
-- Q70 task=recent filter=term,window freq=hi (recent error logs in a 6h window)
{"q": "error", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body", "sort_by": "TimestampMs:desc"}
-- Q71 task=recent filter=phrase,window freq=mid (recent 'failed to place order')
{"q": "\"failed to place order\"", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body", "sort_by": "TimestampMs:desc"}
-- Q72 task=recent filter=and,window freq=hi (recent payment charges)
{"q": "charge", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "ServiceName:=payment && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body", "sort_by": "TimestampMs:desc"}
-- Q73 task=recent filter=window (pure time-series tail: recent cart logs, no text search)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "ServiceName:=cart && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body", "sort_by": "TimestampMs:desc"}
-- Q74 task=recent filter=regexp,window freq=hi (recent charg* logs in a 6h window)
{"q": "charg", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "filter_by": "TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body", "sort_by": "TimestampMs:desc"}
-- Q75 task=recent filter=or,window freq=mid (recent connection/request/conversion logs)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:connection || Body:request || Body:conversion) && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body", "sort_by": "TimestampMs:desc"}
-- Q76 task=recent filter=and,window freq=hi (checkout failed&order, NO order by)
{"q": "failed order", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "ServiceName:=checkout && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body"}
-- Q77 task=recent filter=or,window freq=hi (error/failed/charge sev>=warn, NO order by)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:error || Body:failed || Body:charge) && SeverityNumber:>=13 && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body"}
-- Q78 task=recent filter=term,window freq=hi (error 6h, NO order by)
{"q": "error", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body"}
-- Q79 task=recent filter=phrase,window freq=mid (failed to place order 6h, NO order by)
{"q": "\"failed to place order\"", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body"}
-- Q80 task=recent filter=and,window freq=hi (payment charges, NO order by)
{"q": "charge", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "ServiceName:=payment && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body"}
-- Q81 task=recent filter=window (cart tail, NO order by, no text search)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "ServiceName:=cart && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body"}
-- Q82 task=recent filter=regexp,window freq=hi (charg.* 6h, NO order by)
{"q": "charg", "query_by": "Body", "num_typos": 0, "prefix": "true", "max_candidates": 10000, "filter_by": "TimestampMs:>=1758585600000 && TimestampMs:<=1758607200000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body"}
-- Q83 task=recent filter=or,window freq=mid (connection/request/conversion, NO order by)
{"q": "*", "query_by": "Body", "num_typos": 0, "prefix": "false", "filter_by": "(Body:connection || Body:request || Body:conversion) && TimestampMs:>=1758585600000 && TimestampMs:<=1758587400000", "per_page": 100, "include_fields": "Timestamp,ServiceName,SeverityText,Body"}
-- Q84 task=join filter=term freq=hi (frontend 'failed' traces that also involve payment)
UNSUPPORTED: join queries -- Typesense has no join
-- Q85 task=join filter=or freq=hi
UNSUPPORTED: join queries -- Typesense has no join
-- Q86 task=join filter=phrase freq=mid
UNSUPPORTED: join queries -- Typesense has no join
-- Q87 task=join filter=regexp freq=hi
UNSUPPORTED: join queries -- Typesense has no join
-- Q88 task=join filter=and freq=hi (failed&order traces that also involve cart)
UNSUPPORTED: join queries -- Typesense has no join
-- Q89 task=join filter=or freq=mid
UNSUPPORTED: join queries -- Typesense has no join
-- Q90 task=join filter=and freq=hi
UNSUPPORTED: join queries -- Typesense has no join
-- Q91 task=join filter=term freq=hi
UNSUPPORTED: join queries -- Typesense has no join
-- Q92 task=join filter=prefix freq=hi
UNSUPPORTED: join queries -- Typesense has no join
