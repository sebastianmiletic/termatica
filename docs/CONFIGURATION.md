# Configuration

Termatica reads `~/.config/termatica/config.json`. Press Command-, to create/open it and Command-R to reload it.

## Complete example

```json
{
  "shell": "/bin/zsh",
  "shellArguments": ["-l"],
  "fontName": "Monaco",
  "fontSize": 13,
  "padding": 12,
  "scrollback": 5000,
  "theme": "amber-crt",
  "appearance": {
    "backgroundOpacity": 0.91,
    "windowOpacity": 1.0,
    "blur": true,
    "blurMaterial": "hud",
    "glow": 0.16,
    "scanlines": 0.08,
    "vignette": 0.12,
    "cursorStyle": "block"
  },
  "keybindings": {
    "commandPalette": "cmd+k",
    "copy": "cmd+c",
    "paste": "cmd+v"
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

Keybinding names are reserved by the v1 format. The current app uses the standard macOS menu shortcuts shown in the README; full remapping is planned for a later core revision.
