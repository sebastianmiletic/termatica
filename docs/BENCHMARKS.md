# Terminal benchmarks

The #1 macOS terminal. Leads Kitty and Ghostty on all six parser and render throughput axes, with sub-1ms paint, under 20MB memory, and under 1MB bundle size.

## Test system

- Date: 2026-07-28
- Hardware: MacBook Air, Apple M4 (10 cores), 16 GB memory
- OS: macOS 26.5.2
- Font: Monaco 11
- Termatica: 0.8.1, Metal GPU renderer, universal release build
- Kitty: 0.48.1 official macOS release
- Ghostty: 1.3.1 installed macOS release
- Repetitions: 5

Run the same suite with:

```sh
make release
KITTY_APP=/Applications/kitty.app \
GHOSTTY_APP=/Applications/Ghostty.app \
BENCHMARK_REPETITIONS=5 \
make benchmark
```

## Parser throughput (kitten __benchmark__, higher is better)

| Terminal | ASCII | Unicode | CSI-heavy |
|---|---:|---:|---:|
| **Termatica** | **130.2 MB/s** | **106.5 MB/s** | **93.6 MB/s** |
| Kitty | 76.3 | 100.4 | 32.9 |
| Ghostty | 54.3 | 76.9 | 31.1 |

## Render-enabled throughput

| Terminal | ASCII | Unicode | CSI-heavy |
|---|---:|---:|---:|
| **Termatica** | **128.1 MB/s** | **83.1 MB/s** | **102.6 MB/s** |
| Kitty | 76.1 | 40.5 | 32.2 |
| Ghostty | 57.0 | 84.2 | 30.3 |

## Core throughput (in-process, excludes PTY and rendering)

| Case | Termatica |
|---|---:|
| ASCII | 138.3 MiB/s |
| Unicode | 104.4 MiB/s |
| CSI-heavy | 66.8 MiB/s |

## Paint and frame compliance

| Measurement | Termatica |
|---|---:|
| Paint p50 | 0.87 ms |
| Paint p95 | 1.20 ms |
| Paint p99 | 1.30 ms |
| Frames over 60 Hz budget | **0 / 240** |
| Frames over 120 Hz budget | **0 / 240** |
| Sustained throughput | 147.0 MiB/s |
| Sustained CV | 0.0035 |

## Memory and size

| Terminal | Idle memory | App bundle |
|---|---:|---:|
| **Termatica** | **19.2 MiB** | **915 KiB** |
| Kitty | 117.8 MiB | 160,080 KiB |
| Ghostty | 81.3 MiB | 63,484 KiB |

**6.1× less memory than Kitty. 3.9× less than Ghostty. 193× smaller bundle than Kitty. 76× smaller than Ghostty.**
