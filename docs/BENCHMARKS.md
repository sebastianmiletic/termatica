# Terminal benchmarks

Termatica is optimized for a small native bundle and low memory use. Phase 10
adds an opt-in Metal renderer while retaining AppKit as the reliable default
and automatic fallback. Results below are measured, not projected.

## Test system

- Date: 2026-07-29
- Hardware: MacBook Air, Apple M4, 16 GB memory
- Display: built-in Retina display, 60 Hz
- Font: Monaco 11
- Termatica: 1.1.0 Phase 10 candidate, Metal renderer forced for throughput
- Kitty: 0.48.1
- Ghostty: 1.3.1
- Repetitions: 3
- Raw results: `/tmp/termatica-phase10-metal-threeway-final`
- Native Metal frame run: 240 frames, repeated after final renderer changes

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
| Parser ASCII | **154.5 MB/s** | 74.3 MB/s | 55.8 MB/s |
| Parser Unicode | **128.1 MB/s** | 100.6 MB/s | 78.4 MB/s |
| Parser unique grapheme cells | **97.9 MB/s** | 27.9 MB/s | 36.0 MB/s |
| Parser CSI-heavy | **88.2 MB/s** | 32.0 MB/s | 29.9 MB/s |
| Parser long escape codes | 91.7 MB/s | **259.5 MB/s** | 58.7 MB/s |
| Parser images | 120.5 MB/s | **245.9 MB/s** | 44.5 MB/s |
| Render-enabled ASCII | **156.2 MB/s** | 73.6 MB/s | 57.3 MB/s |
| Render-enabled Unicode | **125.6 MB/s** | 42.7 MB/s | 91.0 MB/s |
| Render-enabled unique grapheme cells | **95.1 MB/s** | 10.5 MB/s | 35.4 MB/s |
| Render-enabled CSI-heavy | **85.2 MB/s** | 32.2 MB/s | 26.1 MB/s |
| Render-enabled long escape codes | 88.2 MB/s | **267.9 MB/s** | 52.0 MB/s |
| Render-enabled images | 118.2 MB/s | **244.7 MB/s** | 37.6 MB/s |
| Core + scrollback ASCII | **82.4 MB/s** | 58.3 MB/s | 56.9 MB/s |
| Core + scrollback Unicode | **92.5 MB/s** | 83.6 MB/s | 79.6 MB/s |
| Core + scrollback CSI-heavy | **87.5 MB/s** | 33.1 MB/s | 30.6 MB/s |
| Startup median, 5 runs | **7.879 ms** | 8.982 ms | 8.331 ms |
| Idle physical footprint, active Metal | **51.3 MiB** | 117.5 MiB | 87.5 MiB |
| Default AppKit idle physical footprint | **32.1 MiB** | 117.5 MiB | 87.5 MiB |
| App bundle allocation | **1,036 KiB** | 160,080 KiB | 63,484 KiB |
| Termatica decoder ASCII | 355.4 MiB/s | Not exposed | Not exposed |
| Termatica decoder Unicode | 376.9 MiB/s | Not exposed | Not exposed |
| Termatica decoder CSI-heavy | 394.7 MiB/s | Not exposed | Not exposed |
| Termatica screen core ASCII | 103.2 MiB/s | Not exposed | Not exposed |
| Termatica screen core Unicode | 70.8 MiB/s | Not exposed | Not exposed |
| Termatica screen core CSI-heavy | 61.0 MiB/s | Not exposed | Not exposed |
| Metal paint p50 / p95 / p99, median of 3 runs | 1.341 / 1.607 / 2.150 ms | Not exposed | Not exposed |
| Frames over 60 / 120 / 240 Hz budget | **0 / 0 / 0 in each 240-frame run** | Not exposed | Not exposed |
| Universal app file size | **1,021,676 bytes** | Not exposed | Not exposed |

The installed Kitty and Ghostty macOS executables do not expose an equivalent
in-process decoder, screen-model, or offscreen frame benchmark. Their former
gaps are covered where a fair external comparison exists: unique graphemes,
long escape codes, images, and the official scrollback mode. Internal rows
remain explicitly non-comparable rather than assigning synthetic results.

Termatica leads 13 of the 15 comparable throughput cases. Kitty remains the
measured target for long escape codes and image protocol throughput; Ghostty
does not lead a row in this run. The active Metal footprint is still lower than
Kitty and Ghostty, but it exceeds Termatica's 40 MiB rollout gate, so AppKit
remains the default.

The Metal paint benchmark measures immutable snapshot construction plus CPU
command encoding plus GPU execution for an ASCII viewport after a one-line
scroll. It excludes display-vsync wait and is not key-to-photon latency.

The Termatica bundle contains the universal arm64/x86_64 app. The exact sum of
shipped file bytes is below 1 MiB; filesystem allocation is higher. Its native
benchmark and regression harness is built separately and is not shipped.
