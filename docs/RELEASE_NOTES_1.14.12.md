# Termatica 1.14.12

Termatica 1.14.12 makes translucent tiled layouts, theme inheritance, live
configuration reloads, and precise scrolling deterministic.

## Rendering and split transitions

- Blurred tile masks now update atomically with the window-owned tile surface,
  with implicit Core Animation actions disabled.
- Translucent tiled layouts no longer animate individual panes over a different
  blur geometry when Command-T or Command-Shift-T changes the layout.
- AppKit and Metal skip redundant default-background cell fills above the
  shared tile surface, while explicit ANSI backgrounds remain intact.

## Configuration and input

- Theme sentinel values now resolve consistently for colors, opacity, blur,
  cursor styling, effects, palettes, and Hyprland blur.
- Invalid or partially written live config files preserve the last known-good
  configuration and recover on the next valid atomic write.
- Precise trackpad scrolling resets direction state at the start of a new
  gesture, preventing stale fractional movement from reversing the first step.

## Verification

The regression suite exercises both split shortcuts under a blurred 37%-opacity
theme and verifies identical surface and blur paths, disabled implicit mask
animation, transparent pane snapshots, and stable focus. Renderer parity,
renderer recovery, config corruption/recovery, scrolling direction, automation,
packaging, signing, universal architectures, and updater behavior remain in the
full release gate.
