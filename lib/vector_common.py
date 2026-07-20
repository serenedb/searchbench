#!/usr/bin/env python3
"""SearchBench vector track — shared dataset registry, loaders, and ground truth.

This is the vector counterpart to the text track's data plumbing helpers
(lib/slice_parquet.py etc.): the bash driver (lib/benchmark-vector.sh) and the
ingest/query helpers (lib/vector_ingest.py, lib/vector_query.py) all import it.

It carries:
  * DATASETS       — the 3x3 (distance x size-tier) registry, single source of truth.
  * read_fbin/read_ibin/read_hdf5 — the on-disk formats (memmap-sliced, big files
    never fully materialize).
  * Dataset        — base vectors + query vectors + exact-KNN ground truth + metric.
  * compute_gt     — exact top-k ground truth for l2 | ip | cosine (cached).
  * load_dataset   — resolve files under a data dir -> Dataset, with the same
    "refuse instead of lying about recall" guards the reference harness uses.

Metrics: "l2" (euclidean), "ip" (max inner product), "cosine" (angular). Ids are
0-based so they line up with big-ann / ann-benchmarks ground-truth ids.

CLI (used by bash so the registry stays the one source of truth):
    python3 vector_common.py meta <key>        # -> one-line JSON of the dataset spec
    python3 vector_common.py list              # -> all keys, one per line
    python3 vector_common.py selftest          # -> exercises GT + recall math (needs numpy)
"""

import glob
import json
import os
import sys

# numpy is required for every real path (loaders, GT). Import lazily inside the
# functions that need it so `meta`/`list` work on a machine without numpy (the
# bash driver calls `meta` to read the registry before any heavy deps exist).


# ---------------------------------------------------------------------------
# Registry: distance x size-tier -> dataset spec. THE single source of truth;
# lib/download-vectors and the driver read it via the `meta` CLI below.
#
# Fields:
#   distance   l2 | ip | cosine        (also the SereneDB index `metric` and the
#                                        per-metric query operator)
#   tier       small | medium | giant | smoke
#   dim        vector dimension
#   nb         base vectors to load (a subset slice of the published set)
#   nq         query vectors
#   fmt        hdf5 | fbin | hf | synthetic
#   files      per-format filename globs (base/query/gt) resolved under the data dir
#   source     human note / URL(s) for lib/download-vectors
#   opt_in     giant tier: wired but not fetched by default runs
#   gt_in_file whether ground truth ships with the data (else recompute + cache)
# ---------------------------------------------------------------------------
_ANN = "https://ann-benchmarks.com"

