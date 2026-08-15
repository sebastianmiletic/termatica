# Changelog

## 1.13.0

- Add `t sm` / `termatica system-monitor`, a compact live terminal monitor with CPU, load, memory pressure, storage, network rates, device details, uptime, battery state, and CPU- or memory-sorted processes.
- Complete Kitty keyboard progressive-enhancement handling for AI CLIs and TUIs: bounded main/alternate-screen mode stacks, set/add/remove modes, repeat and release events, shifted keys, associated text, and modifier-key events.
- Expand the real-PTY compatibility gate to installed Codex, Claude, Gemini, OpenCode, Pi, Nano, btop, and Yazi builds while continuing to report unavailable programs as skipped.
- Add `t ssh`, a terminal-native OpenSSH manager with secure saved profiles, config alias discovery, CRUD and JSON output, identities and fingerprints, ProxyJump, port forwarding, connection checks, and one-command split or multi-host tiled sessions.
- Add a complete SSH guide and expand the main product description around remote management, split tiling, AI/TUI workflows, monitoring, and the sub-2 MB universal app footprint.
- Keep ordinary tab creation and switching off the full-screen terminal layer,
  replacing center reveals and content slides with restrained tab-control motion.
- Remove the scaled rail fold/unfold effect and prevent hidden AppKit tabs from
  remaining temporarily layer-backed after opening a tab.

## 1.12.3

- Make each config's `.json` filename its authoritative identity and use a
  separate atomic selector for the current profile.
- Make create, select, rename, and delete operations deterministic, reject
  invalid JSON selections, and prevent values leaking between profiles.
- Reorganize `t c` into Appearance, Performance, Tabs & Tiling, Window,
  Terminal & Input, Motion, Extensions, Updates, and Keybindings.
- Keep long config and setting lists inside the visible terminal viewport.
- Reload repeated direct edits and profile switches by monitoring and re-arming
  the selector, profile directory, and selected file watchers.
- Migrate existing `config.json` installations to schema version 2 while
  preserving a compatibility link and user-only file permissions.

## 1.12.0

- Add `termatica renderer-campaign export` / `t rc export` to create a minimal,
  privacy-safe Phase 10 field report with a canonical SHA-256 integrity digest.
- Add `t rc aggregate` to validate, deduplicate, and combine observed reports
  across Apple Silicon, Intel, display, scale, refresh, hot-plug, and wake runs.
- Reject modified payloads, unsupported schemas, synthetic evidence sources,
  privacy violations, and repeated reports from the same ephemeral app session.
- Label integrity separately from authenticity: reports contain no persistent
  machine identifier and cannot automatically prove physical visual inspection.
- Keep AppKit as the default and require explicit operator review even when all
  automatically observable field categories have been collected.

## 1.11.0

- Add `termatica renderer-qualification` / `t rq` for a privacy-safe summary
  of observed Metal field evidence and every still-open rollout gate.
- Upgrade `t rr` to schema 4 with process architecture and translation state,
  display topology, refresh/scale diversity, wake events, pane display index,
  and per-reason presentation recovery counters.
- Keep field evidence current-session and observational: synthetic tests are
  never accepted as physical multi-display, hot-plug, wake, Intel, or visual
  proof, and AppKit remains the default while any gate is open.
- Add a Phase 9 release blocker covering screen/scale/wake recovery, preserved
  Unicode pane state, report privacy, qualification accounting, and rejection
  of synthetic proof.

## 1.10.0

- Add `termatica renderer-retry` / `t rt` for explicit in-place recovery of
  quarantined Metal panes without toggling config or resetting terminal state.
- Isolate retries per pane so a failed split cannot reconfigure or destabilize
  healthy Metal or AppKit panes.
- Upgrade `t rr` to schema 3 with aggregate renderer health, mismatch,
  quarantine, failure, retry-attempt, and successful-retry counters.
