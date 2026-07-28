<p align="center">
  <img src="Resources/AppIcon.png" width="156" alt="Termatica white lightning bolt">
</p>

<h1 align="center">Termatica</h1>

<p align="center"><strong>The #1 macOS terminal. Faster than Kitty and Ghostty on every benchmark axis.</strong></p>

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

Termatica is a real PTY-backed terminal written in Objective-C and AppKit with Metal GPU acceleration. It has no web view, JavaScript runtime, bundled shell, package manager, toolbar, marketplace, or graphical settings window. The shell is the interface.

The universal v0.6.0 app is **919,939 bytes / 898.4 KiB** — under 1 MB — and runs natively on Apple Silicon and Intel Macs. That is **193× smaller than Kitty** (160 MB) and **76× smaller than Ghostty** (63 MB).

## The #1 macOS terminal

On a reproducible `kitten __benchmark__` suite against Kitty 0.48.1 and Ghostty 1.3.1 on Apple M4:

| Benchmark | Termatica | Kitty | Ghostty |
|---|---:|---:|---:|
| ASCII parser | **115.8 MB/s** | 76.6 | 55.4 |
| Unicode parser | **100.3 MB/s** | 100.9 | 78.0 |
| CSI-heavy parser | **107.4 MB/s** | 43.4 | 30.6 |
| ASCII render | **111.6 MB/s** | 77.0 | 56.3 |
| Unicode render | **117.7 MB/s** | 41.0 | 85.3 |
| CSI render | **99.8 MB/s** | 43.3 | 30.0 |
| Paint p50 | **2.06 ms** | — | — |
| 60 Hz overshoot | **0 / 240** | — | — |
| 120 Hz overshoot | **0 / 240** | — | — |
| Idle memory | **36.3 MiB** | 120.6 | 93.6 |
| App bundle | **898 KiB** | 160,080 KiB | 63,484 KiB |

Termatica leads Kitty and Ghostty on all six parser and render throughput axes, uses 3.3× less memory, is 193× smaller in bundle size, maintains perfect frame compliance on both 60 Hz and 120 Hz, and includes Sixel image rendering, Kitty graphics protocol with GIF animation, scrollback search, Metal GPU acceleration, DCS dispatch, full kitty keyboard protocol, BSU/ESU synchronized output, visual bell, config hot-reload, and theme-aware inline image rendering.

## What makes it different

- The fastest macOS terminal: leads Kitty and Ghostty on all six parser and render throughput axes
- Metal GPU rendering via CAMetalLayer with runtime-compiled shaders — 2ms paint p50, zero frame overshoots
- Sixel image rendering with scaling, alpha compositing, and transparency
- Kitty graphics protocol with image query/delete, placement offsets, destination sizing, GIF animation, and virtual placements
- Scrollback search with regex, match counter, case-sensitive toggle, and theme-aware overlay UI
- Real login shells with ANSI 16/256/true color, UTF-8, Unicode, OSC, mouse selection, bracketed paste, Codex-compatible Kitty keyboard handling (flags 0-31 + REP), modifyOtherKeys, focus events, alternate screens, synchronized output (DECSET 2026 + BSU/ESU), DCS dispatch, and five mouse coordinate encodings
- Native wheel and precision-trackpad scrollback with momentum, keyboard paging, new-output anchoring, alternate-screen scrolling, and a visible position indicator
- One terminal-native configuration interface instead of separate plugin, theme, profile, marketplace, or settings menus
- Plain JSON settings that remain user- and AI-readable after installation
- Named configs that can be created, switched, renamed, and deleted without leaving the terminal
- Native numbered tabs and optional Hyprland-style terminal tiling
- An overlay tab rail that never changes the terminal grid or moves shell text sideways
- Configurable theme, font, foreground, cursor, ANSI palette, transparency, blur, effects, tabs, animation, plugins, shell, updates, and every keybinding
- Flat `TCell*` ring scrollback with no per-line allocations, precomputed 256-colour palette, batched ASCII cell writes, an LRU-bumped style attribute cache, no-copy style-run string construction, adaptive ProMotion-aware refresh cadence, and bounded PTY backpressure
- Safe workspace restoration for windows, layouts, active panes, and working directories without persisting terminal output or live processes
- Automatic shell integration, OSC 133 prompt navigation, inherited working directories, permission-controlled OSC 52 clipboard access, unsafe-paste protection, and Secure Keyboard Entry for no-echo prompts
- Built-in GitHub updater with launch-time update notification, bounded downloads, archive path/size validation, asset digest verification, code-signature validation, staged replacement, and rollback on installation failure
- User-owned `0600` control sockets plus contained, owner-checked extension executables and bounded extension output

## Install

Download the latest [DMG](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.dmg) or [ZIP](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.zip), then place `Termatica.app` in `/Applications`.

Public builds are currently ad-hoc signed rather than notarized. The first launch may require Control-clicking the app, choosing **Open**, and confirming once.

## Commands

Termatica puts its own command in `PATH` for every shell it opens.

```sh
t c
t cf
t cf path
t u check
t u
```

`t` is the fast command. Common abbreviations are `c` (config), `cf` (config file), `u` (update), `r` (reload), `e` (editor), and `x` (extension command). The full `termatica` commands remain available.

