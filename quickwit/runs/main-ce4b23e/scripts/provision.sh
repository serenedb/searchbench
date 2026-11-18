#!/usr/bin/env bash
# LOCAL macOS control plane. ./provision.sh -- ONE owned launch; never relaunch.
# Quickwit main ce4b23e on S3, 100M then 1B, on one m8gd.4xlarge: the machine, storage and settings of the
# published Datadog BYOC run (runs/hippo-20261105). Instance-store NVMe holds the corpus, the WAL and the
# image build; the index and metastore live on S3.
# SG (current /32 SSH only), host role/profile (corpus read, evidence-prefix write, own Quickwit data prefix),
# scheduler stop role, one-shot EventBridge Scheduler StopInstances at launch+14h; OS shutdown timer at
# RunInstances+13h55, workload cutoff RunInstances+13h40.
# Account, bucket, VPC, subnet, AMI, profile and agent socket come from local.env (not committed).
set -euo pipefail
cd "$(dirname "$0")"
[[ "${APPROVED_RUN:-}" == YES ]] || { echo 'approval required'; exit 1; }
source ./local.env   # AWS_PROFILE ACCOUNT BUCKET VPC SUBNET AMI SSH_AUTH_SOCK
export AWS_PROFILE AWS_REGION=us-east-1 AWS_PAGER='' SSH_AUTH_SOCK
BOX=s3
INSTANCE_TYPE=m8gd.4xlarge
HOURS=14
R=resources-$BOX
mkdir -p "$R/preflight"
[[ ! -e $R/launch-attempted ]] || { echo 'never relaunch: reconcile persisted client token/tag'; exit 1; }
[[ ! -e $R/run.env ]] || { echo "$R/run.env exists: provisioning already started"; exit 1; }
[[ $(aws sts get-caller-identity --query Account --output text) == "$ACCOUNT" ]]
ssh-add -T "$HOME/.ssh/id_ed25519.pub"
curl -fsS -o $R/preflight/source-ip.txt https://checkip.amazonaws.com
IP_SRC=$(tr -d '\n' < $R/preflight/source-ip.txt)
[[ "$IP_SRC" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
TS=$(tr -d '\n' < STAMP)
[[ "$TS" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
N=sb-qwce4b-$TS
PREFIX=searchbench/artifacts/quickwit-main-ce4b23e-$TS/
DATA_PREFIX=searchbench/quickwit-main-ce4b23e/$TS/
(( ${#N} + 5 <= 64 ))
# Benchmark source (git archive of this branch) must be in place and match its hash.
[[ -f source.tar.gz && $(shasum -a 256 source.tar.gz | awk '{print $1}') == $(awk '{print $1}' source.sha256) ]]
for ds in otel_logs_100m otel_logs_1b; do
  aws s3api list-objects-v2 --bucket $BUCKET --prefix "searchbench/data/$ds/part_" --no-paginate > $R/preflight/corpus-$ds.json
done
jq -e '.Contents|length==1' $R/preflight/corpus-otel_logs_100m.json $R/preflight/corpus-otel_logs_1b.json
for p in "$PREFIX" "$DATA_PREFIX"; do
  aws s3api list-objects-v2 --bucket $BUCKET --prefix "$p" --no-paginate > $R/preflight/prefix-$(echo "$p" | tr / _).json
  jq -e '(.Contents // []) | length == 0' $R/preflight/prefix-$(echo "$p" | tr / _).json
done
cat > $R/run.env <<EOF
export BOX=$BOX
export N=$N
export TS=$TS
export S3_PREFIX=$PREFIX
export DATA_PREFIX=$DATA_PREFIX
export SOURCE_IP=$IP_SRC
EOF
jq -n '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"ec2.amazonaws.com"},Action:"sts:AssumeRole"}]}' > $R/instance-trust.json
aws iam create-role --role-name "$N-host" --assume-role-policy-document file://$R/instance-trust.json \
  --tags "Key=SearchbenchRun,Value=$N" > $R/host-role.json
jq -n --arg b "$BUCKET" --arg e "$PREFIX" --arg d "$DATA_PREFIX" '{Version:"2012-10-17",Statement:[
  {Sid:"CorpusRead",Effect:"Allow",Action:["s3:GetObject"],Resource:[
     ("arn:aws:s3:::"+$b+"/searchbench/data/otel_logs_100m/part_*"),
     ("arn:aws:s3:::"+$b+"/searchbench/data/otel_logs_1b/part_*")]},
  {Sid:"BucketRegion",Effect:"Allow",Action:["s3:GetBucketLocation"],Resource:("arn:aws:s3:::"+$b)},
  {Sid:"OwnPrefixList",Effect:"Allow",Action:["s3:ListBucket"],Resource:("arn:aws:s3:::"+$b),
   Condition:{StringLike:{"s3:prefix":["searchbench/data/otel_logs_100m/*","searchbench/data/otel_logs_1b/*",
     $e,($e+"*"),$d,($d+"*")]}}},
  {Sid:"EvidenceNoDeletion",Effect:"Allow",Action:["s3:GetObject","s3:PutObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
   Resource:("arn:aws:s3:::"+$b+"/"+$e+"*")},
  {Sid:"QuickwitData",Effect:"Allow",
   Action:["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
   Resource:("arn:aws:s3:::"+$b+"/"+$d+"*")}]}' > $R/host-policy.json
aws iam put-role-policy --role-name "$N-host" --policy-name owned-corpus-data-evidence --policy-document file://$R/host-policy.json
aws iam create-instance-profile --instance-profile-name "$N-host" > $R/profile.json
aws iam add-role-to-instance-profile --instance-profile-name "$N-host" --role-name "$N-host"
jq -n --arg acct "$ACCOUNT" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"scheduler.amazonaws.com"},Action:"sts:AssumeRole",Condition:{StringEquals:{"aws:SourceAccount":$acct},ArnEquals:{"aws:SourceArn":("arn:aws:scheduler:us-east-1:"+$acct+":schedule-group/default")}}}]}' > $R/scheduler-trust.json
aws iam create-role --role-name "$N-stop" --assume-role-policy-document file://$R/scheduler-trust.json \
  --tags "Key=SearchbenchRun,Value=$N" > $R/stop-role.json
aws ec2 create-security-group --group-name "$N" --description "$N owned SSH only" --vpc-id "$VPC" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$N},{Key=SearchbenchRun,Value=$N}]" > $R/sg.json
SG=$(jq -r .GroupId $R/sg.json)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "$IP_SRC/32" > $R/ingress.json
sleep 15   # instance-profile propagation
read -r NOW OS_DEADLINE_EPOCH WORK_CUTOFF_EPOCH OS_DEADLINE < <(python3 -c '
import time, datetime, sys
h = int(sys.argv[1]); now = int(time.time())
os_deadline = (now + h * 3600 - 5 * 60) // 60 * 60
work = (now + h * 3600 - 20 * 60) // 60 * 60
print(now, os_deadline, work, datetime.datetime.fromtimestamp(os_deadline, datetime.timezone.utc).strftime("%Y-%m-%d_%H:%M:%S"))' "$HOURS")
OS_DEADLINE=${OS_DEADLINE/_/ }
sed "s/@OS_DEADLINE@/$OS_DEADLINE/" boot.sh.in > $R/boot.sh
grep -q "OnCalendar=$OS_DEADLINE UTC" $R/boot.sh
cat >> $R/run.env <<EOF
export RUN_INSTANCES_EPOCH=$NOW
export OS_DEADLINE_EPOCH=$OS_DEADLINE_EPOCH
export OS_DEADLINE='$OS_DEADLINE'
export WORK_CUTOFF_EPOCH=$WORK_CUTOFF_EPOCH
EOF
IID=''
stop_failed_launch() {
  rc=$?
  if [[ $rc -ne 0 && -f $R/launch-attempted ]]; then
    if [[ -z "$IID" ]]; then
      aws ec2 describe-instances --filters "Name=client-token,Values=$N" "Name=tag:SearchbenchRun,Values=$N" > $R/launch-reconciliation.json 2>$R/launch-reconciliation.err || true
      IID=$(jq -r '[.Reservations[].Instances[] | select(.State.Name != "terminated") | .InstanceId] | if length == 1 then .[0] else empty end' $R/launch-reconciliation.json 2>/dev/null) || true
      [[ -z "$IID" ]] || printf '%s\n' "$IID" > $R/instance-id.txt
    fi
    if [[ -n "$IID" ]]; then
      aws ec2 stop-instances --instance-ids "$IID" > $R/emergency-stop.json 2>$R/emergency-stop.err || true
    else
      echo 'ALERT: ambiguous launch not reconciled; inspect unique token/tag, NEVER relaunch' >&2
    fi
  fi
  exit "$rc"
}
trap stop_failed_launch EXIT
date -u > $R/launch-attempted   # marker BEFORE RunInstances; never invoke it twice
aws ec2 run-instances --image-id "$AMI" --instance-type $INSTANCE_TYPE --count 1 \
  --client-token "$N" --iam-instance-profile "Name=$N-host" \
  --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET,Groups=$SG,AssociatePublicIpAddress=true,DeleteOnTermination=true" \
  --instance-initiated-shutdown-behavior stop --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2 \
  --ebs-optimized --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":false}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$N},{Key=SearchbenchRun,Value=$N}]" "ResourceType=volume,Tags=[{Key=Name,Value=$N-vol},{Key=SearchbenchRun,Value=$N}]" \
  --user-data file://$R/boot.sh > $R/instance.json
