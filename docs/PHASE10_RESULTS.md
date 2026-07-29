# Phase 10 results

Phase 10 is implemented as an opt-in Metal renderer with automatic AppKit
fallback. The parser, PTY queues, terminal model, input handling, and AppKit
renderer remain intact.

## Architecture

- Immutable, validated `TRenderSnapshot` values own visible cells, graphemes,
  masks, style data, links, images, cursor state, history state, and damage.
- `TAppKitRenderBackend` and `TMetalRenderBackend` consume the same snapshots.
- Metal uses a serial coalescing queue and presents only increasing snapshot
  generations.
- Runtime shader, device, allocation, glyph-atlas, image, drawable, and command
  failures route to AppKit without clearing terminal state.
- Metal uses a bounded 768 x 768 R8 glyph atlas and direct `CGImage` texture
  upload; MetalKit is not linked.

## Verification

Measured on 2026-07-29 on a MacBook Air M4:

| Gate | Result |
|---|---:|
| Native Metal pixel/readback and fallback self-test | Pass |
| Terminal, tiled input, decoder, CLI, updater, and package tests | Pass |
| AddressSanitizer terminal and decoder tests | Pass |
| Metal frame p50 / p95 / p99, median of 3 runs | 1.341 / 1.607 / 2.150 ms |
| Frames over 60 / 120 / 240 Hz budget | 0 / 0 / 0 in each 240-frame run |
| Universal app file bytes | 1,021,676 bytes |
| Default AppKit idle footprint | 32.1 MiB |
| Opt-in Metal idle footprint | 51.4 MiB |

Metal timing includes immutable snapshot construction, CPU command encoding,
and GPU execution. It excludes time waiting for display vsync and is not a
key-to-photon latency measurement.

The active Metal footprint is above the 40 MiB rollout limit because Retina
`CAMetalLayer` drawable surfaces are charged to the process. Metal therefore
remains opt-in; lowering drawable resolution solely to meet the number would
reduce text quality. AppKit remains the reliable default and satisfies the
memory limit.
