# Termatica Configuration

Each config is a plain JSON file in `~/.config/termatica/configs/`. The filename is its complete and only identity: `work.json` is shown as `work.json` in `t c`, selected by `termatica config use work.json`, and opened by `t cf` while current. The private `~/.config/termatica/current` selector contains the current filename. `~/.config/termatica/config.json` remains as a compatibility symlink to the selected file, so existing scripts and editors continue to edit the right config. Toggle values are always `"on"` or `"off"`, never `0`, `1`, `true`, or `false`.

Every config is a complete, self-contained schema rather than a partial overlay. Switching changes the selector and reloads that one file; it never copies or merges values from another config. Existing partial configs are upgraded atomically to schema version 2 while preserving their explicit values. Config files and the selector use user-only `0600` permissions. Termatica watches the whole config directory, including repeated direct edits, renames, new files, deletion, and selection changes. Run `t r` for an explicit reload if needed.

Creating a config starts from the same benchmark-tuned defaults used by the release benchmark harness rather than copying the currently selected profile. That baseline uses Monaco 11, the opaque `terminal-default` theme, AppKit rendering, disabled blur/glow/scanlines/vignette, a 2,000-line scrollback, and default-off optional plugins. Installed custom plugins discovered during normalization also remain off. The newly created complete profile becomes current and can then be customized independently.

The current profile is always the first entry in both `termatica config` and
`termatica config list`. Every other profile remains case-insensitively sorted,
so switching profiles changes one intentional top entry without randomizing the
rest of the list.

Run `termatica config` for the interactive editor. Use Up/Down to select any setting and Left/Right (or Enter) to cycle through validated values. Press Escape or Q to go back from every Termatica menu. The settings editor never asks you to type a custom value; config-file names remain the only text-entry operation.

## Full config reference

