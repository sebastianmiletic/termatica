# Terminal benchmarks

This is the reproducible six-terminal macOS performance snapshot for Termatica
1.4.1, with a focused 1.4.2 long-escape and latency follow-up. It includes a back-to-back acceptance run for the four optimized paths
and a separate complete 15-workload matrix. Keeping both visible prevents a
focused improvement from being confused with whole-system benchmark variance.

## Test system and method

- Date: 2026-08-01
- Hardware: Apple M4 Mac, 16 GB memory
- OS: macOS 26.5.2 (25F84), arm64
- Font: Monaco 11 in every terminal, with system fallback for missing glyphs
- Termatica: 1.4.0 pre-change baseline and 1.4.1 release candidate
- Kitty: 0.48.1
- Ghostty: 1.3.1
- Alacritty: 0.17.0
- WezTerm: 20240203-110809-5046fc22
- Rio: 0.5.2
- Repetitions: 10 per `kitten __benchmark__` workload
- Raw focused output: `/tmp/termatica-benchmark-v141-baseline-2026-08-01`
  and `/tmp/termatica-benchmark-v141-final3-2026-08-01`
- Raw complete matrix: `/tmp/termatica-benchmark-v141-full-final-2026-08-01`

The focused command used the same cases before and after:

```sh
BENCHMARK_REPETITIONS=10 \
BENCHMARK_TIMEOUT_SECONDS=180 \
BENCHMARK_CASES='unicode images long_escape_codes' \
BENCHMARK_OUTPUT=/tmp/termatica-benchmark-... \
scripts/benchmark-terminals.sh
```

The complete matrix omitted `BENCHMARK_CASES`, enabling all six parser/render
cases and all three scrollback cases. The harness launches a fresh process for
each mode, applies Monaco 11 and the most isolated supported config, and records
startup, physical footprint, app allocation, and internal diagnostics. Higher
throughput is better. Lower startup, memory, and size are better.

## Focused performance acceptance

All four requested Termatica paths improved in the back-to-back focused run.

| Workload | 1.4.0 pre-change | 1.4.1 candidate | Change |
|---|---:|---:|---:|
| Parser Unicode | 103.1 | **115.7** | **+12.2%** |
| Scrollback Unicode | 93.7 | **109.8** | **+17.2%** |
| Render long escapes | 259.7 | **277.0** | **+6.7%** |
| Render images | 251.8 | **264.1** | **+4.9%** |

The same final focused run compared all six terminals:

| Workload (MB/s) | Termatica | Kitty | Ghostty | Alacritty | WezTerm | Rio |
|---|---:|---:|---:|---:|---:|---:|
| Parser Unicode | **115.7** | 98.8 | 75.8 | 95.3 | 29.0 | 50.5 |
| Scrollback Unicode | **109.8** | 82.7 | 79.7 | 95.5 | 28.7 | 51.9 |
| Render long escapes | **277.0** | 267.5 | 58.7 | 137.5 | 113.9 | 88.5 |
| Render images | **264.1** | 223.5 | 44.8 | 242.6 | 112.1 | 138.2 |

The implementation changes behind these measurements are throughput-oriented
release compilation, an interactive-QoS serialized parser, coalesced ignored
OSC 6 scanning, and a wider but still bounded PTY backlog window. Mutable
terminal state remains owned by one serialized parser queue.

### Chunk-boundary follow-up

A later focused 10-repetition run tested long escapes alone. The baseline and
optimized build used the same machine, command, and isolated configuration.

| Workload | Baseline | Optimized | Change |
|---|---:|---:|---:|
| Parser long escapes | 221.6 | **228.9** | **+3.3%** |
| Render long escapes | 223.5 | **244.3** | **+9.3%** |

The follow-up adds a stateful discard mode for unsupported OSC 6 payloads split
across PTY reads and raises the transient read batch from 256 KiB to 1 MiB.
That buffer exists only while output is being read and therefore does not add a
1 MiB idle allocation. The [result summary](benchmark-results/long-escapes-2026-08-01.json)
also records every competitor from the optimized run.

