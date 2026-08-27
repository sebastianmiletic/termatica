# Termatica 1.14.2

Termatica 1.14.2 makes terminal interfaces fully clickable and completes the
renderer hardening for rapidly updating AI CLIs and TUIs.

## Mouse input

- Ordinary left, middle, and right clicks now go directly to applications that
  explicitly enable terminal mouse tracking. Buttons, links, lists, menus, and
  panes work without holding Option.
- Button release, drag, hover, wheel, X10, legacy, UTF-8, SGR, urxvt, and SGR
  pixel reporting remain supported.
- Shift-click and Shift-drag select local terminal text, Shift-right-click opens
  Termatica's context menu, and Shift-wheel reads local history.
- Command-click and Command-drag remain available for Termatica links and tiled
  pane movement.

## Rendering

- Wide cells and their underline/link metadata are cleared as one unit during
  overwrite, erase, insert, delete, and resize operations.
- Complex grapheme clusters keep stable terminal-column widths.
- AppKit draws Unicode glyphs from their cell anchors with row clipping, while
  Metal can present immediately if its display link is temporarily stopped.
- Resize preserves valid cells, links, underline styles, and row order without
  leaving orphaned wide-cell halves or clipped text.

## Verification

The release gate covers default mouse clicks, releases, drags, motion, wheel
events, modifier escape hatches, Unicode and wide-cell redraws, renderer parity,
real PTYs, and the installed Codex, Claude, Gemini, OpenCode, and other detected
terminal applications.