DATASETS = {
    # ---- Cosine ----------------------------------------------------------
    "glove_cosine_small": {
        "distance": "cosine", "tier": "small", "dim": 100, "nb": 1183514, "nq": 10000,
        "fmt": "hdf5", "gt_in_file": True,
        "files": {"hdf5": ["glove-100-angular.hdf5"]},
        "source": f"{_ANN}/glove-100-angular.hdf5",
    },
    "dbpedia_cosine_medium": {
        # ~3M x 1536d ~= 18 GB, targeting the 10-20 GB medium band. Needs a >=3M
        # dbpedia-openai (text-embedding, 1536d) corpus (the common release is 1M) --
        # set VECTOR_SOURCE_URI / drop the parquet(s) in the data dir. GT recomputed
        # for the exact 3M slice.
        "distance": "cosine", "tier": "medium", "dim": 1536, "nb": 3000000, "nq": 10000,
        "fmt": "hf", "gt_in_file": False,
        "files": {"parquet": ["*.parquet"]},
        "source": "HuggingFace dbpedia-openai (>=3M, 1536d) parquet — confirm exact repo (open item)",
    },
    "cohere_cosine_giant": {
        "distance": "cosine", "tier": "giant", "dim": 768, "nb": 35000000, "nq": 10000,
        "fmt": "hf", "gt_in_file": False, "opt_in": True,
        "files": {"parquet": ["*.parquet"]},
        "source": "HuggingFace Cohere/wikipedia-22-12 (en, 768d) parquet",
    },
    # ---- L2 (euclidean) --------------------------------------------------
    "gist_l2_small": {
        "distance": "l2", "tier": "small", "dim": 960, "nb": 1000000, "nq": 1000,
        "fmt": "hdf5", "gt_in_file": True,
        "files": {"hdf5": ["gist-960-euclidean.hdf5"]},
        "source": f"{_ANN}/gist-960-euclidean.hdf5",
    },
    "deep_l2_medium": {
        # ~40M subset of Deep1B (96d). Official GT is for standard sizes only, so
        # GT is recomputed + cached for the 40M slice.
        "distance": "l2", "tier": "medium", "dim": 96, "nb": 40000000, "nq": 10000,
        "fmt": "fbin", "gt_in_file": False,
        "files": {"base": ["base*.fbin", "*base*fbin*"],
                  "query": ["query*.fbin", "*quer*fbin*"],
                  "gt": ["groundtruth*.ibin", "gt*.ibin", "*gt*.ibin"]},
        "source": "big-ann-benchmarks Deep1B (deep-1B .fbin); slice 40M, recompute GT",
    },
    "deep_l2_giant": {
        "distance": "l2", "tier": "giant", "dim": 96, "nb": 1000000000, "nq": 10000,
        "fmt": "fbin", "gt_in_file": True, "opt_in": True,
        "files": {"base": ["base*.fbin", "*base*fbin*"],
                  "query": ["query*.fbin", "*quer*fbin*"],
                  "gt": ["groundtruth*.ibin", "gt*.ibin", "*gt*.ibin"]},
        "source": "big-ann-benchmarks Deep1B (official 1B GT)",
    },
    # ---- IP (max inner product) -----------------------------------------
    "t2i_ip_small": {
        "distance": "ip", "tier": "small", "dim": 200, "nb": 1000000, "nq": 10000,
        "fmt": "fbin", "gt_in_file": False,
        "files": {"base": ["base*.fbin", "*base*fbin*"],
                  "query": ["query.public*fbin*", "query*.fbin", "*quer*fbin*"],
                  "gt": ["groundtruth*.ibin", "gt*.ibin", "*gt*.ibin"]},
        "source": "big-ann-benchmarks text2image (.fbin); slice 1M, recompute GT",
    },
    "t2i_ip_medium": {
        "distance": "ip", "tier": "medium", "dim": 200, "nb": 10000000, "nq": 10000,
        "fmt": "fbin", "gt_in_file": True,
        "files": {"base": ["base*.fbin", "*base*fbin*"],
                  "query": ["query.public*fbin*", "query*.fbin", "*quer*fbin*"],
                  "gt": ["*text2image-10M*", "groundtruth*.ibin", "gt*.ibin", "*gt*.ibin"]},
        "source": "big-ann-benchmarks text2image-10M (official GT)",
    },
    "t2i_ip_giant": {
        "distance": "ip", "tier": "giant", "dim": 200, "nb": 100000000, "nq": 10000,
        "fmt": "fbin", "gt_in_file": True, "opt_in": True,
        "files": {"base": ["base*.fbin", "*base*fbin*"],
                  "query": ["query.public*fbin*", "query*.fbin", "*quer*fbin*"],
                  "gt": ["*text2image-100M*", "groundtruth*.ibin", "gt*.ibin", "*gt*.ibin"]},
        "source": "big-ann-benchmarks text2image-100M (official GT)",
    },
    # ---- Smoke (offline, synthetic; no download) -------------------------
    "synthetic": {
        "distance": "ip", "tier": "smoke", "dim": 32, "nb": 20000, "nq": 200,
        "fmt": "synthetic", "gt_in_file": False,
        "files": {}, "source": "generated in-process (no download)",
    },
}


def meta(key):
    if key not in DATASETS:
        raise KeyError(f"unknown vector dataset {key!r}; known: {', '.join(sorted(DATASETS))}")
    m = dict(DATASETS[key])
    m["key"] = key
    return m


# ---------------------------------------------------------------------------
# On-disk formats
# ---------------------------------------------------------------------------
def read_fbin(path, count=None, offset=0):
    """big-ann .fbin: int32 nvecs, int32 dim, then float32 data (memmap-sliced)."""
    import numpy as np
    with open(path, "rb") as f:
        n, dim = np.fromfile(f, dtype=np.int32, count=2)
    n, dim = int(n), int(dim)
    if count is None or count > n - offset:
        count = n - offset
    arr = np.memmap(path, dtype=np.float32, mode="r",
                    offset=8 + offset * dim * 4, shape=(count, dim))
    return arr, dim


