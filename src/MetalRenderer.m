#import "MetalRenderer.h"
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>
#import <simd/simd.h>

enum { TMetalAtlasSize = 1024, TMetalColorAtlasSize = 1024, TMetalMaxAtlasPages = 4 };
static const NSUInteger TMetalImageCacheBudget=32u*1024u*1024u;
static const NSUInteger TMetalImageUploadLimit=256u*1024u*1024u;
static const void *TMetalRenderQueueKey=&TMetalRenderQueueKey;
enum { TMetalBold=1, TMetalItalic=2, TMetalUnderline=4, TMetalInverse=8, TMetalWide=16, TMetalContinuation=32, TMetalCluster=64 };
static const uint32_t TMetalDefaultColor=0xFFFFFFFFu;

typedef struct {
    vector_float2 origin;
    vector_float2 size;
    vector_float2 uv0;
    vector_float2 uv1;
    uint32_t color;
    uint32_t kind;
} TMetalInstance;

typedef struct {
    CGRect uv;
    float offsetX;
    float offsetY;
    float width;
    float height;
    uint32_t kind;
    uint32_t page;
#if TERMATICA_BENCHMARKS
    uint32_t fallback;
#endif
} TMetalGlyph;

static uint32_t TMetalRGBA(uint32_t rgb,CGFloat alpha) {
    return ((rgb&0xFFFFFFu)<<8)|(uint32_t)lrint(MAX(0,MIN(1,alpha))*255.0);
}

static NSString *TMetalCellString(TRenderSnapshot *snapshot,uint32_t codepoint) {
    if(codepoint>=0x110000){NSUInteger index=codepoint-0x110000;return index<snapshot.graphemes.count?snapshot.graphemes[index]:@"\uFFFD";}
    if(!codepoint)codepoint=' ';
    if(codepoint<128){static NSString *ascii[128];static dispatch_once_t once;dispatch_once(&once,^{for(NSUInteger i=0;i<128;i++){unichar value=(unichar)i;ascii[i]=[NSString stringWithCharacters:&value length:1];}});return ascii[codepoint];}
    if(codepoint<=0xFFFF){unichar value=(unichar)codepoint;return [NSString stringWithCharacters:&value length:1];}
    if(codepoint>0x10FFFF)return @"\uFFFD";
    uint32_t value=codepoint-0x10000;unichar pair[2]={(unichar)(0xD800+(value>>10)),(unichar)(0xDC00+(value&0x3FF))};
    return [NSString stringWithCharacters:pair length:2];
}

static void TMetalAppendQuad(NSMutableData *data,float x,float y,float width,float height,float u0,float v0,float u1,float v1,uint32_t color,uint32_t kind) {
    if(width<=0||height<=0)return;
    TMetalInstance instance={{x,y},{width,height},{u0,v0},{u1,v1},color,kind};
    [data appendBytes:&instance length:sizeof(instance)];
}

static void TMetalAppendUnderline(NSMutableData *data,CGFloat x,CGFloat y,CGFloat width,CGFloat baseThickness,uint8_t style,uint32_t color) {
    CGFloat thickness=MAX(baseThickness,0.5)*(style==2?2:1);if(style<=2){TMetalAppendQuad(data,x,y-thickness,width,thickness,0,0,0,0,color,0);return;}
    CGFloat position=0;while(position<width){CGFloat length=style==4?1:(style==5&&fmod(position,9)>=6?1:4);length=MIN(length,width-position);TMetalAppendQuad(data,x+position,y-thickness,length,thickness,0,0,0,0,color,0);position+=style==4?3:(style==5?(length==1?3:6):6);}
}

static BOOL TMetalLineUsesColorGlyphs(CTLineRef line) {
    CFArrayRef runs=CTLineGetGlyphRuns(line);for(CFIndex index=0;index<CFArrayGetCount(runs);index++){CTRunRef run=(CTRunRef)CFArrayGetValueAtIndex(runs,index);CFDictionaryRef attributes=CTRunGetAttributes(run);CTFontRef font=attributes?CFDictionaryGetValue(attributes,kCTFontAttributeName):NULL;if(font&&(CTFontGetSymbolicTraits(font)&kCTFontTraitColorGlyphs))return YES;}return NO;
}

#if TERMATICA_BENCHMARKS
static BOOL TMetalLineUsesFallbackFont(CTLineRef line,NSFont *requestedFont) {
    CFStringRef requested=(__bridge CFStringRef)requestedFont.fontName;CFArrayRef runs=CTLineGetGlyphRuns(line);for(CFIndex index=0;index<CFArrayGetCount(runs);index++){CTRunRef run=(CTRunRef)CFArrayGetValueAtIndex(runs,index);CFDictionaryRef attributes=CTRunGetAttributes(run);CTFontRef font=attributes?CFDictionaryGetValue(attributes,kCTFontAttributeName):NULL;if(!font)continue;CFStringRef actual=CTFontCopyPostScriptName(font);BOOL differs=actual&&requested&&CFStringCompare(actual,requested,0)!=kCFCompareEqualTo;if(actual)CFRelease(actual);if(differs)return YES;}return NO;
}
#endif

@interface TMetalRenderBackend ()
@property(nonatomic,readwrite) uint64_t lastPresentedGeneration;
@property(nonatomic,readwrite) uint64_t lastFrameChecksum;
@property(nonatomic,readwrite) BOOL lastFrameVariedPixels;
@property(nonatomic,readwrite) double lastCPUEncodeMilliseconds;
@property(nonatomic,readwrite) double lastGPUExecutionMilliseconds;
#if TERMATICA_BENCHMARKS
@property(nonatomic,readwrite) NSData *lastFramePixels;
@property(nonatomic,readwrite) NSUInteger lastFramePixelWidth;
@property(nonatomic,readwrite) NSUInteger lastFramePixelHeight;
@property(nonatomic,readwrite) NSUInteger lastFrameBytesPerRow;
@property(nonatomic,readwrite) NSUInteger lastFrameColorGlyphCount;
@property(nonatomic,readwrite) NSUInteger lastFrameFallbackGlyphCount;
#endif
- (void)purgeResourceCachesForMemoryPressure;
@end

