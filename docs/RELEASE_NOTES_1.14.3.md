# Termatica 1.14.3

Termatica 1.14.3 removes block-art seams in Claude Code and makes large
Hyprland terminal layouts rebalance cleanly as panes open and close.

## Seamless CLI artwork

- AppKit and Metal now render Unicode block and quadrant elements as exact,
  pixel-aligned rectangles instead of relying on font glyph rasterization.
- Claude Code's multi-row logo and other block-art interfaces no longer show
  black seams between adjoining cells or rows.
- Ghost Glass no longer applies a global scanline overlay. The explicit Amber
  CRT and Green Screen themes retain their intentional CRT effects.

## Stable Hyprland layouts

- Every visible Hyprland terminal is assigned directly to a balanced grid;
  nested split anchors can no longer collapse descendants into thin slivers.
- Tile boundaries are aligned to physical display pixels, avoiding blurry
  fractional layer edges.
- Closing panes recomputes all frames and PTY dimensions immediately, allowing
  every surviving terminal to expand to its full new size without glyph scaling.
- The first Hyprland terminal initializes its renderer synchronously so a rapid
  burst of new panes cannot leave the original terminal with stale metrics.

## Verification

The release gate includes the Claude block/quadrant logo corpus in AppKit/Metal
pixel parity and exercises sixteen mixed split panes before closing back to four,
checking valid render snapshots, non-overlap, preserved content, and expansion.
