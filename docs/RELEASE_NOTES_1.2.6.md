# Termatica 1.2.6

## Benchmark fix

- `termatica bench` (`t b`) no longer quits the running app or closes terminal
  sessions. It runs parser, render, and scrollback throughput workloads
  in-process, shows a results table comparing your Termatica numbers to the
  published six-terminal reference (Kitty, Ghostty, Alacritty, WezTerm, Rio),
  and reopens the app when you press Enter.
- Removed the misleading "closes open sessions" warning; it now just measures
  and reopens.

## Layout

- The terminal prompt returns to the top of the window on every launch.
- The window is non-restorable, so macOS no longer saves its previous position
  or size across launches.

## Icons

- The app (Dock) icon is now the **grey** version (white wordmark on a grey
  rounded background).
- The GitHub repository logo (README) stays the **black** version.

## Rendering

- Verified the AppKit render pipeline (present handler → `setNeedsDisplayInRect`
  → `drawRect`) is intact.

## Scope

- Bundle under 1 MiB (1013.2 KiB). No theme changes.