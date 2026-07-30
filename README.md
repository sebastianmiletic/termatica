<p align="center">
  <img src="Resources/AppIcon.png" width="156" alt="Termatica white lightning bolt">
</p>

<h1 align="center">Termatica</h1>

<p align="center"><strong>The best overall-performing macOS terminal in our six-terminal benchmark—native, under 1 MiB, and shell-ready in 8.8 ms.</strong></p>

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

Termatica is a real PTY-backed terminal written in Objective-C and AppKit. It has no web view, JavaScript runtime, bundled shell, package manager, toolbar, marketplace, or graphical settings window. The shell is the interface. Its opt-in Metal GPU renderer sits behind an immutable snapshot boundary and automatically falls back to AppKit.

The current universal app is **1011.3 KiB**, uses **29.4 MiB** of memory at idle, and runs natively on Apple Silicon and Intel Macs. Its measured shell-ready time is **8.817 ms median / 9.305 ms p95**.

## Measured performance

Fresh `kitten __benchmark__` measurements on an Apple M4 compare the same workloads across Termatica 1.2.3, Kitty 0.48.1, Ghostty 1.3.1, Alacritty 0.17.0, WezTerm 20240203, and Rio 0.5.2. Higher throughput is better; lower startup, memory, and size are better.

| Benchmark | Termatica | Kitty | Ghostty | Alacritty | WezTerm | Rio |
|---|---:|---:|---:|---:|---:|---:|
| Parser ASCII (MB/s) | **165.0** | 74.2 | 54.1 | 56.3 | 18.2 | 67.5 |
| Parser Unicode (MB/s) | **134.4** | 101.6 | 78.9 | 57.0 | 15.2 | 49.5 |
| Parser unique graphemes (MB/s) | **104.1** | 27.1 | 36.1 | 28.6 | 27.8 | 41.0 |
| Parser CSI-heavy (MB/s) | **92.6** | 32.2 | 31.2 | 36.6 | 6.7 | 33.3 |
| Parser long escapes (MB/s) | **270.6** | 262.2 | 58.6 | 80.3 | 92.2 | 64.1 |
| Parser images (MB/s) | **257.6** | 247.1 | 44.4 | 169.7 | 100.6 | 94.2 |
| Render ASCII (MB/s) | **169.0** | 73.7 | 56.9 | 82.4 | 11.1 | 122.2 |
| Render Unicode (MB/s) | **133.2** | 22.8 | 86.0 | 106.0 | 14.0 | 2.9 |
| Render unique graphemes (MB/s) | **102.9** | 27.1 | 24.8 | 46.5 | 7.0 | 49.2 |
| Render CSI-heavy (MB/s) | **91.8** | 32.4 | 26.3 | 49.7 | 2.0 | 41.6 |
| Render long escapes (MB/s) | **294.6** | 260.2 | 56.9 | 91.1 | 16.5 | 97.9 |
| Render images (MB/s) | **288.8** | 241.6 | 42.6 | 180.0 | 15.3 | 136.9 |
| Scrollback ASCII (MB/s) | **96.7** | 59.0 | 56.2 | 66.6 | 6.9 | 65.9 |
| Scrollback Unicode (MB/s) | **106.9** | 83.6 | 79.3 | 88.5 | 8.4 | 29.9 |
| Scrollback CSI-heavy (MB/s) | **92.6** | 43.0 | 30.1 | 50.4 | 4.0 | 35.2 |
| Shell-ready median / p95 (ms) | 8.817 / **9.305** | 8.729 / 10.720 | **8.324** / 11.937 | 9.880 / 13.973 | 9.286 / 14.923 | 9.264 / 14.045 |
| Idle physical footprint (MiB) | **29.4** | 73.7 | 94.4 | 66.1 | 45.4 | 46.1 |
| App allocation (KiB) | **1011.3** | 160,080 | 63,484 | 14,328 | 275,100 | 41,992 |

