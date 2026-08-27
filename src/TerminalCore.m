#import "TerminalCore.h"

enum { TDecodeText, TDecodeEscape, TDecodeCSI, TDecodeOSC, TDecodeOSCEscape, TDecodeDCS, TDecodeDCSEscape, TDecodeIgnoredOSC, TDecodeIgnoredOSCEscape };
enum { TDecoderStringLimit = 1398208 };

@implementation TRenderSnapshot
- (instancetype)initWithGeneration:(uint64_t)generation metrics:(TRenderMetrics)metrics cells:(NSData *)cells underlineStyles:(NSData *)underlineStyles selectionMask:(NSData *)selectionMask searchMask:(NSData *)searchMask linkMask:(NSData *)linkMask graphemes:(NSArray<NSString *> *)graphemes style:(NSDictionary<NSString *,id> *)style links:(NSDictionary<NSNumber *,NSString *> *)links images:(NSDictionary<NSNumber *,id> *)images cursorX:(NSUInteger)cursorX cursorY:(NSUInteger)cursorY cursorVisible:(BOOL)cursorVisible historyCount:(NSUInteger)historyCount historyOffset:(NSInteger)historyOffset fullDamage:(BOOL)fullDamage damagedRows:(NSRange)damagedRows {
    if((self=[super init])){_generation=generation;_metrics=metrics;_cells=cells?:NSData.data;_underlineStyles=underlineStyles?:NSData.data;_selectionMask=selectionMask?:NSData.data;_searchMask=searchMask?:NSData.data;_linkMask=linkMask?:NSData.data;_graphemes=[graphemes copy]?:@[];_style=style?:@{};_links=[links copy]?:@{};_images=[images copy]?:@{};_cursorX=cursorX;_cursorY=cursorY;_cursorVisible=cursorVisible;_historyCount=historyCount;_historyOffset=historyOffset;_fullDamage=fullDamage;_damagedRows=damagedRows;}
    return self;
}
- (BOOL)isValid {
    NSUInteger count=_metrics.rows*_metrics.columns;
    if(!_generation||!_metrics.rows||!_metrics.columns||_metrics.cellWidth<=0||_metrics.cellHeight<=0||_metrics.scale<=0||_metrics.viewportWidth<=0||_metrics.viewportHeight<=0)return NO;
    if(_cells.length!=count*sizeof(TCell)||_underlineStyles.length!=count||_selectionMask.length!=count||_searchMask.length!=count||_linkMask.length!=count)return NO;
    if(_cursorX>=_metrics.columns||_cursorY>=_metrics.rows)return NO;
    if(_damagedRows.length&&NSMaxRange(_damagedRows)>_metrics.rows)return NO;
    return YES;
}
@end

NSUInteger TAppendUTF16(unichar *buffer,NSUInteger length,uint32_t codepoint) {
    if(!codepoint)codepoint=' ';
    if(codepoint<=0xFFFF){buffer[length++]=(unichar)codepoint;return length;}
    if(codepoint>0x10FFFF)codepoint=0xFFFD;
    uint32_t value=codepoint-0x10000;
    buffer[length++]=(unichar)(0xD800+(value>>10));
    buffer[length++]=(unichar)(0xDC00+(value&0x3FF));
    return length;
}

typedef struct {uint32_t first,last;} TUnicodeRange;

static inline BOOL TUnicodeInRanges(uint32_t cp,const TUnicodeRange *ranges,size_t count) {
    size_t low=0,high=count;
    while(low<high){size_t middle=low+(high-low)/2;TUnicodeRange range=ranges[middle];if(cp<range.first)high=middle;else if(cp>range.last)low=middle+1;else return YES;}
    return NO;
}

BOOL TUnicodeCombining(uint32_t cp) {
    static const TUnicodeRange ranges[]={
        {0x0300,0x036F},{0x0483,0x0489},{0x0591,0x05BD},{0x05BF,0x05C7},{0x0610,0x061A},{0x064B,0x065F},{0x0670,0x0670},{0x06D6,0x06ED},
        {0x0711,0x0711},{0x0730,0x074A},{0x07A6,0x07B0},{0x07EB,0x07F3},{0x0816,0x082D},{0x08D3,0x0903},{0x093A,0x094F},{0x0981,0x09CD},
        {0x0A01,0x0A4D},{0x0A81,0x0ACD},{0x0B01,0x0BCD},{0x0C00,0x0CCD},{0x0D00,0x0D4D},{0x0E31,0x0E4E},{0x0EB1,0x0ECD},{0x0F18,0x0FBC},
        {0x102B,0x103E},{0x17B4,0x17D3},{0x1AB0,0x1AFF},{0x1DC0,0x1DFF},{0x200D,0x200D},{0x20D0,0x20FF},{0xFE00,0xFE0F},{0xFE20,0xFE2F},
        {0x1F3FB,0x1F3FF},{0xE0020,0xE007F},{0xE0100,0xE01EF}
    };
    return TUnicodeInRanges(cp,ranges,sizeof(ranges)/sizeof(ranges[0]));
}

