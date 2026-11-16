#!/usr/bin/env bash
# HOST. Dependencies, data volume, source, Rust client build + tests, image pull and
# identity check. Outside every measured phase. Corpora are fetched per scale by
# production.sh (the 10B corpus and the 1B index do not fit side by side).
set -euo pipefail
cd /srv/qw
source ./run.env
source ./remote.env
E=/srv/qw/evidence
systemctl is-active qw-deadline.timer
(( $(date +%s) < WORK_CUTOFF_EPOCH ))
while pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null || systemctl is-active --quiet apt-daily.service || systemctl is-active --quiet apt-daily-upgrade.service; do sleep 5; done
systemctl stop apt-daily.timer apt-daily-upgrade.timer
while pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; do sleep 5; done
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io jq python3-venv build-essential pkg-config sysstat nvme-cli curl fio
dpkg-query -W docker.io sysstat jq python3-venv > $E/packages.txt
# CPU-accounting parent for engine containers (SEARCHBENCH_CPU=on), before any container exists.
systemctl stop docker.service docker.socket
cat > /etc/systemd/system/searchbench.slice <<'EOF'
[Unit]
Description=Searchbench engine containers CPU accounting
[Slice]
CPUAccounting=yes
[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/docker
printf '{"cgroup-parent":"searchbench.slice"}\n' > /etc/docker/daemon.json
systemctl daemon-reload
systemctl enable --now searchbench.slice
systemctl start docker
# Data volume: the 3,000 GiB gp3 EBS volume (20,000 IOPS, 625 MiB/s) attached as /dev/sdb. Holds the
# corpus and the data dir (local: index; s3: WAL + split store). Must be the only unpartitioned,
# unmounted EBS disk of DATA_GIB, matched by volume id.
lsblk -J -b -o NAME,PATH,MODEL,SERIAL,SIZE,MOUNTPOINTS > $E/disks-before.json
# The by-id link carries the EBS volume id (vol-0abc -> vol0abc): this is exactly the provisioned volume.
disks=( "$(readlink -f "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${DATA_VOL//-/}")" )
[[ -b "${disks[0]}" && $(lsblk -dbn -o SIZE "${disks[0]}") == $((DATA_GIB * 1073741824)) ]]
[[ -z $(lsblk -n -o MOUNTPOINTS "${disks[0]}" | tr -d '[:space:]') && $(lsblk -nr -o NAME "${disks[0]}" | wc -l) == 1 ]]
mkfs.ext4 -q -F -E nodiscard "${disks[0]}"
mkdir -p /mnt/qw
mount -o noatime "${disks[0]}" /mnt/qw
findmnt -J /mnt/qw > $E/data-mount.json
df -B1 /mnt/qw > $E/data-df.txt
# Data-volume baseline (outside every measured phase): 16k random reads and 1 MiB sequential reads, 60 s each.
fio --name=rr --filename=/mnt/qw/fio.tmp --size=32G --direct=1 --ioengine=libaio --rw=randread --bs=16k --iodepth=64 --numjobs=4 \
    --time_based --runtime=60 --group_reporting --output-format=json > $E/fio-randread-16k.json
fio --name=sr --filename=/mnt/qw/fio.tmp --size=32G --direct=1 --ioengine=libaio --rw=read --bs=1M --iodepth=32 --numjobs=4 \
    --time_based --runtime=60 --group_reporting --output-format=json > $E/fio-seqread-1m.json
rm -f /mnt/qw/fio.tmp
lscpu > $E/lscpu.txt; free -b > $E/memory.txt; lsblk > $E/disks.txt; uname -a > $E/uname.txt
# Benchmark source (git archive of the PR branch), verified.
[[ $(sha256sum source.tar.gz | awk '{print $1}') == $(awk '{print $1}' source.sha256) ]]
mkdir -p source && tar xzf source.tar.gz -C source
cp source.commit $E/
python3 -m venv venv
venv/bin/pip install --quiet 'pyarrow==26.0.1' 'requests==2.34.2' 'awscli==1.46.2' orjson
venv/bin/pip freeze > $E/python-freeze.txt
ln -sf /srv/qw/venv/bin/aws /usr/local/bin/aws
aws --version > $E/awscli-version.txt 2>&1
aws sts get-caller-identity > $E/sts-host.json
jq -e --arg r "assumed-role/$N-host/" '.Arn|contains($r)' $E/sts-host.json
aws configure set default.s3.max_concurrent_requests 32
aws configure set default.s3.multipart_chunksize 64MB
if [[ $BOX == s3 ]]; then
    aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$DATA_PREFIX" --no-paginate > $E/data-prefix-before.json
    jq -e '(.Contents // []) | length == 0' $E/data-prefix-before.json
fi
# Rust ingest client: build + tests before any measured load.
curl --proto '=https' --tlsv1.2 -fsS https://sh.rustup.rs -o rustup-init.sh
sh rustup-init.sh -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
source /root/.cargo/env
rustc -Vv > $E/rustc-version.txt
(cd source/quickwit/client && QW_CLIENT_BUILD=native ./build.sh && cargo test --release --locked) > $E/client-build-and-tests.log 2>&1
sha256sum "$QW_CLIENT_BIN" > $E/client.sha256
# Adapter unit tests on Linux.
(cd source/quickwit && /srv/qw/venv/bin/python3 -m unittest test_load_client) > $E/adapter-tests.log 2>&1
# Image: pinned digest, arm64, built from the expected main commit.
docker pull "$QW_IMAGE" > $E/image-pull.log 2>&1
docker image inspect "$QW_IMAGE" > $E/image-inspect.json
jq -e --arg rev "$QW_EXPECTED_REVISION" '.[0].Architecture=="arm64" and .[0].Os=="linux" and .[0].Config.Labels["org.opencontainers.image.revision"]==$rev' $E/image-inspect.json
date -u > $E/setup-passed
