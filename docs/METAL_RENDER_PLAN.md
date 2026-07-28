# Metal Renderer + Render Thread + Glyph Atlas + Zero-Copy Drain
## Single-Prompt Implementation Plan

This document describes the complete plan for implementing four architectural improvements in one focused work session. Each is described at the code level with exact files, functions, and approach.

---

## Architecture overview

```
                  ┌──────────────┐
  PTY read ──────▶│ _pendingData │── zero-copy ──▶ consumeDataRaw()
  (GCD source)    └──────────────┘   (no NSData)     │
                                                      ▼
                                              ┌───────────────┐
                                              │   Decoder      │  (existing TerminalCore.m)
                                              │   + batch      │
                                              └───────┬───────┘
                                                      │
                                                      ▼
                                              ┌───────────────┐
                                              │  Screen model  │  (grid + history ring)
                                              │  @gridLock      │
                                              └───────┬───────┘
                                                      │ snapshot
                                                      ▼
                                              ┌───────────────┐
                                              │  Render thread  │  (NEW)
                                              │  CVDisplayLink  │
                                              │  Metal device    │
                                              │  Glyph atlas     │
                                              └───────────────┘
```

---

## 1. Zero-Copy Drain

### Current state
`drainPendingData` creates an `NSData` object per 65K chunk via `[NSData dataWithBytes:length:]`, which copies bytes. Then `consumeData:` is called with that NSData.

### Target
Pass a raw pointer + length directly to `consumeDataRaw:`. The `@synchronized(self)` in `consumeDataRaw` prevents the GCD read source from modifying `_pendingData` during parse.

### Changes (src/main.m)

**`drainPendingData`** — rewrite:
```objc
- (void)drainPendingData {
    const uint8_t *parsePtr=NULL;NSUInteger parseLen=0;BOOL more=NO;
    @synchronized(self){
        NSUInteger available=_pendingData.length-_pendingOffset;
        NSUInteger take=MIN((NSUInteger)65536,available);
        if(take){
            parsePtr=(const uint8_t *)_pendingData.bytes+_pendingOffset;
            parseLen=take;
            _pendingOffset+=take;
        }
        // Do NOT compact here — compaction could move memory under parsePtr
        NSUInteger remaining=_pendingData.length-_pendingOffset;
        more=remaining>0;
        if(_readPaused&&remaining<=131072&&_readSource){
            _readPaused=NO;dispatch_resume(_readSource);
        }
        if(!more){_pendingData setLength:0];_pendingOffset=0;_drainScheduled=NO;}
    }
    if(parseLen)[self consumeDataRaw:parsePtr length:parseLen];
    // Compact after parse — no active pointer into _pendingData
    if(parseLen){
        @synchronized(self){
            if(_pendingOffset>=262144&&_pendingOffset*2>=_pendingData.length){
                [_pendingData replaceBytesInRange:NSMakeRange(0,_pendingOffset)
                                        withBytes:NULL length:0];
                _pendingOffset=0;
            }
        }
    }
    if(more)dispatch_async(_parseQueue,^{[self drainPendingData];});
}
```

**Key safety**: `consumeDataRaw:` takes `@synchronized(self)` (recursive lock in Obj-C). The read source's `@synchronized(self)` blocks during parse. `_pendingData.bytes` is stable while the lock is held. Compaction happens AFTER the parse, when no pointer is live.

**Estimated effort**: 30 minutes (including testing)

---

## 2. Grid Lock Separation

### Current state
All `@synchronized(self)` — parse, render, buffer, scroll all share one recursive lock.

### Target
- `_gridLockToken` (NSObject) — protects the grid, history, cursor, damage
- `_bufferLockToken` (NSObject) — protects `_pendingData`, `_pendingOffset`, `_readSource`, `_readPaused`, `_master`
- `drawRect:` takes a snapshot under `_gridLockToken`, releases the lock, then paints

### Changes (src/main.m)

1. Add ivars: `NSObject *_gridLockToken; NSObject *_bufferLockToken;`
2. Initialize in `initWithFrame:config:`
3. Replace buffer-access `@synchronized(self)` with `@synchronized(_bufferLockToken)`
4. Replace grid-access `@synchronized(self)` with `@synchronized(_gridLockToken)`
5. In `drawRect:`, snapshot visible rows under `_gridLockToken`, then release and paint from the snapshot
6. `takeDamageRect` uses `_gridLockToken`

**Lock ordering rule**: Always acquire `_bufferLockToken` before `_gridLockToken` if both are needed. The parse path takes `_gridLockToken` only (inside `consumeDataRaw`). The drain takes `_bufferLockToken` then calls into `consumeDataRaw` which takes `_gridLockToken`. `drawRect:` takes only `_gridLockToken`. No reverse ordering.

