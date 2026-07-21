<p align="center">
  <img src="Resources/AppIcon.png" width="168" alt="Termatica lightning terminal logo">
</p>

<h1 align="center">Termatica</h1>

<p align="center"><strong>A tiny native macOS terminal with an extensible, terminal-first command harness.</strong></p>

<p align="center">
  <a href="https://github.com/sebastianmiletic/termatica/actions/workflows/ci.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/sebastianmiletic/termatica/ci.yml?branch=main&style=flat-square&label=build"></a>
  <a href="https://github.com/sebastianmiletic/termatica/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/sebastianmiletic/termatica?style=flat-square&color=7AA2F7"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-7AA2F7?style=flat-square"></a>
  <img alt="macOS 13 or later" src="https://img.shields.io/badge/macOS-13%2B-151820?style=flat-square">
</p>

<p align="center">
  <a href="https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.dmg"><img alt="Download DMG" src="https://img.shields.io/badge/Download-DMG-7AA2F7?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.zip"><img alt="Download ZIP" src="https://img.shields.io/badge/Download-ZIP-2B3445?style=for-the-badge&logo=apple&logoColor=white"></a>
</p>

Termatica is a real PTY-backed terminal written in Objective-C and AppKit. It has no web view, JavaScript engine, bundled shell, package manager, or third-party framework. The default window is the shell itself. Themes, plugins, AI tools, and editor integrations live in user-owned files outside the app bundle.

```text
┌──────────────┐
│ ●  ●  ●      │
├──────────────┤
│     /\       │
│    / /__  _  │
│   /___ / |_| │
│      /_/  ▔  │
└──────────────┘
```

The universal release supports Apple Silicon and Intel, targets a complete app size below 1 MB, and launches terminal tools where they belong: inside the terminal.

```text
+------------------------------------------------------------------+
|  >_ TERMATICA // MODULES                                        |
|  terminal-native themes, plugins and resource profiles          |
+------------------------------------------------------------------+
  1  [ED] EDITOR DECK       Vim, Neovim, Emacs, Nano, Micro, Helix
  2  [VI] VIM CONTROL       /vim opens files in the active terminal
  3  [NV] NEOVIM CONTROL    /nvim opens files in the active terminal

module> editor-deck
```

## Highlights

- Real login shell through a native pseudo-terminal
- Plain full-window terminal surface with no toolbar, header text, or status strip
- AppKit cell renderer with ANSI 16/256/true color
- UTF-8 input and output, cursor movement, erase modes, scroll regions, and bracketed paste
- Vim-friendly Control, Meta, modified arrow, Shift-Tab, navigation, and function-key sequences
- Command-C copy, Command-V paste, mouse selection, and scrollback
- Terminal-native plugin, theme, and profile browser
- Arrow-key and Enter navigation in every module browser
- Editor controls for Vim, Neovim, terminal-mode Emacs, Nano, Micro, and Helix
- Minimal numbered vertical tabs that disappear when only one terminal is open
- Neutral dark default theme with the complete ANSI color palette
- Skeleterm reduced-overhead profile with effects, extensions, and deep scrollback disabled
- Language-neutral JSON-lines extension protocol
- Portable JSON themes with opacity, blur, glow, scanlines, vignette, cursor, and palette control
- Universal Apple Silicon and Intel binary with a 1 MB bundle budget

## Install

Download the latest [DMG](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.dmg) or [ZIP](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.zip), then move `Termatica.app` to `/Applications`.

Current public builds are ad-hoc signed and not notarized. On first launch, macOS may require Control-clicking the app, choosing **Open**, and confirming once. Release checksums are published as `SHA256SUMS` beside each download.

### Build from source

Requirements: macOS 13 or later and Apple Command Line Tools.

```sh
git clone https://github.com/sebastianmiletic/termatica.git
cd Termatica
make release
open build/Termatica.app
```

