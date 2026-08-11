<p align="center">
  <img src="Resources/AppIcon.png" width="156" alt="Termatica">
</p>

<h1 align="center">Termatica</h1>

<p align="center"><strong>A native PTY terminal for macOS with AppKit and optional Metal rendering.</strong></p>

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

**Download:** use the [latest DMG](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.dmg) (recommended), drag `Termatica.app` to Applications, and open it there. A [ZIP build](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.zip) and checksum file are also available. See [Download and install](#download-and-install) for Gatekeeper and verification instructions.

Termatica is a real PTY-backed terminal written in Objective-C and AppKit. It has no web view, JavaScript runtime, bundled shell, package manager, toolbar, marketplace, or graphical settings window. The shell is the interface. Its opt-in Metal GPU renderer sits behind an immutable snapshot boundary and automatically falls back to AppKit.

The current local universal bundle is **1,321.9 KiB** and runs natively on
Apple Silicon and Intel Macs. Process memory depends on the renderer, config,
scrollback, images, and workload; `t b` reports the running app's current
footprint instead of presenting one host snapshot as a fixed requirement.

## Measured performance

The fresh 2026-08-11 Apple M4 comparison used the same Kitty benchmark protocol for
Termatica 1.9.0, Kitty 0.48.1, Ghostty 1.3.1, Alacritty 0.17.0, WezTerm
20240203, and Rio 0.5.2. Higher throughput is better; lower startup and memory
are better. Bold values are the measured winner in each column.

| Terminal | 15-workload geo mean | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|---:|
| Termatica 1.9.0 | **232.2 MB/s** | 5.696 ms | **26.0 MiB** | **1,360 KiB** |
| Kitty 0.48.1 | 108.7 MB/s | 6.225 ms | 118.1 MiB | 160,080 KiB |
| Ghostty 1.3.1 | 87.3 MB/s | 6.536 ms | 79.4 MiB | 63,484 KiB |
| Alacritty 0.17.0 | 161.7 MB/s | 5.800 ms | 66.5 MiB | 14,328 KiB |
| WezTerm 20240203 | 63.3 MB/s | 5.910 ms | 42.4 MiB | 259,840 KiB |
| Rio 0.5.2 | 93.9 MB/s | **4.874 ms** | 38.0 MiB | 41,992 KiB |

The geometric mean covers six parser, six render-enabled, and three scrollback
workloads. Render-enabled throughput measures accepted input, not confirmed
display completion; image rows do not prove equivalent protocol support or
visual output. Startup is process launch until a child shell writes a ready
marker, not first visible frame. Memory is one post-settle sample. See the
[complete method and limitations](docs/BENCHMARKS.md) and the
[fresh raw artifacts](benchmarks/2026-08-11-v1.9.0-matrix).

To measure the currently running Termatica build with its active visual config:

```sh
t benchmark
# or: t b
# all installed comparison terminals: t b a
```

`t b` measures Termatica now and fills the competitor columns from each
terminal's latest successful, timestamped `t b a` result. `t b a` launches
fresh, isolated Termatica, Kitty, Ghostty, Alacritty, WezTerm, and Rio processes
and refreshes that cache. Termatica receives a temporary copy of the active
config, and the common font and size are applied where each competitor exposes
command-line settings. Results open in a compact native AppKit window showing
all 12 parser/render workloads and the aggregate result in adaptive-width,
monospaced tables. Rows never wrap and every tied winner is bold. Current-app
and run-status details stay in separate tabs. Only processes launched by the
benchmark are closed. Missing or failed terminals
remain `N/A`; a failed fresh run is never presented as successful. The command also reports the
running app's version/build, config, renderer, font, display refresh, process
memory, ASCII/Unicode/CSI throughput, and offscreen
text/image paint FPS. Existing PTYs, tabs, processes, scrollback, and windows
are not closed or replaced.

## What makes it different

- C incremental decoder with span-based ASCII dispatch and chunk-boundary regression coverage
- Immutable render snapshots, an opt-in Metal backend, automatic AppKit fallback, and state-preserving recovery after display, scale, occlusion, and wake changes
- Sixel image rendering with scaling, alpha compositing, and transparency
- Kitty graphics protocol with image query/delete, placement offsets, destination sizing, GIF animation, and virtual placements
- Scrollback search with regex, match counter, case-sensitive toggle, and theme-aware overlay UI
- Real login shells with ANSI 16/256/true color, UTF-8, Unicode, OSC, mouse selection, bracketed paste, Codex-compatible Kitty keyboard handling (flags 0-31 + REP), modifyOtherKeys, focus events, alternate screens, synchronized output (DECSET 2026 + BSU/ESU), DCS dispatch, and five mouse coordinate encodings
- Native wheel and precision-trackpad scrollback with momentum, keyboard paging, new-output anchoring, alternate-screen scrolling, Codex inline-viewport routing, and a visible position indicator
- One terminal-native configuration interface instead of separate plugin, theme, profile, marketplace, or settings menus; every app-facing UI token is arrow-editable, including corner radii, rail geometry, overlays, cursor, scrollbar, effects, and motion
- Plain JSON settings with readable `on`/`off` toggles that remain user- and AI-editable after installation
- Independent, universal named configs that can be copied, created, switched, renamed, and deleted without leaking settings between profiles
- Native numbered tabs and optional Hyprland-style terminal tiling, with animated movement between arbitrary quarter, half, horizontal, vertical, and mixed-size slots
- Exact cursor ownership across tabs and splits: focus changes redraw the old and new cursor cells so Command-T cannot leave cursor ghosts in other terminals
- An overlay tab rail that never changes the terminal grid or moves shell text sideways
- Configurable theme, font, foreground, cursor, ANSI palette, transparency, blur, effects, tabs, animation, plugins, shell, updates, font features, bell style, and every keybinding
- Flat `TCell*` ring scrollback with no per-line allocations, precomputed 256-colour palette, batched ASCII cell writes, an LRU-bumped style attribute cache, no-copy style-run string construction, adaptive ProMotion-aware refresh cadence, interactive parser scheduling, and bounded PTY backpressure
- A guaranteed fresh start: every launch opens one new blank terminal and never restores terminal output, processes, tabs, layouts, paths, or window state
- Automatic shell integration, OSC 133 prompt navigation, inherited working directories, permission-controlled OSC 52 clipboard access, unsafe-paste protection, and Secure Keyboard Entry for no-echo prompts
- Built-in GitHub updater with launch-time update notification, bounded downloads, archive path/size validation, asset digest verification, code-signature validation, staged replacement, and rollback on installation failure
- User-owned `0600` control sockets plus contained, owner-checked extension executables and bounded extension output

## Download and install

Termatica requires macOS 13 or later. Each release is a universal build that
runs natively on Apple Silicon and Intel Macs.

### DMG (recommended)

1. Download the latest
   [Termatica DMG](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.dmg).
2. Open `Termatica-macOS-universal.dmg`.
3. Drag `Termatica.app` onto the `Applications` shortcut in the DMG window.
4. Eject the Termatica disk image, then open Termatica from `/Applications`.

### ZIP

1. Download the latest
   [Termatica ZIP](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.zip).
2. Double-click the ZIP to extract `Termatica.app`.
3. Move `Termatica.app` into `/Applications`, then open it there.

Public builds are ad-hoc signed and are not currently Apple-notarized. On the
first launch, macOS may require you to Control-click `Termatica.app`, choose
**Open**, and confirm. This is a one-time Gatekeeper confirmation for that
installed build.

To verify downloads, place
[`SHA256SUMS`](https://github.com/sebastianmiletic/termatica/releases/latest/download/SHA256SUMS)
beside the downloaded files, then run the matching command:

```sh
grep 'Termatica-macOS-universal.dmg$' SHA256SUMS | shasum -a 256 -c -
grep 'Termatica-macOS-universal.zip$' SHA256SUMS | shasum -a 256 -c -
```

After launch, run `t v` in Termatica to print the installed version. Existing
users can check for a newer release with `t u check` and install it with `t u`.

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
| `t b` | Benchmark Termatica now and compare with saved competitor runs |
| `t b a` | Benchmark every installed comparison terminal now |
| `t rr` | Print a privacy-safe renderer/display field report with no terminal text or paths |
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

The fresh comparison table above records app allocation and one-tab physical
footprint for every terminal. Termatica's logical universal bundle size is
1,321.9 KiB; the comparison harness reports its 1,360 KiB filesystem allocation.
Built-in capability plugins use no persistent helper processes, and terminal
history cells are 12 bytes each. Memory samples are not hard ceilings: fonts,
renderer, effects, window size, scrollback, images, editors, shells, and child
processes affect usage.

## License

[MIT](LICENSE)
