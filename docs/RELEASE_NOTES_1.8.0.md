# Termatica 1.8.0

Termatica 1.8.0 adds Phase 6 field diagnostics and automated rollout coverage.
AppKit remains the default renderer; Metal remains opt-in through
`appearance.renderer`.

## Added

- `t renderer-report` / `t rr` prints a JSON renderer-health report from the
  running app. It includes display geometry, scale and refresh, selected and
  active renderer, pane state, lifecycle recoveries, generations, and Metal
  failure counts.
- The report excludes terminal contents, working directories, config paths,
  commands, environment variables, and shell process details.
- A release-blocking Phase 6 gate exercises AppKit and Metal through 96
  lifecycle recoveries, resize, Unicode and graphemes, IME marked text,
  accessibility output, cursor continuity, state preservation, scheduler
  bounds, and privacy-report serialization.
- The README now has direct DMG/ZIP installation instructions and a fresh
  six-terminal benchmark table linked to raw artifacts.

## Fresh measured result

On the Apple M4 release host, Termatica 1.8.0 measured a 234.9 MB/s geometric
mean across 15 common throughput workloads, 5.532 ms shell-ready median, 29.9
MiB physical footprint, and 1,360 KiB app allocation. Rio measured the fastest
shell-ready median at 5.216 ms. These are host- and methodology-specific
measurements; render-enabled throughput is not confirmed display completion.

The final 30-minute Metal Unicode/image soak presented 77,672 frames while
processing 1,213.3 MiB, peaked at 150.8 MiB physical footprint under its 256
MiB ceiling, retained a 5,242,884-byte renderer cache, used at most one
in-flight frame, and recorded zero generation reversals.

## Honest rollout boundary

The release host has one built-in Retina display. Physical multi-display,
clamshell, real sleep/wake, human VoiceOver, remote-host SSH, Intel runtime, and
cross-machine field-report gates are not claimed as passed. The new report
exists so those checks can be collected without exposing terminal contents.
