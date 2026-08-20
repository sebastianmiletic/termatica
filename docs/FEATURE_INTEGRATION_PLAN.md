# Feature Integration Plan

> Historical planning snapshot. Many items below were subsequently implemented,
> so its `Current` statements and estimates must not be used as the present
> feature inventory. See [FEATURES.md](FEATURES.md) for the current factual
> comparison and [BENCHMARKS.md](BENCHMARKS.md) for current measurements.

This document preserves the original implementation plan for engineering
history. It is not a current parity claim.

## Priority tiers

- **P0 — Performance** (closes the remaining benchmark gaps)
- **P1 — Protocol completeness** (feature parity for TUI applications)
- **P2 — User features** (quality-of-life improvements)
- **P3 — Platform** (cross-platform support)

---

## P0: Performance

### P0-1: GPU rendering (Metal)

**Current**: CPU CoreText via `[NSString drawAtPoint:withAttributes:]` in `drawRect:` on the main thread.
**Target**: `CAMetalLayer` with a dedicated render thread.

**Approach**:
1. Add `CAMetalLayer` as the view's backing layer instead of the default `CALayer`
2. Create a `MTLRenderPipelineState` with a shader that reads cell data from a vertex buffer and glyphs from a texture atlas
3. Build a glyph atlas: pre-rasterize each (codepoint, font, attrs) combination to a `MTLTexture`, with LRU eviction
4. Move rendering to a dedicated serial dispatch queue that reads a snapshot of the visible grid
5. Drive frame timing with `CVDisplayLink` for vsync-accurate presentation

**Files to change**: `src/main.m` (new `TRenderer` class, modified `TTerminalView`), new `shaders.metal`
**Estimated effort**: 2-3 weeks
**Impact**: Eliminates the Unicode render gap (57.9 → target 100+ MB/s), fixes the render-mode throughput gap

### P0-2: Dedicated render thread

**Current**: Rendering in `drawRect:` on the main thread, parser on `_parseQueue`.
**Target**: Three-thread model: parse queue, render thread, main thread (input/UI).

**Approach**:
1. After parsing, publish a `TScreenSnapshot` (copy of visible cells + damage rect) under the grid lock
2. Wake the render thread via `dispatch_semaphore`
3. Render thread reads the snapshot and draws without holding any parser lock
4. Main thread handles only input events and window management

**Files to change**: `src/main.m`
**Estimated effort**: 3-5 days (standalone), or free if done as part of P0-1

### P0-3: Glyph texture atlas

**Current**: CoreText re-rasterizes glyphs on every `[NSString drawAtPoint:]` call.
**Target**: Pre-rasterized glyph cache keyed by (codepoint, font, size, style flags).

**Approach**:
1. Create a `NSMutableDictionary<NSNumber *, CGImageRef>` keyed by `(codepoint << 8) | flags`
2. On first render of a new (codepoint, attrs), rasterize via `CTFontGetGlyphsForCharacters` + `CTFontCreatePathForGlyph` to a `CGContext`, store the `CGImage`
3. On subsequent renders, blit the cached `CGImage` via `CGContextDrawImage` (CPU path) or use as a `MTLTexture` (GPU path)
4. LRU evict at 8192 entries

**Files to change**: `src/main.m`
**Estimated effort**: 1 week (CPU path), or free with P0-1 (GPU path)

### P0-4: Zero-copy PTY drain

**Current**: Each 65K chunk is copied into an `NSData` object before parsing.
**Target**: Parse directly from the `_pendingData` buffer.

**Approach**:
1. In `drainPendingData`, capture a pointer into `_pendingData.bytes` and pass it to `consumeDataRaw:` without creating an `NSData`
2. The `@synchronized(self)` lock in `consumeDataRaw` already prevents the read handler from modifying `_pendingData`
3. Move compaction to after the parse completes

**Files to change**: `src/main.m` (drainPendingData, consumeDataRaw)
**Estimated effort**: 1 day (requires careful lock-safety testing)
**Impact**: Closes the gap between core Unicode (106.4) and end-to-end (93.4)

---

## P1: Protocol completeness

### P1-1: DCS dispatch (Sixel, Kitty graphics, DCS passthrough)

**Current**: `ESC P` falls through to `escape(byte)` which ignores `P`.
**Target**: Full DCS state machine supporting Sixel and Kitty graphics protocol.

