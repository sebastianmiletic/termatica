#!/usr/bin/env python3
"""Enable primary-screen SGR mouse tracking and record one wheel report."""

import json
import os
import pathlib
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
        os.write(sys.stdout.fileno(), b"\x1b[?1000;1006hCodex-style wheel probe")
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            readable, _, _ = select.select([sys.stdin.fileno()], [], [], 0.25)
            if not readable:
                continue
            captured.extend(os.read(sys.stdin.fileno(), 256))
            if b"\x1b[<64;" in captured or b"\x1b[<65;" in captured:
                output.write_text(
                    json.dumps(
                        {
                            "protocol": "sgr",
                            "primary_screen": True,
                            "hex": captured.hex(),
                        },
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                return 0
        output.write_text(
            json.dumps({"protocol": "missing", "hex": captured.hex()}, indent=2)
            + "\n",
            encoding="utf-8",
        )
        return 1
    finally:
        os.write(sys.stdout.fileno(), b"\x1b[?1000;1006l")
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, original)


if __name__ == "__main__":
    raise SystemExit(main())
