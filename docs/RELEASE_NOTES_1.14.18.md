# Termatica 1.14.18

Termatica 1.14.18 replaces the Intel cursor rendering path and introduces recursive Command-T tiling.

## Intel cursor isolation

- On Intel, the AppKit renderer no longer paints the cursor into terminal text or a retained tile backing store.
- The live cursor is a dedicated, pixel-aligned overlay attached only to the focused terminal.
- Moving or blinking the cursor updates that single overlay instead of leaving bars before and after the hidden-path semicolon.
- Creating, focusing, moving, and closing tiles cannot copy an old cursor into another terminal surface.
- Apple Silicon and Metal rendering retain their existing cursor paths.

## Command-T Hyprland tiling

- Command-T is now the only terminal-creation shortcut.
- In Hyprland mode, the first press splits the focused terminal vertically and focuses the new right pane.
- Later presses split the newly focused pane locally, alternating horizontal and vertical directions.
- Outside Hyprland mode, Command-T continues to create an ordinary tab.

## Compatibility

The release remains a universal macOS app with native x86_64 and arm64 slices. The regression suite includes a forced Intel-overlay run that exercises hidden-path cursor movement, repeated focus transfers, blinking, and tiled terminals.
