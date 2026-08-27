<p align="center">
  <img src="Resources/AppIcon.png" width="156" alt="Termatica">
</p>

<h1 align="center">Termatica</h1>

<p align="center"><strong>A sub-2 MB native macOS terminal with SSH management, split tiling, AI/TUI compatibility, system monitoring, AppKit, and optional Metal rendering.</strong></p>

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

It combines a full terminal emulator with a password-free SSH profile manager,
OpenSSH config discovery, connection diagnostics, key fingerprints, forwarding,
ProxyJump, and one-command remote split layouts. Native tabs and arbitrary
horizontal, vertical, quarter, half, and mixed-size panes can run local shells,
AI coding agents, monitors, editors, and independent remote hosts side by side—
without bundling a browser engine or JavaScript runtime.

The current local universal bundle is **1,493.0 KiB (1,528,880 bytes)**—well
under 2 MB—and runs natively on
Apple Silicon and Intel Macs. Process memory depends on the renderer, config,
scrollback, images, and workload; `t b` reports the running app's current
footprint instead of presenting one host snapshot as a fixed requirement.

## Measured performance

The fresh 2026-08-13 Apple M4 comparison used the same Kitty benchmark protocol for
Termatica 1.12.0, Kitty 0.48.1, Ghostty 1.3.1, Alacritty 0.17.0, WezTerm
20240203, and Rio 0.5.2. Higher throughput is better; lower startup and memory
are better. Bold values are the measured winner in each column.

| Terminal | 15-workload geo mean | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|---:|
| Termatica 1.12.0 | **237.5 MB/s** | 5.170 ms | **26.0 MiB** | **1,408 KiB** |
| Kitty 0.48.1 | 108.1 MB/s | 7.473 ms | 118.2 MiB | 160,080 KiB |
| Ghostty 1.3.1 | 87.1 MB/s | 5.029 ms | 135.7 MiB | 63,484 KiB |
| Alacritty 0.17.0 | 154.6 MB/s | 6.972 ms | 142.6 MiB | 14,328 KiB |
| WezTerm 20240203 | 63.8 MB/s | 5.425 ms | 48.9 MiB | 259,840 KiB |
| Rio 0.5.2 | 95.8 MB/s | **4.687 ms** | 88.4 MiB | 41,992 KiB |