```json
{
  "schemaVersion": 2,
  "shell": "/bin/zsh",
  "shellArguments": ["-l"],
  "scrollback": 2000,
  "theme": "terminal-default",
  "themeOptions": ["terminal-default", "amber-crt", "ghost-glass", "green-screen"],
  "textColorMode": "ansi",
  "fontName": "Monaco",
  "fontSize": 11,
  "padding": 12,
  "fontFeatures": ["calt", "liga"],
  "colors": {
    "background": "#101216",
    "foreground": "#D8DEE9",
    "cursor": "#EEF1F5",
    "accent": "#7AA2F7",
    "panel": "#151820",
    "muted": "#6B7280",
    "selection": "#2B3445",
    "palette": ["#1B1D23", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#D7DAE0", "#5C6370", "#F07178", "#AAD94C", "#FFB454", "#59C2FF", "#D2A6FF", "#95E6CB", "#EEF1F5"],
    "plainTextPalette": ["#7CE38B", "#7DD3FC", "#FFE083", "#FF8787", "#DDB2F4", "#67B7F7"]
  },
  "appearance": {
    "backgroundOpacity": 1.0,
    "windowOpacity": 1.0,
    "blur": "off",
    "blurMaterial": "hud",
    "glow": 0,
    "scanlines": 0,
    "vignette": 0,
    "cursorStyle": "block",
    "renderer": "appkit"
  },
  "window": {
    "initialWidth": 580,
    "initialHeight": 350,
    "minimumWidth": 480,
    "minimumHeight": 280,
    "cornerRadius": 14,
    "tileCornerRadius": 14,
    "shadow": "off"
  },
  "system": {
    "pasteProtection": "off",
    "secureKeyboard": "on",
    "shellIntegration": "on",
    "clipboardRead": "ask",
    "clipboardWrite": "allow",
    "bellStyle": "sound"
  },
  "updates": {
    "checkOnLaunch": "on",
    "repository": "sebastianmiletic/termatica"
  },
  "plugins": {
    "hello": "off",
    "pi-bridge": "off",
    "editor-deck": "off",
    "vim-control": "off",
    "neovim-control": "off",
    "emacs-control": "off",
    "nano-control": "off",
    "micro-control": "off",
    "helix-control": "off",
    "hidden-path": "off",
    "hyprland-layout": "off",
    "unicode-rendering": "off",
    "osc-integration": "off",
    "borderless-window": "off"
  },
  "tabs": {
    "railWidth": 34,
    "animations": "on",
    "animationSpeed": 1.35,
    "autoHide": "on",
    "hideDelay": 5,
    "tileGap": 10,
    "screenInset": 18,
    "hyprlandBlur": "off",
    "railMargin": 8,
    "railCornerRadius": 11,
    "buttonCornerRadius": 8,
    "buttonFontSize": 11,
    "buttonInset": 4,
    "minimumHeight": 20,
    "maximumHeight": 28,
    "selectedOpacity": 0.22,
    "hoverOpacity": 0.68,
    "railOpacity": 0.96,
    "railBlurOpacity": 0.26,
    "edgeOpacity": 0.58,
    "collapsedPeek": 7
  },
  "terminalUI": {
    "cursorThickness": 2,
    "cursorBlockOpacity": 0.42,
    "cursorInactiveOpacity": 0.20,
    "scrollbarWidth": 2.5,
    "scrollbarMargin": 5,
    "scrollbarMinimumThumb": 24,
    "scrollbarOpacity": 0.42,
    "scanlineSpacing": 4,
    "scanlineThickness": 1,
    "vignetteLayers": 6,
    "searchWidth": 340,
    "searchHeight": 28,
    "searchCornerRadius": 6
  },
  "motion": {
    "launchDuration": 0.30,
    "terminalDuration": 0.18,
    "layoutDuration": 0.12
  },
  "keybindings": {
    "openConfig": "cmd+,",
    "newWindow": "cmd+n",
    "newTab": "cmd+t",
    "newVerticalTab": "cmd+shift+t",
    "closeTab": "cmd+w",
    "clearTerminal": "cmd+k",
    "searchScrollback": "cmd+shift+h",
    "previousPrompt": "cmd+shift+p",
    "nextPrompt": "cmd+option+p",
    "reload": "cmd+r",
    "copy": "cmd+c",
    "paste": "cmd+v",
    "selectAll": "cmd+a",
    "splitHorizontal": "cmd+d",
    "splitVertical": "cmd+shift+d",
    "nextSplit": "cmd+]",
    "previousSplit": "cmd+[",
    "zoomIn": "cmd+plus",
    "zoomOut": "cmd+-",
    "zoomReset": "cmd+0"
  }
}
```

## Settings reference

### Shell

| Key | Type | Default | Description |
|---|---|---|---|
| `shell` | string | `/bin/zsh` | Absolute path to shell executable |
| `shellArguments` | array | `["-l"]` | Arguments passed to the shell; `["-l"]` starts a login shell |
| `scrollback` | integer | `2000` | Maximum history lines (100–100000) |

### Text & Colour

| Key | Type | Default | Description |
|---|---|---|---|
| `theme` | string | `"terminal-default"` | Active theme name |
| `themeOptions` | array | 4 themes | Available theme names |
| `textColorMode` | string | `"ansi"` | `"ansi"` for standard colors, `"spectrum"` for per-token plain-text coloring |
| `fontName` | string | `"Monaco"` | Font family name |
| `fontSize` | integer | `11` | Font size in points (8–48) |
| `padding` | integer | `12` | Terminal content padding in points (0–40) |
| `fontFeatures` | array | `[]` | OpenType features: `"liga"`, `"calt"`, `"ss01"`, `"ss02"`, `"zero"` |

### Colors (nested under `"colors"`)

