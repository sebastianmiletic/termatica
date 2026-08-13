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
# fresh six-terminal matrix
t b a
```

`t b` launches one isolated Termatica process and measures it now. The other
columns come from each competitor's latest successful, timestamped `t b a`
run. `t b a` launches isolated fresh processes for Termatica, Kitty, Ghostty,
Alacritty, WezTerm, and Rio, runs the same Kitty benchmark protocol in each,
captures the output, and refreshes the saved results for every successful
terminal. It closes only the processes it launched. Termatica receives a temporary copy of the active config;
the user's config file, PTYs, tabs, scrollback, processes, and windows are not
modified or closed. The common active font and size are applied to competitors
where their command-line configuration supports it.
All isolated benchmark processes start in a private temporary working
directory. Running `t b` from Desktop, Documents, Downloads, or another
protected folder therefore does not make the benchmark request access to that
folder.

No comparison values are compiled into either command. The status table labels
every column `FRESH`, `SAVED`, or `NONE` and prints its UTC measurement time.
A missing executable, failed workload, or timeout in `t b a` is printed as
`N/A` with a nonzero command status; it does not overwrite that terminal's last
successful cache. Raw parser and render output, a manifest, and the exact
matrix TSV are written to the per-run directory printed at the end. Results
open in a compact native AppKit window with separate Comparison, Current App,
and Run Status tabs. Comparison shows all 12 parser/render workloads and the
aggregate result in adaptive-width monospaced tables, with every tied winner
bold. Rows do not wrap; horizontal and vertical scrolling preserve alignment
when a value is longer. The window does not use a deferred or recycled table
data source.

The interactive default is one fresh repetition per workload so the six-app
matrix completes promptly. Set `TERMATICA_BENCHMARK_REPETITIONS=3` for a longer
confirmation run; failures and timeouts still remain `N/A`.

The running app then benchmarks an isolated model and offscreen paint surface
using the active visual configuration. It does not replace or close a PTY, tab,
process, scrollback buffer, or window. The report includes:

- Termatica version and build
- active config, renderer, font, and display refresh rate
- process physical footprint before and after the sample
- open window and terminal counts
- median ASCII, Unicode, dense-cell, CSI, and scrolling-region parser/model
  throughput over three 1 MiB runs
- warmed offscreen AppKit text and image paint FPS, p50, and p95 over 20 frames
- a fresh aligned 12-workload comparison and geometric mean for Termatica,
  Kitty, Ghostty, Alacritty, WezTerm, and Rio
- per-terminal completion status and versions

The paint number is not Metal FPS, display FPS, or physical key-to-photon
latency. It excludes WindowServer, vsync, panel scanout, and pixel response.
The cross-terminal matrix uses Kitty's benchmark driver. Its render-enabled
mode allows asynchronous presentation, so those values measure accepted
throughput rather than verified displayed frames. The `CURRENT RUN` section is
a separate, freshly executed Termatica-only internal model and warmed offscreen
AppKit paint measurement. The two methods are labeled separately and must not
be compared directly.

## Termatica 1.10.0 fresh six-terminal result

On 2026-08-13, the Phase 8 release candidate and all five installed comparison
terminals were freshly measured on the same Apple M4 Mac with 16 GB memory,
Monaco 11 where configurable, three throughput repetitions, and five
shell-ready launches. The Mac was on battery power and the one-minute load
average was 7.17 when the run was inspected, so these absolute values are not
comparable to runs captured under different power or load conditions.

| Terminal | 15-workload geo mean | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|---:|
| Termatica 1.10.0 | **75.5 MB/s** | 34.403 ms | **30.3 MiB** | **1,376 KiB** |
| Kitty 0.48.1 | 41.6 MB/s | 61.062 ms | 118.1 MiB | 160,080 KiB |
| Ghostty 1.3.1 | 13.4 MB/s | 30.436 ms | 97.4 MiB | 63,484 KiB |
| Alacritty 0.17.0 | 35.4 MB/s | 50.551 ms | 147.7 MiB | 14,328 KiB |
| WezTerm 20240203 | 16.4 MB/s | **27.897 ms** | 47.8 MiB | 259,840 KiB |
| Rio 0.5.2 | 32.0 MB/s | 31.319 ms | 50.0 MiB | 41,992 KiB |

The geometric mean covers six parser, six render-enabled, and three scrollback
workloads. Render-enabled throughput measures accepted input, not confirmed
display completion. Startup ends when the child writes and syncs a marker, not
when a frame becomes visible. Physical footprint is one post-settle sample.
Every raw result is committed under
`benchmarks/2026-08-13-v1.10.0-matrix`.

## Termatica 1.9.0 fresh six-terminal result

On 2026-08-11, the Phase 7 release candidate and all five installed comparison
terminals were measured in fresh isolated processes on an Apple M4 Mac with
16 GB memory. The run used Monaco 11 where a terminal exposed an isolated font
setting, three throughput repetitions, and five shell-ready launches. Higher
throughput is better; lower startup, memory, and allocation are better.

| Terminal | 15-workload geo mean | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|---:|
| Termatica 1.9.0 | **232.2 MB/s** | 5.696 ms | **26.0 MiB** | **1,360 KiB** |
| Kitty 0.48.1 | 108.7 MB/s | 6.225 ms | 118.1 MiB | 160,080 KiB |
| Ghostty 1.3.1 | 87.3 MB/s | 6.536 ms | 79.4 MiB | 63,484 KiB |
| Alacritty 0.17.0 | 161.7 MB/s | 5.800 ms | 66.5 MiB | 14,328 KiB |
| WezTerm 20240203 | 63.3 MB/s | 5.910 ms | 42.4 MiB | 259,840 KiB |
| Rio 0.5.2 | 93.9 MB/s | **4.874 ms** | 38.0 MiB | 41,992 KiB |

The geometric mean covers the six parser, six render-enabled, and three
scrollback workloads emitted by the common harness. The complete raw terminal
output, startup samples, memory samples, versions, and Termatica internal JSON
results are committed under `benchmarks/2026-08-11-v1.9.0-matrix`.

In the equal-content internal renderer comparison, AppKit work measured 4.105
ms p50 and 4.519 ms p95; Metal measured 2.494 ms p50 and 3.605 ms p95. Both had
zero frames above the 60 Hz and 120 Hz work budgets. This is renderer work, not
physical key-to-photon latency. Metal remains opt-in because performance alone
does not complete the physical display, accessibility, Intel, and field gates.

The common benchmark's render-enabled mode permits asynchronous presentation,
so it measures accepted throughput rather than confirmed display completion.
The image workload can be processed faster by rejecting unsupported graphics
controls and therefore does not establish equivalent image rendering. Startup
ends when the child shell writes and syncs a ready marker; it is not first
visible frame. Physical footprint is one post-settle sample and can vary.

## Termatica 1.5.1 focused Unicode and escape result

On 2026-08-11, released v1.5.0 and the v1.5.1 release candidate were each
measured in three independent runs with the same active user config, SF Mono
11, and five repetitions per workload. The table reports the median of those
three run-level results. Higher accepted throughput is better. These are Kitty
benchmark protocol results; render-enabled rows do not prove displayed-frame
completion. Raw artifacts and the extracted series are in
`benchmarks/2026-08-11-unicode-escapes/median-series`.

| Workload | v1.5.0 median | v1.5.1 median | Change |
|---|---:|---:|---:|
| Parser Unicode | 112.8 MiB/s | **121.4 MiB/s** | +7.6% |
| Parser unique graphemes | 87.2 MiB/s | **93.3 MiB/s** | +7.0% |
| Parser long escapes | 215.8 MiB/s | **219.1 MiB/s** | +1.5% |
| Render-enabled Unicode | 109.3 MiB/s | **145.9 MiB/s** | +33.5% |
| Render-enabled unique graphemes | 84.1 MiB/s | **92.1 MiB/s** | +9.5% |
| Render-enabled long escapes | 193.4 MiB/s | **210.3 MiB/s** | +8.7% |

The implementation decodes contiguous valid UTF-8 sequences directly into a
larger batched codepoint buffer, avoids full CSI parameter-array clearing, and
constructs common two-scalar graphemes without intermediate strings. Invalid
and fragmented UTF-8, fragmented OSC 6, and chunk boundaries remain covered by
the decoder and terminal self-tests. A rejected 32-byte OSC/DCS scan experiment
was removed after it regressed long-escape throughput. The three-run series is
retained so the result is not selected from a single favorable sample.

If an already-running app predates the benchmark request handler, `t b` now
stops after 15 seconds with an explicit one-time restart instruction. It does
not close the old process or its terminals. A current app replies directly.

One isolated live-app verification on 2026-08-10 returned:

| Measurement | Result |
|---|---:|
| ASCII parser/model | 174.9 MiB/s |
| Unicode parser/model | 90.7 MiB/s |
| Dense cells/model | 126.7 MiB/s |
| CSI parser/model | 99.9 MiB/s |
| Scrolling region/model | 285.0 MiB/s |
| Offscreen text paint | 312.8 FPS; 3.197 ms p50; 3.511 ms p95 |
| Offscreen image paint | 303.3 FPS; 3.297 ms p50; 3.353 ms p95 |
| Process footprint | 81.1 MiB before; 88.0 MiB after |

That sample used Termatica 1.5.0 build 51, the `custom` config, AppKit,
Monaco 11, and a 60 Hz display. In-app results are configuration- and
machine-specific and should not be compared with the cross-terminal protocol
results below.

## Upstream vtebench PTY throughput

The [Alacritty vtebench](https://github.com/alacritty/vtebench) suite measures
how long a terminal takes to accept workload bytes through its PTY. It does not
measure frame rate, presentation latency, visual correctness, or the time at
which every byte becomes visible. Lower time is better.

The following run used upstream vtebench commit
`ead80032e57dee2e75f0b51f2ea67528647d9944`, its default 10-second limit per
workload, 1 MiB minimum samples, and the same machine as the supplied reference
results. Raw output is `/tmp/termatica-vte-final-20260810a.dat`.

| Workload | Supplied reference avg | Updated Termatica avg | Updated p90 | Change |
|---|---:|---:|---:|---:|
| dense_cells | 15.35 ms | **9.21 ms** | 10 ms | 40.0% lower |
| medium_cells | 16.37 ms | **7.92 ms** | 8 ms | 51.6% lower |
| scrolling | 113.39 ms | **60.66 ms** | 143 ms | 46.5% lower |
| scrolling_bottom_region | 40.30 ms | **24.01 ms** | 64 ms | 40.4% lower |
| scrolling_bottom_small_region | 43.93 ms | **23.87 ms** | 65 ms | 45.7% lower |
| scrolling_fullscreen | 232.68 ms | **104.99 ms** | 181 ms | 54.9% lower |
| scrolling_top_region | 393.33 ms | **24.24 ms** | 64 ms | 93.8% lower |
| scrolling_top_small_region | 42.37 ms | **23.95 ms** | 64 ms | 43.5% lower |
| sync_medium_cells | 12.00 ms | **8.06 ms** | 8 ms | 32.8% lower |
| unicode | 10.11 ms | **6.85 ms** | 7 ms | 32.2% lower |

The optimized implementation rotates physical row indexes for full-screen and
DECSTBM-region scrolling and clears only the reused row. A regression test
checks forward region scrolling and reverse-index row order. The p90 values
show that scrolling still has scheduling-related tail latency; the table does
not claim that variance has been eliminated.

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
- Raw output: `/tmp/termatica-all-categories-clean-20260810`

```sh
BENCHMARK_REPETITIONS=3 \
BENCHMARK_TIMEOUT_SECONDS=900 \
BENCHMARK_OUTPUT=/tmp/termatica-all-categories-clean-20260810 \
make benchmark
```

The harness launches a fresh process for each mode. Higher MB/s is better;
lower startup and memory are better. Values are reported by Kitty's
`kitten __benchmark__` protocol.

## Complete throughput matrix

| Mode / workload (MB/s) | Termatica | Kitty | Ghostty | Alacritty | WezTerm | Rio |
|---|---:|---:|---:|---:|---:|---:|
| Parser ASCII | **309.1** | 113.0 | 89.0 | 127.1 | 34.6 | 126.4 |
| Parser Unicode | **212.1** | 146.4 | 123.6 | 182.5 | 53.8 | 97.1 |
| Parser unique graphemes | **160.0** | 49.0 | 58.5 | 86.4 | 70.1 | 75.1 |
| Parser CSI-heavy | **170.1** | 55.5 | 52.1 | 94.3 | 23.5 | 70.2 |
| Parser long escapes | 287.9 | **327.9** | 93.5 | 286.0 | 299.3 | 154.2 |
| Parser image stream | 296.4 | 287.5 | 74.4 | **418.9** | 248.3 | 182.9 |
| Render ASCII | **314.9** | 115.7 | 108.0 | 153.5 | 34.3 | 231.7 |
| Render Unicode | 205.7 | 62.0 | 162.8 | **208.4** | 38.4 | 5.2 |
| Render unique graphemes | **153.3** | 25.3 | 70.7 | 89.0 | 59.9 | 93.5 |
| Render CSI-heavy | **165.9** | 55.5 | 55.7 | 103.0 | 22.3 | 82.8 |
| Render long escapes | **354.3** | 326.1 | 101.2 | 269.5 | 278.6 | 162.0 |
| Render image stream | 349.3 | 284.4 | 77.6 | **443.9** | 240.8 | 243.8 |
| Scrollback ASCII | **231.6** | 94.4 | 88.9 | 122.9 | 34.0 | 119.1 |
| Scrollback Unicode | **186.6** | 123.9 | 129.1 | 164.5 | 54.2 | 59.9 |
| Scrollback CSI-heavy | **165.2** | 55.4 | 52.5 | 93.4 | 23.8 | 70.1 |
| 15-workload geometric mean | **227.2** | 106.5 | 84.2 | 162.8 | 63.8 | 93.0 |

## Results where another terminal was faster

| Measurement | Faster terminal | Faster result | Termatica | Difference |
|---|---|---:|---:|---:|
| Fresh shell-ready median, 5 launches | Alacritty | **4.658 ms** | 5.837 ms | Alacritty 1.179 ms lower |
| Parser long escapes | Kitty | **327.9 MB/s** | 287.9 MB/s | Kitty 13.9% higher |
| Parser image stream | Alacritty | **418.9 MB/s** | 296.4 MB/s | Alacritty 41.3% higher |
| Render Unicode | Alacritty | **208.4 MB/s** | 205.7 MB/s | Alacritty 1.3% higher |
| Render image stream | Alacritty | **443.9 MB/s** | 349.3 MB/s | Alacritty 27.1% higher |

WezTerm and Ghostty did not lead a throughput row in this particular matrix.
This is a statement about this run, not a general claim about those applications.

The Alacritty image row must not be read as evidence that Alacritty displayed
the same image. The input contains terminal graphics controls; a terminal can
increase reported throughput by rejecting or discarding an unsupported
protocol. Visual equivalence was not instrumented by this harness.

A separate seven-repetition confirmation run of Unicode, long escapes, and
images was written to `/tmp/termatica-losses-confirm-20260810`. In that narrower
run Termatica led rendered Unicode (205.5 versus Alacritty 187.1 MB/s), Kitty
led long escapes by 1.9% or less, and Alacritty retained both image-stream
throughput leads. The complete matrix above remains the primary result; the
confirmation is reported to show run-to-run variability rather than replacing
unfavourable primary measurements.

## Startup and memory

Startup is process launch until the benchmark child shell writes and fsyncs a
ready file. It is not first visible frame. Memory is one post-settle physical
footprint sample and varies with macOS caching and compression.

| Terminal | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|
| Termatica | 5.837 ms | **25.9 MiB** | **1,208 KiB** |
| Kitty | 5.533 ms | 115.6 MiB | 160,080 KiB |
| Ghostty | 5.037 ms | 78.0 MiB | 63,484 KiB |
| Alacritty | **4.658 ms** | 69.0 MiB | 14,328 KiB |
| WezTerm | 5.701 ms | 45.4 MiB | 259,840 KiB |
| Rio | 4.712 ms | 42.1 MiB | 41,992 KiB |

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
