#import "MetalRenderer.h"
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>
#import <simd/simd.h>

enum { TMetalAtlasSize = 768 };
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

static void TMetalAppendUnderline(NSMutableData *data,CGFloat x,CGFloat y,CGFloat width,uint8_t style,uint32_t color) {
    CGFloat thickness=style==2?2:1;if(style<=2){TMetalAppendQuad(data,x,y-thickness,width,thickness,0,0,0,0,color,0);return;}
    CGFloat position=0;while(position<width){CGFloat length=style==4?1:(style==5&&fmod(position,9)>=6?1:4);length=MIN(length,width-position);TMetalAppendQuad(data,x+position,y-thickness,length,thickness,0,0,0,0,color,0);position+=style==4?3:(style==5?(length==1?3:6):6);}
}

@interface TMetalRenderBackend ()
@property(nonatomic,readwrite) uint64_t lastPresentedGeneration;
@property(nonatomic,readwrite) uint64_t lastFrameChecksum;
@property(nonatomic,readwrite) BOOL lastFrameVariedPixels;
@property(nonatomic,readwrite) double lastCPUEncodeMilliseconds;
@property(nonatomic,readwrite) double lastGPUExecutionMilliseconds;
@end

@implementation TMetalRenderBackend {
    __weak NSView *_hostView;
    CAMetalLayer *_metalLayer;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _atlasTexture;
    dispatch_queue_t _renderQueue;
    NSObject *_stateLock;
    TRenderSnapshot *_pendingSnapshot;
    BOOL _renderScheduled;
    BOOL _stopped;
    TRenderMetrics _metrics;
    NSMutableDictionary<NSString *,NSValue *> *_glyphs;
    uint8_t *_atlasBytes;
    NSUInteger _atlasX;
    NSUInteger _atlasY;
    NSUInteger _atlasRowHeight;
    BOOL _atlasResetDuringBuild;
    BOOL _validatePixels;
    NSValue *_asciiGlyphs[3][128];
    id<MTLCommandBuffer> _lastCommandBuffer;
}

- (NSString *)name {return @"metal";}
- (CALayer *)presentationLayer {return _metalLayer;}

- (instancetype)initWithHostView:(NSView *)view error:(NSError **)error {
    if(!(self=[super init]))return nil;
    _hostView=view;_stateLock=[NSObject new];_glyphs=[NSMutableDictionary dictionary];
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
    "fragment float4 tf(O i[[stage_in]],texture2d<float> t[[texture(0)]]){constexpr sampler s(coord::normalized,filter::linear);"
    "if(i.k==0)return i.c;float4 p=t.sample(s,i.u);if(i.k==1)return float4(i.c.rgb,i.c.a*p.r);return p*i.c;}";
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
    atlasDescriptor.usage=MTLTextureUsageShaderRead;_atlasTexture=[_device newTextureWithDescriptor:atlasDescriptor];
    _atlasBytes=calloc(TMetalAtlasSize*TMetalAtlasSize,1);
    if(!_atlasTexture||!_atlasBytes){if(error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Metal glyph atlas allocation failed"}];return nil;}
    _renderQueue=dispatch_queue_create("com.termatica.metal-render",DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
    _validatePixels=getenv("TERMATICA_METAL_VALIDATE_PIXELS")!=NULL;
    _metalLayer=[CAMetalLayer layer];_metalLayer.device=_device;_metalLayer.pixelFormat=MTLPixelFormatBGRA8Unorm;_metalLayer.framebufferOnly=!_validatePixels;_metalLayer.maximumDrawableCount=2;_metalLayer.allowsNextDrawableTimeout=YES;_metalLayer.opaque=NO;_metalLayer.hidden=YES;
    [view.layer addSublayer:_metalLayer];
    [self resetAtlas];
    return self;
}

- (void)dealloc {free(_atlasBytes);}

- (void)waitForAtlasSafety {
    id<MTLCommandBuffer> command=nil;@synchronized(_stateLock){command=_lastCommandBuffer;}
    if(command&&command.status<MTLCommandBufferStatusCompleted)[command waitUntilCompleted];
    @synchronized(_stateLock){if(_lastCommandBuffer==command)_lastCommandBuffer=nil;}
}

- (void)resetAtlas {
    [self waitForAtlasSafety];
    [_glyphs removeAllObjects];memset(_asciiGlyphs,0,sizeof(_asciiGlyphs));memset(_atlasBytes,0,TMetalAtlasSize*TMetalAtlasSize);
    _atlasX=1;_atlasY=1;_atlasRowHeight=0;
    MTLRegion region=MTLRegionMake2D(0,0,TMetalAtlasSize,TMetalAtlasSize);
    [_atlasTexture replaceRegion:region mipmapLevel:0 withBytes:_atlasBytes bytesPerRow:TMetalAtlasSize];
}

- (void)setPresentationFrame:(CGRect)frame scale:(CGFloat)scale {
    if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf setPresentationFrame:frame scale:scale];});return;}
    [CATransaction begin];[CATransaction setDisableActions:YES];_metalLayer.frame=frame;_metalLayer.contentsScale=MAX(1,scale);_metalLayer.drawableSize=CGSizeMake(MAX(1,frame.size.width*scale),MAX(1,frame.size.height*scale));[CATransaction commit];
}