| Key | Type | Default | Description |
|---|---|---|---|
| `background` | hex | `#101216` | Terminal and window background |
| `foreground` | hex | `#D8DEE9` | Default text color |
| `cursor` | hex | `#EEF1F5` | Cursor color |
| `accent` | hex | `#7AA2F7` | UI accent color (borders, highlights) |
| `panel` | hex | `#151820` | Panel/overlay background |
| `muted` | hex | `#6B7280` | Muted text color (e.g., search counter) |
| `selection` | hex | `#2B3445` | Text selection background |
| `palette` | array | 16 ANSI | 16 ANSI colors as hex strings. Omit to use theme palette. |
| `plainTextPalette` | array | 6 colors | Colors for `"spectrum"` text color mode |

### Appearance (nested under `"appearance"`)

| Key | Type | Default | Description |
|---|---|---|---|
| `backgroundOpacity` | float | `1.0` | Terminal background opacity (0.0–1.0) |
| `windowOpacity` | float | `1.0` | Window opacity (0.0–1.0) |
| `blur` | toggle | `"off"` | Enable macOS vibrancy blur |
| `blurMaterial` | string | `"hud"` | Vibrancy material: `hud`, `popover`, `sidebar`, `menu`, or `under-window` |
| `glow` | float | `0` | Phosphor glow intensity (0.0–1.0) |
| `scanlines` | float | `0` | CRT scanline intensity (0.0–1.0) |
| `vignette` | float | `0` | Edge vignette intensity (0.0–1.0) |
| `cursorStyle` | string | `"block"` | Cursor style: `"block"`, `"bar"`, or `"underline"` |
| `renderer` | string | `"appkit"` | Rendering backend: `"appkit"` or opt-in `"metal"` |

### Window & Surfaces (nested under `"window"`)

| Key | Type | Default | Description |
|---|---|---|---|
| `initialWidth` / `initialHeight` | number | `580` / `350` | Minimum preferred new-window dimensions; Termatica expands proportionally on larger displays |
| `minimumWidth` / `minimumHeight` | number | `480` / `280` | Smallest allowed window dimensions |
| `cornerRadius` | number | `14` | Main window corner radius |
| `tileCornerRadius` | number | `14` | Split/tiled terminal corner radius |
| `shadow` | toggle | `"off"` | Native window shadow |

### System (nested under `"system"`)

| Key | Type | Default | Description |
|---|---|---|---|
| `pasteProtection` | toggle | `"off"` | Warn before pasting multiline content that may execute commands |
| `secureKeyboard` | toggle | `"on"` | Enable macOS Secure Keyboard Entry when PTY echo is disabled (password prompts) |
| `shellIntegration` | toggle | `"on"` | Install OSC 7/133 shell integration for prompt navigation and cwd tracking |
| `clipboardRead` | string | `"ask"` | OSC 52 clipboard read policy: `"ask"`, `"allow"`, or `"deny"` |
| `clipboardWrite` | string | `"allow"` | OSC 52 clipboard write policy: `"ask"`, `"allow"`, or `"deny"` |
| `bellStyle` | string | `"sound"` | Bell behavior: `"sound"`, `"visual"`, `"both"`, or `"none"` |

### Updates (nested under `"updates"`)

| Key | Type | Default | Description |
|---|---|---|---|
| `checkOnLaunch` | toggle | `"on"` | Check GitHub for new releases on app launch |
| `repository` | string | `"sebastianmiletic/termatica"` | GitHub repository for update checks |

### Plugins (nested under `"plugins"`)

Built-in helper-free plugins. Each uses an `"on"` or `"off"` toggle.

