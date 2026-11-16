#!/usr/bin/env bash
# Cumulative CPU seconds (user + system) of an engine, for SEARCHBENCH_CPU=on.
#
#   lib/cpu-usage.sh containers <name>...   sum of the containers' cgroup v2 cpu.stat usage_usec
#   lib/cpu-usage.sh pids <pid>...          sum of utime + stime of the processes and their descendants
#   lib/cpu-usage.sh slice [<name>]         cgroup v2 cpu.stat usage_usec of a systemd slice (default
#                                           searchbench.slice): every container started under it,
#                                           including those that already exited
#
# Prints one number (seconds, 6 decimals) or nothing if no target is running. The driver reads it
# before and after each try (lib/benchmark.sh); the difference is the CPU the engine spent on that
# try, on every core, as the kernel accounts it. Containers are found through `docker inspect`
# (systemd cgroup driver: /sys/fs/cgroup/<cgroup-parent or system.slice>/docker-<id>.scope; cgroupfs: /sys/fs/cgroup/docker/<id>).
set -uo pipefail
mode=${1:?usage: cpu-usage.sh containers|pids|slice ...}; shift
case "$mode" in
containers)
    total=0; found=0
    for c in "$@"; do
        id=$(docker inspect -f '{{if .State.Running}}{{.Id}}{{end}}' "$c" 2>/dev/null) || continue
        [[ -n "$id" ]] || continue
        for d in "/sys/fs/cgroup/${SEARCHBENCH_CPU_SLICE:-searchbench.slice}/docker-$id.scope" "/sys/fs/cgroup/system.slice/docker-$id.scope" "/sys/fs/cgroup/docker/$id"; do
            if [[ -r "$d/cpu.stat" ]]; then
                u=$(awk '$1=="usage_usec"{print $2}' "$d/cpu.stat"); total=$((total + u)); found=1; break
            fi
        done
    done
    (( found )) && awk -v u="$total" 'BEGIN{printf "%.6f\n", u / 1e6}'
    ;;
pids)
    tck=$(getconf CLK_TCK)
    all=()
    for p in "$@"; do [[ -d /proc/$p ]] && all+=("$p" $(pgrep -d ' ' -P "$p" 2>/dev/null)); done
    (( ${#all[@]} )) || exit 0
    # utime(14) + stime(15) + cutime(16) + cstime(17): children that exited count too
    for p in "${all[@]}"; do [[ -r /proc/$p/stat ]] && sed -E 's/^.*\) //' "/proc/$p/stat"; done \
        | awk -v t="$tck" '{s += $12 + $13 + $14 + $15} END{printf "%.6f\n", s / t}'
    ;;
slice)
    f="/sys/fs/cgroup/${1:-searchbench.slice}/cpu.stat"
    [[ -r "$f" ]] && awk '$1=="usage_usec"{printf "%.6f\n", $2 / 1e6}' "$f"
    ;;
*) echo "unknown mode $mode" >&2; exit 2 ;;
esac
