# Termatica 1.11.0

Termatica 1.11.0 completes Metal Phase 9 field qualification. Metal remains an
option in config and AppKit remains the default.

- `t rq` reports observed current-session qualification evidence and blockers.
- `t rr` schema 4 adds architecture, Rosetta state, display topology,
  scale/refresh diversity, wake events, pane display indices, and recovery
  reasons without exposing terminal content, paths, commands, or display names.
- Unobserved physical gates remain open instead of being inferred from tests.
- Synthetic events cannot satisfy physical visual, multi-machine, Intel,
  multi-display, hot-plug, or wake qualification.
- Phase 9 testing preserves Unicode and grapheme state across repeated display,
  scale, and wake recovery and verifies the privacy boundary.

This release does not claim that one development Mac represents every Intel,
Apple Silicon, monitor, refresh-rate, scaling, sleep/wake, or hot-plug setup.

`make check`, AddressSanitizer, UndefinedBehaviorSanitizer, Clang static
analysis, a five-minute Metal soak, and the real-PTY compatibility matrix
passed. The fresh six-terminal run measured Termatica at 116.5 MB/s geometric
mean throughput, 17.377 ms shell-ready median, and 26.3 MiB physical footprint;
WezTerm won shell-ready time at 11.729 ms. Raw artifacts are retained under
`benchmarks/2026-08-13-v1.11.0-matrix`.