- (BOOL)configureWithMetrics:(TRenderMetrics)metrics error:(NSError **)error {
    if(metrics.rows==0||metrics.columns==0||metrics.viewportWidth<=0||metrics.viewportHeight<=0){if(error)*error=[NSError errorWithDomain:@"TermaticaMetal" code:5 userInfo:@{NSLocalizedDescriptionKey:@"invalid render metrics"}];return NO;}
    _metrics=metrics;
    dispatch_async(dispatch_get_main_queue(),^{[self setPresentationFrame:CGRectMake(0,0,metrics.viewportWidth,metrics.viewportHeight) scale:metrics.scale];});
    return YES;
}

- (void)invalidateCaches {
    dispatch_async(_renderQueue,^{[self resetAtlas];});
}

- (void)fail:(NSString *)message code:(NSInteger)code {
    void (^handler)(NSError *)=self.failureHandler;if(!handler)return;
    NSError *error=[NSError errorWithDomain:@"TermaticaMetal" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    dispatch_async(dispatch_get_main_queue(),^{handler(error);});
}

- (NSValue *)glyphForText:(NSString *)text font:(NSFont *)font width:(NSUInteger)width height:(NSUInteger)height scale:(CGFloat)scale slot:(NSUInteger)slot {
    NSUInteger pixelWidth=MAX((NSUInteger)1,MIN((NSUInteger)TMetalAtlasSize-2,(NSUInteger)ceil(width*scale)));
    NSUInteger pixelHeight=MAX((NSUInteger)1,MIN((NSUInteger)TMetalAtlasSize-2,(NSUInteger)ceil(height*scale)));
    unichar asciiCharacter=text.length==1?[text characterAtIndex:0]:128;BOOL ascii=asciiCharacter<128&&slot<3;NSValue *cached=ascii?_asciiGlyphs[slot][asciiCharacter]:nil;NSString *key=nil;if(!ascii){key=[NSString stringWithFormat:@"%@|%.3f|%lu|%lu|%@",font.fontName,font.pointSize,(unsigned long)pixelWidth,(unsigned long)pixelHeight,text];cached=_glyphs[key];}if(cached)return cached;
    if(_atlasX+pixelWidth+1>TMetalAtlasSize){_atlasX=1;_atlasY+=_atlasRowHeight+1;_atlasRowHeight=0;}
    if(_atlasY+pixelHeight+1>TMetalAtlasSize){[self resetAtlas];_atlasResetDuringBuild=YES;}
    if(_atlasX+pixelWidth+1>TMetalAtlasSize||_atlasY+pixelHeight+1>TMetalAtlasSize)return nil;
    [self waitForAtlasSafety];
    uint8_t *glyph=calloc(pixelWidth*pixelHeight,1);if(!glyph)return nil;
    CGContextRef context=CGBitmapContextCreate(glyph,pixelWidth,pixelHeight,8,pixelWidth,NULL,(CGBitmapInfo)kCGImageAlphaOnly);
    if(!context){free(glyph);return nil;}
    CGContextSetShouldAntialias(context,true);CGContextSetAllowsAntialiasing(context,true);
    CGContextTranslateCTM(context,0,pixelHeight);CGContextScaleCTM(context,scale,-scale);
    NSDictionary *attributes=@{(__bridge NSString *)kCTFontAttributeName:font,(__bridge NSString *)kCTForegroundColorAttributeName:NSColor.whiteColor};
    NSAttributedString *attributed=[[NSAttributedString alloc]initWithString:text attributes:attributes];
    CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    CGFloat baseline=MAX(1,font.ascender+1);CGContextSetTextPosition(context,0,baseline);CTLineDraw(line,context);CFRelease(line);CGContextRelease(context);
    for(NSUInteger row=0;row<pixelHeight;row++)memcpy(_atlasBytes+(_atlasY+row)*TMetalAtlasSize+_atlasX,glyph+row*pixelWidth,pixelWidth);
    MTLRegion region=MTLRegionMake2D(_atlasX,_atlasY,pixelWidth,pixelHeight);
    [_atlasTexture replaceRegion:region mipmapLevel:0 withBytes:glyph bytesPerRow:pixelWidth];free(glyph);
    CGRect rect=CGRectMake((CGFloat)_atlasX/TMetalAtlasSize,(CGFloat)_atlasY/TMetalAtlasSize,(CGFloat)pixelWidth/TMetalAtlasSize,(CGFloat)pixelHeight/TMetalAtlasSize);
    cached=[NSValue valueWithRect:NSRectFromCGRect(rect)];if(ascii)_asciiGlyphs[slot][asciiCharacter]=cached;else _glyphs[key]=cached;_atlasX+=pixelWidth+1;_atlasRowHeight=MAX(_atlasRowHeight,pixelHeight);
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
            CGRect uv=NSRectToCGRect(glyph.rectValue);CGFloat glyphX=left+x*cellWidth,glyphY=top+y*cellHeight,glyphWidth=cellWidth*span;
            if(glow>0){uint32_t glowColor=TMetalRGBA(accent,MIN(0.45,glow*0.32));for(NSInteger oy=-1;oy<=1;oy++)for(NSInteger ox=-1;ox<=1;ox++)if(ox||oy)TMetalAppendQuad(instances,glyphX+ox,glyphY+oy,glyphWidth,cellHeight,uv.origin.x,uv.origin.y,CGRectGetMaxX(uv),CGRectGetMaxY(uv),glowColor,1);}
            TMetalAppendQuad(instances,glyphX,glyphY,glyphWidth,cellHeight,uv.origin.x,uv.origin.y,CGRectGetMaxX(uv),CGRectGetMaxY(uv),TMetalRGBA(fg,1),1);
            if((cell.flags&TMetalUnderline)||links[index]){
                TMetalAppendUnderline(instances,glyphX,top+(y+1)*cellHeight,glyphWidth,MAX((uint8_t)1,underlines[index]),TMetalRGBA(fg,1));
            }
        }
    }
    if(snapshot.cursorVisible){
        NSString *cursorStyle=style[@"cursorStyle"]?:@"block";CGFloat width=cellWidth,height=cellHeight,x=left+snapshot.cursorX*cellWidth,y=top+snapshot.cursorY*cellHeight;
        if([cursorStyle isEqual:@"bar"])width=2;else if([cursorStyle isEqual:@"underline"]){height=2;y+=cellHeight-2;}
        CGFloat alpha=[style[@"cursorFocused"] boolValue]?([cursorStyle isEqual:@"block"]?0.42:0.96):([cursorStyle isEqual:@"block"]?0.2:0.5);
        TMetalAppendQuad(instances,x,y,width,height,0,0,0,0,TMetalRGBA(cursor,alpha),0);
    }
    CGFloat scanlines=[style[@"scanlines"] doubleValue];if(scanlines>0)for(CGFloat y=2;y<snapshot.metrics.viewportHeight;y+=4)TMetalAppendQuad(instances,0,y,snapshot.metrics.viewportWidth,1,0,0,0,0,TMetalRGBA(0,scanlines*0.10),0);
    CGFloat vignette=[style[@"vignette"] doubleValue];if(vignette>0&&![style[@"tiled"] boolValue])for(NSUInteger i=0;i<6;i++){CGFloat alpha=vignette*(6-i)/30.0,w=snapshot.metrics.viewportWidth-i*2,h=snapshot.metrics.viewportHeight-i*2;TMetalAppendQuad(instances,i,i,w,1,0,0,0,0,TMetalRGBA(0,alpha),0);TMetalAppendQuad(instances,i,i+h-1,w,1,0,0,0,0,TMetalRGBA(0,alpha),0);TMetalAppendQuad(instances,i,i,1,h,0,0,0,0,TMetalRGBA(0,alpha),0);TMetalAppendQuad(instances,i+w-1,i,1,h,0,0,0,0,TMetalRGBA(0,alpha),0);}
    if(snapshot.historyCount&&snapshot.historyOffset>0){CGFloat track=MAX(1,snapshot.metrics.viewportHeight-12),total=snapshot.historyCount+rows,thumb=MAX(24,track*rows/MAX((CGFloat)rows,total)),progress=(CGFloat)snapshot.historyOffset/MAX(1,(CGFloat)snapshot.historyCount),y=6+(track-thumb)*(1-progress);TMetalAppendQuad(instances,snapshot.metrics.viewportWidth-5,y,2.5,thumb,0,0,0,0,TMetalRGBA(foreground,0.42),0);}
    return YES;
}

