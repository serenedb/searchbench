#!/usr/bin/env python3
"""Stream a row-limited prefix of a parquet file to a local parquet.

Used by lib/download-otel-logs for smoke scales: read only the row groups needed
to reach <rows> (HTTP byte-range when SOURCE is a URL), slicing the final group
for exactly <rows>. Schema preserved verbatim so engines read it like a real part.

    slice_parquet.py SOURCE --rows N --out PATH   # write first N rows of SOURCE
    slice_parquet.py SOURCE --count               # print SOURCE's row count

SOURCE is an http(s) URL or a local path. Requires pyarrow + requests.
"""
import argparse
import sys

import pyarrow.parquet as pq


class HttpRangeFile:
    """Minimal seekable, read-only file backed by HTTP byte-range requests.

    pyarrow reads only the footer + requested row-group byte ranges, so this
    fetches just those bytes, never the whole file.
    """

    def __init__(self, url):
        import requests
        self.url = url
        self.s = requests.Session()
        self.bytes_read = 0
        r = self.s.head(url, allow_redirects=True, timeout=60)
        r.raise_for_status()
        size = r.headers.get("Content-Length")
        if size is None:
            # No length on HEAD; get one byte, read total from Content-Range
            r = self.s.get(url, headers={"Range": "bytes=0-0"}, timeout=60)
            r.raise_for_status()
            size = r.headers["Content-Range"].split("/")[-1]
        self.size = int(size)
        self.pos = 0

    def seek(self, offset, whence=0):
        self.pos = (offset if whence == 0
                    else self.pos + offset if whence == 1
                    else self.size + offset)
        return self.pos

    def tell(self):
        return self.pos

    def read(self, n=-1):
        end = (self.size if n is None or n < 0 else min(self.pos + n, self.size)) - 1
        if self.pos > end:
            return b""
        r = self.s.get(self.url, headers={"Range": f"bytes={self.pos}-{end}"},
                       timeout=300)
        r.raise_for_status()
        data = r.content
        self.pos += len(data)
        self.bytes_read += len(data)
        return data

    def readable(self): return True
    def seekable(self): return True
    def writable(self): return False
    def close(self): self.s.close()

    @property
    def closed(self): return False


def open_source(source):
    if source.startswith(("http://", "https://")):
        return HttpRangeFile(source)
    return open(source, "rb")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="http(s) URL or local path of the parquet")
    ap.add_argument("--rows", type=int, help="number of rows to write")
    ap.add_argument("--out", help="output parquet path")
    ap.add_argument("--count", action="store_true",
                    help="print the source's total row count and exit")
    args = ap.parse_args()

    src = open_source(args.source)
    pf = pq.ParquetFile(src)

    if args.count:
        print(pf.metadata.num_rows)
        return

    if args.rows is None or not args.out:
        ap.error("--rows and --out are required unless --count is given")

    total = pf.metadata.num_rows
    if args.rows > total:
        sys.exit(f"requested {args.rows} rows but source has only {total}")

    writer = None
    written = 0
    try:
        for rg in range(pf.num_row_groups):
            tbl = pf.read_row_group(rg)
            if written + tbl.num_rows > args.rows:
                tbl = tbl.slice(0, args.rows - written)
            if writer is None:
                writer = pq.ParquetWriter(args.out, tbl.schema)
            writer.write_table(tbl)
            written += tbl.num_rows
            if written >= args.rows:
                break
    finally:
        if writer is not None:
            writer.close()

    fetched = getattr(src, "bytes_read", None)
    note = f", fetched {fetched/1e6:.0f} MB" if fetched is not None else ""
    print(f"wrote {written} rows -> {args.out}{note}", file=sys.stderr)


if __name__ == "__main__":
    main()