def read_ibin(path, count=None):
    """big-ann .ibin ground-truth ids: int32 n, int32 k, then int32 ids."""
    import numpy as np
    with open(path, "rb") as f:
        n, k = np.fromfile(f, dtype=np.int32, count=2)
    n, k = int(n), int(k)
    if count is None or count > n:
        count = n
    ids = np.memmap(path, dtype=np.int32, mode="r", offset=8, shape=(n, k))[:count]
    return np.asarray(ids, dtype=np.int64)


# ann-benchmarks HDF5 `distance` attribute -> our metric name.
_HDF5_DISTANCE = {"angular": "cosine", "cosine": "cosine",
                  "euclidean": "l2", "l2": "l2",
                  "dot": "ip", "ip": "ip"}


def read_hdf5(path):
    """ann-benchmarks HDF5: datasets 'train' (base), 'test' (queries),
    'neighbors' (top-k GT ids), and a 'distance' attr. Returns
    (base, queries, neighbors, metric)."""
    import numpy as np
    try:
        import h5py
    except ImportError as e:  # pragma: no cover - env-dependent
        raise RuntimeError("read_hdf5 needs h5py (pip install h5py)") from e
    with h5py.File(path, "r") as f:
        base = np.asarray(f["train"], dtype=np.float32)
        queries = np.asarray(f["test"], dtype=np.float32)
        neighbors = np.asarray(f["neighbors"], dtype=np.int64) if "neighbors" in f else None
        dist_attr = f.attrs.get("distance", "euclidean")
        if isinstance(dist_attr, bytes):
            dist_attr = dist_attr.decode()
    metric = _HDF5_DISTANCE.get(str(dist_attr).lower())
    if metric is None:
        raise ValueError(f"unknown HDF5 distance attr {dist_attr!r} in {path}")
    return base, queries, neighbors, metric


# ---------------------------------------------------------------------------
# Exact ground truth (per metric)
# ---------------------------------------------------------------------------
def compute_gt(base, queries, k, metric, batch=64):
    """Exact top-k neighbor ids per query (0-based), for l2 | ip | cosine.

    Ranking reduces to a top-k over a per-query score, computed in query
    batches so a big base never fans out to a full (nb x nq) matrix:
      ip     -> largest inner product           score = base . q
      cosine -> largest cosine similarity        score = norm(base) . norm(q)
      l2     -> smallest euclidean distance      score = 2*base.q - ||base||^2
                (drops the per-query ||q||^2 constant; argmax(score) == argmin dist)
    """
    import numpy as np
    base = np.asarray(base, dtype=np.float32)
    queries = np.asarray(queries, dtype=np.float32)
    nb, nq = base.shape[0], queries.shape[0]
    k = min(k, nb)

    base_norm = qset = None
    base_sq = None
    if metric == "cosine":
        bn = np.linalg.norm(base, axis=1, keepdims=True)
        bn[bn == 0] = 1.0
        base_norm = base / bn
        qn = np.linalg.norm(queries, axis=1, keepdims=True)
        qn[qn == 0] = 1.0
        qset = queries / qn
    elif metric == "l2":
        base_sq = np.einsum("ij,ij->i", base, base).astype(np.float32)

    out = np.empty((nq, k), dtype=np.int64)
    for start in range(0, nq, batch):
        if metric == "cosine":
            qb = qset[start:start + batch]
            scores = base_norm @ qb.T
        elif metric == "l2":
            qb = queries[start:start + batch]
            scores = 2.0 * (base @ qb.T) - base_sq[:, None]
        else:  # ip
            qb = queries[start:start + batch]
            scores = base @ qb.T
        part = np.argpartition(-scores, kth=k - 1, axis=0)[:k]  # (k, bq)
        for j in range(part.shape[1]):
            idx = part[:, j]
            out[start + j] = idx[np.argsort(-scores[idx, j])]
    return out


