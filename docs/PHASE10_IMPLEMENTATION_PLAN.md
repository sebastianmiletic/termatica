# Phase 10 Metal renderer implementation plan

This plan implements Metal as an opt-in consumer of immutable terminal
snapshots. It preserves the current parser, PTY queue, screen model, input
handling, and complete AppKit renderer. The safety rules in
`PHASE10_RENDER_CONTRACT.md` are authoritative; the older
`METAL_RENDER_PLAN.md` is historical input only.

## Baseline and non-negotiable gates

The 2026-07-29 pre-Phase-10 baseline is recorded in `BENCHMARKS.md`. Every
milestone must pass `make check`, and the final candidate must satisfy:

- Idle physical footprint below 40 MiB after a 10-second settle.
- Shipped universal app below 1,048,576 file bytes.
- Zero of 240 frames over the 60, 120, and 240 Hz budgets in the existing
  offscreen benchmark, with an equivalent Metal timing path added.
- No regression greater than 3% in the median of three ten-repetition official
  benchmark runs for the cases Termatica currently leads.
- No loss or reordering of snapshots, terminal output, input, or scrollback
  during backend failure, resize, tab changes, or session restoration.
- Pixel parity for text geometry, styles, cursor, selection, search, links, and
  inline images, with documented antialiasing tolerance.

## Milestone 1: complete the immutable render input

`TRenderBackend` is currently declared but not connected to `TTerminalView`.
Before adding Metal:

1. Add immutable style data to `TRenderSnapshot`: resolved foreground,
   background, cursor, selection, accent and plain-text palette colors; font
   descriptors; padding/insets; cursor style and focus/blink state; selection
   and search ranges; scanline, glow, and vignette parameters.
2. Replace untyped image values with immutable image records containing cell
   origin, pixel size, stable identity, and retained `CGImageRef` ownership.
3. Keep live grid, history, grapheme, configuration, and view pointers out of
   the snapshot. Snapshot creation remains under the existing model lock;
   rendering never holds that lock.
4. Add validation for cell count, metadata bounds, generation monotonicity,
   damage ranges, and image lifetime to `--terminal-self-test`.

Acceptance: snapshot fixtures represent every visual input currently read by
`drawRect:` and pass Address Sanitizer plus `make check`.

## Milestone 2: route AppKit through the backend contract

Create `TAppKitRenderBackend` first and make it consume the same snapshot that
Metal will receive. Move drawing primitives out of `TTerminalView` only as they
are covered by parity fixtures. `drawRect:` remains the final AppKit
presentation entry point.

Add an internal backend selector with `appkit` as the default. Backend creation,
configuration, invalidation, presentation, and shutdown must be idempotent.
Any backend error switches to AppKit on the main thread and schedules a full
snapshot without resetting terminal state.

Acceptance: forced AppKit backend is visually and behaviorally identical to
1.0.2, including alternate-screen TUIs, mouse protocols, Shift-wheel history,
tiles, transparency, and accessibility.

## Milestone 3: build renderer-neutral visual tests

Extend `TermaticaBenchmark` with deterministic fixtures for:

- ASCII, ANSI colors, bold, italic, inverse, dim, strike and underline styles.
- Combining marks, grapheme clusters, wide CJK cells, emoji and fallback fonts.
- Block, bar and underline cursors in focused and unfocused states.
- Selection, search highlights, hyperlinks and plain-text palette coloring.
- Sixel, Kitty graphics and iTerm2 images at clipping and resize boundaries.
- Partial row damage, full damage, scroll, resize and backing-scale changes.

Render AppKit and Metal to same-size bitmap outputs. Compare cell geometry and
solid colors exactly, and compare glyph antialiasing with a bounded per-pixel
tolerance plus a maximum changed-pixel ratio. Store only compact fixture inputs
and hashes in the repository.

Acceptance: AppKit reference capture is deterministic across three consecutive
runs on the same OS and scale.

## Milestone 4: implement the minimal Metal backend

Add `TMetalRenderBackend`, backed by `CAMetalLayer`, a dedicated serial render
queue, and triple-buffered instance buffers. The view owns the layer; the
backend owns Metal resources. Present only monotonically increasing snapshot
generations and coalesce queued stale generations without reordering the newest
state.

Use ordered passes for backgrounds, selections/search, glyphs, decorations,
cursor, images, scanlines and vignette. Respect damaged rows, but force full
damage after configuration, scale, drawable-size, atlas or backend changes.
Command-buffer, drawable, shader, device-removal and allocation errors invoke
the AppKit fallback path.

Start with runtime-compiled embedded Metal source to protect the bundle budget.
Measure startup and bundle size against a precompiled `metallib` before choosing
the shipping form; do not assume either is smaller.

Acceptance: ASCII and ANSI fixtures pass, backend toggle survives 1,000 cycles,
and injected initialization/drawable/command-buffer failures recover through
AppKit without output loss.

## Milestone 5: bounded glyph and image caches

Rasterize glyphs with CoreText into a monochrome atlas and use a separate BGRA
atlas for color glyphs. Cache keys include font descriptor, size, backing
scale, glyph identity, style and variation. Use measured CoreText positions for
wide and composed cells instead of assuming double-width placement.

The current 37.9 MiB idle baseline leaves about 2.1 MiB before the hard memory
limit. Begin with a combined 1 MiB idle cache budget, allocate pages lazily,
evict by LRU, and purge on memory pressure, font or scale changes. Inline image
textures must also be bounded and recreated from snapshot-owned image records.

Acceptance: all Unicode and image fixtures pass; a 30-minute mixed Unicode and
image soak remains below 40 MiB after caches settle and purge.

## Milestone 6: scheduling and frame pacing

Drive Metal presentation from display refresh notifications while allowing
immediate full redraw for resize and recovery. Never change parser scheduling
or PTY backpressure as part of renderer work. Record snapshot wait, CPU encode,
GPU completion and present intervals independently.

Extend `--benchmark-experience` to report AppKit and Metal using equivalent
viewport content, damage patterns, warmup and frame counts. Add 60, 120 and
240 Hz synthetic budgets even when the attached display is 60 Hz.

Acceptance: zero of 240 overshoots at all three budgets, no generation reversal,
and no unbounded queue growth during sustained output.

## Milestone 7: reliability and rollout

Run `make check` with AppKit-only, Metal available, Metal forced, and injected
Metal failure. Exercise real shells and alternate-screen applications,
selection/copy/paste, mouse reporting, scrollback, tabs, tiles, resize, sleep
and wake, display changes, session restore, inline images and VoiceOver.

Ship Metal behind an opt-in setting for one release. Keep automatic fallback
and diagnostic counters, but avoid verbose per-frame logging in release builds.
Make Metal the default only after the benchmark, parity, memory, bundle, failure
injection and soak gates all pass. Do not remove AppKit in Phase 10.

## Implementation order

1. Snapshot metadata and ownership tests.
2. AppKit backend adapter and backend lifecycle/fallback tests.
3. Renderer-neutral fixtures and bitmap comparator.
4. Minimal Metal backgrounds and ASCII glyphs.
5. Styles, cursor, selection, search and links.
6. Unicode shaping, wide cells, combining marks and color emoji.
7. Inline images and effects.
8. Damage tracking, frame pacing and cache tuning.
9. Full regression, failure injection, soak and three-run benchmark.
10. Opt-in release; default-on decision only after collected field evidence.
