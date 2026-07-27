# Termatica design system

## Product register

Termatica is a terminal, not an application dashboard. The shell owns the surface. App chrome appears only when it conveys terminal state that cannot live inside the PTY, and settings live in the readable config rather than a parallel GUI.

## Visual direction

- Native macOS rendering, compact geometry, neutral defaults, and standard ANSI semantics.
- One white lightning bolt is the product mark.
- Terminal output uses the selected theme foreground and ANSI palette; ordinary text is never arbitrarily recolored.
- Transparent themes preserve full-opacity text and keep gaps genuinely transparent.
- Borderless windows and Hyprland tiles use 14-point rounded corners with no contrasting outline or shadow.
- Borderless terminals add a small six-point top inset so the first prompt does not touch the window edge.
- Numbered tabs are compact connected capsules, absent for one terminal, automatically hidden after five seconds, and completely suppressed in Hyprland mode where the tiles already communicate terminal state.
- The tab rail overlays the canvas and never changes terminal columns, prompt position, or PTY dimensions.

## Typography

- Default terminal face: Monaco, 11 pt.
- The user may choose any installed fixed-width font and an 8–48 pt size in `config.json`.
- UI overlays use the same terminal-minded hierarchy and never compete with PTY content.

## Color and themes

- `terminal-default` is the neutral baseline.
- Themes own background, foreground, cursor, accent, panel, muted, selection, ANSI palette, and optional effects.
- Config values use `theme` to inherit or an explicit value to override.
- Plugin state and window mode never live inside a theme.

## Motion

- Motion uses Core Animation only, has no continuous frame loop, and scales with `tabs.animationSpeed`.
- App and terminal entry use a clip-only center-to-edge reveal with a short 160–300 ms ease-out. The window frame settles before launch motion begins, and glyph layers are never scaled or faded. Adding a Hyprland tile animates only the new terminal; existing tiles settle immediately into their new frames.
- Tabs use compact bubble/slide motion; Hyprland tiles snap directly between computed frames.
- No decorative bounce, long easing tail, or animation that delays keyboard focus.

## Interaction

- Command-K clears the terminal and leaves a fresh prompt.
- Mouse wheels and precision trackpads scroll history with native momentum; Shift-Page Up/Down pages and Shift-Home/End jumps between oldest and live output.
- Window-level frame hit testing routes every wheel gesture to the pane under the pointer, including split and Hyprland layouts; transparent gaps and overlay/effect views never become implicit scroll targets.
- A child that enables terminal mouse tracking owns unmodified wheel gestures on both primary and alternate screens. Shift-wheel is the explicit local-scrollback override. Clicks remain native unless Option is held.
- Scrollback remains anchored when background output arrives, returns to live output when typing, and exposes a minimal position thumb without permanent chrome.
- Ordinary clicks only focus or begin native text selection. Application mouse coordinates require an explicit Option-click so mouse-aware TUIs cannot unexpectedly reposition their own cursor.
- Command-T creates a terminal; Command-Shift-T splits below the focused terminal.
- Command-1 through Command-9 selects terminals.
- `termatica config` is the only interactive settings surface. It uses arrows or J/K, Enter for action, and Q to return or close.
- Config Files is the entry screen. Config selection and lifecycle actions happen before the categorized settings screen.
- `termatica config-file` opens the single JSON source of truth for users, scripts, and coding agents.
- Themes, plugins, saved configs, system behavior, updates, and keybindings are categories inside the unified terminal UI rather than separate menus.

## Performance constraints

- No web view, JavaScript runtime, third-party UI framework, persistent animation loop, or helper process for native plugins.
- PTYs remain independent and responsive; rendering is layer-backed, cell-damage-driven, dirty-row/run-batched, and coalesced to an 8 ms active refresh window.
- Each terminal parses and mutates its locked screen model on an independent serial core queue. Printable ASCII is batched, screen/history storage is circular and reused, and PTY drains use bounded 32 KiB slices with backpressure.
- Performance claims must include a repeatable workload and raw output; asynchronous parser acknowledgment is never labeled as visual rendering latency.
- Workspace restoration recreates window geometry, terminal layout, active pane, and working directories. It never serializes output, credentials, or live process state.
- The universal app bundle stays below the 1 MiB release gate.