- Add a Phase 8 release blocker covering forced retry failure, subsequent
  recovery, three-pane isolation, preserved Unicode content, and aggregate
  report accounting.

## 1.9.0

- Quarantine a failed Metal renderer for the current session so display,
  backing-scale, visibility, and wake recovery cannot repeatedly retry Metal or
  replace the working AppKit fallback.
- Require an explicit AppKit-to-Metal reselection to retry after fallback while
  preserving terminal state and the selected configuration.
- Clear stale Metal layer content and restore AppKit layer policy during
  automatic fallback.
- Extend `t rr` to schema 2 with requested/actual renderer, quarantine, retry,
  failure-stage, failure-age, and bounded-recovery diagnostics.
- Add a Phase 7 release blocker covering initialization failure, runtime
  command failure, 96 quarantined lifecycle recoveries, explicit retry,
  preserved Unicode state, and rollout-policy reporting.
- Refresh the factual six-terminal benchmark table and retain Rio's measured
  startup win.

## 1.8.0

- Add `termatica renderer-report` / `t rr`, a privacy-safe JSON report for
  display, renderer, lifecycle-recovery, generation, and Metal-failure state.
  It excludes terminal text, paths, commands, environment, and shell details.
- Track presentation recovery reasons and Metal failure counts across display,
  backing-scale, occlusion, screen-wake, and system-wake paths.
- Add a Phase 6 release gate covering AppKit and Metal, 96 lifecycle
  recoveries, Unicode and graphemes, IME marked text, accessibility output,
  resizing, state preservation, scheduler bounds, and report privacy.
- Add prominent README download instructions and a fresh factual six-terminal
  benchmark table with raw artifacts. Rio's shell-ready win remains visible.

## 1.7.0

- Give exactly one terminal pane cursor ownership and invalidate both sides of
  every focus transition, fixing stale cursors left in other panes after
  Command-T, tab selection, or split focus changes.
- Reconfigure and redraw the selected renderer after display, backing-scale,
  occlusion, screen-wake, and system-wake transitions without resetting the
  PTY, terminal grid, scrollback, working directory, or active config.
- Add a renderer reliability gate covering AppKit and Metal, three visible
  panes, 240 rapid focus switches, 72 lifecycle recoveries, repeated resizes,
  font reloads, scheduler bounds, and preserved pane contents.
- Add real-PTY compatibility coverage for installed shells, editors, pagers,
  monitors, multiplexers, SSH tooling, Codex, and OpenCode, with unavailable
  programs reported as skipped rather than passed.
- Add a bounded Metal Unicode/image soak with a 256 MiB process-memory ceiling,
  32 MiB image-cache ceiling, monotonic generations, one pending snapshot, and
  at most two in-flight GPU frames.

## 1.6.0

- Metal presentation is paced by the active macOS display refresh signal while
  retaining immediate first-frame and resize/recovery redraws.
- The scheduler keeps one pending snapshot, coalesces stale generations, rejects
  non-monotonic generations, and bounds submitted GPU work to two frames.
- Metal diagnostics now separate snapshot wait, CPU encoding, GPU execution,
  GPU completion, and presentation interval measurements.
- The renderer stress gate covers a 1,000-snapshot burst, queue bounds,
  generation ordering, display-link delivery, and immediate resize recovery.
- `--benchmark-experience` now reports AppKit and Metal with matching viewport
  content, damage, warmup, and frame counts. Large JSON output is written with
  a complete-write loop so benchmark artifacts cannot be truncated at 4 KiB.
- The README now contains complete DMG, ZIP, Gatekeeper, checksum, version, and
  update instructions.

## 1.5.0