BOOL TUnicodeRegional(uint32_t cp){return cp>=0x1F1E6&&cp<=0x1F1FF;}

BOOL TUnicodeWide(uint32_t cp) {
    if(cp<0x1100)return NO;
    if(cp>=0x2E80&&cp<=0xA4CF)return cp!=0x303F;
    if(cp>=0x1F000&&cp<=0x1FAFF)return YES;
    static const TUnicodeRange ranges[]={{0x1100,0x115F},{0x2329,0x232A},{0x2E80,0xA4CF},{0xAC00,0xD7A3},{0xF900,0xFAFF},{0xFE10,0xFE19},{0xFE30,0xFE6F},{0xFF00,0xFF60},{0xFFE0,0xFFE6},{0x1F000,0x1FAFF},{0x20000,0x3FFFD}};
    return cp!=0x303F&&TUnicodeInRanges(cp,ranges,sizeof(ranges)/sizeof(ranges[0]));
}

NSUInteger TBlockElementRects(uint32_t cp,TBlockElementRect rectangles[2]) {
    if(!rectangles)return 0;
    if(cp==0x2580){rectangles[0]=(TBlockElementRect){0,0,1,0.5};return 1;}
    if(cp>=0x2581&&cp<=0x2588){double fraction=(double)(cp-0x2580)/8.0;rectangles[0]=(TBlockElementRect){0,1-fraction,1,fraction};return 1;}
    if(cp>=0x2589&&cp<=0x258F){double fraction=(double)(0x2590-cp)/8.0;rectangles[0]=(TBlockElementRect){0,0,fraction,1};return 1;}
    if(cp==0x2590){rectangles[0]=(TBlockElementRect){0.5,0,0.5,1};return 1;}
    if(cp==0x2594){rectangles[0]=(TBlockElementRect){0,0,1,0.125};return 1;}
    if(cp==0x2595){rectangles[0]=(TBlockElementRect){0.875,0,0.125,1};return 1;}
    switch(cp){
        case 0x2596: rectangles[0]=(TBlockElementRect){0,0.5,0.5,0.5};return 1;
        case 0x2597: rectangles[0]=(TBlockElementRect){0.5,0.5,0.5,0.5};return 1;
        case 0x2598: rectangles[0]=(TBlockElementRect){0,0,0.5,0.5};return 1;
        case 0x2599: rectangles[0]=(TBlockElementRect){0,0,0.5,1};rectangles[1]=(TBlockElementRect){0.5,0.5,0.5,0.5};return 2;
        case 0x259A: rectangles[0]=(TBlockElementRect){0,0,0.5,0.5};rectangles[1]=(TBlockElementRect){0.5,0.5,0.5,0.5};return 2;
        case 0x259B: rectangles[0]=(TBlockElementRect){0,0,1,0.5};rectangles[1]=(TBlockElementRect){0,0.5,0.5,0.5};return 2;
        case 0x259C: rectangles[0]=(TBlockElementRect){0,0,1,0.5};rectangles[1]=(TBlockElementRect){0.5,0.5,0.5,0.5};return 2;
        case 0x259D: rectangles[0]=(TBlockElementRect){0.5,0,0.5,0.5};return 1;
        case 0x259E: rectangles[0]=(TBlockElementRect){0.5,0,0.5,0.5};rectangles[1]=(TBlockElementRect){0,0.5,0.5,0.5};return 2;
        case 0x259F: rectangles[0]=(TBlockElementRect){0.5,0,0.5,1};rectangles[1]=(TBlockElementRect){0,0.5,0.5,0.5};return 2;
        default:return 0;
    }
}

void TDecoderInit(TDecoderState *decoder) {
    if(!decoder)return;
    memset(decoder,0,sizeof(*decoder));
}

void TDecoderReset(TDecoderState *decoder) {
    if(!decoder)return;
    decoder->state=TDecodeText;
    decoder->parameterIndex=0;
    decoder->prefix=0;
    decoder->intermediate=0;
    decoder->utf8Code=0;
    decoder->utf8Min=0;
    decoder->utf8Needed=0;
    decoder->stringLength=0;
    decoder->stringDiscarded=false;
    decoder->codepointCount=0;
    memset(decoder->parameters,0,sizeof(decoder->parameters));
}