@implementation TMetalRenderBackend {
    __weak NSView *_hostView;
    CAMetalLayer *_metalLayer;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _atlasTexture;
    id<MTLTexture> _colorAtlasTexture;
    dispatch_queue_t _renderQueue;
    NSObject *_stateLock;
    TRenderSnapshot *_pendingSnapshot;
    BOOL _renderScheduled;
    BOOL _stopped;
    TRenderMetrics _metrics;
    NSMutableDictionary<NSString *,NSValue *> *_glyphs;
    NSMutableDictionary<NSValue *,NSDictionary *> *_imageTextures;
    NSMutableArray<NSValue *> *_imageLRU;
    NSUInteger _atlasX[TMetalMaxAtlasPages];
    NSUInteger _atlasY[TMetalMaxAtlasPages];
    NSUInteger _atlasRowHeight[TMetalMaxAtlasPages];
    NSUInteger _colorAtlasX[TMetalMaxAtlasPages];
    NSUInteger _colorAtlasY[TMetalMaxAtlasPages];
    NSUInteger _colorAtlasRowHeight[TMetalMaxAtlasPages];
    NSUInteger _atlasPage;
    NSUInteger _colorAtlasPage;
    NSUInteger _atlasPageCount;
    NSUInteger _colorAtlasPageCount;
    NSUInteger _imageTextureBytes;
#if TERMATICA_BENCHMARKS
    NSUInteger _imageEvictionCount;
    NSUInteger _glyphEntryCount;
    NSUInteger _atlasResetCount;
    NSUInteger _memoryPurgeCount;
#endif
    BOOL _atlasResetDuringBuild;
    BOOL _validatePixels;
    NSValue *_asciiGlyphs[3][128];
    uint32_t _bmpGlyphKeys[3][256];
    NSValue *_bmpGlyphs[3][256];
    NSFont *_slotFonts[3];
    id<MTLCommandBuffer> _lastCommandBuffer;
    dispatch_source_t _memoryPressureSource;
}

- (NSString *)name {return @"metal";}
- (CALayer *)presentationLayer {return _metalLayer;}
#if TERMATICA_BENCHMARKS
- (NSDictionary *)validationFrameCapture {@synchronized(_stateLock){if(!self.lastFramePixels.length)return @{};return @{@"pixels":self.lastFramePixels,@"width":@(self.lastFramePixelWidth),@"height":@(self.lastFramePixelHeight),@"bytesPerRow":@(self.lastFrameBytesPerRow),@"generation":@(self.lastPresentedGeneration),@"colorGlyphs":@(self.lastFrameColorGlyphCount),@"fallbackGlyphs":@(self.lastFrameFallbackGlyphCount)};}}
- (NSDictionary *)cacheDiagnostics {__block NSDictionary *result=nil;dispatch_sync(_renderQueue,^{NSUInteger monoGPU=self->_atlasPageCount*TMetalAtlasSize*TMetalAtlasSize,colorGPU=self->_colorAtlasPageCount*TMetalColorAtlasSize*TMetalColorAtlasSize*4;result=@{@"glyphEntries":@(self->_glyphEntryCount),@"imageEntries":@(self->_imageTextures.count),@"imageBytes":@(self->_imageTextureBytes),@"imageBudget":@(TMetalImageCacheBudget),@"monoAtlasPages":@(self->_atlasPageCount),@"colorAtlasPages":@(self->_colorAtlasPageCount),@"monoAtlasGPUBytes":@(monoGPU),@"colorAtlasGPUBytes":@(colorGPU),@"atlasCPUBytes":@0,@"totalCacheBytes":@(monoGPU+colorGPU+self->_imageTextureBytes),@"colorAtlasAllocated":@(self->_colorAtlasTexture!=nil),@"imageEvictions":@(self->_imageEvictionCount),@"atlasResets":@(self->_atlasResetCount),@"memoryPurges":@(self->_memoryPurgeCount)};});return result?:@{};}
- (void)purgeCachesForValidation {dispatch_sync(_renderQueue,^{[self purgeResourceCachesForMemoryPressure];});}
#endif