## Complete end-to-end matrix

All values are MB/s. This is a separate run containing all 15 workloads.

| Mode / workload | Termatica | Kitty | Ghostty | Alacritty | WezTerm | Rio |
|---|---:|---:|---:|---:|---:|---:|
| Parser ASCII | **177.5** | 77.4 | 51.7 | 69.9 | 19.3 | 69.5 |
| Parser Unicode | **119.9** | 102.1 | 86.0 | 103.0 | 29.8 | 53.2 |
| Parser unique graphemes | **94.0** | 28.4 | 37.9 | 45.6 | 40.4 | 40.6 |
| Parser CSI-heavy | **88.9** | 43.5 | 30.7 | 52.0 | 13.2 | 36.5 |
| Parser long escapes | 255.5 | **270.2** | 62.8 | 140.2 | 167.6 | 78.6 |
| Parser images | **300.3** | 248.0 | 44.3 | 230.7 | 130.6 | 101.7 |
| Render ASCII | **172.0** | 77.5 | 58.0 | 86.1 | 18.9 | 129.8 |
| Render Unicode | **117.6** | 71.7 | 84.2 | 115.7 | 25.3 | 9.7 |
| Render unique graphemes | **87.5** | 14.9 | 38.7 | 48.7 | 30.3 | 55.6 |
| Render CSI-heavy | **87.8** | 43.8 | 31.7 | 52.0 | 12.9 | 41.2 |
| Render long escapes | 229.5 | **268.8** | 53.7 | 137.6 | 165.4 | 97.3 |
| Render images | 226.8 | **251.1** | 39.9 | 242.8 | 132.7 | 137.6 |
| Scrollback ASCII | **121.0** | 61.4 | 56.5 | 71.5 | 18.7 | 66.7 |
| Scrollback Unicode | **106.2** | 84.5 | 79.8 | 97.2 | 29.1 | 52.0 |
| Scrollback CSI-heavy | **81.1** | 43.4 | 31.1 | 51.0 | 13.1 | 36.3 |

Termatica leads 12 of 15 complete-matrix rows.

| Terminal | 15-workload geometric mean |
|---|---:|
| Termatica | **137.2 MB/s** |
| Alacritty | 88.7 MB/s |
| Kitty | 80.1 MB/s |
| Rio | 56.9 MB/s |
| Ghostty | 49.5 MB/s |
| WezTerm | 35.7 MB/s |

Long-escape and image throughput moves substantially between complete and
focused matrices for several terminals. These rows are dominated by PTY flow,
benchmark ordering, asynchronous presentation, and system scheduling. The
focused back-to-back run is the acceptance evidence for the requested changes;
the complete matrix remains visible rather than selecting its fastest rows.

## Responsiveness and process energy

The release benchmark configuration was measured five times. The refreshed
latency pass contains 1,000 input/paint samples per run; the energy pass uses
240 samples followed by 10 seconds of sustained Unicode and ANSI output.
Values below are the median result across the five runs.

| Measurement | Result |
|---|---:|
| Software key-to-paint lower bound, p50 | **1.544 ms** |
| Software key-to-paint lower bound, p95 | **1.746 ms** |
| Software key-to-paint lower bound, p99 | **2.146 ms** |
| Event mapping, p50 | **0.028 ms** |
| Immediate echo parsing, p50 | **0.00025 ms** |
| Full AppKit paint, p50 | **1.520 ms** |
| Process-attributed energy, 10 seconds | **14.455 J** |
| Process-attributed average power | **1.445 W** |
| Process-attributed energy per GiB | **11.064 J/GiB** |
| Sustained throughput during energy sample | **133.479 MiB/s** |

