# Termatica 1.14.16

Termatica 1.14.16 makes fresh installations match the maintained Termatica setup and corrects oversized icons on Intel Macs.

## Maintained defaults

- Fresh installations and newly created configs use Ghost Glass with SF Mono 11, AppKit rendering, HUD blur, 90% window opacity, and 60,000 lines of scrollback.
- Hyprland layout, hidden path, full Unicode rendering, OSC integration, and the borderless window are enabled by default.
- Enabled built-in integrations install automatically on first launch, so the complete configured experience is available immediately.
- Shell, input, motion, tab, window, terminal UI, update, color, and keybinding settings match the maintained daily-use profile.

## Correctly sized Intel Mac icon

- Every 16, 32, 64, 128, 256, 512, and 1024 pixel ICNS representation now keeps the artwork inside Apple's standard 824-pixel design area.
- Transparent optical padding is baked into the raster assets instead of relying on newer system masking behavior, keeping the icon consistently sized in legacy Intel Dock and Finder renderers.
