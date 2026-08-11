#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "TerminalCore.h"

@interface TMetalRenderBackend : NSObject <TRenderBackend>
@property(nonatomic,copy) void (^failureHandler)(NSError *error);
@property(nonatomic,copy) void (^redrawRequested)(void);
@property(nonatomic,readonly) CALayer *presentationLayer;
@property(nonatomic,readonly) uint64_t lastFrameChecksum;
@property(nonatomic,readonly) BOOL lastFrameVariedPixels;
@property(nonatomic,readonly) double lastCPUEncodeMilliseconds;
@property(nonatomic,readonly) double lastGPUExecutionMilliseconds;
@property(nonatomic,readonly) double lastSnapshotWaitMilliseconds;
@property(nonatomic,readonly) double lastGPUCompletionMilliseconds;
@property(nonatomic,readonly) double lastPresentIntervalMilliseconds;
- (instancetype)initWithHostView:(NSView *)view error:(NSError **)error;
- (void)setPresentationFrame:(CGRect)frame scale:(CGFloat)scale;
- (void)requestImmediatePresentation;
#if TERMATICA_BENCHMARKS
- (NSDictionary *)validationFrameCapture;
- (NSDictionary *)cacheDiagnostics;
- (NSDictionary *)schedulerDiagnostics;
- (void)purgeCachesForValidation;
#endif
@end