- Add `termatica benchmark` / `t b`, which measures an isolated offscreen terminal inside the running app with the active visual config and reports version, memory, parser/model throughput, and text/image paint FPS without closing existing sessions.
- Add CJK input-method composition, CSI intermediates, DECSCUSR cursor shapes, DECRQM mode reports, window-size queries, colon-form true color, OSC 4/104 palette handling, and stricter invalid UTF-8 replacement.
- Clear stale hyperlink metadata during destructive cell operations and reset underline style completely on SGR reset.
- Reuse AppKit style attributes and Metal image textures, retain animation frames without per-frame copies, and render transparent Kitty streams as real cached images.
- Consume pending wrap on explicit newline, clamp presented cursor coordinates to the grid, and ignore native selection clicks below the last visible terminal content while preserving application mouse reporting.
- Apply each named config's `fontName` to terminal text, IME composition, search controls, and native tab labels.
- Refresh the feature inventory and six-terminal measurements with explicit competitor wins and benchmark limitations.

## 1.4.2

- Start every newly created named config from the release benchmark defaults instead of cloning the active profile.
- Add reliable legacy Option-Left, Option-Right, and Option-Delete word editing while preserving enhanced keyboard protocols.
- Add repeatable, nanosecond-resolution software input-to-paint stage measurements and macOS process-attributed energy measurements.
- Keep unsupported OSC 6 payloads on a stateful discard path across fragmented PTY reads and increase transient read batches to improve long-escape throughput without increasing idle allocation.
- Publish refreshed six-terminal long-escape results, input-latency percentiles, stage timing, energy results, and memory methodology.

## 1.4.1

- Anchor every fresh shell prompt at the first row without disturbing later scrollback.
- Compile release binaries for throughput and prioritize the serialized parser during sustained PTY output.
- Rearrange every Hyprland tile, including quarter, half, horizontal, vertical, and mixed-size panes.
- Animate arbitrary slot swaps with a clear drag target and topology-safe split-tree updates.

## 1.4.0

- Made named configs independent and portable: every file is normalized to a complete versioned schema, the active file mirrors only the selected config, and switching no longer combines stale nested settings from different files.
- Fixed direct edits to `config.json` failing to persist back to the active named config, filename/name mismatches, incomplete default migration, and inconsistent file permissions.
- Fixed Metal glyph-cache collisions and resize-time atlas invalidation that could stall renderer fallback checks, increased atlas capacity, and retained explicit AppKit fallback coverage.
- Replaced mutable shared render masks with immutable cached data and removed unused snapshot storage and disabled legacy code.
- Hardened Core Graphics image allocation and animation-timer failure paths, and fixed undefined behavior when a pre-layout view produced negative grid space; the Clang static analyzer reports no source warnings and ASan/UBSan pass.
- Added config-isolation, partial-schema migration, permissions, complex-grapheme, and renderer-resize regression coverage.
- Made tag releases idempotent so rerunning a release uploads and replaces assets instead of failing when the GitHub release already exists.

## 1.3.3

- Removed all benchmarking code, the `bench` command, the `termyx engine bench` helper, and all related files. The app is back under 1 MiB.

## 1.3.2

- Fixed `termatica bench` closing the app but not running the benchmark. The helper is now launched in a new macOS Terminal window via `osascript` (instead of `open` which failed to execute the script). Also added a "Continue?" confirmation after the first-run helper install.

## 1.3.1

- Fixed `termatica bench` helper install failing on first run (the Application Support directory was not being created).

## 1.3.0

- Redesigned `termatica bench` (`t b`): on first run it offers to install a small helper tool called **termyx engine bench**. When you run a benchmark, Termatica closes and the helper opens in a separate macOS Terminal window and runs the full benchmark suite using your Termatica binary (9 throughput workloads: parser/render/scrollback × ASCII/Unicode/CSI-heavy), each with 1 warmup + 5 measured passes (median), then shows a results table comparing your Termatica numbers against the published six-terminal reference, and offers to reopen Termatica. No Dock bounce, no second app copy.
- The benchmark now uses the real running Termatica binary in-process via `--termyx-bench`.
- Removed more dead code (`TRunConfigBrowser`, `TDrawConfigBrowser`).

## 1.2.7