| Key | Default | Description |
|---|---|---|
| `hidden-path` | `"off"` | Replace the prompt with a short path indicator (`Coding/Project ;`) |
| `hyprland-layout` | `"off"` | Enable Hyprland-style terminal tiling |
| `unicode-rendering` | `"off"` | Full Unicode: wide glyphs, emoji, composed grapheme clusters |
| `osc-integration` | `"off"` | OSC 7 cwd, OSC 8 hyperlinks, OSC 133 command marks |
| `borderless-window` | `"off"` | Remove titlebar and traffic lights, keep rounded corners |
| `hello` | `"off"` | Example plugin |
| `pi-bridge` | `"off"` | Raspberry Pi bridge plugin |
| `editor-deck` | `"off"` | Editor deck plugin |
| `vim-control` | `"off"` | Vim control integration |
| `neovim-control` | `"off"` | Neovim control integration |
| `emacs-control` | `"off"` | Emacs control integration |
| `nano-control` | `"off"` | Nano control integration |
| `micro-control` | `"off"` | Micro control integration |
| `helix-control` | `"off"` | Helix control integration |

Horizontal and vertical split commands remain grouped under the root tab where they were created. Selecting an unrelated ordinary tab hides the complete prior split group. The rail keeps labels at a legible height in compact windows; scroll over it to reach tabs outside the visible subset. When Hyprland tiling is enabled, independent root tabs occupy pixel-aligned slots in a balanced grid, while Command-T and Command-Shift-T recursively split only the focused pane inside its root slot. Opening or closing roots rebalances the outer grid, and Command-drag exchanges terminals between slots without scaling their text.

### Tabs (nested under `"tabs"`)

| Key | Type | Default | Description |
|---|---|---|---|
| `railWidth` | integer | `34` | Tab rail width in points |
| `animations` | toggle | `"on"` | Enable tab and window animations |
| `animationSpeed` | float | `1.35` | Animation speed multiplier |
| `autoHide` | toggle | `"on"` | Auto-hide the tab rail after the configured delay |
| `hideDelay` | integer | `5` | Seconds before auto-hiding the tab rail |
| `tileGap` | integer | `10` | Gap between Hyprland tiles in points |
| `screenInset` | integer | `18` | Safe edge inset for adaptive windows and Hyprland tiles in points |
| `hyprlandBlur` | toggle | `"off"` | Enable blur for Hyprland tiles |
| `railMargin` | number | `8` | Outer tab-rail margin |
| `railCornerRadius` | number | `11` | Tab-rail corner radius |
| `buttonCornerRadius` | number | `8` | Tab-button corner radius |
| `buttonFontSize` | number | `11` | Tab-button font size |
| `buttonInset` | number | `4` | Tab-button inner inset |
| `minimumHeight` / `maximumHeight` | number | `20` / `28` | Tab-item height limits |
| `selectedOpacity` | float | `0.22` | Selected-tab fill opacity |
| `hoverOpacity` | float | `0.68` | Hover highlight opacity |
| `railOpacity` / `railBlurOpacity` | float | `0.96` / `0.26` | Solid and blurred rail opacity |
| `edgeOpacity` | float | `0.58` | Rail-edge separator opacity |
| `collapsedPeek` | number | `7` | Visible rail width while collapsed |

### Terminal UI (nested under `"terminalUI"`)

| Key | Type | Default | Description |
|---|---|---|---|
| `cursorThickness` | number | `2` | Bar and underline cursor thickness |
| `cursorBlockOpacity` / `cursorInactiveOpacity` | float | `0.42` / `0.20` | Active block and inactive cursor opacity |
| `scrollbarWidth` / `scrollbarMargin` | number | `2.5` / `5` | Scrollback indicator geometry |
| `scrollbarMinimumThumb` | number | `24` | Minimum scrollback-thumb height |
| `scrollbarOpacity` | float | `0.42` | Scrollback indicator opacity |
| `scanlineSpacing` / `scanlineThickness` | number | `4` / `1` | CRT scanline geometry |
| `vignetteLayers` | integer | `6` | Number of vignette edge layers |
| `searchWidth` / `searchHeight` | number | `340` / `28` | Search overlay dimensions |
| `searchCornerRadius` | number | `6` | Search overlay corner radius |

### Motion (nested under `"motion"`)

