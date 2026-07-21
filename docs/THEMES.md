# Themes

Themes are open JSON files. Termatica searches bundled themes first and then `~/.config/termatica/themes/`; a user theme with the same filename takes precedence.

## Install a theme

1. Create `~/.config/termatica/themes/`.
2. Copy a theme such as `my-crt.json` into that folder.
3. Set `"theme": "my-crt"` in `~/.config/termatica/config.json`, or run `termatica themes` and choose it with the arrow keys and Enter.
4. Press Command-R if the change is not already visible.

The bundled starting points are `terminal-default`, `amber-crt`, `ghost-glass`, and `green-screen`. `terminal-default` is the neutral, opaque default with standard ANSI colors; the phosphor themes are optional.

## Theme format

```json
{
  "name": "Transparent Violet",
  "background": "#090611",
  "foreground": "#E2C8FF",
  "cursor": "#FFFFFF",
  "accent": "#C58CFF",
  "panel": "#100A1A",
  "muted": "#8B6AA8",
  "selection": "#44265F",
  "appearance": {
    "backgroundOpacity": 0.52,
    "windowOpacity": 0.96,
    "blur": true,
    "blurMaterial": "popover",
    "glow": 0.08,
    "scanlines": 0.02,
    "vignette": 0.08,
    "cursorStyle": "bar"
  },
  "palette": [
    "#0B0810", "#E06C75", "#98C379", "#E5C07B",
    "#61AFEF", "#C678DD", "#56B6C2", "#D7D2C9",
    "#5C5852", "#F07B84", "#A8D389", "#F2CD88",
    "#79BDF2", "#D58BE5", "#6CCAD3", "#F1EDE6"
  ]
}
```

Colors use `#RRGGBB` or `#RRGGBBAA`. `palette` contains the standard 8 ANSI colors followed by their 8 bright variants.

## Transparency recipes

- Solid and fastest: `backgroundOpacity: 1`, `windowOpacity: 1`, `blur: false`.
- Dark glass: `backgroundOpacity: 0.55`, `windowOpacity: 1`, `blur: true`, `blurMaterial: "hud"`.
- Nearly invisible: lower `backgroundOpacity`, keep foreground contrast high, and use `blurMaterial: "popover"`.

macOS accessibility settings can reduce transparency system-wide. A theme should remain readable when blur is unavailable. Set `scanlines`, `glow`, and `vignette` to `0` for a clean pixel-terminal look.

## Share themes

A theme has no executable code. Share the single JSON file, document any non-system font it expects, and include a screenshot. Do not bundle font files unless their license permits redistribution.
