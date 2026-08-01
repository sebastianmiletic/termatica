# Termatica 1.4.1

Termatica 1.4.1 improves sustained terminal throughput and makes every Hyprland tile movable.

## Faster terminal workloads

- Release binaries now use throughput-oriented optimization instead of minimum-size optimization.
- The serialized parser queue now uses interactive quality of service, reducing scheduling stalls during sustained output without changing its bounded backpressure model.
- Fresh six-terminal measurements cover Unicode parsing, Unicode scrollback, image rendering, and long escape rendering.

## Arbitrary terminal movement

- Command-drag or drag from a tile's top padding to move any terminal.
- Quarter, half, horizontal, vertical, and mixed-size panes can exchange slots and adopt the destination size.
- Split relationships are rewritten without cycles, so moving a nested pane cannot corrupt the remaining layout.
- Non-dragged panes settle into place during the drag; the moved pane animates cleanly into its final size and position on release.

## Fresh prompt placement

- A newly opened app anchors its first integrated shell prompt at row zero after startup hooks finish.
- Later prompts and scrollback remain untouched.

The release remains a universal macOS 13+ application for Apple Silicon and Intel Macs, with AppKit rendering and an opt-in Metal backend.
