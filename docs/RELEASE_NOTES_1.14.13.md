# Termatica 1.14.13

Termatica 1.14.13 hardens interactive terminal redraws, tiled transitions, live
configuration, and macOS display integration.

## Rendering and tiled layouts

- Cursor blinking now updates only its dedicated overlay. It no longer redraws
  the terminal surface or makes Codex CLI and other rapidly updating TUIs pulse,
  blink, or appear doubled while typing.
- AppKit partial redraws explicitly replace old pixels, including transparent
  pixels, so shorter updates cannot leave glyph tails from previous frames.
- Entering or leaving a tiled layout discards the old layer backing before a
  complete repaint, preventing the first pane's black strip and stale tint after
  Command-T or Command-Shift-T.

## Configuration and privacy

- Atomic config writes now request and acknowledge immediate application by the
  running app; the file watcher reacts in tens of milliseconds and keeps the
  last valid configuration during incomplete writes.
- Metal presentation no longer enumerates all active displays through the
  deprecated Core Video display-link API. Ordered queue coalescing preserves
  responsive rendering without Termatica using a screen-capture or
  display-enumeration path.

## Verification

The release gate covers repeated long-to-short and blank partial redraws on
transparent and translucent surfaces, cursor blink without frame regeneration,
inactive-pane cursor cleanup, untiled-to-tiled backing transitions, 1,000-frame
Metal coalescing, renderer parity, fast config reload, package signing,
universal architectures, and updater behavior.
