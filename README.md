<p align="center">
  <img src="Resources/AppIcon.png" width="168" alt="Termatica white lightning logo">
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
       /\
      / /
  ___/ /
  \   /
   \ /
    V
```

The universal release supports Apple Silicon and Intel, targets a complete app size below 1 MB, and launches terminal tools where they belong: inside the terminal. The v0.3.4 app bundle is **600,586 bytes / 586.5 KiB** before DMG/ZIP packaging.

```text
+------------------------------------------------------------------+
|  >_ TERMATICA // MODULES                                        |
|  terminal-native themes and plugins                             |
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
- Separate terminal-native plugin and theme browsers
- Arrow-key and Enter navigation in every module browser
- Live GET/ON/OFF state with one-key download and immediate plugin toggling
- Persistent browsers: change several modules, then press Q once to close
- Editor controls for Vim, Neovim, terminal-mode Emacs, Nano, Micro, and Helix
- Compact connected numbered tabs that grow downward and disappear when only one terminal is open
- Auto-hiding tab rail that reveals on terminal changes or edge hover, then leaves a tiny edge arrow after five seconds
- Native bubble-pop tab creation, directional slide transitions, and furnished tile entry/exit motion with no animation runtime
- Optional Hyprland Layout plugin that tiles and snaps terminal sessions in one window
- Command-Shift-T splits the focused terminal downward, with or without Hyprland Layout
- Fair round-robin PTY output scheduling so one noisy process cannot starve the other terminals or keyboard input
- Direct active-PTY keyboard routing, with no full-canvas focus/layout pass on each tiled keystroke
- Immediate shell, output-queue, and restore-snapshot cleanup when a terminal closes
- Cached 1× tile motion with burst throttling, so rapid terminal creation does not redraw every cell at 60 FPS
- Restored terminal layout, working directories, and bounded scrollback after an ordinary app restart
- User- and AI-readable JSON config profiles managed entirely inside the terminal
- Optional Hidden Path prompt showing `;` at home/root and relative paths such as `Coding/OpenCloud ;`
- Neutral dark default theme with the complete ANSI color palette
- Skeleterm low-memory mode with effects, extensions, and deep scrollback disabled
- Helper-free built-in plugins, compact terminal cells, and an on-demand blur compositor
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

## Size and memory

- Universal `.app` bundle: **600,586 bytes / 586.5 KiB**
- Clean one-tab physical footprint measured on Apple Silicon/macOS 26: **39.8 MiB**
- Skeleterm one-tab physical footprint with no titlebar: **37.0 MiB**
- Three live Hyprland PTYs at 1434×793: **65.8 MiB** physical footprint
- Three unlimited-output Hyprland PTYs: **about 96 MiB RSS, stable**, in the local stress fixture
- Shared Hyprland canvas: one **34.9 MiB** graphics allocation for one or many tiles
- Built-in plugins: **zero persistent helper processes**
- Terminal history cells: **12 bytes each**, 25% smaller than the previous layout
- Scrollback lines omit unused trailing cells and default to 2,000 retained lines
- Blur compositor: created only when blur is enabled; opaque themes use the cheaper window path
- Exited shells cancel their PTY reader immediately, preventing repeated EOF wakeups

These figures are reproducible local snapshots, not guaranteed ceilings; AppKit, macOS, fonts, window size, effects, and scrollback affect them. Codex, Claude, OpenCode, shells, language servers, and editors are separate processes with their own memory budgets. Termatica minimizes the host overhead around them without imposing unsafe heap limits that could break those tools.

## Terminal commands

Termatica prepends its app binary directory to `PATH`, so each shell can call:

```sh
termatica plugins
termatica themes
termatica configs
termatica configs save focused-work
termatica configs use focused-work
termatica install editor-deck
termatica run vim README.md
termatica editor nvim README.md
termatica skeleterm
termatica reload
```

Readable subcommands and legacy flags such as `termatica --plugins` both work. See the complete [CLI reference](docs/CLI.md).

Module browsers stay open while you make multiple changes. `GET` means the plugin or theme is not installed, `ON` means it is active, and `OFF` means it is installed but inactive. Plugin and theme lists remain separate and close only when you press Q.

`termatica configs` opens the saved-config browser. Use Up/Down or J/K, Enter to activate, S to save, R to rename, D to delete with confirmation, and Q to close. Scriptable forms—`list`, `path`, `save NAME`, `use NAME`, `rename OLD NEW`, and `delete NAME`—let a coding agent create or switch setups without proprietary APIs.

## Terminal editor controls

Open the plugin browser and install Editor Deck:

