#import <Foundation/Foundation.h>
#include <stddef.h>

typedef struct {
    uint32_t ch:24;
    uint32_t flags:8;
    uint32_t fg;
    uint32_t bg;
} TCell;

_Static_assert(sizeof(TCell)==12,"terminal cells must remain compact");

typedef struct {
    NSUInteger rows;
    NSUInteger columns;
    double cellWidth;
    double cellHeight;
    double scale;
} TRenderMetrics;

@interface TRenderSnapshot : NSObject
@property(nonatomic,readonly) uint64_t generation;
@property(nonatomic,readonly) TRenderMetrics metrics;
@property(nonatomic,readonly) NSData *cells;
@property(nonatomic,readonly) NSData *underlineStyles;
@property(nonatomic,readonly) NSDictionary<NSNumber *,NSString *> *links;
@property(nonatomic,readonly) NSDictionary<NSNumber *,id> *images;
@property(nonatomic,readonly) NSUInteger cursorX;
@property(nonatomic,readonly) NSUInteger cursorY;
@property(nonatomic,readonly) BOOL cursorVisible;
@property(nonatomic,readonly) BOOL fullDamage;
@property(nonatomic,readonly) NSRange damagedRows;
- (instancetype)initWithGeneration:(uint64_t)generation
                           metrics:(TRenderMetrics)metrics
                             cells:(NSData *)cells
                   underlineStyles:(NSData *)underlineStyles
                             links:(NSDictionary<NSNumber *,NSString *> *)links
                            images:(NSDictionary<NSNumber *,id> *)images
                           cursorX:(NSUInteger)cursorX
                           cursorY:(NSUInteger)cursorY
                     cursorVisible:(BOOL)cursorVisible
                        fullDamage:(BOOL)fullDamage
                       damagedRows:(NSRange)damagedRows;
@end

@protocol TRenderBackend <NSObject>
- (BOOL)configureWithMetrics:(TRenderMetrics)metrics error:(NSError **)error;
- (void)presentSnapshot:(TRenderSnapshot *)snapshot;
- (void)invalidateCaches;
- (void)shutdown;
@end

FOUNDATION_EXPORT NSUInteger TAppendUTF16(unichar *buffer,NSUInteger length,uint32_t codepoint);
FOUNDATION_EXPORT BOOL TUnicodeCombining(uint32_t codepoint);
FOUNDATION_EXPORT BOOL TUnicodeRegional(uint32_t codepoint);
FOUNDATION_EXPORT BOOL TUnicodeWide(uint32_t codepoint);

typedef struct {
    int state;
    int parameters[20];
    NSUInteger parameterIndex;
    uint8_t prefix;
    uint32_t utf8Code;
    int utf8Needed;
    uint8_t *stringBytes;
    size_t stringLength;
    size_t stringCapacity;
    uint32_t codepointBuffer[512];
    size_t codepointCount;
} TDecoderState;

typedef struct {
    void *context;
    void (*ascii)(void *context,const uint8_t *bytes,size_t length);
    void (*codepoint)(void *context,uint32_t codepoint);
    void (*codepoints)(void *context,const uint32_t *codepoints,size_t count);
    void (*control)(void *context,uint8_t control);
    void (*escape)(void *context,uint8_t finalByte);
    void (*csi)(void *context,uint8_t finalByte,uint8_t prefix,const int *parameters,size_t count);
    void (*string)(void *context,const uint8_t *bytes,size_t length);
} TDecoderSink;

FOUNDATION_EXPORT void TDecoderInit(TDecoderState *decoder);
FOUNDATION_EXPORT void TDecoderReset(TDecoderState *decoder);
FOUNDATION_EXPORT void TDecoderDestroy(TDecoderState *decoder);
FOUNDATION_EXPORT void TDecoderConsume(TDecoderState *decoder,const uint8_t *bytes,size_t length,const TDecoderSink *sink);
