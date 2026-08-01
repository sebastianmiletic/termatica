<p align="center">
  <img src="Resources/AppIcon.png" width="156" alt="Termatica">
</p>

<h1 align="center">Termatica</h1>

<p align="center"><strong>The highest overall throughput in our six-terminal benchmark—native, about 1.1 MiB, and shell-ready in 7.8 ms.</strong></p>

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

The current universal app allocation is **1144 KiB**, used **30.2 MiB** of physical memory in the current idle snapshot, and runs natively on Apple Silicon and Intel Macs. Its measured shell-ready time is **7.786 ms median / 9.075 ms maximum across five launches**.

## Measured performance

Fresh `kitten __benchmark__` measurements on an Apple M4 compare the same workloads across Termatica 1.4.1, Kitty 0.48.1, Ghostty 1.3.1, Alacritty 0.17.0, WezTerm 20240203, and Rio 0.5.2. Higher throughput is better; lower startup, memory, and size are better.

| Benchmark | Termatica | Kitty | Ghostty | Alacritty | WezTerm | Rio |
|---|---:|---:|---:|---:|---:|---:|
| Parser ASCII (MB/s) | **177.5** | 77.4 | 51.7 | 69.9 | 19.3 | 69.5 |
| Parser Unicode (MB/s) | **119.9** | 102.1 | 86.0 | 103.0 | 29.8 | 53.2 |
| Parser unique graphemes (MB/s) | **94.0** | 28.4 | 37.9 | 45.6 | 40.4 | 40.6 |
| Parser CSI-heavy (MB/s) | **88.9** | 43.5 | 30.7 | 52.0 | 13.2 | 36.5 |
| Parser long escapes (MB/s) | 255.5 | **270.2** | 62.8 | 140.2 | 167.6 | 78.6 |
| Parser images (MB/s) | **300.3** | 248.0 | 44.3 | 230.7 | 130.6 | 101.7 |
| Render ASCII (MB/s) | **172.0** | 77.5 | 58.0 | 86.1 | 18.9 | 129.8 |
| Render Unicode (MB/s) | **117.6** | 71.7 | 84.2 | 115.7 | 25.3 | 9.7 |
| Render unique graphemes (MB/s) | **87.5** | 14.9 | 38.7 | 48.7 | 30.3 | 55.6 |
| Render CSI-heavy (MB/s) | **87.8** | 43.8 | 31.7 | 52.0 | 12.9 | 41.2 |
| Render long escapes (MB/s) | 229.5 | **268.8** | 53.7 | 137.6 | 165.4 | 97.3 |
| Render images (MB/s) | 226.8 | **251.1** | 39.9 | 242.8 | 132.7 | 137.6 |
| Scrollback ASCII (MB/s) | **121.0** | 61.4 | 56.5 | 71.5 | 18.7 | 66.7 |
| Scrollback Unicode (MB/s) | **106.2** | 84.5 | 79.8 | 97.2 | 29.1 | 52.0 |
| Scrollback CSI-heavy (MB/s) | **81.1** | 43.4 | 31.1 | 51.0 | 13.1 | 36.3 |
| 15-workload geometric mean (MB/s) | **137.2** | 80.1 | 49.5 | 88.7 | 35.7 | 56.9 |
| Shell-ready median / max, 5 launches (ms) | **7.786 / 9.075** | 10.309 / 12.489 | 8.416 / 8.892 | 11.583 / 12.385 | 9.356 / 9.911 | 9.014 / 9.691 |
| Idle physical footprint, one sample (MiB) | **30.2** | 120.7 | 86.5 | 65.4 | 46.7 | 42.6 |
| App allocation (KiB) | **1144** | 160,080 | 63,484 | 14,328 | 259,840 | 41,992 |