```sh
termatica plugins
# choose editor-deck
```

Run `termatica run vim README.md`, `termatica run nvim src/main.m`, `termatica run emacs`, `termatica run nano`, `termatica run micro`, or `termatica run hx`. The extension writes a `termatica editor ...` command into the active PTY, and the editor takes over the terminal normally. Emacs is forced to `-nw`; no editor integration opens a GUI.

Focused plugins such as `vim-control`, `neovim-control`, and `helix-control` are available when the full deck is unnecessary. The source-readable reference implementation lives in [`examples/editor-controls`](examples/editor-controls).

Install `hyprland-layout` from `termatica plugins` for native automatic tiling. The first terminal fills the window; Command-T snaps additional terminal sessions into a compact grid. Command-Shift-T splits the focused terminal and places the new live PTY directly beneath it, even when Hyprland Layout is disabled. Command-1 through Command-9 changes focus without hiding visible tiles. Command-drag anywhere in a tile, or drag its top padding, to move that live PTY to another position. Disabling the plugin restores normal tab view unless an explicit focused split is open.

Install `hidden-path` from the same plugin browser for a shorter shell prompt. Home and `/` display only `;`. Directories beneath your home folder are relative, so `/Users/you/Coding/OpenCloud` displays `Coding/OpenCloud ;`. The prompt updates after every `cd`, applies to existing shells after the plugin browser returns control, and restores the previous prompt when toggled off. The built-in integration supports Zsh and Bash without a persistent helper process.

## Keyboard

| Action | Shortcut |
|---|---|
| Copy selected cells | Command-C |
| Paste into PTY | Command-V |
| New window | Command-N |
| New terminal tab | Command-T |
| Split focused terminal downward | Command-Shift-T |
| Close terminal tab | Command-W |
| Select terminal tab | Command-1 through Command-9 |
| Open configuration | Command-, |
| Reload configuration | Command-R |
| Clear terminal | Command-K |
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
  "scrollback": 2000,
  "theme": "terminal-default",
  "skeleterm": false,
  "disabledPlugins": [],
  "appearance": {
    "backgroundOpacity": 1.0,
    "windowOpacity": 1.0,
    "blur": false,
    "topBar": true,
    "glow": 0,
    "scanlines": 0,
    "vignette": 0,
    "cursorStyle": "block"
  },
  "tabs": {
    "railWidth": 34,
    "animations": true,
    "animationSpeed": 1.35,
    "autoHide": true,
    "hideDelay": 5,
    "tileGap": 10,
    "screenInset": 18,
    "hyprlandBlur": false
  },
  "session": {
    "restore": true,
    "maxLines": 2000
  }
}
```

See [configuration](docs/CONFIGURATION.md) and [themes](docs/THEMES.md) for all values.

The active file is always `~/.config/termatica/config.json`; named profiles live in `~/.config/termatica/configs/*.json`, and the restart snapshot is `~/.config/termatica/session.json`. These are ordinary editable JSON files that remain outside the application bundle after install. Set `TERMATICA_CONFIG_DIR` to use another portable directory. Session restore recreates the terminal arrangement, working directories, and saved screen/scrollback text with fresh shells; it does not attempt to serialize or revive running processes.

## Extensions

Extensions are executable folders in `~/.config/termatica/extensions`. The native host exchanges one JSON-RPC-style object per line over standard input and output. Extensions register terminal commands invoked with `termatica run <name> [query]` and can write text into the active PTY.

Termatica's bundled plugins use equivalent native command definitions, so enabling all of them does not create persistent Python processes. User and downloaded extensions retain the complete language-neutral subprocess protocol.

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
├── helper-free native definitions for bundled plugins
└── executable custom extensions over JSON lines
    └── registered commands write back to the active PTY
```

The native core is intentionally concentrated in [`src/main.m`](src/main.m). Resources contain the icon and bundled themes. Installed content stays in `~/.config/termatica`, keeping the app small and user data replaceable.

## Current limits

- The parser covers common xterm behavior, not every xterm escape sequence.
- Wide and combining Unicode glyphs currently occupy one grid cell.
- Alternate-screen mode clears the visible grid instead of preserving a separate main-screen buffer.
- Extensions run with the current user's privileges. Review source before installation.
- Public builds are not yet Developer ID signed or notarized.
- The current native implementation and published artifacts target macOS. Windows EXE and Linux packages are not yet available.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Report sensitive issues through GitHub private vulnerability reporting as described in [SECURITY.md](SECURITY.md).

Termatica is available under the [MIT License](LICENSE).