The geometric mean covers six parser, six render-enabled, and three scrollback
workloads. Render-enabled throughput measures accepted input, not confirmed
display completion; image rows do not prove equivalent protocol support or
visual output. Startup is process launch until a child shell writes a ready
marker, not first visible frame. Memory is one post-settle sample. See the
[complete method and limitations](docs/BENCHMARKS.md) and the
[fresh raw artifacts](benchmarks/2026-08-13-v1.12.0-matrix). This run was on
AC power with a 1.75 one-minute system load when inspected; its absolute values must not
be compared with a differently loaded run.

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
- Real login shells with ANSI 16/256/true color, UTF-8, Unicode, OSC, document-anchored mouse selection, bracketed paste, Kitty keyboard flags 0-31 with bounded per-screen push/pop state, repeat/release and associated-text events, modifyOtherKeys, focus events, alternate screens, synchronized output (DECSET 2026 + BSU/ESU), DCS dispatch, and X10/normal/button-motion/all-motion reporting across five mouse coordinate encodings
- Native wheel and precision-trackpad scrollback with momentum, keyboard paging, new-output anchoring, alternate-screen scrolling, Codex inline-viewport routing, and a visible position indicator
- One terminal-native configuration interface instead of separate plugin, theme, profile, marketplace, or settings menus; every app-facing UI token is arrow-editable, including corner radii, rail geometry, overlays, cursor, scrollbar, effects, and motion
- Plain JSON settings with readable `on`/`off` toggles that remain user- and AI-editable after installation
- Independent, universal named configs that can be copied, created, switched, renamed, and deleted without leaking settings between profiles
- Native numbered tabs with independent horizontal, vertical, and mixed split groups in ordinary mode, plus pixel-aligned balanced Hyprland tiling that expands every survivor after panes close and supports clean movement between arbitrary slots
- Terminal-native SSH manager with `0600` password-free profiles, OpenSSH config discovery, identities and fingerprints, ProxyJump, custom options, local/remote/dynamic forwarding, real connection checks, and direct launch into one or many split panes
- Terminal-native automation through `t a`, an owner-only `0600` local socket, and a native AppleScript dictionary for windows, tabs, splits, focus, commands, literal input, named keys, and privacy-safe topology; CLI automation can also close panes, tab groups, and windows while protecting the final terminal
- Explicit named SSH launch recipes for repeatable split layouts, stored without passwords or terminal content and never launched or restored automatically
- Exact cursor ownership across tabs and splits: focus changes redraw the old and new cursor cells so Command-T cannot leave cursor ghosts in other terminals
- A bounded, auto-hiding overlay tab rail that never changes the terminal grid, overlaps labels, or moves shell text sideways
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
t a status
t sm
t cf
t cf path
t u check
t u
```

`t` is the fast command. Common commands include `ssh` (SSH manager), `a` (automation), `sm` (system monitor), `c` (config), `cf` (config file), `u` (update), `r` (reload), `e` (editor), and `x` (extension command). The full `termatica` commands remain available. In every Termatica terminal UI, use the arrow keys and Enter to edit or open items, and Escape or Q to go back.

Running bare `t` or `termatica` prints the full public commands in four compact
sections: Remote & System, Configuration, Tools, and Maintenance. Quick aliases
stay documented here instead of being repeated in that output.

| Command | Purpose |
|---|---|
| `t ssh` | Open the terminal-native SSH profile manager |
| `t ssh tile <names...>` | Start multiple remote hosts across independent split panes |
| `t a status` | Print privacy-safe window, tab, pane, and focus topology as JSON |
| `t a new-tab\|new-window\|split ...` | Create and control fresh terminal surfaces |
| `t a recipe run <name>` | Explicitly launch a saved SSH split layout |
| `t c` | Open the interactive categorized config UI |
| `t sm` | Open the live terminal-native system monitor |
| `t b` | Benchmark Termatica now and compare with saved competitor runs |
| `t b a` | Benchmark every installed comparison terminal now |
| `t cf` | Open the selected config file |
| `t u check` | Check GitHub for an update |
| `t r` | Reload the running app |
| `t e <name> [files]` | Run a terminal editor |
| `termatica config` | Open the interactive categorized config UI |
| `termatica config list` | List the current config first, followed by other saved configs |
| `termatica config get <path>` | Read one setting |
| `termatica config set <path> <value>` | Change one setting and reload the app |
| `termatica config create <name>` | Create a benchmark-tuned default config and make it current |
| `termatica config use <name>` | Activate a named config |
| `termatica config rename <old> <new>` | Rename a config |
| `termatica config delete <name>` | Delete a saved config |
| `termatica config-file` | Open the selected config file |
| `termatica config-file path` | Print the config file path |
| `termatica system-monitor` | Show live CPU, memory, storage, network, device, and process statistics |
| `termatica ssh <action>` | Manage, inspect, check, connect, split, or tile OpenSSH profiles; see [SSH manager](docs/SSH.md) |
| `termatica update [check]` | Check GitHub or securely install the latest release |
| `termatica reload` | Reload the running app |
| `termatica editor <name> [files]` | Run Vim, Neovim, Emacs, Nano, Micro, or Helix |
| `termatica run <name> [text]` | Run a configured extension command |
| `termatica completions install` | Install Zsh, Bash, and Fish completions |

The former `plugins`, `themes`, `configs`, `code`, `marketplace`, and directory menus are removed. Their settings and saved-config actions now live in `termatica config`; direct JSON editing lives in `termatica config-file`.

See the complete [CLI reference](docs/CLI.md).

## Configuration

`termatica config` always opens on Config Files first. It lists each real `.json` filename exactly once and marks it CURRENT, SAVED, or INVALID. Enter opens the current file's settings; Enter on another valid file selects it and opens its settings. New creates a complete default config and selects it. Rename changes the actual filename. Delete removes the selected file, and deleting the current file selects the first valid remaining filename; the only valid config cannot be deleted.

Boolean settings are direct toggles. The terminal UI shows `ON` or `OFF`, and config files store the matching lowercase strings `"on"` or `"off"` instead of numeric or JSON boolean values.

Settings are grouped into:

1. Appearance — theme, font, colours, transparency, blur, effects, and cursor styling
2. Performance — AppKit/Metal renderer, scrollback, Unicode rendering, and OSC integration
3. Tabs & Tiling — tab rail, tile layout, and Hyprland behavior
4. Window — dimensions, corners, shadow, and borderless mode
5. Terminal & Input — shell, clipboard, security, bell, scrollbar, and search
6. Motion — animation switches, speed, and durations
7. Extensions
8. Updates
9. Keybindings

Use Up/Down or J/K to move, Left/Right to change values, Enter to open or edit, and Q to return from settings to Config Files. Changes are written atomically with user-only permissions and reloaded immediately.

All settings live at:

```text
~/.config/termatica/configs/*.json
~/.config/termatica/current
~/.config/termatica/config.json  # compatibility symlink to the current file
```

The same fields can be changed by a person, shell script, or coding agent. See [Configuration](docs/CONFIGURATION.md) for every setting.

Each filename is a full portable schema and is the config's only identity. Switching changes `current`; Termatica never merges the selected file with another profile. `config.json` is only a compatibility link to the selected file, so direct edits still update exactly that profile.

## Updating

Termatica checks `sebastianmiletic/termatica` asynchronously on launch. If a newer release exists, it posts a macOS notification, marks the Dock icon with `UP`, and tells the user to run `termatica update`.

The updater reads the latest public release, downloads the universal ZIP, requires and verifies GitHub's SHA-256 asset digest, verifies the bundle identifier/version/code signature, and stages the replacement beside the destination. If replacement fails, the prior app is restored.

Update checks can be disabled with `updates.checkOnLaunch` in config.

## Keyboard

| Action | Shortcut |
|---|---|
| Copy / paste | Command-C / Command-V |
| Click buttons, links, lists, and panes in mouse-aware terminal software | Click / middle-click / right-click |
| Select terminal text while mouse-aware software is active | Shift-click / Shift-drag |
| Open Termatica's context menu while mouse-aware software is active | Shift-right-click |
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

`make check` builds both architectures, validates commands and completions, exercises scrollback and alternate-screen state, runs the seeded real-PTY app-control campaign, checks terminal performance invariants, and performs a complete updater install against a locally signed mock GitHub release. `make benchmark` runs the reproducible Termatica, Kitty, Ghostty, Alacritty, WezTerm, and Rio comparison when those apps are present. `make package` produces the DMG, ZIP, and `SHA256SUMS` published by the release workflow.

See [Terminal benchmarks](docs/BENCHMARKS.md) for the exact hardware, versions, commands, limitations, and measured results.

## Size and memory

The fresh comparison table above records app allocation and one-tab physical
footprint for every terminal. Termatica's logical universal bundle size is
1,337.9 KiB; the comparison harness reports its 1,376 KiB filesystem allocation.
Built-in capability plugins use no persistent helper processes, and terminal
history cells are 12 bytes each. Memory samples are not hard ceilings: fonts,
renderer, effects, window size, scrollback, images, editors, shells, and child
processes affect usage.

## License

[MIT](LICENSE)
