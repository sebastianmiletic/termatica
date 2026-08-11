# Termatica 1.5.4

Termatica 1.5.4 corrects vertical glyph clipping in the opt-in Metal renderer.
AppKit remains the default renderer and automatic fallback.

## Rendering correction

- Metal now rasterizes CoreText glyphs in a conventional bottom-left bitmap
  coordinate system and positions the baseline from the font descender and
  atlas padding.
- Glyph texture coordinates match that raster orientation. Uppercase ascenders,
  lowercase descenders, Unicode scripts, combining marks, fallback fonts,
  emoji, bold, italic, and glow glyphs retain their full height.
- The correction applies at both 1x and Retina backing scales and does not alter
  parser, PTY, terminal-model, or AppKit behavior.

## Regression coverage

- Non-effects AppKit/Metal fixtures now have a dedicated `0.1200` glyph-fidelity
  limit in addition to the existing orientation and whole-frame gates. The
  clipped v1.5.3 output measured approximately `0.163` and fails this gate; the
  corrected 2x text fixture measured `0.0434` on the release test machine.
- The corpus continues to cover ASCII, Unicode scripts, combining sequences,
  fallback and color glyphs, cursor styles, effects, images, and partial damage.

## Release verification

The default-font parity corpus passed ten consecutive runs. Additional native
pixel runs passed with Monaco at 9 and 18 points, Menlo at 11 and 24 points,
and SF Mono at 11 and 24 points. The corrected Metal frames were visually
inspected at the smallest Monaco and SF Mono settings. `make check`,
AddressSanitizer, UndefinedBehaviorSanitizer, renderer switching and fallback,
cache pressure, terminal behavior, decoder behavior, packaging, and updater
safety passed on the release test machine.

The release remains a universal macOS 13+ application for Apple Silicon and
Intel Macs. Metal is selected with `appearance.renderer: "metal"`.
