#import "TerminalCore.h"

enum { TDecodeText, TDecodeEscape, TDecodeCSI, TDecodeOSC, TDecodeOSCEscape, TDecodeDCS, TDecodeDCSEscape };

NSUInteger TAppendUTF16(unichar *buffer,NSUInteger length,uint32_t codepoint) {
    if(!codepoint)codepoint=' ';
    if(codepoint<=0xFFFF){buffer[length++]=(unichar)codepoint;return length;}
    if(codepoint>0x10FFFF)codepoint=0xFFFD;
    uint32_t value=codepoint-0x10000;
    buffer[length++]=(unichar)(0xD800+(value>>10));
    buffer[length++]=(unichar)(0xDC00+(value&0x3FF));
    return length;
}

BOOL TUnicodeCombining(uint32_t cp) {
    return (cp>=0x0300&&cp<=0x036F)||(cp>=0x0483&&cp<=0x0489)||(cp>=0x0591&&cp<=0x05BD)||(cp>=0x05BF&&cp<=0x05C7)||(cp>=0x0610&&cp<=0x061A)||(cp>=0x064B&&cp<=0x065F)||(cp==0x0670)||(cp>=0x06D6&&cp<=0x06ED)||(cp==0x0711)||(cp>=0x0730&&cp<=0x074A)||(cp>=0x07A6&&cp<=0x07B0)||(cp>=0x07EB&&cp<=0x07F3)||(cp>=0x0816&&cp<=0x082D)||(cp>=0x08D3&&cp<=0x0903)||(cp>=0x093A&&cp<=0x094F)||(cp>=0x0981&&cp<=0x09CD)||(cp>=0x0A01&&cp<=0x0A4D)||(cp>=0x0A81&&cp<=0x0ACD)||(cp>=0x0B01&&cp<=0x0BCD)||(cp>=0x0C00&&cp<=0x0CCD)||(cp>=0x0D00&&cp<=0x0D4D)||(cp>=0x0E31&&cp<=0x0E4E)||(cp>=0x0EB1&&cp<=0x0ECD)||(cp>=0x0F18&&cp<=0x0FBC)||(cp>=0x102B&&cp<=0x103E)||(cp>=0x17B4&&cp<=0x17D3)||(cp>=0x1AB0&&cp<=0x1AFF)||(cp>=0x1DC0&&cp<=0x1DFF)||(cp>=0x20D0&&cp<=0x20FF)||(cp>=0xFE00&&cp<=0xFE0F)||(cp>=0xFE20&&cp<=0xFE2F)||(cp>=0x1F3FB&&cp<=0x1F3FF)||(cp>=0xE0020&&cp<=0xE007F)||(cp>=0xE0100&&cp<=0xE01EF)||cp==0x200D;
}

BOOL TUnicodeRegional(uint32_t cp){return cp>=0x1F1E6&&cp<=0x1F1FF;}

static inline uint8_t TWidthFast(uint32_t cp) {
    if(cp<0x1100) return 1;
    if(cp<=0x115F) return 2;
    if(cp<0x2329) return 1;
    if(cp<=0x232A) return 2;
    if(cp<0x2E80) return 1;
    if(cp<=0x303E) return 2;
    if(cp==0x303F) return 1;
    if(cp<=0xA4CF) return 2;
    if(cp<0xAC00) return 1;
    if(cp<=0xD7A3) return 2;
    if(cp<0xF900) return 1;
    if(cp<=0xFAFF) return 2;
    if(cp<0xFE10) return 1;
    if(cp<=0xFE19) return 2;
    if(cp<0xFE30) return 1;
    if(cp<=0xFE6F) return 2;
    if(cp<0xFF00) return 1;
    if(cp<=0xFF60) return 2;
    if(cp<0xFFE0) return 1;
    if(cp<=0xFFE6) return 2;
    if(cp<0x1F000) return 1;
    if(cp<=0x1FAFF) return 2;
    if(cp<0x20000) return 1;
    if(cp<=0x3FFFD) return 2;
    return 1;
}

BOOL TUnicodeWide(uint32_t cp) { return TWidthFast(cp)==2; }

@implementation TTerminalDecoder {
    int _state;
    int _parameters[20];
    NSUInteger _parameterIndex;
    uint8_t _prefix;
    NSMutableString *_osc;
    uint32_t _utf8Code;
    int _utf8Needed;
}

- (instancetype)init {if((self=[super init])){_osc=[NSMutableString string];[self reset];}return self;}
- (void)reset {_state=TDecodeText;_parameterIndex=0;_prefix=0;_utf8Code=0;_utf8Needed=0;memset(_parameters,0,sizeof(_parameters));[_osc setString:@""];}

- (void)consumeTextByte:(uint8_t)byte codepoint:(TCodepointHandler)codepoint control:(TControlHandler)control {
    if(byte==27){_state=TDecodeEscape;return;}
    if(byte<32||byte==127){control(byte);return;}
    if(_utf8Needed){if((byte&0xC0)!=0x80){_utf8Needed=0;codepoint(0xFFFD);[self consumeTextByte:byte codepoint:codepoint control:control];return;}_utf8Code=(_utf8Code<<6)|(byte&0x3F);if(--_utf8Needed==0)codepoint(_utf8Code);}
    else if(byte<0x80)codepoint(byte);
    else if((byte&0xE0)==0xC0){_utf8Code=byte&0x1F;_utf8Needed=1;}
    else if((byte&0xF0)==0xE0){_utf8Code=byte&0x0F;_utf8Needed=2;}
    else if((byte&0xF8)==0xF0){_utf8Code=byte&0x07;_utf8Needed=3;}
    else codepoint(0xFFFD);
}

