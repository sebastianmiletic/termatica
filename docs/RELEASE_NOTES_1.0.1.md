# Termatica 1.0.1

## Performance

- Replaces block-based parsing with an incremental C decoder and batched ASCII
  and Unicode delivery.
- Adds no-copy PTY chunk ownership, bounded backpressure, refresh coalescing,
  row-span ASCII writes, Unicode fast paths, and progressive scrollback
  allocation.
- Reaches zero overshoots in 240-frame ASCII viewport paint measurements at
  60 Hz, 120 Hz, and 240 Hz.
- Keeps the universal app below 1 MiB and the measured idle physical footprint
  below 40 MiB.

## Phase 10 readiness

- Adds immutable `TRenderSnapshot`, `TRenderMetrics`, and `TRenderBackend`
  contracts for the Metal renderer.
- Keeps AppKit as a complete fallback and prohibits renderers from retaining
  pointers into mutable terminal, history, image, or PTY buffers.
- Moves native benchmarks and self-tests outside the shipped application.

## Reliability

- Adds decoder chunk-boundary equivalence coverage for ASCII, Unicode, CSI,
  OSC, DCS, and invalid UTF-8.
- Preserves alternate-screen scrolling, mouse routing, shell integration,
  configuration, editor adapters, session restore, and verified updater
  rollback behavior.
