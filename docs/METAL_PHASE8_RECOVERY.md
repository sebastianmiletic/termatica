# Metal Phase 8 pane-isolated recovery

Termatica 1.10.0 adds an explicit, state-preserving recovery path for a Metal
pane that has fallen back to AppKit. AppKit remains the default renderer and
Metal remains opt-in.

## User operation

Run `t rt` (or `termatica renderer-retry`) in a current Termatica build. The
running app examines every pane, retries only panes that still request Metal
and are quarantined, and prints JSON with attempted, recovered,
still-quarantined, and unchanged counts. It does not edit config, restart a
PTY, clear terminal state, or touch a healthy pane.

If Metal initialization fails again, that pane remains on AppKit and remains
quarantined. A later explicit retry may be attempted after the external cause
has changed.

## Diagnostics

`t rr` schema 3 adds aggregate `health` counters and per-pane retry counters.
The report excludes terminal content, commands, working directories,
environment variables, and config paths.

## Deterministic gate

`--phase8-recovery-self-test` creates three panes, forces the middle Metal pane
to fail, confirms the other two panes are unchanged, forces an explicit retry
to fail, then retries again with the fault removed. It verifies preserved
Unicode content and schema-3 aggregate accounting. The gate accepts a continued
AppKit fallback on hosts where Metal presentation is unavailable; it never
labels an unavailable renderer as recovered.

This phase does not make Metal the default. Physical display behavior across
multiple Mac and display combinations remains a separate field gate.

## Release-candidate evidence

- `make check`: pass, including Phase 8 and the local real-PTY compatibility gate.
- AddressSanitizer and UndefinedBehaviorSanitizer: pass for terminal, renderer
  reliability, Phase 6, Phase 7, Phase 8, and decoder tests.
- Clang static analyzer: zero diagnostics across all three source files.
- Five-minute native Metal soak: 13,555 frames, 211.7 MiB processed, 154.8 MiB
  peak footprint against a 256 MiB limit, 5,242,884 cache bytes, two maximum
  in-flight frames, and zero generation reversals.
- Universal package: ad-hoc signature valid, `x86_64 arm64`, version 1.10.0,
  build 60; ZIP checksums and DMG integrity verified locally.
