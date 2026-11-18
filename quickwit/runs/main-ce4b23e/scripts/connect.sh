#!/usr/bin/env bash
# LOCAL. After provision.sh: wait for SSH, open the ONE ControlMaster, verify
# the OS deadline timer, stage files and start the detached workload unit.
# Any failure stops the exact instance (no authentication retry, no bypass).
set -euo pipefail
cd "$(dirname "$0")"
source ./local.env   # AWS_PROFILE ACCOUNT BUCKET VPC SUBNET AMI SSH_AUTH_SOCK (not committed)
export AWS_PROFILE AWS_REGION=us-east-1 AWS_PAGER='' SSH_AUTH_SOCK
BOX=s3
RD=resources-$BOX
source $RD/run.env
SOCK=/tmp/qwm-$BOX-$TS
stop_on_failure() {
  rc=$?
  trap - EXIT
  if [[ $rc -ne 0 ]]; then
    echo "connect/stage failed rc=$rc: stopping $IID" >&2
    aws ec2 stop-instances --instance-ids "$IID" > $RD/connect-failure-stop.json 2>$RD/connect-failure-stop.err \
      || { [[ -S "$SOCK" ]] && ssh -S "$SOCK" -o ProxyCommand=false -o BatchMode=yes ubuntu@"$IP" 'sudo systemctl --no-block poweroff' || true; }
    date -u > $RD/connect-failed.txt
  fi
  exit "$rc"
}
IP=''
trap stop_on_failure EXIT
aws ec2 wait instance-running --instance-ids "$IID"
aws ec2 describe-instances --instance-ids "$IID" > $RD/running.json
IP=$(jq -er '.Reservations[0].Instances[0].PublicIpAddress' $RD/running.json)
printf 'export IP=%s\nexport SOCK=%s\n' "$IP" "$SOCK" >> $RD/run.env
python3 - "$IP" <<'PY'
import socket, time, sys
for _ in range(90):
    try:
        with socket.create_connection((sys.argv[1], 22), timeout=2):
            break
    except OSError:
        time.sleep(2)
else:
    raise SystemExit('SSH port did not become available')
PY
aws ec2-instance-connect send-ssh-public-key --instance-id "$IID" --availability-zone "$AZ" \
  --instance-os-user ubuntu --ssh-public-key "file://$HOME/.ssh/id_ed25519.pub" > $RD/eic.json
ssh -MNf -o ControlMaster=yes -o ControlPersist=23h -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=15 \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519.pub" \
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$PWD/known_hosts" ubuntu@"$IP"
date -u > $RD/master-opened.txt
R() { ssh -S "$SOCK" -o ProxyCommand=false -o BatchMode=yes -o ControlMaster=no ubuntu@"$IP" "$@"; }
R 'sudo systemctl is-active qw-deadline.timer && sudo systemctl cat qw-deadline.timer && sudo systemctl list-timers --all && sudo mkdir -p /srv/qw/evidence && sudo chown -R ubuntu:ubuntu /srv/qw' > $RD/first-master-os-cap.txt
grep -q "OnCalendar=$OS_DEADLINE UTC" $RD/first-master-os-cap.txt
cp $RD/run.env run.env
cp remote.env remote.staged.env; printf 'export BUCKET=%s\n' "$BUCKET" >> remote.staged.env
scp -o ControlPath="$SOCK" -o ProxyCommand=false -o BatchMode=yes \
  source.tar.gz source.sha256 source.commit run.env run.sh setup.sh production.sh collect.sh run_until.py ubuntu@"$IP":/srv/qw/
scp -o ControlPath="$SOCK" -o ProxyCommand=false -o BatchMode=yes remote.staged.env ubuntu@"$IP":/srv/qw/remote.env
# Detached root unit: survives local sleep/SSH loss; host timer still caps it.
R 'sudo bash -c "cd /srv/qw && chmod +x ./*.sh && systemd-run --unit=qw-workload --description=\"Quickwit main ce4b23e $BOX workload\" --property=KillMode=control-group /srv/qw/run.sh"' > $RD/workload-started.txt 2>&1
R 'sudo systemctl is-active qw-workload.service || sudo systemctl status --no-pager qw-workload.service' >> $RD/workload-started.txt 2>&1
date -u >> $RD/workload-started.txt
trap - EXIT
echo "workload unit started on $IID ($IP); poll with ./poll.sh"
