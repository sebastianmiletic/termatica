# Changelog

## 0.3.4

- Closed terminals now stop their shell and discard queued PTY output immediately, even when a rapid follow-up action interrupts the closing animation.
- Command-W on the final terminal removes it from the controller before the app exits, so it cannot be written back into the next session.
- Closing any terminal invalidates the previous restore snapshot at once; a crash before the next ordinary quit can no longer resurrect already-closed terminals.
- Hyprland tile motion now animates cached terminal snapshots instead of re-rendering every cell in every terminal at 60 FPS.
- Animation snapshots use bounded 1× buffers, and rapid bursts or layouts above six terminals switch directly to their final geometry instead of allocating repeated transient frames.
- Rapid tile actions cancel their previous transient animation state cleanly, preventing retained exit tiles and stale geometry.
- PTY read callbacks verify that their source is still live before queuing data, and the global fair-drain queue releases terminated terminals.

## 0.3.3

### Added

- Hidden Path plugin with a prompt that shows `;` at home/root and relative locations such as `Coding/OpenCloud ;` after `cd`.

### Changed

- Tiled keyboard input now goes directly to the active PTY without repeating focus/layout work or invalidating the complete shared canvas on every keypress.
- New and closed terminals rebuild the tab rail once instead of twice when entering or leaving tiled layout.
- Hidden Path runs natively without a persistent helper process and applies to existing shells after the plugin browser returns control.

### Fixed

- Clicking a Hyprland tile no longer transfers focus to its invisible backing terminal view.
- Rapid terminal creation no longer causes key events to stall behind redundant full-canvas redraws.
- Hidden Path activation clears its one-time integration line before presenting the shortened prompt.

## 0.3.2

### Added

- Command-Shift-T creates a focused vertical split directly below the active PTY, independently of the Hyprland plugin.
- Configurable `tabs.animationSpeed` with a faster 1.35 default.
- Direct Hyprland terminal rearrangement with Command-drag or top-padding drag.
- Live `GET`, `ON`, and `OFF` states in every terminal module browser.
- One-action plugin download, enable, and disable with immediate runtime reload.
- `disabledPlugins` configuration for immediate installed-plugin toggling.
- Theme-aware transparent titlebar plus `appearance.topBar` for a fully borderless terminal.
- Rounded borderless windows, reliable terminal focus, and configurable Hyprland screen-edge spacing.
- Independently focusable Hyprland tiles, theme-matched borders, and wider transparent gutters.
- Local socket command bridge for reliable, helper-free CLI-to-app actions.
- Bubble-pop tab creation, directional tab slides, and Hyprland-style terminal snapping.
- Persistent multi-action plugin and theme sessions.
- Minimal white lightning app icon.
- Terminal-native `termatica configs` browser and scriptable list, path, save, use, rename, and delete commands.
- Restart persistence for terminal layout, working directories, selected terminal, window frame, and bounded screen/scrollback text.
- Configurable five-second tab-rail auto-hide with an edge-hover reveal handle.

### Changed

