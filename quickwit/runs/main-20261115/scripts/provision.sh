#!/usr/bin/env bash
# LOCAL macOS control plane. BOX=local|s3 ./provision.sh -- ONE owned launch per box; never relaunch.
# Per box: SG (current /32 SSH only), host role/profile (corpus read, evidence-prefix write; s3 box:
# its Quickwit data prefix Get/Put/List/Delete), scheduler stop role, an m8g.4xlarge (16 physical cores, 64 GiB)
# with a 3,000 GiB gp3 data volume at 20,000 IOPS / 625 MiB/s (the instance's sustained,
# non-burst EBS limits; upstream used a 3 TB GCP pd-ssd), and a one-shot
# EventBridge Scheduler StopInstances at launch+22h. OS shutdown timer at RunInstances+21h55 (user-data),
# workload cutoff RunInstances+21h40.
set -euo pipefail
cd "$(dirname "$0")"
[[ "${APPROVED_RUN:-}" == YES ]] || { echo 'approval required'; exit 1; }
[[ "${BOX:-}" == local || "${BOX:-}" == s3 ]] || { echo 'BOX must be local or s3'; exit 1; }
export AWS_PROFILE=<profile> AWS_REGION=us-east-1 AWS_PAGER=''
export SSH_AUTH_SOCK="<ssh-agent-socket>"
ACCOUNT=<account>
BUCKET=<bucket>
INSTANCE_TYPE=m8g.4xlarge
DATA_GIB=3000 DATA_IOPS=20000 DATA_MIBPS=625
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
N=sb-qwmain-$BOX-$TS
PREFIX=searchbench/artifacts/quickwit-main-$TS/$BOX/
DATA_PREFIX=searchbench/quickwit-main/$TS/
(( ${#N} + 5 <= 64 ))
# Source archive (git archive of the PR branch) must be in place and match its hash.
[[ -f source.tar.gz && $(shasum -a 256 source.tar.gz | awk '{print $1}') == $(awk '{print $1}' source.sha256) ]]
for ds in otel_logs_100m otel_logs_1b otel_logs_10b; do
  aws s3api list-objects-v2 --bucket $BUCKET --prefix "searchbench/data/$ds/part_" --no-paginate > $R/preflight/corpus-$ds.json
done
jq -e '.Contents|length==1' $R/preflight/corpus-otel_logs_100m.json $R/preflight/corpus-otel_logs_1b.json
jq -e '.Contents|length==10' $R/preflight/corpus-otel_logs_10b.json
aws s3api list-objects-v2 --bucket $BUCKET --prefix "$PREFIX" --no-paginate > $R/preflight/evidence-prefix.json
jq -e '(.Contents // []) | length == 0' $R/preflight/evidence-prefix.json
if [[ $BOX == s3 ]]; then
  aws s3api list-objects-v2 --bucket $BUCKET --prefix "$DATA_PREFIX" --no-paginate > $R/preflight/data-prefix.json
  jq -e '(.Contents // []) | length == 0' $R/preflight/data-prefix.json
fi
cat > $R/run.env <<EOF
export BOX=$BOX
export N=$N
export TS=$TS
export S3_PREFIX=$PREFIX
export DATA_PREFIX=$DATA_PREFIX
export SOURCE_IP=$IP_SRC
export DATA_GIB=$DATA_GIB DATA_IOPS=$DATA_IOPS DATA_MIBPS=$DATA_MIBPS
EOF
jq -n '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"ec2.amazonaws.com"},Action:"sts:AssumeRole"}]}' > $R/instance-trust.json
aws iam create-role --role-name "$N-host" --assume-role-policy-document file://$R/instance-trust.json \
  --tags "Key=SearchbenchRun,Value=$N" > $R/host-role.json
jq -n --arg b "$BUCKET" --arg e "$PREFIX" --arg d "$DATA_PREFIX" --arg box "$BOX" '{Version:"2012-10-17",Statement:([
  {Sid:"CorpusRead",Effect:"Allow",Action:["s3:GetObject"],Resource:[
     ("arn:aws:s3:::"+$b+"/searchbench/data/otel_logs_100m/part_*"),
     ("arn:aws:s3:::"+$b+"/searchbench/data/otel_logs_1b/part_*"),
     ("arn:aws:s3:::"+$b+"/searchbench/data/otel_logs_10b/part_*")]},
  {Sid:"BucketRegion",Effect:"Allow",Action:["s3:GetBucketLocation"],Resource:("arn:aws:s3:::"+$b)},
  {Sid:"OwnPrefixList",Effect:"Allow",Action:["s3:ListBucket"],Resource:("arn:aws:s3:::"+$b),
   Condition:{StringLike:{"s3:prefix":["searchbench/data/otel_logs_100m/*","searchbench/data/otel_logs_1b/*","searchbench/data/otel_logs_10b/*",
     $e,($e+"*")] + (if $box=="s3" then [$d,($d+"*")] else [] end)}}},
  {Sid:"EvidenceNoDeletion",Effect:"Allow",Action:["s3:GetObject","s3:PutObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
   Resource:("arn:aws:s3:::"+$b+"/"+$e+"*")}]
  + (if $box=="s3" then [{Sid:"QuickwitData",Effect:"Allow",
       Action:["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
       Resource:("arn:aws:s3:::"+$b+"/"+$d+"*")}] else [] end))}' > $R/host-policy.json
aws iam put-role-policy --role-name "$N-host" --policy-name owned-corpus-data-evidence --policy-document file://$R/host-policy.json
aws iam create-instance-profile --instance-profile-name "$N-host" > $R/profile.json
aws iam add-role-to-instance-profile --instance-profile-name "$N-host" --role-name "$N-host"
jq -n --arg acct "$ACCOUNT" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"scheduler.amazonaws.com"},Action:"sts:AssumeRole",Condition:{StringEquals:{"aws:SourceAccount":$acct},ArnEquals:{"aws:SourceArn":("arn:aws:scheduler:us-east-1:"+$acct+":schedule-group/default")}}}]}' > $R/scheduler-trust.json
aws iam create-role --role-name "$N-stop" --assume-role-policy-document file://$R/scheduler-trust.json \
  --tags "Key=SearchbenchRun,Value=$N" > $R/stop-role.json
