# Termatica 1.14.1

Termatica 1.14.1 fixes the Codex redraw corruption that could appear after
switching to another named config and then switching back.

Config mutations previously reached the running app through both the direct CLI
notification and the filesystem watcher. That caused two rapid renderer, font,
layout, and PTY-resize cycles for one saved change. Active configs are now
content-addressed: the first observation applies the change, while a second
observation of the same selected filename and SHA-256 content is skipped. A
manual `termatica reload` remains an explicit forced reload.

Terminal-native automation now includes `close pane`, `close tab`, and
`close window`. These operations stop the relevant PTYs and update the live
topology, but refuse to close the final terminal through unattended automation.

The release gate adds a deterministic real-PTY app-control campaign. It performs
hundreds of seeded window, tab, split, focus, resize, config, renderer, font,
input, and command actions. The campaign exercises installed Codex, tmux, SSH,
and Vim commands where available, plus Unicode, synchronized output, and
high-throughput terminal activity. It validates topology, active ownership,
split-anchor acyclicity, and visible render snapshots after every action.

The release remains a universal macOS 13+ application for Apple Silicon and
Intel. Public artifacts are ad-hoc signed rather than Developer ID notarized.
