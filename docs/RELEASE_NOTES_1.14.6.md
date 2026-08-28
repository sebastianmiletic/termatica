# Termatica 1.14.6

Termatica 1.14.6 makes repeated Command-Shift-T splits strictly pane-local.

## Split only the focused half

- Command-Shift-T still creates a horizontal, stacked split.
- If the focused pane is already half of a terminal layout, the new split now
  subdivides only that focused half.
- Existing sibling halves keep their exact position and size; Termatica no
  longer recalculates them as part of the new split.
- The same subtree-preserving insertion rule applies to repeated Command-T
  vertical splits.

## Verification

The regression gate creates an ordinary tab, splits it into two horizontal
halves, records both frames, focuses the original half, and presses the actual
Command-Shift-T action again. It requires the sibling frame to remain exactly
unchanged, both new panes to stay inside the previously focused half, correct
stacked orientation, matching widths, full height accounting, and no overlap.
The complete release gate retains real-PTY automation, AppKit/Metal parity,
Codex and Claude redraw coverage, mouse input, dense Hyprland reflow, updater
replacement, both architectures, and strict release signatures.
