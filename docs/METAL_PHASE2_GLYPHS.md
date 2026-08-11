# Metal Phase 2 glyph fidelity

Phase 2 improves the opt-in Metal renderer's text rasterization. AppKit remains
the default renderer and the automatic fallback. The parser, PTY, terminal
model, input handling, and active configuration path are unchanged.

## Implemented

- Monochrome glyphs remain in the R8 atlas; CoreText color-font runs now use a
  separate BGRA atlas and retain their intrinsic colors in the Metal shader.
- Glyph records now carry explicit UV, padded offset, raster size, texture kind,
  and benchmark-only fallback metadata. Two logical pixels of scale-aware
  padding preserve antialiasing and italic/combining-mark overhangs.
- Glyph cache identity includes font slot, backing scale, raster dimensions,
  and text. A font-object change invalidates all slot fast paths and rebuilds
  the atlas, preventing stale glyphs after a live font/configuration change.
- Inline images have an independent fragment-texture binding, so color glyphs
  and images cannot overwrite one another's texture state.
- Single, thick, dashed, dotted, and dash-dot underlines use the cell origin and
  CoreText underline position/thickness. Padding no longer shifts decorations.
- Color-glyph and fallback counters exist only in the benchmark build and only
  scan instances during pixel validation; they add no per-frame scan to the
  normal Metal benchmark or production app.

## Deterministic corpus

The shared AppKit/Metal corpus now includes Latin combining marks, Devanagari,
Arabic combining marks, Thai combining marks, CJK, supplementary-plane text,
emoji modifiers, ZWJ emoji, flags, emoji/text variation selectors, and an
invalid scalar that must become the replacement character. Every one of the
seven fixtures records five color-glyph instances and twelve fallback-font or
replacement instances on this machine.

Ten consecutive native runs produced identical results:

| Measurement | Result |
|---|---:|
| 1x text fixture RMS | 0.1666 |
| 2x text/cursor fixture RMS | 0.1788 |
| Effects fixture RMS | 0.2049 |
| Maximum allowed RMS | 0.2200 |
| Background-only negative control | 0.2519, required above 0.2400 |

RMS is a normalized block-averaged RGB distance. It is a parity guard, not a
claim of pixel-identical CoreText antialiasing between AppKit and Metal.

## Verification on 2026-08-11

| Gate | Result |
|---|---|
| `make check` | Pass |
| AddressSanitizer parity / terminal / decoder | Pass |
| UndefinedBehaviorSanitizer parity / terminal / decoder | Pass |
| Repeated native parity | 10 of 10 pass, identical measurements |
| Universal release architecture | arm64 and x86_64 |
| Strict ad-hoc code-sign verification | Pass |
| Bundle size | 1,302,381 bytes; limit 1,310,720 |

Five fresh 240-frame Metal runs measured snapshot construction plus CPU encode
plus GPU execution. Median p50/p95/p99 was 1.224/4.574/4.898 ms. All five runs
had zero frames above the 60 Hz and 120 Hz budgets. Frames above the synthetic
240 Hz budget varied from 0 to 57, with a median of 28. These measurements do
not include display-vsync wait and do not establish a Phase 3 performance gain.

No app was installed, no running Termatica process was closed or restarted, and
no GitHub commit, tag, release, or updater publication was made in this phase.