void TDecoderDestroy(TDecoderState *decoder) {
    if(!decoder)return;
    free(decoder->stringBytes);
    memset(decoder,0,sizeof(*decoder));
}

static inline void TDecoderAppendStringBytes(TDecoderState *decoder,const uint8_t *bytes,size_t length) {
    if(decoder->stringDiscarded||!length)return;
    if(!decoder->stringLength){
        uint8_t first=bytes[0];
        BOOL osc=decoder->state==TDecodeOSC;
        BOOL accepted=osc?(first=='0'||first=='1'||first=='2'||first=='4'||first=='5'||first=='7'||first=='8'||first=='9'||first=='b'||first=='e'):(first=='G'||first=='q');
        if(!accepted){decoder->stringDiscarded=true;return;}
    }
    size_t available=TDecoderStringLimit-decoder->stringLength,take=MIN(available,length);
    if(!take)return;
    size_t required=decoder->stringLength+take;
    if(required>decoder->stringCapacity){
        size_t capacity=decoder->stringCapacity?:256;
        while(capacity<required)capacity=MIN((size_t)TDecoderStringLimit,capacity*2);
        uint8_t *next=realloc(decoder->stringBytes,capacity);
        if(!next)return;
        decoder->stringBytes=next;
        decoder->stringCapacity=capacity;
    }
    memcpy(decoder->stringBytes+decoder->stringLength,bytes,take);
    decoder->stringLength+=take;
}

static inline void TDecoderEmitString(TDecoderState *decoder,const TDecoderSink *sink) {
    if(!decoder->stringDiscarded&&sink->string)sink->string(sink->context,decoder->stringBytes,decoder->stringLength);
    decoder->stringLength=0;
    decoder->stringDiscarded=false;
}

static inline void TDecoderFlushCodepoints(TDecoderState *decoder,const TDecoderSink *sink) {
    if(!decoder->codepointCount)return;
    if(sink->codepoints)sink->codepoints(sink->context,decoder->codepointBuffer,decoder->codepointCount);
    else if(sink->codepoint)for(size_t i=0;i<decoder->codepointCount;i++)sink->codepoint(sink->context,decoder->codepointBuffer[i]);
    decoder->codepointCount=0;
}

static inline void TDecoderEmitCodepoint(TDecoderState *decoder,const TDecoderSink *sink,uint32_t codepoint) {
    decoder->codepointBuffer[decoder->codepointCount++]=codepoint;
    if(decoder->codepointCount==sizeof(decoder->codepointBuffer)/sizeof(decoder->codepointBuffer[0]))TDecoderFlushCodepoints(decoder,sink);
}

static inline const uint8_t *TDecoderFindStringStop(const uint8_t *bytes,size_t length) {
    const uint64_t ones=UINT64_C(0x0101010101010101),highs=UINT64_C(0x8080808080808080),bells=UINT64_C(0x0707070707070707),escapes=UINT64_C(0x1b1b1b1b1b1b1b1b);
    while(length>=8){uint64_t word;memcpy(&word,bytes,8);uint64_t bell=word^bells,escape=word^escapes;if(((bell-ones)&~bell&highs)|((escape-ones)&~escape&highs)){for(size_t i=0;i<8;i++)if(bytes[i]==7||bytes[i]==27)return bytes+i;}bytes+=8;length-=8;}
    while(length){if(*bytes==7||*bytes==27)return bytes;bytes++;length--;}
    return NULL;
}

static inline size_t TDecoderConsumeValidUTF8(TDecoderState *decoder,const uint8_t *bytes,size_t length,const TDecoderSink *sink) {
    size_t index=0;
    while(index<length){
        uint8_t first=bytes[index],second=0,third=0,fourth=0;uint32_t codepoint=0;size_t width=0;
        if(first>=0xC2&&first<=0xDF){width=2;if(length-index<width)break;second=bytes[index+1];if((second&0xC0)!=0x80)break;codepoint=((uint32_t)(first&0x1F)<<6)|(second&0x3F);}
        else if(first>=0xE0&&first<=0xEF){width=3;if(length-index<width)break;second=bytes[index+1];third=bytes[index+2];if((second&0xC0)!=0x80||(third&0xC0)!=0x80||(first==0xE0&&second<0xA0)||(first==0xED&&second>=0xA0))break;codepoint=((uint32_t)(first&0x0F)<<12)|((uint32_t)(second&0x3F)<<6)|(third&0x3F);}
        else if(first>=0xF0&&first<=0xF4){width=4;if(length-index<width)break;second=bytes[index+1];third=bytes[index+2];fourth=bytes[index+3];if((second&0xC0)!=0x80||(third&0xC0)!=0x80||(fourth&0xC0)!=0x80||(first==0xF0&&second<0x90)||(first==0xF4&&second>=0x90))break;codepoint=((uint32_t)(first&7)<<18)|((uint32_t)(second&0x3F)<<12)|((uint32_t)(third&0x3F)<<6)|(fourth&0x3F);}
        else break;
        TDecoderEmitCodepoint(decoder,sink,codepoint);index+=width;
    }
    return index;
}

