# Termatica 1.6.0

Termatica 1.6.0 completes the production scheduling portion of Metal Phase 4.
Metal remains optional; AppKit remains the default renderer and automatic
fallback.

## Metal scheduling

- Metal presentation is driven by the active display's refresh notifications.
- One pending snapshot is retained and stale pending generations are coalesced.
  Older generations are rejected and the newest accepted terminal state is
  presented without reordering.
- GPU submission is bounded to two in-flight frames. Three reusable instance
  buffers and reusable CPU scratch storage remove per-frame buffer allocation.
- Initial presentation, resize, backing-scale changes, and resource recovery
  can redraw immediately rather than waiting for the next refresh callback.
- Snapshot wait, CPU encoding, GPU execution, GPU completion, presentation
  interval, queue depth, coalescing, and generation ordering are measured
  separately.

## Benchmark and regression coverage

- A 1,000-snapshot scheduler burst coalesces stale work, requires a one-snapshot
  pending bound, a two-frame in-flight bound, zero generation reversals, and
  successful immediate resize recovery.
- The experience benchmark now reports AppKit and Metal using matching viewport
  content, damage, warmup, and frame counts.
- Benchmark JSON uses a complete-write loop. The regression suite requires a
  valid JSON result larger than 4 KiB, preventing the former truncated artifact.
- The bundle-size cap increased by one 16 KiB Mach-O alignment unit to account
  for the Xcode 15.4 universal layout: 1,320,109 bytes locally and 1,339,901
  bytes on GitHub's runner.
- On five fresh 240-frame Apple M4 runs, Metal recorded zero frames over the 60
  Hz and 120 Hz work budgets. The synthetic 240 Hz budget had 2-14 overshoots,
  so this release does not claim guaranteed 240 Hz work completion.

## Installation documentation

The GitHub README now includes separate DMG and ZIP instructions, supported
macOS and architectures, first-launch Gatekeeper behavior, SHA-256 verification,
installed-version checking, and updater commands.

## Verification scope

`make check`, native pixel parity, renderer switching and fallback, cache
pressure, the scheduler stress gate, AddressSanitizer, UndefinedBehaviorSanitizer,
terminal and decoder behavior, and package/updater safety passed on the release
test machine. The universal package, code signature, hashes, public release
metadata, downloaded assets, and updater feed are verified separately after
publication.