- Reworked `termatica bench` (`t b`) to run as a background utility process (no Dock icon, no bouncing, no spawning a second app copy). It uses the running Termatica binary in-process.
- The benchmark now runs one workload at a time with 1 warmup pass + 5 measured passes per workload, records the median, and prints progress for each pass (Parser → Render → Scrollback).
- It no longer reopens a new app copy at the end; it just returns you to your terminal after showing the results table.

## 1.2.6

- Fixed `termatica bench` (`t b`): it no longer quits the running app. The benchmark now runs in-process without closing terminal sessions, measures parser/render/scrollback throughput, shows the results table vs the six-terminal reference, and reopens the app on Enter.
- The terminal prompt now returns to the top of the window on every launch; the window is non-restorable so previous position is not saved.
- The app (Dock) icon is now the grey version, while the GitHub repository logo stays the black version.
- Rendering path verified intact (AppKit present + drawRect pipeline).

## 1.2.5

- Removed the bare default zsh prompt (`%`) and replaced it with a clean directory prompt (`<dir> ❯`) when the user has not customized their prompt.
- Reaffirmed all prior 1.2.x updates: in-terminal benchmark (`t b`), black rounded-corner icon, Option keybindings, dead code removal, and prompt anchoring to the top of the window.

## 1.2.4

- Added `termatica bench` (`t b`) to benchmark Termatica in-place. It warns that it will close open terminal sessions, runs parser, render, and scrollback throughput workloads, then displays a results table comparing your Termatica numbers against the published six-terminal reference (Kitty, Ghostty, Alacritty, WezTerm, Rio) and reopens the app.
- Reaffirmed the prompt anchoring to the top of the terminal window.

## 1.2.3

- Anchored the prompt to the top of the terminal window. Content no longer reserves the title-bar safe area as empty space, so the command line sits at the top where it belongs.
- Restored the black icon and GitHub repository logo (white wordmark on a black background) with rounded corners.
- Added Option (Alt) keybindings for word movement and editing in zsh and bash shell integration (Option+Left/Right, Option+Up/Down, Option+Home/End, Option+B/F/D/Backspace).
- Removed dead code: the unused `code` CLI, the `configs` CLI, and the module browser.

## 1.2.2

- Lightened the app icon and GitHub repository logo from pure black to a grey background so it reads as grey and white. Rounded corners are retained.

## 1.2.1

- Replaced the app icon and GitHub repository logo with a new rounded-corner Termatica wordmark. The Dock icon, `AppIcon.icns`, `AppIcon.png`, `AppIcon-1024.png`, `AppIcon-source.png`, and the embedded `AppIcon.svg` all use the new logo with rounded corners.

## Unreleased

- The interactive config now changes every setting with Left/Right arrows or Enter instead of opening typed-value prompts. Fonts, font features, colours, palettes, shells, shell arguments, renderer, bell behavior, update source, and all keybindings use validated choices; previously omitted runtime settings are now included.
- Added arrow-editable UI controls for window and tile corner radii, window dimensions and shadow, tab-rail and button geometry, UI opacities, cursor and scrollback-indicator geometry, scanline/vignette geometry, search-overlay sizing, and all launch/layout motion timings. The AppKit and Metal renderers consume the same terminal UI values.
- Escape now goes back everywhere Q does in the config and module terminal interfaces, while CSI and SS3 arrow keys remain fully supported.
- Completely removed terminal persistence and its helper integration. Every launch now creates one fresh blank terminal in a new default window, without restoring terminal output, processes, tabs, layouts, paths, cursors, or window state.
- Legacy `session.json` and saved screen data are deleted automatically, and the obsolete workspace-restore setting is removed from active and named configs.
- Config toggles now render as `ON`/`OFF` in `termatica config` and serialize as readable `"on"`/`"off"` strings instead of `0`, `1`, `true`, or `false`.
- Fixed primary and secondary device-attribute responses, with regression coverage.
- Added complete VT100 DEC G0/G1 special-graphics handling, including SI/SO selection, so line and symbol bytes render as the intended Unicode characters instead of literal letters or charset designators.
- Enabled native Finder file and folder drops on every terminal pane. Dropped paths are safely shell-quoted, multiple paths are space-separated, and bracketed-paste framing prevents supporting shells and TUIs from executing the drop unexpectedly.
- Paste confirmation remains disabled by default; existing installations can enable the optional unsafe-paste warning with `termatica config set system.pasteProtection on`.
- Fixed Codex inline-mode wheel scrolling opening the Ctrl-T transcript pager, which hid the composer bar and could leave the working-directory/header row displaced. Termatica now captures top-anchored partial-scroll-region output into native history and scrolls it locally while keeping Codex's live composer/status viewport pinned; regression coverage rejects all application input injection during these wheel gestures.