- (instancetype)initWithHostView:(NSView *)view error:(NSError **)error {
    if(!(self=[super init]))return nil;
    _hostView=view;_stateLock=[NSObject new];_glyphs=[NSMutableDictionary dictionary];_imageTextures=[NSMutableDictionary dictionary];_imageLRU=[NSMutableArray array];
    if(getenv("TERMATICA_METAL_FORCE_FAILURE")){
        if(error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:1 userInfo:@{NSLocalizedDescriptionKey:@"forced Metal initialization failure"}];
        return nil;
    }
    _device=MTLCreateSystemDefaultDevice();
    if(!_device){if(error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Metal device unavailable"}];return nil;}
    _commandQueue=[_device newCommandQueue];
    if(!_commandQueue){if(error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Metal command queue unavailable"}];return nil;}
    NSString *source=@"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct I{float2 o;float2 s;float2 u0;float2 u1;uint c;uint k;};"
    "struct O{float4 p[[position]];float2 u;float4 c;uint k[[flat]];};"
    "float4 color(uint v){return float4(float((v>>24)&255),float((v>>16)&255),float((v>>8)&255),float(v&255))/255.0;}"
    "vertex O tv(uint v[[vertex_id]],uint n[[instance_id]],constant I*i[[buffer(0)]],constant float2&vp[[buffer(1)]]){"
    "float2 q=v==0?float2(0,0):(v==1?float2(1,0):(v==2?float2(0,1):float2(1,1)));I a=i[n];float2 z=a.o+q*a.s;"
    "O o;o.p=float4(z.x/vp.x*2-1,1-z.y/vp.y*2,0,1);o.u=mix(a.u0,a.u1,q);o.c=color(a.c);o.k=a.k;return o;}"
    "fragment float4 tf(O i[[stage_in]],texture2d_array<float> mono[[texture(0)]],texture2d_array<float> colorGlyphs[[texture(1)]],texture2d<float> image[[texture(2)]]){constexpr sampler s(coord::normalized,filter::linear);uint k=i.k&255;uint page=(i.k>>16)&255;"
    "if(k==0)return i.c;if(k==1){float4 p=mono.sample(s,i.u,page);return float4(i.c.rgb,i.c.a*p.r);}if(k==3)return colorGlyphs.sample(s,i.u,page);return image.sample(s,i.u)*i.c;}";
    NSError *libraryError=nil;id<MTLLibrary> library=[_device newLibraryWithSource:source options:nil error:&libraryError];
    if(!library){if(error)*error=libraryError;return nil;}
    MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction=[library newFunctionWithName:@"tv"];descriptor.fragmentFunction=[library newFunctionWithName:@"tf"];
    descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    descriptor.colorAttachments[0].blendingEnabled=YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    _pipeline=[_device newRenderPipelineStateWithDescriptor:descriptor error:&libraryError];
    if(!_pipeline){if(error)*error=libraryError;return nil;}
    MTLTextureDescriptor *atlasDescriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:TMetalAtlasSize height:TMetalAtlasSize mipmapped:NO];
    atlasDescriptor.textureType=MTLTextureType2DArray;atlasDescriptor.arrayLength=1;atlasDescriptor.usage=MTLTextureUsageShaderRead;_atlasTexture=[_device newTextureWithDescriptor:atlasDescriptor];_atlasPageCount=1;
    if(!_atlasTexture){if(error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Metal glyph atlas allocation failed"}];return nil;}
    _renderQueue=dispatch_queue_create("com.termatica.metal-render",DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);dispatch_queue_set_specific(_renderQueue,TMetalRenderQueueKey,(__bridge void *)self,NULL);
    _memoryPressureSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,0,DISPATCH_MEMORYPRESSURE_WARN|DISPATCH_MEMORYPRESSURE_CRITICAL,_renderQueue);if(_memoryPressureSource){__weak typeof(self) weakSelf=self;dispatch_source_set_event_handler(_memoryPressureSource,^{[weakSelf purgeResourceCachesForMemoryPressure];});dispatch_resume(_memoryPressureSource);}
    _validatePixels=getenv("TERMATICA_METAL_VALIDATE_PIXELS")!=NULL;
    _metalLayer=[CAMetalLayer layer];_metalLayer.device=_device;_metalLayer.pixelFormat=MTLPixelFormatBGRA8Unorm;_metalLayer.framebufferOnly=!_validatePixels;_metalLayer.maximumDrawableCount=2;_metalLayer.allowsNextDrawableTimeout=YES;_metalLayer.opaque=NO;_metalLayer.hidden=YES;
    [view.layer addSublayer:_metalLayer];
    [self resetAtlas];
    return self;
}

- (void)dealloc {if(_memoryPressureSource){dispatch_source_set_event_handler(_memoryPressureSource,^{});dispatch_source_cancel(_memoryPressureSource);}}

- (void)waitForAtlasSafety {
    id<MTLCommandBuffer> command=nil;@synchronized(_stateLock){command=_lastCommandBuffer;}
    if(command&&command.status<MTLCommandBufferStatusCompleted)[command waitUntilCompleted];
    @synchronized(_stateLock){if(_lastCommandBuffer==command)_lastCommandBuffer=nil;}
}

- (void)resetAtlas {
    [self waitForAtlasSafety];
    [_glyphs removeAllObjects];for(NSUInteger slot=0;slot<3;slot++){for(NSUInteger scalar=0;scalar<128;scalar++)_asciiGlyphs[slot][scalar]=nil;for(NSUInteger bucket=0;bucket<256;bucket++){_bmpGlyphKeys[slot][bucket]=0;_bmpGlyphs[slot][bucket]=nil;}_slotFonts[slot]=nil;}memset(_atlasX,0,sizeof(_atlasX));memset(_atlasY,0,sizeof(_atlasY));memset(_atlasRowHeight,0,sizeof(_atlasRowHeight));memset(_colorAtlasX,0,sizeof(_colorAtlasX));memset(_colorAtlasY,0,sizeof(_colorAtlasY));memset(_colorAtlasRowHeight,0,sizeof(_colorAtlasRowHeight));for(NSUInteger page=0;page<TMetalMaxAtlasPages;page++){_atlasX[page]=1;_atlasY[page]=1;_colorAtlasX[page]=1;_colorAtlasY[page]=1;}_atlasPage=0;_colorAtlasPage=0;
#if TERMATICA_BENCHMARKS
    _glyphEntryCount=0;_atlasResetCount++;
#endif
}

- (id<MTLTexture>)newGlyphAtlasColor:(BOOL)color pages:(NSUInteger)pages {NSUInteger size=color?TMetalColorAtlasSize:TMetalAtlasSize;MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:color?MTLPixelFormatBGRA8Unorm:MTLPixelFormatR8Unorm width:size height:size mipmapped:NO];descriptor.textureType=MTLTextureType2DArray;descriptor.arrayLength=MAX((NSUInteger)1,MIN((NSUInteger)TMetalMaxAtlasPages,pages));descriptor.usage=MTLTextureUsageShaderRead;return [_device newTextureWithDescriptor:descriptor];}

- (BOOL)ensureColorAtlas {
    if(_colorAtlasTexture)return YES;_colorAtlasTexture=[self newGlyphAtlasColor:YES pages:1];_colorAtlasPageCount=_colorAtlasTexture?1:0;return _colorAtlasTexture!=nil;
}

- (BOOL)growGlyphAtlasColor:(BOOL)color {NSUInteger count=color?_colorAtlasPageCount:_atlasPageCount;if(count>=TMetalMaxAtlasPages)return NO;[self waitForAtlasSafety];id<MTLTexture> texture=[self newGlyphAtlasColor:color pages:count+1];if(!texture)return NO;if(color){_colorAtlasTexture=texture;_colorAtlasPageCount=count+1;}else{_atlasTexture=texture;_atlasPageCount=count+1;}[self resetAtlas];_atlasResetDuringBuild=YES;return YES;}

- (void)removeAllImageTextures {
    [_imageTextures removeAllObjects];[_imageLRU removeAllObjects];_imageTextureBytes=0;
}

- (void)purgeResourceCachesForMemoryPressure {
    if(_stopped)return;[self waitForAtlasSafety];id<MTLTexture> mono=[self newGlyphAtlasColor:NO pages:1];if(mono){_atlasTexture=mono;_atlasPageCount=1;}_colorAtlasTexture=nil;_colorAtlasPageCount=0;[self resetAtlas];[self removeAllImageTextures];
#if TERMATICA_BENCHMARKS
    _memoryPurgeCount++;
#endif
}

- (void)setPresentationFrame:(CGRect)frame scale:(CGFloat)scale {
    if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf setPresentationFrame:frame scale:scale];});return;}
    [CATransaction begin];[CATransaction setDisableActions:YES];_metalLayer.frame=frame;_metalLayer.contentsScale=MAX(1,scale);_metalLayer.drawableSize=CGSizeMake(MAX(1,frame.size.width*scale),MAX(1,frame.size.height*scale));[CATransaction commit];
}