Termatica leads 12 of the 15 throughput workloads and has a 137.2 MB/s geometric mean across them, versus 88.7 MB/s for the next result. It also has the lowest shell-ready median in this run. A focused back-to-back acceptance run improved the four requested paths over the pre-change build: parser Unicode 103.1→115.7 MB/s, scrollback Unicode 93.7→109.8 MB/s, rendered long escapes 259.7→277.0 MB/s, and rendered images 251.8→264.1 MB/s. See the [full methodology, focused comparison, complete matrix, and limitations](docs/BENCHMARKS.md).

### Responsiveness and energy

Five repeated 10-second AppKit runs on the same Apple M4 measured a **1.486 ms p50 / 1.675 ms p95 / 2.293 ms p99 software key-to-paint lower bound**. The path begins with a synthetic `NSEvent`, passes through Termatica's input mapping and immediate PTY loopback, parses the echo, and paints a full terminal surface. It is not literal physical key-to-photon latency because it excludes keyboard hardware, shell scheduling, WindowServer/vsync, and display scanout.

The same runs used macOS's process-attributed energy counter and measured a median **14.455 J over 10 seconds**, **1.445 W average**, and **11.064 J/GiB** while sustaining Unicode and ANSI output. This is Termatica process energy, not total Mac or display-wall power. Run `make benchmark-experience` to reproduce it; [all five samples](docs/benchmark-results/responsiveness-energy-2026-08-01.json) and the [methodology and limitations](docs/BENCHMARKS.md) are checked in.

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
- Independent, universal named configs that can be copied, created, switched, renamed, and deleted without leaking settings between profiles
- Native numbered tabs and optional Hyprland-style terminal tiling, with animated movement between arbitrary quarter, half, horizontal, vertical, and mixed-size slots
- An overlay tab rail that never changes the terminal grid or moves shell text sideways
- Configurable theme, font, foreground, cursor, ANSI palette, transparency, blur, effects, tabs, animation, plugins, shell, updates, font features, bell style, and every keybinding
- Flat `TCell*` ring scrollback with no per-line allocations, precomputed 256-colour palette, batched ASCII cell writes, an LRU-bumped style attribute cache, no-copy style-run string construction, adaptive ProMotion-aware refresh cadence, interactive parser scheduling, and bounded PTY backpressure
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
| `termatica config create <name>` | Create a benchmark-tuned default config and make it current |
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

Each named config is a full portable schema. The active `config.json` mirrors only the selected config, so switching files cannot inherit stale nested values or overwrite an unrelated config.

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
| Move one word backward / forward | Option-Left / Option-Right |
| Delete the previous word | Option-Delete |
| New window | Command-N |
| New terminal | Command-T |
| Split focused terminal downward | Command-Shift-T |
| Move any tiled terminal | Command-drag, or drag from its top padding |
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

`make check` builds both architectures, validates commands and completions, exercises scrollback and alternate-screen state, checks terminal performance invariants, and performs a complete updater install against a locally signed mock GitHub release. `make benchmark` runs the reproducible Termatica, Kitty, Ghostty, Alacritty, WezTerm, and Rio comparison when those apps are present. `make package` produces the DMG, ZIP, and `SHA256SUMS` published by the release workflow.

See [Terminal benchmarks](docs/BENCHMARKS.md) for the exact hardware, versions, commands, limitations, and measured results.

## Size and memory

- Local universal app allocation: **1,144 KiB**
- Clean one-tab physical footprint in the current snapshot: **30.2 MiB**
- Three live Hyprland PTYs at 1434×793: **about 65.8 MiB**
- Built-in capability plugins: **zero persistent helper processes**
- Terminal history cells: **12 bytes each**

The same benchmark snapshot measured Kitty at 120.7 MiB, Ghostty at 86.5 MiB, Alacritty at 65.4 MiB, WezTerm at 46.7 MiB, and Rio at 42.6 MiB idle physical footprint.

Memory figures are reproducible snapshots, not hard ceilings. Fonts, effects, window size, scrollback, editors, shells, and CLI processes affect total usage.

## License

[MIT](LICENSE)
