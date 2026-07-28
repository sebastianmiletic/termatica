# Contributing to Termatica

## Build requirements

- macOS 13 or later
- Apple Command Line Tools (`xcode-select --install`)
- No external dependencies — pure Objective-C with AppKit and Metal

## Build and verify

```sh
git clone https://github.com/sebastianmiletic/termatica.git
cd termatica
make check      # builds both architectures, runs self-test
make benchmark  # reproducible Kitty/Ghostty comparison (needs all three apps)
make package    # produces DMG, ZIP, SHA256SUMS
```

## Code style

- Objective-C with ARC (`-fobjc-arc`)
- `-O3 -flto` for release builds
- Methods on the parser hot path use `__attribute__((objc_direct))` to bypass Obj-C runtime dispatch
- No comments in shipped code (per project convention)
- No external libraries — only system frameworks (AppKit, Foundation, QuartzCore, Carbon, Metal)
- Bundle must stay under 1 MB (`make size` enforces this via Makefile check)

## Architecture

```
src/
  TerminalCore.h    — TCell struct (12 bytes), decoder interface, Unicode width tables
  TerminalCore.m    — PTY→codepoint decoder with batch ASCII/Unicode fast paths, TWidthFast table-driven width
  main.m            — Everything else: grid, scrollback, rendering, PTY I/O, OSC, keybinding, images, search, window management
```

The decoder (`TerminalCore.m`) is platform-independent C/Objective-C. The rendering, windowing, and PTY I/O (`main.m`) use Apple frameworks.

## Key constraints

- **1 MB bundle size cap** — enforced by `make release`
- **12-byte cells** — `_Static_assert(sizeof(TCell)==12)`
- **Zero persistent helper processes** — all built-in plugins run declaratively
- **Plain JSON config** — must remain user- and AI-readable

## Pull requests

1. Fork the repo
2. Create a feature branch
3. Run `make check` — all tests must pass
4. Run `make size` — bundle must be under 1 MB
5. Open a PR with a clear description of what changed and why

## Reporting issues

Include:
- macOS version and architecture
- Termatica version (`t v` or `termatica version`)
- Steps to reproduce
- Expected vs actual behavior