- (BOOL)configureWithMetrics:(TRenderMetrics)metrics error:(NSError **)error {
    if(metrics.rows==0||metrics.columns==0||metrics.viewportWidth<=0||metrics.viewportHeight<=0){if(error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:5 userInfo:@{NSLocalizedDescriptionKey:@"invalid render metrics"}];return NO;}
    BOOL glyphMetricsChanged=_metrics.cellWidth>0&&(_metrics.cellWidth!=metrics.cellWidth||_metrics.cellHeight!=metrics.cellHeight||_metrics.scale!=metrics.scale);
    _metrics=metrics;
    if(glyphMetricsChanged)dispatch_async(_renderQueue,^{[self resetAtlas];[self removeAllImageTextures];});
    void (^applyPresentationFrame)(void)=^{[self setPresentationFrame:CGRectMake(0,0,metrics.viewportWidth,metrics.viewportHeight) scale:metrics.scale];};
    if(NSThread.isMainThread)applyPresentationFrame();else dispatch_async(dispatch_get_main_queue(),applyPresentationFrame);
    return YES;
}

- (void)invalidateCaches {
    dispatch_async(_renderQueue,^{[self resetAtlas];[self->_imageTextures removeAllObjects];});
}

- (void)fail:(NSString *)message code:(NSInteger)code {
    void (^handler)(NSError *)=self.failureHandler;if(!handler)return;
    NSError *error=[NSError errorWithDomain:@"TermaticaMetal" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    dispatch_async(dispatch_get_main_queue(),^{handler(error);});
}

- (NSValue *)glyphForText:(NSString *)text font:(NSFont *)font width:(NSUInteger)width height:(NSUInteger)height scale:(CGFloat)scale slot:(NSUInteger)slot {
    NSUInteger padding=MAX((NSUInteger)1,(NSUInteger)ceil(scale*2)),contentWidth=MAX((NSUInteger)1,(NSUInteger)ceil(width*scale)),contentHeight=MAX((NSUInteger)1,(NSUInteger)ceil(height*scale));
    NSUInteger requestedWidth=contentWidth+padding*2,requestedHeight=contentHeight+padding*2;
    if(slot<3&&_slotFonts[slot]&&_slotFonts[slot]!=font){[self resetAtlas];_atlasResetDuringBuild=YES;}
    if(slot<3)_slotFonts[slot]=font;
    unichar firstChar=text.length>0?[text characterAtIndex:0]:128;BOOL ascii=firstChar<128&&text.length==1&&slot<3;NSValue *cached=ascii?_asciiGlyphs[slot][firstChar]:nil;
    if(!cached&&text.length==1&&slot<3){NSUInteger bucket=firstChar&0xFF;if(_bmpGlyphKeys[slot][bucket]==firstChar)cached=_bmpGlyphs[slot][bucket];}
    NSString *key=nil;if(!cached){key=[NSString stringWithFormat:@"%lu|%.3f|%lu|%lu|%@",(unsigned long)slot,scale,(unsigned long)requestedWidth,(unsigned long)requestedHeight,text];cached=_glyphs[key];}if(cached)return cached;
    NSDictionary *attributes=@{(__bridge NSString *)kCTFontAttributeName:font,(__bridge NSString *)kCTForegroundColorAttributeName:NSColor.whiteColor};
    NSAttributedString *attributed=[[NSAttributedString alloc]initWithString:text attributes:attributes];CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    BOOL colorGlyph=TMetalLineUsesColorGlyphs(line);
#if TERMATICA_BENCHMARKS
    BOOL fallbackGlyph=[text isEqual:@"\uFFFD"]||TMetalLineUsesFallbackFont(line,font);
#endif
    NSUInteger atlasSize=colorGlyph?TMetalColorAtlasSize:TMetalAtlasSize,pixelWidth=MIN(atlasSize-2,requestedWidth),pixelHeight=MIN(atlasSize-2,requestedHeight);
    if(colorGlyph&&![self ensureColorAtlas]){CFRelease(line);return nil;}
    NSUInteger page=colorGlyph?_colorAtlasPage:_atlasPage,pageCount=colorGlyph?_colorAtlasPageCount:_atlasPageCount;NSUInteger *xValues=colorGlyph?_colorAtlasX:_atlasX,*yValues=colorGlyph?_colorAtlasY:_atlasY,*heightValues=colorGlyph?_colorAtlasRowHeight:_atlasRowHeight;NSUInteger *atlasX=&xValues[page],*atlasY=&yValues[page],*rowHeight=&heightValues[page];
    if(*atlasX+pixelWidth+1>atlasSize){*atlasX=1;*atlasY+=*rowHeight+1;*rowHeight=0;}
    if(*atlasY+pixelHeight+1>atlasSize){if(page+1<pageCount)page++;else if(pageCount<TMetalMaxAtlasPages){if(![self growGlyphAtlasColor:colorGlyph]){CFRelease(line);return nil;}page=0;}else{[self resetAtlas];_atlasResetDuringBuild=YES;page=0;}if(colorGlyph)_colorAtlasPage=page;else _atlasPage=page;xValues=colorGlyph?_colorAtlasX:_atlasX;yValues=colorGlyph?_colorAtlasY:_atlasY;heightValues=colorGlyph?_colorAtlasRowHeight:_atlasRowHeight;atlasX=&xValues[page];atlasY=&yValues[page];rowHeight=&heightValues[page];if(slot<3)_slotFonts[slot]=font;}
    if(*atlasX+pixelWidth+1>atlasSize||*atlasY+pixelHeight+1>atlasSize){CFRelease(line);return nil;}
    [self waitForAtlasSafety];
    NSUInteger bytesPerPixel=colorGlyph?4:1,bytesPerRow=pixelWidth*bytesPerPixel;uint8_t *glyph=calloc(pixelHeight,bytesPerRow);if(!glyph){CFRelease(line);return nil;}
    CGColorSpaceRef colorSpace=colorGlyph?CGColorSpaceCreateDeviceRGB():NULL;CGContextRef context=colorGlyph?CGBitmapContextCreate(glyph,pixelWidth,pixelHeight,8,bytesPerRow,colorSpace,(CGBitmapInfo)(kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little)):CGBitmapContextCreate(glyph,pixelWidth,pixelHeight,8,bytesPerRow,NULL,(CGBitmapInfo)kCGImageAlphaOnly);if(colorSpace)CGColorSpaceRelease(colorSpace);
    if(!context){free(glyph);CFRelease(line);return nil;}
    CGContextSetShouldAntialias(context,true);CGContextSetAllowsAntialiasing(context,true);CGContextSetShouldSmoothFonts(context,true);CGContextSetAllowsFontSmoothing(context,true);
    // The texture quad extends one padding inset outside each cell. Rasterize
    // bottom-up and include both quad insets so Metal lands on AppKit's baseline.
    CGContextSetTextMatrix(context,CGAffineTransformIdentity);CGContextScaleCTM(context,scale,scale);CGFloat inset=(CGFloat)padding/scale,baseline=inset*3-font.descender;CGContextSetTextPosition(context,inset,baseline);CTLineDraw(line,context);CFRelease(line);CGContextRelease(context);
    MTLRegion region=MTLRegionMake2D(*atlasX,*atlasY,pixelWidth,pixelHeight);
    [(colorGlyph?_colorAtlasTexture:_atlasTexture) replaceRegion:region mipmapLevel:0 slice:page withBytes:glyph bytesPerRow:bytesPerRow bytesPerImage:bytesPerRow*pixelHeight];free(glyph);
    TMetalGlyph glyphInfo={.uv=CGRectMake((CGFloat)*atlasX/atlasSize,(CGFloat)*atlasY/atlasSize,(CGFloat)pixelWidth/atlasSize,(CGFloat)pixelHeight/atlasSize),.offsetX=-(float)padding/(float)scale,.offsetY=-(float)padding/(float)scale,.width=(float)width+(float)(padding*2)/(float)scale,.height=(float)height+(float)(padding*2)/(float)scale,.kind=colorGlyph?3u:1u,.page=(uint32_t)page};
#if TERMATICA_BENCHMARKS
    glyphInfo.fallback=fallbackGlyph;
#endif
    cached=[NSValue valueWithBytes:&glyphInfo objCType:@encode(TMetalGlyph)];if(ascii)_asciiGlyphs[slot][firstChar]=cached;else if(text.length==1&&slot<3){NSUInteger bucket=firstChar&0xFF;_bmpGlyphKeys[slot][bucket]=firstChar;_bmpGlyphs[slot][bucket]=cached;_glyphs[key]=cached;}else _glyphs[key]=cached;
#if TERMATICA_BENCHMARKS
    _glyphEntryCount++;
#endif
    *atlasX+=pixelWidth+1;*rowHeight=MAX(*rowHeight,pixelHeight);
    return cached;
}

- (BOOL)buildInstancesForSnapshot:(TRenderSnapshot *)snapshot data:(NSMutableData *)instances {
    NSDictionary *style=snapshot.style;const TCell *cells=snapshot.cells.bytes;NSUInteger rows=snapshot.metrics.rows,columns=snapshot.metrics.columns;
    const uint8_t *underlines=snapshot.underlineStyles.bytes,*selection=snapshot.selectionMask.bytes,*search=snapshot.searchMask.bytes,*links=snapshot.linkMask.bytes;
    CGFloat scale=snapshot.metrics.scale,cellWidth=snapshot.metrics.cellWidth,cellHeight=snapshot.metrics.cellHeight;
    CGFloat left=[style[@"left"] doubleValue],top=[style[@"top"] doubleValue];
    uint32_t foreground=[style[@"foreground"] unsignedIntValue],background=[style[@"background"] unsignedIntValue],cursor=[style[@"cursor"] unsignedIntValue],accent=[style[@"accent"] unsignedIntValue],selectionColor=[style[@"selection"] unsignedIntValue];
    CGFloat backgroundAlpha=[style[@"backgroundAlpha"] doubleValue];
    CGFloat glow=[style[@"glow"] doubleValue];
    NSArray<NSNumber *> *plain=style[@"plainPalette"];BOOL colorize=[style[@"colorize"] boolValue]&&plain.count;
    TMetalAppendQuad(instances,0,0,snapshot.metrics.viewportWidth,snapshot.metrics.viewportHeight,0,0,0,0,TMetalRGBA(background,backgroundAlpha),0);
    for(NSUInteger y=0;y<rows;y++){
        BOOL inToken=NO;NSUInteger token=0;
        for(NSUInteger x=0;x<columns;x++){
            NSUInteger index=y*columns+x;TCell cell=cells[index];BOOL whitespace=!cell.ch||cell.ch==' '||cell.ch=='\t';
            if(whitespace)inToken=NO;else if(!inToken){inToken=YES;token++;}
            BOOL inverse=(cell.flags&TMetalInverse)!=0;uint32_t fg=cell.fg==TMetalDefaultColor?foreground:cell.fg,bg=cell.bg==TMetalDefaultColor?background:cell.bg;
            if(colorize&&cell.fg==TMetalDefaultColor&&!inverse&&!whitespace)fg=[plain[(token-1)%plain.count] unsignedIntValue];
            if(inverse){uint32_t swap=fg;fg=bg;bg=swap;}
            if(search[index]){bg=accent;fg=background;}
            if(selection[index])bg=selectionColor;
            if(selection[index]||search[index]||cell.bg!=TMetalDefaultColor||inverse)TMetalAppendQuad(instances,left+x*cellWidth,top+y*cellHeight,cellWidth,cellHeight,0,0,0,0,TMetalRGBA(bg,1),0);
            if(cell.flags&TMetalContinuation)continue;
            NSString *text=TMetalCellString(snapshot,cell.ch);if(!text.length||[text isEqual:@" "])continue;
            NSUInteger fontSlot=(cell.flags&TMetalBold)?1:((cell.flags&TMetalItalic)?2:0);NSFont *font=fontSlot==1?style[@"boldFont"]:(fontSlot==2?style[@"italicFont"]:style[@"font"]);if(!font)font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
            NSUInteger span=(cell.flags&TMetalWide)?2:1;NSValue *glyph=[self glyphForText:text font:font width:(NSUInteger)ceil(cellWidth*span) height:(NSUInteger)ceil(cellHeight) scale:scale slot:fontSlot];if(!glyph)return NO;
            TMetalGlyph glyphInfo={0};[glyph getValue:&glyphInfo size:sizeof(glyphInfo)];CGRect uv=glyphInfo.uv;CGFloat cellX=left+x*cellWidth,glyphX=cellX+glyphInfo.offsetX,glyphY=top+y*cellHeight+glyphInfo.offsetY,glyphWidth=cellWidth*span;
            uint32_t glyphKind=glyphInfo.kind|(glyphInfo.page<<16);
            if(glow>0&&glyphInfo.kind==1){uint32_t glowColor=TMetalRGBA(accent,MIN(0.45,glow*0.32));for(NSInteger oy=-1;oy<=1;oy++)for(NSInteger ox=-1;ox<=1;ox++)if(ox||oy)TMetalAppendQuad(instances,glyphX+ox,glyphY+oy,glyphInfo.width,glyphInfo.height,uv.origin.x,uv.origin.y,CGRectGetMaxX(uv),CGRectGetMaxY(uv),glowColor,glyphKind);}
#if TERMATICA_BENCHMARKS
            if(glyphInfo.fallback)glyphKind|=0x100u;
#endif
            TMetalAppendQuad(instances,glyphX,glyphY,glyphInfo.width,glyphInfo.height,uv.origin.x,uv.origin.y,CGRectGetMaxX(uv),CGRectGetMaxY(uv),glyphInfo.kind==3?0xFFFFFFFFu:TMetalRGBA(fg,1),glyphKind);
            if((cell.flags&TMetalUnderline)||links[index]){
                CGFloat underlineY=top+y*cellHeight+font.ascender-font.underlinePosition;
                TMetalAppendUnderline(instances,cellX,underlineY,glyphWidth,MAX(1.0/scale,font.underlineThickness),MAX((uint8_t)1,underlines[index]),TMetalRGBA(fg,1));
            }
        }
    }
    if(snapshot.cursorVisible){
        NSString *cursorStyle=style[@"cursorStyle"]?:@"block";CGFloat width=cellWidth,height=cellHeight,x=left+snapshot.cursorX*cellWidth,y=top+snapshot.cursorY*cellHeight;
        CGFloat thickness=[style[@"cursorThickness"] doubleValue];if([cursorStyle isEqual:@"bar"])width=thickness;else if([cursorStyle isEqual:@"underline"]){height=thickness;y+=cellHeight-thickness;}
        CGFloat alpha=[style[@"cursorFocused"] boolValue]?([cursorStyle isEqual:@"block"]?[style[@"cursorBlockOpacity"] doubleValue]:0.96):([cursorStyle isEqual:@"block"]?[style[@"cursorInactiveOpacity"] doubleValue]:0.5);
        TMetalAppendQuad(instances,x,y,width,height,0,0,0,0,TMetalRGBA(cursor,alpha),0);
    }
    CGFloat scanlines=[style[@"scanlines"] doubleValue],scanlineSpacing=[style[@"scanlineSpacing"] doubleValue],scanlineThickness=[style[@"scanlineThickness"] doubleValue];if(scanlines>0)for(CGFloat y=scanlineThickness;y<snapshot.metrics.viewportHeight;y+=scanlineSpacing)TMetalAppendQuad(instances,0,y,snapshot.metrics.viewportWidth,scanlineThickness,0,0,0,0,TMetalRGBA(0,scanlines*0.10),0);
    CGFloat vignette=[style[@"vignette"] doubleValue];NSUInteger vignetteLayers=[style[@"vignetteLayers"] unsignedIntegerValue];if(vignette>0&&![style[@"tiled"] boolValue])for(NSUInteger i=0;i<vignetteLayers;i++){CGFloat alpha=vignette*(vignetteLayers-i)/MAX(1.0,vignetteLayers*5.0),w=snapshot.metrics.viewportWidth-i*2,h=snapshot.metrics.viewportHeight-i*2;TMetalAppendQuad(instances,i,i,w,1,0,0,0,0,TMetalRGBA(0,alpha),0);TMetalAppendQuad(instances,i,i+h-1,w,1,0,0,0,0,TMetalRGBA(0,alpha),0);TMetalAppendQuad(instances,i,i,1,h,0,0,0,0,TMetalRGBA(0,alpha),0);TMetalAppendQuad(instances,i+w-1,i,1,h,0,0,0,0,TMetalRGBA(0,alpha),0);}
    if(snapshot.historyCount&&snapshot.historyOffset>0){CGFloat margin=[style[@"scrollbarMargin"] doubleValue],width=[style[@"scrollbarWidth"] doubleValue],track=MAX(1,snapshot.metrics.viewportHeight-margin*2),total=snapshot.historyCount+rows,thumb=MAX([style[@"scrollbarMinimumThumb"] doubleValue],track*rows/MAX((CGFloat)rows,total)),progress=(CGFloat)snapshot.historyOffset/MAX(1,(CGFloat)snapshot.historyCount),y=margin+(track-thumb)*(1-progress);TMetalAppendQuad(instances,snapshot.metrics.viewportWidth-margin,y,width,thumb,0,0,0,0,TMetalRGBA(foreground,[style[@"scrollbarOpacity"] doubleValue]),0);}
    return YES;
}

- (void)trimImageCacheForIncomingBytes:(NSUInteger)incomingBytes {
    while(_imageLRU.count&&_imageTextureBytes+incomingBytes>TMetalImageCacheBudget){NSValue *oldestKey=_imageLRU.firstObject;NSUInteger bytes=[_imageTextures[oldestKey][@"bytes"] unsignedIntegerValue];_imageTextureBytes=bytes>_imageTextureBytes?0:_imageTextureBytes-bytes;[_imageTextures removeObjectForKey:oldestKey];[_imageLRU removeObjectAtIndex:0];
#if TERMATICA_BENCHMARKS
        _imageEvictionCount++;
#endif
    }
}

- (id<MTLTexture>)textureForImage:(CGImageRef)image error:(NSError **)error {
    NSValue *cacheKey=[NSValue valueWithPointer:(const void *)image];NSDictionary *cached=_imageTextures[cacheKey];
    if(cached&&(__bridge CGImageRef)cached[@"image"]==image){[_imageLRU removeObject:cacheKey];[_imageLRU addObject:cacheKey];return cached[@"texture"];}
    if(cached){NSUInteger cachedBytes=[cached[@"bytes"] unsignedIntegerValue];_imageTextureBytes=cachedBytes>_imageTextureBytes?0:_imageTextureBytes-cachedBytes;[_imageTextures removeObjectForKey:cacheKey];[_imageLRU removeObject:cacheKey];}
    NSUInteger width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    if(!width||!height||width>16384||height>16384||width>NSUIntegerMax/4/height||width*height*4>TMetalImageUploadLimit){
        if(error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:10 userInfo:@{NSLocalizedDescriptionKey:@"invalid image dimensions"}];
        return nil;
    }
    NSUInteger bytesPerRow=width*4;void *pixels=calloc(height,bytesPerRow);
    CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=pixels&&colorSpace?CGBitmapContextCreate(pixels,width,height,8,bytesPerRow,colorSpace,(CGBitmapInfo)(kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst)):nil;
    if(colorSpace)CGColorSpaceRelease(colorSpace);
    if(!context){free(pixels);if(error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:10 userInfo:@{NSLocalizedDescriptionKey:@"image staging allocation failed"}];return nil;}
    CGContextTranslateCTM(context,0,height);CGContextScaleCTM(context,1,-1);CGContextDrawImage(context,CGRectMake(0,0,width,height),image);CGContextRelease(context);
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];descriptor.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[_device newTextureWithDescriptor:descriptor];
    if(texture)[texture replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:pixels bytesPerRow:bytesPerRow];
    free(pixels);
    if(!texture&&error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:10 userInfo:@{NSLocalizedDescriptionKey:@"Metal image texture allocation failed"}];
    NSUInteger textureBytes=bytesPerRow*height;if(texture&&textureBytes<=TMetalImageCacheBudget){[self trimImageCacheForIncomingBytes:textureBytes];id retainedImage=CFBridgingRelease(CGImageRetain(image));_imageTextures[cacheKey]=@{@"image":retainedImage,@"texture":texture,@"bytes":@(textureBytes)};[_imageLRU addObject:cacheKey];_imageTextureBytes+=textureBytes;}
    return texture;
}