# ---------------------------------------------------------------------------
# Dataset
# ---------------------------------------------------------------------------
class Dataset:
    def __init__(self, key, base, queries, gt, metric, dim):
        import numpy as np
        self.key = key
        self.base = base
        self.queries = np.ascontiguousarray(queries, dtype=np.float32)
        self.gt = gt
        self.metric = metric
        self.dim = dim

    @property
    def nb(self):
        return int(self.base.shape[0])

    @property
    def nq(self):
        return int(self.queries.shape[0])

    def ids(self):
        import numpy as np
        return np.arange(self.nb, dtype=np.int64)

    def gt_list(self):
        return [row.tolist() for row in self.gt]


def _find_one(data_dir, patterns, what):
    for pat in patterns:
        hits = sorted(glob.glob(os.path.join(data_dir, pat)))
        if hits:
            return hits[0]
    raise FileNotFoundError(
        f"could not find {what} in {data_dir} (looked for {patterns})")


def _gt_cache_path(data_dir, nb, nq, k, metric):
    return os.path.join(data_dir, f"gt_cache_nb{nb}_nq{nq}_k{k}_{metric}.npy")


def _resolve_gt(data_dir, base, queries, k, metric, gt_file, gt_in_file):
    """Ground truth for the loaded slice, with the reference harness's two
    correctness guards. Returns an (nq, k) int64 array."""
    import numpy as np
    nb_eff = int(base.shape[0])
    nq = int(queries.shape[0])

    if gt_in_file and gt_file is not None:
        gt_full = read_ibin(gt_file, count=nq)
        if k > gt_full.shape[1]:
            raise SystemExit(
                f"GT file {os.path.basename(gt_file)} has only {gt_full.shape[1]} "
                f"neighbors/query but k={k}. Use a smaller k or omit the GT file to "
                f"recompute exact GT at k={k}.")
        gt = np.asarray(gt_full[:, :k])
        # The official GT indexes the full published slice. If we loaded fewer base
        # vectors, those neighbor ids aren't present and recall collapses to ~nb/base
        # -- refuse instead of reporting a meaningless number.
        if gt.size and int(gt.max()) >= nb_eff:
            raise SystemExit(
                f"GT file {os.path.basename(gt_file)} references neighbor ids up to "
                f"{int(gt.max())} but only nb={nb_eff} base vectors were loaded. This "
                f"GT was computed over a larger base, so recall would be meaningless. "
                f"Load the full published slice, or recompute GT over your subset.")
        return gt

    cache = _gt_cache_path(data_dir, nb_eff, nq, k, metric)
    if os.path.exists(cache):
        return np.load(cache)
    gt = compute_gt(base, queries, k, metric)
    try:
        np.save(cache, gt)
    except OSError:
        pass
    return gt


