# Termatica feature and gap inventory

This inventory separates implemented Termatica behavior from capabilities that
other terminals provide. Performance results are reported separately in
[Terminal benchmarks](BENCHMARKS.md).

## Implemented in Termatica

- Native macOS PTY terminal with AppKit rendering and an optional Metal backend
  that falls back to AppKit on renderer failure and redraws state after display,
  backing-scale, occlusion, and wake transitions.
- ANSI 16/256/true color, colon-form true color, Unicode wide cells and
  grapheme clusters, CJK input-method composition, DEC special graphics,
  alternate screen, scrolling regions, cursor styles, and palette queries.
- Bracketed paste, focus reporting, synchronized output, Kitty keyboard,
  modifyOtherKeys, application cursor keys, and legacy/UTF-8/SGR/urxvt/pixel
  mouse encodings.
- OSC 7 working directory, OSC 8 hyperlinks, OSC 10/11/12 color queries,
  permission-controlled OSC 52 clipboard access, OSC 133 shell marks, and
  DECRQM/window-size query responses used by modern TUIs.
- Sixel, Kitty graphics, and iTerm2 inline-image input, including tested Kitty
  transmit/query/delete and placement behavior.
- Scrollback, search, prompt navigation, numbered terminals, native splits,
  optional Hyprland-style tiling, JSON themes/configuration, named configs,
  shell integration, and a local control socket.
- Password-free SSH profile management backed by the system OpenSSH client,
  including config-alias discovery, identities, fingerprints, ProxyJump,
  forwarding, connection checks, and multi-host split/tile launch commands.
- Single cursor ownership across tabs and visible splits, including immediate
  invalidation of the previously focused pane after Command-T or focus changes.
- A non-destructive `t benchmark` command that measures the running app with
  its active visual config and reports version, memory, throughput, and
  offscreen paint FPS.
- A privacy-safe `t renderer-report` command that reports display geometry,
  requested and actual renderer, recovery counts, generations, Metal failure
  stage/age, quarantine state, and explicit retry policy without terminal text,
  paths, commands, environment, or shell details.
- A factual `t renderer-qualification` summary of current-session architecture,
  display topology, scale/refresh diversity, wake and transition evidence, and
  open rollout gates. Synthetic test events cannot satisfy physical field gates.
- Phase 10 field-campaign export and aggregation with minimal evidence payloads,
  canonical SHA-256 tamper detection, ephemeral-session duplicate rejection,
  no persistent machine identifier, and explicit human-review boundaries.
- Session-local Metal failure quarantine: automatic AppKit fallback remains
  stable across lifecycle recovery. `t renderer-retry` retries only quarantined
  Metal panes in place, preserves terminal state, and leaves healthy panes
  untouched.

## Capabilities other terminals have that Termatica does not

| Product | Capability absent or materially narrower in Termatica | Evidence |
|---|---|---|
| Kitty | Seven managed layouts, session files, event-driven Python watchers, encrypted remote control over a network, arbitrary copy/paste buffers, per-Unicode-range font selection, and mature kitten extensions | [Kitty overview](https://sw.kovidgoyal.net/kitty/overview/) |
| Ghostty | Native tabs/splits, Quick Terminal, AppleScript control of windows/tabs/splits/input, Quick Look, proxy icons, automatic system light/dark theme switching, and native window-state recovery | [Ghostty features](https://ghostty.org/docs/features/), [AppleScript](https://ghostty.org/docs/features/applescript) |
| WezTerm | Local/SSH/TLS multiplexer domains, reconnectable remote sessions, remote panes/tabs, Lua automation, pane introspection, SSH-config discovery, and predictive local echo for high-latency multiplexed sessions | [WezTerm multiplexing](https://wezterm.org/multiplexing.html), [Pane API](https://wezterm.org/config/lua/pane/index.html) |
| macOS Terminal | Window groups, profile import/export, marks and named bookmarks, AppleScript automation, configurable legacy character encodings, East Asian ambiguous-width policy, and system-native profile management | [Apple profiles](https://support.apple.com/guide/terminal/profiles-change-terminal-windows-trml107/mac), [marks and bookmarks](https://support.apple.com/guide/terminal/trml135fbc26/mac), [advanced settings](https://support.apple.com/guide/terminal/change-profiles-advanced-settings-trmladvn/mac) |
| Alacritty | Cross-platform macOS/Linux/BSD/Windows availability and a deliberately smaller feature surface maintained as a mature standalone project | [Alacritty project](https://github.com/alacritty/alacritty) |
| Rio | Cross-platform macOS/Linux/Windows/WebAssembly availability and its own native navigation model | [Rio project](https://github.com/raphamorim/rio) |

## Current Termatica boundaries

- macOS 13 or later only; no Linux, Windows, BSD, or web build.
- Public builds are ad-hoc signed, not Apple-notarized.
- SSH sessions use the system OpenSSH client; there is no proprietary SSH/TLS
  multiplexer, reconnectable remote domain, serial terminal, or predictive
  local echo.
- No Kitty-style session files/watchers/network remote control or WezTerm-style
  Lua object model.
- No Ghostty Quick Terminal, AppleScript dictionary, Quick Look integration,
  proxy icon, or native window restoration.
- No macOS Terminal window groups, named output bookmarks, or non-UTF-8 encoding
  selection.
- Font fallback is delegated to CoreText; there is no user mapping from Unicode
  ranges to specific fallback fonts.
- Bidirectional and right-to-left terminal layout is not claimed.
- VT compatibility is covered by implemented sequence tests, not by a claim of
  complete xterm or every-application conformance. Programs can emit private or
  future protocols that are outside the tested set.

## Compatibility evidence

`make check` exercises incremental/chunked decoding, invalid UTF-8 replacement,
Unicode graphemes, DEC line drawing, colon true color, cursor styles, DECRQM,
window-size queries, OSC palettes, CJK IME commit, synchronized output,
Codex-style inline scrolling, Kitty and legacy keyboard input, mouse modes,
Sixel/iTerm2/Kitty images, real Metal pixel variation, resize behavior, cursor
ownership across three panes, lifecycle recovery, scheduler/cache bounds, and
automatic AppKit fallback. A separate real-PTY gate exercises installed shells,
editors, pagers, monitors, tmux, SSH tooling, Codex, Claude, Gemini, OpenCode,
Pi, Nano, btop, and Yazi and reports missing applications instead of treating
them as passed. Passing these checks
supports the listed behaviors; it is not a guarantee that every current or
future CLI is defect-free.
