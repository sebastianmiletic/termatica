# Termatica design system

## Product register

Termatica is a terminal, not an application dashboard. The shell owns the surface. App chrome appears only when it conveys terminal state that cannot live inside the PTY, and settings live in the readable config rather than a parallel GUI.

## Visual direction

- Native macOS rendering, compact geometry, neutral defaults, and standard ANSI semantics.
- One white lightning bolt is the product mark.
- Terminal output uses the selected theme foreground and ANSI palette; ordinary text is never arbitrarily recolored.
- Transparent themes preserve full-opacity text and keep gaps genuinely transparent.
- Borderless windows and Hyprland tiles use 14-point rounded corners with no contrasting outline or shadow.
- Numbered tabs are compact connected capsules, absent for one terminal, and automatically hidden after five seconds.
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
- App and terminal entry reveal from the center to the edges with a short 160–300 ms ease-out.
- Tabs use compact bubble/slide motion; Hyprland tiles snap directly between computed frames.
- No decorative bounce, long easing tail, or animation that delays keyboard focus.

## Interaction

- Command-K clears the terminal and leaves a fresh prompt.
- Command-T creates a terminal; Command-Shift-T splits below the focused terminal.
- Command-1 through Command-9 selects terminals.
- `termatica config` is the only interactive settings surface. It uses arrows or J/K, Enter for action, and Q to return or close.
- `termatica config-file` opens the single JSON source of truth for users, scripts, and coding agents.
- Themes, plugins, saved configs, system behavior, updates, and keybindings are categories inside the unified terminal UI rather than separate menus.

## Performance constraints

- No web view, JavaScript runtime, third-party UI framework, persistent animation loop, or helper process for native plugins.
- PTYs remain independent and responsive; rendering is invalidation-driven.
- A fresh launch creates one PTY and never restores closed terminal output or process state.
- The universal app bundle stays below the 1 MiB release gate.
