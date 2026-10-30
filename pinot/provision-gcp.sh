#!/usr/bin/env bash
# Provision an n2-standard-32 (Ubuntu 24.04) for SearchBench against Apache Pinot.
#
# Differs from provision-ec2.sh in three ways that matter:
#   1. apt, not dnf; and JDK 25 is not in Ubuntu 24.04's repos, so Corretto is fetched as a tarball.
#   2. n2-standard-32 has NO local NVMe -- all I/O goes to the persistent disk. Disk throughput
#      therefore gates ingestion in a way it did not on m6id's local NVMe.
#   3. Ubuntu may or may not mount /tmp as tmpfs; we redirect scratch regardless.
set -euo pipefail

DATA=${DATA:-/data}
JDK_URL=${JDK_URL:-https://corretto.aws/downloads/latest/amazon-corretto-25-x64-linux-jdk.tar.gz}
PINOT_REF=${PINOT_REF:-master}

log() { echo "[provision] $*"; }

# The benchmark needs far more space than the 200GB boot disk: corpus + shards + server copy
# + controller deep store. Fail loudly and early rather than dying mid-ingestion.
check_disk() {
    mkdir -p "$DATA"
    local avail_gb
    avail_gb=$(df -BG --output=avail "$DATA" | tail -1 | tr -dc '0-9')
    log "$DATA has ${avail_gb}GB available"
    if (( avail_gb < 450 )); then
        log "WARNING: the 1B run peaked at ~486GB on EC2 (corpus 39 + shards 39 + server 152"
        log "         + controller deep store 95 + segment tars ~95). ${avail_gb}GB is not enough."
        log "         Attach a larger disk, or set PINOT_AGGRESSIVE_CLEANUP=1 to delete shards"
        log "         and segment tars as they are consumed (needs ~300GB, still above 200GB)."
        [[ "${ALLOW_SMALL_DISK:-}" == "1" ]] || exit 1
    fi
}

# Use the attached data disk, addressed by its GCP device alias.
# NEVER pick by "largest unmounted disk": the boot disk /dev/sda reports an empty MOUNTPOINT
# because the filesystem is mounted from its partition (sda1), so that heuristic can format
# the boot disk. /dev/disk/by-id/google-<device-name> is unambiguous.
DATA_DEVICE=${DATA_DEVICE:-/dev/disk/by-id/google-sbdata}

mount_data_disk() {
    if mountpoint -q "$DATA"; then log "$DATA already mounted"; return; fi
    if [[ ! -e "$DATA_DEVICE" ]]; then
        log "data disk $DATA_DEVICE not found; attach one or set DATA_DEVICE"
        lsblk -po NAME,SIZE,MOUNTPOINT
        exit 1
    fi
    local real; real=$(readlink -f "$DATA_DEVICE")
    # Refuse to touch a disk that already carries mounted filesystems.
    if lsblk -nro MOUNTPOINT "$real" | grep -q .; then
        log "$real has mounted filesystems; refusing to format"
        exit 1
    fi
    log "formatting $real ($DATA_DEVICE) -> $DATA"
    sudo mkfs.ext4 -F -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$real"
    sudo mkdir -p "$DATA" && sudo mount -o discard,defaults "$real" "$DATA"
    sudo chown -R "$USER:$USER" "$DATA"
}

install_packages() {
    log "installing packages"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        git jq curl wget tar gzip python3 python3-pip python3-venv unzip >/dev/null
    # Ubuntu 24.04 marks the system Python externally-managed; a venv keeps pyarrow installable.
    # requests is needed too: lib/slice_parquet.py imports it for the HTTP range reads that the
    # smoke scales (100k/1m/100m) use. Installing only pyarrow leaves otel_logs_100m failing at
    # the download step, while 1b/10b pass because they fetch whole parts with wget.
    python3 -m venv "$HOME/sbvenv" && "$HOME/sbvenv/bin/pip" install --quiet pyarrow requests
    log "pyarrow $("$HOME/sbvenv/bin/python" -c 'import pyarrow;print(pyarrow.__version__)')"
}

install_jdk25() {
    local jdk="$DATA/jdk25"
    if [[ -x "$jdk/bin/java" ]]; then log "JDK 25 already present"; return; fi
    log "fetching Corretto 25"
    mkdir -p "$jdk"
    curl -fsSL "$JDK_URL" | tar -xz -C "$jdk" --strip-components=1
    "$jdk/bin/java" -version 2>&1 | head -1
}

build_pinot() {
    local src="$DATA/pinot" jdk="$DATA/jdk25"
    [[ -d "$src" ]] || { log "cloning apache/pinot @ $PINOT_REF"
        git clone --depth 50 --branch "$PINOT_REF" https://github.com/apache/pinot.git "$src"; }
    mkdir -p "$DATA/tmp"
    log "building (-Pbin-dist is required; a plain install leaves the distribution stale)"
    (cd "$src" && JAVA_HOME="$jdk" ./mvnw -q -T1C -DskipTests -Pbin-dist \
        -Djava.io.tmpdir="$DATA/tmp" clean install)
    rm -rf "$DATA/pinot-dist" && mkdir -p "$DATA/pinot-dist"
    tar -xzf "$src"/pinot-distribution/target/apache-pinot-*-bin.tar.gz \
        -C "$DATA/pinot-dist" --strip-components=1

    local major
    major=$("$jdk/bin/java" -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/')
    cat > "$HOME/.searchbench-env" <<EOF
export PINOT_JAVA_HOME="$jdk"
export PINOT_MIN_JAVA=$major
export PINOT_DIST="$DATA/pinot-dist"
export PINOT_WORK="$DATA/pinot-work"
export PINOT_TMPDIR="$DATA/tmp"
export SEARCHBENCH_DATA_DIR="$DATA/searchbench-data"
export SEARCHBENCH_PYTHON="$HOME/sbvenv/bin/python"
EOF
    log "wrote ~/.searchbench-env"
}

main() {
    mount_data_disk
    check_disk
    install_packages
    install_jdk25
    build_pinot
    log "done. next: source ~/.searchbench-env && cd searchbench/pinot && ./benchmark.sh --index"
}

main "$@"
