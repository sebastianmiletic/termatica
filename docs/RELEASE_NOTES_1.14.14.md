# Termatica 1.14.14

Termatica 1.14.14 fixes the remaining theme-tint changes and overlapping text
that could appear while opening the app, creating tabs or windows, and splitting
panes.

## Stable color and tint

- One window-owned surface now paints the configured background from the first
  launch frame through ordinary tabs and tiled layouts.
- AppKit and Metal terminal panes remain transparent except where applications
  explicitly draw ANSI cell backgrounds. The theme therefore has one color and
  opacity owner regardless of renderer, focus, tab count, or split topology.
- New windows, Command-T tabs, Command-Shift-T splits, and ordinary/tiled
  transitions retain the same configured RGBA values without darkening.

## Overlapping text protection

- Metal hides its previous drawable whenever terminal geometry changes and
  reveals the surface only after a frame matching the new dimensions completes.
- Snapshots produced for an earlier size are discarded instead of being scaled
  or composited over current text.
- GPU presentation is serialized to one frame in flight while retaining bounded
  latest-frame coalescing, eliminating out-of-order old/new glyph layers.

## Verification

The release gate covers initial launch, repeated ordinary tabs, new windows,
nested translucent splits, AppKit/Metal parity, transparent partial redraws,
wide-cell and emoji cleanup, cursor-overlay blinking, stale resize rejection,
and a 1,000-frame scheduler burst with exactly one frame in flight.
