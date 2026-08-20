# Termatica 1.14.0

Termatica 1.14.0 adds complete terminal-native automation without weakening its
fresh-start model.

The `termatica automation` command and `t a` alias now control windows, tabs,
horizontal and vertical splits, tab/pane focus, literal input, shell commands,
named keys, activation, and privacy-safe topology through the existing
user-owned mode-`0600` Unix socket. Every public request receives a structured
success or validation response.

macOS automation is native: the app bundle includes an AppleScript dictionary
for the same operations. Named SSH recipes can save a direction and 1–9 managed
profile names, then explicitly launch fresh OpenSSH processes into a split
layout. Recipes contain no passwords, terminal text, scrollback, or process
snapshots.

Automatic terminal-content restoration remains disabled. Every normal launch
still starts one fresh terminal and never restores prior contents, commands,
processes, tabs, splits, paths, recipes, or window state.

The release is a universal macOS 13+ app for Apple Silicon and Intel. Public
artifacts are ad-hoc signed rather than Developer ID notarized.
