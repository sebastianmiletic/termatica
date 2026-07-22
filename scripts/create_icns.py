#!/usr/bin/env python3
"""Render the single-bolt logo and build Termatica's ICNS container."""

from pathlib import Path
import shutil
import struct
import subprocess


ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Resources" / "AppIcon.iconset"
OUTPUT = ROOT / "Resources" / "AppIcon.icns"
SVG = ROOT / "Resources" / "AppIcon.svg"

PNG_TARGETS = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

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
    renderer = shutil.which("rsvg-convert")
    if not renderer:
        raise SystemExit("rsvg-convert is required to regenerate the icon")
    ICONSET.mkdir(parents=True, exist_ok=True)
    for filename, size in PNG_TARGETS.items():
        subprocess.run([renderer, "-w", str(size), "-h", str(size), "-o", str(ICONSET / filename), str(SVG)], check=True)
    for filename in ("AppIcon.png", "AppIcon-1024.png", "AppIcon-source.png"):
        subprocess.run([renderer, "-w", "1024", "-h", "1024", "-o", str(ROOT / "Resources" / filename), str(SVG)], check=True)

    chunks = []
    for kind, filename in CHUNKS:
        payload = (ICONSET / filename).read_bytes()
        chunks.append(kind + struct.pack(">I", len(payload) + 8) + payload)
    body = b"".join(chunks)
    OUTPUT.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print(f"wrote {OUTPUT} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