**Estimated effort**: 2 hours (including deadlock testing)

---

## 3. Dedicated Render Thread

### Current state
`drawRect:` on the main thread. `refreshTextView` uses `dispatch_after` with 8ms delay.

### Target
A dedicated serial render queue (`com.termatica.render`) driven by `CVDisplayLink`. The main thread only handles input events and window management.

### Changes (src/main.m)

**New ivars**: `dispatch_queue_t _renderQueue; CVDisplayLinkRef _displayLink; TCell *_renderSnapshot; NSUInteger *_renderCursor;`

**`refreshTextView`** — rewrite:
```objc
- (void)refreshTextView {
    if(_synchronizedUpdates||_displayScheduled) return;
    _displayScheduled=YES;
    dispatch_async(_renderQueue, ^{
        self->_displayScheduled=NO;
        NSRect damage=[self takeDamageRect];
        if(!NSIsEmptyRect(damage)){
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setNeedsDisplayInRect:damage];
            });
        }
    });
}
```

**`startDisplayLink`** (called from `initWithFrame:` or `viewDidMoveToWindow:`):
```objc
- (void)startDisplayLink {
    CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    __weak typeof(self) weakSelf=self;
    CVDisplayLinkSetOutputCallback(_displayLink,
        ^(CVDisplayLinkRef link,const CVTimeStamp *now,const CVTimeStamp *out,
          CVOptionFlags flags,CVOptionFlags *flagsOut,void *ctx){
            __strong typeof(weakSelf) self=weakSelf;
            if(!self) return kCVReturnSuccess;
            dispatch_async(self->_renderQueue,^{[weakSelf renderFrame];});
            return kCVReturnSuccess;
        }, NULL);
    CVDisplayLinkStart(_displayLink);
}
```

**`renderFrame`** (NEW — on `_renderQueue`):
1. Acquire `_gridLockToken` (read-only — quickly snapshot damage + visible cells)
2. Copy visible rows into `_renderSnapshot` (memcpy, bounded by `rows*cols*12` bytes)
3. Release `_gridLockToken`
4. Draw from `_renderSnapshot` via Metal or CoreText

**`drawRect:`** — simplified to just call the render queue if not already scheduled.

**Estimated effort**: 4 hours (including frame pacing tests)

---

## 4. Glyph Atlas (CoreText, CPU path)

### Current state
Every frame calls `[NSString drawAtPoint:withAttributes:]` which goes through CoreText's full shaping pipeline per style run.

### Target
Pre-rasterize each (codepoint, font, flags) combination to a `CGImage`, cache in an `NSCache`, and blit via `CGContextDrawImage` during `drawRect:` / `renderFrame`.

### Changes (src/main.m)

**New ivars**: `NSCache *_glyphCache;` keyed by `@(codepoint | (flags << 24))`

**`cachedGlyphForCodepoint:flags:`** (NEW):
```objc
- (CGImageRef)cachedGlyphForCodepoint:(uint32_t)cp flags:(uint8_t)flags
    __attribute__((objc_direct)) {
    NSNumber *key=@(cp | ((uint32_t)flags << 24));
    CGImageRef cached=(__bridge CGImageRef)_glyphCache[key];
    if(cached) return cached;
    
    NSFont *font=(flags&TBold)?_boldFont:((flags&TItalic)?_italicFont:_font);
    NSString *str=[self stringForCodepoint:cp];
    if(!str) str=@" ";
    
    NSColor *color=TColor(cp==0?TRGB(self.config.foreground):TDefaultColor);
    NSDictionary *attrs=@{NSFontAttributeName:font,
                          NSForegroundColorAttributeName:color};
    NSSize size=[str sizeWithAttributes:attrs];
    if(size.width<=0||size.height<=0) return NULL;
    
    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:ceil(size.width)
        pixelsHigh:ceil(size.height) bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:32];
    NSGraphicsContext *ctx=[NSGraphicsContext
        graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsContext];
    [NSGraphicsContext setCurrentContext:ctx];
    [str drawAtPoint:NSZeroPoint withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsContext];
    CGImageRef image=rep.CGImage;
    _glyphCache[key]=(__bridge id)image;
    return image;
}
```

**In `drawRect:` / `renderFrame`** — replace `[NSString drawAtPoint:withAttributes:]` with:
```objc
CGImageRef glyph=[self cachedGlyphForCodepoint:codepoint flags:flags];
if(glyph) CGContextDrawImage(ctx,NSRectToCGRect(drawRect),glyph);
```

**Cache limits**: `NSCache` with `countLimit=8192`, `totalCostLimit=8*1024*1024` (8 MB).

**For wide characters (CJK, emoji)**: The glyph is naturally 2× the cell width, drawn at the correct position.

