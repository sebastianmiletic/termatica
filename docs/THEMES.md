# Themes

Themes are open JSON files. Termatica searches `~/.config/termatica/themes/` and its bundled themes; a user theme with the same filename takes precedence.

## Install a theme

1. Create `~/.config/termatica/themes/`.
2. Copy a theme such as `my-crt.json` into that folder.
3. Select `my-crt` in the Appearance section of `termatica config`, or set `"theme": "my-crt"` through `termatica config-file`.
4. Press Command-R if the change is not already visible.

The bundled starting points are `terminal-default`, `amber-crt`, `ghost-glass`, and `green-screen`. `terminal-default` is the neutral, opaque default with standard ANSI colors; the phosphor themes are optional.

## Theme format

```json
{
  "name": "Transparent Violet",
  "background": "#090611",
  "foreground": "#E2C8FF",
  "cursor": "#F2FAF8",
  "accent": "#C58CFF",
  "panel": "#100A1A",
  "muted": "#8B6AA8",
  "selection": "#44265F",
  "plainTextPalette": [
    "#8CCBFF", "#DDB2F4", "#82F0DD",
    "#9AF0A7", "#FFE083", "#FF8787"
  ],
  "appearance": {
    "backgroundOpacity": 0.50,
    "windowOpacity": 1,
    "blur": "on",
    "blurMaterial": "under-window",
    "hyprlandBlur": "on",
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

`plainTextPalette` is only used when the user explicitly selects `textColorMode: "spectrum"` in the selected config file. The default `ansi` mode keeps ordinary text on the single `foreground` color and lets shells, CLI tools, and editors choose colors through the normal ANSI palette.

User-level `colors.background`, `colors.foreground`, `colors.cursor`, `colors.accent`, `colors.panel`, `colors.muted`, `colors.selection`, and `colors.palette` values in the selected config file override those theme tokens without copying or editing the theme file. Use `"theme"` to inherit, a precise hex value for a color, or a complete 16-entry array for the ANSI palette.

`appearance.hyprlandBlur` lets a transparent theme request the shared masked blur surface when terminals are tiled. An explicit `tabs.hyprlandBlur` setting in the selected config file always wins.

## Transparency recipes

- Solid with the least compositor work: `backgroundOpacity: 1`, `windowOpacity: 1`, `blur: "off"`.
- Dark glass: `backgroundOpacity: 0.55`, `windowOpacity: 1`, `blur: "on"`, `blurMaterial: "hud"`.
- Ghost Glass: `backgroundOpacity: 0.28`, `windowOpacity: 1`, `blur: "on"`, `blurMaterial: "under-window"`, and no scanline overlay so block-art TUIs remain seamless.
- Stronger background separation: lower `backgroundOpacity`, keep `windowOpacity: 1`, and use `blurMaterial: "under-window"`.

macOS accessibility settings can reduce transparency system-wide. A theme should remain readable when blur is unavailable. Set `scanlines`, `glow`, and `vignette` to `0` for a clean pixel-terminal look.

The macOS titlebar uses the same window material and transparency as the terminal. Titlebar removal is intentionally not a theme token: enable Borderless window under Window in `termatica config` or set `plugins.borderless-window` in the selected config file. The window keeps rounded corners and remains resizable.

## Share themes

A theme has no executable code. Share the single JSON file, document any non-system font it expects, and include a screenshot. Do not bundle font files unless their license permits redistribution.