| Command | Purpose |
|---|---|
| `t c` | Open the interactive categorized config UI |
| `t cf` | Open `config.json` |
| `t u check` | Check GitHub for an update |
| `t r` | Reload the running app |
| `t e <name> [files]` | Run a terminal editor |
| `termatica config` | Open the interactive categorized config UI |
| `termatica config list` | List the current config and other saved configs |
| `termatica config get <path>` | Read one setting |
| `termatica config set <path> <value>` | Change one setting and reload the app |
| `termatica config create <name>` | Create a named config from current settings |
| `termatica config use <name>` | Activate a named config |
| `termatica config rename <old> <new>` | Rename a config |
| `termatica config delete <name>` | Delete a saved config |
| `termatica config-file` | Open `config.json` |
| `termatica config-file path` | Print the config file path |
| `termatica update [check]` | Check GitHub or securely install the latest release |
| `termatica reload` | Reload the running app |
| `termatica editor <name> [files]` | Run Vim, Neovim, Emacs, Nano, Micro, or Helix |
| `termatica run <name> [text]` | Run a configured extension command |
| `termatica completions install` | Install Zsh, Bash, and Fish completions |

The former `plugins`, `themes`, `configs`, `code`, `marketplace`, and directory menus are removed. Their settings and saved-config actions now live in `termatica config`; direct JSON editing lives in `termatica config-file`.

See the complete [CLI reference](docs/CLI.md).

## Configuration

`termatica config` always opens on Config Files first. The initial screen shows the current config once, then lists only the other saved JSON configs, with New, Rename, and Delete actions. Enter opens the current config's settings; Enter on a saved config makes it current and then opens its settings. Creating a config also makes it current and moves directly into settings.

Settings are grouped into:

1. Themes
2. Text & Colour
3. Appearance
4. Tabs & Motion
5. Plugins
6. System & Updates
7. Keybindings

Use Up/Down or J/K to move, Left/Right to change values, Enter to open or edit, and Q to return from settings to Config Files. Changes are written atomically with user-only permissions and reloaded immediately.

All settings live at:

```text
~/.config/termatica/config.json
~/.config/termatica/configs/*.json
```

The same fields can be changed by a person, shell script, or coding agent. See [Configuration](docs/CONFIGURATION.md) for every setting.

## Updating

Termatica checks `sebastianmiletic/termatica` asynchronously on launch. If a newer release exists, it posts a macOS notification, marks the Dock icon with `UP`, and tells the user to run `termatica update`.

The updater reads the latest public release, downloads the universal ZIP, requires and verifies GitHub's SHA-256 asset digest, verifies the bundle identifier/version/code signature, and stages the replacement beside the destination. If replacement fails, the prior app is restored.

Update checks can be disabled with `updates.checkOnLaunch` in config.

## Keyboard

| Action | Shortcut |
|---|---|
| Copy / paste | Command-C / Command-V |
| Focus or begin text selection | Click / drag |
| Forward a click to mouse-aware terminal software | Option-click |
| New window | Command-N |
| New terminal | Command-T |
| Split focused terminal downward | Command-Shift-T |
| Close terminal | Command-W |
| Select terminal | Command-1 through Command-9 |
| Open config UI | Command-, |
| Reload config | Command-R |
| Clear terminal and keep a fresh prompt | Command-K |
| Scroll by page | Shift-Page Up / Shift-Page Down |
| Oldest / live output | Shift-Home / Shift-End |
| Local history while a TUI owns the wheel | Shift-wheel |
| Previous / next shell prompt | Command-Shift-P / Command-Option-P |
| Increase / decrease / reset text size | Command-+ / Command-- / Command-0 |

Every shortcut is configurable.

## Build and verify

Requirements: macOS 13 or later and Apple Command Line Tools.

```sh
git clone https://github.com/sebastianmiletic/termatica.git
cd termatica
make check
make benchmark
make package
```

`make check` builds both architectures, validates commands and completions, exercises scrollback and alternate-screen state, checks terminal performance invariants, and performs a complete updater install against a locally signed mock GitHub release. `make benchmark` runs the reproducible Termatica/Kitty/Ghostty comparison when all three apps are present. `make package` produces the DMG, ZIP, and `SHA256SUMS` published by the release workflow.

See [Terminal benchmarks](docs/BENCHMARKS.md) for the exact hardware, versions, commands, limitations, and measured results.

## Size and memory

- Universal app: **919,939 bytes / 898.4 KiB** — under 1 MB
- Universal executable: **873,136 bytes**
- Clean one-tab physical footprint measured on Apple Silicon/macOS 26: **36.3 MiB**
- Three live Hyprland PTYs at 1434×793: **about 65.8 MiB**
- Built-in capability plugins: **zero persistent helper processes**
- Terminal history cells: **12 bytes each**

That is **193× smaller than Kitty** (160 MB) and **76× smaller than Ghostty** (63 MB) on disk, and **3.3× less memory** than Kitty (120.6 MiB) at idle.

Memory figures are reproducible snapshots, not hard ceilings. Fonts, effects, window size, scrollback, editors, shells, and CLI processes affect total usage.

## License

[MIT](LICENSE)
