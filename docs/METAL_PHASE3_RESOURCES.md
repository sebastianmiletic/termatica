# Metal Phase 3 resource management

Phase 3 bounds the opt-in Metal renderer's GPU resources and adds deterministic
resource-pressure validation. AppKit remains the default renderer and the
automatic fallback. The parser, PTY, terminal model, input handling, and active
configuration path are unchanged.

## Implemented

- Monochrome and color glyph atlases are 1024 x 1024 texture arrays. Each starts
  with one page and grows only when needed, to a hard maximum of four pages.
- The color atlas is not allocated until a color glyph is encountered. Glyph
  instances encode their atlas page, so a page change does not alter cell
  geometry or texture selection.
- Glyph uploads use a per-glyph staging buffer. The former full-size CPU atlas
  mirror is gone.
- Inline-image textures use a byte-accounted least-recently-used cache with a
  32 MiB budget. Hits refresh recency, eviction removes the oldest entries, and
  an individually valid texture larger than the cache budget can render without
  being retained. Uploads larger than 256 MiB are rejected safely.
- macOS memory-pressure notifications purge image and glyph caches on the Metal
  render queue after the in-flight command buffer is safe. The monochrome atlas
  shrinks to one page, the lazy color atlas is released, and the next frame
  rebuilds the resources.
- Font and cell-metric changes invalidate glyph and image resources. Diagnostic
  counters are compiled only into benchmark builds.

## Deterministic resource test

`--renderer-cache-self-test` performs the following in a real Metal renderer:

1. Renders mixed Unicode, color glyphs, and an inline image.
2. Renders 1,200 distinct glyph cells and verifies growth from one to two
   monochrome pages without falling back to AppKit.
3. Submits forty 1 MiB images and verifies the exact 32 MiB image budget. Nine
   LRU evictions occurred in the final run.
4. Reuses retained images for 240 frames and verifies that cache size remains
   bounded.
5. Invokes the same purge path used for memory pressure, verifies that retained
   image/color resources are gone and the monochrome atlas is back to one page,
   then renders the mixed fixture again and verifies Metal recovery.

The recovered mixed fixture used 5,246,336 bytes. A normal text benchmark used
5,242,880 bytes: one 1 MiB monochrome page plus one 4 MiB color page. For
comparison, Phase 2 allocated approximately 24 MiB before cached images: 4 MiB
monochrome GPU, 16 MiB color GPU, and a 4 MiB CPU mirror. The Phase 3 maximum
glyph allocation is bounded at 20 MiB if all four monochrome and all four color
pages are needed; images have their separate 32 MiB bound.

## Verification on 2026-08-11

| Gate | Result |
|---|---|
| `make check` | Pass |
| AddressSanitizer parity / cache / terminal / decoder | Pass |
| UndefinedBehaviorSanitizer parity / cache / terminal / decoder | Pass |
| Native visual parity | Pass; maximum RMS 0.1916, limit 0.2200 |
| Sanitized visual parity | Pass; maximum RMS 0.2049, limit 0.2200 |
| Cache pressure and 240-frame soak | Pass |
| Universal release architecture | arm64 and x86_64 |
| Strict ad-hoc code-sign verification | Pass |
| Bundle size | 1,319,197 bytes; limit 1,327,104 |

Five fresh 240-frame Metal runs measured snapshot construction plus CPU command
encoding plus GPU execution. Median p50/p95/p99 was 1.268/4.186/5.807 ms. All
five runs had zero frames above the 60 Hz budget; one run had one frame above
the 120 Hz budget. Frames above the synthetic 240 Hz budget ranged from 2 to
43, with a median of 13. Every run retained exactly 5,242,880 cache bytes and
reported zero memory-pressure purges.

These measurements do not include display-vsync wait. The p95/p99 result is
noisy and does not establish a Phase 3 frame-time improvement over Phase 2;
Phase 3's demonstrated gain is lower typical resource allocation and bounded
growth. The bundle cap increased by one Mach-O alignment unit because the new
production resource-management code increased the universal executable.

Local installation, running-app verification, and GitHub release verification
are separate states. The Phase 3 release evidence and updater publication state
are recorded in the corresponding release notes rather than inferred from the
local renderer tests in this document.