Termatica leads all 15 throughput workloads and has a 144.8 MB/s geometric mean across them, versus 72.7 MB/s for the next result. Ghostty retains the lowest startup median. See the [full methodology and limitations](docs/BENCHMARKS.md).

## What makes it different

- C incremental decoder with span-based ASCII dispatch and chunk-boundary regression coverage
- Immutable render snapshots and a complete AppKit fallback for the planned Metal backend
- Sixel image rendering with scaling, alpha compositing, and transparency
- Kitty graphics protocol with image query/delete, placement offsets, destination sizing, GIF animation, and virtual placements
- Scrollback search with regex, match counter, case-sensitive toggle, and theme-aware overlay UI
- Real login shells with ANSI 16/256/true color, UTF-8, Unicode, OSC, mouse selection, bracketed paste, Codex-compatible Kitty keyboard handling (flags 0-31 + REP), modifyOtherKeys, focus events, alternate screens, synchronized output (DECSET 2026 + BSU/ESU), DCS dispatch, and five mouse coordinate encodings
- Native wheel and precision-trackpad scrollback with momentum, keyboard paging, new-output anchoring, alternate-screen scrolling, Codex inline-viewport routing, and a visible position indicator
- One terminal-native configuration interface instead of separate plugin, theme, profile, marketplace, or settings menus; every app-facing UI token is arrow-editable, including corner radii, rail geometry, overlays, cursor, scrollbar, effects, and motion
- Plain JSON settings with readable `on`/`off` toggles that remain user- and AI-editable after installation
- Named configs that can be created, switched, renamed, and deleted without leaving the terminal
- Native numbered tabs and optional Hyprland-style terminal tiling
- An overlay tab rail that never changes the terminal grid or moves shell text sideways
- Configurable theme, font, foreground, cursor, ANSI palette, transparency, blur, effects, tabs, animation, plugins, shell, updates, font features, bell style, and every keybinding
- Flat `TCell*` ring scrollback with no per-line allocations, precomputed 256-colour palette, batched ASCII cell writes, an LRU-bumped style attribute cache, no-copy style-run string construction, adaptive ProMotion-aware refresh cadence, and bounded PTY backpressure
- A guaranteed fresh start: every launch opens one new blank terminal and never restores terminal output, processes, tabs, layouts, paths, or window state
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

`t` is the fast command. Common abbreviations are `c` (config), `cf` (config file), `u` (update), `r` (reload), `e` (editor), and `x` (extension command). The full `termatica` commands remain available. In every Termatica terminal UI, use the arrow keys and Enter to edit or open items, and Escape or Q to go back.

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

Boolean settings are direct toggles. The terminal UI shows `ON` or `OFF`, and config files store the matching lowercase strings `"on"` or `"off"` instead of numeric or JSON boolean values.

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
| Search scrollback (regex) | Command-Shift-H |
| Split horizontal | Command-D |
| Split vertical | Command-Shift-D |
| Next / previous split | Command-] / Command-[ |
| Scroll by page | Shift-Page Up / Shift-Page Down |
| Oldest / live output | Shift-Home / Shift-End |
| Local history while a TUI owns the wheel | Shift-wheel |
| Previous / next shell prompt | Command-Shift-P / Command-Option-P |
| Increase / decrease / reset text size | Command-+ / Command-- / Command-0 |

Every shortcut is configurable. See [Configuration](docs/CONFIGURATION.md) for every setting.

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

- CI-built universal app allocation: **1011.3 KiB** (**1,035,557 bytes**) — under 1 MiB
- Clean one-tab physical footprint: **29.4 MiB**
- Three live Hyprland PTYs at 1434×793: **about 65.8 MiB**
- Built-in capability plugins: **zero persistent helper processes**
- Terminal history cells: **12 bytes each**

The same benchmark snapshot measured Kitty at 73.7 MiB and Ghostty at 94.4 MiB idle physical footprint.

Memory figures are reproducible snapshots, not hard ceilings. Fonts, effects, window size, scrollback, editors, shells, and CLI processes affect total usage.

## License

[MIT](LICENSE)
