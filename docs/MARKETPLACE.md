# Terminal module browser

Termatica's plugin, theme, and profile browser is an ANSI terminal program. It does not open a gallery window or add permanent controls to the terminal.

```sh
termatica plugins
termatica themes
termatica marketplace
```

Use Up/Down or J/K to move, Enter to install, and Q to exit. When input is redirected, type a row number or module id. For automation, bypass the browser:

```sh
termatica install editor-deck
termatica install vim-control
termatica install green-screen
```

Built-in editor controls include Vim, Neovim, terminal-mode Emacs, Nano, Micro, and Helix. Install `editor-deck` for all six, or install one focused control plugin.

## User catalog

`termatica catalog` creates `~/.config/termatica/marketplace.json`. Add modules to its `items` array. Valid kinds are `plugins`, `themes`, and `profiles`.

Downloaded modules must use HTTPS and are limited to 2 MB. Plugin entries and identifiers are validated before files are written. An installed extension is still executable local code, so review its source and trust its publisher.
