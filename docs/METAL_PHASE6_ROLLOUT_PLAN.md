# Metal Phase 6 rollout plan

Status: automated rollout support and release-host gates are implemented and
locally verified for the v1.8.0 candidate. Physical/manual and multi-machine
field gates remain explicitly open.

## Objective

Collect field evidence from the opt-in Metal renderer, close the remaining
physical/manual coverage gaps, and make an evidence-based decision about
whether Metal should remain opt-in or become the default while always retaining
AppKit as a selectable fallback.

## Gates

1. Verify real multi-display movement across different scale and refresh-rate
   displays, clamshell transitions, display sleep/wake, and a physical macOS
   system sleep/wake cycle.
2. Complete VoiceOver navigation, IME, selection, clipboard, mouse, trackpad,
   and accessibility review with AppKit and Metal selected.
3. Run remote SSH sessions and long-lived Codex/OpenCode/tmux/editor workflows,
   including network interruption and reconnection behavior where the program
   supports it.
4. Gather crash, fallback, memory, and rendering reports from the Phase 5 public
   build across Apple Silicon and Intel Macs.
5. Repeat the complete release gate, 30-minute soak, and same-machine AppKit vs
   Metal benchmark on the final Phase 6 commit.

## Implemented rollout support

- `t renderer-report` (short form `t rr`) requests diagnostics from the running
  app and prints version/build, active config name, requested and actual
  renderer, font, display geometry/scale/refresh, pane counts, lifecycle
  recovery counts, renderer generations, and Metal failure counts.
- The report deliberately excludes terminal text, working directories, config
  paths, command lines, environment variables, and shell process details. Its
  schema and privacy flags are covered by a release-blocking self-test.
- Presentation diagnostics now retain a recovery count and last recovery reason
  across view/window, backing-scale, display, occlusion, screen-wake, and
  system-wake paths. Metal initialization and runtime failures are counted.
- The Phase 6 field gate exercises AppKit and Metal, 96 lifecycle recoveries,
  repeated resize, Unicode and complex graphemes, IME marked text,
  accessibility output, cursor continuity, preserved terminal contents,
  bounded Metal scheduling, and privacy-report serialization.

## Release-host evidence

| Gate | Result |
|---|---|
| Phase 6 AppKit/Metal field self-test | Pass: 96 recoveries, state preserved |
| Unicode, graphemes, and IME marked text | Pass |
| Accessibility value generation | Pass; human VoiceOver navigation still manual |
| Renderer report privacy schema | Pass: no terminal content or paths |
| Connected displays on release host | One built-in Retina display; no multi-display claim |
| Apple Silicon | Exercised on Apple M4 |
| Intel runtime | Not exercised; universal x86_64 build and CI compilation only |
| Physical sleep/wake and clamshell | Not run automatically |
| Remote SSH session | Not run; local OpenSSH client path only |
| Field crash/fallback reports | Awaiting v1.8.0 user rollout |

The final 30-minute native Metal Unicode/image soak completed 77,672 frames
while processing 1,213.3 MiB. Physical footprint started at 64.0 MiB, peaked at
150.8 MiB under the 256 MiB limit, and ended at 127.4 MiB. Renderer cache use
ended at 5,242,884 bytes, maximum in-flight work was one frame, and generation
reversals were zero.

The new diagnostics make those remaining gates reproducible, but do not turn
unavailable hardware or human interaction into an automated pass. Users can
capture a report with `t rr > termatica-renderer-report.json` after a display,
wake, or fallback issue without exposing terminal contents.

## Fresh benchmark evidence

The 2026-08-11 six-terminal run used all installed comparison apps, three
throughput repetitions, and five shell-ready launches. Termatica measured
234.9 MB/s across the 15-workload geometric mean, 5.532 ms shell-ready median,
29.9 MiB physical footprint, and 1,360 KiB app allocation. Rio won shell-ready
median at 5.216 ms. The full factual table and raw artifacts are linked from the
README and `docs/BENCHMARKS.md`.

Equal-content renderer work measured AppKit at 4.089 ms p50 / 4.271 ms p95 and
Metal at 2.522 ms p50 / 3.223 ms p95. These are renderer-work measurements, not
physical key-to-photon latency or proof of display correctness.

## Decision rule

Changing the default is a separate product decision, not an automatic result of
passing tests. It requires the physical/manual gates, acceptable field reports,
and explicit approval. If those conditions are not met, Metal remains opt-in.

That condition is not yet met for v1.8.0, so AppKit remains the default and
Metal remains an explicit config choice.
