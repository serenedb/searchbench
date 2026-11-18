#!/usr/bin/env bash
# HOST (root, transient unit qw-workload-2). Second production pass, same box, after the first pass was
# stopped at the start of 1B: storage_cache 0/0 (remote.env QW_STORAGE_CACHE). Re-queries the 100M S3
# index (load reused, rounds under otel_logs_100m-sc0/), then loads and queries 1B. The first pass's 100M
# rounds (default 500 MB storage cache) stay in otel_logs_100m/. Then collect, poweroff as run.sh.
set -uo pipefail
cd /srv/qw
source ./run.env
source ./remote.env
P=evidence/progress.log
note() { echo "$(date -u +%FT%TZ) $*" | tee -a "$P"; }
echo running-2 > state
sha256sum source/quickwit/start production.sh remote.env > evidence/pass2-files.sha256
note "pass 2 start (QW_STORAGE_CACHE=$QW_STORAGE_CACHE); cutoff $(date -u -d @"$WORK_CUTOFF_EPOCH" +%FT%TZ)"
SKIP_SMOKE=yes REUSE_LOAD_SCALES=otel_logs_100m EVIDENCE_SUFFIX=-sc0 \
  python3 ./run_until.py "$WORK_CUTOFF_EPOCH" ./production.sh > evidence/production-2.log 2>&1
rc=$?
note "pass 2 production rc=$rc"
echo "$rc" > evidence/production-2-rc.txt
./collect.sh >> evidence/collect.log 2>&1
note "collected; evidence.tar.gz ready"
echo "done rc=$rc" > state
sleep 600
note "controller did not stop the host within 10 min of done: powering off"
systemctl --no-block poweroff
