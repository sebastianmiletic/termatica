# Termatica 1.12.0

Termatica 1.12.0 completes Metal rollout Phase 10's field-campaign tooling.

- `t rc export [file]` exports a minimal privacy-safe field report.
- `t rc aggregate <file ...>` validates, deduplicates, and combines reports.
- Canonical SHA-256 detects post-export changes, while output explicitly states
  that machine and operator authenticity are not asserted.
- An ephemeral per-process identifier rejects repeated exports from one app
  session without creating a persistent machine identifier.
- Modified, malformed, unsupported, privacy-violating, and synthetic-source
  reports are rejected.
- Complete automatically observable coverage still requires physical visual
  review and never changes AppKit from the default renderer.

The deterministic gate proves the data rules with fixtures. It does not claim
that Intel hardware, multiple monitors, hot-plug, sleep/wake, or physical pixel
inspection occurred on the release machine.

`make check`, AddressSanitizer, UndefinedBehaviorSanitizer, Clang static
analysis, real-PTY coverage, and a five-minute Metal soak passed. The fresh
six-terminal matrix measured Termatica at 237.5 MB/s geometric-mean throughput,
5.170 ms shell-ready median, and 26.0 MiB physical footprint. Rio won
shell-ready time at 4.687 ms; Ghostty also measured lower at 5.029 ms. Raw
artifacts are retained under `benchmarks/2026-08-13-v1.12.0-matrix`.
