#!/usr/bin/env bash
# HOST. Dependencies, instance-store NVMe, source, Rust client build + tests, Quickwit image build
# from the pinned main commit and identity check. Outside every measured phase. Corpora are fetched
# per scale by production.sh.
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
apt-get install -y docker.io docker-buildx jq python3-venv build-essential pkg-config sysstat nvme-cli curl fio git
dpkg-query -W docker.io docker-buildx sysstat jq python3-venv git > $E/packages.txt
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
# Data volume: the instance-store NVMe of the m8gd.4xlarge (as the published BYOC run). Holds the corpus,
# the WAL / split staging and the image build. Must be the only unmounted instance-store disk.
lsblk -J -b -o NAME,PATH,MODEL,SERIAL,SIZE,MOUNTPOINTS > $E/disks-before.json
mapfile -t disks < <(lsblk -dn -o PATH,MODEL | awk '$0 ~ /Amazon EC2 NVMe Instance Storage/ {print $1}')
(( ${#disks[@]} == 1 ))
[[ -z $(lsblk -n -o MOUNTPOINTS "${disks[0]}" | tr -d '[:space:]') ]]
mkfs.ext4 -q -F "${disks[0]}"
mkdir -p "$DATA_MNT"
mount -o noatime "${disks[0]}" "$DATA_MNT"
findmnt -J "$DATA_MNT" > $E/data-mount.json
df -B1 "$DATA_MNT" > $E/data-df.txt
# Docker's data root on the NVMe too (image build cache, container layers): keeps the 100 GiB root volume free.
mkdir -p "$DATA_MNT/docker"
printf '{"cgroup-parent":"searchbench.slice","data-root":"%s/docker"}\n' "$DATA_MNT" > /etc/docker/daemon.json
systemctl daemon-reload
systemctl enable --now searchbench.slice
systemctl start docker
docker info --format '{{.DockerRootDir}} {{.CgroupDriver}}' > $E/docker-info.txt
grep -q "^$DATA_MNT/docker " $E/docker-info.txt
# Data-volume baseline (outside every measured phase): 16k random reads and 1 MiB sequential reads, 60 s each.
fio --name=rr --filename="$DATA_MNT/fio.tmp" --size=32G --direct=1 --ioengine=libaio --rw=randread --bs=16k --iodepth=64 --numjobs=4 \
    --time_based --runtime=60 --group_reporting --output-format=json > $E/fio-randread-16k.json
fio --name=sr --filename="$DATA_MNT/fio.tmp" --size=32G --direct=1 --ioengine=libaio --rw=read --bs=1M --iodepth=32 --numjobs=4 \
    --time_based --runtime=60 --group_reporting --output-format=json > $E/fio-seqread-1m.json
rm -f "$DATA_MNT/fio.tmp"
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
# Image: Quickwit main at the pinned commit, built here with the repository's own Dockerfile and the
# build arguments of its publish workflow (release-feature-set, release profile, commit hash/date/tags).
QSRC=$DATA_MNT/build/quickwit
git clone --filter=blob:none --no-checkout "$QW_SOURCE_REPO" "$QSRC" > $E/image-clone.log 2>&1
git -C "$QSRC" checkout --quiet "$QW_EXPECTED_REVISION"
[[ $(git -C "$QSRC" rev-parse HEAD) == "$QW_EXPECTED_REVISION" ]]
git -C "$QSRC" log -1 --format='%H %cI %s' > $E/image-source-commit.txt
QW_COMMIT_DATE=$(TZ=UTC0 git -C "$QSRC" log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ)
QW_COMMIT_TAGS=$(git -C "$QSRC" tag --points-at HEAD | tr '\n' ',')
t0=$(date +%s)
DOCKER_BUILDKIT=1 docker build "$QSRC" -t "$QW_IMAGE" \
    --build-arg QW_COMMIT_DATE="$QW_COMMIT_DATE" --build-arg QW_COMMIT_HASH="$QW_EXPECTED_REVISION" \
    --build-arg QW_COMMIT_TAGS="$QW_COMMIT_TAGS" --build-arg CARGO_FEATURES=release-feature-set \
    --label org.opencontainers.image.revision="$QW_EXPECTED_REVISION" \
    --label org.opencontainers.image.source="$QW_SOURCE_REPO" > $E/image-build.log 2>&1
echo $(( $(date +%s) - t0 )) > $E/image-build-seconds.txt
docker image inspect "$QW_IMAGE" > $E/image-inspect.json
jq -e --arg rev "$QW_EXPECTED_REVISION" '.[0].Architecture=="arm64" and .[0].Os=="linux" and .[0].Config.Labels["org.opencontainers.image.revision"]==$rev' $E/image-inspect.json
docker run --rm "$QW_IMAGE" --version > $E/image-version.txt 2>&1
grep -q "${QW_EXPECTED_REVISION:0:7}" $E/image-version.txt
docker builder prune -af > /dev/null 2>&1 || true
date -u > $E/setup-passed
