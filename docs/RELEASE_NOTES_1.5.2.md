# Termatica 1.5.2

Termatica 1.5.2 completes the first three phases of the opt-in Metal renderer:
an immutable parity contract, improved Unicode and color-glyph fidelity, and
bounded GPU resource management. AppKit remains the default renderer and the
automatic fallback.

## Rendering correctness

- A deterministic seven-fixture corpus compares AppKit and Metal output across
  text styles, combining marks, Devanagari, Arabic, Thai, CJK, supplementary
  scalars, emoji modifiers, ZWJ sequences, flags, variation selectors, cursor
  styles, effects, partial damage, and inline images.
- Snapshot semantic validation rejects malformed cell, mask, grapheme, image,
  and damage data before rendering.
- Color-font runs use a dedicated BGRA texture array while monochrome glyphs use
  an R8 texture array. Images retain an independent texture binding.
- Font identity, scale, dimensions, atlas page, padding, and fallback behavior
  are covered by the renderer tests. AppKit remains available if Metal cannot
  initialize or safely present a frame.

The native release test produced a maximum normalized block RMS difference of
0.1916 against a 0.2200 limit. This is a regression threshold, not a claim of
pixel-identical CoreText antialiasing.

## Bounded resources

- Monochrome and color glyph atlases begin with one 1024 x 1024 page and grow
  lazily to a hard maximum of four pages each.
- The full-size CPU atlas mirror is removed. A normal mixed text benchmark
  retained 5,242,880 cache bytes, compared with approximately 24 MiB allocated
  before images in Phase 2.
- Inline images use a byte-accounted 32 MiB least-recently-used cache and a
  256 MiB per-upload safety limit.
- macOS memory-pressure handling waits for in-flight GPU work, releases retained
  image and color resources, shrinks the monochrome atlas to one page, and
  rebuilds on the next frame.
- Renderer shutdown drains queued and in-flight Metal work, cancels the
  memory-pressure source, and releases ARC-managed glyph and image resources in
  ownership-safe order.
- The resource regression test grows the monochrome atlas with 1,200 distinct
  glyphs, applies forty 1 MiB images, verifies LRU eviction, reuses images for
  240 frames, purges the caches, and verifies successful Metal recovery.

## Verification and performance

`make check`, AddressSanitizer, UndefinedBehaviorSanitizer, native visual parity,
the cache-pressure soak, terminal behavior, decoder behavior, packaging, and
updater safety passed on the release test machine.

An optimized repeated pressure/teardown audit also completed 36 consecutive
runs after correcting the image-fixture ownership defect that the audit exposed.
The pre-fix candidate had produced intermittent segmentation faults and was not
published.

Five fresh 240-frame Metal runs measured snapshot construction, CPU command
encoding, and GPU execution. Median p50/p95/p99 was 1.268/4.186/5.807 ms. All
five runs stayed within the 60 Hz budget; one run had one frame above the 120 Hz
budget. The synthetic 240 Hz overshoot count ranged from 2 to 43. These numbers
exclude display-vsync wait and do not establish a universal frame-time gain;
the demonstrated Phase 3 improvement is bounded and lower typical resource
allocation.

The release remains a universal macOS 13+ application for Apple Silicon and
Intel Macs. Metal remains opt-in through `appearance.renderer: "metal"`.
