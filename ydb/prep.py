"""Parallel parquet -> YDB-loadable parquet.

The single-threaded prep is dominated by json.dumps over the three map columns,
so chunks are split across processes and written as separate files.
`ydb import file parquet` accepts a directory, so the chunking costs nothing at
load time and the loader stays parallel too.
"""
import json, os, sys, time
from concurrent.futures import ProcessPoolExecutor
import pyarrow as pa, pyarrow.compute as pc, pyarrow.parquet as pq

SRC = sys.argv[1]
DSTDIR = sys.argv[2]
LIMIT = int(sys.argv[3]) if len(sys.argv) > 3 else 0
NPROC = int(sys.argv[4]) if len(sys.argv) > 4 else 30

COLS = ["Timestamp", "TraceId", "SpanId", "TraceFlags", "SeverityText", "SeverityNumber",
        "ServiceName", "Body", "ResourceSchemaUrl", "ResourceAttributes", "ScopeSchemaUrl",
        "ScopeName", "ScopeVersion", "ScopeAttributes", "LogAttributes"]
MAPS = {"ResourceAttributes", "ScopeAttributes", "LogAttributes"}
SCHEMA = pa.schema([
    ("Id", pa.uint64()), ("Timestamp", pa.timestamp("us")),
    ("TraceId", pa.string()), ("SpanId", pa.string()), ("TraceFlags", pa.uint8()),
    ("SeverityText", pa.string()), ("SeverityNumber", pa.uint8()),
    ("ServiceName", pa.string()), ("Body", pa.string()), ("BodyNorm", pa.string()),
    ("ResourceSchemaUrl", pa.string()), ("ResourceAttributes", pa.string()),
    ("ScopeSchemaUrl", pa.string()), ("ScopeName", pa.string()),
    ("ScopeVersion", pa.string()), ("ScopeAttributes", pa.string()),
    ("LogAttributes", pa.string()),
])


def do_chunk(args):
    idx, rg_list, base_id = args
    pf = pq.ParquetFile(SRC)
    dst = os.path.join(DSTDIR, f"part_{idx:04d}.parquet")
    w = pq.ParquetWriter(dst, SCHEMA, compression="snappy")
    rid, n_out = base_id, 0
    for rg in rg_list:
        t = pf.read_row_group(rg, columns=COLS)
        for b in t.to_batches(max_chunksize=50_000):
            n = b.num_rows
            col = {c: b.column(b.schema.get_field_index(c)) for c in COLS}
            body = col["Body"].cast(pa.string())
            norm = pc.replace_substring_regex(pc.utf8_lower(body), r'[^a-z0-9]+', ' ')
            out = {
                "Id": pa.array(range(rid, rid + n), pa.uint64()),
                "Timestamp": col["Timestamp"].cast(pa.timestamp("us"), safe=False),
                "TraceFlags": col["TraceFlags"].cast(pa.uint8()),
                "SeverityNumber": col["SeverityNumber"].cast(pa.uint8()),
                "Body": body, "BodyNorm": norm,
            }
            for c in COLS:
                if c in ("Timestamp", "TraceFlags", "SeverityNumber", "Body"):
                    continue
                if c in MAPS:
                    out[c] = pa.array([json.dumps(dict(v)) if v is not None else "{}"
                                       for v in col[c].to_pylist()], pa.string())
                else:
                    out[c] = col[c].cast(pa.string())
            w.write_table(pa.Table.from_pydict({f.name: out[f.name] for f in SCHEMA},
                                               schema=SCHEMA))
            rid += n; n_out += n
    w.close()
    return n_out


if __name__ == "__main__":
    os.makedirs(DSTDIR, exist_ok=True)
    for f in os.listdir(DSTDIR):
        os.remove(os.path.join(DSTDIR, f))
    pf = pq.ParquetFile(SRC)
    ngroups = pf.metadata.num_row_groups
    rows_per_group = [pf.metadata.row_group(i).num_rows for i in range(ngroups)]

    groups, total = [], 0
    for i, r in enumerate(rows_per_group):
        if LIMIT and total >= LIMIT:
            break
        groups.append(i); total += r

    chunks, base = [], 0
    per = max(1, len(groups) // NPROC)
    for k in range(0, len(groups), per):
        sl = groups[k:k + per]
        chunks.append((len(chunks), sl, base))
        base += sum(rows_per_group[g] for g in sl)

    t0 = time.perf_counter()
    with ProcessPoolExecutor(max_workers=NPROC) as ex:
        counts = list(ex.map(do_chunk, chunks))
    el = time.perf_counter() - t0
    tot = sum(counts)
    print(f"  {tot:,} rows -> {len(chunks)} files in {el:.1f}s = {tot/el:,.0f} rows/s")
