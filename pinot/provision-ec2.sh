#!/usr/bin/env bash
# Provision a fresh Amazon Linux 2023 m6id.8xlarge for a SearchBench run against Apache Pinot.
#
# m6id.8xlarge: 32 vCPU Ice Lake, 128 GiB RAM, 1.9 TB local NVMe.
# The NVMe is ephemeral and unformatted on every boot -- nothing here survives a stop/start.
#
# Encodes four traps that cost real time on the previous run:
#   1. /tmp is a 62 GB tmpfs on AL2023; segment build needs ~74 GB and dies in close().
#   2. The runtime JDK must be at least the JDK the distribution was built with.
#   3. Pinot's scratch dirs must exist before start, or the controller cannot write its pid.
#   4. ZooKeeper's "ruok" four-letter probe is disabled by default, so health checks hang.
set -euo pipefail

DATA_MNT=${DATA_MNT:-/data}
JDK_PKG=${JDK_PKG:-java-25-amazon-corretto-devel}
PINOT_REPO=${PINOT_REPO:-https://github.com/apache/pinot.git}
PINOT_REF=${PINOT_REF:-master}

log() { echo "[provision] $*"; }

# The local NVMe is the only disk big enough for a 1B-row corpus plus segments.
mount_nvme() {
    if mountpoint -q "$DATA_MNT"; then log "$DATA_MNT already mounted"; return; fi
    # Pick the largest unmounted NVMe that is not the root device.
    local dev
    dev=$(lsblk -dnpo NAME,SIZE,MOUNTPOINT | awk '$3=="" && $1 ~ /nvme/ {print $1}' | tail -1)
    [[ -n "$dev" ]] || { log "no spare NVMe found"; lsblk; exit 1; }
    log "formatting $dev -> $DATA_MNT"
    sudo mkfs.xfs -f "$dev"
    sudo mkdir -p "$DATA_MNT"
    sudo mount "$dev" "$DATA_MNT"
    sudo chown -R "$USER:$USER" "$DATA_MNT"
}

install_packages() {
    log "installing packages"
    # AL2023 preinstalls curl-minimal, which provides /usr/bin/curl and conflicts with the full curl package.
    sudo dnf -y install git jq tar gzip "$JDK_PKG" python3 python3-pip docker >/dev/null
    pip3 install --quiet --user pyarrow
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER" || true
}

# Trap 1: keep every temp write off the tmpfs /tmp.
redirect_tmp() {
    mkdir -p "$DATA_MNT/tmp"
    log "scratch space -> $DATA_MNT/tmp ($(df -h "$DATA_MNT" | awk 'NR==2{print $4}') free)"
}

build_pinot() {
    local src="$DATA_MNT/pinot"
    if [[ ! -d "$src" ]]; then
        log "cloning $PINOT_REPO @ $PINOT_REF"
        git clone --depth 50 --branch "$PINOT_REF" "$PINOT_REPO" "$src"
    fi
    # Trap 2: build and run with the same JDK. Record it so the adapter cannot drift.
    local jh
    jh=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
    log "building with JAVA_HOME=$jh"
    # -Pbin-dist is required: a plain install does NOT refresh the unpacked distribution.
    (cd "$src" && JAVA_HOME="$jh" ./mvnw -q -T1C -DskipTests -Pbin-dist \
        -Djava.io.tmpdir="$DATA_MNT/tmp" clean install)

    local tgz
    tgz=$(ls "$src"/pinot-distribution/target/apache-pinot-*-bin.tar.gz)
    rm -rf "$DATA_MNT/pinot-dist" && mkdir -p "$DATA_MNT/pinot-dist"
    tar -xzf "$tgz" -C "$DATA_MNT/pinot-dist" --strip-components=1
    log "distribution -> $DATA_MNT/pinot-dist"

    # Pin the runtime JDK to the build JDK for every later shell.
    local major
    major=$("$jh/bin/java" -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/')
    cat > "$HOME/.searchbench-env" <<EOF
export PINOT_JAVA_HOME="$jh"
export PINOT_MIN_JAVA=$major
export PINOT_DIST="$DATA_MNT/pinot-dist"
export PINOT_WORK="$DATA_MNT/pinot-work"
export PINOT_TMPDIR="$DATA_MNT/tmp"
export SEARCHBENCH_DATA_DIR="$DATA_MNT/searchbench-data"
EOF
    log "wrote ~/.searchbench-env (source it before running benchmark.sh)"
}

main() {
    mount_nvme
    install_packages
    redirect_tmp
    build_pinot
    log "done. next: source ~/.searchbench-env && cd searchbench/pinot && ./benchmark.sh --index"
}

main "$@"