**Estimated effort**: 3 hours

---

## 5. Metal Renderer (GPU path)

### Current state
`[NSString drawAtPoint:withAttributes:]` via CoreText, on the main thread, no GPU.

### Target
`CAMetalLayer` with a `MTLRenderPipelineState`, rendering from a glyph atlas texture and cell vertex buffer.

### New files

**`src/shaders.metal`** (NEW):
```metal
#include <metal_stdlib>
using namespace metal;

struct CellVertex {
    float2 position [[attribute(0)]];
    float2 texCoord  [[attribute(1)]];
    float4 color     [[attribute(2)]];
};

vertex CellVertex cell_vertex(uint vid [[vertex_id]],
                              device const CellVertex* cells [[buffer(0)]]) {
    return cells[vid];
}

fragment float4 cell_fragment(CellVertex in [[stage_in]],
                              texture2d<float> atlas [[texture(0)]],
                              sampler texSampler [[sampler(0)]]) {
    float4 glyph = atlas.sample(texSampler, in.texCoord);
    return glyph * in.color;
}
```

**Changes (src/main.m)**:

1. **`TTerminalView`** — set `self.layerClass` to `[CAMetalLayer class]` by overriding `+ (Class)layerClass`
2. **Initialize Metal**: `id<MTLDevice> _device = MTLCreateSystemDefaultDevice();`, `id<MTLCommandQueue> _commandQueue = [_device newCommandQueue];`
3. **Load shaders**: Use `MTKView` or manually compile `shaders.metal` into a `MTLLibrary`
4. **Build pipeline**: `MTLRenderPipelineDescriptor` with vertex+fragment functions, `MTLPixelFormatBGRA8Unorm`, alpha blending
5. **Glyph atlas texture**: `MTLTexture` of 1024×1024 (or 2048×2048) with LRU eviction. Each glyph is rasterized via CoreText to a `CGContext` and uploaded via `replaceRegion:`
6. **Cell buffer**: Each frame, fill a `MTLBuffer` with `CellVertex` data (position, texCoord, color) for visible cells. One quad per cell = 6 vertices per cell (two triangles)
7. **Draw**: `MTLCommandBuffer` → `MTLRenderCommandEncoder` → `setVertexBytes:` for cells, `setFragmentTexture:` for atlas, `drawPrimitives:MTLPrimitiveTriangle vertexStart:0 vertexCount:6*rows*cols`

### Render thread flow:
```
CVDisplayLink fires → renderFrame:
1. Lock _gridLockToken, snapshot visible cells
2. For each cell, look up glyph in atlas texture (upload if missing)
3. Fill vertex buffer with (position, texCoord, color) per cell
4. Unlock _gridLockToken
5. Create MTLCommandBuffer
6. Create MTLRenderCommandEncoder
7. Set pipeline, vertex buffer, texture
8. drawPrimitives
9. presentDrawable
```

**Estimated effort**: 5-7 days (Metal is the big one)

### Backward compatibility
The Metal renderer would be an opt-in path, with the CoreText renderer as fallback for systems without Metal (none in practice on macOS 13+). A `config.metalRendering` boolean (default `YES`) would gate it.

---

## Summary table

| Component | Est. effort | Est. Unicode gain | Est. render gain |
|---|---:|---:|---:|
| Zero-copy drain | 30 min | +10-15 MB/s (core→end-to-end) | — |
| Lock separation | 2 hrs | +5-10 MB/s (parser/render overlap) | — |
| Render thread | 4 hrs | — | frame pacing, latency |
| Glyph atlas (CPU) | 3 hrs | — | 2-3× paint speedup |
| Metal renderer | 5-7 days | — | 10×+ paint speedup |

### Total for the "1 prompt" scope (zero-copy + lock + render thread + glyph atlas):
**~10 hours of implementation**, achievable in one focused session.

### What this would deliver:
- **Unicode parser**: 94 → ~110+ MB/s (zero-copy eliminates the 12 MB/s gap between core and end-to-end)
- **Unicode core**: 106 → ~120+ MiB/s (TWidthFast + wider batch + no index-- overhead)
- **Paint**: p50 7.2 → ~3 ms (glyph atlas eliminates per-frame CoreText shaping)
- **Frame pacing**: vsync-accurate via CVDisplayLink (0/240 overshoots guaranteed)
- **Render-mode throughput**: 62 → ~100+ MB/s (render thread overlaps with parser)

### The Metal renderer (5-7 days) would add:
- **Paint**: p50 ~3 → ~0.5 ms (GPU blit vs CPU CGContext)
- **Render-mode throughput**: 100 → 150+ MB/s (GPU textured quads vs CPU glyph cache)
