# Termatica 1.9.0

Termatica 1.9.0 completes Metal Phase 7 production hardening. AppKit remains
the default renderer; Metal remains opt-in through `appearance.renderer`.

## Metal recovery hardening

- A Metal initialization or runtime failure now enters a bounded session-local
  quarantine and continues through AppKit without repeated Metal retries or
  AppKit backend replacement during lifecycle recovery.
- Retrying Metal requires an explicit AppKit-to-Metal reselection. Terminal
  contents, scrollback, PTY state, and the selected config remain intact.
- AppKit fallback now clears stale Metal layer content and restores the correct
  view-layer policy before presenting the preserved snapshot.
- `t rr` renderer-report schema 2 adds requested versus actual renderer,
  quarantine state, explicit-retry policy, failure category and age, and
  quarantined reconfiguration-bypass counts without exposing terminal content
  or paths.

## Verification

- The release-blocking Phase 7 gate forces initialization and runtime failures,
  performs 96 quarantined lifecycle recoveries, verifies no retry loop, and
  preserves Unicode terminal state.
- `make check`, AddressSanitizer, UndefinedBehaviorSanitizer, Clang static
  analysis, and the real-PTY compatibility matrix passed.
- The fresh six-terminal matrix measured Termatica at 232.2 MB/s geometric-mean
  throughput, 5.696 ms shell-ready median, 26.0 MiB physical footprint, and
  1,360 KiB app allocation. Rio won shell-ready startup at 4.874 ms.
- The final 30-minute Metal soak presented 83,102 frames while processing
  1,298.2 MiB, peaked at 150.7 MiB physical footprint under its 256 MiB limit,
  retained 5,242,884 cache bytes, used at most one in-flight frame, and
  recorded zero generation reversals.

## Honest rollout boundary

Physical multi-display, clamshell, real sleep/wake, human VoiceOver, Intel
runtime, and broad multi-machine field evidence remain open. This release does
not use performance alone to make Metal the default.