- (id<MTLTexture>)textureForImage:(CGImageRef)image error:(NSError **)error {
    NSUInteger width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    if(!width||!height||width>16384||height>16384){
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
    id<MTLBuffer> buffer=[_device newBufferWithBytes:instances.bytes length:MAX((NSUInteger)1,instances.length) options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command=[_commandQueue commandBuffer];if(!buffer||!command){[self fail:@"Metal command allocation failed" code:8];return;}
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder){[self fail:@"Metal command encoder failed" code:9];return;}
    vector_float2 viewport={(float)snapshot.metrics.viewportWidth,(float)snapshot.metrics.viewportHeight};
    [encoder setRenderPipelineState:_pipeline];[encoder setVertexBuffer:buffer offset:0 atIndex:0];[encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:1];[encoder setFragmentTexture:_atlasTexture atIndex:0];
    NSUInteger count=instances.length/sizeof(TMetalInstance);if(count)[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:count];
    for(NSNumber *key in snapshot.images){
        CGImageRef image=(__bridge CGImageRef)snapshot.images[key];if(!image)continue;NSError *textureError=nil;
        id<MTLTexture> texture=[self textureForImage:image error:&textureError];if(!texture){[encoder endEncoding];[self fail:textureError.localizedDescription?:@"Metal image texture failed" code:10];return;}
        NSUInteger value=key.unsignedIntegerValue,row=value>>16,column=value&0xFFFF;TMetalInstance imageInstance={{[snapshot.style[@"left"] floatValue]+column*snapshot.metrics.cellWidth,[snapshot.style[@"top"] floatValue]+row*snapshot.metrics.cellHeight},{CGImageGetWidth(image),CGImageGetHeight(image)},{0,0},{1,1},0xFFFFFFFFu,2};
        [encoder setVertexBytes:&imageInstance length:sizeof(imageInstance) atIndex:0];[encoder setFragmentTexture:texture atIndex:0];[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:1];
    }
    [encoder endEncoding];
    id<MTLBuffer> readback=nil;NSUInteger readbackWidth=0,readbackHeight=0,readbackStride=0;
    if(_validatePixels){readbackWidth=drawable.texture.width;readbackHeight=drawable.texture.height;readbackStride=(readbackWidth*4+255)&~(NSUInteger)255;readback=[_device newBufferWithLength:readbackStride*readbackHeight options:MTLResourceStorageModeShared];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];if(readback&&blit){[blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(readbackWidth,readbackHeight,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:readbackStride destinationBytesPerImage:readbackStride*readbackHeight];[blit endEncoding];}}
    [command presentDrawable:drawable];uint64_t generation=snapshot.generation;double cpuMilliseconds=(CFAbsoluteTimeGetCurrent()-cpuStart)*1000.0;__weak typeof(self) weakSelf=self;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){__strong typeof(weakSelf) self=weakSelf;if(!self)return;if(completed.status==MTLCommandBufferStatusError){[self fail:completed.error.localizedDescription?:@"Metal command buffer failed" code:11];return;}uint64_t checksum=1469598103934665603ULL;BOOL varied=NO;if(readback){const uint8_t *bytes=readback.contents;uint32_t first=0;if(readbackWidth&&readbackHeight)memcpy(&first,bytes,4);for(NSUInteger y=0;y<readbackHeight;y++){const uint8_t *row=bytes+y*readbackStride;for(NSUInteger x=0;x<readbackWidth*4;x++){checksum^=row[x];checksum*=1099511628211ULL;}for(NSUInteger x=0;x<readbackWidth;x++){uint32_t pixel=0;memcpy(&pixel,row+x*4,4);if(pixel!=first){varied=YES;break;}}}}double gpuMilliseconds=completed.GPUEndTime>completed.GPUStartTime?(completed.GPUEndTime-completed.GPUStartTime)*1000.0:0;@synchronized(self->_stateLock){self.lastPresentedGeneration=MAX(self.lastPresentedGeneration,generation);self.lastCPUEncodeMilliseconds=cpuMilliseconds;self.lastGPUExecutionMilliseconds=gpuMilliseconds;if(self->_lastCommandBuffer==completed)self->_lastCommandBuffer=nil;if(readback){self.lastFrameChecksum=checksum;self.lastFrameVariedPixels=varied;}}}];@synchronized(_stateLock){_lastCommandBuffer=command;}[command commit];
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
    if(NSThread.isMainThread){_metalLayer.hidden=YES;[_metalLayer removeFromSuperlayer];}else dispatch_async(dispatch_get_main_queue(),^{self->_metalLayer.hidden=YES;[self->_metalLayer removeFromSuperlayer];});
}
@end
