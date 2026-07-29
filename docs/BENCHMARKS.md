# Terminal benchmarks

Termatica is optimized for a small native bundle and low memory use. The
current AppKit renderer is the reliable fallback for the planned Phase 10 Metal
backend. Results below are measured, not projected.

## Test system

- Date: 2026-07-29
- Hardware: MacBook Air, Apple M4, 16 GB memory
- Display: built-in Retina display, 60 Hz
- Font: Monaco 11
- Termatica: 1.0.2 pre-Phase-10 build, AppKit renderer
- Kitty: 0.48.1
- Ghostty: 1.3.1
- Repetitions: 10
- Raw results: `/tmp/termatica-prephase10-10x`

Run the suite with:

```sh
make release
make benchmark-harness
BENCHMARK_REPETITIONS=10 make benchmark
```

## End-to-end throughput

`kitten __benchmark__` includes PTY transport and terminal model updates.

| Parser | ASCII | Unicode | CSI-heavy |
|---|---:|---:|---:|
| Termatica | **165.0 MB/s** | **113.7 MB/s** | **78.2 MB/s** |
| Kitty | 77.9 MB/s | 102.6 MB/s | 43.9 MB/s |
| Ghostty | 55.3 MB/s | 78.4 MB/s | 31.0 MB/s |

| Render enabled | ASCII | Unicode | CSI-heavy |
|---|---:|---:|---:|
| Termatica | **150.7 MB/s** | **108.4 MB/s** | **72.0 MB/s** |
| Kitty | 76.9 MB/s | 69.6 MB/s | 43.8 MB/s |
| Ghostty | 57.7 MB/s | 71.1 MB/s | 29.1 MB/s |

Termatica leads all six official end-to-end throughput cases in this run.

## Internal throughput

| Case | Decoder only | Decoder + screen model |
|---|---:|---:|
| ASCII | 376.4 MiB/s | 102.8 MiB/s |
| Unicode | 367.6 MiB/s | 71.9 MiB/s |
| CSI-heavy | 387.8 MiB/s | 62.0 MiB/s |

The decoder-only benchmark uses the C decoder sink and excludes PTY, model, and
rendering work. The core benchmark includes screen mutation and scrollback.

## Paint and sustained output

| Measurement | Termatica |
|---|---:|
| ASCII viewport paint p50 | 2.10 ms |
| ASCII viewport paint p95 | 2.16 ms |
| ASCII viewport paint p99 | 2.35 ms |
| Frames over 60 Hz budget | **0 / 240** |
| Frames over 120 Hz budget | **0 / 240** |
| Frames over 240 Hz budget | **0 / 240** |
| Sustained throughput | 95.0 MiB/s |
| Minimum 250 ms window | 93.6 MiB/s |

Paint is a warmed, full-surface offscreen AppKit `cacheDisplay` measurement of
an ASCII terminal viewport after a one-line scroll. It is not key-to-photon
latency and does not claim the same frame cost for Unicode fallback shaping,
images, transparency, or visual effects.

## Memory and size

| Terminal | Idle physical footprint | App bundle allocation |
|---|---:|---:|
| Termatica | **37.7 MiB** | **956 KiB** |
| Kitty | 120.2 MiB | 160,080 KiB |
| Ghostty | 80.7 MiB | 63,484 KiB |

The Termatica bundle contains the universal arm64/x86_64 app. Its native
benchmark and regression harness is built separately and is not shipped in the
bundle.
