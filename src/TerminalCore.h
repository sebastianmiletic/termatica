#import <Foundation/Foundation.h>

typedef struct {
    uint32_t ch:24;
    uint32_t flags:8;
    uint32_t fg;
    uint32_t bg;
} TCell;

_Static_assert(sizeof(TCell)==12,"terminal cells must remain compact");

FOUNDATION_EXPORT NSUInteger TAppendUTF16(unichar *buffer,NSUInteger length,uint32_t codepoint);
FOUNDATION_EXPORT BOOL TUnicodeCombining(uint32_t codepoint);
FOUNDATION_EXPORT BOOL TUnicodeRegional(uint32_t codepoint);
FOUNDATION_EXPORT BOOL TUnicodeWide(uint32_t codepoint);

typedef void (^TASCIIHandler)(const uint8_t *bytes,NSUInteger length);
typedef void (^TCodepointHandler)(uint32_t codepoint);
typedef void (^TControlHandler)(uint8_t control);
typedef void (^TEscapeHandler)(uint8_t finalByte);
typedef void (^TCSIHandler)(uint8_t finalByte,uint8_t prefix,const int *parameters,NSUInteger count);
typedef void (^TOSCHandler)(NSString *value);

@interface TTerminalDecoder : NSObject
- (void)consumeData:(const uint8_t *)bytes length:(NSUInteger)length
               ascii:(TASCIIHandler)ascii
           codepoint:(TCodepointHandler)codepoint
             control:(TControlHandler)control
              escape:(TEscapeHandler)escape
                 csi:(TCSIHandler)csi
                 osc:(TOSCHandler)osc;
- (void)reset;
@end
