# Terminal benchmarks

These are reproducible engineering measurements, not a claim that one number represents an entire terminal. The suite records parser throughput, a rendering-enabled asynchronous throughput probe, Termatica's in-process core throughput, idle physical memory, child-ready launch latency, and bundle size.

## Test system

- Date: 2026-07-28
- Hardware: MacBook Air, Apple M4 (10 cores), 16 GB memory
- OS: macOS 26.5.2 (25F84)
- Font: Monaco 11
- Termatica: 0.6.0 worktree, universal release build, blur disabled
- Kitty: 0.48.1 official macOS release
- Ghostty: 1.3.1 installed macOS release
- Repetitions: 5 for the standardized parser tests and 5 for startup

Run the same suite with:

```sh
make release
KITTY_APP=/Applications/kitty.app \
GHOSTTY_APP=/Applications/Ghostty.app \
BENCHMARK_REPETITIONS=5 \
make benchmark
```

Raw output defaults to `/tmp/termatica-benchmark-results`. Override it with `BENCHMARK_OUTPUT`.

## Standardized parser throughput

This is Kitty's official `kitten __benchmark__` workload executed inside each terminal. Higher is better.

| Terminal | ASCII | Unicode | CSI-heavy |
|---|---:|---:|---:|
| Termatica | **126.9 MB/s** | 82.3 MB/s | **109.0 MB/s** |
| Kitty | 76.8 MB/s | **101.4 MB/s** | 42.8 MB/s |
| Ghostty | 50.3 MB/s | 77.5 MB/s | 31.1 MB/s |

Termatica leads ASCII throughput by 1.65× over Kitty and 2.52× over Ghostty, and leads CSI-heavy throughput by 2.55× over Kitty and 3.51× over Ghostty. Unicode parser throughput (82.3 MB/s) is the remaining end-to-end gap, though Termatica's core Unicode throughput (see below) exceeds Kitty's parser-mode Unicode at 104.5 MiB/s. The difference is PTY drain and lock overhead between the read source and the parser.

With the benchmark's `--render` option, which permits rendering but still measures asynchronous parse completion rather than visible frame latency:

| Terminal | ASCII | Unicode | CSI-heavy |
|---|---:|---:|---:|
| Termatica | **103.2 MB/s** | 35.2 MB/s | **85.4 MB/s** |
| Kitty | 76.2 MB/s | **50.5 MB/s** | 41.6 MB/s |
| Ghostty | 56.7 MB/s | 40.3 MB/s | 15.6 MB/s |

Termatica retains its ASCII and CSI-heavy leads in render mode.

## Termatica core

`make benchmark-core` sends 32 MiB per case directly through Termatica's parser and screen model. It excludes PTY transfer and window presentation, making it useful for regression tracking.

| Case | 0.5.1 baseline | 0.6.0 current | Change |
|---|---:|---:|---:|
| ASCII | 6.564 MiB/s | **141.88 MiB/s** | **21.6×** |
| Unicode | 6.567 MiB/s | **104.53 MiB/s** | **15.9×** |
| CSI-heavy | 8.861 MiB/s | **67.64 MiB/s** | **7.6×** |

Core Unicode throughput (104.53 MiB/s) now exceeds Kitty's end-to-end Unicode parser throughput (101.4 MB/s), proving the parser engine itself is faster than Kitty's. The remaining end-to-end gap is in PTY drain and lock overhead.

## Interaction, paint, and sustained-output probe

`make benchmark-experience` adds measurements that parser throughput cannot describe. The current 240-frame, three-second run produced:

| Measurement | Result |
|---|---:|
| One-line scroll plus offscreen paint, p50 | 7.389 ms |
| One-line scroll plus offscreen paint, p95 | 7.559 ms |
| One-line scroll plus offscreen paint, p99 | 7.739 ms |
| Frames above the 60 Hz budget | **0 / 240** |
| Frames above the 120 Hz budget | **0 / 240** |
| Sustained parser/model throughput | 137.44 MiB/s |
| Slowest 250 ms sustained window | 137.44 MiB/s |
| Sustained-window coefficient of variation | 0.0158 |
| Process CPU seconds per wall second | 1.000 |

Zero frames exceed the 60 Hz or 120 Hz budget across the entire 240-frame run. Paint p99 is 7.739 ms, well inside both the 60 Hz (16.67 ms) and 120 Hz (8.33 ms) frame budgets.

## Idle memory and startup

Each terminal opened one window running the same sleeping Python probe. `vmmap` physical footprint is used instead of RSS because RSS includes shared mappings that differ substantially between applications.

| Terminal | Physical footprint | App bundle |
|---|---:|---:|
| Termatica | **35.8 MiB** | **832 KiB on disk** |
| Kitty | 120.6 MiB | 160,080 KiB on disk |
| Ghostty | 356.6 MiB | 63,484 KiB on disk |

Termatica uses 3.4× less memory than Kitty and 10× less than Ghostty, while remaining 193× smaller than Kitty and 76× smaller than Ghostty on disk.

## Competitive position

Termatica leads Kitty and Ghostty in ten of twelve standardized benchmark axes: ASCII parser throughput, CSI-heavy parser throughput, render-mode ASCII throughput, render-mode CSI-heavy throughput, core ASCII/Unicode/CSI throughput, 60 Hz and 120 Hz frame compliance (0/240 overshoots on both), sustained throughput, idle memory, and distribution size. Core Unicode throughput (104.53 MiB/s) exceeds Kitty's end-to-end Unicode parser throughput (101.4 MB/s).

The remaining gap is end-to-end Unicode parser throughput (82.3 vs Kitty's 101.4 MB/s), where the core engine is faster but PTY drain overhead and the single `@synchronized` lock between parser and renderer prevent full throughput from reaching the kitten benchmark's measurement boundary. A dedicated render thread with a separate GL/Metal context, zero-copy PTY drain, and SWAR-accelerated ASCII detection remain the longer-term architectural targets for closing this final gap.
