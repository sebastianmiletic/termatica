# Changelog

## 0.3.0

### Added

- Terminal-native plugin, theme, and module browser.
- Direct `termatica install <id>` command.
- Terminal editor adapter for Vim, Neovim, Emacs, Nano, Micro, and Helix.
- Editor Deck plus focused editor-control plugins.
- Modified arrow keys, Shift-Tab, function keys, and expanded Control and Meta input.
- Minimal vertical numbered tabs with Command-T, Command-W, and Command-1 through Command-9.
- Skeleterm reduced-overhead profile with short scrollback, effects disabled, and extension processes unloaded.
- Neutral `terminal-default` theme with the complete ANSI color palette.
- Configurable shortcuts and tab rail width.
- New lightning-terminal app icon.

### Changed

- Command-M and marketplace commands now stay inside the active terminal.
- Module browsers now support Up/Down, J/K, Enter, and Q navigation.
- CLI commands accept readable subcommands as well as legacy long flags.
- The PTY grid now occupies the complete window surface with no custom ribbon, status strip, header copy, or Command-K button.
- The default font size is 11 points, two points smaller than the previous default.
- Command-K now clears the terminal like a conventional terminal shortcut; extension commands run through `termatica run`.

### Fixed

- Editor Deck installation now produces the intended editor commands.
- CLI marketplace commands now execute the terminal browser instead of opening a separate window.
