# Termatica 1.14.11

Termatica 1.14.11 keeps every tiled terminal on the same configured color and
opacity, including transparent and blurred layouts.

## Uniform tile appearance

- A single window-owned rounded surface now provides the configured background
  for every visible tile.
- AppKit and Metal panes render terminal content above that shared surface
  instead of independently compositing translucent default backgrounds.
- Active, inactive, busy, idle, nested, moved, resized, and renderer-fallback
  panes therefore resolve to the same background RGBA value.
- Ordinary non-tiled tabs retain their configured background behavior.

## Verification

The terminal regression suite builds a nested three-pane layout at 37%
background opacity and verifies the shared surface color and alpha, transparent
pane backgrounds, focus stability, and non-opaque tile declaration. The full
release gate also covers AppKit/Metal parity, renderer switching and recovery,
wide-cell and block rendering, dense Hyprland layouts, mouse and keyboard input,
monitor changes, automation, packaging, signing, and updater validation.
