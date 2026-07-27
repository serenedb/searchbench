#!/usr/bin/env bash
# ArangoDB engine entrypoint. Sets engine identity and hands off to the
# shared driver in ../lib/benchmark.sh.
set -e

export ENGINE_NAME="ArangoDB"
export ENGINE_TAGS='["C++","ArangoDB","IResearch"]'

# Queries are AQL, not SQL, so override the driver's default (queries.sql). The
# driver reads one statement per line, skips `--` comment lines, and parses the
# `-- Qnn task=... filter=... freq=...` tag lines. queries.aql is the 92-query
# tagged workload (aligned 1:1 with serenedb/queries.sql).
export SEARCHBENCH_QUERIES="${SEARCHBENCH_QUERIES:-queries.aql}"

exec ../lib/benchmark.sh "$@"
