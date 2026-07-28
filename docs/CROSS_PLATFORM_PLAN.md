# Cross-Platform Port Plan: Linux and Windows

## Current architecture

Termatica is a macOS-native terminal written in Objective-C with AppKit. The rendering, windowing, PTY, clipboard, font, and update subsystems are tightly coupled to Apple frameworks:

| Subsystem | Current (macOS) | Linux equivalent | Windows equivalent |
|---|---|---|---|
| Window management | AppKit `NSWindow` | GTK4 / Qt6 / X11+Wayland | Win32 `HWND` |
| Rendering | `NSView drawRect:` + CoreText | Cairo/Pango or GTK4 snapshot | Direct2D/DirectWrite or GDI |
| PTY | `forkpty()` | `forkpty()` / `openpty()` | ConPTY (`CreatePseudoConsole`) |
| Event loop | `NSApplication` run loop | GLib MainContext / epoll | Win32 message pump |
| Font rendering | CoreText / NSFont | Pango + HarfBuzz + FreeType | DirectWrite |
| Clipboard | `NSPasteboard` | wl-clipboard / X11 selections | Win32 clipboard API |
| Notifications | `UNUserNotificationCenter` | dbus/freedesktop notifications | Windows toast notifications |
| Code signing | codesign + notarytool | GPG / no equivalent | Authenticode |
| Updates | GitHub API + staged replace | Same | Same |

## Effort estimate

Each port is approximately **3,000-5,000 lines** of new platform code plus a platform abstraction layer (PAL) of **500-1,000 lines** extracted from the current 1,932-line `main.m`.

- **Linux (ARM64 + x86_64)**: ~2-3 weeks. The main challenge is replacing CoreText with Pango/HarfBuzz for glyph rendering, and replacing AppKit with GTK4 for window management. The PTY layer maps almost 1:1.
- **Windows (x86_64 + ARM64)**: ~4-6 weeks. ConPTY has a different API surface from `forkpty`. DirectWrite is a significant departure from CoreText. The window management is fundamentally different (HWND-based vs. NSWindow).

## Recommended approach

### Phase 1: Platform Abstraction Layer
Extract platform-independent code (parser, screen model, scrollback, OSC handling, config) into a `core` directory. The current `TerminalCore.h`/`.m` already isolates the decoder; extend this pattern to the screen model, history ring, and color pipeline.

```
src/
  core/           # Platform-independent
    decoder.c      # (existing TerminalCore.m)
    screen.c       # Grid, history ring, damage
    osc.c          # OSC 7/8/10/11/12/52/133
    config.c       # JSON config parsing
    benchmark.c    # Core benchmarks
  platform/
    macos/         # Current AppKit code
      main.m       # NSView, NSWindow, CoreText rendering
    linux/         # Future GTK4 port
      main.c       # GTK4 window, Cairo/Pango rendering
    windows/       # Future Win32 port
      main.c       # HWND, Direct2D/DirectWrite
```

### Phase 2: Linux port
1. Create `platform/linux/` with GTK4 window and Cairo rendering
2. Use Pango for font shaping and glyph layout
3. Reuse `forkpty()` for PTY (nearly identical to macOS)
4. Replace `NSPasteboard` with wl-clipboard/X11 selections
5. Build with meson or cmake; produce .deb, .rpm, .AppImage

### Phase 3: Windows port
1. Create `platform/windows/` with Win32 window class
2. Use ConPTY (`CreatePseudoConsole`) for PTY
3. Use DirectWrite for font shaping and glyph rendering
4. Build with MSVC or clang-cl; produce .msi or portable .zip
5. Replace update mechanism with Windows-specific staged replace

### Phase 4: CI for all platforms
- macOS: existing GitHub Actions workflow
- Linux: containerized build per distro (Ubuntu, Fedora, Arch)
- Windows: Windows runner with MSVC

## What does NOT need porting
- The decoder (`TerminalCore.m`) — pure C, works everywhere
- The config system — JSON-based, platform-independent
- The CLI — already a separate binary, needs only path adjustments
- The benchmark suite — runs against the core abstraction
- The shell integration scripts — zsh/bash/fish are cross-platform

## Timeline
- Phase 1 (PAL extraction): 3-5 days
- Phase 2 (Linux): 2-3 weeks
- Phase 3 (Windows): 4-6 weeks
- Phase 4 (CI): 2-3 days

Total: approximately 2-3 months of focused development.

## Alternative: GPU-first rewrite
Instead of porting the AppKit rendering layer, build a Metal/Vulkan/Direct3D rendering backend from scratch with a shared GPU shader. This is the approach Kitty (OpenGL) and Ghostty (Metal) use. It would be more work but would achieve GPU-accelerated rendering on all platforms simultaneously.

Estimated effort: 4-6 months for a full GPU rewrite with cross-platform backends.
