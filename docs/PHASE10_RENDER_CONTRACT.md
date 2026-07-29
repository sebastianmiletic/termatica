# Phase 10 render contract

Phase 10 replaces only the consumer of `TRenderSnapshot`. It must not change
the decoder, PTY queue, terminal model ownership, or snapshot producer while
the renderer is being introduced.

## Ownership

- `TTerminalView` is the sole owner of mutable terminal state.
- `renderSnapshot` copies the visible cells and renderer metadata while holding
  the existing model lock.
- A renderer may retain a snapshot until presentation completes.
- A renderer must never retain pointers into the live grid, history, underline,
  hyperlink, or PTY buffers.
- Rendering occurs without holding the model lock.

The interface is declared in `src/TerminalCore.h` as `TRenderSnapshot`,
`TRenderMetrics`, and `TRenderBackend`.

## Backend lifecycle

1. Configure a backend with the current metrics.
2. Present immutable snapshots in generation order.
3. Invalidate backend caches after font, scale, or theme changes.
4. Shut the backend down before releasing its view or graphics device.

AppKit remains the complete fallback. Metal starts opt-in and may become the
automatic backend only after pixel parity, terminal regression, memory, bundle,
and sustained-output tests pass. Metal initialization, shader, drawable,
device, or command-buffer failure must switch back to AppKit without dropping
terminal output.

## Prohibited designs

- Separate locks that allow a renderer to read the grid while parsing mutates it.
- Zero-copy pointers into mutable `NSMutableData` or terminal cell storage.
- A Metal backend that changes parser scheduling, PTY backpressure, escape
  handling, scrollback, or screen-model behavior.
- Default-on Metal before the AppKit/Metal parity and soak gates pass.

## Acceptance

- `make check` passes with both the AppKit backend and Metal available.
- ASCII, Unicode, graphemes, wide cells, style runs, cursor variants,
  selection/search, hyperlinks, Sixel, Kitty graphics, and iTerm2 images match
  the AppKit reference.
- Closing, resizing, splitting, restoring sessions, and switching renderers do
  not crash, deadlock, corrupt cells, or lose output.
- The final app remains below 40 MiB idle physical footprint and 1 MiB bundle
  size.
