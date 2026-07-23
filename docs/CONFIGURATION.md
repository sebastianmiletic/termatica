# Configuration

Termatica reads `~/.config/termatica/config.json`. Press Command-, to create/open it and Command-R to reload it.

## Complete example

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
    "blurMaterial": "hud",
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

## Fields

| Field | Meaning |
|---|---|
| `shell` | Absolute path to the shell executable. |
| `shellArguments` | Arguments passed when the PTY starts; `-l` creates a login shell. |
| `fontName` | Any installed fixed-width font, including pixel fonts you install in macOS. Falls back to the system monospace font. |
| `fontSize` | 8–48 points. |
| `padding` | 0–40 points inside the terminal canvas. |
| `scrollback` | 100–100000 retained lines. |
| `theme` | Installed theme filename without `.json`, or an inline theme object. |
| `skeleterm` | Enables the direct low-memory mode. It selects the terminal-default theme, limits scrollback, disables visual effects, and unloads extensions. |
| `disabledPlugins` | Installed plugin identifiers to keep off. The module browser maintains this list. |
| `tabs.railWidth` | 28–64 point numbered rail width; the rail is hidden with one tab. |
| `tabs.animations` | Enables short native bubble, slide, and tile-snap transitions. No background animation loop is used. |
| `tabs.animationSpeed` | 0.25–4 speed multiplier for every native tab and hover transition. The faster default is `1.35`. |
| `tabs.autoHide` | Shows the numbered rail after a tab is opened, closed, selected, or rearranged, then collapses it to an edge arrow. Hovering the arrow or rail area reveals it again. |
| `tabs.hideDelay` | 1–30 seconds before the revealed tab rail collapses. The default is 5. |
| `tabs.tileGap` | 0–24 point fully transparent, border-free gap between terminals while Hyprland Layout is enabled. |
| `tabs.screenInset` | 8–80 point buffer between a maximized Hyprland window and the usable screen edges. |
| `tabs.hyprlandBlur` | Explicitly enables or disables the single masked blur surface in Hyprland Layout. Ghost Glass requests it by default; set this field to `false` for the lowest transient peak. |
| `session.restore` | Saves and restores the window frame, terminal layout, selected terminal, working directories, and bounded screen/scrollback text on a normal app exit. |
| `session.maxLines` | 100–10000 text lines kept per terminal in `session.json`; the default is 2,000. |

Appearance values:

| Field | Range/options |
|---|---|
| `backgroundOpacity` | 0.08–1.0 |
| `windowOpacity` | 0.20–1.0 |
| `blur` | `true` or `false` |
| `topBar` | `true` keeps the transparent, theme-backed macOS titlebar and traffic lights; `false` removes both while preserving rounded window corners. Neither mode draws an outer border or window shadow. |
| `blurMaterial` | `hud`, `popover`, `sidebar`, `menu`, or the stronger background-focused `under-window` material |
| `glow` | 0–1 |
| `scanlines` | 0–1; use 0 for a clean bitmap surface |
| `vignette` | 0–1 |
| `cursorStyle` | `block`, `bar`, or `underline` |

Configuration appearance values override the same values supplied by the selected theme. This lets you keep a theme’s colors but change its transparency or effects locally.

Each `keybindings` value uses modifiers joined with `+`, such as `cmd+k`, `cmd+shift+t`, or `control+space`. `newVerticalTab` splits the focused terminal downward independently of the Hyprland plugin. Set a value to an empty string to leave that menu action unbound. Tab selection defaults to `cmd+1` through `cmd+9` and can be overridden with `tab1` through `tab9`.

Every visible characteristic is file-controlled: font, font size, padding, theme colors, ANSI palette, transparency, blur, titlebar, glow, scanlines, vignette, cursor, tab width, tab motion, tile spacing, and menu shortcuts. The visible titlebar shares the same window material, opacity, and blur as the terminal. Command-K clears the terminal by default; it does not open application UI.

## Files and saved configurations

The installed app keeps user state outside its signed bundle:

- `~/.config/termatica/config.json` — active, editable configuration
- `~/.config/termatica/configs/*.json` — named configurations
- `~/.config/termatica/session.json` — bounded terminal-layout and text snapshot
- `~/.config/termatica/themes` and `extensions` — downloaded modules

All files are plain JSON or source-readable extension files, so users and coding agents can edit them directly. `termatica config-path` prints the active file and `termatica configs path` prints the profile folder. `TERMATICA_CONFIG_DIR=/some/folder` redirects every one of these files for portable setups or automation.

Prompt integrations are plugins rather than themes. Hidden Path stores its readable Zsh/Bash integration at `extensions/hidden-path/prompt.sh`; the module browser maintains its enabled state through `disabledPlugins`.

Open `termatica configs` to manage named configurations without leaving the terminal. The browser uses Up/Down or J/K, Enter, S, R, D, and Q. Direct subcommands are documented in [the CLI reference](CLI.md).

Session restoration intentionally starts fresh login shells and replays only saved terminal text. It cannot preserve the in-memory state of a running editor, AI CLI, or other child process.

In Hyprland Layout, Command-drag a terminal surface or drag from its top padding to rearrange live terminal sessions. Ordinary dragging inside terminal content remains text selection. Command-Shift-T creates a new PTY directly beneath the focused terminal, including outside Hyprland Layout. Every visible PTY is rendered into one shared rounded canvas, so adding tiles does not allocate another full-window graphics surface. The 10-point default gutters are cleared to full transparency, and tiles have no contrasting border. Set `tabs.hyprlandBlur` to `true` only when you specifically want the more expensive per-tile blur effect.