- (void)consumeData:(const uint8_t *)bytes length:(NSUInteger)length ascii:(TASCIIHandler)ascii codepoint:(TCodepointHandler)codepoint control:(TControlHandler)control escape:(TEscapeHandler)escape csi:(TCSIHandler)csi osc:(TOSCHandler)osc runHook:(TRunHandler)runHook runFunc:(TRunFunc)runFunc context:(void *)context {
    uint32_t cps[2048];uint8_t wids[2048];
    for(NSUInteger index=0;index<length;index++){
        uint8_t byte=bytes[index];
        if(_state==TDecodeText&&!_utf8Needed&&byte>=32&&byte<127){NSUInteger start=index;while(index+1<length&&bytes[index+1]>=32&&bytes[index+1]<127)index++;ascii(bytes+start,index-start+1);continue;}
        if(_state==TDecodeText&&!_utf8Needed&&byte>=0xC0&&(runFunc||runHook)){NSUInteger cpCount=0;
            while(index<length&&cpCount<2048){
                byte=bytes[index];
                if(byte>=32&&byte<127){cps[cpCount]=byte;wids[cpCount]=1;cpCount++;index++;continue;}
                if(byte>=0xC0){
                    uint32_t cp;
                    if((byte&0xE0)==0xC0&&index+1<length&&(bytes[index+1]&0xC0)==0x80){
                        cp=((uint32_t)(byte&0x1F)<<6)|(bytes[index+1]&0x3F);
                        cps[cpCount]=cp;wids[cpCount]=TWidthFast(cp);cpCount++;
                        index+=2;continue;
                    } else if((byte&0xF0)==0xE0&&index+2<length&&(bytes[index+1]&0xC0)==0x80&&(bytes[index+2]&0xC0)==0x80){
                        cp=((uint32_t)(byte&0x0F)<<12)|((uint32_t)(bytes[index+1]&0x3F)<<6)|(bytes[index+2]&0x3F);
                        cps[cpCount]=cp;wids[cpCount]=TWidthFast(cp);cpCount++;
                        index+=3;continue;
                    } else if((byte&0xF8)==0xF0&&index+3<length&&(bytes[index+1]&0xC0)==0x80&&(bytes[index+2]&0xC0)==0x80&&(bytes[index+3]&0xC0)==0x80){
                        cp=((uint32_t)(byte&0x07)<<18)|((uint32_t)(bytes[index+1]&0x3F)<<12)|((uint32_t)(bytes[index+2]&0x3F)<<6)|(bytes[index+3]&0x3F);
                        cps[cpCount]=cp;wids[cpCount]=TWidthFast(cp);cpCount++;
                        index+=4;continue;
                    }
                    break;
                }
                break;
            }
            if(cpCount){
                if(runFunc) runFunc(context,cps,wids,cpCount);
                else runHook(cps,wids,cpCount);
            }
            continue;
        }
        if(_state==TDecodeOSC){if(byte==7){osc([_osc copy]);[_osc setString:@""];_state=TDecodeText;}else if(byte==27)_state=TDecodeOSCEscape;else if(byte>=32&&_osc.length<1398208)[_osc appendFormat:@"%c",byte];continue;}
        if(_state==TDecodeOSCEscape){if(byte=='\\'){osc([_osc copy]);[_osc setString:@""];_state=TDecodeText;}else _state=TDecodeOSC;continue;}
        if(_state==TDecodeDCS){if(byte==7){osc([_osc copy]);[_osc setString:@""];_state=TDecodeText;}else if(byte==27)_state=TDecodeDCSEscape;else if(byte>=32&&_osc.length<1398208)[_osc appendFormat:@"%c",byte];continue;}
        if(_state==TDecodeDCSEscape){if(byte=='\\'){osc([_osc copy]);[_osc setString:@""];_state=TDecodeDCS;}else _state=TDecodeDCS;continue;}
        if(_state==TDecodeEscape){_state=TDecodeText;if(byte=='['){_state=TDecodeCSI;memset(_parameters,0,sizeof(_parameters));_parameterIndex=0;_prefix=0;}else if(byte==']'){[_osc setString:@""];_state=TDecodeOSC;}else if(byte=='P'||byte=='X'||byte=='^'||byte=='_'){[_osc setString:@""];_state=TDecodeDCS;}else escape(byte);continue;}
        if(_state==TDecodeCSI){if(byte=='?'||byte=='>'||byte=='<'||byte=='='){_prefix=byte;continue;}if(byte>='0'&&byte<='9'){_parameters[_parameterIndex]=_parameters[_parameterIndex]*10+byte-'0';continue;}if(byte==';'||byte==':'){if(_parameterIndex<19)_parameterIndex++;continue;}if(byte>=0x40&&byte<=0x7E){csi(byte,_prefix,_parameters,_parameterIndex+1);_state=TDecodeText;}continue;}
        [self consumeTextByte:byte codepoint:codepoint control:control];
    }
}
@end
