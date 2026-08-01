# Terminal benchmarks

This is the reproducible six-terminal macOS performance snapshot used for
Termatica 1.4.0. It records both the pre-change baseline and the final release
candidate; measured regressions and limitations are intentionally visible.

## Test system and method

- Date: 2026-08-01
- Hardware: Apple M4 Mac, 16 GB memory
- OS: macOS 26.5.2 (25F84), arm64
- Font: Monaco 11 in every terminal, with system fallback for missing glyphs
- Termatica: 1.3.3 baseline and 1.4.0 final candidate
- Kitty: 0.48.1
- Ghostty: 1.3.1
- Alacritty: 0.17.0
- WezTerm: 20240203-110809-5046fc22
- Rio: 0.5.2
- Repetitions: 10 per `kitten __benchmark__` workload
- Raw local output: `/tmp/termatica-benchmark-pre-2026-08-01` and
  `/tmp/termatica-benchmark-final-2026-08-01`

The command was identical before and after:

```sh
BENCHMARK_REPETITIONS=10 \
BENCHMARK_TIMEOUT_SECONDS=180 \
BENCHMARK_OUTPUT=/tmp/termatica-benchmark-... \
scripts/benchmark-terminals.sh
```

The harness launches a fresh process for parser, render, and scrollback modes.
It applies Monaco 11 and the most isolated supported config to each terminal.
Higher throughput is better. The geometric mean is a compact summary across
heterogeneous workloads, not a claim that every row is equally important.

## Final end-to-end throughput

All values are MB/s.

| Mode / workload | Termatica | Kitty | Ghostty | Alacritty | WezTerm | Rio |
|---|---:|---:|---:|---:|---:|---:|
| Parser ASCII | **146.3** | 77.7 | 57.5 | 71.1 | 19.3 | 68.9 |
| Parser Unicode | 100.8 | 102.3 | 78.2 | **103.5** | 29.7 | 54.1 |
| Parser unique graphemes | **56.4** | 27.7 | 36.7 | 44.8 | 41.2 | 41.5 |
| Parser CSI-heavy | **68.6** | 33.3 | 30.4 | 52.3 | 12.9 | 36.9 |
| Parser long escapes | **289.5** | 269.0 | 59.0 | 128.2 | 166.4 | 78.2 |
| Parser images | **280.2** | 247.7 | 44.6 | 230.8 | 130.0 | 102.6 |
| Render ASCII | **144.2** | 77.7 | 57.1 | 86.1 | 18.8 | 128.7 |
| Render Unicode | 99.3 | 70.4 | 66.7 | **115.6** | 24.3 | 9.6 |
| Render unique graphemes | **54.2** | 17.1 | 33.9 | 48.0 | 29.5 | **54.2** |
| Render CSI-heavy | **68.2** | 33.5 | 21.0 | 55.2 | 12.9 | 46.1 |
| Render long escapes | 254.0 | **266.6** | 56.6 | 143.0 | 168.0 | 103.3 |
| Render images | 243.3 | **248.9** | 43.7 | 243.4 | 129.6 | 137.9 |
| Scrollback ASCII | **108.2** | 61.2 | 57.5 | 70.6 | 18.9 | 68.5 |
| Scrollback Unicode | 94.2 | 84.5 | 80.6 | **97.0** | 29.1 | 52.9 |
| Scrollback CSI-heavy | **68.6** | 43.5 | 30.7 | 52.2 | 13.1 | 37.8 |

Termatica leads or ties 10 of 15 workloads. Across all 15 rows:

| Terminal | Geometric mean |
|---|---:|
| Termatica | **117.0 MB/s** |
| Alacritty | 88.8 MB/s |
| Kitty | 77.7 MB/s |
| Rio | 57.9 MB/s |
| Ghostty | 47.1 MB/s |
| WezTerm | 35.5 MB/s |

## Termatica before and after

The baseline was captured from the 1.3.3 checkout before the fixes. The final
candidate raises the 15-workload geometric mean from 114.1 to 117.0 MB/s
(+2.6%). Individual rows remain useful because the combined score hides
tradeoffs.