- Ghost Glass uses a slightly clearer, stronger under-window blur while keeping text at full window opacity.
- Hidden Hyprland terminal views skip redundant AppKit redraws, terminal style caches are bounded more tightly, and screen text is generated only while VoiceOver is active.
- CLI control sockets are isolated by configuration directory, and ordinary reloads no longer rebuild an unchanged macOS menu.
- The app, build, README, and iconset now use one frameless white lightning-bolt mark.
- Marketplace and profile abstractions were removed; Skeleterm is now a direct low-memory mode.
- Native tab, hover, and focus transitions are shorter and use a snappier ease-out curve.
- Hyprland tiles now render through one shared canvas, keeping graphics memory essentially flat as terminals are added.
- Hyprland uses a lightweight no-blur compositor by default; optional tile blur is available with `tabs.hyprlandBlur`.
- The default transparent tile gap is 10 points and all tile corners are clipped to a clean 12-point radius.
- Default scrollback is 2,000 lines, and retained lines omit unused trailing cells.
- Hyprland creation, focus, and rearrangement use faster ease-out snapping without spring bounce.
- Blur is masked to terminal surfaces so the space between tiles stays fully transparent.
- Built-in plugins now register declaratively and no longer keep Python helper processes alive.
- Plugin and theme browsers are category-pure and use consistent GET/ON/OFF states.
- Default opaque windows skip the visual-effect compositor; blur surfaces exist only when enabled.
- Terminal history cells use 25% less memory, while color, text-attribute, and accessibility work is cached or throttled.
- Release builds use size-oriented optimization and dead-code stripping; icon assets use compact lossless palette encoding.
- Return and native plugin commands submit with a PTY-safe newline.
- PTY output is coalesced, backpressured at a fixed memory bound, and drained in UI-friendly slices.
- Busy PTYs now share one fair round-robin output scheduler, bounding host parsing work while keeping each terminal and keyboard path responsive.
- Full-screen terminal scrolling uses a constant-time circular screen and scrollback buffer.
- Hyprland output redraws are tile-local and frame-paced, while tile creation uses a continuous 60 Hz ease-out morph.
- Transparent-theme tab rails use a lighter glass fill, sit six points lower, and collapse automatically after inactivity.
- Hyprland tile creation and closure use a smoother geometry-and-opacity transition while survivor tiles reflow.

### Fixed

- Return and numeric-keypad Enter now send the standard terminal carriage return, including native plugin command submission.
- Shells that exit on their own now cancel their PTY reader and are reaped immediately instead of waiting for tab closure.
- Shared-canvas terminal text now uses the correct coordinate direction and remains fully interactive.
- Hyprland gutters are completely transparent and tiles have no double-painted contrast edge.
- Keyboard input returns to the selected live PTY when a tab control temporarily owns focus.
- Hyprland terminals, gutters, vignette edges, and the outer layout no longer draw borders.
- The native window shadow and root edge stroke are disabled in titlebar and no-titlebar modes.
- Closed tab shells are reaped asynchronously instead of remaining as zombie processes.
- Installed plugins now toggle instead of reinstalling, and newly installed plugins become active immediately.
- Hello, Pi Bridge, Editor Deck, and each focused editor control work without persistent plugin subprocesses.
- Command-K clears scrollback while retaining the active prompt and working-directory line.
- Command-Shift-T now splits the currently focused tile instead of attaching the new PTY to another column.
- Sustained output in several terminals no longer grows queued data without limit or starves keyboard input.

## 0.3.1

### Added

- Compact connected tab capsule that grows with the number of terminal sessions.
- Subtle tab hover and resize transitions using native AppKit animation.
- Color-enabled defaults for standard macOS terminal commands.

### Changed

- Tabs now float at the top-left instead of occupying the full window height.
- Command-K clears scrollback through the shell so the active prompt and path redraw correctly.
- The app icon now combines a lightning prompt, terminal frame, and multicolor command output.

## 0.3.0

### Added

- Terminal-native plugin, theme, and module browser.
- Direct `termatica install <id>` command.
- Terminal editor adapter for Vim, Neovim, Emacs, Nano, Micro, and Helix.
- Editor Deck plus focused editor-control plugins.
- Modified arrow keys, Shift-Tab, function keys, and expanded Control and Meta input.
- Minimal vertical numbered tabs with Command-T, Command-W, and Command-1 through Command-9.
- Skeleterm low-memory mode with short scrollback, effects disabled, and extension processes unloaded.
- Neutral `terminal-default` theme with the complete ANSI color palette.
- Configurable shortcuts and tab rail width.
- New lightning-terminal app icon.

### Changed

- Module browsers now support Up/Down, J/K, Enter, and Q navigation.
- CLI commands accept readable subcommands as well as legacy long flags.
- The PTY grid now occupies the complete window surface with no custom ribbon, status strip, header copy, or Command-K button.
- The default font size is 11 points, two points smaller than the previous default.
- Command-K now clears the terminal like a conventional terminal shortcut; extension commands run through `termatica run`.

### Fixed

- Editor Deck installation now produces the intended editor commands.
