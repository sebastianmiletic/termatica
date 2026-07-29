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
- Raw results: `/tmp/termatica-phase10-baseline-20260729-rerun`

Run the suite with:

```sh
make release
make benchmark-harness
BENCHMARK_REPETITIONS=10 BENCHMARK_TIMEOUT_SECONDS=300 make benchmark
```

## Results

Higher throughput is better; lower latency, memory, and size are better.
`kitten __benchmark__` supplies the identical end-to-end workload to all three
terminals. Its render mode enables terminal rendering, but remains an
asynchronous throughput test rather than a frame-time measurement.

| Measurement | Termatica | Kitty | Ghostty |
|---|---:|---:|---:|
| Parser ASCII | **165.4 MB/s** | 78.1 MB/s | 57.5 MB/s |
| Parser Unicode | **113.7 MB/s** | 102.6 MB/s | 78.1 MB/s |
| Parser unique grapheme cells | **94.2 MB/s** | 28.3 MB/s | 36.6 MB/s |
| Parser CSI-heavy | **78.2 MB/s** | 44.0 MB/s | 30.7 MB/s |
| Parser long escape codes | 89.5 MB/s | **265.0 MB/s** | 58.9 MB/s |
| Parser images | 119.8 MB/s | **247.5 MB/s** | 44.6 MB/s |
| Render-enabled ASCII | **152.0 MB/s** | 77.9 MB/s | 57.7 MB/s |
| Render-enabled Unicode | **108.1 MB/s** | 50.8 MB/s | 83.3 MB/s |
| Render-enabled unique grapheme cells | **69.6 MB/s** | 15.0 MB/s | 37.4 MB/s |
| Render-enabled CSI-heavy | **73.3 MB/s** | 43.9 MB/s | 30.1 MB/s |
| Render-enabled long escape codes | 89.4 MB/s | **265.6 MB/s** | 58.8 MB/s |
| Render-enabled images | 119.2 MB/s | **248.5 MB/s** | 44.7 MB/s |
| Core + scrollback ASCII | **90.3 MB/s** | 61.3 MB/s | 56.6 MB/s |
| Core + scrollback Unicode | **90.1 MB/s** | 84.8 MB/s | 81.1 MB/s |
| Core + scrollback CSI-heavy | **73.9 MB/s** | 44.0 MB/s | 31.2 MB/s |
| Startup median, 5 runs | 9.229 ms | 11.009 ms | **6.867 ms** |
| Idle physical footprint | **37.9 MiB** | 120.1 MiB | 125.0 MiB |
| App bundle allocation | **956 KiB** | 160,080 KiB | 63,484 KiB |
| Termatica decoder ASCII | 368.8 MiB/s | Not exposed | Not exposed |
| Termatica decoder Unicode | 385.5 MiB/s | Not exposed | Not exposed |
| Termatica decoder CSI-heavy | 393.0 MiB/s | Not exposed | Not exposed |
| Termatica screen core ASCII | 103.6 MiB/s | Not exposed | Not exposed |
| Termatica screen core Unicode | 72.2 MiB/s | Not exposed | Not exposed |
| Termatica screen core CSI-heavy | 60.9 MiB/s | Not exposed | Not exposed |
| AppKit paint p50 / p95 / p99 | 2.091 / 2.157 / 2.258 ms | Not exposed | Not exposed |
| Frames over 60 / 120 / 240 Hz budget | **0 / 0 / 0 of 240** | Not exposed | Not exposed |
| Sustained / minimum 250 ms window | 95.1 / 92.6 MiB/s | Not exposed | Not exposed |

The installed Kitty and Ghostty macOS executables do not expose an equivalent
in-process decoder, screen-model, or offscreen frame benchmark. Their former
gaps are covered where a fair external comparison exists: unique graphemes,
long escape codes, images, and the official scrollback mode. Internal rows
remain explicitly non-comparable rather than assigning synthetic results.

Termatica leads 11 of the 15 comparable throughput cases. Kitty remains the
measured target for long escape codes and image protocol throughput; Ghostty
has the fastest measured startup. Phase 10 must preserve these measured wins
without claiming that asynchronous render throughput is GPU frame latency.

The paint benchmark is a warmed, full-surface offscreen AppKit `cacheDisplay`
of an ASCII terminal viewport after a one-line scroll. It is not key-to-photon
latency and does not represent Unicode fallback shaping, images, transparency,
or visual effects.

The Termatica bundle contains the universal arm64/x86_64 app. Its native
benchmark and regression harness is built separately and is not shipped in the
bundle.
