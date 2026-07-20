#!/usr/bin/env python3
"""SearchBench vector track — ingest base vectors + build the ANN index.

Called by each engine's ./load-vector for ONE build config, over the pgwire
protocol (both SereneDB and pgvector speak it). Prints a one-line JSON of build
metrics on stdout for the driver to fold into the results record:

    {"rows":N,"load_s":..,"index_build_s":..,"build_total_s":..,
     "index_disk_bytes":..,"datadir_bytes":..,"ddl":"..."}

Engine specifics (the only per-engine differences):
  serenedb : emb FLOAT[dim];  CREATE INDEX ... USING inverted(id, emb ivf (metric=.., quant=.., nlist=..));
             VACUUM (REFRESH_TABLE) [+ (COMPACT_TABLE)]; size from sdb_metrics.
  pgvector : emb vector(dim);  CREATE INDEX ... USING hnsw|ivfflat (emb <opclass>) WITH (m/ef_construction | lists);
             size from pg_relation_size().

Build params come from flags; nothing is swept here (the driver loops build
configs). Search-time knobs (nprobe / ef_search) are set in lib/vector_query.py.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vector_common as vc  # noqa: E402


def _log(msg):
    print(msg, file=sys.stderr, flush=True)


def emb_literal(vec):
    """Row value for a COPY into FLOAT[dim] (SereneDB) or vector(dim) (pgvector):
    both accept a bracketed float list text literal."""
    return "[" + ",".join(repr(float(x)) for x in vec) + "]"


def copy_vectors(cur, table, ids, base, log_every=1_000_000):
    n = len(base)
    t0 = time.perf_counter()
    with cur.copy(f"COPY {table} (id, emb) FROM STDIN") as cp:
        for i in range(n):
            cp.write_row((int(ids[i]), emb_literal(base[i])))
            if (i + 1) % log_every == 0:
                rate = (i + 1) / (time.perf_counter() - t0)
                _log(f"    copied {i + 1:,}/{n:,} ({rate:,.0f} rows/s)")
    return n


def stage_parquet(path, ids, base):
    """Stage (id, emb) to parquet for SereneDB's read_parquet CTAS path."""
    import pyarrow as pa
    import pyarrow.parquet as pq
    dim = int(base.shape[1])
    emb = pa.FixedSizeListArray.from_arrays(
        pa.array(base.reshape(-1).tolist(), type=pa.float32()), dim)
    tbl = pa.table({"id": pa.array([int(x) for x in ids], type=pa.int64()), "emb": emb})
    pq.write_table(tbl, path)
    return path


# ---- SereneDB (IVF) --------------------------------------------------------
def serenedb_index_ddl(index, table, metric, quant, nlist, pq_m, rabitq_bits, dim, settle):
    opts = [f"metric = '{metric}'"]
    if nlist:
        opts.append(f"nlist = {int(nlist)}")
    opts.append(f"quant = '{quant}'")
    if quant == "pq":
        m = pq_m or vc_default_pq_m(dim)
        opts.append(f"pq_m = {int(m)}")
    if quant == "rabitq" and rabitq_bits:
        opts.append(f"rabitq_bits = {int(rabitq_bits)}")
    ddl = f"CREATE INDEX {index} ON {table} USING inverted(id, emb ivf ({', '.join(opts)}))"
    if settle in ("compact", "no-compact"):
        ddl += " WITH (compaction_interval = 0, refresh_interval = 0)"
    return ddl


