# Termatica 1.4.2

Termatica 1.4.2 improves fragmented long-escape handling, makes new configs inherit the benchmarked defaults, completes common Option-key editing, and publishes measured input-latency stages.

## Faster fragmented escape handling

- Unsupported OSC 6 payloads remain on a stateful discard path when sequences cross PTY read boundaries.
- Transient PTY read batches increase from 256 KiB to 1 MiB without adding idle allocation.
- In the fresh 10-repetition comparison, parser long escapes improved from 221.6 to 228.9 MiB/s and rendered long escapes improved from 223.5 to 244.3 MiB/s.
- The isolated one-pane AppKit benchmark remains at a 30.3 MiB physical footprint.

## Measured input latency

- The benchmark now reports event mapping, immediate-echo parsing, AppKit painting, and total software input-to-paint independently using `CLOCK_UPTIME_RAW` nanoseconds.
- Five 1,000-sample runs measured 1.544 ms p50, 1.746 ms p95, and 2.146 ms p99 software input-to-paint.
- The documentation explicitly distinguishes this software boundary from physical key-to-photon latency, which requires external optical measurement.

## Predictable configs and editing

- Every newly created named config starts from the same optimal settings used by the release benchmark instead of inheriting unrelated settings from the active profile.
- Option-Left, Option-Right, and Option-Delete work in legacy terminal input mode while enhanced keyboard reporting remains intact.
- Named configurations remain independent, complete, portable files.

The release remains a universal macOS 13+ application for Apple Silicon and Intel Macs, with AppKit rendering by default and an opt-in Metal backend.
