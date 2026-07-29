# Termatica 1.1.0

## Phase 10 Metal renderer

- Adds an opt-in native Metal backend selected with
  `appearance.renderer = "metal"` or `TERMATICA_RENDERER=metal`.
- Preserves the complete AppKit renderer as the default and automatic fallback.
- Renders immutable snapshots through a serial, latest-generation-wins queue.
- Adds CoreText glyph atlasing, instanced backgrounds and glyphs, Unicode and
  wide cells, cursor styles, selections, search, links, inline images, effects,
  and scroll position.
- Falls back to AppKit after initialization, allocation, shader, drawable,
  atlas, image, or command-buffer failure without clearing terminal output.

## Reliability and tooling

- Adds native GPU pixel-readback, resize stress, and injected-failure tests.
- Fixes headless Hyprland layout when no `NSScreen` is available.
- Fixes AppKit fallback invalidation recursion.
- Corrects retained image ownership for iTerm2 and shared snapshot rendering.
- Updates the Ghostty 1.3 benchmark launcher to use its supported macOS
  `--command=` path.

## Measured results

- Zero overshoots at 60, 120, and 240 Hz in each of three 240-frame Metal runs.
- Median Metal frame percentiles: 1.341 / 1.607 / 2.150 ms.
- Universal app contents: 1,021,676 bytes, below the 1 MiB file-byte limit.
- Default AppKit idle footprint: 32.1 MiB.
- Opt-in Metal idle footprint: 51.4 MiB, so Metal remains opt-in.
