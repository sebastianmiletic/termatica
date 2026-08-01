# Termatica 1.4.0

Termatica 1.4.0 fixes config cross-contamination and hardens the renderer and release path.

## Configs that stay independent

- Every named config is now a complete, versioned, portable JSON document.
- `config.json` mirrors only the selected named config.
- Direct edits persist to that selected config and never modify another profile.
- Switching configs replaces the active settings instead of shallow-merging stale nested values.
- Partial and legacy files are filled from canonical defaults, repaired to match their filenames, written atomically, and protected with `0600` permissions.

## Terminal and renderer hardening

- Fixed collisions in the BMP Metal glyph cache.
- Increased the Metal atlas to reduce reset pressure under diverse Unicode workloads.
- Stopped resize-only geometry updates from repeatedly invalidating renderer caches.
- Made shared empty render masks immutable and removed unused snapshot and disabled legacy code.
- Hardened image-context and animation-timer failure handling.
- Fixed undefined behavior when a pre-layout view temporarily had negative usable grid space.
- Expanded regression coverage for config isolation, partial profiles, complex graphemes, and resize/fallback behavior.

The release remains a universal macOS 13+ build with Apple Silicon and Intel binaries, a complete AppKit fallback, and an opt-in Metal renderer.

## Measured performance

The same six-terminal, 15-workload matrix was run before and after the changes. Termatica's geometric mean moved from 114.1 to 117.0 MB/s (+2.6%) and was the highest final result, ahead of Alacritty at 88.8 MB/s. Termatica led or tied 10 of 15 rows. The full report also records five regressions and the benchmark's latency and graphics-protocol limitations rather than treating the aggregate as a universal win.
