# Metal Phase 4 scheduling and frame pacing

Phase 4 moves the opt-in Metal renderer from immediate queue draining to
display-refresh-driven presentation. AppKit remains the default renderer and
automatic fallback. Parser scheduling, PTY backpressure, terminal-model
ownership, and input handling are unchanged.

## Implemented

- A Core Video display link wakes the Metal render queue at the active display's
  refresh cadence. Moving or resizing the window retargets the link to the
  window's current display.
- The scheduler retains exactly one pending immutable snapshot. A newer
  generation replaces stale pending work; generations at or below the last
  accepted generation are rejected.
- Configuration, drawable-size, backing-scale, and recovery changes force an
  immediate full presentation instead of waiting for the next display tick.
- A two-slot semaphore bounds GPU submissions. Three reusable shared instance
  buffers prevent reuse while either permitted frame is in flight and remove
  per-frame Metal-buffer allocation.
- The serial render queue runs at interactive quality of service. Instance data
  uses reusable scratch storage rather than allocating a new mutable buffer for
  every frame.
- A missing drawable is retried on a later display tick. It does not silently
  advance the presented generation.
- Diagnostics record snapshot wait, snapshot construction, CPU encoding, GPU
  execution, GPU completion, presentation intervals, submissions, coalescing,
  pending and in-flight counts, and generation reversals independently.

## Deterministic scheduler gate

`--renderer-scheduler-self-test` submits 1,000 sequential snapshots without
waiting between submissions, then submits an older generation and performs a
resize redraw. On the release test host it produced:

| Measurement | Result |
|---|---:|
| Submitted burst | 1,000 snapshots |
| Coalesced stale snapshots | 999 |
| Maximum pending snapshots | 1 |
| Maximum in-flight GPU frames | 1; hard limit 2 |
| Generation reversals | 0 |
| Immediate resize redraw | 7.3-8.0 ms in sanitizer runs |

The exact number of submitted GPU frames can vary with display ticks. The
invariants are bounded pending/in-flight work, monotonic generations, and final
presentation of the newest accepted state.

## Benchmark methodology and results

Five fresh 240-frame native Metal runs on the Apple M4 release host measured
snapshot construction plus CPU command encoding plus the command buffer's GPU
execution interval. Refresh wait, scanout, and physical key-to-photon latency
are not included in the work total and are reported separately where available.

| Measurement | Median of five runs | Range |
|---|---:|---:|
| Work p50 | 1.284 ms | 1.267-1.339 ms |
| Work p95 | 3.815 ms | 2.970-4.273 ms |
| Work p99 | 5.361 ms | 4.126-5.435 ms |
| Frames over 60 Hz work budget | 0 | 0 |
| Frames over 120 Hz work budget | 0 | 0 |
| Frames over synthetic 240 Hz work budget | 7 | 2-14 |
| Maximum in-flight GPU frames | 1 | 1 |
| Generation reversals | 0 | 0 |

The implementation satisfies the 60 Hz and 120 Hz work budgets in these runs.
It does **not** satisfy the older zero-overshoot synthetic 240 Hz target, so the
results are not described as a 240 Hz guarantee. GPU execution variance, not
snapshot construction or CPU encoding, accounted for the remaining tail.

`--benchmark-experience` now also runs AppKit and Metal over identical 1000 x
700 Unicode/ANSI viewport content, full-row scroll damage, eight warmup frames,
and equal frame counts. AppKit work is snapshot plus offscreen CoreText paint;
Metal work is snapshot plus CPU encoding plus GPU execution. The two paths are
reported side by side but are not claimed to be identical presentation APIs.
Benchmark JSON uses a complete-write loop and has a regression requiring a
valid artifact larger than 4 KiB.

The universal bundle measured 1,320,109 bytes with the local Command Line Tools
and 1,339,901 bytes with GitHub's Xcode 15.4 runner. The bundle guard increased
by one 16 KiB Mach-O alignment unit, from 1,327,104 to 1,343,488 bytes, to cover
that toolchain-dependent layout while retaining a bounded release size.

## Release boundary

Metal remains opt-in through `appearance.renderer: "metal"`. Phase 4 does not
make Metal the default and does not remove AppKit. Live application replacement,
GitHub publication, downloaded-asset verification, and updater behavior remain
separate release checks rather than renderer-test conclusions.
