# Metal Phase 1 renderer parity corpus

Phase 1 establishes a deterministic contract and comparison gate shared by the
AppKit and Metal renderers. It does not change parser scheduling, terminal
model ownership, or the selected renderer.

## Corpus

`build/TermaticaBenchmark --renderer-parity-self-test` constructs immutable
`TRenderSnapshot` fixtures and submits each exact snapshot to both renderers.
The seven fixtures cover:

- ASCII, Greek, Cyrillic, CJK, supplementary-plane scalars, combining
  graphemes, emoji modifiers, ZWJ sequences, regional indicators, variation
  selectors, wide cells, and continuation cells;
- bold, italic, inverse, true-colour foreground/background, all five underline
  styles, selection, search, hyperlinks, and colourized plain text;
- focused block and bar cursors plus an inactive underline cursor;
- inline image placement, scroll position, full and partial damage metadata;
- glow, scanlines, vignette, tiled rendering, and 1x/2x backing scales.

The existing `--terminal-self-test` remains responsible for model states that
are intentionally absent from renderer snapshots, including alternate-screen
entry and exit, tabs, arbitrary split layouts, and Hyprland tile geometry.

## Gates

Every fixture must first pass exact structural validation. The test also proves
that malformed cell buffers, masks, cursors, damage ranges, and zero-sized
metrics are rejected by `TRenderSnapshot`.

On a machine with Metal, both backends are captured in BGRA form and compared
over the populated terminal region using block-averaged normalized RGB RMS.
This tolerates expected CoreText antialiasing differences while retaining cell
position and colour sensitivity. The maximum permitted distance is `0.2200`.
A stricter `0.1200` limit applies to fixtures without glow or scanline effects;
this rejects missing ascenders, descenders, or other glyph-atlas clipping that
can be hidden by coarse whole-frame similarity.
A dense-cell background-only negative control must exceed `0.2200`, proving
that an empty or missing-glyph frame cannot satisfy the parity gate.
Capture-coordinate orientation must remain consistent across all fixtures at
each backing scale. A second negative control vertically flips the Metal pixels
inside every terminal cell and requires the unmodified frame to be closer to
AppKit by at least `0.0050`. This distinguishes whole-buffer capture orientation
from an incorrectly inverted glyph texture.

On headless CI, the exact semantic corpus, malformed snapshot rejection, and
forced AppKit fallback gates run without requesting a virtual-display drawable.
A real Metal-capable host remains required for pixel capture, RMS comparison,
cache pressure, and GPU recovery validation.

The command is part of `make check`; any semantic, timeout, glyph orientation,
capture orientation, configuration, visual, or negative-control failure is a
release blocker. `--renderer-switch-self-test` also performs three in-place
AppKit-to-Metal-to-AppKit cycles and verifies first-frame presentation and
terminal-model preservation.
