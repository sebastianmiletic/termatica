# Termatica 1.12.2

Termatica 1.12.2 corrects the remaining stale and duplicated text-cursor
artifacts when moving focus between terminals, tabs, panes, and windows.

- The text cursor is now a synchronous, focus-owned overlay instead of pixels
  retained inside each pane's AppKit or Metal framebuffer.
- A cursor is visible only when its terminal is active, its window is key, and
  that terminal is the window's first responder.
- Losing focus hides the previous cursor immediately, preventing old cursor
  positions from remaining before or after the shell prompt.
- AppKit and Metal render terminal content without embedding cursor pixels, so
  delayed frames cannot restore a stale cursor.
- Cursor geometry remains configurable for block, bar, and underline styles.
- Regression coverage verifies exact cursor movement, immediate focus loss,
  tiled Hyprland panes, multiple windows, 240 focus switches, and renderer
  lifecycle recovery.

The complete `make check` gate passed before publication. The release process
does not replace or restart a running `/Applications/Termatica.app`; users can
update when ready and restart Termatica for the new executable to take effect.
