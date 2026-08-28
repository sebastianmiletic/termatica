# Termatica 1.14.8

Termatica 1.14.8 adds adaptive multi-monitor window support.

## Useful on every display

- New windows use a useful proportion of the current display instead of always
  opening at a fixed 580 by 350 points.
- Moving a window between a laptop and a large external monitor preserves its
  relative screen coverage, so it grows on the large display and shrinks safely
  when returned to a smaller display.
- Window frames remain inside the destination display's visible area and honor
  its menu bar, Dock, backing scale, configured screen inset, and minimum size.
- Displays arranged left or below the primary display are supported through
  negative global screen coordinates.
- Hyprland mode immediately refits to the active display after moves,
  resolution changes, display connection, or display removal.

## Verification

Deterministic geometry regressions cover laptop and large-external visible
frames, negative origins, proportional upscaling, round-trip downscaling,
visible-area containment, pixel alignment, and exact Hyprland fitting. The full
release gate retains mixed pane-local splits, dense Hyprland reflow, mouse and
keyboard input, Codex and Claude redraw coverage, AppKit and Metal parity,
real-PTY automation, updater replacement, universal architectures, and stable
release signatures.
