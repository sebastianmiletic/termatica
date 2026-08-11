# Termatica 1.5.3

Termatica 1.5.3 corrects two defects in the opt-in Metal renderer. AppKit
remains the default renderer and automatic fallback.

## Correctness fixes

- Metal glyph and glow texture coordinates now use the terminal view's upright
  orientation. ASCII, Unicode, fallback-font, combining, and color glyphs no
  longer render vertically mirrored inside their cells.
- Switching an existing terminal from AppKit to Metal now sizes the Metal
  presentation layer synchronously on the main thread. The first Metal snapshot
  is presented instead of being dropped while the layer is still unsized.
- Switching renderers preserves the terminal model and visible content; it does
  not restart the shell or replace the terminal.

## Regression coverage

- The seven-fixture AppKit/Metal pixel corpus now includes a per-cell vertical
  flip negative control. This catches mirrored glyph textures independently of
  the whole-frame coordinate normalization required by AppKit capture buffers.
- A renderer-switch test performs three AppKit-to-Metal-to-AppKit cycles in the
  same terminal, requiring Metal frame completion, AppKit surface rendering,
  and preserved ASCII and Unicode content on every cycle.
- The config regression gate writes, reads, and restores
  `appearance.renderer` through the same config command used by `t c`.

## Release verification

The native parity corpus passed ten consecutive runs. Its maximum normalized
block RMS was `0.1986` against the `0.2200` limit; the deliberately cell-flipped
frames were farther from AppKit in every fixture. Five additional switch tests
completed fifteen renderer transitions in each direction with terminal state
preserved. `make check`, AddressSanitizer, UndefinedBehaviorSanitizer, renderer
fallback and resize checks, the cache-pressure soak, packaging, signature, and
updater-safety tests passed on the release machine.

The release remains a universal macOS 13+ application for Apple Silicon and
Intel Macs. Metal is selected with `appearance.renderer: "metal"`.
