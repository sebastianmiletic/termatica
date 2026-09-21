# Termatica 1.14.19

Termatica 1.14.19 adds direct keybinding recording to the terminal-native configuration UI.

## Keybinding capture

- Open `t c`, enter **Keybindings**, select an action, and press Enter to begin recording.
- The selected setting displays `READING...` while Termatica waits for the next key combination.
- Command, Shift, Option, Control, navigation keys, and F1–F12 are normalized into the existing macOS-style notation.
- Escape cancels recording without changing the current binding.
- Capture happens before normal application shortcut dispatch, so combinations such as Command-T and Command-Q can be recorded safely instead of triggering their usual actions.

## Shortcut dispatch

- Recorded shortcuts are applied immediately after the configuration reloads.
- Application actions now match the active configured bindings instead of retaining hard-coded Command-T, Command-W, Command-K, or numbered-tab behavior.
- Navigation and function-key bindings are translated to native AppKit menu equivalents.

## Compatibility

The release remains a universal macOS 13+ application with native x86_64 and arm64 slices. Regression coverage verifies shortcut normalization, the one-shot terminal capture protocol, configuration persistence, both renderers, and the complete updater/package path.
