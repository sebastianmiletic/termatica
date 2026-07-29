# Terminal benchmarks

Termatica is optimized for a small native bundle and low memory use. The
current AppKit renderer is the reliable fallback for the planned Phase 10 Metal
backend. Results below are measured, not projected.

## Test system

- Date: 2026-07-29
- Hardware: MacBook Air, Apple M4, 16 GB memory
- Display: built-in Retina display, 60 Hz
- Font: Monaco 11
- Termatica: 1.0.1 pre-Phase-10 build, AppKit renderer
- Kitty: 0.48.1
- Ghostty: 1.3.1
- Repetitions: 3
- Raw results: `/tmp/termatica-v101-prephase10`

Run the suite with:

```sh
make release
make benchmark-harness
BENCHMARK_REPETITIONS=3 make benchmark
```

## End-to-end throughput

`kitten __benchmark__` includes PTY transport and terminal model updates.

| Parser | ASCII | Unicode | CSI-heavy |
|---|---:|---:|---:|
| Termatica | 44.9 MB/s | 36.2 MB/s | **54.0 MB/s** |
| Kitty | **75.1 MB/s** | **101.1 MB/s** | 43.5 MB/s |
| Ghostty | 56.6 MB/s | 78.2 MB/s | 30.0 MB/s |

| Render enabled | ASCII | Unicode | CSI-heavy |
|---|---:|---:|---:|
| Termatica | 43.5 MB/s | 34.7 MB/s | **53.2 MB/s** |
| Kitty | **74.1 MB/s** | 22.3 MB/s | 42.9 MB/s |
| Ghostty | 58.2 MB/s | **88.6 MB/s** | 30.4 MB/s |

Termatica leads CSI-heavy throughput. ASCII and Unicode PTY/model throughput
remain open optimization targets.

## Internal throughput

| Case | Decoder only | Decoder + screen model |
|---|---:|---:|
| ASCII | 372.0 MiB/s | 111.6 MiB/s |
| Unicode | 367.1 MiB/s | 73.1 MiB/s |
| CSI-heavy | 354.4 MiB/s | 64.7 MiB/s |

The decoder-only benchmark uses the C decoder sink and excludes PTY, model, and
rendering work. The core benchmark includes screen mutation and scrollback.

## Paint and sustained output

| Measurement | Termatica |
|---|---:|
| ASCII viewport paint p50 | 2.11 ms |
| ASCII viewport paint p95 | 2.17 ms |
| ASCII viewport paint p99 | 2.26 ms |
| Frames over 60 Hz budget | **0 / 240** |
| Frames over 120 Hz budget | **0 / 240** |
| Frames over 240 Hz budget | **0 / 240** |
| Sustained throughput | 101.2 MiB/s |
| Minimum 250 ms window | 97.2 MiB/s |

Paint is a warmed, full-surface offscreen AppKit `cacheDisplay` measurement of
an ASCII terminal viewport after a one-line scroll. It is not key-to-photon
latency and does not claim the same frame cost for Unicode fallback shaping,
images, transparency, or visual effects.

## Memory and size

| Terminal | Idle physical footprint | App bundle allocation |
|---|---:|---:|
| Termatica | **37.3 MiB** | **940 KiB** |
| Kitty | 120.4 MiB | 160,080 KiB |
| Ghostty | 82.7 MiB | 63,484 KiB |

The Termatica bundle contains the universal arm64/x86_64 app. Its native
benchmark and regression harness is built separately and is not shipped in the
bundle.
