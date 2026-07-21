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
  "scrollback": 5000,
  "theme": "terminal-default",
  "appearance": {
    "backgroundOpacity": 1.0,
    "windowOpacity": 1.0,
    "blur": false,
    "blurMaterial": "hud",
    "glow": 0,
    "scanlines": 0,
    "vignette": 0,
    "cursorStyle": "block"
  },
  "tabs": {
    "railWidth": 34
  },
  "keybindings": {
    "openConfig": "cmd+,",
    "newWindow": "cmd+n",
    "newTab": "cmd+t",
    "closeTab": "cmd+w",
    "clearTerminal": "cmd+k",
    "modules": "cmd+m",
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
| `tabs.railWidth` | 28–64 point numbered rail width; the rail is hidden with one tab. |

Appearance values:

| Field | Range/options |
|---|---|
| `backgroundOpacity` | 0.08–1.0 |
| `windowOpacity` | 0.20–1.0 |
| `blur` | `true` or `false` |
| `blurMaterial` | `hud`, `popover`, `sidebar`, or `menu` |
| `glow` | 0–1 |
| `scanlines` | 0–1; use 0 for a clean bitmap surface |
| `vignette` | 0–1 |
| `cursorStyle` | `block`, `bar`, or `underline` |

Configuration appearance values override the same values supplied by the selected theme. This lets you keep a theme’s colors but change its transparency or effects locally.

Each `keybindings` value uses modifiers joined with `+`, such as `cmd+k`, `cmd+shift+t`, or `control+space`. Set a value to an empty string to leave that menu action unbound. Tab selection defaults to `cmd+1` through `cmd+9` and can be overridden with `tab1` through `tab9`.

Every visible characteristic is file-controlled: font, font size, padding, theme colors, ANSI palette, transparency, blur, glow, scanlines, vignette, cursor, tab width, and menu shortcuts. Command-K clears the terminal by default; it does not open application UI.