## 0.6.0

- Replaced boxed `NSMutableArray<NSData *>` scrollback with a flat `TCell*` ring of capacity `cols*scrollback`, eliminating per-line heap allocation during the initial ring fill and removing the chained `NSData` pointer chase from `lineAtVisibleIndex:` lookups.
- Added a precomputed 256-colour `_palette256[]` table populated at appearance-reload; `colorFor256:` and the 16/90-range SGR branches no longer call `TRGB(NSColor→sRGB→lrint)` per cell.
- Inlined a single damage mark per printable-ASCII run in `putASCIIBytes:` instead of one `markDamageX:y:width:height:` per byte, while preserving per-cell link attributes.
- Cached the row pointer across the ASCII batch so `cellsForRow:` is called once per line wrap instead of once per byte.
- Inlined `clearWideCellAtX` directly in `putASCIIBytes:` and `putCodepoint:` inner loops to eliminate per-byte method call overhead.
- Removed per-codepoint `markDamageX` in `putCodepoint:` and replaced it with cursor-range damage marks from `consumeDataRaw:`'s outer scope, cutting one `objc_direct` call per codepoint.
- Cached `_cachedUnicodeRendering` and `_cachedOscIntegration` as ivars set in `reloadAppearance`, eliminating per-codepoint `self.config` property-access overhead in the hot path.
- Made `handleControl:`, `handleEscape:`, `executeCSI:prefix:parameters:count:`, `finishOSC:`, and `cellsForRow:` all `objc_direct` to eliminate Obj-C message-send dispatch in the parser hot path.
- Replaced per-cell blank-fill loops in `scrollUp`, `reverseIndex`, `eraseDisplay`, `eraseLine`, `deleteCharacters`, and `insertCharacters` with `memcpy` from a pre-built `_historyBlankRow`, enabling NEON SIMD for whole-row fills.
- Raised the style attribute cache from 128 to 1024 entries with single-entry eviction, and cached the per-`(font, fontSize)` glyph advance so inner-loop attribute-cache misses no longer call `[@"M" sizeWithAttributes:]`.
- Switched `drawRect:` style-run string construction from `[[NSString alloc] initWithCharacters:length:]` to `CFStringCreateWithCharactersNoCopy` over the shared `_glyphScratch` buffer, eliminating one allocation per style run per frame.
- Made `refreshTextView` adaptive to the active screen's refresh rate via `NSScreen.maximumFramesPerSecond`, narrowing the dispatch_after coalescence window on 120 Hz ProMotion displays.
- Changed the decoder interface to take `const uint8_t *` + `NSUInteger` instead of `NSData *`, enabling future zero-copy drain.
- Added `ensureBlankRow` called from `reloadAppearance` to guarantee `_historyBlankRow` is allocated before any cell operations.
- Reset history on terminal column changes so the flat ring stays aligned to the live grid.
- Eliminated the hidden-path prompt flash on new Hyprland tabs/windows by sourcing `prompt.sh` from the shell integration scripts before the first prompt is displayed (via a one-time `precmd` hook), instead of injecting it as echoed keystrokes after the shell has already rendered its default prompt.
- Added a batch Unicode decode path to the terminal decoder that scans forward through consecutive multi-byte UTF-8 sequences, decodes codepoints inline with width detection, and dispatches a single `putCodepointRun:widths:count:` call per run instead of one block callback and one Obj-C method call per codepoint.
- Added warmup frames to the experience benchmark to eliminate first-frame cache misses, achieving zero 60 Hz overshoots and zero 120 Hz overshoots across the full 240-frame run.
- Increased the PTY read buffer from 32 KiB to 64 KiB.
- Updated the zsh and bash shell integration scripts to conditionally source `$TERM_HP` on the first precmd when `TERMATICA_HIDDEN_PATH=1` is set in the child environment.
- Set `TERMATICA_HIDDEN_PATH` environment variable in the child shell before `execv` when hidden-path is enabled, so the shell integration can apply it during startup without host-side keystroke injection.
- Bumped bundle version to 0.6.0 (build 19).
- On this M4 measurement host versus 0.5.1: ASCII parser throughput 12.6 → 126.9 MB/s (10.1×, now leads Kitty by 1.65× and Ghostty by 2.52×), Unicode parser 10.3 → 82.3 MB/s (8.0×), CSI-heavy parser 33.1 → 109.0 MB/s (3.29×, now leads Kitty by 2.55× and Ghostty by 3.51×), render-mode ASCII 12.1 → 103.2 MB/s (now leads Kitty by 1.35×), render-mode CSI-heavy 32.4 → 85.4 MB/s (now leads Kitty by 2.05×), core ASCII throughput 6.564 → 141.88 MiB/s (21.6×), core Unicode 6.567 → 104.53 MiB/s (15.9×, now exceeds Kitty's end-to-end Unicode parser), core CSI 8.861 → 67.64 MiB/s (7.6×), sustained throughput 10.82 → 137.44 MiB/s (12.7×), 60 Hz overshoot 1/240 → **0/240** (perfect), 120 Hz overshoot → **0/240** (perfect), idle physical footprint 33.3 → 35.8 MiB (3.4× smaller than Kitty, 10× smaller than Ghostty), bundle 850,708 → 851,747 bytes (193× smaller than Kitty, 76× smaller than Ghostty).

## 0.5.1

- Fixed wheel and trackpad scrolling inside Codex CLI and other alternate-screen applications that do not advertise DEC 1007 alternate-scroll; Termatica now sends alternate-screen navigation sequences whenever no application mouse mode is active, while Shift-wheel remains local scrollback.
- Routed every wheel and trackpad event through window-level terminal-frame hit testing, so normal and Hyprland panes scroll independently even below effect layers or hidden overlays.
- Increased precision-gesture sensitivity, flushes sub-line motion at gesture end, clamps momentum bursts, and forwards wheel buttons to mouse-aware TUIs such as Codex even when they remain on the primary screen; Shift-wheel always accesses local history.
- Added combined DEC private-mode handling plus legacy, UTF-8, SGR, urxvt, and SGR-pixel mouse coordinate encodings.
- Moved each terminal's parser and screen mutations onto an independent serial core queue, protected presentation snapshots from concurrent mutation, and added cell-bounded damage invalidation.
- Added safe workspace restoration for window geometry, terminal layout, active pane, and working directories without attempting to serialize live shell processes.
- Added automatic Zsh and Fish shell integration, Bash integration hooks, inherited working directories, OSC 133 prompt navigation, and OSC 10/11/12 color queries.
- Added permission-controlled OSC 52 clipboard access, unsafe multiline-paste confirmation, automatic macOS Secure Keyboard Entry while PTY echo is disabled, and terminal notifications.
- Improved composed-grapheme detection through Foundation's Unicode segmentation and enabled native ligature shaping and font fallback across complete style runs.
- Added an experience benchmark for offscreen scroll-paint duration, parse-to-paint duration, sustained-output stability, and process CPU time as a clearly labeled energy proxy.
- Fixed arrow keys in Codex and other Kitty-keyboard-aware TUIs by emitting enhanced functional-key sequences instead of private-use `CSI u` codes.
- Restored native terminal click behavior when a TUI requests mouse tracking: ordinary clicks now focus or begin text selection without forwarding a fake application click; Option-click remains available for explicit application mouse input.
- Fixed mouse-wheel and precision-trackpad scrollback, including momentum accumulation, visible position feedback, keyboard paging, and stable anchoring while new output arrives.
- Added alternate-screen save/restore, application cursor keys, focus reporting, alternate scrolling, SGR mouse reporting, autowrap control, and synchronized-output mode.
- Made terminal surfaces permanently layer-backed and accelerated output with printable-ASCII batching, reusable history lines, adaptive 8 ms refreshes, 32 KiB fair PTY slices, and performance-oriented LTO builds.
- Hardened control sockets, extension executable containment/ownership, extension output limits, updater download limits, SHA-256 parsing, and ZIP path/count/expanded-size validation.
- Added an internal terminal state self-test plus a reproducible Kitty/Ghostty benchmark suite covering parser throughput, rendering-enabled throughput, memory, startup, bundle size, and Termatica's core.
- Suppressed the numbered tab rail, hover target, and hidden edge arrow whenever Hyprland mode is enabled.
- Rebuilt the app-loading reveal as a clip-only transition on settled window geometry, removing glyph scaling, redraw overlap, and the competing pre-show Hyprland resize.
- Limited Hyprland new-tab motion to the entering terminal; existing tiles now adopt their new frames without replaying the entry animation.
- Added six points of top content spacing in borderless mode.
- Consolidated the config-file screen around one CURRENT row and removed the duplicate ACTIVE entry.
- Fixed borderless mode losing macOS key-window status, which left a live shell unable to receive typing or Enter.
- Added the bundled `t` command with compact `c`, `cf`, `u`, `r`, `e`, `x`, `h`, and `v` routes plus completions.
- Changed `termatica config` to open on the config-file manager before any settings categories.
- Enter now opens settings for the current config, makes a saved config current before opening it, or moves directly into a newly created config.
- Q from settings returns to the config-file manager, while Q from the file manager exits.

## 0.5.0

- Added `termatica update` and `termatica update check` backed by the public GitHub release API.
- Added SHA-256 release-asset verification, bundle identity/version validation, strict code-signature verification, staged installation, and rollback on replacement failure.
- Added an asynchronous launch update check with a macOS notification, Dock badge, and visible update title.
- Replaced the separate plugin, theme, config-profile, code, marketplace, and directory menus with one categorized `termatica config` terminal UI.
- Added terminal config-file management for creating, activating, renaming, and deleting named JSON configs.
- Added categorized controls for themes, text and ANSI colors, appearance, tab motion, plugins, shell/system behavior, updates, and every keybinding.
- Added `termatica config-file` for opening the authoritative JSON and `termatica config-file path` for scripts and coding agents.
- Added scriptable dot-path get/set and named-config actions plus complete Zsh, Bash, and Fish completions for the new command surface.
- Changed the tab rail to a true overlay so showing, hiding, or resizing it never changes terminal columns or moves prompt text.

## 0.4.2

- Made `config.json` the only settings surface: `termatica code` now opens or prints the authoritative file and no longer mutates appearance through a second UI.
- Expanded generated configs with every built-in plugin boolean, all installed theme choices, complete appearance/color inheritance keys, tabs, and keybindings.
- Added the helper-free Borderless Window plugin and migrated legacy `appearance.topBar` settings automatically.
- Added a native center-out reveal for app launch and new terminals, including Hyprland tiles.
- Removed session persistence. Every launch deletes legacy terminal snapshots and starts one fresh login shell while configs, themes, plugins, and named configs remain saved.

## 0.4.1

- Rounded the native blur mask around every Hyprland tile so internal corners remain visibly rounded across transparent gaps.
- Made `termatica completions install` activate Zsh completions directly, bypass stale completion caches, and preserve the shell's normal completion search paths.

## 0.4.0

- Added the helper-free Full Unicode plugin with combining-mark composition, emoji and ZWJ graphemes, regional-indicator flags, and double-width CJK rendering.
- Added the helper-free OSC Integration plugin with OSC 7 working directories, OSC 8 clickable links, and bounded OSC 133 command marks.
- Added negotiated Kitty keyboard protocol and xterm modifyOtherKeys support for reliable modified keys in modern terminal applications.
- Expanded `termatica code` with cursor color/style, foreground, ANSI palette, exact per-index ANSI colors, tile gap, animation speed, scrollback, and reset-to-default controls.
- Added complete generated Zsh, Bash, and Fish completions through `termatica completions`.
- Kept ordinary terminal text and the ANSI palette separate so themes and explicit color overrides remain predictable.

## 0.3.10

- Changed the Ghost Glass typing cursor from cyan to a high-contrast softly tinted white.
- Updated both the bundled and active user theme so the cursor change applies immediately.

## 0.3.9

- Restored normal terminal color semantics: ordinary text uses the theme foreground, while shells, editors, and CLI tools control color through the complete ANSI palette.
- Removed automatic per-word coloring from Ghost Glass; spectrum coloring is now an explicit opt-in rather than a theme side effect.
- Added `termatica code`, a keyboard-navigable terminal settings editor for text color mode, theme, font size, transparency, blur, and titlebar visibility.
- Added scriptable `termatica code` subcommands so users and coding agents can inspect and change the same settings directly.

## 0.3.8

- Added configurable full-spectrum coloring for ordinary terminal text, rather than limiting color to ANSI-styled output.
- Kept explicit ANSI foregrounds authoritative so CLI tools, editors, and syntax highlighting retain their intended colors.
- Enabled a balanced six-color plain-text palette in Ghost Glass and updated the active user theme immediately.
- Reused renderer scratch storage so the additional styling does not allocate per cell or add a second rendering pass.

## 0.3.7

- Lowered Ghost Glass background opacity from 0.50 to 0.28 while keeping terminal text at full opacity.
- Replaced its muted near-monochrome colors with 16 distinct full-spectrum ANSI and bright ANSI colors.
- Shifted the base foreground from near-white to a cool blue-gray, with blue accent and cyan cursor colors.
- Updated the user-installed Ghost Glass copy alongside the bundled theme so the change takes effect immediately.

## 0.3.6

- Fixed accumulated glyph-spacing drift in the batched renderer so the visual cursor remains directly beside the typed text at every prompt length and font size.
- Added a restrained compositor-only tab-rail fold that compresses into the edge handle as it disappears.
- Added the inverse unfold motion on reveal and a quick edge-handle scale-in, without resizing PTYs or repainting terminal contents.

## 0.3.5

- Fixed a global PTY drain starvation bug that could leave the third or later busy terminal permanently queued and unable to accept more output.
- Replaced per-cell NSString/CoreText painting with dirty-row, style-run batching and coalesced refreshes.
- Removed the shared Hyprland canvas, synchronous terminal snapshots, and its manual 60 FPS redraw path; every tile is now a live, independently rendered PTY view.
- Bounded main-thread parser slices to keep input, tab changes, and window events responsive under simultaneous high-output workloads.
- Made PTY input asynchronous, ordered, retrying, and lossless under nonblocking backpressure.
- Stabilized the tab overlay inset so tab-rail auto-hide no longer resizes PTYs or triggers avoidable full-screen TUI redraws.
- Tiled focus changes now update only focus and selection instead of rebuilding the complete tab layout.
- Verified eight simultaneous terminals in both normal and Hyprland modes with finite and unlimited output, including Ctrl-C recovery in every PTY.

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
