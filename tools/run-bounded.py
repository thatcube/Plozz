#!/usr/bin/env python3
"""Run one command with a real wall-clock deadline.

Apple tools sometimes ignore their own --timeout while blocked below CoreDevice
or Xcode's destination resolver. This wrapper owns the process group, forwards
stdout/stderr unchanged, and kills the whole tree when the deadline expires.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[3] != "--":
        print(
            "usage: run-bounded.py <seconds> <stage-label> -- <command> [args...]",
            file=sys.stderr,
        )
        return 2

    try:
        timeout = float(sys.argv[1])
    except ValueError:
        print(f"invalid timeout: {sys.argv[1]}", file=sys.stderr)
        return 2

    label = sys.argv[2]
    command = sys.argv[4:]
    if not command:
        print("missing command", file=sys.stderr)
        return 2

    started = time.monotonic()
    process = subprocess.Popen(command, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        elapsed = int(time.monotonic() - started)
        print(
            f"✗ {label} exceeded its hard {int(timeout)}s deadline "
            f"(elapsed {elapsed}s); terminating it.",
            file=sys.stderr,
            flush=True,
        )
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
