#!/usr/bin/env bash
# LOCAL. Fetch evidence over the ControlMaster (if alive), stop the exact
# instance, verify STOPPED, then remove the schedule, host/stop roles + profile
# and the SSG ingress rule. EBS volumes and the (empty) SG are retained.
# With expired SSO: poweroff via the master and exit 9 (ask for login, rerun).
set -uo pipefail
cd "$(dirname "$0")"
export AWS_PROFILE=<profile> AWS_REGION=us-east-1 AWS_PAGER=''
RD=resources-${BOX:?BOX must be local or s3}
source $RD/run.env
# Multiplexed only: ProxyCommand=false makes any non-master connection fail.
R() { ssh -S "$SOCK" -O check ubuntu@"$IP" 2>/dev/null && ssh -S "$SOCK" -o ProxyCommand=false -o BatchMode=yes -o ControlMaster=no ubuntu@"$IP" "$@"; }
mkdir -p recovered-$BOX
if [[ "${SKIP_FETCH:-}" != yes && ! -f recovered-$BOX/evidence.tar.gz ]] && [[ -S "$SOCK" ]] && R true 2>/dev/null; then
  R 'cat /srv/qw/state; ls -l /srv/qw/evidence.tar.gz /srv/qw/evidence.tar.gz.sha256' > $RD/fetch-state.txt 2>&1
  scp -o ControlPath="$SOCK" -o ProxyCommand=false -o BatchMode=yes \
    ubuntu@"$IP":/srv/qw/evidence.tar.gz ubuntu@"$IP":/srv/qw/evidence.tar.gz.sha256 recovered-$BOX/ \
    && (cd recovered-$BOX && shasum -a 256 -c evidence.tar.gz.sha256) > $RD/fetch-verify.txt 2>&1 \
    && date -u > $RD/evidence-fetched.txt
fi
if ! aws sts get-caller-identity > $RD/sts-finish.json 2>$RD/sts-finish.err; then
  echo 'SSO expired: powering off via the ControlMaster; rerun finish.sh after aws sso login' >&2
  R 'sudo systemctl --no-block poweroff' > $RD/master-poweroff.txt 2>&1 || true
  date -u >> $RD/master-poweroff.txt
  exit 9
fi
set -e
aws ec2 stop-instances --instance-ids "$IID" > $RD/stop.json
aws ec2 wait instance-stopped --instance-ids "$IID"
aws ec2 describe-instances --instance-ids "$IID" > $RD/final-instance.json
jq -e '.Reservations[0].Instances[0].State.Name=="stopped"' $RD/final-instance.json
date -u > $RD/stopped-verified.txt
set +e
errors=$RD/cleanup-errors.txt; : > "$errors"
try() { "$@" >> $RD/cleanup.log 2>&1 || echo "FAILED: $*" >> "$errors"; }
# Data volume (3,000 GiB gp3 at 20k IOPS / 625 MiB/s, ~$7.50/day): detach and delete once the instance is stopped
# and the evidence is on S3 (DeleteOnTermination only applies to a terminate). The root volume is retained.
if [[ -n "${DATA_VOL:-}" ]] && aws ec2 describe-volumes --volume-ids "$DATA_VOL" > $RD/data-volume-final.json 2>/dev/null \
   && jq -e --arg n "$N" '.Volumes[0].Tags[] | select(.Key=="SearchbenchRun" and .Value==$n)' $RD/data-volume-final.json >/dev/null; then
  try aws ec2 detach-volume --volume-id "$DATA_VOL"
  try aws ec2 wait volume-available --volume-ids "$DATA_VOL"
  try aws ec2 delete-volume --volume-id "$DATA_VOL"
fi
try aws scheduler delete-schedule --name "$N-stop"
ASSOC=$(aws ec2 describe-iam-instance-profile-associations --filters "Name=instance-id,Values=$IID" \
  --query 'IamInstanceProfileAssociations[0].AssociationId' --output text)
[[ -z "$ASSOC" || "$ASSOC" == None ]] || try aws ec2 disassociate-iam-instance-profile --association-id "$ASSOC"
try aws iam remove-role-from-instance-profile --instance-profile-name "$N-host" --role-name "$N-host"
try aws iam delete-instance-profile --instance-profile-name "$N-host"
try aws iam delete-role-policy --role-name "$N-host" --policy-name owned-corpus-data-evidence
try aws iam delete-role --role-name "$N-host"
try aws iam delete-role-policy --role-name "$N-stop" --policy-name exact-owned-instance
try aws iam delete-role --role-name "$N-stop"
try aws ec2 revoke-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "$SOURCE_IP/32"
# Verification: every removed resource must now be absent.
{
  aws scheduler get-schedule --name "$N-stop" >/dev/null 2>&1 && echo "schedule still present"
  aws iam get-role --role-name "$N-host" >/dev/null 2>&1 && echo "host role still present"
  aws iam get-role --role-name "$N-stop" >/dev/null 2>&1 && echo "stop role still present"
  aws iam get-instance-profile --instance-profile-name "$N-host" >/dev/null 2>&1 && echo "profile still present"
  [[ $(aws ec2 describe-security-groups --group-ids "$SG" --query 'length(SecurityGroups[0].IpPermissions)' --output text) == 0 ]] \
    || echo "SG ingress still present"
} >> "$errors"
aws ec2 describe-security-groups --group-ids "$SG" > $RD/final-sg.json
aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$IID" > $RD/final-volumes.json
aws ec2 describe-instances --instance-ids "$IID" > $RD/final-instance.json
aws s3api list-objects-v2 --bucket <bucket> --prefix "$S3_PREFIX" > $RD/final-s3.json
[[ -S "$SOCK" ]] && ssh -S "$SOCK" -O exit ubuntu@"$IP" 2>/dev/null
if [[ -s "$errors" ]]; then cat "$errors"; exit 1; fi
date -u > $RD/access-cleanup-completed.txt
echo "stopped and cleaned up (data volume deleted); retained: root EBS volume and empty SG $SG"
