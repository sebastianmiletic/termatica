# Changelog

## 0.2.0

### Added

- Terminal-native plugin, theme, and module browser.
- Direct `termatica install <id>` command.
- Terminal editor adapter for Vim, Neovim, Emacs, Nano, Micro, and Helix.
- Editor Deck plus focused editor-control plugins.
- Modified arrow keys, Shift-Tab, function keys, and expanded Control and Meta input.

### Changed

- Command-M and marketplace commands now stay inside the active terminal.
- CLI commands accept readable subcommands as well as legacy long flags.
- The PTY grid now occupies the complete window surface with no custom ribbon, status strip, header copy, or Command-K button.

### Fixed

- Editor Deck installation now produces the intended editor commands.
- Command-K remains keyboard-accessible without adding permanent terminal chrome.
- CLI marketplace commands now execute the terminal browser instead of opening a separate window.
