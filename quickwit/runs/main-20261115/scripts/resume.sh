#!/usr/bin/env bash
# HOST (root, transient unit qw-workload-2). Re-run production only, after attempt 1 failed on the
# data-dir path (lib/benchmark.sh appends the dataset). Setup already passed on this boot (disk, image,
# client, tests: evidence/setup-passed); attempt-1 per-scale evidence kept under evidence/attempt1/.
set -uo pipefail
cd /srv/qw
source ./run.env
source ./remote.env
P=evidence/progress.log
note() { echo "$(date -u +%FT%TZ) $*" | tee -a "$P"; }
[[ -f evidence/setup-passed ]] || { note "resume refused: setup did not pass"; exit 1; }
mkdir -p evidence/attempt1
for f in evidence/otel_logs_* evidence/smoke evidence/failed-scales.txt evidence/df-after-cleanup.txt evidence/production.log; do
  [[ -e $f ]] && mv "$f" evidence/attempt1/
done
rm -rf /mnt/qw/corpus /mnt/qw/qw-* /mnt/qw/corpus-smoke source/quickwit/results/load/*.json
echo running > state
note "attempt 2 (production only, data-dir fix); $(( WORK_CUTOFF_EPOCH - $(date +%s) ))s to cutoff"
python3 ./run_until.py "$WORK_CUTOFF_EPOCH" ./production.sh > evidence/production.log 2>&1
rc=$?
note "production rc=$rc"
echo "$rc" > evidence/production-rc.txt
./collect.sh >> evidence/collect.log 2>&1
note "collected; evidence.tar.gz ready"
echo "done rc=$rc" > state
sleep 600
note "controller did not stop the host within 10 min of done: powering off"
systemctl --no-block poweroff