def load_dataset(key, data_dir, nb=None, nq=None, k=10, gt_file=None,
                 base_file=None, query_file=None, seed=0, with_gt=True):
    """Resolve the registry entry's files under `data_dir` into a Dataset.

    `nb`/`nq` override the registry defaults (slice the published set). HDF5
    ships its own GT (metric comes from the file's `distance` attr); big-ann
    fbin uses official GT when present and it fits the slice, else recomputes;
    hf/parquet and synthetic always compute GT.

    `with_gt=False` skips ground-truth resolution entirely (the ingest step
    only needs base vectors; recomputing GT for a 40M slice is not free).
    """
    import numpy as np
    spec = meta(key)
    metric = spec["distance"]
    want_nb = nb or spec.get("nb")
    want_nq = nq or spec.get("nq")
    fmt = spec["fmt"]

    if fmt == "synthetic":
        rng = np.random.default_rng(seed)
        base = rng.standard_normal((want_nb, spec["dim"]), dtype=np.float32)
        queries = rng.standard_normal((want_nq, spec["dim"]), dtype=np.float32)
        gt = compute_gt(base, queries, k, metric) if with_gt else None
        return Dataset(key, base, queries, gt, metric, spec["dim"])

    if fmt == "hdf5":
        path = base_file or _find_one(data_dir, spec["files"]["hdf5"], f"{key} HDF5")
        base_full, queries_full, neighbors, file_metric = read_hdf5(path)
        metric = file_metric  # trust the file's declared distance
        base = base_full[:want_nb] if want_nb else base_full
        queries = queries_full[:want_nq] if want_nq else queries_full
        nb_eff = int(base.shape[0])
        gt = None
        if with_gt:
            if neighbors is not None and neighbors.shape[1] >= k and \
                    (not want_nb or want_nb >= base_full.shape[0]):
                gt = np.asarray(neighbors[:queries.shape[0], :k])
                if gt.size and int(gt.max()) >= nb_eff:
                    gt = _resolve_gt(data_dir, base, queries, k, metric, None, False)
            else:
                gt = _resolve_gt(data_dir, base, queries, k, metric, None, False)
        return Dataset(key, base, queries, gt, metric, int(base.shape[1]))

    if fmt == "fbin":
        bpath = base_file or _find_one(data_dir, spec["files"]["base"], f"{key} base")
        qpath = query_file or _find_one(data_dir, spec["files"]["query"], f"{key} queries")
        base, dim = read_fbin(bpath, count=want_nb)
        queries, _ = read_fbin(qpath, count=want_nq)
        queries = np.ascontiguousarray(queries, dtype=np.float32)
        gt = None
        if with_gt:
            gtp = gt_file
            if gtp is None and spec.get("gt_in_file"):
                try:
                    gtp = _find_one(data_dir, spec["files"]["gt"], f"{key} gt")
                except FileNotFoundError:
                    gtp = None
            gt = _resolve_gt(data_dir, base, queries, k, metric,
                             gtp, gt_in_file=gtp is not None)
        return Dataset(key, base, queries, gt, metric, dim)

    if fmt == "hf":
        # Staged locally as parquet (id, emb). Reuse pyarrow (already a repo dep).
        import pyarrow.parquet as pq
        path = base_file or _find_one(data_dir, spec["files"]["parquet"], f"{key} parquet")
        table = pq.read_table(path)
        emb_col = "emb" if "emb" in table.column_names else table.column_names[-1]
        base = np.asarray(table.column(emb_col).to_pylist(), dtype=np.float32)
        if want_nb:
            base = base[:want_nb]
        rng = np.random.default_rng(seed)
        qidx = np.sort(rng.choice(base.shape[0],
                                  size=min(want_nq or 10000, base.shape[0]), replace=False))
        queries = base[qidx]
        gt = _resolve_gt(data_dir, base, queries, k, metric, None, False) if with_gt else None
        return Dataset(key, base, queries, gt, metric, int(base.shape[1]))

    raise ValueError(f"unhandled format {fmt!r} for dataset {key!r}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _selftest():
    """Exercise GT + recall math on tiny arrays (needs numpy)."""
    import numpy as np
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import vector_metrics as m
    base = np.array([[1, 0], [0, 1], [0.9, 0.1], [-1, 0]], dtype=np.float32)
    q = np.array([[1, 0]], dtype=np.float32)
    ip = compute_gt(base, q, k=2, metric="ip")[0].tolist()
    l2 = compute_gt(base, q, k=2, metric="l2")[0].tolist()
    cos = compute_gt(base, q, k=2, metric="cosine")[0].tolist()
    assert ip[0] == 0 and l2[0] == 0 and cos[0] == 0, (ip, l2, cos)
    r = m.recall_at_k([[0, 2, 1]], [[0, 1]], k=2)
    assert abs(r - 0.5) < 1e-9, r
    print("selftest OK:", {"ip": ip, "l2": l2, "cosine": cos, "recall@2": r})


def main(argv):
    try:
        return _main(argv)
    except KeyError as e:
        print(str(e).strip('"'), file=sys.stderr)
        return 1


def _main(argv):
    if not argv:
        print(__doc__.strip().splitlines()[0]); return 2
    cmd = argv[0]
    if cmd == "list":
        for k in sorted(DATASETS):
            print(k)
        return 0
    if cmd == "meta":
        if len(argv) < 2:
            print("usage: vector_common.py meta <key>", file=sys.stderr); return 2
        print(json.dumps(meta(argv[1])))
        return 0
    if cmd == "haslocal":
        # exit 0 if base/parquet files for <key> are present under <dir>, else 3.
        if len(argv) < 3:
            print("usage: vector_common.py haslocal <key> <dir>", file=sys.stderr); return 2
        spec = meta(argv[1])
        pats = (spec.get("files") or {})
        need = pats.get("base") or pats.get("parquet") or []
        found = any(glob.glob(os.path.join(argv[2], p)) for p in need)
        return 0 if found else 3
    if cmd == "selftest":
        _selftest()
        return 0
    print(f"unknown command {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