The five 1,000-sample p50 results were 1.399, 1.569, 1.544, 1.535, and
1.544 ms. Stage timing uses `CLOCK_UPTIME_RAW` nanoseconds. The
energy samples were 14.486, 14.421, 14.455, 14.234, and 14.606 J. The
[checked-in sample summary](benchmark-results/responsiveness-energy-2026-08-01.json)
preserves every published value; raw per-run JSON is stored locally at
`/tmp/termatica-responsiveness-energy-2026-08-01`.

The input measurement starts at a synthetic `NSEvent`, passes through
Termatica's key mapping, loops the resulting bytes back as an immediate PTY
echo, parses them, and performs a warmed full-surface AppKit paint. It is a
software pipeline lower bound, not literal key-to-photon: physical keyboard
latency, a real shell's scheduling, PTY scheduling, WindowServer, vsync, panel
scanout, and pixel response are excluded. Literal key-to-photon requires an
external actuator plus a photodiode or high-speed camera.

Energy comes from macOS `rusage_info_v6.ri_energy_nj` for the Termatica
benchmark process. It includes process-attributed work but excludes the display
and unassigned whole-system energy, so it must not be compared with wall-power
measurements. Reproduce both measurements with `make benchmark-experience`.

## Startup, memory, and size

Startup measures process launch until the child shell writes and fsyncs a probe
file. It is not first-pixel or key-to-photon latency. Physical footprint is one
post-settle snapshot and is sensitive to macOS cache and compression state.

| Terminal | Shell-ready median / max | Physical footprint | App allocation |
|---|---:|---:|---:|
| Termatica | **7.786 / 9.075 ms** | **30.2 MiB** | **1144 KiB** |
| Kitty | 10.309 / 12.489 ms | 120.7 MiB | 160,080 KiB |
| Ghostty | 8.416 / 8.892 ms | 86.5 MiB | 63,484 KiB |
| Alacritty | 11.583 / 12.385 ms | 65.4 MiB | 14,328 KiB |
| WezTerm | 9.356 / 9.911 ms | 46.7 MiB | 259,840 KiB |
| Rio | 9.014 / 9.691 ms | 42.6 MiB | 41,992 KiB |

The release app is larger than 1.4.0 because its universal binaries now favor
runtime throughput over minimum code size. It remains roughly 12.5 times
smaller than the next app allocation in this comparison.

## Termatica internal measurements

These native-harness diagnostics are regression signals, not cross-terminal
wins because competitors do not expose equivalent entry points.

| Measurement | Final result |
|---|---:|
| C decoder ASCII / Unicode / CSI | 377.1 / 397.0 / 377.0 MiB/s |
| Screen core ASCII / Unicode / CSI | 151.1 / 98.4 / 75.6 MiB/s |
| AppKit offscreen paint p50 / p95 / p99 | 1.491 / 1.561 / 1.664 ms |
| Parse-to-paint p50 / p95 / p99 | 1.469 / 1.527 / 1.650 ms |
| Frames over 60 / 120 / 240 Hz budgets | 0 / 0 / 0 of 240 |
| Sustained output | 139.1 MiB/s |
| Minimum 250 ms sustained window | 136.8 MiB/s |

The paint test is a warmed, offscreen AppKit cache-display path. It includes no
display-vsync wait. The Metal test in `make check` verifies real GPU submission,
pixel variation, cache invalidation, and automatic AppKit fallback, but does not
claim camera-measured latency.

## Interpretation and proof boundaries

`kitten __benchmark__` is a common end-to-end protocol, but it remains Kitty's
benchmark. Render mode permits asynchronous presentation and therefore does not
measure the time until light reaches the display. Terminals can reject, store,
or present graphics controls at different stages, so image throughput does not
by itself prove equivalent image presentation.

The benchmark does not measure key-to-photon latency, first visible frame,
electrical energy, GPU utilization, resize smoothness, or subjective TUI feel.
Those require high-speed capture, Instruments or power sampling, and scripted
real-window interaction. Correctness, Unicode shaping, protocol coverage,
security, config isolation, and arbitrary tile movement are verified separately
by regression tests, Clang analysis, sanitizers, and renderer self-tests.
