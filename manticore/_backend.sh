# Manticore Search adapter env defaults. Sourced (not executed).

: "${MANTICORE_HTTP_PORT:=9308}"
: "${MANTICORE_IMAGE:=manticoresearch/manticore:latest}"
: "${MANTICORE_CONTAINER:=searchbench-manticore}"
# Data lives in a project-local bind-mount dir (like the other docker engines:
# arango_data/, es-data/, clickhouse_data/, ...), NOT a named docker volume.
# Named volumes live under /var/lib/docker on the small root disk (96G); the
# full-column corpus at 100M/1B needs ~1TB, which only fits on /mnt/data where
# the repo (and every other engine's data dir) already lives.
# NOTE: this default assumes the REPO itself sits on the big disk. Verify that on
# a new host -- if the checkout is on a small root filesystem, this silently puts
# ~38GB (100M) or ~369GB (1B) of index there and the ingest dies partway with
# "No space left on device". Set MANTICORE_DATA_DIR explicitly in that case.
: "${MANTICORE_DATA_DIR:=${PWD}/manticore_data}"
: "${MANTICORE_TABLE:=otel_logs}"

die() { echo "ERROR: $*" >&2; exit 1; }