static inline void TDecoderConsumeTextByte(TDecoderState *decoder,uint8_t byte,const TDecoderSink *sink) {
retry:
    if(byte==27){TDecoderFlushCodepoints(decoder,sink);decoder->state=TDecodeEscape;return;}
    if(byte<32||byte==127){TDecoderFlushCodepoints(decoder,sink);if(sink->control)sink->control(sink->context,byte);return;}
    if(decoder->utf8Needed){
        if((byte&0xC0)!=0x80){
            decoder->utf8Needed=0;
            TDecoderEmitCodepoint(decoder,sink,0xFFFD);
            goto retry;
        }
        decoder->utf8Code=(decoder->utf8Code<<6)|(byte&0x3F);
        if(--decoder->utf8Needed==0){uint32_t codepoint=decoder->utf8Code;TDecoderEmitCodepoint(decoder,sink,(codepoint<decoder->utf8Min||codepoint>0x10FFFF||(codepoint>=0xD800&&codepoint<=0xDFFF))?0xFFFD:codepoint);}
    } else if(byte<0x80) {
        TDecoderEmitCodepoint(decoder,sink,byte);
    } else if(byte>=0xC2&&byte<=0xDF) {
        decoder->utf8Code=byte&0x1F;decoder->utf8Min=0x80;decoder->utf8Needed=1;
    } else if(byte>=0xE0&&byte<=0xEF) {
        decoder->utf8Code=byte&0x0F;decoder->utf8Min=0x800;decoder->utf8Needed=2;
    } else if(byte>=0xF0&&byte<=0xF4) {
        decoder->utf8Code=byte&0x07;decoder->utf8Min=0x10000;decoder->utf8Needed=3;
    } else TDecoderEmitCodepoint(decoder,sink,0xFFFD);
}

