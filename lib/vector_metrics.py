#!/usr/bin/env python3
"""Recall + latency helpers for the SearchBench vector track.

Ported from the reference ANN harness (vector-search-benchmark/common/metrics.py):
standard ANN recall@k (retrieved-k vs truth-k) and nearest-rank latency
percentiles. Pure Python (no numpy) so it stays trivially testable.
"""


def recall_at_k(returned_ids, gt_ids, k):
    """Mean recall@k: |returned[:k] ∩ groundtruth[:k]| / min(k, |truth|), over queries."""
    assert len(returned_ids) == len(gt_ids), (len(returned_ids), len(gt_ids))
    total = 0.0
    n = 0
    for got, gt in zip(returned_ids, gt_ids):
        if got is None:
            continue
        truth = set(gt[:k])
        if not truth:
            continue
        hit = sum(1 for x in got[:k] if x in truth)
        total += hit / min(k, len(truth))
        n += 1
    return total / n if n else 0.0


def percentiles(latencies_ms, ps=(50, 95, 99)):
    if not latencies_ms:
        return {f"p{p}": 0.0 for p in ps}
    s = sorted(latencies_ms)
    out = {}
    for p in ps:
        idx = min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1))))
        out[f"p{p}"] = s[idx]
    return out


def latency_summary(latencies_ms):
    pct = percentiles(latencies_ms)
    return {
        "lat_ms_mean": (sum(latencies_ms) / len(latencies_ms)) if latencies_ms else 0.0,
        "lat_ms_p50": pct["p50"],
        "lat_ms_p95": pct["p95"],
        "lat_ms_p99": pct["p99"],
        "lat_ms_min": min(latencies_ms) if latencies_ms else 0.0,
        "lat_ms_max": max(latencies_ms) if latencies_ms else 0.0,
    }