- (void)renderSnapshot:(TRenderSnapshot *)snapshot {
    if(_stopped||!snapshot.isValid)return;
    if(getenv("TERMATICA_METAL_FORCE_COMMAND_FAILURE")){[self fail:@"forced Metal command failure" code:12];return;}
    id<CAMetalDrawable> drawable=[_metalLayer nextDrawable];if(!drawable)return;
    CFAbsoluteTime cpuStart=CFAbsoluteTimeGetCurrent();
    NSMutableData *instances=[NSMutableData dataWithCapacity:snapshot.metrics.rows*snapshot.metrics.columns*sizeof(TMetalInstance)];_atlasResetDuringBuild=NO;
    if(![self buildInstancesForSnapshot:snapshot data:instances]){[self fail:@"glyph atlas could not represent the current viewport" code:6];return;}
    if(_atlasResetDuringBuild){[instances setLength:0];_atlasResetDuringBuild=NO;if(![self buildInstancesForSnapshot:snapshot data:instances]||_atlasResetDuringBuild){[self fail:@"glyph atlas overflow" code:7];return;}}
#if TERMATICA_BENCHMARKS
    NSUInteger colorGlyphCount=0,fallbackGlyphCount=0;if(_validatePixels){const TMetalInstance *builtInstances=instances.bytes;for(NSUInteger index=0;index<instances.length/sizeof(TMetalInstance);index++){colorGlyphCount+=(builtInstances[index].kind&0xFF)==3;fallbackGlyphCount+=(builtInstances[index].kind&0x100)!=0;}}
#endif
    id<MTLBuffer> buffer=[_device newBufferWithBytes:instances.bytes length:MAX((NSUInteger)1,instances.length) options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command=[_commandQueue commandBuffer];if(!buffer||!command){[self fail:@"Metal command allocation failed" code:8];return;}
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder){[self fail:@"Metal command encoder failed" code:9];return;}
    vector_float2 viewport={(float)snapshot.metrics.viewportWidth,(float)snapshot.metrics.viewportHeight};
    [encoder setRenderPipelineState:_pipeline];[encoder setVertexBuffer:buffer offset:0 atIndex:0];[encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:1];[encoder setFragmentTexture:_atlasTexture atIndex:0];[encoder setFragmentTexture:_colorAtlasTexture atIndex:1];
    NSUInteger count=instances.length/sizeof(TMetalInstance);if(count)[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:count];
    for(NSNumber *key in snapshot.images){
        CGImageRef image=(__bridge CGImageRef)snapshot.images[key];if(!image)continue;NSError *textureError=nil;
        id<MTLTexture> texture=[self textureForImage:image error:&textureError];if(!texture){[encoder endEncoding];[self fail:textureError.localizedDescription?:@"Metal image texture failed" code:10];return;}
        NSUInteger value=key.unsignedIntegerValue,row=value>>16,column=value&0xFFFF;TMetalInstance imageInstance={{[snapshot.style[@"left"] floatValue]+column*snapshot.metrics.cellWidth,[snapshot.style[@"top"] floatValue]+row*snapshot.metrics.cellHeight},{CGImageGetWidth(image),CGImageGetHeight(image)},{0,0},{1,1},0xFFFFFFFFu,2};
        [encoder setVertexBytes:&imageInstance length:sizeof(imageInstance) atIndex:0];[encoder setFragmentTexture:texture atIndex:2];[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:1];
    }
    [encoder endEncoding];
    id<MTLBuffer> readback=nil;NSUInteger readbackWidth=0,readbackHeight=0,readbackStride=0;
    if(_validatePixels){readbackWidth=drawable.texture.width;readbackHeight=drawable.texture.height;readbackStride=(readbackWidth*4+255)&~(NSUInteger)255;readback=[_device newBufferWithLength:readbackStride*readbackHeight options:MTLResourceStorageModeShared];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];if(readback&&blit){[blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(readbackWidth,readbackHeight,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:readbackStride destinationBytesPerImage:readbackStride*readbackHeight];[blit endEncoding];}}
    [command presentDrawable:drawable];uint64_t generation=snapshot.generation;double cpuMilliseconds=(CFAbsoluteTimeGetCurrent()-cpuStart)*1000.0;__weak typeof(self) weakSelf=self;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){
        __strong typeof(weakSelf) self=weakSelf;if(!self)return;
        if(completed.status==MTLCommandBufferStatusError){[self fail:completed.error.localizedDescription?:@"Metal command buffer failed" code:11];return;}
        uint64_t checksum=1469598103934665603ULL;BOOL varied=NO;
#if TERMATICA_BENCHMARKS
        NSData *pixels=nil;
#endif
        if(readback){const uint8_t *bytes=readback.contents;uint32_t first=0;if(readbackWidth&&readbackHeight)memcpy(&first,bytes,4);for(NSUInteger y=0;y<readbackHeight;y++){const uint8_t *row=bytes+y*readbackStride;for(NSUInteger x=0;x<readbackWidth*4;x++){checksum^=row[x];checksum*=1099511628211ULL;}for(NSUInteger x=0;x<readbackWidth;x++){uint32_t pixel=0;memcpy(&pixel,row+x*4,4);if(pixel!=first){varied=YES;break;}}}
#if TERMATICA_BENCHMARKS
            pixels=[NSData dataWithBytes:bytes length:readbackStride*readbackHeight];
#endif
        }
        double gpuMilliseconds=completed.GPUEndTime>completed.GPUStartTime?(completed.GPUEndTime-completed.GPUStartTime)*1000.0:0;
        @synchronized(self->_stateLock){self.lastPresentedGeneration=MAX(self.lastPresentedGeneration,generation);self.lastCPUEncodeMilliseconds=cpuMilliseconds;self.lastGPUExecutionMilliseconds=gpuMilliseconds;if(self->_lastCommandBuffer==completed)self->_lastCommandBuffer=nil;if(readback){self.lastFrameChecksum=checksum;self.lastFrameVariedPixels=varied;
#if TERMATICA_BENCHMARKS
            self.lastFramePixels=pixels;self.lastFramePixelWidth=readbackWidth;self.lastFramePixelHeight=readbackHeight;self.lastFrameBytesPerRow=readbackStride;self.lastFrameColorGlyphCount=colorGlyphCount;self.lastFrameFallbackGlyphCount=fallbackGlyphCount;
#endif
        }}
    }];@synchronized(_stateLock){_lastCommandBuffer=command;}[command commit];
}

