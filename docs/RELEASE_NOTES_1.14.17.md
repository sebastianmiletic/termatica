# Termatica 1.14.17

Termatica 1.14.17 removes retained cursor trails from the Intel AppKit renderer.

## One cursor position

- AppKit damage now always includes both the previously displayed cursor cell and the current cursor cell.
- On the x86_64 build, a layered terminal tile clears and synchronously repaints its backing store whenever the cursor moves, blinks, changes style, appears, disappears, or transfers to another terminal.
- Hidden-path prompts no longer retain cursor bars on both sides of the semicolon.
- Opening and switching tabs, splits, or windows can no longer preserve a cursor from the previously focused terminal.

## Intel verification

The x86_64 terminal regression runs under Rosetta and covers layered Hyprland panes, repeated focus transfers, cursor movement, blinking, inactive-terminal cleanup, and cross-window ownership. The universal release continues to include native x86_64 and arm64 slices.
