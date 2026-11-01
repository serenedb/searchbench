#!/usr/bin/env python3
"""Split the corpus parquet into N shards, one per Pinot segment.

Pinot creates one segment per input file, and a segment is both the unit of
intra-query parallelism and the unit of Lucene index build, so a single 1B-row
input file would pin every scan to one thread and build one enormous index.

Shards are cut on row-group boundaries. That makes the split exact (every row
lands in exactly one shard, no row group is read twice) and lets workers run in
parallel, each touching a disjoint range of row groups.

    shard_parquet.py <src_dir> --count                 -> total row count
    shard_parquet.py <src_dir> <out_dir> <n> [workers] -> write ~n shards
"""
import glob
import math
import os
import sys
from multiprocessing import Pool

import pyarrow.parquet as pq


def parts(src_dir):
    p = sorted(glob.glob(os.path.join(src_dir, "part_*.parquet")))
    if not p:
        sys.exit(f"no part_*.parquet under {src_dir}")
    return p


def row_groups(src_dir):
    """[(file, row_group_index, num_rows)] across the whole corpus, in order."""
    out = []
    for f in parts(src_dir):
        md = pq.ParquetFile(f).metadata
        for g in range(md.num_row_groups):
            out.append((f, g, md.row_group(g).num_rows))
    return out


def write_shard(task):
    """Write one shard, reading a single row group at a time.

    Reading a shard's whole group range at once materialises ~4.3M very wide
    rows (Body plus three JSON map columns) at ~9GB per worker; sixteen of those
    OOM-kill a 128GB box. One group at a time caps a worker at roughly one
    group, so memory is bounded by workers, not by shard size.
    """
    idx, out_dir, groups = task
    path = os.path.join(out_dir, f"shard_{idx:04d}.parquet")
    writer = None
    rows = 0
    handles = {}
    for f, g, _ in groups:
        pf = handles.get(f) or handles.setdefault(f, pq.ParquetFile(f))
        table = pf.read_row_groups([g])
        if writer is None:
            writer = pq.ParquetWriter(path, table.schema, compression="snappy")
        writer.write_table(table)
        rows += table.num_rows
        del table
    if writer is not None:
        writer.close()
    return rows


def default_workers():
    """One worker per core, capped by RAM.

    write_shard reads a single row group at a time, so a worker peaks at roughly
    one group (~1.3GB on the 1B corpus) rather than a whole shard. Budget 3GB
    each for headroom; the cap only binds on small-memory machines.
    """
    cores = os.cpu_count() or 8
    try:
        ram_gb = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 1024 ** 3
    except (ValueError, OSError):
        return int(os.environ.get("SHARD_WORKERS", cores))
    return int(os.environ.get("SHARD_WORKERS", max(1, min(cores, int(ram_gb // 3)))))


def main():
    src_dir = sys.argv[1]
    groups = row_groups(src_dir)
    if sys.argv[2] == "--count":
        print(sum(n for _, _, n in groups))
        return

    out_dir, nshards = sys.argv[2], int(sys.argv[3])
    workers = int(sys.argv[4]) if len(sys.argv) > 4 else default_workers()
    os.makedirs(out_dir, exist_ok=True)
    for f in glob.glob(os.path.join(out_dir, "*.parquet")):
        os.remove(f)

    per = max(1, math.ceil(len(groups) / nshards))
    chunks = [groups[i:i + per] for i in range(0, len(groups), per)]
    tasks = [(i, out_dir, c) for i, c in enumerate(chunks)]
    total = sum(n for _, _, n in groups)
    print(f"{len(groups)} row groups -> {len(chunks)} shards "
          f"({per} groups each) on {workers} workers", flush=True)

    with Pool(workers) as pool:
        written = sum(pool.imap_unordered(write_shard, tasks))
    if written != total:
        sys.exit(f"ERROR: wrote {written} rows, corpus has {total}")
    print(f"{written} rows -> {len(chunks)} shards in {out_dir}")


if __name__ == "__main__":
    main()
