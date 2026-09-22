# Termatica 1.14.21

Termatica 1.14.21 makes interactive keybinding recording reliable, including Command-Enter and other shortcuts normally consumed by the application.

## Reliable keybinding recording

- The config UI and terminal now establish an acknowledged, tokenized capture session before displaying `READING...`.
- The next native key event is intercepted before menu commands or terminal input handling can consume it.
- Command-Enter records as `cmd+return`; Command, Shift, Option, Control, arrows, navigation keys, and F1–F12 use the same normalized path.
- Capture follows the pane that requested it rather than relying only on the currently selected terminal reference.
- Bare Escape cancels, while modified Escape combinations remain bindable.

## Failure handling

- A request that cannot reach the Termatica host reports that capture is unavailable instead of hanging.
- Waiting for a shortcut has a bounded timeout and abandoned host-side capture state expires automatically.
- Token matching prevents stale responses or another pane's input from completing the wrong setting.

## Verification

Regression coverage now verifies the ready acknowledgement, one-shot token lifecycle, Command-Shift character capture, explicit Command-Enter capture, normalized shortcut matching, and stale-state cleanup. The full universal package and updater gates pass with the pinned Termatica release signature.
