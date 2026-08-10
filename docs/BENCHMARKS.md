# Terminal benchmarks

This document reports measured results, the commands that produced them, and
the limits of those measurements. It does not infer terminal compatibility or
visual quality from throughput alone.

## In-app benchmark

Run this from a shell inside the Termatica instance to be measured:

```sh
t benchmark
# short form
t b
```

The CLI asks the already-running app to benchmark an isolated offscreen
terminal using the active visual configuration. It does not replace or close a
PTY, tab, process, scrollback buffer, or window. The report includes:

- Termatica version and build
- active config, renderer, font, and display refresh rate
- process physical footprint before and after the sample
- open window and terminal counts
- median ASCII, Unicode, and CSI parser/model throughput over three 1 MiB runs
- warmed offscreen AppKit text and image paint FPS, p50, and p95 over 20 frames

The paint number is not Metal FPS, display FPS, or physical key-to-photon
latency. It excludes WindowServer, vsync, panel scanout, and pixel response.

One isolated live-app verification on 2026-08-10 returned:

| Measurement | Result |
|---|---:|
| ASCII parser/model | 261.8 MiB/s |
| Unicode parser/model | 169.7 MiB/s |
| CSI parser/model | 186.8 MiB/s |
| Offscreen text paint | 620.1 FPS; 1.613 ms p50; 1.807 ms p95 |
| Offscreen image paint | 587.7 FPS; 1.701 ms p50; 1.858 ms p95 |
| Process footprint | 35.0 MiB before; 38.9 MiB after |

That sample used Termatica 1.4.2 build 50, the `custom` config, AppKit,
Monaco 11, and a 60 Hz display. In-app results are configuration- and
machine-specific and should not be compared with the cross-terminal protocol
results below.

## Cross-terminal method

- Date: 2026-08-10
- Hardware: Apple M4 Mac, 16 GB memory
- OS: macOS 26.5.2, arm64
- Termatica: local 1.5.0 build after the rendering changes in this tree
- Kitty: 0.48.1
- Ghostty: 1.3.1
- Alacritty: 0.17.0
- WezTerm: 20240203-110809-5046fc22
- Rio: 0.5.2
- Font: Monaco 11 where the terminal exposed an isolated command-line setting
- Throughput repetitions: 3
- Startup launches: 5
- Raw output: `/tmp/termatica-render-fixes-final-20260810`

```sh
BENCHMARK_REPETITIONS=3 \
BENCHMARK_OUTPUT=/tmp/termatica-render-fixes-final-20260810 \
make benchmark
```

The harness launches a fresh process for each mode. Higher MB/s is better;
lower startup and memory are better. Values are reported by Kitty's
`kitten __benchmark__` protocol.

## Complete throughput matrix

| Mode / workload (MB/s) | Termatica | Kitty | Ghostty | Alacritty | WezTerm | Rio |
|---|---:|---:|---:|---:|---:|---:|
| Parser ASCII | **136.7** | 95.0 | 80.3 | 129.6 | 32.5 | 125.4 |
| Parser Unicode | 169.7 | 153.4 | 124.8 | **186.2** | 56.8 | 95.5 |
| Parser unique graphemes | **144.3** | 50.3 | 58.3 | 82.0 | 76.7 | 73.5 |
| Parser CSI-heavy | **168.1** | 72.8 | 51.2 | 92.8 | 24.5 | 68.5 |
| Parser long escapes | 226.0 | **327.6** | 92.6 | 223.6 | 317.9 | 150.1 |
| Parser image stream | 261.9 | 275.9 | 73.3 | **417.9** | 238.4 | 180.4 |
| Render ASCII | 158.6 | 115.7 | 88.2 | 129.3 | 30.6 | **167.3** |
| Render Unicode | 160.3 | 48.3 | 175.2 | **203.7** | 41.9 | 5.3 |
| Render unique graphemes | **159.9** | 21.4 | 71.7 | 89.7 | 55.4 | 106.0 |
| Render CSI-heavy | **163.4** | 72.0 | 50.9 | 101.0 | 21.3 | 85.3 |
| Render long escapes | **291.1** | 271.9 | 102.0 | 223.7 | 267.8 | 163.9 |
| Render image stream | 332.0 | 271.9 | 74.8 | **447.4** | 203.4 | 255.9 |
| Scrollback ASCII | **141.8** | 82.5 | 91.8 | 100.0 | 31.2 | 98.7 |
| Scrollback Unicode | **188.1** | 129.5 | 129.3 | 166.2 | 48.3 | 98.2 |
| Scrollback CSI-heavy | **165.9** | 72.2 | 49.1 | 97.5 | 21.1 | 69.1 |
| 15-workload geometric mean | **184.1** | 105.9 | 82.0 | 154.2 | 61.5 | 93.5 |

## Results where another terminal was faster

| Measurement | Faster terminal | Faster result | Termatica | Difference |
|---|---|---:|---:|---:|
| Fresh shell-ready median, 5 launches | Rio | **3.513 ms** | 4.307 ms | Rio 0.794 ms lower |
| Parser Unicode | Alacritty | **186.2 MB/s** | 169.7 MB/s | Alacritty 9.7% higher |
| Parser long escapes | Kitty | **327.6 MB/s** | 226.0 MB/s | Kitty 45.0% higher |
| Parser image stream | Alacritty | **417.9 MB/s** | 261.9 MB/s | Alacritty 59.6% higher |
| Render ASCII | Rio | **167.3 MB/s** | 158.6 MB/s | Rio 5.5% higher |
| Render Unicode | Alacritty | **203.7 MB/s** | 160.3 MB/s | Alacritty 27.1% higher |
| Render image stream | Alacritty | **447.4 MB/s** | 332.0 MB/s | Alacritty 34.8% higher |

WezTerm and Ghostty did not lead a throughput row in this particular matrix.
This is a statement about this run, not a general claim about those applications.

The Alacritty image row must not be read as evidence that Alacritty displayed
the same image. The input contains terminal graphics controls; a terminal can
increase reported throughput by rejecting or discarding an unsupported
protocol. Visual equivalence was not instrumented by this harness.

## Startup and memory

Startup is process launch until the benchmark child shell writes and fsyncs a
ready file. It is not first visible frame. Memory is one post-settle physical
footprint sample and varies with macOS caching and compression.

| Terminal | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|
| Termatica | 4.307 ms | **30.3 MiB** | **1,192 KiB** |
| Kitty | 6.860 ms | 121.2 MiB | 160,080 KiB |
| Ghostty | 5.321 ms | 128.3 MiB | 63,484 KiB |
| Alacritty | 4.185 ms | 66.5 MiB | 14,328 KiB |
| WezTerm | 4.955 ms | 46.1 MiB | 259,840 KiB |
| Rio | **3.513 ms** | 42.3 MiB | 41,992 KiB |

## macOS Terminal boundary

The automated final harness did not include macOS Terminal because it cannot
apply the same isolated command-line configuration. A separate same-day run
using the user's Terminal profile produced a 68.5 MB/s geometric mean and no
throughput row above Termatica. Those values are not included in the normalized
matrix because the profile and launch controls were different. Terminal's
profiles, window groups, marks/bookmarks, AppleScript integration, and selectable
legacy encodings remain functional differences, not benchmark results.

## Interpretation limits

`kitten __benchmark__` is a useful common workload, but render mode permits
asynchronous presentation and does not measure photons reaching the display.
The results do not measure first visible frame, GPU utilization, resize
smoothness, electrical power, accessibility, correctness, protocol coverage,
or subjective TUI behavior. Correctness is checked separately by the decoder,
terminal, renderer, real-PTY, and sanitizer gates.
