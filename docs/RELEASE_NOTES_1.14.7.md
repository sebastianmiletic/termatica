# Termatica 1.14.7

Termatica 1.14.7 fixes pane-local mixed splits when Hyprland layout is enabled.

## One half plus two quarters

- Command-T vertically splits only the focused pane.
- Selecting either half and pressing Command-Shift-T horizontally splits only
  that selected half.
- The opposite half keeps its exact frame instead of being replaced by a
  full-width pane across the bottom.
- Hyprland still balances independent root tabs and expands them when roots
  close; nested splits now remain inside their assigned root rectangle.

## Verification

The regression gate reproduces the exact shortcut sequence in Hyprland mode,
records both half frames, selects the original half, and invokes the real
Command-Shift-T action. It requires the opposite half to remain byte-for-byte
unchanged, the two quarter panes to remain inside the selected half, exact
width and height accounting, and zero overlap. The complete release gate also
retains 16-root Hyprland reflow and close expansion, drag swapping, real-PTY
automation, mouse input, Codex and Claude redraw checks, AppKit and Metal
parity, updater replacement, universal architectures, and release signatures.
