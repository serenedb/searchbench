#!/usr/bin/env bash
# One-time HOST bootstrap: install Docker Engine + grant invoking user daemon access.
# Not part of the SearchBench adapter contract (driver never calls it); convenience
# for a fresh box. Idempotent: skips install if Docker present.
#
# Usage:
#   ./setup-docker.sh           # re-execs under sudo if needed
#   sudo ./setup-docker.sh
#
# After: start a NEW login shell (or `newgrp docker`) to pick up the docker group.
set -euo pipefail

# Re-exec under sudo if not root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "==> re-running under sudo (you'll be prompted for your password)"
    exec sudo -E bash "$0" "$@"
fi

# Real user to add to docker group (sudo sets SUDO_USER)
TARGET_USER="${SUDO_USER:-${USER:-root}}"

if command -v docker >/dev/null 2>&1; then
    echo "==> Docker already installed: $(docker --version)"
else
    echo "==> installing Docker Engine via get.docker.com"
    curl -fsSL https://get.docker.com | sh
fi

# Enable + start daemon; tolerated on hosts without systemd (containers/WSL)
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 \
        || echo "   (could not manage docker via systemctl; start it however your host does)"
fi

# Grant daemon access via docker group (persists across restarts, unlike chmod'ing socket)
if [[ "$TARGET_USER" != "root" ]]; then
    getent group docker >/dev/null || groupadd docker
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
        echo "==> ${TARGET_USER} already in the docker group"
    else
        usermod -aG docker "$TARGET_USER"
        echo "==> added ${TARGET_USER} to the docker group"
    fi
fi

cat <<EOF

==> Docker is installed.
    $(docker --version)

Next:
  1. Start a NEW login shell (log out/in) or run:  newgrp docker
     so '${TARGET_USER}' can use docker without sudo.
  2. Verify:  docker run --rm hello-world
  3. Run the benchmark:
       cd "$(dirname "$(readlink -f "$0")")"
       SEARCHBENCH_DATA_DIR=/path/to/data SEARCHBENCH_DATASET=otel_logs_1m ./benchmark.sh --index
EOF