| Key | Type | Default | Description |
|---|---|---|---|
| `launchDuration` | seconds | `0.30` | Window launch animation |
| `terminalDuration` | seconds | `0.18` | New-terminal reveal animation |
| `layoutDuration` | seconds | `0.12` | Tab and tiling layout animation |

### Keybindings (nested under `"keybindings"`)

Every keybinding is configurable. Values use macOS notation: `cmd+shift+h`.

| Key | Default | Description |
|---|---|---|
| `openConfig` | `cmd+,` | Open the config UI |
| `newWindow` | `cmd+n` | New terminal window |
| `newTab` | `cmd+t` | Split only the focused pane vertically into side-by-side panes (compatibility key name) |
| `newVerticalTab` | `cmd+shift+t` | Split only the focused pane horizontally into stacked panes (compatibility key name) |
| `closeTab` | `cmd+w` | Close current tab |
| `clearTerminal` | `cmd+k` | Clear terminal and scrollback |
| `searchScrollback` | `cmd+shift+h` | Search scrollback (regex) |
| `previousPrompt` | `cmd+shift+p` | Jump to previous shell prompt (OSC 133) |
| `nextPrompt` | `cmd+option+p` | Jump to next shell prompt (OSC 133) |
| `reload` | `cmd+r` | Reload configuration |
| `copy` | `cmd+c` | Copy selection to clipboard |
| `paste` | `cmd+v` | Paste from clipboard |
| `selectAll` | `cmd+a` | Select all text |
| `splitHorizontal` | `cmd+d` | Split current pane horizontally |
| `splitVertical` | `cmd+shift+d` | Split current pane vertically |
| `nextSplit` | `cmd+]` | Focus next split |
| `previousSplit` | `cmd+[` | Focus previous split |
| `zoomIn` | `cmd+plus` | Increase font size |
| `zoomOut` | `cmd+-` | Decrease font size |
| `zoomReset` | `cmd+0` | Reset font size to default |

## Theme structure

Themes are JSON files in `~/.config/termatica/themes/` or the bundled `Resources/Themes/` directory. A theme looks like:

```json
{
  "background": "#101216",
  "foreground": "#D8DEE9",
  "cursor": "#EEF1F5",
  "accent": "#7AA2F7",
  "panel": "#151820",
  "muted": "#6B7280",
  "selection": "#2B3445",
  "appearance": {
    "backgroundOpacity": 0.28,
    "windowOpacity": 1,
    "blur": "off",
    "glow": 0,
    "scanlines": 0,
    "vignette": 0,
    "cursorStyle": "block",
    "renderer": "appkit"
  },
  "palette": ["#FF6B6B", "#7CE38B", "#67B7F7", "..."],
  "plainTextPalette": ["#7CE38B", "#7DD3FC", "#FFE083", "#FF8787", "#DDB2F4", "#67B7F7"]
}
```

The `colors` key in the selected config file overrides theme colors. Set `"palette": "theme"` to use the theme's palette, or provide a 16-element array for a custom ANSI palette.

## CLI

```sh
t c                    # Open config UI
t cf                   # Open the selected config file in editor
t cf path              # Print config file path
t r                    # Reload config
t u check              # Check for update
t u                    # Download and install update
t e <name> [files]     # Run terminal editor
t v                    # Print version
t h                    # Help
```

Public update builds use one certificate-backed macOS designated requirement.
The first build that moves from the older ad-hoc identity may require one final
privacy confirmation; later signed updates retain the same protected-folder
and service permissions. The updater also rejects a public ZIP unless it
matches that exact signing identity and the SHA-256 digest published by GitHub.

## Local automation

Use `termatica automation` (or `t a`) for request/reply control of windows,
tabs, splits, focus, commands, input, and named SSH launch recipes. The socket
is a user-owned, mode-`0600` local Unix datagram endpoint; there is no TCP
listener. AppleScript uses the same validated app-side implementation. See the
[complete automation guide](AUTOMATION.md), including the fresh-start and
privacy boundaries.