def vc_default_pq_m(dim):
    for m in range(min(max(1, dim // 2), dim), 0, -1):
        if dim % m == 0:
            return m
    return 1


def build_serenedb(cur, ds, args):
    dim = ds.dim
    vc_execute(cur, f"DROP TABLE IF EXISTS {args.table} CASCADE")
    t0 = time.perf_counter()
    if args.load_via == "parquet":
        os.makedirs(args.workdir, exist_ok=True)
        pqp = os.path.join(args.workdir, f"{args.dataset}_base.parquet")
        if not os.path.exists(pqp):
            _log(f"  staging {ds.nb} vectors -> {pqp}")
            stage_parquet(pqp, ds.ids(), ds.base)
        _log("  CREATE TABLE AS SELECT read_parquet ...")
        vc_execute(cur, f"CREATE TABLE {args.table} AS "
                        f"SELECT id, emb::FLOAT[{dim}] AS emb FROM read_parquet('{pqp}')")
    else:
        vc_execute(cur, f"CREATE TABLE {args.table} (id BIGINT, emb FLOAT[{dim}])")
        _log(f"  COPY {ds.nb} vectors (dim {dim}) ...")
        copy_vectors(cur, args.table, ds.ids(), ds.base)
    load_s = time.perf_counter() - t0

    ddl = serenedb_index_ddl(args.index, args.table, ds.metric, args.quant,
                             args.nlist, args.pq_m, args.rabitq_bits, dim, args.settle)
    _log(f"  {ddl}")
    t1 = time.perf_counter()
    vc_execute(cur, ddl)
    vc_execute(cur, f"VACUUM (REFRESH_TABLE) {args.table}")
    if args.settle == "compact":
        _log("  VACUUM (COMPACT_TABLE) ...")
        vc_execute(cur, f"VACUUM (COMPACT_TABLE) {args.table}")
    index_s = time.perf_counter() - t1

    rows = vc_scalar(cur, f"SELECT count(*) FROM {args.index}")
    try:
        idx_bytes = float(vc_scalar(
            cur, f"SELECT value FROM sdb_metrics WHERE metric = 'index_size' "
                 f"AND relation_id = '{args.index}'::regclass::BIGINT"))
    except Exception:  # noqa: BLE001 - fall back to NULL; driver's data-size still runs
        idx_bytes = None
    return load_s, index_s, rows, idx_bytes, ddl


# ---- pgvector (HNSW / IVFFlat) --------------------------------------------
_PGV_OPCLASS = {"cosine": "vector_cosine_ops", "l2": "vector_l2_ops", "ip": "vector_ip_ops"}


def pgvector_index_ddl(index, table, metric, index_type, m, ef_construction, lists):
    opclass = _PGV_OPCLASS[metric]
    if index_type == "ivfflat":
        return (f"CREATE INDEX {index} ON {table} USING ivfflat (emb {opclass}) "
                f"WITH (lists = {int(lists)})")
    return (f"CREATE INDEX {index} ON {table} USING hnsw (emb {opclass}) "
            f"WITH (m = {int(m)}, ef_construction = {int(ef_construction)})")


def build_pgvector(cur, ds, args):
    dim = ds.dim
    vc_execute(cur, "CREATE EXTENSION IF NOT EXISTS vector")
    vc_execute(cur, f"DROP TABLE IF EXISTS {args.table} CASCADE")
    vc_execute(cur, f"CREATE TABLE {args.table} (id bigint, emb vector({dim}))")
    _log(f"  COPY {ds.nb} vectors (dim {dim}) ...")
    t0 = time.perf_counter()
    copy_vectors(cur, args.table, ds.ids(), ds.base)
    load_s = time.perf_counter() - t0

    ddl = pgvector_index_ddl(args.index, args.table, ds.metric, args.pg_index_type,
                             args.hnsw_m, args.ef_construction, args.lists)
    _log(f"  {ddl}")
    t1 = time.perf_counter()
    vc_execute(cur, ddl)
    vc_execute(cur, f"ANALYZE {args.table}")
    index_s = time.perf_counter() - t1

    rows = vc_scalar(cur, f"SELECT count(*) FROM {args.table}")
    idx_bytes = float(vc_scalar(cur, f"SELECT pg_relation_size('{args.index}')"))
    return load_s, index_s, rows, idx_bytes, ddl


# ---- small psycopg helpers (kept local so this file is self-contained) -----
def vc_execute(cur, sql):
    cur.execute(sql)


def vc_scalar(cur, sql):
    cur.execute(sql)
    row = cur.fetchone()
    return None if row is None else row[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, choices=["serenedb", "pgvector"])
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--host", default=os.environ.get("PGHOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--user", default=os.environ.get("PGUSER", "postgres"))
    ap.add_argument("--dbname", default=os.environ.get("PGDATABASE", "postgres"))
    ap.add_argument("--nb", type=int, default=None)
    ap.add_argument("--nq", type=int, default=None)
    ap.add_argument("--k", type=int, default=10)
    ap.add_argument("--table", default="vec")
    ap.add_argument("--index", default="vec_idx")
    ap.add_argument("--load-via", default="copy", choices=["copy", "parquet"])
    ap.add_argument("--workdir", default=None)
    # SereneDB IVF build params
    ap.add_argument("--quant", default="none", choices=["none", "sq8", "sq4", "pq", "rabitq"])
    ap.add_argument("--nlist", type=int, default=None)
    ap.add_argument("--pq-m", dest="pq_m", type=int, default=None)
    ap.add_argument("--rabitq-bits", dest="rabitq_bits", type=int, default=None)
    ap.add_argument("--settle", default="compact", choices=["compact", "no-compact", "wait", "none"])
    # pgvector build params
    ap.add_argument("--pg-index-type", dest="pg_index_type", default="hnsw", choices=["hnsw", "ivfflat"])
    ap.add_argument("--hnsw-m", dest="hnsw_m", type=int, default=16)
    ap.add_argument("--ef-construction", dest="ef_construction", type=int, default=64)
    ap.add_argument("--lists", type=int, default=1000)
    args = ap.parse_args()

    import psycopg
    ds = vc.load_dataset(args.dataset, args.data_dir, nb=args.nb, nq=args.nq,
                         k=args.k, with_gt=False)
    _log(f"[ingest] engine={args.engine} dataset={args.dataset} "
         f"nb={ds.nb} dim={ds.dim} metric={ds.metric}")

    conn = psycopg.connect(host=args.host, port=args.port, user=args.user,
                           dbname=args.dbname, autocommit=True)
    cur = conn.cursor()
    try:
        if args.engine == "serenedb":
            load_s, index_s, rows, idx_bytes, ddl = build_serenedb(cur, ds, args)
        else:
            load_s, index_s, rows, idx_bytes, ddl = build_pgvector(cur, ds, args)
    finally:
        cur.close()
        conn.close()

    out = {
        "rows": int(rows) if rows is not None else None,
        "load_s": round(load_s, 3),
        "index_build_s": round(index_s, 3),
        "build_total_s": round(load_s + index_s, 3),
        "index_disk_bytes": idx_bytes,
        "dim": ds.dim,
        "nb": ds.nb,
        "metric": ds.metric,
        "ddl": ddl,
    }
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
