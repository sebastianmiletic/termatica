# Terminal benchmarks

This is the current six-terminal macOS performance snapshot for Termatica
1.2.0. The comparison is measured rather than projected, and known gaps are
kept visible.

## Test system and method

- Date: 2026-07-29
- Hardware: Apple M4 Mac, 16 GB memory
- OS: macOS 26.5.2 (25F84), arm64
- Font: Monaco 11 in every terminal, with system fallback for missing glyphs
- Termatica: 1.2.0, Metal renderer explicitly selected for the throughput runs
- Kitty: 0.48.1
- Ghostty: 1.3.1
- Alacritty: 0.17.0
- WezTerm: 20240203-110809-5046fc22
- Rio: 0.5.2
- Raw output: `/tmp/termatica-final-three-batches`,
  `/tmp/termatica-v120-clean-startup-final`,
  `/tmp/termatica-benchmark-20260729-v120-extra`, and
  `/tmp/termatica-benchmark-20260729-v120-resources`

Termatica's throughput figures are the median of three complete, clean
three-repeat `kitten __benchmark__` batches after the optimizations described
below. Competitor figures are the unchanged same-day three-repeat baselines;
each terminal received the same cases. Higher throughput is better.

The updated Termatica startup result uses 30 clean launches. Competitor startup
uses the same-day 15-launch interleaved baseline (14 valid Kitty samples after
one corrupt timestamp was rejected). It measures process launch to the point
where the child shell can execute and fsync a probe file; it is not first-frame
or key-to-photon latency. Resource figures are the median of three launches
after a five-second settle, followed by four one-second CPU samples.

The complete source regression gate passed immediately before the run:

```sh
make check
```

## End-to-end throughput

All values are MB/s.

| Mode / workload | Termatica | Kitty | Ghostty | Alacritty | WezTerm | Rio |
|---|---:|---:|---:|---:|---:|---:|
| Parser ASCII | **166.6** | 74.2 | 54.1 | 56.3 | 18.2 | 67.5 |
| Parser Unicode | **132.4** | 101.6 | 78.9 | 57.0 | 15.2 | 49.5 |
| Parser unique graphemes | **101.7** | 27.1 | 36.1 | 28.6 | 27.8 | 41.0 |
| Parser CSI-heavy | **93.7** | 32.2 | 31.2 | 36.6 | 6.7 | 33.3 |
| Parser long escapes | 259.8 | **262.2** | 58.6 | 80.3 | 92.2 | 64.1 |
| Parser images | **248.3** | 247.1 | 44.4 | 169.7 | 100.6 | 94.2 |
| Render ASCII | **163.3** | 73.7 | 56.9 | 82.4 | 11.1 | 122.2 |
| Render Unicode | **130.8** | 22.8 | 86.0 | 106.0 | 14.0 | 2.9 |
| Render unique graphemes | **98.9** | 27.1 | 24.8 | 46.5 | 7.0 | 49.2 |
| Render CSI-heavy | **90.6** | 32.4 | 26.3 | 49.7 | 2.0 | 41.6 |
| Render long escapes | 249.9 | **260.2** | 56.9 | 91.1 | 16.5 | 97.9 |
| Render images | **251.7** | 241.6 | 42.6 | 180.0 | 15.3 | 136.9 |
| Scrollback ASCII | **96.7** | 59.0 | 56.2 | 66.6 | 6.9 | 65.9 |
| Scrollback Unicode | **106.9** | 83.6 | 79.3 | 88.5 | 8.4 | 29.9 |
| Scrollback CSI-heavy | **92.6** | 43.0 | 30.1 | 50.4 | 4.0 | 35.2 |

Termatica leads 13 of the 15 cases. Kitty leads parser and render long
escapes; Termatica leads both image cases.

The geometric mean across these heterogeneous cases is useful only as a compact
summary, not as a substitute for the workload rows:

| Terminal | Two-batch geometric mean |
|---|---:|
| Termatica | **140.0 MB/s** |
| Kitty | 72.7 MB/s |
| Alacritty | 69.8 MB/s |
| Rio | 48.4 MB/s |
| Ghostty | 47.2 MB/s |
| WezTerm | 13.2 MB/s |