Use `make check` for command and plugin protocol tests, `make size` for the bundle budget, or `make package` to create release-ready DMG and ZIP files.

## Terminal commands

Termatica prepends its app binary directory to `PATH`, so each shell can call:

```sh
termatica plugins
termatica themes
termatica marketplace
termatica install editor-deck
termatica run vim README.md
termatica editor nvim README.md
termatica skeleterm
termatica reload
```

Readable subcommands and legacy flags such as `termatica --plugins` both work. See the complete [CLI reference](docs/CLI.md).

## Terminal editor controls

Open the plugin browser and install Editor Deck:

```sh
termatica plugins
# choose editor-deck
```

Run `termatica run vim README.md`, `termatica run nvim src/main.m`, `termatica run emacs`, `termatica run nano`, `termatica run micro`, or `termatica run hx`. The extension writes a `termatica editor ...` command into the active PTY, and the editor takes over the terminal normally. Emacs is forced to `-nw`; no editor integration opens a GUI.

Focused plugins such as `vim-control`, `neovim-control`, and `helix-control` are available when the full deck is unnecessary. The source-readable reference implementation lives in [`examples/editor-controls`](examples/editor-controls).

## Keyboard

| Action | Shortcut |
|---|---|
| Copy selected cells | Command-C |
| Paste into PTY | Command-V |
| New window | Command-N |
| New terminal tab | Command-T |
| Close terminal tab | Command-W |
| Select terminal tab | Command-1 through Command-9 |
| Open configuration | Command-, |
| Reload configuration | Command-R |
| Clear terminal | Command-K |
| Terminal module browser | Command-M |
| Increase, decrease, reset text | Command-+, Command--, Command-0 |

Control-C is sent to the running process. Command-C only copies when terminal cells are selected.

## Configuration

Press Command-, or run `termatica config` to create `~/.config/termatica/config.json`.

```json
{
  "shell": "/bin/zsh",
  "shellArguments": ["-l"],
  "fontName": "Monaco",
  "fontSize": 11,
  "padding": 12,
  "scrollback": 5000,
  "theme": "terminal-default",
  "appearance": {
    "backgroundOpacity": 1.0,
    "windowOpacity": 1.0,
    "blur": false,
    "glow": 0,
    "scanlines": 0,
    "vignette": 0,
    "cursorStyle": "block"
  }
}
```

See [configuration](docs/CONFIGURATION.md) and [themes](docs/THEMES.md) for all values.

## Extensions

Extensions are executable folders in `~/.config/termatica/extensions`. The native host exchanges one JSON-RPC-style object per line over standard input and output. Extensions register terminal commands invoked with `termatica run <name> [query]` and can write text into the active PTY.

```text
my-extension/
├── extension.json
└── extension.py
```

The protocol has no required implementation language. Use a script with a valid shebang or a compiled executable. Start with the [extension protocol](docs/EXTENSIONS.md), [Hello example](examples/hello), or [Editor Controls example](examples/editor-controls).

## Architecture

```text
AppKit window
└── native terminal grid
    └── forkpty login shell
        ├── termatica CLI and module browser
        └── terminal editors and user commands

extension host
└── executable child processes over JSON lines
    └── registered commands write back to the active PTY
```

The native core is intentionally concentrated in [`src/main.m`](src/main.m). Resources contain the icon and bundled themes. Installed content stays in `~/.config/termatica`, keeping the app small and user data replaceable.

## Current limits

- The parser covers common xterm behavior, not every xterm escape sequence.
- Wide and combining Unicode glyphs currently occupy one grid cell.
- Alternate-screen mode clears the visible grid instead of preserving a separate main-screen buffer.
- Extensions run with the current user's privileges. Review source before installation.
- Public builds are not yet Developer ID signed or notarized.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Report sensitive issues through GitHub private vulnerability reporting as described in [SECURITY.md](SECURITY.md).

Termatica is available under the [MIT License](LICENSE).
