#!/usr/bin/env bash
# HOST. Bounded best-effort evidence capture; never re-runs workload steps.
set -u
cd /srv/qw
source ./run.env
source ./remote.env
E=/srv/qw/evidence
mkdir -p $E/host
(date -u; uptime; free -b; df -h; lsblk; systemctl list-timers --all) > $E/host/host-final.txt 2>&1
journalctl -u qw-workload -u qw-deadline.timer -u docker --no-pager > $E/host/services-journal.txt 2>&1
cp /var/log/cloud-init-output.log $E/host/ 2>/dev/null || true
cp /etc/docker/daemon.json /etc/systemd/system/searchbench.slice $E/host/ 2>/dev/null || true
for c in $(docker ps -aq 2>/dev/null); do
  n=$(docker inspect -f '{{.Name}}' "$c" | tr -d /)
  timeout 30 docker logs --timestamps "$c" 2>&1 | tail -n 20000 > "$E/host/$n.log" || true
  timeout 200 docker stop --time 120 "$c" >/dev/null 2>&1 || true
done
if [[ $BOX == s3 ]]; then
  timeout 300 aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$DATA_PREFIX" --query 'Contents[].[Key,Size]' \
    --output json > $E/host/s3-inventory-final.json 2>$E/host/s3-inventory-final.err || true
fi
find $E -type f ! -name SHA256SUMS -exec sha256sum '{}' + > $E/SHA256SUMS
tar czf evidence.tar.gz evidence ./*.sh ./*.py ./*.env source.sha256 source.commit 2>/dev/null
sha256sum evidence.tar.gz > evidence.tar.gz.sha256
timeout 900 aws s3 cp --only-show-errors evidence.tar.gz "s3://$BUCKET/${S3_PREFIX}evidence.tar.gz" > $E/upload.log 2>&1 || true
timeout 20 aws s3 cp --only-show-errors evidence.tar.gz.sha256 "s3://$BUCKET/${S3_PREFIX}evidence.tar.gz.sha256" >> $E/upload.log 2>&1 || true