- (void)drainSnapshots {
    while(YES){TRenderSnapshot *snapshot=nil;@synchronized(_stateLock){snapshot=_pendingSnapshot;_pendingSnapshot=nil;if(!snapshot){_renderScheduled=NO;return;}}if(snapshot.generation<=self.lastPresentedGeneration)continue;@autoreleasepool{[self renderSnapshot:snapshot];}}
}

- (void)presentSnapshot:(TRenderSnapshot *)snapshot {
    if(!snapshot.isValid||_stopped)return;
    @synchronized(_stateLock){if(snapshot.generation<=self.lastPresentedGeneration)return;if(!_pendingSnapshot||snapshot.generation>=_pendingSnapshot.generation)_pendingSnapshot=snapshot;if(_renderScheduled)return;_renderScheduled=YES;}
    dispatch_async(_renderQueue,^{[self drainSnapshots];});
}

- (void)shutdown {
    @synchronized(_stateLock){_stopped=YES;_pendingSnapshot=nil;}
    void (^drain)(void)=^{[self waitForAtlasSafety];[self removeAllImageTextures];[self resetAtlas];if(self->_memoryPressureSource){dispatch_source_set_event_handler(self->_memoryPressureSource,^{});dispatch_source_cancel(self->_memoryPressureSource);self->_memoryPressureSource=nil;}};
    if(dispatch_get_specific(TMetalRenderQueueKey)==(__bridge void *)self)drain();else dispatch_sync(_renderQueue,drain);
    if(NSThread.isMainThread){_metalLayer.hidden=YES;[_metalLayer removeFromSuperlayer];}else dispatch_async(dispatch_get_main_queue(),^{self->_metalLayer.hidden=YES;[self->_metalLayer removeFromSuperlayer];});
}
@end
