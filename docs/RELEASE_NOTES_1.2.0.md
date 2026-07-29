# Termatica 1.2.0

## Performance

- Starts the PTY before presentation setup and defers terminal font/render
  initialization briefly, allowing the shell and initial native window to become
  ready in parallel.
- Shows the native window before scheduling the launch reveal animation.
- Discards unsupported OSC and DCS payloads without allocating or copying their
  contents, substantially accelerating long escape-code workloads.
- Uses vectorized control-string terminator scanning instead of byte-by-byte
  traversal.
- Streams Kitty graphics chunks into a pre-sized byte buffer and performs
  base64 and image decoding on a dedicated serial background queue.
- Supports Kitty raw RGBA transmission without routing it through ImageIO.
- Avoids redundant render-snapshot copies and unused scrollback allocation.

## Resource targets

- Keeps the universal application below 1 MiB: 1,037,662 exact file bytes.
- Keeps the default AppKit physical footprint below 30 MiB: 29.2/29.3/29.4 MiB
  across three clean five-second settled launches.

## Measured changes from 1.1.1

| Measurement | 1.1.1 | 1.2.0 | Change |
|---|---:|---:|---:|
| Parser, long escapes | 209.6 MB/s | 234.9 MB/s | +12.1% |
| Parser, images | 157.8 MB/s | 202.9 MB/s | +28.6% |
| Render, long escapes | 237.7 MB/s | 265.3 MB/s | +11.6% |
| Render, images | 142.7 MB/s | 218.9 MB/s | +53.4% |
| Shell ready median | 9.643 ms | 9.045 ms | 6.2% faster |
| Shell ready p95 | 12.649 ms | 11.604 ms | 8.3% faster |

## Scope

- This release is intentionally performance-focused. Configuration, theme, UI,
  and UX changes are reserved for the next release.
