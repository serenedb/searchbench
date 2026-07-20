#!/usr/bin/env python3
"""SearchBench vector track — the recall-vs-QPS sweep.

The one piece the text driver's `./query` (one query on stdin -> one latency on
stderr) can't express: answer all query vectors, at each search-effort setting,
as binary-bound prepared statements across `clients` concurrent connections, and
score the returned ids against exact-KNN ground truth. Ported/generalized from
vector-search-benchmark/common/runner.py (closed-loop, barrier-synced timing).

Emits a JSON array of sweep records on stdout (one per search_effort x clients
[x rerank_factor]); each is merged with --extra-json (metadata + build metrics)
so the driver can write complete result records.

Per-metric KNN operator (same symbols on both engines; both order ASC):
    l2 -> `<->`   cosine -> `<=>`   ip -> `<#>`   (ip: negative-IP, so ASC = max IP)
Search-effort knob:
    serenedb -> SET sdb_nprobe   pgvector(hnsw) -> SET hnsw.ef_search
                                 pgvector(ivfflat) -> SET ivfflat.probes
"""

import argparse
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vector_common as vc      # noqa: E402
import vector_metrics as vm     # noqa: E402

_OP = {"l2": "<->", "cosine": "<=>", "ip": "<#>"}


def _log(msg):
    print(msg, file=sys.stderr, flush=True)


def _ints(s):
    return [int(x) for x in str(s).split(",") if str(x).strip() != ""]


class EngineCfg:
    """Per-engine query specifics: the KNN SQL, how to bind a query vector, and
    how to set the search-effort (and rerank) knobs on a fresh session."""

    def __init__(self, engine, target, dim, metric, k, pg_index_type):
        self.engine = engine
        op = _OP[metric]
        if engine == "serenedb":
            # binary-bound list param -> FLOAT[dim]; query the index relation so
            # the optimizer fires the IVF "Vector KNN" scan.
            self.sql = f"SELECT id FROM {target} ORDER BY emb {op} %b::FLOAT[{dim}] LIMIT {k}"
            self._bind = lambda vec: [float(x) for x in vec]
            self._effort_knob = "sdb_nprobe"
        else:  # pgvector
            # text-literal param cast to vector (no pgvector python dep required;
            # installing `pgvector` would enable binary binding for lower parse cost).
            self.sql = f"SELECT id FROM {target} ORDER BY emb {op} %s::vector LIMIT {k}"
            self._bind = lambda vec: "[" + ",".join(repr(float(x)) for x in vec) + "]"
            self._effort_knob = "ivfflat.probes" if pg_index_type == "ivfflat" else "hnsw.ef_search"

    def bind(self, vec):
        return self._bind(vec)

    def setup_session(self, cur, effort, rerank_factor):
        cur.execute(f"SET {self._effort_knob} = {int(effort)}")
        if self.engine == "serenedb" and rerank_factor is not None:
            cur.execute(f"SET sdb_rerank_factor = {int(rerank_factor)}")


def _client_run(connect, cfg, effort, rerank_factor, params, nq, warmup, indices,
                latencies, returned, barrier, errors):
    try:
        conn = connect()
        cur = conn.cursor()
        cfg.setup_session(cur, effort, rerank_factor)
        for i in range(warmup):
            cur.execute(cfg.sql, (params[i % nq],), prepare=True)
            cur.fetchall()
        barrier.wait()
        for idx in indices:
            qi = idx % nq
            t0 = time.perf_counter()
            cur.execute(cfg.sql, (params[qi],), prepare=True)
            rows = cur.fetchall()
            latencies[idx] = (time.perf_counter() - t0) * 1000.0
            if idx < nq:
                returned[qi] = [r[0] for r in rows]
        cur.close()
        conn.close()
    except threading.BrokenBarrierError:
        pass
    except Exception as e:  # noqa: BLE001 - surface + unblock the other clients
        errors.append(e)
        try:
            barrier.abort()
        except Exception:  # noqa: BLE001
            pass


