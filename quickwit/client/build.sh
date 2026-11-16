#!/usr/bin/env bash
# Build before load timing, never concurrently with an engine benchmark.
set -euo pipefail
cd "$(dirname "$0")"
mode="${QW_CLIENT_BUILD:-auto}"
if [[ "$mode" == auto ]]; then
    if command -v cargo >/dev/null; then mode=native; else mode=docker; fi
fi
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"
case "$mode" in
    native) cargo build --release --locked ;;
    docker)
        cache="${CARGO_HOME_CACHE:-$HOME/.cache/qw-client-cargo}"
        mkdir -p "$cache"
        docker run --rm -e CARGO_BUILD_JOBS \
            -v "$PWD:/src" -v "$cache:/usr/local/cargo/registry" -w /src \
            "${QW_RUST_IMAGE:-rust:bookworm}" \
            bash -c 'cargo build --release --locked && chown -R "$1:$2" /src/target' \
            _ "$(id -u)" "$(id -g)"
        ;;
    *) echo "QW_CLIENT_BUILD must be auto, native or docker" >&2; exit 1 ;;
esac