aws ec2 create-security-group --group-name "$N" --description "$N owned SSH only" --vpc-id <vpc> \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$N},{Key=SearchbenchRun,Value=$N}]" > $R/sg.json
SG=$(jq -r .GroupId $R/sg.json)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "$IP_SRC/32" > $R/ingress.json
sleep 15   # instance-profile propagation
read -r NOW OS_DEADLINE_EPOCH WORK_CUTOFF_EPOCH OS_DEADLINE < <(python3 -c '
import time, datetime
now = int(time.time())
os_deadline = (now + 1315 * 60) // 60 * 60
work = (now + 1300 * 60) // 60 * 60
print(now, os_deadline, work, datetime.datetime.fromtimestamp(os_deadline, datetime.timezone.utc).strftime("%Y-%m-%d_%H:%M:%S"))')
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
aws ec2 run-instances --image-id ami-09a93d801db0bafae --instance-type $INSTANCE_TYPE --count 1 \
  --client-token "$N" --iam-instance-profile "Name=$N-host" \
  --network-interfaces "DeviceIndex=0,SubnetId=<subnet>,Groups=$SG,AssociatePublicIpAddress=true,DeleteOnTermination=true" \
  --instance-initiated-shutdown-behavior stop --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2 \
  --ebs-optimized --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":100,\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":false}},{\"DeviceName\":\"/dev/sdb\",\"Ebs\":{\"VolumeSize\":$DATA_GIB,\"VolumeType\":\"gp3\",\"Iops\":$DATA_IOPS,\"Throughput\":$DATA_MIBPS,\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$N},{Key=SearchbenchRun,Value=$N}]" "ResourceType=volume,Tags=[{Key=Name,Value=$N-vol},{Key=SearchbenchRun,Value=$N}]" \
  --user-data file://$R/boot.sh > $R/instance.json
IID=$(jq -er '.Instances[0].InstanceId' $R/instance.json)
printf '%s\n' "$IID" > $R/instance-id.txt
jq -er --arg t $INSTANCE_TYPE '.Instances[0].Placement.AvailabilityZone=="us-east-1a" and .Instances[0].InstanceType==$t' $R/instance.json
aws ec2 wait instance-exists --instance-ids "$IID"
for _ in $(seq 1 30); do
  aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$IID" "Name=attachment.device,Values=/dev/sdb" > $R/data-volume.json
  [[ $(jq '.Volumes|length' $R/data-volume.json) == 1 ]] && break; sleep 5
done
jq -e --argjson g $DATA_GIB --argjson i $DATA_IOPS --argjson t $DATA_MIBPS '.Volumes[0] | .Size==$g and .VolumeType=="gp3" and .Iops==$i and .Throughput==$t' $R/data-volume.json
DATA_VOL=$(jq -r '.Volumes[0].VolumeId' $R/data-volume.json)
read -r LAUNCH_EPOCH SCHEDULE_AT < <(python3 - "$R/instance.json" <<'PY'
import json, datetime, sys
x = json.load(open(sys.argv[1]))["Instances"][0]
t = datetime.datetime.fromisoformat(x["LaunchTime"].replace("Z", "+00:00"))
at = int(t.timestamp() + 79200) // 60 * 60
print(int(t.timestamp()), datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"))
PY
)
SCHED_EPOCH=$(python3 -c "import datetime;print(int(datetime.datetime.fromisoformat('$SCHEDULE_AT+00:00').timestamp()))")
(( SCHED_EPOCH - LAUNCH_EPOCH <= 79200 && SCHED_EPOCH > OS_DEADLINE_EPOCH && OS_DEADLINE_EPOCH > WORK_CUTOFF_EPOCH ))
cat >> $R/run.env <<EOF
export IID=$IID
export SG=$SG
export DATA_VOL=$DATA_VOL
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
printf '[%s] instance %s launched %s; workload cutoff %s; OS timer %s UTC; Scheduler %s UTC\n' \
  "$BOX" "$IID" "$(iso "$LAUNCH_EPOCH")" "$(iso "$WORK_CUTOFF_EPOCH")" "$OS_DEADLINE" "$SCHEDULE_AT" | tee $R/timeline.txt