**Approach**:
1. Add `TDecodeDCS` state to `TerminalCore.m` decoder, entered on `ESC P` / `ESC X`
2. Accumulate DCS body until `ST` (ESC \) or `BEL`
3. Dispatch to handlers: `dcsHandler(intermediate, body)`
4. Implement Sixel parser: parse `!`, `"`, `#`, `?` Sixel commands, build an image buffer, render to a `CGImage` / `MTLTexture`
5. Implement Kitty graphics protocol: parse `APC G ... ST` commands, base64-decode image data, create texture
6. Store images in a per-cell or per-position image map, composite during render

**Files to change**: `src/TerminalCore.h` and `.m` (DCS state), `src/main.m` (Sixel/graphics handlers, image cache, render compositing)
**Estimated effort**: 1-2 weeks (Sixel: ~4 days, Kitty graphics: ~5 days)
**Impact**: Enables `chafa`, `img2sixel`, `timg`, image previews in `lf`/`ranger`

### P1-2: Full kitty keyboard protocol

**Current**: Flags 0/1/8 only. No REP, no progressive enhancement flags 2/4/16.
**Target**: Complete CSI > u / CSI ? u protocol.

**Approach**:
1. In `executeCSI:prefix:parameters:count:`, extend the `>u` handler to accept flags 0-31
2. Add `CSI Pn b` (REP — repeat last character) to the CSI switch
3. In `keyDown:`, emit full kitty keyboard sequences when `_kittyKeyboardFlags & 1`
4. Handle progressive enhancement: flag 2 (report all keys), flag 4 (report text), flag 16 (alternate key encoding)

**Files to change**: `src/main.m` (executeCSI, keyDown)
**Estimated effort**: 1 day

### P1-3: BSU/ESU synchronized output

**Current**: DECSET 2026 on/off only. Flush triggers only when 2026 is disabled.
**Target**: Full BSU/ESU via DCS flush.

**Approach**:
1. On DCS flush command (`DCS bsu ST`), call `refreshTextView` immediately
2. On DCS ESU begin, set `_synchronizedUpdates=YES`; on ESU end, set `NO` and flush
3. Combine with existing DECSET 2026 handling

**Files to change**: `src/main.m` (finishOSC, refreshTextView)
**Estimated effort**: 1 day (requires P1-1 DCS dispatch)

### P1-4: Font feature settings

**Current**: `NSLigatureAttributeName:@1` (binary on/off), no per-feature control.
**Target**: User-configurable font features (`calt`, `ss01`, `liga`, etc.)

**Approach**:
1. Add `fontFeatures` array to config (`"fontFeatures": ["calt", "ss01"]`)
2. In `reloadAppearance`, create a `CTFontDescriptorRef` with `kCTFontFeatureSettingsAttribute` from the config array
3. Create `_font`, `_boldFont`, `_italicFont` via `CTFontCreateWithFontDescriptor` instead of `NSFont fontWithName:`
4. Apply ligature toggle by adding/removing `liga` from the features array

**Files to change**: `src/main.m` (TConfig, reloadAppearance, textAttributesForForeground)
**Estimated effort**: 2-3 days

### P1-5: Per-cell link index (OSC 8 optimization)

**Current**: `_linksByCell` is an `NSMutableDictionary` keyed by boxed `NSNumber` per cell.
**Target**: `uint8_t` link index per cell, stored in cell flags or a side array.

**Approach**:
1. Add `uint8_t *_linkIndex` array of size `rows*cols`
2. Add `NSMutableArray<NSString *> *_linkURLs` for URL storage
3. In `putASCIIBytes`/`putCodepoint`/`putCodepointRun`, set `_linkIndex[y*cols+x]` to the current link index instead of dict operations
4. In `drawRect`, check `_linkIndex[y*cols+x]` instead of dict lookup
5. In OSC 8 handler, push/pop link URLs into `_linkURLs` and return the index

**Files to change**: `src/main.m`
**Estimated effort**: 1 day

---

## P2: User features

### P2-1: Scrollback search

**Current**: No search.
**Target**: `Ctrl+Shift+H` opens a search overlay.

**Approach**:
1. Add a search bar overlay (NSTextField at the top of the terminal view)
2. On search, linear-scan the history ring + visible grid for matches
3. Highlight matched cells, navigate with up/down
4. Regex support via `NSRegularExpression`

**Files to change**: `src/main.m` (new search overlay view, keybinding, search logic)
**Estimated effort**: 2-3 days

### P2-2: Per-tab title

**Current**: OSC 0/2 sets all tabs.
**Target**: Per-tab title tracking.