void TDecoderConsume(TDecoderState *decoder,const uint8_t *bytes,size_t length,const TDecoderSink *sink) {
    if(!decoder||!bytes||!sink)return;
    for(size_t index=0;index<length;index++){
        uint8_t byte=bytes[index];
        if(decoder->state==TDecodeText&&!decoder->utf8Needed&&byte>=0x80){size_t consumed=TDecoderConsumeValidUTF8(decoder,bytes+index,length-index,sink);if(consumed){index+=consumed-1;continue;}}
        if(decoder->state==TDecodeText&&!decoder->utf8Needed&&byte==27&&index+3<length){
            if(bytes[index+1]==']'&&bytes[index+2]=='6'&&bytes[index+3]==';'){
                size_t cursor=index;
                do {
                    const uint8_t *end=memchr(bytes+cursor+4,7,length-cursor-4);
                    if(!end)break;
                    cursor=(size_t)(end-bytes)+1;
                } while(cursor+3<length&&bytes[cursor]==27&&bytes[cursor+1]==']'&&bytes[cursor+2]=='6'&&bytes[cursor+3]==';');
                if(cursor>index){index=cursor-1;continue;}
            }else if(bytes[index+1]=='_'&&bytes[index+2]=='G'){
                const uint8_t *end=memchr(bytes+index+3,27,length-index-3);
                if(end&&end+1<bytes+length&&end[1]=='\\'){
                    TDecoderFlushCodepoints(decoder,sink);
                    if(sink->string)sink->string(sink->context,bytes+index+2,(size_t)(end-(bytes+index+2)));
                    index=(size_t)(end-bytes)+1;
                    continue;
                }
            }
        }
        if(decoder->state==TDecodeText&&!decoder->utf8Needed&&byte>=32&&byte<127){
            TDecoderFlushCodepoints(decoder,sink);
            size_t start=index;
            while(index+1<length&&bytes[index+1]>=32&&bytes[index+1]<127)index++;
            if(sink->ascii)sink->ascii(sink->context,bytes+start,index-start+1);
            continue;
        }
        if(decoder->state==TDecodeOSC&&!decoder->stringLength&&!decoder->stringDiscarded&&byte=='6'){
            decoder->state=TDecodeIgnoredOSC;
            continue;
        }
        if(decoder->state==TDecodeIgnoredOSC){
            size_t remaining=length-index;const uint8_t *stop=TDecoderFindStringStop(bytes+index,remaining);
            if(!stop){index=length-1;continue;}
            index=(size_t)(stop-bytes);byte=*stop;
            if(byte==7){TDecoderFlushCodepoints(decoder,sink);decoder->state=TDecodeText;}
            else decoder->state=TDecodeIgnoredOSCEscape;
            continue;
        }
        if(decoder->state==TDecodeIgnoredOSCEscape){
            if(byte=='\\'){TDecoderFlushCodepoints(decoder,sink);decoder->state=TDecodeText;}
            else decoder->state=TDecodeIgnoredOSC;
            continue;
        }
        if(decoder->state==TDecodeOSC||decoder->state==TDecodeDCS){
            size_t remaining=length-index;const uint8_t *stop=TDecoderFindStringStop(bytes+index,remaining);
            size_t run=stop?(size_t)(stop-(bytes+index)):remaining;
            if(run){TDecoderAppendStringBytes(decoder,bytes+index,run);index+=run-1;continue;}
        }
        if(decoder->state==TDecodeOSC){
            if(byte==7){TDecoderFlushCodepoints(decoder,sink);TDecoderEmitString(decoder,sink);decoder->state=TDecodeText;}
            else if(byte==27)decoder->state=TDecodeOSCEscape;
            else if(byte>=32){size_t start=index;while(index+1<length&&bytes[index+1]>=32)index++;TDecoderAppendStringBytes(decoder,bytes+start,index-start+1);}
            continue;
        }
        if(decoder->state==TDecodeOSCEscape){
            if(byte=='\\'){TDecoderFlushCodepoints(decoder,sink);TDecoderEmitString(decoder,sink);decoder->state=TDecodeText;}
            else decoder->state=TDecodeOSC;
            continue;
        }
        if(decoder->state==TDecodeDCS){
            if(byte==7){TDecoderFlushCodepoints(decoder,sink);TDecoderEmitString(decoder,sink);decoder->state=TDecodeText;}
            else if(byte==27)decoder->state=TDecodeDCSEscape;
            else if(byte>=32){size_t start=index;while(index+1<length&&bytes[index+1]>=32)index++;TDecoderAppendStringBytes(decoder,bytes+start,index-start+1);}
            continue;
        }
        if(decoder->state==TDecodeDCSEscape){
            if(byte=='\\'){TDecoderFlushCodepoints(decoder,sink);TDecoderEmitString(decoder,sink);decoder->state=TDecodeText;}
            else decoder->state=TDecodeDCS;
            continue;
        }
        if(decoder->state==TDecodeEscape){
            decoder->state=TDecodeText;
            if(byte=='['){decoder->state=TDecodeCSI;decoder->parameters[0]=0;decoder->parameterIndex=0;decoder->prefix=0;decoder->intermediate=0;}
            else if(byte==']'){decoder->stringLength=0;decoder->stringDiscarded=false;decoder->state=TDecodeOSC;}
            else if(byte=='P'||byte=='X'||byte=='^'||byte=='_'){decoder->stringLength=0;decoder->stringDiscarded=false;decoder->state=TDecodeDCS;}
            else{TDecoderFlushCodepoints(decoder,sink);if(sink->escape)sink->escape(sink->context,byte);}
            continue;
        }
        if(decoder->state==TDecodeCSI){
            if(byte=='?'||byte=='>'||byte=='<'||byte=='='){decoder->prefix=byte;continue;}
            if(byte>=0x20&&byte<=0x2F){decoder->intermediate=byte;continue;}
            if(byte>='0'&&byte<='9'){decoder->parameters[decoder->parameterIndex]=decoder->parameters[decoder->parameterIndex]*10+byte-'0';continue;}
            if(byte==';'||byte==':'){if(decoder->parameterIndex<19){decoder->parameterIndex++;decoder->parameters[decoder->parameterIndex]=0;}continue;}
            if(byte>=0x40&&byte<=0x7E){
                TDecoderFlushCodepoints(decoder,sink);if(sink->csi)sink->csi(sink->context,byte,decoder->prefix,decoder->intermediate,decoder->parameters,decoder->parameterIndex+1);
                decoder->state=TDecodeText;
            }
            continue;
        }
        TDecoderConsumeTextByte(decoder,byte,sink);
    }
    TDecoderFlushCodepoints(decoder,sink);
}
