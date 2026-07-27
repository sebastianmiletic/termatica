#!/usr/bin/env python3
"""Record when a terminal child process becomes runnable."""

import os
import pathlib
import sys
import time


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: benchmark_probe.py OUTPUT", file=sys.stderr)
        return 2
    output = pathlib.Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        handle.write(f"{time.monotonic_ns()}\n")
        handle.flush()
        os.fsync(handle.fileno())
    time.sleep(30)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
