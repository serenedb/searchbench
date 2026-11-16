#!/usr/bin/env python3
"""Run a command in its own session until an absolute deadline (stdlib only).

  run_until.py DEADLINE_EPOCH COMMAND [ARGS...]

At the deadline (or on SIGTERM/SIGINT to this process) the WHOLE process group
gets SIGTERM, then SIGKILL 30 s later -- unlike timeout(1), which signals only
its direct child and would leave bash's grandchildren (queries, docker CLI)
running past the cutoff. Exit status: the command's, or 124 at the deadline.
"""
import os
import signal
import subprocess
import sys
import time

GRACE = 30


def main():
    deadline = float(sys.argv[1])
    proc = subprocess.Popen(sys.argv[2:], start_new_session=True)
    stop = {"why": None}

    def forward(signum, _frame):
        stop["why"] = signum

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    while proc.poll() is None and stop["why"] is None and time.time() < deadline:
        time.sleep(1)
    if proc.poll() is not None:
        return proc.returncode
    print(f"run_until: {'deadline' if stop['why'] is None else 'signal ' + str(stop['why'])}: "
          f"SIGTERM to process group {proc.pid}", file=sys.stderr, flush=True)
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    end = time.time() + GRACE
    while proc.poll() is None and time.time() < end:
        time.sleep(0.5)
    try:
        os.killpg(proc.pid, signal.SIGKILL)  # also any leftover group members
    except ProcessLookupError:
        pass
    proc.wait()
    return 124 if stop["why"] is None else 128 + stop["why"]


if __name__ == "__main__":
    raise SystemExit(main())