IID=$(jq -er '.Instances[0].InstanceId' $R/instance.json)
printf '%s\n' "$IID" > $R/instance-id.txt
jq -er --arg t $INSTANCE_TYPE '.Instances[0].InstanceType==$t' $R/instance.json
AZ=$(jq -er '.Instances[0].Placement.AvailabilityZone' $R/instance.json)
aws ec2 wait instance-exists --instance-ids "$IID"
read -r LAUNCH_EPOCH SCHEDULE_AT < <(python3 - "$R/instance.json" "$HOURS" <<'PY'
import json, datetime, sys
x = json.load(open(sys.argv[1]))["Instances"][0]
t = datetime.datetime.fromisoformat(x["LaunchTime"].replace("Z", "+00:00"))
at = int(t.timestamp() + int(sys.argv[2]) * 3600) // 60 * 60
print(int(t.timestamp()), datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"))
PY
)
SCHED_EPOCH=$(python3 -c "import datetime;print(int(datetime.datetime.fromisoformat('$SCHEDULE_AT+00:00').timestamp()))")
(( SCHED_EPOCH - LAUNCH_EPOCH <= HOURS * 3600 && SCHED_EPOCH > OS_DEADLINE_EPOCH && OS_DEADLINE_EPOCH > WORK_CUTOFF_EPOCH ))
cat >> $R/run.env <<EOF
export IID=$IID
export AZ=$AZ
export SG=$SG
export LAUNCH_EPOCH=$LAUNCH_EPOCH
export SCHEDULE_AT=$SCHEDULE_AT
EOF
jq -n --arg arn "arn:aws:ec2:us-east-1:$ACCOUNT:instance/$IID" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"ec2:StopInstances",Resource:$arn}]}' > $R/stop-policy.json
aws iam put-role-policy --role-name "$N-stop" --policy-name exact-owned-instance --policy-document file://$R/stop-policy.json
jq -n --arg id "$IID" --arg role "arn:aws:iam::$ACCOUNT:role/$N-stop" '{Arn:"arn:aws:scheduler:::aws-sdk:ec2:stopInstances",RoleArn:$role,Input:({InstanceIds:[$id]}|tojson),RetryPolicy:{MaximumEventAgeInSeconds:120,MaximumRetryAttempts:1}}' > $R/schedule-target.json
aws scheduler create-schedule --name "$N-stop" --schedule-expression "at($SCHEDULE_AT)" --schedule-expression-timezone UTC \
  --flexible-time-window '{"Mode":"OFF"}' --target file://$R/schedule-target.json --state ENABLED > $R/schedule.json
aws scheduler get-schedule --name "$N-stop" > $R/schedule-verified.json
jq -e --arg id "$IID" --arg at "at($SCHEDULE_AT)" '.State=="ENABLED" and .ScheduleExpression==$at and (.Target.Input|fromjson|.InstanceIds==[$id])' $R/schedule-verified.json
trap - EXIT
iso() { python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime('%FT%TZ'))" "$1"; }
printf '[%s] instance %s (%s) launched %s; workload cutoff %s; OS timer %s UTC; Scheduler %s UTC\n' \
  "$BOX" "$IID" "$AZ" "$(iso "$LAUNCH_EPOCH")" "$(iso "$WORK_CUTOFF_EPOCH")" "$OS_DEADLINE" "$SCHEDULE_AT" | tee $R/timeline.txt
