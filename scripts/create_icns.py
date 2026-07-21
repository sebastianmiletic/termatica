#!/usr/bin/env python3
"""Build a modern ICNS container from Termatica's PNG iconset."""

from pathlib import Path
import struct


ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Resources" / "AppIcon.iconset"
OUTPUT = ROOT / "Resources" / "AppIcon.icns"

CHUNKS = (
    (b"icp4", "icon_16x16.png"),
    (b"icp5", "icon_16x16@2x.png"),
    (b"icp6", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_128x128@2x.png"),
    (b"ic09", "icon_256x256@2x.png"),
    (b"ic10", "icon_512x512@2x.png"),
)


def main() -> None:
    chunks = []
    for kind, filename in CHUNKS:
        payload = (ICONSET / filename).read_bytes()
        chunks.append(kind + struct.pack(">I", len(payload) + 8) + payload)
    body = b"".join(chunks)
    OUTPUT.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print(f"wrote {OUTPUT} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
