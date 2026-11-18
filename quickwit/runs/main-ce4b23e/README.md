# Quickwit main ce4b23e · m8gd.4xlarge · S3 · 100M / 1B

> **Status:** prepared, not run yet.

Quickwit main at commit
[`ce4b23e`](https://github.com/quickwit-oss/quickwit/commit/ce4b23eb52ba063bb72c22adc8226bfd42bc09ca)
(2026-11-17, "Ignore empty and null-only arrays for object fields when mapping documents (#7026)"),
run with the setup of the published Datadog BYOC column
([`runs/hippo-20261105`](../../../runs/hippo-20261105/README.md)): same machine, same storage, same
index and query settings. One box, 100M then 1B.

## Build

No published image contains this commit (the `edge` tag is main `961c871`, 2026-11-09), so `setup.sh`
builds it on the benchmark box, before any measured phase, with the repository's own `Dockerfile` and
the build arguments of its publish workflow: `CARGO_FEATURES=release-feature-set`, release profile,
`QW_COMMIT_HASH`/`QW_COMMIT_DATE`/`QW_COMMIT_TAGS` from the checkout. Setup checks the commit, the
arm64 architecture, the revision label and `quickwit --version` before any load; the smoke test checks
`/api/v1/version` reports the same commit.

## Machine and storage (as Datadog BYOC)

| | |
|---|---|
| Instance | AWS `m8gd.4xlarge`, us-east-1: 16 Graviton4 cores, 64 GiB |
| Index + metastore | S3, same region |
| Local disk | instance-store NVMe (~885 GB): corpus, WAL, ingest queue, Docker data root and image build |
| OS | Ubuntu 24.04, Docker, engine containers in a CPU-accounting slice |

## Settings (as Datadog BYOC, both scales)

| | |
|---|---|
| Ingest | native ingest API, Rust client, 16 processes, 2,000 docs/request |
| Shards | `min_shards` 48, `shard_throughput_limit` 20mb |
| Indexing | commit 30 s, `split_num_docs_target` 10M, `stable_log` merges, validation off |
| Ingest queue | 32 GiB memory, 80 GiB disk |
| In-memory indexing | on |
| Document clustering | on |
| Caches | fast field, partial request and predicate caches off; split footer cache at its default |
| Queries | 3 rounds; per round 3 tries per query (cold, hot, hot), engine restart + `drop_caches` before every query, 60 s cap |

## Run

`scripts/` is the control plane (`provision.sh`, `connect.sh`, `poll.sh`, `finish.sh`, run locally) and the
host side (`run.sh` → `setup.sh` → `production.sh` → `collect.sh`). Account, bucket, VPC, subnet, AMI and
profile come from `scripts/local.env`, which is not committed. The box has a 14 h hard stop
(EventBridge Scheduler), an OS shutdown timer 5 min earlier and a workload cutoff 20 min earlier.

```sh
cd quickwit/runs/main-ce4b23e/scripts
date -u +%Y%m%dT%H%M%SZ > STAMP
git -C ../../../.. archive --format=tar.gz -o "$PWD/source.tar.gz" HEAD
shasum -a 256 source.tar.gz > source.sha256; git rev-parse HEAD > source.commit
APPROVED_RUN=YES ./provision.sh && ./connect.sh
./poll.sh            # status
./finish.sh          # after "done": fetch evidence, stop, clean up IAM/schedule/SG ingress
```

Results are recorded as separate columns (`Quickwit (main-ce4b23e-s3-r<N>)`), next to the 0.9.0 rows
and the 2026-11-15 `961c871` runs.
