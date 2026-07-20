#!/usr/bin/env bash
# SereneDB vector entrypoint: set identity + connection, hand off to the shared
# vector driver. Reuses this adapter's existing install/start/stop/check/data-size
# (same Docker image as the text track); adds ./load-vector for ANN index builds.
set -e

export ENGINE_NAME="SereneDB"
export ENGINE_TAGS='["C++","SereneDB","IVF","Postgres-wire"]'
export VECTOR_ENGINE="serenedb"
export VECTOR_TARGET="vec_idx"       # query the index relation -> IVF "Vector KNN" scan
export PGPORT="${PGPORT:-5499}"

exec ../lib/benchmark-vector.sh "$@"