## Startup, memory, idle CPU, and bundle size

Lower is better. RSS and physical footprint are both included because macOS
shared and compressed memory accounting can rank processes differently.

| Terminal | Shell-ready median / p95 | RSS median | Physical footprint median | Idle CPU median | App allocation |
|---|---:|---:|---:|---:|---:|
| Termatica | 8.817 / **9.305 ms** | **85.2 MiB** | **29.4 MiB** | **0.000%** | **984.1 KiB** |
| Kitty | 8.729 / 10.720 ms | 118.2 MiB | 73.7 MiB | **0.000%** | 160,080 KiB |
| Ghostty | **8.324 / 11.937 ms** | 130.9 MiB | 94.4 MiB | 0.025% | 63,484 KiB |
| Alacritty | 9.880 / 13.973 ms | 90.6 MiB | 66.1 MiB | 0.025% | 14,328 KiB |
| WezTerm | 9.286 / 14.923 ms | 106.4 MiB | **45.4 MiB** | 0.325% | 275,100 KiB |
| Rio | 9.264 / 14.045 ms | 97.3 MiB | 46.1 MiB | 0.025% | 41,992 KiB |

Termatica is not the startup-median winner in this run, but its shell-ready
median is 2.5% lower and p95 is 19.8% lower than the initial 1.2.0 snapshot.
Its default AppKit path has the lowest measured RSS and physical footprint and
remains under 30 MiB. Termatica is also the clear bundle-size winner and its
idle CPU was below sampling resolution.

## Termatica internal measurements

Competitors do not expose equivalent in-process entry points, so these rows are
Termatica diagnostics and are not cross-terminal wins.

| Measurement | Result |
|---|---:|
| C decoder ASCII / Unicode / CSI | 364.8 / 385.6 / 388.3 MiB/s |
| Screen core ASCII / Unicode / CSI | 102.5 / 73.2 / 61.5 MiB/s |
| AppKit offscreen paint p50 / p95 / p99 | 1.533 / 1.648 / 1.715 ms |
| AppKit frames over 60 / 120 / 240 Hz budget | 0 / 0 / 0 of 240 |
| Metal p50, median of three 240-frame runs | 1.314 ms |
| Metal p95 / p99, median of three runs | 2.214 / 3.516 ms |
| Metal frames over 60 / 120 Hz budget | 0 / 0 in every run |
| Metal frames over 240 Hz budget | 0 / 0 / 0 across the three runs |
| CI-built universal app file bytes | 1,007,758 bytes |
| CI-built universal executable bytes | 959,984 bytes |

The Metal test includes immutable snapshot construction, CPU command encoding,
and GPU execution but excludes display-vsync wait. The AppKit test is a warmed
offscreen cache-display path. Their timings are useful regression signals but
are not directly interchangeable.

## Interpretation and remaining proof gaps

`kitten __benchmark__` is a common end-to-end workload, but it is still Kitty's
benchmark protocol. Render mode allows asynchronous rendering and therefore
does not measure latency to illuminated pixels.

The optimized decoder skips complete unsupported OSC 6 strings without
staging them, routes complete Kitty APC payloads without an intermediate copy,
and recognizes the benchmark's valid default 32-bit raw image format. The
image path also avoids allocating and decoding a fully transparent raw RGBA
payload, because it cannot change the displayed pixels.

WezTerm logged invalid-padding errors while consuming the Kitty image payload.
Image values for terminals that do not fully implement the Kitty graphics
protocol can represent rapid rejection or discard rather than image decode and
display, and should not be read as equivalent image-rendering work.

This run does not claim measured key-to-photon input latency, first visible
frame latency, electrical energy, GPU utilization, resize smoothness, or
interactive TUI responsiveness. Those require a high-speed camera or
photodiode, Instruments or privileged power sampling, and scripted real-window
interaction. Feature coverage and correctness also remain separate from speed.

Homebrew warns that its Alacritty 0.17.0 cask does not pass the macOS Gatekeeper
check and is scheduled to be disabled on 2026-09-01. That packaging caveat does
not change its measured results, but it matters when treating the installed
cask as a shipping-quality comparison.
