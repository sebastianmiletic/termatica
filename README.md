<p align="center">
  <img src="Resources/AppIcon.png" width="156" alt="Termatica white lightning bolt">
</p>

<h1 align="center">Termatica</h1>

<p align="center"><strong>A tiny, native, fully configurable macOS terminal.</strong></p>

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

Termatica is a real PTY-backed terminal written in Objective-C and AppKit. It has no web view, JavaScript runtime, bundled shell, package manager, toolbar, marketplace, or graphical settings window. The shell is the interface.

The universal v0.5.0 app is **666,417 bytes / 650.8 KiB** before DMG or ZIP packaging and runs natively on Apple Silicon and Intel Macs.

## What makes it different

- Real login shells with ANSI 16/256/true color, UTF-8, Unicode, OSC, mouse selection, bracketed paste, Kitty keyboard protocol, and modifyOtherKeys
- One terminal-native configuration interface instead of separate plugin, theme, profile, marketplace, or settings menus
- Plain JSON settings that remain user- and AI-readable after installation
- Named configs that can be created, switched, renamed, and deleted without leaving the terminal
- Native numbered tabs and optional Hyprland-style terminal tiling
- An overlay tab rail that never changes the terminal grid or moves shell text sideways
- Configurable theme, font, foreground, cursor, ANSI palette, transparency, blur, effects, tabs, animation, plugins, shell, updates, and every keybinding
- Fair PTY scheduling and bounded output work so multiple busy terminals remain responsive
- No terminal/session restoration: every launch starts with one fresh shell, while configuration is always retained
- Built-in GitHub updater with launch-time update notification, asset digest verification, code-signature validation, staged replacement, and rollback on installation failure

## Install

Download the latest [DMG](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.dmg) or [ZIP](https://github.com/sebastianmiletic/termatica/releases/latest/download/Termatica-macOS-universal.zip), then place `Termatica.app` in `/Applications`.

Public builds are currently ad-hoc signed rather than notarized. The first launch may require Control-clicking the app, choosing **Open**, and confirming once.

## Commands

Termatica puts its own command in `PATH` for every shell it opens.

```sh
termatica config
termatica config-file
termatica config-file path
termatica update check
termatica update
```

| Command | Purpose |
|---|---|
| `termatica config` | Open the interactive categorized config UI |
| `termatica config list` | List the active and saved configs |
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

`termatica config` begins with saved config files and these categories:

1. Themes
2. Text & Colour
3. Appearance
4. Tabs & Motion
5. Plugins
6. System & Updates
7. Keybindings

Use Up/Down or J/K to move, Left/Right to change values, Enter to open or edit, and Q to go back. The config-file panel includes New, Rename, Delete, and Use actions. Changes are written atomically with user-only permissions and reloaded immediately.

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
| New window | Command-N |
| New terminal | Command-T |
| Split focused terminal downward | Command-Shift-T |
| Close terminal | Command-W |
| Select terminal | Command-1 through Command-9 |
| Open config UI | Command-, |
| Reload config | Command-R |
| Clear terminal and keep a fresh prompt | Command-K |
| Increase / decrease / reset text size | Command-+ / Command-- / Command-0 |

Every shortcut is configurable.

## Build and verify

Requirements: macOS 13 or later and Apple Command Line Tools.

```sh
git clone https://github.com/sebastianmiletic/termatica.git
cd termatica
make check
make package
```

`make check` builds both architectures, validates commands and completions, exercises config management, checks terminal performance invariants, and performs a complete updater install against a locally signed mock GitHub release. `make package` produces the DMG, ZIP, and `SHA256SUMS` published by the release workflow.

## Size and memory

- Universal app: **666,417 bytes / 650.8 KiB**
- Universal executable: **623,344 bytes**
- Clean one-tab physical footprint measured on Apple Silicon/macOS 26: **about 39 MiB**
- Three live Hyprland PTYs at 1434×793: **about 65.8 MiB**
- Built-in capability plugins: **zero persistent helper processes**
- Terminal history cells: **12 bytes each**

Memory figures are reproducible snapshots, not hard ceilings. Fonts, effects, window size, scrollback, editors, shells, and CLI processes affect total usage.

## License

[MIT](LICENSE)
