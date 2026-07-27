# Configuration

Termatica keeps appearance, terminal behavior, tabs, plugins, updates, and shortcuts in one user-owned file:

```text
~/.config/termatica/config.json
```

Run `termatica config` for the categorized terminal UI or `termatica config-file` to open the JSON itself. Command-, opens the same terminal config UI. Configuration survives app replacement; terminals, terminal text, processes, layouts, and working directories do not.

## Complete generated config

```json
{
  "shell": "/bin/zsh",
  "shellArguments": ["-l"],
  "fontName": "Monaco",
  "fontSize": 11,
  "padding": 12,
  "scrollback": 2000,
  "theme": "terminal-default",
  "themeOptions": ["terminal-default", "amber-crt", "ghost-glass", "green-screen"],
  "textColorMode": "ansi",
  "skeleterm": false,
  "plugins": {
    "hello": false,
    "pi-bridge": false,
    "editor-deck": false,
    "vim-control": false,
    "neovim-control": false,
    "emacs-control": false,
    "nano-control": false,
    "micro-control": false,
    "helix-control": false,
    "hidden-path": false,
    "hyprland-layout": false,
    "unicode-rendering": false,
    "osc-integration": false,
    "borderless-window": false
  },
  "colors": {
    "foreground": "theme",
    "cursor": "theme",
    "palette": "theme"
  },
  "appearance": {
    "backgroundOpacity": "theme",
    "windowOpacity": "theme",
    "blur": "theme",
    "blurMaterial": "theme",
    "glow": "theme",
    "scanlines": "theme",
    "vignette": "theme",
    "cursorStyle": "theme"
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
  "updates": {
    "checkOnLaunch": true,
    "repository": "sebastianmiletic/termatica"
  },
  "keybindings": {
    "openConfig": "cmd+,",
    "newWindow": "cmd+n",
    "newTab": "cmd+t",
    "newVerticalTab": "cmd+shift+t",
    "closeTab": "cmd+w",
    "clearTerminal": "cmd+k",
    "reload": "cmd+r",
    "copy": "cmd+c",
    "paste": "cmd+v",
    "selectAll": "cmd+a",
    "zoomIn": "cmd+plus",
    "zoomOut": "cmd+-",
    "zoomReset": "cmd+0"
  }
}
```

Termatica merges missing default keys into older configs without overwriting user values. Writes are atomic and config files use `0600` permissions.

## Themes

`theme` selects an installed theme. `themeOptions` is the informational installed list. `textColorMode` is `ansi` for normal terminal colors or `spectrum` for optional plain-text coloring. Themes are selected in `termatica config`; there is no separate themes menu.

## Text and colour

| Field | Range |
|---|---|
| `fontName` | Installed fixed-width font name |
| `fontSize` | 8–48 |
| `padding` | 0–40 |
| `scrollback` | 100–100000 lines for the current session |
| `colors.foreground` | `theme` or `#RRGGBB` |
| `colors.cursor` | `theme` or `#RRGGBB` |
| `colors.palette` | `theme` or 16 `#RRGGBB` values |

The tab rail is drawn as an overlay. Changing its visibility or width never reduces terminal columns or moves the prompt.

## Appearance

| Field | Range/options |
|---|---|
| `backgroundOpacity` | `theme` or 0.08–1 |
| `windowOpacity` | `theme` or 0.20–1 |
| `blur` | `theme`, `true`, or `false` |
| `blurMaterial` | `theme`, `hud`, `popover`, `sidebar`, `menu`, or `under-window` |
| `glow` | `theme` or 0–1 |
| `scanlines` | `theme` or 0–1 |
| `vignette` | `theme` or 0–1 |
| `cursorStyle` | `theme`, `block`, `bar`, or `underline` |

`theme` inherits the active theme value. An explicit setting overrides the theme without modifying the theme file.

## Tabs and motion

| Field | Range/options |
|---|---|
| `railWidth` | 28–64 |
| `animations` | Boolean |
| `animationSpeed` | 0.25–4 |
| `autoHide` | Boolean |
| `hideDelay` | 1–30 seconds |
| `tileGap` | 0–24 |
| `screenInset` | 8–80 |
| `hyprlandBlur` | Boolean |

## Plugins

Every built-in and discovered capability is represented as `plugins.<id>: true|false` and appears in the Plugins section of `termatica config`. There is no plugin browser or install menu. Enabling a built-in capability installs its small readable files when needed and applies it on reload.

Important built-ins include `hidden-path`, `hyprland-layout`, `unicode-rendering`, `osc-integration`, and `borderless-window`.

## System and updates

| Field | Meaning |
|---|---|
| `shell` | Absolute shell executable |
| `shellArguments` | JSON argument array; `["-l"]` starts a login shell |
| `skeleterm` | Reduces scrollback and disables expensive effects/extensions |
| `updates.checkOnLaunch` | Asynchronously check for a newer GitHub release at app launch |
| `updates.repository` | GitHub `owner/repository` used by the updater |

The default updater repository is `sebastianmiletic/termatica`. Disable the launch request by setting `updates.checkOnLaunch` to `false`.

## Keybindings

Each keybinding is a string with modifiers joined by `+`. All application shortcuts appear under Keybindings in the config UI.

Command-K clears scrollback and leaves a fresh shell prompt. `newVerticalTab` creates a terminal below the focused terminal. `tab1` through `tab9` may be added to override numbered selection shortcuts.

## Saved configs

Named configs live in `~/.config/termatica/configs/*.json`. Open Config Files at the top of `termatica config` to create, activate, rename, or delete them.

```sh
termatica config create focused
termatica config use focused
termatica config rename focused work
termatica config delete work
```

Set `TERMATICA_CONFIG_DIR=/some/folder` to redirect the complete configuration root for testing, automation, or portable setups.
