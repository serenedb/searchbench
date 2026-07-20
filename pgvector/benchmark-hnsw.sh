#!/usr/bin/env bash
# pgvector HNSW entrypoint. HNSW and IVFFlat are different ANN algorithms, so
# they run as separate engine identities (distinct results file + UI series).
# Sweep HNSW build params with VECTOR_HNSW_M / VECTOR_EF_CONSTRUCTION.
set -e
source "$(dirname "$0")/common.sh"   # sets + exports PGPORT etc.

export ENGINE_NAME="pgvector (HNSW)"
export ENGINE_TAGS='["C","Postgres","pgvector","HNSW"]'
export VECTOR_ENGINE="pgvector"
export VECTOR_TARGET="vec"
export VECTOR_PG_INDEX_TYPE="hnsw"

exec ../lib/benchmark-vector.sh "$@"