def _run_combo(connect, cfg, effort, rerank_factor, clients, params, gt, k, warmup, repeats):
    nq = len(params)
    total = repeats * nq
    latencies = [0.0] * total
    returned = [None] * nq
    t_loop = [None]

    def _start():
        t_loop[0] = time.perf_counter()

    barrier = threading.Barrier(clients, action=_start)
    errors = []
    threads = [
        threading.Thread(target=_client_run, args=(
            connect, cfg, effort, rerank_factor, params, nq, warmup,
            range(c, total, clients), latencies, returned, barrier, errors))
        for c in range(clients)
    ]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    if errors:
        raise errors[0]
    total_s = time.perf_counter() - t_loop[0]

    rec = {
        "search_effort": effort,
        "clients": clients,
        "k": k,
        "recall_at_k": round(vm.recall_at_k(returned, gt, k), 4),
        "qps": round(total / total_s if total_s > 0 else 0.0, 1),
        "n_queries": nq,
    }
    if rerank_factor is not None:
        rec["rerank_factor"] = rerank_factor
    rec.update({key: round(v, 3) for key, v in vm.latency_summary(latencies).items()})
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, choices=["serenedb", "pgvector"])
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--host", default=os.environ.get("PGHOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--user", default=os.environ.get("PGUSER", "postgres"))
    ap.add_argument("--dbname", default=os.environ.get("PGDATABASE", "postgres"))
    ap.add_argument("--target", required=True, help="index (serenedb) or table (pgvector) to query")
    ap.add_argument("--k", type=int, default=10)
    ap.add_argument("--nb", type=int, default=None)
    ap.add_argument("--nq", type=int, default=None)
    ap.add_argument("--search-effort", dest="search_effort", default="8,16,32,64,128")
    ap.add_argument("--clients", default="1")
    ap.add_argument("--rerank-factor", dest="rerank_factor", default=None,
                    help="serenedb quantized only; comma list (e.g. 0,4). Omit for unquantized.")
    ap.add_argument("--pg-index-type", dest="pg_index_type", default="hnsw",
                    choices=["hnsw", "ivfflat"])
    ap.add_argument("--warmup", type=int, default=50)
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--extra-json", dest="extra_json", default="{}",
                    help="JSON object merged into every emitted record (metadata + build metrics)")
    args = ap.parse_args()

    import psycopg
    ds = vc.load_dataset(args.dataset, args.data_dir, nb=args.nb, nq=args.nq,
                         k=args.k, with_gt=True)
    gt = ds.gt_list()
    extra = json.loads(args.extra_json)

    cfg = EngineCfg(args.engine, args.target, ds.dim, ds.metric, args.k, args.pg_index_type)
    params = [cfg.bind(q) for q in ds.queries]

    def connect():
        return psycopg.connect(host=args.host, port=args.port, user=args.user,
                               dbname=args.dbname, autocommit=True)

    efforts = _ints(args.search_effort)
    clients_list = _ints(args.clients)
    reranks = _ints(args.rerank_factor) if args.rerank_factor else [None]

    _log(f"[query] engine={args.engine} dataset={args.dataset} metric={ds.metric} "
         f"dim={ds.dim} nq={ds.nq} k={args.k} efforts={efforts} clients={clients_list}")

    records = []
    for effort in efforts:
        for rr in reranks:
            for clients in clients_list:
                rec = _run_combo(connect, cfg, effort, rr, clients, params, gt,
                                 args.k, args.warmup, args.repeats)
                merged = dict(extra)
                merged.update(rec)
                records.append(merged)
                _log(f"  effort={effort:<6d} clients={clients:<3d}"
                     + (f" rr={rr}" if rr is not None else "")
                     + f"  recall@{args.k}={rec['recall_at_k']:.4f} qps={rec['qps']:.1f}"
                     f" p50={rec['lat_ms_p50']:.3f}ms p95={rec['lat_ms_p95']:.3f}ms")

    json.dump(records, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
