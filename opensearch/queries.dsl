-- OpenSearch DSL tagged workload, aligned 1:1 with serenedb (Q01-Q92). Joins -> NULL.

-- Q01 task=count filter=term freq=hi
{"query":{"match":{"Body":"error"}},"size":0,"track_total_hits":true}
-- Q02 task=count filter=term freq=lo
{"query":{"match":{"Body":"payment"}},"size":0,"track_total_hits":true}
-- Q03 task=count filter=and freq=hi (AND, 2 tokens)
{"query":{"match":{"Body":{"query":"failed order","operator":"and"}}},"size":0,"track_total_hits":true}
-- Q04 task=count filter=and freq=hi (AND, 4 tokens)
{"query":{"match":{"Body":{"query":"failed charge card cache","operator":"and"}}},"size":0,"track_total_hits":true}
-- Q05 task=count filter=and freq=lo (AND, 8 tokens)
{"query":{"match":{"Body":{"query":"failed send order confirmation email service expected post","operator":"and"}}},"size":0,"track_total_hits":true}
-- Q06 task=count filter=or freq=hi (OR, 2 tokens)
{"query":{"match":{"Body":{"query":"error failed","operator":"or"}}},"size":0,"track_total_hits":true}
-- Q07 task=count filter=or freq=hi (OR, 4 tokens)
{"query":{"match":{"Body":{"query":"connection request conversion post","operator":"or"}}},"size":0,"track_total_hits":true}
-- Q08 task=count filter=or freq=mid (OR, 8 tokens)
{"query":{"match":{"Body":{"query":"payment exception refused send confirmation email expected deadline","operator":"or"}}},"size":0,"track_total_hits":true}
-- Q09 task=count filter=or,minmatch freq=hi (>=2 of 4)
{"query":{"match":{"Body":{"query":"error failed charge cache","minimum_should_match":2}}},"size":0,"track_total_hits":true}
-- Q10 task=count filter=phrase freq=mid (phrase, 2 tokens)
{"query":{"match_phrase":{"Body":"place order"}},"size":0,"track_total_hits":true}
-- Q11 task=count filter=phrase freq=mid (phrase, 4 tokens)
{"query":{"match_phrase":{"Body":"failed to place order"}},"size":0,"track_total_hits":true}
-- Q12 task=count filter=phrase freq=lo (phrase, 8 tokens)
{"query":{"match_phrase":{"Body":"post to email service expected 200 got 500"}},"size":0,"track_total_hits":true}
-- Q13 task=count filter=phrase,proximity freq=hi (failed within 2 of order)
{"query":{"match_phrase":{"Body":{"query":"failed order","slop":2}}},"size":0,"track_total_hits":true}
-- Q14 task=count filter=phrase,or freq=hi (phrase OR term)
{"query":{"bool":{"should":[{"match_phrase":{"Body":"failed to place order"}},{"match":{"Body":"charge"}}],"minimum_should_match":1}},"size":0,"track_total_hits":true}
-- Q15 task=count filter=phrase,and freq=mid (phrase AND term)
{"query":{"bool":{"must":[{"match_phrase":{"Body":"failed to place order"}},{"match":{"Body":"charge"}}]}},"size":0,"track_total_hits":true}
-- Q16 task=count filter=regexp freq=hi (charg.*)
{"query":{"regexp":{"Body":"charg.*"}},"size":0,"track_total_hits":true}
-- Q17 task=count filter=regexp freq=hi (ord.*)
{"query":{"regexp":{"Body":"ord.*"}},"size":0,"track_total_hits":true}
-- Q18 task=count filter=regexp freq=mid (conn.*)
{"query":{"regexp":{"Body":"conn.*"}},"size":0,"track_total_hits":true}
-- Q19 task=count filter=regexp freq=hi (single-char wildcard mid: c.che -> cache)
{"query":{"regexp":{"Body":"c.che"}},"size":0,"track_total_hits":true}
-- Q20 task=count filter=prefix freq=mid (conn)
{"query":{"prefix":{"Body":"conn"}},"size":0,"track_total_hits":true}
-- Q21 task=count filter=prefix freq=hi (charg)
{"query":{"prefix":{"Body":"charg"}},"size":0,"track_total_hits":true}
-- Q22 task=count filter=fuzzy freq=mid (levenshtein distance 1)
{"query":{"fuzzy":{"Body":{"value":"connection","fuzziness":1}}},"size":0,"track_total_hits":true}
-- Q23 task=count filter=fuzzy freq=mid (levenshtein distance 2)
{"query":{"fuzzy":{"Body":{"value":"connection","fuzziness":2}}},"size":0,"track_total_hits":true}
-- Q24 task=count filter=fuzzy,prefix freq=mid (levenshtein-2 AND prefix, same 'conn' root)
{"query":{"bool":{"must":[{"fuzzy":{"Body":{"value":"connection","fuzziness":2}}},{"prefix":{"Body":"conn"}}]}},"size":0,"track_total_hits":true}
-- Q25 task=count filter=like freq=mid (prefix wildcard conn%)
{"query":{"wildcard":{"Body":"conn*"}},"size":0,"track_total_hits":true}
-- Q26 task=count filter=like freq=hi (suffix wildcard %tion)
{"query":{"wildcard":{"Body":"*tion"}},"size":0,"track_total_hits":true}
-- Q27 task=count filter=like freq=mid (middle wildcard %nnec%)
{"query":{"wildcard":{"Body":"*nnec*"}},"size":0,"track_total_hits":true}
-- Q28 task=count filter=and,negation freq=hi (error but NOT cache)
{"query":{"bool":{"must":[{"match":{"Body":"error"}}],"must_not":[{"match":{"Body":"cache"}}]}},"size":0,"track_total_hits":true}
-- Q29 task=count filter=or,negation freq=hi (error/failed, excluding charge)
{"query":{"bool":{"must":[{"match":{"Body":{"query":"error failed","operator":"or"}}}],"must_not":[{"match":{"Body":"charge"}}]}},"size":0,"track_total_hits":true}
-- Q30 task=count filter=term,window freq=hi (term + Timestamp BETWEEN 6h)
{"query":{"bool":{"must":[{"match":{"Body":"error"}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T06:00:00"}}}]}},"size":0,"track_total_hits":true}
-- Q31 task=count filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
{"query":{"bool":{"must":[{"match":{"Body":"failed"}}],"filter":[{"term":{"ServiceName":"frontend"}},{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T06:00:00"}}}]}},"size":0,"track_total_hits":true}
-- Q32 task=count filter=or,window freq=mid (8-token OR within a BETWEEN 6h window)
{"query":{"bool":{"must":[{"match":{"Body":{"query":"payment exception refused send confirmation email expected deadline","operator":"or"}}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T06:00:00"}}}]}},"size":0,"track_total_hits":true}
-- Q33 task=top_k filter=term freq=hi
{"query":{"match":{"Body":"charge"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q34 task=top_k filter=term freq=mid
{"query":{"match":{"Body":"connection"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q35 task=top_k filter=term freq=lo
{"query":{"match":{"Body":"payment"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q36 task=top_k filter=and freq=hi (AND, 2 tokens)
{"query":{"match":{"Body":{"query":"failed order","operator":"and"}}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q37 task=top_k filter=and freq=hi (AND, 4 tokens)
{"query":{"match":{"Body":{"query":"failed charge card cache","operator":"and"}}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q38 task=top_k filter=and freq=lo (AND, 8 tokens)
{"query":{"match":{"Body":{"query":"failed send order confirmation email service expected post","operator":"and"}}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q39 task=top_k filter=or freq=hi (OR, 2 tokens)
{"query":{"match":{"Body":{"query":"error failed","operator":"or"}}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q40 task=top_k filter=or freq=hi (OR, 4 tokens)
{"query":{"match":{"Body":{"query":"connection request conversion post","operator":"or"}}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q41 task=top_k filter=or freq=mid (OR, 8 tokens)
{"query":{"match":{"Body":{"query":"payment exception refused send confirmation email expected deadline","operator":"or"}}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q42 task=top_k filter=or,minmatch freq=hi (>=2 of 4)
{"query":{"match":{"Body":{"query":"error failed charge cache","minimum_should_match":2}}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q43 task=top_k filter=phrase freq=mid (phrase, 2 tokens)
{"query":{"match_phrase":{"Body":"place order"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q44 task=top_k filter=phrase freq=mid (phrase, 4 tokens)
{"query":{"match_phrase":{"Body":"failed to place order"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q45 task=top_k filter=phrase freq=lo (phrase, 8 tokens)
{"query":{"match_phrase":{"Body":"post to email service expected 200 got 500"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q46 task=top_k filter=regexp freq=mid (conn.*)
{"query":{"regexp":{"Body":"conn.*"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q47 task=top_k filter=prefix freq=hi (charg)
{"query":{"prefix":{"Body":"charg"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q48 task=top_k filter=fuzzy freq=mid (levenshtein distance 1)
{"query":{"fuzzy":{"Body":{"value":"connection","fuzziness":1}}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q49 task=top_k filter=fuzzy freq=mid (levenshtein distance 2)
{"query":{"fuzzy":{"Body":{"value":"connection","fuzziness":2}}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q50 task=top_k filter=like freq=mid (prefix wildcard conn%)
{"query":{"wildcard":{"Body":"conn*"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q51 task=top_k filter=phrase,or freq=hi (phrase OR term)
{"query":{"bool":{"should":[{"match_phrase":{"Body":"failed to place order"}},{"match":{"Body":"charge"}}],"minimum_should_match":1}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q52 task=top_k filter=and,negation freq=hi (error but NOT cache)
{"query":{"bool":{"must":[{"match":{"Body":"error"}}],"must_not":[{"match":{"Body":"cache"}}]}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q53 task=top_k filter=and,window freq=hi (term + service + Timestamp BETWEEN 6h)
{"query":{"match":{"Body":"charge"}},"size":100,"sort":[{"_score":"desc"}],"_source":["Timestamp","ServiceName","Body"]}
-- Q54 task=group_by filter=or freq=hi (key=SeverityText, ordered)
{"query":{"match":{"Body":{"query":"error failed","operator":"or"}}},"size":0,"aggs":{"by_sev":{"terms":{"field":"SeverityText","size":100,"order":{"_count":"desc"}}}}}
-- Q55 task=group_by filter=term freq=hi (key=SeverityText, ordered)
{"query":{"match":{"Body":"charge"}},"size":0,"aggs":{"by_sev":{"terms":{"field":"SeverityText","size":100,"order":{"_count":"desc"}}}}}
-- Q56 task=group_by filter=and freq=hi (key=SeverityText, NO order by)
{"query":{"match":{"Body":{"query":"failed order","operator":"and"}}},"size":0,"aggs":{"by_sev":{"terms":{"field":"SeverityText","size":100}}}}
-- Q57 task=group_by filter=or freq=hi (key=ScopeName, top 20 ordered)
{"query":{"match":{"Body":{"query":"error failed","operator":"or"}}},"size":0,"aggs":{"by_scope":{"terms":{"field":"ScopeName","size":20,"order":{"_count":"desc"}}}}}
-- Q58 task=group_by filter=regexp freq=hi (key=ScopeName)
{"query":{"regexp":{"Body":"charg.*"}},"size":0,"aggs":{"by_scope":{"terms":{"field":"ScopeName","size":20,"order":{"_count":"desc"}}}}}
-- Q59 task=group_by filter=fuzzy freq=mid (key=ScopeName)
{"query":{"fuzzy":{"Body":{"value":"connection","fuzziness":1}}},"size":0,"aggs":{"by_scope":{"terms":{"field":"ScopeName","size":20,"order":{"_count":"desc"}}}}}
-- Q60 task=group_by filter=or freq=hi (key=ScopeName, NO order by)
{"query":{"match":{"Body":{"query":"error failed","operator":"or"}}},"size":0,"aggs":{"by_scope":{"terms":{"field":"ScopeName","size":100}}}}
-- Q61 task=group_by filter=term freq=hi (key=minute)
{"query":{"match":{"Body":"error"}},"size":0,"aggs":{"by_minute":{"date_histogram":{"field":"Timestamp","calendar_interval":"minute","min_doc_count":1,"order":{"_key":"asc"}}}}}
-- Q62 task=group_by filter=and freq=hi (key=minute)
{"query":{"match":{"Body":{"query":"failed order","operator":"and"}}},"size":0,"aggs":{"by_minute":{"date_histogram":{"field":"Timestamp","calendar_interval":"minute","min_doc_count":1,"order":{"_key":"asc"}}}}}
-- Q63 task=group_by filter=phrase freq=mid (key=minute)
{"query":{"match_phrase":{"Body":"failed to place order"}},"size":0,"aggs":{"by_minute":{"date_histogram":{"field":"Timestamp","calendar_interval":"minute","min_doc_count":1,"order":{"_key":"asc"}}}}}
-- Q64 task=group_by filter=or freq=hi (key=minute)
{"query":{"match":{"Body":{"query":"error failed charge","operator":"or"}}},"size":0,"aggs":{"by_minute":{"date_histogram":{"field":"Timestamp","calendar_interval":"minute","min_doc_count":1,"order":{"_key":"asc"}}}}}
-- Q65 task=group_by filter=term freq=hi (key=minute, NO order by)
{"query":{"match":{"Body":"error"}},"size":0,"aggs":{"by_minute":{"date_histogram":{"field":"Timestamp","calendar_interval":"minute","min_doc_count":1}}}}
-- Q66 task=group_by filter=and freq=hi (key=SeverityText, Body term + indexed service)
{"query":{"bool":{"must":[{"match":{"Body":"failed"}}],"filter":[{"term":{"ServiceName":"frontend"}}]}},"size":0,"aggs":{"by_sev":{"terms":{"field":"SeverityText","size":100,"order":{"_count":"desc"}}}}}
-- Q67 task=group_by filter=or freq=hi (two keys: SeverityText, ScopeName)
{"query":{"match":{"Body":{"query":"error failed","operator":"or"}}},"size":0,"aggs":{"by_sev":{"terms":{"field":"SeverityText","size":100,"order":{"_count":"desc"}},"aggs":{"by_scope":{"terms":{"field":"ScopeName","size":20,"order":{"_count":"desc"}}}}}}}
-- Q68 task=recent filter=and,window freq=hi (recent failed-order logs from checkout)
{"query":{"bool":{"must":[{"match":{"Body":{"query":"failed order","operator":"and"}}}],"filter":[{"term":{"ServiceName":"checkout"}},{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"],"sort":[{"Timestamp":"desc"}]}
-- Q69 task=recent filter=or,window freq=hi (recent error/failed/charge, severity>=warn)
{"query":{"bool":{"must":[{"match":{"Body":{"query":"error failed charge","operator":"or"}}}],"filter":[{"range":{"SeverityNumber":{"gte":13}}},{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"],"sort":[{"Timestamp":"desc"}]}
-- Q70 task=recent filter=term,window freq=hi (recent error logs in a 6h window)
{"query":{"bool":{"must":[{"match":{"Body":"error"}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T06:00:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"],"sort":[{"Timestamp":"desc"}]}
-- Q71 task=recent filter=phrase,window freq=mid (recent 'failed to place order')
{"query":{"bool":{"must":[{"match_phrase":{"Body":"failed to place order"}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T06:00:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"],"sort":[{"Timestamp":"desc"}]}
-- Q72 task=recent filter=and,window freq=hi (recent payment charges)
{"query":{"bool":{"must":[{"match":{"Body":"charge"}}],"filter":[{"term":{"ServiceName":"payment"}},{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"],"sort":[{"Timestamp":"desc"}]}
-- Q73 task=recent filter=window (pure time-series tail: recent cart logs, no text search)
{"query":{"bool":{"must":[],"filter":[{"term":{"ServiceName":"cart"}},{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"],"sort":[{"Timestamp":"desc"}]}
-- Q74 task=recent filter=regexp,window freq=hi (recent charg* logs in a 6h window)
{"query":{"bool":{"must":[{"regexp":{"Body":"charg.*"}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T06:00:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"],"sort":[{"Timestamp":"desc"}]}
-- Q75 task=recent filter=or,window freq=mid (recent connection/request/conversion logs)
{"query":{"bool":{"must":[{"match":{"Body":{"query":"connection request conversion","operator":"or"}}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"],"sort":[{"Timestamp":"desc"}]}
-- Q76 task=recent filter=and,window freq=hi (checkout failed&order, NO order by)
{"query":{"bool":{"must":[{"match":{"Body":{"query":"failed order","operator":"and"}}}],"filter":[{"term":{"ServiceName":"checkout"}},{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"]}
-- Q77 task=recent filter=or,window freq=hi (error/failed/charge sev>=warn, NO order by)
{"query":{"bool":{"must":[{"match":{"Body":{"query":"error failed charge","operator":"or"}}}],"filter":[{"range":{"SeverityNumber":{"gte":13}}},{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"]}
-- Q78 task=recent filter=term,window freq=hi (error 6h, NO order by)
{"query":{"bool":{"must":[{"match":{"Body":"error"}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T06:00:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"]}
-- Q79 task=recent filter=phrase,window freq=mid (failed to place order 6h, NO order by)
{"query":{"bool":{"must":[{"match_phrase":{"Body":"failed to place order"}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T06:00:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"]}
-- Q80 task=recent filter=and,window freq=hi (payment charges, NO order by)
{"query":{"bool":{"must":[{"match":{"Body":"charge"}}],"filter":[{"term":{"ServiceName":"payment"}},{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"]}
-- Q81 task=recent filter=window (cart tail, NO order by, no text search)
{"query":{"bool":{"must":[],"filter":[{"term":{"ServiceName":"cart"}},{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"]}
-- Q82 task=recent filter=regexp,window freq=hi (charg.* 6h, NO order by)
{"query":{"bool":{"must":[{"regexp":{"Body":"charg.*"}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T06:00:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"]}
-- Q83 task=recent filter=or,window freq=mid (connection/request/conversion, NO order by)
{"query":{"bool":{"must":[{"match":{"Body":{"query":"connection request conversion","operator":"or"}}}],"filter":[{"range":{"Timestamp":{"gte":"2025-09-23T00:00:00","lte":"2025-09-23T00:30:00"}}}]}},"size":100,"_source":["Timestamp","ServiceName","SeverityText","Body"]}
-- Q84 task=join filter=term freq=hi (frontend 'failed' traces that also involve payment)
-- (NULL: OpenSearch has no self-join / LOOKUP JOIN)
-- Q85 task=join filter=or freq=hi
-- (NULL: OpenSearch has no self-join / LOOKUP JOIN)
-- Q86 task=join filter=phrase freq=mid
-- (NULL: OpenSearch has no self-join / LOOKUP JOIN)
-- Q87 task=join filter=regexp freq=hi
-- (NULL: OpenSearch has no self-join / LOOKUP JOIN)
-- Q88 task=join filter=and freq=hi (failed&order traces that also involve cart)
-- (NULL: OpenSearch has no self-join / LOOKUP JOIN)
-- Q89 task=join filter=or freq=mid
-- (NULL: OpenSearch has no self-join / LOOKUP JOIN)
-- Q90 task=join filter=and freq=hi
-- (NULL: OpenSearch has no self-join / LOOKUP JOIN)
-- Q91 task=join filter=term freq=hi
-- (NULL: OpenSearch has no self-join / LOOKUP JOIN)
-- Q92 task=join filter=prefix freq=hi
-- (NULL: OpenSearch has no self-join / LOOKUP JOIN)