| Workload | 1.3.3 baseline | 1.4.0 final | Change |
|---|---:|---:|---:|
| Parser ASCII | 134.3 | 146.3 | +8.9% |
| Parser Unicode | 101.9 | 100.8 | -1.1% |
| Parser unique graphemes | 54.6 | 56.4 | +3.3% |
| Parser CSI-heavy | 66.6 | 68.6 | +3.0% |
| Parser long escapes | 228.2 | 289.5 | +26.9% |
| Parser images | 171.5 | 280.2 | +63.4% |
| Render ASCII | 145.5 | 144.2 | -0.9% |
| Render Unicode | 105.0 | 99.3 | -5.4% |
| Render unique graphemes | 54.2 | 54.2 | 0.0% |
| Render CSI-heavy | 67.0 | 68.2 | +1.8% |
| Render long escapes | 305.4 | 254.0 | -16.8% |
| Render images | 310.0 | 243.3 | -21.5% |
| Scrollback ASCII | 108.4 | 108.2 | -0.2% |
| Scrollback Unicode | 95.4 | 94.2 | -1.3% |
| Scrollback CSI-heavy | 67.9 | 68.6 | +1.0% |

The large escape/image swings occurred without corresponding changes to those
parsers and competitor results also moved between full matrices. They should be
treated as whole-system variance until reproduced on more machines. The release
does not claim every individual throughput row improved.

## Startup, memory, and size

Lower is better. Startup measures process launch until the child shell writes
and fsyncs a probe file. It is not first-pixel or key-to-photon latency. The
maximum is reported instead of a p95 because there are only five samples.
Physical footprint is one post-settle snapshot and is especially sensitive to
macOS cache and compression state.

| Terminal | Shell-ready median / max | Physical footprint | App allocation |
|---|---:|---:|---:|
| Termatica | 8.782 / 11.144 ms | **30.3 MiB** | **1013.2 KiB** |
| Kitty | 9.494 / 13.228 ms | 120.5 MiB | 160,080 KiB |
| Ghostty | **8.055 / 9.350 ms** | 89.1 MiB | 63,484 KiB |
| Alacritty | 11.094 / 12.400 ms | 65.5 MiB | 14,328 KiB |
| WezTerm | 9.048 / 9.999 ms | 50.9 MiB | 259,840 KiB |
| Rio | 9.502 / 9.588 ms | 48.4 MiB | 41,992 KiB |

## Termatica internal measurements

These native-harness diagnostics are regression signals, not cross-terminal
wins because competitors do not expose equivalent entry points.

| Measurement | Final result |
|---|---:|
| C decoder ASCII / Unicode / CSI | 381.7 / 384.4 / 346.7 MiB/s |
| Screen core ASCII / Unicode / CSI | 151.4 / 99.1 / 76.5 MiB/s |
| AppKit offscreen paint p50 / p95 / p99 | 1.453 / 1.507 / 1.538 ms |
| Parse-to-paint p50 / p95 / p99 | 1.432 / 1.485 / 1.514 ms |
| Frames over 60 / 120 / 240 Hz budgets | 0 / 0 / 0 of 240 |
| Sustained output | 139.5 MiB/s |
| Minimum 250 ms sustained window | 137.6 MiB/s |

The paint test is a warmed, offscreen AppKit cache-display path. It includes no
display-vsync wait. The Metal test in `make check` verifies real GPU submission,
pixel variation, cache invalidation, and automatic AppKit fallback, but does not
claim a camera-measured latency.

## Interpretation and proof boundaries

`kitten __benchmark__` is a common end-to-end protocol, but it remains Kitty's
benchmark. Render mode permits asynchronous presentation and therefore does not
measure the time until light reaches the display. Terminals can also reject or
discard unsupported graphics controls at different points, so image throughput
does not by itself prove equivalent image presentation.

The benchmark does not measure key-to-photon latency, first visible frame,
electrical energy, GPU utilization, resize smoothness, or subjective TUI feel.
Those require high-speed capture, Instruments or power sampling, and scripted
real-window interaction. Correctness, Unicode shaping, protocol coverage,
security, and config isolation are verified separately by regression tests,
Clang analysis, ASan/UBSan, and renderer self-tests.
