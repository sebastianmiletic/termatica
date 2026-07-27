# Terminal benchmarks

These are reproducible engineering measurements, not a claim that one number represents an entire terminal. The suite records parser throughput, a rendering-enabled asynchronous throughput probe, Termatica's in-process core throughput, idle physical memory, child-ready launch latency, and bundle size.

## Test system

- Date: 2026-07-27
- Hardware: MacBook Air, Apple M4 (10 cores), 16 GB memory
- OS: macOS 26.5.2 (25F84)
- Font: Monaco 11
- Termatica: 0.5.1 worktree, universal release build, blur disabled
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
| Termatica | 16.4 MB/s | 17.7 MB/s | 56.8 MB/s |
| Kitty | 76.3 MB/s | 100.7 MB/s | 42.9 MB/s |
| Ghostty | 56.4 MB/s | 78.7 MB/s | 30.0 MB/s |

Termatica now leads this run's CSI-heavy case, but its plain-text and Unicode parser throughput remains well behind Kitty and Ghostty. That is the clearest remaining performance gap.

With the benchmark's `--render` option, which permits rendering but still measures asynchronous parse completion rather than visible frame latency:

| Terminal | ASCII | Unicode | CSI-heavy |
|---|---:|---:|---:|
| Termatica | 15.6 MB/s | 16.1 MB/s | 65.4 MB/s |
| Kitty | 75.8 MB/s | 46.8 MB/s | 42.9 MB/s |
| Ghostty | 56.0 MB/s | 83.0 MB/s | 30.4 MB/s |

Do not interpret that table as GPU frame rate or key-to-photon latency. The experience probe below adds paint-duration and sustained-output coverage; true key-to-photon comparison still needs synchronized screen capture or compositor instrumentation.

## Termatica core before and after

`make benchmark-core` sends 32 MiB per case directly through Termatica's parser and screen model. It excludes PTY transfer and window presentation, making it useful for regression tracking.

| Case | Previous release build | Current build | Change |
|---|---:|---:|---:|
| ASCII | 6.564 MiB/s | 16.083 MiB/s | 2.45× |
| Unicode | 6.567 MiB/s | 11.307 MiB/s | 1.72× |
| CSI-heavy | 8.861 MiB/s | 12.965 MiB/s | 1.46× |

The improvement comes from printable-ASCII batching, reusable history lines, removal of disabled-OSC bookkeeping, `-O3` plus link-time optimization, and bounded PTY slices without a forced one-millisecond delay. The extracted decoder adds a small callback boundary relative to the immediately preceding monolithic build, in exchange for keeping terminal byte parsing independent from AppKit.

## Interaction, paint, and sustained-output probe

`make benchmark-experience` adds measurements that parser throughput cannot describe. The current 240-frame, three-second run produced:

| Measurement | Result |
|---|---:|
| One-line scroll plus offscreen paint, p50 | 7.711 ms |
| One-line scroll plus offscreen paint, p95 | 8.381 ms |
| One-line scroll plus offscreen paint, p99 | 9.080 ms |
| Frames above the 60 Hz budget | 1 / 240 |
| Frames above the 120 Hz budget | 15 / 240 |
| Parse plus immediate offscreen paint, p50 | 4.145 ms |
| Parse plus immediate offscreen paint, p95 | 4.494 ms |
| Parse plus immediate offscreen paint, p99 | 4.866 ms |
| Sustained parser/model throughput | 10.527 MiB/s |
| Slowest 250 ms sustained window | 10.389 MiB/s |
| Sustained-window coefficient of variation | 0.0078 |
| Process CPU seconds per wall second | 0.999 |

The paint probe uses AppKit's offscreen `cacheDisplayInRect` path after moving history by one line. It measures how long Termatica needs to produce pixels, not compositor presentation or hardware key-to-photon latency. The interaction probe measures parse plus immediate paint, not physical keyboard latency. CPU seconds per wall second is an energy proxy, not electrical power. A true cross-terminal visual-latency comparison still requires synchronized high-speed capture or compositor instrumentation.

## Idle memory and startup

Each terminal opened one 128×32 window running the same sleeping Python probe. `vmmap` physical footprint is used instead of RSS because RSS includes shared mappings that differ substantially between applications.

| Terminal | Physical footprint | Median child-ready latency | App bundle |
|---|---:|---:|---:|
| Termatica | 33.3 MiB | 8.485 ms | 868 KiB on disk |
| Kitty | 117.8 MiB | 9.292 ms | 160,080 KiB on disk |
| Ghostty | 121.0 MiB | 8.070 ms | 63,484 KiB on disk |

Child-ready latency is measured from process launch until the child records `monotonic_ns()`. It is not time-to-first-painted-frame. Bundle values use `du -sk`; Termatica's current raw file total is 850,708 bytes (830.8 KiB). The memory and launch values above are from the earlier same-day comparison build; the current bundle size and the current core/experience results below were refreshed after the native-core refactor.

## Competitive position

Termatica is competitive here on startup, memory, distribution size, and CSI-heavy command streams. The extracted native decoder, per-terminal background model queues, cell-bounded damage, adaptive coalescing, scroll anchoring, alternate-screen state, mouse/focus protocols, and synchronized output materially broaden real application compatibility.

Kitty and Ghostty still lead in plain-text/Unicode throughput, GPU rendering architecture, cross-platform reach, graphics protocols, ligatures/shaping breadth, and ecosystem maturity. Termatica remains intentionally macOS-native and universal across Apple Silicon and Intel; matching their operating-system portability would require a platform abstraction or a separate frontend rather than an AppKit optimization.
