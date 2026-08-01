# Termatica Features

## Performance

| Feature | Termatica | Kitty | Ghostty |
|---|:---:|:---:|:---:|
| Metal GPU rendering | Phase 10 | ✅ OpenGL | ✅ Metal |
| Immutable render snapshot | ✅ | ✅ | ✅ |
| AppKit fallback renderer | ✅ | — | — |
| GPU image compositing | Phase 10 | ✅ | ✅ |
| GPU cursor rendering | Phase 10 | ✅ | ✅ |
| Zero-frame overshoot (60Hz) | ✅ 0/240 | — | — |
| Zero-frame overshoot (120Hz) | ✅ 0/240 | — | — |
| Zero-frame overshoot (240Hz) | ✅ 0/240 | — | — |
| ASCII viewport paint p50 | 1.49ms | — | — |
| Under 40MiB memory | ✅ 30.2MiB | ❌ 120.7MiB | ❌ 86.5MiB |
| Compact universal bundle | ✅ 1,144KiB | ❌ 160,080KiB | ❌ 63,484KiB |

## Terminal protocols

| Protocol | Termatica | Kitty | Ghostty |
|---|:---:|:---:|:---:|
| ANSI 16/256/truecolor | ✅ | ✅ | ✅ |
| UTF-8 + Unicode | ✅ | ✅ | ✅ |
| Wide characters (CJK) | ✅ | ✅ | ✅ |
| Grapheme clusters (emoji ZWJ) | ✅ | ✅ | ✅ |
| Bracketed paste | ✅ | ✅ | ✅ |
| Synchronized output (DECSET 2026) | ✅ | ✅ | ✅ |
| BSU/ESU (DCS flush) | ✅ | ✅ | ✅ |
| DCS dispatch (ESC P/X/^/_) | ✅ | ✅ | ✅ |
| Alternate screen (1049/47/1047) | ✅ | ✅ | ✅ |
| Auto-wrap (DECAWM) | ✅ | ✅ | ✅ |
| Focus events (1004) | ✅ | ✅ | ✅ |
| Cursor visibility (25) | ✅ | ✅ | ✅ |
| Application cursor keys (1) | ✅ | ✅ | ✅ |
| ModifyOtherKeys | ✅ | ✅ | ✅ |
| Kitty keyboard protocol (flags 0-31) | ✅ | ✅ | ✅ |
| REP (CSI Pn b) | ✅ | ✅ | ✅ |
| Mouse: legacy/UTF-8/SGR/urxvt/pixel | ✅ | ✅ | ✅ |

## Image protocols

| Feature | Termatica | Kitty | Ghostty |
|---|:---:|:---:|:---:|
| Sixel images | ✅ RGB+HLS | ✅ | ✅ |
| Sixel scaling | ✅ | ✅ | ✅ |
| Sixel alpha compositing | ✅ | ✅ | ✅ |
| Sixel repeat (!n) | ✅ | ✅ | ✅ |
| Sixel color registers (1024) | ✅ | ✅ | ✅ |
| Kitty graphics protocol | ✅ | ✅ | ✅ |
| Image query (a=q) | ✅ | ✅ | ✅ |
| Image delete (a=d) | ✅ | ✅ | ✅ |
| Placement offset (x=, y=) | ✅ | ✅ | ✅ |
| Cell placement (c=, r=) | ✅ | ✅ | ✅ |
| Destination size (w=, h=) | ✅ | ✅ | ✅ |
| Image ID (i=) | ✅ | ✅ | ✅ |
| GIF animation | ✅ per-frame | ✅ per-frame | ✅ per-frame |
| Virtual placements (U=1) | ✅ | ✅ | ❌ |
| Transmission type (t=) | ✅ f/d | ✅ | ✅ |
| iTerm2 inline images | ✅ OSC 1337 | ✅ | ✅ |

## Shell integration

| Feature | Termatica | Kitty | Ghostty |
|---|:---:|:---:|:---:|
| Zsh integration | ✅ | ✅ | ✅ |
| Bash integration | ✅ | ✅ | ✅ |
| Fish integration | ✅ | ✅ | ✅ |
| OSC 7 (cwd reporting) | ✅ | ✅ | ✅ |
| OSC 8 (hyperlinks) | ✅ | ✅ | ✅ |
| OSC 10/11/12 (color query) | ✅ | ✅ | ✅ |
| OSC 52 (clipboard) | ✅ | ✅ | ✅ |
| OSC 133 (prompt marks) | ✅ | ✅ | ✅ |
| Prompt navigation | ✅ | ✅ | ✅ |
| Inherited working directories | ✅ | ✅ | ✅ |

## User features

| Feature | Termatica | Kitty | Ghostty |
|---|:---:|:---:|:---:|
| Scrollback search | ✅ regex+counter | ✅ | ✅ |
| Case-sensitive search toggle | ✅ | ✅ | ✅ |
| Window splits | ✅ Cmd+D/Cmd+Shift+D | ✅ | ❌ |
| Split navigation | ✅ Cmd+]/Cmd+[ | ✅ | ❌ |
| Hyprland tiling | ✅ | ❌ | ❌ |
| Arbitrary mixed-size tile movement | ✅ animated slot swap | ❌ | ❌ |
| Hidden-path mode | ✅ | ❌ | ❌ |
| Config UI (in-terminal) | ✅ `t c` | ❌ | ✅ GTK |
| Config file hot-reload | ✅ VNODE watch | ✅ | ✅ |
| Font feature settings | ✅ liga/calt/ss01/ss02/zero | ✅ | ✅ |
| Visual bell | ✅ sound/visual/both/none | ✅ | ✅ |
| Remote control IPC | ✅ JSON socket | ✅ `kitten @` | ❌ |
| Auto-update (secure) | ✅ SHA256+codesign | ✅ | ❌ |
| Auto-update notification | ✅ Install Now button | ❌ | ❌ |
| Fresh top-row shell on launch | ✅ | ✅ | ✅ |
| Themes | ✅ JSON | ✅ importable | ✅ importable |
| Tab bar | ✅ overlay rail | ✅ | ✅ |
| Numbered tabs | ✅ Cmd+1-9 | ✅ | ✅ |
| Borderless window | ✅ plugin | ✅ | ✅ |
| CLI tool | ✅ `termatica`/`t` | ✅ `kitten` | ❌ |
| Shell completions | ✅ zsh/bash/fish | ✅ | ❌ |
| Secure Keyboard Entry | ✅ | ❌ | ❌ |
| Unsafe-paste protection | ✅ (off by default) | ❌ | ❌ |

## Platform

| Feature | Termatica | Kitty | Ghostty |
|---|:---:|:---:|:---:|
| macOS Apple Silicon | ✅ | ✅ | ✅ |
| macOS Intel | ✅ | ✅ | ✅ |
| Linux | ❌ (planned) | ✅ | ✅ |
| Windows | ❌ | ❌ | ❌ |
| Notarized builds | ❌ (planned) | ✅ | ✅ |
| Homebrew | ✅ tap | ✅ | ✅ |
| Universal binary | ✅ | ✅ | ✅ |
