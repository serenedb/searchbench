#!/usr/bin/env bash
# LOCAL. BOX=local|s3 ./poll.sh -- read-only status over the existing ControlMaster (no new authentication).
set -uo pipefail
cd "$(dirname "$0")"
RD=resources-${BOX:?BOX must be local or s3}
source $RD/run.env
ssh -S "$SOCK" -O check ubuntu@"$IP" 2>/dev/null || { echo 'ControlMaster gone: not re-authenticating'; exit 3; }
ssh -S "$SOCK" -o ProxyCommand=false -o BatchMode=yes -o ControlMaster=no ubuntu@"$IP" \
  'date -u; systemctl is-active qw-workload-2.service; cat /srv/qw/state 2>/dev/null; tail -n 15 /srv/qw/evidence/progress.log 2>/dev/null; df -h /mnt/qw 2>/dev/null | tail -1; for f in /srv/qw/evidence/otel_logs_*/load.samples; do [[ -f $f ]] && echo "$f: $(tail -n 1 $f)"; done; for f in /srv/qw/evidence/otel_logs_*/r*/benchmark.log; do [[ -f $f ]] && echo "$f: $(tail -n 1 $f | cut -c1-200)"; done'
python3 -c "import time;print('seconds to workload cutoff:', $WORK_CUTOFF_EPOCH - int(time.time()))"
