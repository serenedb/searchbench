#!/usr/bin/env bash
# HOST (root, transient unit qw-workload). setup -> production (bounded by the
# workload cutoff, which precedes the OS timer and the Scheduler) -> collect.
# run_until.py (not timeout(1)) kills the whole process group at the cutoff.
# Setup or production failure: collect + poweroff (no retry, no relaunch).
# Success: poweroff 10 min after "done" unless the controller stopped it first.
set -uo pipefail
cd /srv/qw
source ./run.env
source ./remote.env
mkdir -p evidence
P=evidence/progress.log
note() { echo "$(date -u +%FT%TZ) $*" | tee -a "$P"; }
echo running > state
note "workload unit started; cutoff $(date -u -d @"$WORK_CUTOFF_EPOCH" +%FT%TZ)"
python3 ./run_until.py "$WORK_CUTOFF_EPOCH" ./setup.sh > evidence/setup.log 2>&1
rc=$?
note "setup rc=$rc"
if [[ $rc -ne 0 ]]; then
  echo "setup-failed rc=$rc" > state
  ./collect.sh >> evidence/collect.log 2>&1
  note "collected; powering off after setup failure"
  echo "setup-failed rc=$rc collected" > state
  systemctl --no-block poweroff
  exit "$rc"
fi
remaining=$(( WORK_CUTOFF_EPOCH - $(date +%s) ))
note "production start; ${remaining}s to cutoff"
python3 ./run_until.py "$WORK_CUTOFF_EPOCH" ./production.sh > evidence/production.log 2>&1
rc=$?
note "production rc=$rc"
echo "$rc" > evidence/production-rc.txt
./collect.sh >> evidence/collect.log 2>&1
note "collected; evidence.tar.gz ready"
echo "done rc=$rc" > state
if [[ $rc -ne 0 ]]; then
  note "production failed: powering off in 10 min unless the controller stops first"
fi
sleep 600
note "controller did not stop the host within 10 min of done: powering off"
systemctl --no-block poweroff
