#!/usr/bin/env bash
# pgvector IVFFlat entrypoint. HNSW and IVFFlat are different ANN algorithms, so
# they run as separate engine identities (distinct results file + UI series).
# Sweep the IVFFlat build param with VECTOR_LISTS (comma list of cell counts).
set -e
source "$(dirname "$0")/common.sh"   # sets + exports PGPORT etc.

export ENGINE_NAME="pgvector (IVFFlat)"
export ENGINE_TAGS='["C","Postgres","pgvector","IVFFlat"]'
export VECTOR_ENGINE="pgvector"
export VECTOR_TARGET="vec"
export VECTOR_PG_INDEX_TYPE="ivfflat"

exec ../lib/benchmark-vector.sh "$@"
