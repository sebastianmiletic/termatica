#!/usr/bin/env python3
"""Record real primary-screen SGR press, release, motion, and wheel reports."""

import json
import os
import pathlib
import re
import select
import sys
import termios
import time
import tty


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: tui_mouse_probe.py OUTPUT", file=sys.stderr)
        return 2

    output = pathlib.Path(sys.argv[1])
    original = termios.tcgetattr(sys.stdin.fileno())
    captured = bytearray()
    try:
        tty.setraw(sys.stdin.fileno())
        os.write(sys.stdout.fileno(), b"\x1b[?1003;1006hTermatica mouse compatibility probe")
        deadline = time.monotonic() + 120
        reports = []
        while time.monotonic() < deadline:
            readable, _, _ = select.select([sys.stdin.fileno()], [], [], 0.25)
            if not readable:
                continue
            captured.extend(os.read(sys.stdin.fileno(), 256))
            reports = [
                {
                    "code": int(match.group(1)),
                    "x": int(match.group(2)),
                    "y": int(match.group(3)),
                    "final": match.group(4).decode("ascii"),
                }
                for match in re.finditer(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])", captured)
            ]
            has_wheel = any(report["code"] & 64 for report in reports)
            has_motion = any(report["code"] & 32 for report in reports)
            has_press = any(
                report["final"] == "M" and not report["code"] & (32 | 64)
                for report in reports
            )
            has_release = any(report["final"] == "m" for report in reports)
            if has_wheel and has_motion and has_press and has_release:
                output.write_text(
                    json.dumps(
                        {
                            "protocol": "sgr",
                            "primary_screen": True,
                            "press": has_press,
                            "release": has_release,
                            "motion": has_motion,
                            "wheel": has_wheel,
                            "reports": reports,
                            "hex": captured.hex(),
                        },
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                return 0
        output.write_text(
            json.dumps(
                {"protocol": "incomplete", "reports": reports, "hex": captured.hex()},
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        return 1
    finally:
        os.write(sys.stdout.fileno(), b"\x1b[?1003;1006l")
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, original)


if __name__ == "__main__":
    raise SystemExit(main())
