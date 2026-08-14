# Termatica 1.12.1

Termatica 1.12.1 fixes duplicate and stale text cursors during terminal focus,
tab creation, pane movement, and window switching.

- A cursor is now rendered only for the key window's actual first responder.
- Focus transfer clears the previous cursor frame before assigning the new
  terminal as cursor owner.
- Windows invalidate cursor presentation immediately when they resign key
  status, preventing inactive windows from retaining cursor ghosts.
- Regression coverage checks immediate and settled cursor ownership across
  tiled panes and multiple windows.
- AppKit and Metal each passed 120 rapid focus-transfer cycles with exactly one
  active cursor owner.

The complete `make check` gate passed before publication. The Termatica app in
`/Applications` is not replaced by the release process; users can update when
ready and restart the app for the new executable to take effect.