**Approach**:
1. Store `_tabTitle` per `TTerminalView`
2. On OSC 0/2, set the terminal's own title instead of the window title
3. In `TWindowController`, display the active terminal's title in the tab bar

**Files to change**: `src/main.m` (finishOSC, tab bar rendering)
**Estimated effort**: 1 day

### P2-3: Config file watching (hot reload)

**Current**: Manual `t r` reload.
**Target**: Automatic reload on `config.json` change.

**Approach**:
1. Use `dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, ...)` on the config file
2. On `VNODE_ATTRIB_REVOKE` or `VNODE_ATTRIB_WRITE`, trigger `reloadConfig` after a 500ms debounce

**Files to change**: `src/main.m` (TApplication)
**Estimated effort**: 1 day

### P2-4: Custom bell (visual + sound)

**Current**: `NSBeep()` only.
**Target**: Configurable visual bell and/or custom sound.

**Approach**:
1. Add `bellStyle` config: `"none"`, `"visual"`, `"sound"`, `"both"`
2. On BEL (control 7), if visual: flash the terminal border for 200ms via `CABasicAnimation`
3. If sound: play configured sound file or `NSBeep()`

**Files to change**: `src/main.m` (handleControl, config)
**Estimated effort**: 1 day

### P2-5: Remote control protocol

**Current**: CLI socket only (`t` commands).
**Target**: Full IPC protocol for programmatic control.

**Approach**:
1. Extend the existing CLI socket to accept JSON commands
2. Define protocol: `{"action":"newTab","cwd":"/tmp"}`, `{"action":"sendText","text":"ls\n"}`, etc.
3. Document the protocol in `docs/REMOTE_CONTROL.md`

**Files to change**: `src/main.m` (CLI listener), new `docs/REMOTE_CONTROL.md`
**Estimated effort**: 1 week

### P2-6: Window splits beyond Hyprland (completed in 1.13.4)

Horizontal, vertical, and mixed-direction splits now work in ordinary mode.
Each ordinary tab owns an independent pane group, `Cmd+]` / `Cmd+[` cycles
inside the visible group, and selecting another ordinary tab hides the complete
previous group without changing its PTYs or layout.

### P2-7: Notarized builds

**Current**: Ad-hoc signed.
**Target**: Notarized with Developer ID.

**Approach**:
1. Obtain Apple Developer ID ($99/year)
2. In `.github/workflows/ci.yml`, add `codesign --deep --options runtime --sign "Developer ID Application: ..."` 
3. Run `xcrun notarytool submit` with app-specific password
4. Staple with `xcrun stapler staple`

**Files to change**: `.github/workflows/ci.yml`, `Makefile` (package target)
**Estimated effort**: 1 day setup (plus $99/year)

---

## P3: Platform

### P3-1: Linux port (ARM64 + x86_64)

See `docs/CROSS_PLATFORM_PLAN.md` for the full plan.

**Approach**:
1. Phase 1: Extract platform-independent code (decoder, screen model, OSC, config) into `src/core/`
2. Phase 2: GTK4 window + Cairo/Pango rendering in `platform/linux/`
3. Build with meson; produce .deb, .rpm, .AppImage

**Estimated effort**: 2-3 weeks

### P3-2: Windows port (x86_64 + ARM64)

**Approach**:
1. ConPTY (`CreatePseudoConsole`) for PTY
2. Direct2D/DirectWrite for rendering
3. Win32 `HWND` for windows
4. Build with MSVC or clang-cl; produce .msi

**Estimated effort**: 4-6 weeks

---

## Implementation order

```
Sprint 1 (1 week): P0-4 (zero-copy drain) + P1-2 (kitty keyboard) + P1-5 (link index)
Sprint 2 (1 week): P1-3 (BSU/ESU) + P1-4 (font features) + P2-3 (config watch) + P2-4 (bell)
Sprint 3 (2 weeks): P0-2 (render thread) + P0-3 (glyph atlas)
Sprint 4 (2-3 weeks): P0-1 (Metal renderer) + P1-1 (DCS/Sixel/graphics)
Sprint 5 (1 week): P2-1 (search) + P2-2 (tab titles) + P2-6 (window splits)
Sprint 6 (1 week): P2-5 (remote control) + P2-7 (notarization)
Sprint 7 (2-3 weeks): P3-1 (Linux)
Sprint 8 (4-6 weeks): P3-2 (Windows)
```

Total: approximately 3-4 months to reach full parity with Kitty and Ghostty, with GPU rendering, graphics protocols, and cross-platform support.
