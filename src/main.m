#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "TerminalCore.h"
#import "MetalRenderer.h"
#import <QuartzCore/QuartzCore.h>
#import <Carbon/Carbon.h>
#import <math.h>
#import <util.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/resource.h>
#import <sys/un.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <signal.h>
#import <stdarg.h>
#import <libproc.h>
#import <poll.h>
#import <float.h>
#import <string.h>
#import <termios.h>

static const uint32_t TDefaultColor = 0xFFFFFFFFu;
static CFAbsoluteTime TProcessStartedAt;
static void TLog(NSString *format, ...);
static NSString *TCurrentVersion(void);
static NSString *TShellQuotedPath(NSString *path) {
    if(!path.length)return @"''";
    return [NSString stringWithFormat:@"'%@'",[path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}
static uint32_t TDECSpecialGraphics(uint8_t byte) {
    static const uint32_t map[31]={0x25C6,0x2592,0x2409,0x240C,0x240D,0x240A,0x00B0,0x00B1,0x2424,0x240B,0x2518,0x2510,0x250C,0x2514,0x253C,0x23BA,0x23BB,0x2500,0x23BC,0x23BD,0x251C,0x2524,0x2534,0x252C,0x2502,0x2264,0x2265,0x03C0,0x2260,0x00A3,0x00B7};
    return byte>=0x60&&byte<=0x7E?map[byte-0x60]:byte;
}

static NSString *TConfigDirectoryPath(void) {
    const char *override = getenv("TERMATICA_CONFIG_DIR");
    if (override && *override) return [[NSString stringWithUTF8String:override] stringByExpandingTildeInPath];
    return [@"~/.config/termatica" stringByExpandingTildeInPath];
}

static NSString *TCLISocketPath(void) {const char *path=TConfigDirectoryPath().stringByStandardizingPath.fileSystemRepresentation;uint32_t hash=2166136261u;for(const unsigned char *byte=(const unsigned char *)path;*byte;byte++)hash=(hash^*byte)*16777619u;return [NSString stringWithFormat:@"/tmp/termatica-%u-%08x.sock",getuid(),hash];}

static NSString *TEnsureDirectory(NSString *name) {
    NSString *path = name.length ? [TConfigDirectoryPath() stringByAppendingPathComponent:name] : TConfigDirectoryPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}
static BOOL TConfigBool(id value,BOOL fallback) {
    if([value isKindOfClass:NSNumber.class])return [value boolValue];
    if([value isKindOfClass:NSString.class]){
        NSString *token=[value lowercaseString];
        if([@[@"on",@"true",@"yes",@"1"] containsObject:token])return YES;
        if([@[@"off",@"false",@"no",@"0"] containsObject:token])return NO;
    }
    return fallback;
}
static NSString *TConfigToggle(BOOL enabled) {return enabled?@"on":@"off";}
static void TNormalizeConfigToggles(NSMutableDictionary *dictionary) {
    NSDictionary<NSString *,NSArray<NSString *> *> *groups=@{
        @"appearance":@[@"blur"],
        @"tabs":@[@"animations",@"autoHide",@"hyprlandBlur"],
        @"system":@[@"pasteProtection",@"secureKeyboard",@"shellIntegration"],
        @"updates":@[@"checkOnLaunch"]
    };
    for(NSString *group in groups){
        NSDictionary *raw=[dictionary[group] isKindOfClass:NSDictionary.class]?dictionary[group]:@{};NSMutableDictionary *values=[raw mutableCopy];
        for(NSString *key in groups[group])if(values[key]&&![values[key] isEqual:@"theme"])values[key]=TConfigToggle(TConfigBool(values[key],NO));
        if([group isEqual:@"system"]){[values removeObjectForKey:@"restoreSession"];[values removeObjectForKey:@"saveScreenContent"];}
        dictionary[group]=values;
    }
    NSDictionary *rawPlugins=[dictionary[@"plugins"] isKindOfClass:NSDictionary.class]?dictionary[@"plugins"]:@{};NSMutableDictionary *plugins=[rawPlugins mutableCopy];
    for(NSString *identifier in plugins.allKeys)plugins[identifier]=TConfigToggle(TConfigBool(plugins[identifier],NO));
    dictionary[@"plugins"]=plugins;
    [dictionary removeObjectForKey:@"session"];
    [dictionary removeObjectForKey:@"skeleterm"];
}
static void TRemoveLegacyTerminalState(void) {
    NSFileManager *fm=NSFileManager.defaultManager;NSString *root=TConfigDirectoryPath();
    for(NSString *name in @[@"session.json",@"screens"]){NSString *path=[root stringByAppendingPathComponent:name];if([fm fileExistsAtPath:path]&&![fm removeItemAtPath:path error:nil])TLog(@"could not remove legacy terminal state at %@",path);}
}

static void TOpenPath(NSString *path) {
    if (!path.length) return;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[path];
    [task launchAndReturnError:nil];
}

static BOOL TSafeIdentifier(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length < 1 || value.length > 64) return NO;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound;
}

static BOOL TRemoveOwnedSocket(NSString *path) {
    struct stat info={0};if(lstat(path.fileSystemRepresentation,&info)<0)return errno==ENOENT;
    if(!S_ISSOCK(info.st_mode)||info.st_uid!=getuid())return NO;
    return unlink(path.fileSystemRepresentation)==0;
}

static BOOL TSafeExtensionExecutable(NSString *root,NSString *entry) {
    if(![entry isKindOfClass:NSString.class]||!entry.length||entry.length>256||entry.isAbsolutePath)return NO;
    NSString *base=root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *path=[[root stringByAppendingPathComponent:entry] stringByStandardizingPath].stringByResolvingSymlinksInPath;
    if(![path hasPrefix:[base stringByAppendingString:@"/"]])return NO;
    struct stat info={0};if(stat(path.fileSystemRepresentation,&info)<0||!S_ISREG(info.st_mode)||info.st_uid!=getuid()||(info.st_mode&0022))return NO;
    return access(path.fileSystemRepresentation,X_OK)==0;
}

static void TLog(NSString *format, ...) {
    if (!getenv("TERMATICA_VERBOSE")) return;
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "[Termatica +%.2fms] %s\n", TProcessStartedAt?(CFAbsoluteTimeGetCurrent()-TProcessStartedAt)*1000.0:0, message.UTF8String);
}

static NSColor *THexColor(NSString *value, NSColor *fallback) {
    if (![value isKindOfClass:NSString.class]) return fallback;
    NSString *s = [value stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (s.length != 6 && s.length != 8) return fallback;
    unsigned int rgba = 0;
    if (![[NSScanner scannerWithString:s] scanHexInt:&rgba]) return fallback;
    if (s.length == 6) rgba = (rgba << 8) | 0xFF;
    return [NSColor colorWithSRGBRed:((rgba >> 24) & 255) / 255.0
                               green:((rgba >> 16) & 255) / 255.0
                                blue:((rgba >> 8) & 255) / 255.0
                               alpha:(rgba & 255) / 255.0];
}

static uint32_t TRGB(NSColor *color) {
    NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!c) return 0;
    return ((uint32_t)lrint(c.redComponent * 255) << 16) |
           ((uint32_t)lrint(c.greenComponent * 255) << 8) |
           (uint32_t)lrint(c.blueComponent * 255);
}

static NSColor *TColor(uint32_t rgb) {
    static NSCache<NSNumber *,NSColor *> *cache;static dispatch_once_t once;dispatch_once(&once,^{cache=[NSCache new];cache.countLimit=256;});NSNumber *key=@(rgb);NSColor *color=[cache objectForKey:key];if(!color){color=[NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];[cache setObject:color forKey:key];}return color;
}
static NSString *TOSCColor(NSColor *color) {NSColor *c=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace]?:NSColor.whiteColor;return [NSString stringWithFormat:@"rgb:%04x/%04x/%04x",(unsigned)lrint(c.redComponent*65535),(unsigned)lrint(c.greenComponent*65535),(unsigned)lrint(c.blueComponent*65535)];}
static BOOL TParseOSCColor(NSString *value,uint32_t *result){if([value hasPrefix:@"#"]&&(value.length==7||value.length==13)){unsigned long long raw=0;NSScanner *scanner=[NSScanner scannerWithString:[value substringFromIndex:1]];if(![scanner scanHexLongLong:&raw])return NO;if(value.length==7)*result=(uint32_t)raw;else *result=(uint32_t)((((raw>>32)&0xFFFF)>>8)<<16)|((uint32_t)(((raw>>16)&0xFFFF)>>8)<<8)|(uint32_t)((raw&0xFFFF)>>8);return YES;}if([value hasPrefix:@"rgb:"]){NSArray *parts=[[value substringFromIndex:4] componentsSeparatedByString:@"/"];if(parts.count!=3)return NO;uint32_t rgb=0;for(NSString *part in parts){unsigned valuePart=0;if(![[NSScanner scannerWithString:part] scanHexInt:&valuePart])return NO;NSUInteger digits=part.length;unsigned maxValue=digits>=4?0xFFFF:(digits==3?0xFFF:(digits==2?0xFF:0xF));rgb=(rgb<<8)|(uint32_t)lrint((double)valuePart*255.0/MAX(1,maxValue));}*result=rgb;return YES;}return NO;}

static NSArray<NSString *> *TStandardPaletteHex(void) {return @[@"#1B1D23",@"#E06C75",@"#98C379",@"#E5C07B",@"#61AFEF",@"#C678DD",@"#56B6C2",@"#D7DAE0",@"#5C6370",@"#F07178",@"#AAD94C",@"#FFB454",@"#59C2FF",@"#D2A6FF",@"#95E6CB",@"#EEF1F5"];}

@interface TConfig : NSObject {
@public
    CGFloat initialWindowWidth,initialWindowHeight,minimumWindowWidth,minimumWindowHeight,windowCornerRadius,tileCornerRadius;
    BOOL windowShadow;
    CGFloat tabRailMargin,tabRailCornerRadius,tabButtonCornerRadius,tabButtonFontSize,tabButtonInset,tabMinimumHeight,tabMaximumHeight,tabSelectedOpacity,tabHoverOpacity,tabRailOpacity,tabRailBlurOpacity,tabEdgeOpacity,tabCollapsedPeek;
    CGFloat cursorThickness,cursorBlockOpacity,cursorInactiveOpacity,scrollbarWidth,scrollbarMargin,scrollbarMinimumThumb,scrollbarOpacity,scanlineSpacing,scanlineThickness;
    NSUInteger vignetteLayers;
    CGFloat searchOverlayWidth,searchOverlayHeight,searchOverlayCornerRadius,launchAnimationDuration,terminalAnimationDuration,layoutAnimationDuration;
}
@property NSString *path;
@property NSString *shell;
@property NSArray<NSString *> *shellArguments;
@property NSString *fontName;
@property NSArray<NSString *> *fontFeatures;
@property CGFloat fontSize;
@property CGFloat padding;
@property NSUInteger scrollback;
@property BOOL hyprlandLayout;
@property NSDictionary<NSString *,id> *pluginStates;
@property CGFloat tabRailWidth;
@property BOOL tabAnimations;
@property CGFloat animationSpeed;
@property CGFloat tileGap;
@property CGFloat screenInset;
@property BOOL hyprlandBlur;
@property BOOL tabAutoHide;
@property CGFloat tabHideDelay;
@property CGFloat backgroundOpacity;
@property CGFloat windowOpacity;
@property CGFloat glow;
@property CGFloat scanlines;
@property CGFloat vignette;
@property BOOL blur;
@property BOOL topBar;
@property NSString *blurMaterial;
@property NSString *cursorStyle;
@property NSString *renderer;
@property NSDictionary *keybindings;
@property NSString *themeName;
@property NSColor *background;
@property NSColor *foreground;
@property NSColor *cursor;
@property NSColor *accent;
@property NSColor *panel;
@property NSColor *muted;
@property NSColor *selection;
@property NSArray<NSColor *> *palette;
@property BOOL colorizePlainText;
@property NSArray<NSColor *> *plainTextPalette;
@property BOOL unicodeRendering;
@property BOOL oscIntegration;
@property BOOL updateCheckOnLaunch;
@property NSString *updateRepository;
@property BOOL pasteProtection;
@property NSString *clipboardRead;
@property NSString *clipboardWrite;
@property NSString *bellStyle;
@property BOOL secureKeyboard;
@property BOOL shellIntegration;
- (void)reload;
- (void)ensureEditableFile;
- (NSMutableDictionary *)normalizedDictionary:(NSDictionary *)source configName:(NSString *)configName;
- (NSArray<NSString *> *)installedThemeNames;
- (void)useThemeNamed:(NSString *)name;
- (BOOL)isPluginInstalled:(NSString *)identifier;
- (BOOL)isPluginEnabled:(NSString *)identifier;
- (void)setPlugin:(NSString *)identifier enabled:(BOOL)enabled;
@end

@implementation TConfig
- (instancetype)init {
    if ((self = [super init])) {
        TRemoveLegacyTerminalState();
        _path = [TConfigDirectoryPath() stringByAppendingPathComponent:@"config.json"];
        [self ensureEditableFile];
        [self reload];
    }
    return self;
}
- (NSDictionary *)defaults {
    static NSDictionary *base;static dispatch_once_t once;dispatch_once(&once,^{
        NSString *json=@"{\"shell\":\"/bin/zsh\",\"shellArguments\":[\"-l\"],\"fontName\":\"Monaco\",\"fontFeatures\":[],\"fontSize\":11,\"padding\":12,\"scrollback\":2000,\"theme\":\"terminal-default\",\"themeOptions\":[\"terminal-default\",\"amber-crt\",\"ghost-glass\",\"green-screen\"],\"textColorMode\":\"ansi\","
        "\"plugins\":{\"hello\":\"off\",\"pi-bridge\":\"off\",\"editor-deck\":\"off\",\"vim-control\":\"off\",\"neovim-control\":\"off\",\"emacs-control\":\"off\",\"nano-control\":\"off\",\"micro-control\":\"off\",\"helix-control\":\"off\",\"hidden-path\":\"off\",\"hyprland-layout\":\"off\",\"unicode-rendering\":\"off\",\"osc-integration\":\"off\",\"borderless-window\":\"off\"},"
        "\"appearance\":{\"backgroundOpacity\":\"theme\",\"windowOpacity\":\"theme\",\"blur\":\"theme\",\"blurMaterial\":\"theme\",\"glow\":\"theme\",\"scanlines\":\"theme\",\"vignette\":\"theme\",\"cursorStyle\":\"theme\",\"renderer\":\"appkit\"},"
        "\"colors\":{\"background\":\"theme\",\"foreground\":\"theme\",\"cursor\":\"theme\",\"accent\":\"theme\",\"panel\":\"theme\",\"muted\":\"theme\",\"selection\":\"theme\",\"palette\":\"theme\"},"
        "\"window\":{\"initialWidth\":580,\"initialHeight\":350,\"minimumWidth\":480,\"minimumHeight\":280,\"cornerRadius\":14,\"tileCornerRadius\":14,\"shadow\":\"off\"},"
        "\"tabs\":{\"railWidth\":34,\"animations\":\"on\",\"animationSpeed\":1.35,\"autoHide\":\"on\",\"hideDelay\":5,\"tileGap\":10,\"screenInset\":18,\"hyprlandBlur\":\"off\",\"railMargin\":8,\"railCornerRadius\":11,\"buttonCornerRadius\":8,\"buttonFontSize\":11,\"buttonInset\":4,\"minimumHeight\":20,\"maximumHeight\":28,\"selectedOpacity\":0.22,\"hoverOpacity\":0.68,\"railOpacity\":0.96,\"railBlurOpacity\":0.26,\"edgeOpacity\":0.58,\"collapsedPeek\":7},"
        "\"terminalUI\":{\"cursorThickness\":2,\"cursorBlockOpacity\":0.42,\"cursorInactiveOpacity\":0.20,\"scrollbarWidth\":2.5,\"scrollbarMargin\":5,\"scrollbarMinimumThumb\":24,\"scrollbarOpacity\":0.42,\"scanlineSpacing\":4,\"scanlineThickness\":1,\"vignetteLayers\":6,\"searchWidth\":340,\"searchHeight\":28,\"searchCornerRadius\":6},"
        "\"motion\":{\"launchDuration\":0.30,\"terminalDuration\":0.18,\"layoutDuration\":0.12},\"system\":{\"pasteProtection\":\"off\",\"secureKeyboard\":\"on\",\"shellIntegration\":\"on\",\"clipboardRead\":\"ask\",\"clipboardWrite\":\"allow\",\"bellStyle\":\"sound\"},\"updates\":{\"checkOnLaunch\":\"on\",\"repository\":\"sebastianmiletic/termatica\"},"
        "\"keybindings\":{\"openConfig\":\"cmd+,\",\"newWindow\":\"cmd+n\",\"newTab\":\"cmd+t\",\"newVerticalTab\":\"cmd+shift+t\",\"closeTab\":\"cmd+w\",\"clearTerminal\":\"cmd+k\",\"searchScrollback\":\"cmd+shift+f\",\"splitHorizontal\":\"cmd+d\",\"splitVertical\":\"cmd+shift+d\",\"nextSplit\":\"cmd+]\",\"previousSplit\":\"cmd+[\",\"previousPrompt\":\"cmd+shift+p\",\"nextPrompt\":\"cmd+option+p\",\"reload\":\"cmd+r\",\"copy\":\"cmd+c\",\"paste\":\"cmd+v\",\"selectAll\":\"cmd+a\",\"zoomIn\":\"cmd+plus\",\"zoomOut\":\"cmd+-\",\"zoomReset\":\"cmd+0\"}}";
        id parsed=[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];base=[parsed isKindOfClass:NSDictionary.class]?parsed:@{};
    });NSMutableDictionary *defaults=[base mutableCopy];defaults[@"shell"]=NSProcessInfo.processInfo.environment[@"SHELL"]?:@"/bin/zsh";return defaults;
}
- (NSDictionary *)fallbackTheme {
    return @{@"background":@"#101216",@"foreground":@"#D8DEE9",@"cursor":@"#EEF1F5",@"accent":@"#7AA2F7",@"panel":@"#151820",@"muted":@"#6B7280",@"selection":@"#2B3445",@"appearance":@{@"backgroundOpacity":@1,@"windowOpacity":@1,@"blur":@NO,@"glow":@0,@"scanlines":@0,@"vignette":@0,@"cursorStyle":@"block"},@"palette":TStandardPaletteHex()};
}
- (NSDictionary *)themeNamed:(NSString *)name {
    if (!name.length) return nil;
    NSArray *roots=@[[TConfigDirectoryPath() stringByAppendingPathComponent:@"themes"],
                     [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Themes"]];
    for(NSString *root in roots){NSData *data=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]]];if(!data)continue;id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if([value isKindOfClass:NSDictionary.class])return value;}
    return nil;
}
- (void)reload {
    NSDictionary *d = [self defaults];
    NSDictionary *user = @{};
    NSData *data = [NSData dataWithContentsOfFile:self.path];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:NSDictionary.class]) {
            user = parsed;
            NSMutableDictionary *merged = [d mutableCopy];
            [merged addEntriesFromDictionary:parsed];
            d = merged;
        }
    }
    self.shell = [d[@"shell"] isKindOfClass:NSString.class] ? d[@"shell"] : @"/bin/zsh";
    self.shellArguments = [d[@"shellArguments"] isKindOfClass:NSArray.class] ? d[@"shellArguments"] : @[@"-l"];
    self.fontName = [d[@"fontName"] isKindOfClass:NSString.class] ? d[@"fontName"] : @"Monaco";
    self.fontFeatures = [d[@"fontFeatures"] isKindOfClass:NSArray.class] ? d[@"fontFeatures"] : @[];
    self.fontSize = MAX(8, MIN(48, [d[@"fontSize"] doubleValue] ?: 11));
    self.padding = MAX(0, MIN(40, [d[@"padding"] doubleValue]));
    self.scrollback = MAX(100, MIN(100000, [d[@"scrollback"] unsignedIntegerValue] ?: 2000));
    
    NSDictionary *system=[d[@"system"] isKindOfClass:NSDictionary.class]?d[@"system"]:@{};self.pasteProtection=TConfigBool(system[@"pasteProtection"],NO);self.secureKeyboard=TConfigBool(system[@"secureKeyboard"],YES);self.shellIntegration=TConfigBool(system[@"shellIntegration"],YES);self.clipboardRead=[@[@"ask",@"allow",@"deny"] containsObject:system[@"clipboardRead"]]?system[@"clipboardRead"]:@"ask";self.clipboardWrite=[@[@"ask",@"allow",@"deny"] containsObject:system[@"clipboardWrite"]]?system[@"clipboardWrite"]:@"allow";self.bellStyle=[@[@"sound",@"visual",@"both",@"none"] containsObject:system[@"bellStyle"]]?system[@"bellStyle"]:@"sound";
    NSDictionary *updates=[d[@"updates"] isKindOfClass:NSDictionary.class]?d[@"updates"]:@{};self.updateCheckOnLaunch=TConfigBool(updates[@"checkOnLaunch"],YES);self.updateRepository=[updates[@"repository"] isKindOfClass:NSString.class]?updates[@"repository"]:@"sebastianmiletic/termatica";
    self.pluginStates=[d[@"plugins"] isKindOfClass:NSDictionary.class]?d[@"plugins"]:@{};
    self.unicodeRendering=[self isPluginEnabled:@"unicode-rendering"];
    self.oscIntegration=[self isPluginEnabled:@"osc-integration"];
    self.hyprlandLayout=[self isPluginEnabled:@"hyprland-layout"];
    NSDictionary *window=[d[@"window"] isKindOfClass:NSDictionary.class]?d[@"window"]:@{};self->initialWindowWidth=MAX(320,MIN(3840,[window[@"initialWidth"] doubleValue]?:580));self->initialWindowHeight=MAX(200,MIN(2160,[window[@"initialHeight"] doubleValue]?:350));self->minimumWindowWidth=MAX(240,MIN(1920,[window[@"minimumWidth"] doubleValue]?:480));self->minimumWindowHeight=MAX(160,MIN(1080,[window[@"minimumHeight"] doubleValue]?:280));self->windowCornerRadius=MAX(0,MIN(64,[window[@"cornerRadius"] doubleValue]?:14));self->tileCornerRadius=MAX(0,MIN(64,[window[@"tileCornerRadius"] doubleValue]?:14));self->windowShadow=TConfigBool(window[@"shadow"],NO);
    NSDictionary *tabs=[d[@"tabs"] isKindOfClass:NSDictionary.class]?d[@"tabs"]:@{};self.tabRailWidth=MAX(20,MIN(120,[tabs[@"railWidth"] doubleValue]?:34));self.tabAnimations=TConfigBool(tabs[@"animations"],YES);self.animationSpeed=MAX(0.25,MIN(4,[tabs[@"animationSpeed"] doubleValue]?:1.35));self.tabAutoHide=TConfigBool(tabs[@"autoHide"],YES);self.tabHideDelay=MAX(1,MIN(30,[tabs[@"hideDelay"] doubleValue]?:5));self.tileGap=MAX(0,MIN(48,[tabs[@"tileGap"] doubleValue]?:10));self.screenInset=MAX(0,MIN(120,[tabs[@"screenInset"] doubleValue]?:18));self.hyprlandBlur=TConfigBool(tabs[@"hyprlandBlur"],NO);self->tabRailMargin=MAX(0,MIN(48,[tabs[@"railMargin"] doubleValue]?:8));self->tabRailCornerRadius=MAX(0,MIN(48,[tabs[@"railCornerRadius"] doubleValue]?:11));self->tabButtonCornerRadius=MAX(0,MIN(32,[tabs[@"buttonCornerRadius"] doubleValue]?:8));self->tabButtonFontSize=MAX(8,MIN(28,[tabs[@"buttonFontSize"] doubleValue]?:11));self->tabButtonInset=MAX(0,MIN(16,[tabs[@"buttonInset"] doubleValue]?:4));self->tabMinimumHeight=MAX(12,MIN(64,[tabs[@"minimumHeight"] doubleValue]?:20));self->tabMaximumHeight=MAX(self->tabMinimumHeight,MIN(96,[tabs[@"maximumHeight"] doubleValue]?:28));self->tabSelectedOpacity=MAX(0,MIN(1,[tabs[@"selectedOpacity"] doubleValue]?:0.22));self->tabHoverOpacity=MAX(0,MIN(1,[tabs[@"hoverOpacity"] doubleValue]?:0.68));self->tabRailOpacity=MAX(0,MIN(1,[tabs[@"railOpacity"] doubleValue]?:0.96));self->tabRailBlurOpacity=MAX(0,MIN(1,[tabs[@"railBlurOpacity"] doubleValue]?:0.26));self->tabEdgeOpacity=MAX(0,MIN(1,[tabs[@"edgeOpacity"] doubleValue]?:0.58));self->tabCollapsedPeek=MAX(0,MIN(24,[tabs[@"collapsedPeek"] doubleValue]?:7));
    NSDictionary *terminalUI=[d[@"terminalUI"] isKindOfClass:NSDictionary.class]?d[@"terminalUI"]:@{};self->cursorThickness=MAX(1,MIN(8,[terminalUI[@"cursorThickness"] doubleValue]?:2));self->cursorBlockOpacity=MAX(0.05,MIN(1,[terminalUI[@"cursorBlockOpacity"] doubleValue]?:0.42));self->cursorInactiveOpacity=MAX(0.02,MIN(1,[terminalUI[@"cursorInactiveOpacity"] doubleValue]?:0.20));self->scrollbarWidth=MAX(1,MIN(16,[terminalUI[@"scrollbarWidth"] doubleValue]?:2.5));self->scrollbarMargin=MAX(0,MIN(32,[terminalUI[@"scrollbarMargin"] doubleValue]?:5));self->scrollbarMinimumThumb=MAX(4,MIN(160,[terminalUI[@"scrollbarMinimumThumb"] doubleValue]?:24));self->scrollbarOpacity=MAX(0.05,MIN(1,[terminalUI[@"scrollbarOpacity"] doubleValue]?:0.42));self->scanlineSpacing=MAX(1,MIN(16,[terminalUI[@"scanlineSpacing"] doubleValue]?:4));self->scanlineThickness=MAX(1,MIN(self->scanlineSpacing,[terminalUI[@"scanlineThickness"] doubleValue]?:1));self->vignetteLayers=MAX(1,MIN((NSUInteger)24,[terminalUI[@"vignetteLayers"] unsignedIntegerValue]?:6));self->searchOverlayWidth=MAX(180,MIN(800,[terminalUI[@"searchWidth"] doubleValue]?:340));self->searchOverlayHeight=MAX(24,MIN(80,[terminalUI[@"searchHeight"] doubleValue]?:28));self->searchOverlayCornerRadius=MAX(0,MIN(32,[terminalUI[@"searchCornerRadius"] doubleValue]?:6));
    NSDictionary *motion=[d[@"motion"] isKindOfClass:NSDictionary.class]?d[@"motion"]:@{};self->launchAnimationDuration=MAX(0.05,MIN(2,[motion[@"launchDuration"] doubleValue]?:0.30));self->terminalAnimationDuration=MAX(0.05,MIN(2,[motion[@"terminalDuration"] doubleValue]?:0.18));self->layoutAnimationDuration=MAX(0.03,MIN(1,[motion[@"layoutDuration"] doubleValue]?:0.12));
    id rawTheme=d[@"theme"];self.themeName=[rawTheme isKindOfClass:NSString.class]?rawTheme:@"custom";
    NSDictionary *theme=[rawTheme isKindOfClass:NSDictionary.class]?rawTheme:[self themeNamed:self.themeName];if(!theme)theme=[self fallbackTheme];
    NSDictionary *themeAppearance=[theme[@"appearance"] isKindOfClass:NSDictionary.class]?theme[@"appearance"]:@{};
    NSMutableDictionary *appearance=[themeAppearance mutableCopy];
    NSDictionary *configAppearance=[d[@"appearance"] isKindOfClass:NSDictionary.class]?d[@"appearance"]:@{};for(NSString *key in configAppearance){id value=configAppearance[key];if(![value isKindOfClass:NSString.class]||![value isEqual:@"theme"])appearance[key]=value;}
    NSDictionary *userTabs=[user[@"tabs"] isKindOfClass:NSDictionary.class]?user[@"tabs"]:@{};if(!userTabs[@"hyprlandBlur"]&&appearance[@"hyprlandBlur"])self.hyprlandBlur=TConfigBool(appearance[@"hyprlandBlur"],NO);
    self.backgroundOpacity=MAX(0.08,MIN(1.0,appearance[@"backgroundOpacity"]?[appearance[@"backgroundOpacity"] doubleValue]:0.90));
    self.windowOpacity=MAX(0.20,MIN(1.0,appearance[@"windowOpacity"]?[appearance[@"windowOpacity"] doubleValue]:1.0));
    self.blur=TConfigBool(appearance[@"blur"],YES);
    self.topBar=![self isPluginEnabled:@"borderless-window"];
    self.blurMaterial=[appearance[@"blurMaterial"] isKindOfClass:NSString.class]?appearance[@"blurMaterial"]:@"hud";
    self.glow=MAX(0,MIN(1,[appearance[@"glow"] doubleValue]));self.scanlines=MAX(0,MIN(1,[appearance[@"scanlines"] doubleValue]));self.vignette=MAX(0,MIN(1,[appearance[@"vignette"] doubleValue]));
    self.cursorStyle=[appearance[@"cursorStyle"] isKindOfClass:NSString.class]?appearance[@"cursorStyle"]:@"block";
    self.renderer=[@[@"appkit",@"metal"] containsObject:appearance[@"renderer"]]?appearance[@"renderer"]:@"appkit";
    NSMutableDictionary *bindings=[[[self defaults] objectForKey:@"keybindings"] mutableCopy];if([d[@"keybindings"] isKindOfClass:NSDictionary.class])[bindings addEntriesFromDictionary:d[@"keybindings"]];self.keybindings=bindings;
    NSDictionary *colorOverrides=[d[@"colors"] isKindOfClass:NSDictionary.class]?d[@"colors"]:@{};
    self.background = [THexColor(colorOverrides[@"background"]?:theme[@"background"], THexColor(@"#101216", NSColor.blackColor)) colorWithAlphaComponent:self.backgroundOpacity];
    self.foreground = THexColor(colorOverrides[@"foreground"]?:theme[@"foreground"], THexColor(@"#D8DEE9", NSColor.textColor));
    self.cursor = THexColor(colorOverrides[@"cursor"]?:theme[@"cursor"], THexColor(@"#EEF1F5", NSColor.textColor));
    self.accent = THexColor(colorOverrides[@"accent"]?:theme[@"accent"], self.cursor);
    self.panel=THexColor(colorOverrides[@"panel"]?:theme[@"panel"],THexColor(@"#151820",NSColor.windowBackgroundColor));self.muted=THexColor(colorOverrides[@"muted"]?:theme[@"muted"],THexColor(@"#6B7280",NSColor.secondaryLabelColor));self.selection=THexColor(colorOverrides[@"selection"]?:theme[@"selection"],THexColor(@"#2B3445",self.accent));
    NSArray *raw = [colorOverrides[@"palette"] isKindOfClass:NSArray.class] ? colorOverrides[@"palette"] : ([theme[@"palette"] isKindOfClass:NSArray.class] ? theme[@"palette"] : [self fallbackTheme][@"palette"]);
    NSMutableArray *colors = [NSMutableArray arrayWithCapacity:16];
    for (NSUInteger i = 0; i < 16; i++) {
        NSString *hex = i < raw.count ? raw[i] : @"#E8E4DD";
        [colors addObject:THexColor(hex, self.foreground)];
    }
    self.palette = colors;
    NSArray *plainRaw=[theme[@"plainTextPalette"] isKindOfClass:NSArray.class]?theme[@"plainTextPalette"]:@[];NSMutableArray *plainColors=[NSMutableArray arrayWithCapacity:8];for(NSUInteger i=0;i<MIN((NSUInteger)8,plainRaw.count);i++)if([plainRaw[i] isKindOfClass:NSString.class])[plainColors addObject:THexColor(plainRaw[i],self.foreground)];if(!plainColors.count){NSUInteger indexes[]={12,13,14,10,11,9};for(NSUInteger i=0;i<6;i++)[plainColors addObject:self.palette[indexes[i]]];}self.plainTextPalette=plainColors;self.colorizePlainText=[d[@"textColorMode"] isKindOfClass:NSString.class]&&[d[@"textColorMode"] isEqual:@"spectrum"];
}
- (NSArray<NSString *> *)installedThemeNames {NSMutableOrderedSet *names=[NSMutableOrderedSet orderedSet];for(NSString *root in @[[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Themes"],[TConfigDirectoryPath() stringByAppendingPathComponent:@"themes"]])for(NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]?:@[])if([file.pathExtension.lowercaseString isEqual:@"json"])[names addObject:file.stringByDeletingPathExtension];return names.array;}
- (void)useThemeNamed:(NSString *)name {if(![self themeNamed:name])return;NSMutableDictionary *d=[self editableDictionary];d[@"theme"]=name;[d removeObjectForKey:@"profile"];[self writeEditableDictionary:d];}
- (NSMutableDictionary *)normalizedDictionary:(NSDictionary *)source configName:(NSString *)configName {
    NSDictionary *existing=[source isKindOfClass:NSDictionary.class]?source:@{};
    NSMutableDictionary *normalized=[[self defaults] mutableCopy];
    [normalized addEntriesFromDictionary:existing];
    for(NSString *key in @[@"appearance",@"colors",@"window",@"tabs",@"terminalUI",@"motion",@"system",@"updates",@"keybindings"]){
        NSMutableDictionary *nested=[[[self defaults] objectForKey:key] mutableCopy]?:[NSMutableDictionary dictionary];
        if([existing[key] isKindOfClass:NSDictionary.class])[nested addEntriesFromDictionary:existing[key]];
        normalized[key]=nested;
    }
    NSMutableDictionary *plugins=[[[self defaults] objectForKey:@"plugins"] mutableCopy];
    NSDictionary *configuredPlugins=[existing[@"plugins"] isKindOfClass:NSDictionary.class]?existing[@"plugins"]:nil;
    NSSet *legacyDisabled=[NSSet setWithArray:[existing[@"disabledPlugins"] isKindOfClass:NSArray.class]?existing[@"disabledPlugins"]:@[]];
    if(configuredPlugins)[plugins addEntriesFromDictionary:configuredPlugins];
    else {
        for(NSString *identifier in [plugins.allKeys copy])plugins[identifier]=TConfigToggle([self isPluginInstalled:identifier]&&![legacyDisabled containsObject:identifier]);
        NSDictionary *legacyAppearance=[existing[@"appearance"] isKindOfClass:NSDictionary.class]?existing[@"appearance"]:@{};
        if(legacyAppearance[@"topBar"]&&!TConfigBool(legacyAppearance[@"topBar"],YES))plugins[@"borderless-window"]=@"on";
    }
    NSString *extensionRoot=[TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"];
    for(NSString *identifier in [NSFileManager.defaultManager contentsOfDirectoryAtPath:extensionRoot error:nil]?:@[]){
        if(!TSafeIdentifier(identifier)||[identifier hasPrefix:@"."])continue;
        if(!plugins[identifier])plugins[identifier]=TConfigToggle(![legacyDisabled containsObject:identifier]);
    }
    for(NSString *identifier in [plugins.allKeys copy])if([identifier hasPrefix:@"."])[plugins removeObjectForKey:identifier];
    normalized[@"plugins"]=plugins;
    normalized[@"themeOptions"]=[self installedThemeNames];
    normalized[@"schemaVersion"]=@1;
    NSMutableDictionary *appearance=[normalized[@"appearance"] mutableCopy];[appearance removeObjectForKey:@"topBar"];normalized[@"appearance"]=appearance;
    [normalized removeObjectForKey:@"disabledPlugins"];
    [normalized removeObjectForKey:@"profile"];
    if(configName.length&&TSafeIdentifier(configName))normalized[@"configName"]=configName;else[normalized removeObjectForKey:@"configName"];
    TNormalizeConfigToggles(normalized);
    return normalized;
}
- (void)ensureEditableFile {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = self.path.stringByDeletingLastPathComponent;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *existingData=[NSData dataWithContentsOfFile:self.path];
    id parsed=existingData?[NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil]:nil;
    NSDictionary *existing=[parsed isKindOfClass:NSDictionary.class]?parsed:@{};
    NSString *activeName=[existing[@"configName"] isKindOfClass:NSString.class]&&TSafeIdentifier(existing[@"configName"])?existing[@"configName"]:nil;
    NSMutableDictionary *normalized=[self normalizedDictionary:existing configName:activeName];
    if(!existingData||![normalized isEqualToDictionary:existing]){
        NSData *data=[NSJSONSerialization dataWithJSONObject:normalized options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
        if([data writeToFile:self.path options:NSDataWritingAtomic error:nil])
            [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:self.path error:nil];
    }
    NSString *profiles=[TConfigDirectoryPath() stringByAppendingPathComponent:@"configs"];
    [fm createDirectoryAtPath:profiles withIntermediateDirectories:YES attributes:nil error:nil];
    for(NSString *file in [fm contentsOfDirectoryAtPath:profiles error:nil]?:@[]){
        if(![file.pathExtension.lowercaseString isEqual:@"json"])continue;NSString *name=file.stringByDeletingPathExtension;if(!TSafeIdentifier(name))continue;NSString *profilePath=[profiles stringByAppendingPathComponent:file];NSData *profileData=[NSData dataWithContentsOfFile:profilePath];id value=profileData?[NSJSONSerialization JSONObjectWithData:profileData options:0 error:nil]:nil;if(![value isKindOfClass:NSDictionary.class])continue;NSMutableDictionary *profile=[self normalizedDictionary:value configName:name];if(![profile isEqualToDictionary:value]){NSData *updated=[NSJSONSerialization dataWithJSONObject:profile options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];if([updated writeToFile:profilePath options:NSDataWritingAtomic error:nil])[fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:profilePath error:nil];}
    }
    if(activeName.length){NSString *activePath=[[profiles stringByAppendingPathComponent:activeName] stringByAppendingPathExtension:@"json"];NSData *savedData=[NSData dataWithContentsOfFile:activePath];id saved=savedData?[NSJSONSerialization JSONObjectWithData:savedData options:0 error:nil]:nil;if(![saved isKindOfClass:NSDictionary.class]||![saved isEqualToDictionary:normalized]){NSData *activeData=[NSJSONSerialization dataWithJSONObject:normalized options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];if([activeData writeToFile:activePath options:NSDataWritingAtomic error:nil])[fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:activePath error:nil];}}
}
- (NSMutableDictionary *)editableDictionary {
    [self ensureEditableFile];NSData *data=[NSData dataWithContentsOfFile:self.path];id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;return [parsed isKindOfClass:NSDictionary.class]?[parsed mutableCopy]:[[self defaults] mutableCopy];
}
- (void)writeEditableDictionary:(NSDictionary *)dictionary {
    NSString *name=[dictionary[@"configName"] isKindOfClass:NSString.class]?dictionary[@"configName"]:nil;NSMutableDictionary *normalized=[self normalizedDictionary:dictionary configName:name];NSData *data=[NSJSONSerialization dataWithJSONObject:normalized options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];if([data writeToFile:self.path options:NSDataWritingAtomic error:nil])[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:self.path error:nil];[self ensureEditableFile];[self reload];
}
- (BOOL)isPluginInstalled:(NSString *)identifier {return identifier.length&&[NSFileManager.defaultManager fileExistsAtPath:[[TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"] stringByAppendingPathComponent:identifier]];}
- (BOOL)isPluginEnabled:(NSString *)identifier {return [self isPluginInstalled:identifier]&&TConfigBool(self.pluginStates[identifier],NO);}
- (void)setPlugin:(NSString *)identifier enabled:(BOOL)enabled {if(!TSafeIdentifier(identifier))return;NSMutableDictionary *d=[self editableDictionary];NSDictionary *configured=[d[@"plugins"] isKindOfClass:NSDictionary.class]?d[@"plugins"]:@{};NSMutableDictionary *plugins=[configured mutableCopy];plugins[identifier]=TConfigToggle(enabled);d[@"plugins"]=plugins;[self writeEditableDictionary:d];}
@end

static BOOL TPostCLIRequest(NSDictionary *request) {
    NSData *payload=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];if(!payload.length||payload.length>8192)return NO;int socketFD=socket(AF_UNIX,SOCK_DGRAM,0);if(socketFD<0)return NO;struct sockaddr_un address={0};address.sun_family=AF_UNIX;strlcpy(address.sun_path,TCLISocketPath().fileSystemRepresentation,sizeof(address.sun_path));address.sun_len=(uint8_t)(offsetof(struct sockaddr_un,sun_path)+strlen(address.sun_path)+1);ssize_t sent=sendto(socketFD,payload.bytes,payload.length,0,(struct sockaddr *)&address,address.sun_len);if(sent<0)TLog(@"CLI socket send failed: %s",strerror(errno));close(socketFD);return sent==(ssize_t)payload.length;
}
static void TPostCLICommand(NSString *command) {TPostCLIRequest(@{@"command":command?:@""});}
static NSDictionary *TRequestCLI(NSDictionary *request,NSTimeInterval timeout) {
    NSString *path=[NSString stringWithFormat:@"/tmp/termatica-reply-%u-%d-%@.sock",getuid(),getpid(),NSUUID.UUID.UUIDString];
    int fd=socket(AF_UNIX,SOCK_DGRAM,0);if(fd<0)return nil;struct sockaddr_un address={0};address.sun_family=AF_UNIX;strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path));address.sun_len=(uint8_t)(offsetof(struct sockaddr_un,sun_path)+strlen(address.sun_path)+1);
    if(bind(fd,(struct sockaddr *)&address,address.sun_len)<0){close(fd);return nil;}chmod(path.fileSystemRepresentation,0600);NSMutableDictionary *payload=[request mutableCopy];payload[@"replyPath"]=path;
    NSDictionary *result=nil;if(TPostCLIRequest(payload)){struct pollfd wait={.fd=fd,.events=POLLIN};int ready=0;CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+MAX(1,timeout);do{int remaining=(int)MAX(1,(deadline-CFAbsoluteTimeGetCurrent())*1000);ready=poll(&wait,1,remaining);}while(ready<0&&errno==EINTR&&CFAbsoluteTimeGetCurrent()<deadline);if(ready>0&&(wait.revents&POLLIN)){uint8_t buffer[8192];ssize_t count=recv(fd,buffer,sizeof(buffer),0);if(count>0){id value=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buffer length:(NSUInteger)count] options:0 error:nil];if([value isKindOfClass:NSDictionary.class])result=value;}}}
    close(fd);unlink(path.fileSystemRepresentation);return result;
}
static BOOL TSendCLIReply(NSString *path,NSDictionary *reply) {
    if(![path isKindOfClass:NSString.class]||![path hasPrefix:[NSString stringWithFormat:@"/tmp/termatica-reply-%u-",getuid()]])return NO;struct stat info={0};if(lstat(path.fileSystemRepresentation,&info)<0||!S_ISSOCK(info.st_mode)||info.st_uid!=getuid())return NO;NSData *data=[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];if(!data.length||data.length>8192)return NO;
    int fd=socket(AF_UNIX,SOCK_DGRAM,0);if(fd<0)return NO;struct sockaddr_un address={0};address.sun_family=AF_UNIX;strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path));address.sun_len=(uint8_t)(offsetof(struct sockaddr_un,sun_path)+strlen(address.sun_path)+1);BOOL ok=sendto(fd,data.bytes,data.length,0,(struct sockaddr *)&address,address.sun_len)==(ssize_t)data.length;close(fd);return ok;
}

static NSArray<NSDictionary *> *TModuleItems(void) {
    return @[
      @{@"id":@"terminal-default",@"kind":@"themes",@"icon":@"[T]",@"title":@"TERMINAL DEFAULT",@"detail":@"neutral dark surface with a complete standard ANSI palette"},
      @{@"id":@"amber-crt",@"kind":@"themes",@"icon":@"[T:]",@"title":@"AMBER CRT",@"detail":@"optional phosphor palette, glow and blur"},
      @{@"id":@"ghost-glass",@"kind":@"themes",@"icon":@"[T~]",@"title":@"GHOST GLASS",@"detail":@"transparent cool glass and bar cursor"},
      @{@"id":@"green-screen",@"kind":@"themes",@"icon":@"[T#]",@"title":@"GREEN SCREEN",@"detail":@"opaque green phosphor and underline cursor"},
      @{@"id":@"hello",@"kind":@"plugins",@"icon":@"[>_]",@"title":@"HELLO PROTOCOL",@"detail":@"source-readable extension example, Python 3"},
      @{@"id":@"pi-bridge",@"kind":@"plugins",@"icon":@"[PI]",@"title":@"PI COMMAND BRIDGE",@"detail":@"adds /pi for an installed Pi CLI, Python 3"},
      @{@"id":@"editor-deck",@"kind":@"plugins",@"icon":@"[ED]",@"title":@"EDITOR DECK",@"detail":@"terminal controls for Vim, Neovim, Emacs, Nano, Micro and Helix"},
      @{@"id":@"vim-control",@"kind":@"plugins",@"icon":@"[VI]",@"title":@"VIM CONTROL",@"detail":@"/vim opens files in Vim inside the active terminal"},
      @{@"id":@"neovim-control",@"kind":@"plugins",@"icon":@"[NV]",@"title":@"NEOVIM CONTROL",@"detail":@"/nvim opens files in Neovim inside the active terminal"},
      @{@"id":@"emacs-control",@"kind":@"plugins",@"icon":@"[EM]",@"title":@"EMACS CONTROL",@"detail":@"/emacs opens terminal-mode Emacs with no GUI"},
      @{@"id":@"nano-control",@"kind":@"plugins",@"icon":@"[NA]",@"title":@"NANO CONTROL",@"detail":@"/nano opens files in Nano inside the active terminal"},
      @{@"id":@"micro-control",@"kind":@"plugins",@"icon":@"[MI]",@"title":@"MICRO CONTROL",@"detail":@"/micro opens files in Micro inside the active terminal"},
      @{@"id":@"helix-control",@"kind":@"plugins",@"icon":@"[HX]",@"title":@"HELIX CONTROL",@"detail":@"/hx opens files in Helix inside the active terminal"},
      @{@"id":@"hidden-path",@"kind":@"plugins",@"icon":@"[;/]",@"title":@"HIDDEN PATH",@"detail":@"short prompt paths such as Coding/OpenCloud ;"}
      ,@{@"id":@"hyprland-layout",@"kind":@"plugins",@"icon":@"[HY]",@"title":@"HYPRLAND LAYOUT",@"detail":@"tiles terminal sessions with native snapping and motion"},
      @{@"id":@"unicode-rendering",@"kind":@"plugins",@"icon":@"[U+]",@"title":@"FULL UNICODE",@"detail":@"wide glyphs, emoji and composed grapheme rendering"},
      @{@"id":@"osc-integration",@"kind":@"plugins",@"icon":@"[OSC]",@"title":@"OSC INTEGRATION",@"detail":@"OSC 7 cwd, OSC 8 links and OSC 133 command marks"},
      @{@"id":@"borderless-window",@"kind":@"plugins",@"icon":@"[__]",@"title":@"BORDERLESS WINDOW",@"detail":@"removes the titlebar and traffic lights while keeping rounded corners"}
    ];
}

static NSArray<NSDictionary *> *TBuiltInCommands(NSString *identifier) {
    NSDictionary *editors=@{@"vim":@"Vim",@"nvim":@"Neovim",@"emacs":@"Emacs terminal",@"nano":@"Nano",@"micro":@"Micro",@"hx":@"Helix"};NSDictionary *idToKey=@{@"vim-control":@"vim",@"neovim-control":@"nvim",@"emacs-control":@"emacs",@"nano-control":@"nano",@"micro-control":@"micro",@"helix-control":@"hx"};
    if([identifier isEqual:@"editor-deck"]||idToKey[identifier]){NSArray *keys=idToKey[identifier]?@[idToKey[identifier]]:@[@"vim",@"nvim",@"emacs",@"nano",@"micro",@"hx"];NSMutableArray *commands=[NSMutableArray array];for(NSString *key in keys)[commands addObject:@{@"id":[@"editor." stringByAppendingString:key],@"title":[NSString stringWithFormat:@"Editor: %@ (terminal)",editors[key]],@"slash":[@"/" stringByAppendingString:key],@"terminalCommand":[@"termatica editor " stringByAppendingString:key]}];return commands;}
    if([identifier isEqual:@"pi-bridge"])return @[@{@"id":@"pi-bridge.run",@"title":@"Pi: send prompt",@"slash":@"/pi",@"terminalCommand":@"pi"}];
    if([identifier isEqual:@"hello"])return @[@{@"id":@"hello.run",@"title":@"Hello: write into shell",@"slash":@"/hello",@"terminalCommand":@"printf '\\033[38;2;122;162;247mTermatica\\033[0m %s\\n'"}];
    return @[];
}

static NSString *TShellQuote(NSString *value) {NSString *safe=[(value?:@"") stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];return [NSString stringWithFormat:@"'%@'",safe];}

static NSString *TEditorControlsScript(NSString *identifier) {
    NSDictionary *all=@{
      @"vim":@{ @"bin":@"vim", @"command":@"vim", @"title":@"Vim" },
      @"nvim":@{ @"bin":@"nvim", @"command":@"nvim", @"title":@"Neovim" },
      @"emacs":@{ @"bin":@"emacs", @"command":@"emacs -nw", @"title":@"Emacs terminal" },
      @"nano":@{ @"bin":@"nano", @"command":@"nano", @"title":@"Nano" },
      @"micro":@{ @"bin":@"micro", @"command":@"micro", @"title":@"Micro" },
      @"hx":@{ @"bin":@"hx", @"command":@"hx", @"title":@"Helix" }
    };
    NSDictionary *idToKey=@{@"vim-control":@"vim",@"neovim-control":@"nvim",@"emacs-control":@"emacs",@"nano-control":@"nano",@"micro-control":@"micro",@"helix-control":@"hx"};
    NSString *only=idToKey[identifier];NSDictionary *editors=only?@{only:all[only]}:all;
    NSData *json=[NSJSONSerialization dataWithJSONObject:editors options:0 error:nil];
    NSString *encoded=[[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"#!/usr/bin/env python3\nimport json,sys,shlex\neditors=%@\nfor line in sys.stdin:\n try:\n  m=json.loads(line)\n  if m.get('method')=='initialize':\n   for key,item in editors.items(): print(json.dumps({'jsonrpc':'2.0','method':'command.register','params':{'id':'editor.'+key,'title':'Editor: '+item['title']+' (terminal)','slash':'/'+key}}),flush=True)\n  elif m.get('method')=='command.execute':\n   key=m.get('params',{}).get('id','').split('.')[-1]; query=m.get('params',{}).get('query',''); item=editors.get(key)\n   if item:\n    text='termatica editor '+shlex.quote(key)+((' '+shlex.quote(query)) if query else '')+'\\n'\n    print(json.dumps({'jsonrpc':'2.0','method':'terminal.sendText','params':{'text':text}}),flush=True)\n except Exception as error:\n  print(json.dumps({'jsonrpc':'2.0','method':'ui.notify','params':{'message':'editor control: '+str(error)}}),flush=True)\n",encoded];
}

static NSString *THiddenPathPromptScript(void) {
    return @"# Termatica Hidden Path prompt integration\n"
    @"_termatica_hidden_path_value() {\n"
    @"  local path=\"$PWD\"\n"
    @"  if [ \"$path\" = \"$HOME\" ] || [ \"$path\" = \"/\" ]; then TERMATICA_HIDDEN_PATH_VALUE=\"\"\n"
    @"  elif [ \"${path#\"$HOME\"/}\" != \"$path\" ]; then TERMATICA_HIDDEN_PATH_VALUE=\"${path#\"$HOME\"/}\"\n"
    @"  else TERMATICA_HIDDEN_PATH_VALUE=\"${path#/}\"\n"
    @"  fi\n"
    @"}\n"
    @"_termatica_hidden_path_precmd() {\n"
    @"  _termatica_hidden_path_value\n"
    @"  if [ -n \"$TERMATICA_HIDDEN_PATH_VALUE\" ]; then PS1=\"$TERMATICA_HIDDEN_PATH_VALUE ; \"; else PS1=\"; \"; fi\n"
    @"  if [ -n \"${ZSH_VERSION:-}\" ]; then PROMPT=\"$PS1\"; fi\n"
    @"}\n"
    @"_termatica_hidden_path_action=\"${1:-on}\"\n"
    @"if [ \"$_termatica_hidden_path_action\" = \"on\" ]; then\n"
    @"  if [ -n \"${ZSH_VERSION:-}\" ]; then\n"
    @"    if [ -z \"${TERMATICA_HIDDEN_PATH_SAVED_PROMPT+x}\" ]; then typeset -g TERMATICA_HIDDEN_PATH_SAVED_PROMPT=\"$PROMPT\"; fi\n"
    @"    autoload -Uz add-zsh-hook\n"
    @"    add-zsh-hook -d precmd _termatica_hidden_path_precmd 2>/dev/null\n"
    @"    add-zsh-hook precmd _termatica_hidden_path_precmd\n"
    @"    _termatica_hidden_path_precmd\n"
    @"  elif [ -n \"${BASH_VERSION:-}\" ]; then\n"
    @"    if [ -z \"${TERMATICA_HIDDEN_PATH_SAVED_PS1+x}\" ]; then TERMATICA_HIDDEN_PATH_SAVED_PS1=\"$PS1\"; TERMATICA_HIDDEN_PATH_SAVED_PROMPT_COMMAND=\"${PROMPT_COMMAND:-}\"; fi\n"
    @"    PROMPT_COMMAND=\"_termatica_hidden_path_precmd${TERMATICA_HIDDEN_PATH_SAVED_PROMPT_COMMAND:+;$TERMATICA_HIDDEN_PATH_SAVED_PROMPT_COMMAND}\"\n"
    @"    _termatica_hidden_path_precmd\n"
    @"  fi\n"
    @"else\n"
    @"  if [ -n \"${ZSH_VERSION:-}\" ]; then\n"
    @"    autoload -Uz add-zsh-hook\n"
    @"    add-zsh-hook -d precmd _termatica_hidden_path_precmd 2>/dev/null\n"
    @"    if [ -n \"${TERMATICA_HIDDEN_PATH_SAVED_PROMPT+x}\" ]; then PROMPT=\"$TERMATICA_HIDDEN_PATH_SAVED_PROMPT\"; PS1=\"$PROMPT\"; unset TERMATICA_HIDDEN_PATH_SAVED_PROMPT; fi\n"
    @"  elif [ -n \"${BASH_VERSION:-}\" ]; then\n"
    @"    if [ -n \"${TERMATICA_HIDDEN_PATH_SAVED_PS1+x}\" ]; then PS1=\"$TERMATICA_HIDDEN_PATH_SAVED_PS1\"; PROMPT_COMMAND=\"$TERMATICA_HIDDEN_PATH_SAVED_PROMPT_COMMAND\"; unset TERMATICA_HIDDEN_PATH_SAVED_PS1 TERMATICA_HIDDEN_PATH_SAVED_PROMPT_COMMAND; fi\n"
    @"  fi\n"
    @"fi\n"
    @"unset _termatica_hidden_path_action TERMATICA_HIDDEN_PATH_VALUE\n";
}

static BOOL TWritePlugin(NSString *identifier,NSDictionary *manifest,NSData *script,NSError **error) {NSString *entry=[manifest[@"entry"] isKindOfClass:NSString.class]?manifest[@"entry"]:@"extension";if(!TSafeIdentifier(identifier)||[entry containsString:@"/"]||[entry containsString:@".."]||!script.length){if(error)*error=[NSError errorWithDomain:@"TermaticaModules" code:1 userInfo:@{NSLocalizedDescriptionKey:@"invalid plugin package"}];return NO;}NSString *root=[TEnsureDirectory(@"extensions") stringByAppendingPathComponent:identifier];NSFileManager *fm=NSFileManager.defaultManager;if(![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error])return NO;NSData *json=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];if(![json writeToFile:[root stringByAppendingPathComponent:@"extension.json"] options:NSDataWritingAtomic error:error])return NO;NSString *path=[root stringByAppendingPathComponent:entry];if(![script writeToFile:path options:NSDataWritingAtomic error:error])return NO;return [fm setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:path error:error];}

static BOOL TInstallModule(NSDictionary *item,TConfig *config,NSError **error) {
    NSString *identifier=item[@"id"],*kind=item[@"kind"];
    if(!TSafeIdentifier(identifier))return NO;
    if([kind isEqual:@"themes"]){NSData *data=[NSData dataWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[NSString stringWithFormat:@"Themes/%@.json",identifier]] options:0 error:error];NSDictionary *theme=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:error]:nil;if(![theme isKindOfClass:NSDictionary.class])return NO;NSString *path=[[TEnsureDirectory(@"themes") stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"json"];BOOL ok=[data writeToFile:path options:NSDataWritingAtomic error:error];if(ok)[config useThemeNamed:identifier];return ok;}
    if(![kind isEqual:@"plugins"])return NO;
    NSDictionary *manifest=@{@"id":[NSString stringWithFormat:@"com.termatica.%@",identifier],@"name":identifier,@"version":@"1.0.0",@"entry":@"extension.py"};NSString *script=nil;
    if([identifier isEqual:@"editor-deck"]||[identifier hasSuffix:@"-control"]){script=TEditorControlsScript(identifier);}
    else if([@[@"hyprland-layout",@"hidden-path",@"unicode-rendering",@"osc-integration",@"borderless-window"] containsObject:identifier]){script=@"#!/usr/bin/env python3\nimport sys\nfor line in sys.stdin: pass\n";}
    else {NSString *command=[identifier isEqual:@"pi-bridge"]?@"pi":@"printf '\\033[38;2;122;162;247mTermatica\\033[0m %s\\n'";NSString *slash=[identifier isEqual:@"pi-bridge"]?@"/pi":@"/hello";NSString *title=[identifier isEqual:@"pi-bridge"]?@"Pi: send prompt":@"Hello: write into shell";script=[NSString stringWithFormat:@"#!/usr/bin/env python3\nimport json,sys,shlex\nfor line in sys.stdin:\n try:\n  m=json.loads(line)\n  if m.get('method')=='initialize': print(json.dumps({'jsonrpc':'2.0','method':'command.register','params':{'id':'%@.run','title':'%@','slash':'%@'}}),flush=True)\n  elif m.get('method')=='command.execute':\n   q=m.get('params',{}).get('query',''); print(json.dumps({'jsonrpc':'2.0','method':'terminal.sendText','params':{'text':\"%@ \"+shlex.quote(q)+\"\\n\"}}),flush=True)\n except Exception: pass\n",identifier,title,slash,command];}
    BOOL ok=TWritePlugin(identifier,manifest,[script dataUsingEncoding:NSUTF8StringEncoding],error);
    if(ok&&[identifier isEqual:@"hidden-path"]){NSString *path=[[[TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"] stringByAppendingPathComponent:identifier] stringByAppendingPathComponent:@"prompt.sh"];ok=[[THiddenPathPromptScript() dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:NSDataWritingAtomic error:error];}
    if(ok)[config setPlugin:identifier enabled:YES];return ok;
}

static volatile sig_atomic_t TMenuInterrupted=0;
static void TMenuSignal(int signalNumber){TMenuInterrupted=1;}

static NSString *TConfigProfileDirectory(void){return TEnsureDirectory(@"configs");}
static NSString *TConfigProfilePath(NSString *name){return [[TConfigProfileDirectory() stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"json"];}
static NSArray<NSString *> *TConfigProfileNames(void){NSMutableArray<NSString *> *names=[NSMutableArray array];for(NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:TConfigProfileDirectory() error:nil]?:@[]){NSString *name=file.stringByDeletingPathExtension;if([file.pathExtension.lowercaseString isEqual:@"json"]&&TSafeIdentifier(name))[names addObject:name];}return [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];}
static NSMutableDictionary *TReadActiveConfig(TConfig *config){[config ensureEditableFile];NSData *data=[NSData dataWithContentsOfFile:config.path];id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;return [value isKindOfClass:NSDictionary.class]?[value mutableCopy]:[NSMutableDictionary dictionary];}
static BOOL TWriteJSONDictionary(NSDictionary *dictionary,NSString *path,NSError **error){NSMutableDictionary *normalized=[dictionary mutableCopy];TNormalizeConfigToggles(normalized);NSData *data=[NSJSONSerialization dataWithJSONObject:normalized options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];if(!data)return NO;BOOL ok=[data writeToFile:path options:NSDataWritingAtomic error:error];if(ok)[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];return ok;}
static NSString *TActiveConfigName(TConfig *config){id name=TReadActiveConfig(config)[@"configName"];return [name isKindOfClass:NSString.class]?name:@"custom";}
static NSArray<NSString *> *TOtherConfigProfileNames(TConfig *config){NSString *current=TActiveConfigName(config);return [TConfigProfileNames() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name,NSDictionary *bindings){return ![name isEqual:current];}]];}
static BOOL TValidConfigName(NSString *name){return TSafeIdentifier(name)&&![name isEqual:@"session"];}
static NSString *TSaveConfigNamed(NSString *name,TConfig *config){if(!TValidConfigName(name))return @"[ INVALID ] use letters, numbers, dot, dash or underscore";NSMutableDictionary *profile=[config normalizedDictionary:[config defaults] configName:name];NSError *error=nil;if(!TWriteJSONDictionary(profile,TConfigProfilePath(name),&error)||!TWriteJSONDictionary(profile,config.path,&error))return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not save config"];[config ensureEditableFile];[config reload];TPostCLICommand(@"reload");return [NSString stringWithFormat:@"[ SAVED + CURRENT ] %@",name];}
static NSString *TUseConfigNamed(NSString *name,TConfig *config){if(!TValidConfigName(name))return @"[ INVALID ] config name";NSData *data=[NSData dataWithContentsOfFile:TConfigProfilePath(name)];id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;if(![value isKindOfClass:NSDictionary.class])return [NSString stringWithFormat:@"[ NOT FOUND ] %@",name];NSMutableDictionary *active=[config normalizedDictionary:value configName:name];NSError *error=nil;if(!TWriteJSONDictionary(active,TConfigProfilePath(name),&error)||!TWriteJSONDictionary(active,config.path,&error))return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not select config"];[config ensureEditableFile];[config reload];TPostCLICommand(@"reload");return [NSString stringWithFormat:@"[ CURRENT ] %@",name];}
static NSString *TRenameConfig(NSString *oldName,NSString *newName,TConfig *config){if(!TValidConfigName(oldName)||!TValidConfigName(newName))return @"[ INVALID ] config name";NSMutableDictionary *active=TReadActiveConfig(config);BOOL wasActive=[active[@"configName"] isEqual:oldName];NSString *oldPath=TConfigProfilePath(oldName),*newPath=TConfigProfilePath(newName);NSFileManager *fm=NSFileManager.defaultManager;if(![fm fileExistsAtPath:oldPath])return [NSString stringWithFormat:@"[ NOT FOUND ] %@",oldName];if([fm fileExistsAtPath:newPath])return [NSString stringWithFormat:@"[ EXISTS ] %@",newName];NSError *error=nil;if(![fm moveItemAtPath:oldPath toPath:newPath error:&error])return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not rename config"];NSData *data=[NSData dataWithContentsOfFile:newPath];id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;NSMutableDictionary *profile=[config normalizedDictionary:[value isKindOfClass:NSDictionary.class]?value:@{} configName:newName];TWriteJSONDictionary(profile,newPath,nil);if(wasActive){active[@"configName"]=newName;TWriteJSONDictionary([config normalizedDictionary:active configName:newName],config.path,nil);[config reload];TPostCLICommand(@"reload");}return [NSString stringWithFormat:@"[ RENAMED ] %@ -> %@",oldName,newName];}
static NSString *TDeleteConfig(NSString *name,TConfig *config){if(!TValidConfigName(name))return @"[ INVALID ] config name";NSMutableDictionary *active=TReadActiveConfig(config);BOOL wasActive=[active[@"configName"] isEqual:name];NSString *path=TConfigProfilePath(name);if(![NSFileManager.defaultManager fileExistsAtPath:path])return [NSString stringWithFormat:@"[ NOT FOUND ] %@",name];NSError *error=nil;if(![NSFileManager.defaultManager removeItemAtPath:path error:&error])return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not delete config"];if(wasActive){[active removeObjectForKey:@"configName"];TWriteJSONDictionary([config normalizedDictionary:active configName:nil],config.path,nil);[config ensureEditableFile];[config reload];TPostCLICommand(@"reload");}return [NSString stringWithFormat:@"[ DELETED ] %@",name];}
static NSString *TConfigPrompt(struct termios original,struct termios raw,NSString *prompt){tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);fputs("\033[?25h\n",stdout);fprintf(stdout,"%s",prompt.UTF8String);fflush(stdout);char input[2048]={0};NSString *answer=@"";if(fgets(input,sizeof(input),stdin))answer=[[NSString stringWithUTF8String:input] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);fputs("\033[?25l",stdout);return answer;}
static id TConfigValueAtPath(NSDictionary *dictionary,NSString *path) {
    id value=dictionary;for(NSString *part in [path componentsSeparatedByString:@"."]){if(![value isKindOfClass:NSDictionary.class])return nil;value=value[part];}return value;
}
static void TConfigSetValueAtPath(NSMutableDictionary *dictionary,NSString *path,id value) {
    NSArray<NSString *> *parts=[path componentsSeparatedByString:@"."];NSMutableDictionary *cursor=dictionary;
    for(NSUInteger i=0;i+1<parts.count;i++){id nested=cursor[parts[i]];NSMutableDictionary *next=[nested isKindOfClass:NSDictionary.class]?[nested mutableCopy]:[NSMutableDictionary dictionary];cursor[parts[i]]=next;cursor=next;}
    if(value)cursor[parts.lastObject]=value;else[cursor removeObjectForKey:parts.lastObject];
}
static NSDictionary *TSetting(NSString *label,NSString *path,NSString *type,NSArray *options,NSNumber *minimum,NSNumber *maximum,NSNumber *step) {
    NSMutableDictionary *setting=[@{@"label":label,@"path":path,@"type":type} mutableCopy];if(options)setting[@"options"]=options;if(minimum)setting[@"min"]=minimum;if(maximum)setting[@"max"]=maximum;if(step)setting[@"step"]=step;return setting;
}
static NSArray *TOptionsIncludingCurrent(id current,NSArray *candidates) {
    NSMutableArray *options=[NSMutableArray array];if(current&&current!=NSNull.null)[options addObject:current];for(id candidate in candidates)if(candidate&&![options containsObject:candidate])[options addObject:candidate];return options;
}
static NSArray *TMonospacedFontOptions(NSString *current) {
    NSMutableArray *fonts=[NSMutableArray arrayWithArray:TOptionsIncludingCurrent(current,@[@"Monaco",@"Menlo",@"SF Mono"])];
    for(NSString *family in NSFontManager.sharedFontManager.availableFontFamilies){NSFont *font=[NSFont fontWithName:family size:11];if(font&&(font.fontDescriptor.symbolicTraits&NSFontDescriptorTraitMonoSpace)&&![fonts containsObject:family])[fonts addObject:family];}
    return fonts;
}
static NSArray *TShellOptions(NSString *current) {
    NSMutableArray *shells=[NSMutableArray arrayWithArray:TOptionsIncludingCurrent(current,@[@"/bin/zsh",@"/bin/bash",@"/bin/sh"])];
    NSString *contents=[NSString stringWithContentsOfFile:@"/etc/shells" encoding:NSUTF8StringEncoding error:nil];for(NSString *line in [contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){NSString *path=[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];if([path hasPrefix:@"/"]&&[NSFileManager.defaultManager isExecutableFileAtPath:path]&&![shells containsObject:path])[shells addObject:path];}
    return shells;
}
static NSArray *TShortcutOptions(NSString *current,NSString *fallback) {
    NSMutableArray *options=[NSMutableArray arrayWithArray:TOptionsIncludingCurrent(current,@[fallback?:@"",@""])];
    NSString *key=[[fallback componentsSeparatedByString:@"+"] lastObject]?:@"";
    if(key.length)for(NSString *modifier in @[@"cmd",@"cmd+shift",@"cmd+option",@"cmd+control",@"control",@"control+shift",@"option"]){NSString *shortcut=[NSString stringWithFormat:@"%@+%@",modifier,key];if(![options containsObject:shortcut])[options addObject:shortcut];}
    return options;
}
static NSArray<NSDictionary *> *TUnifiedConfigSections(TConfig *config) {
    NSDictionary *active=TReadActiveConfig(config),*defaults=[config defaults];
    NSMutableArray *pluginRows=[NSMutableArray array];for(NSString *identifier in [config.pluginStates.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)])[pluginRows addObject:TSetting(identifier.uppercaseString,[@"plugins." stringByAppendingString:identifier],@"bool",nil,nil,nil,nil)];
    NSMutableArray *bindingRows=[NSMutableArray array];NSDictionary *defaultBindings=defaults[@"keybindings"];for(NSString *identifier in [config.keybindings.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]){NSString *path=[@"keybindings." stringByAppendingString:identifier];[bindingRows addObject:TSetting(identifier,path,@"option",TShortcutOptions(TConfigValueAtPath(active,path),defaultBindings[identifier]),nil,nil,nil)];}
    NSArray *themes=config.installedThemeNames.count?config.installedThemeNames:@[@"terminal-default"];
    NSArray *colours=@[@"theme",@"#F2FAF8",@"#7DD3FC",@"#7CE38B",@"#FFE083",@"#FF8787",@"#DDB2F4",@"#67B7F7",@"#FFFFFF",@"#000000"];
    id background=TConfigValueAtPath(active,@"colors.background");id foreground=TConfigValueAtPath(active,@"colors.foreground");id cursor=TConfigValueAtPath(active,@"colors.cursor");id accent=TConfigValueAtPath(active,@"colors.accent");id panel=TConfigValueAtPath(active,@"colors.panel");id muted=TConfigValueAtPath(active,@"colors.muted");id selection=TConfigValueAtPath(active,@"colors.selection");id palette=TConfigValueAtPath(active,@"colors.palette");
    id shellArguments=TConfigValueAtPath(active,@"shellArguments");id fontFeatures=TConfigValueAtPath(active,@"fontFeatures");
    return @[
      @{@"title":@"THEMES",@"detail":@"active palette and surface",@"rows":@[TSetting(@"Active theme",@"theme",@"option",themes,nil,nil,nil)]},
      @{@"title":@"TEXT & COLOUR",@"detail":@"font, cursor and ANSI behaviour",@"rows":@[
        TSetting(@"Font name",@"fontName",@"option",TMonospacedFontOptions(config.fontName),nil,nil,nil),TSetting(@"Font size",@"fontSize",@"number",nil,@8,@48,@1),
        TSetting(@"Font features",@"fontFeatures",@"option",TOptionsIncludingCurrent(fontFeatures,@[@[],@[@"calt"],@[@"liga"],@[@"calt",@"liga"],@[@"calt",@"liga",@"zero"],@[@"ss01"],@[@"ss02"]]),nil,nil,nil),
        TSetting(@"Text colour mode",@"textColorMode",@"option",@[@"ansi",@"spectrum"],nil,nil,nil),TSetting(@"Padding",@"padding",@"number",nil,@0,@40,@1),
        TSetting(@"Scrollback",@"scrollback",@"number",nil,@100,@100000,@500),TSetting(@"Background",@"colors.background",@"option",TOptionsIncludingCurrent(background,colours),nil,nil,nil),
        TSetting(@"Foreground",@"colors.foreground",@"option",TOptionsIncludingCurrent(foreground,colours),nil,nil,nil),TSetting(@"Cursor colour",@"colors.cursor",@"option",TOptionsIncludingCurrent(cursor,colours),nil,nil,nil),
        TSetting(@"Accent",@"colors.accent",@"option",TOptionsIncludingCurrent(accent,colours),nil,nil,nil),TSetting(@"Panel",@"colors.panel",@"option",TOptionsIncludingCurrent(panel,colours),nil,nil,nil),
        TSetting(@"Muted",@"colors.muted",@"option",TOptionsIncludingCurrent(muted,colours),nil,nil,nil),TSetting(@"Selection",@"colors.selection",@"option",TOptionsIncludingCurrent(selection,colours),nil,nil,nil),
        TSetting(@"ANSI palette",@"colors.palette",@"option",TOptionsIncludingCurrent(palette,@[@"theme",TStandardPaletteHex()]),nil,nil,nil)
      ]},
      @{@"title":@"APPEARANCE",@"detail":@"opacity, blur and terminal effects",@"rows":@[
        TSetting(@"Background opacity",@"appearance.backgroundOpacity",@"number-theme",nil,@0.08,@1,@0.05),TSetting(@"Window opacity",@"appearance.windowOpacity",@"number-theme",nil,@0.20,@1,@0.05),
        TSetting(@"Blur",@"appearance.blur",@"bool-theme",nil,nil,nil,nil),TSetting(@"Blur material",@"appearance.blurMaterial",@"option-theme",@[@"hud",@"popover",@"sidebar",@"menu",@"under-window"],nil,nil,nil),
        TSetting(@"Glow",@"appearance.glow",@"number-theme",nil,@0,@1,@0.05),TSetting(@"Scanlines",@"appearance.scanlines",@"number-theme",nil,@0,@1,@0.05),
        TSetting(@"Vignette",@"appearance.vignette",@"number-theme",nil,@0,@1,@0.05),TSetting(@"Cursor style",@"appearance.cursorStyle",@"option-theme",@[@"block",@"bar",@"underline"],nil,nil,nil),
        TSetting(@"Renderer",@"appearance.renderer",@"option",@[@"appkit",@"metal"],nil,nil,nil)
      ]},
      @{@"title":@"WINDOW & SURFACES",@"detail":@"window dimensions, corners and shadow",@"rows":@[
        TSetting(@"Initial width",@"window.initialWidth",@"number",nil,@320,@3840,@20),TSetting(@"Initial height",@"window.initialHeight",@"number",nil,@200,@2160,@20),
        TSetting(@"Minimum width",@"window.minimumWidth",@"number",nil,@240,@1920,@20),TSetting(@"Minimum height",@"window.minimumHeight",@"number",nil,@160,@1080,@20),
        TSetting(@"Window corner radius",@"window.cornerRadius",@"number",nil,@0,@64,@1),TSetting(@"Tile corner radius",@"window.tileCornerRadius",@"number",nil,@0,@64,@1),
        TSetting(@"Window shadow",@"window.shadow",@"bool",nil,nil,nil,nil)
      ]},
      @{@"title":@"TABS & TILING",@"detail":@"rail, buttons, tiling and interaction",@"rows":@[
        TSetting(@"Rail width",@"tabs.railWidth",@"number",nil,@20,@120,@1),TSetting(@"Animations",@"tabs.animations",@"bool",nil,nil,nil,nil),
        TSetting(@"Animation speed",@"tabs.animationSpeed",@"number",nil,@0.25,@4,@0.10),TSetting(@"Auto hide rail",@"tabs.autoHide",@"bool",nil,nil,nil,nil),
        TSetting(@"Hide delay",@"tabs.hideDelay",@"number",nil,@1,@30,@1),TSetting(@"Tile gap",@"tabs.tileGap",@"number",nil,@0,@48,@1),
        TSetting(@"Screen inset",@"tabs.screenInset",@"number",nil,@0,@120,@1),TSetting(@"Hyprland blur",@"tabs.hyprlandBlur",@"bool",nil,nil,nil,nil),
        TSetting(@"Rail margin",@"tabs.railMargin",@"number",nil,@0,@48,@1),TSetting(@"Rail corner radius",@"tabs.railCornerRadius",@"number",nil,@0,@48,@1),
        TSetting(@"Button corner radius",@"tabs.buttonCornerRadius",@"number",nil,@0,@32,@1),TSetting(@"Button font size",@"tabs.buttonFontSize",@"number",nil,@8,@28,@1),
        TSetting(@"Button inset",@"tabs.buttonInset",@"number",nil,@0,@16,@1),TSetting(@"Minimum item height",@"tabs.minimumHeight",@"number",nil,@12,@64,@1),
        TSetting(@"Maximum item height",@"tabs.maximumHeight",@"number",nil,@12,@96,@1),TSetting(@"Selected opacity",@"tabs.selectedOpacity",@"number",nil,@0,@1,@0.05),
        TSetting(@"Hover opacity",@"tabs.hoverOpacity",@"number",nil,@0,@1,@0.05),TSetting(@"Rail opacity",@"tabs.railOpacity",@"number",nil,@0,@1,@0.05),
        TSetting(@"Blur rail opacity",@"tabs.railBlurOpacity",@"number",nil,@0,@1,@0.05),TSetting(@"Edge opacity",@"tabs.edgeOpacity",@"number",nil,@0,@1,@0.05),
        TSetting(@"Collapsed rail peek",@"tabs.collapsedPeek",@"number",nil,@0,@24,@1)
      ]},
      @{@"title":@"TERMINAL UI",@"detail":@"cursor, scrollbar, scanlines and search",@"rows":@[
        TSetting(@"Cursor thickness",@"terminalUI.cursorThickness",@"number",nil,@1,@8,@1),TSetting(@"Block cursor opacity",@"terminalUI.cursorBlockOpacity",@"number",nil,@0.05,@1,@0.05),
        TSetting(@"Inactive cursor opacity",@"terminalUI.cursorInactiveOpacity",@"number",nil,@0.02,@1,@0.05),TSetting(@"Scrollbar width",@"terminalUI.scrollbarWidth",@"number",nil,@1,@16,@0.5),
        TSetting(@"Scrollbar margin",@"terminalUI.scrollbarMargin",@"number",nil,@0,@32,@1),TSetting(@"Minimum thumb",@"terminalUI.scrollbarMinimumThumb",@"number",nil,@4,@160,@2),
        TSetting(@"Scrollbar opacity",@"terminalUI.scrollbarOpacity",@"number",nil,@0.05,@1,@0.05),TSetting(@"Scanline spacing",@"terminalUI.scanlineSpacing",@"number",nil,@1,@16,@1),
        TSetting(@"Scanline thickness",@"terminalUI.scanlineThickness",@"number",nil,@1,@16,@1),TSetting(@"Vignette layers",@"terminalUI.vignetteLayers",@"number",nil,@1,@24,@1),
        TSetting(@"Search width",@"terminalUI.searchWidth",@"number",nil,@180,@800,@20),TSetting(@"Search height",@"terminalUI.searchHeight",@"number",nil,@24,@80,@2),
        TSetting(@"Search corner radius",@"terminalUI.searchCornerRadius",@"number",nil,@0,@32,@1)
      ]},
      @{@"title":@"MOTION",@"detail":@"launch, terminal and layout timing",@"rows":@[
        TSetting(@"Launch duration",@"motion.launchDuration",@"number",nil,@0.05,@2,@0.05),TSetting(@"Terminal duration",@"motion.terminalDuration",@"number",nil,@0.05,@2,@0.05),
        TSetting(@"Layout duration",@"motion.layoutDuration",@"number",nil,@0.03,@1,@0.03)
      ]},
      @{@"title":@"PLUGINS",@"detail":@"all installed and built-in capabilities",@"rows":pluginRows},
      @{@"title":@"SYSTEM & UPDATES",@"detail":@"shell, memory mode and GitHub releases",@"rows":@[
        TSetting(@"Shell",@"shell",@"option",TShellOptions(config.shell),nil,nil,nil),TSetting(@"Shell arguments",@"shellArguments",@"option",TOptionsIncludingCurrent(shellArguments,@[@[@"-l"],@[],@[@"-i"],@[@"-l",@"-i"]]),nil,nil,nil),
        TSetting(@"Unsafe paste protection",@"system.pasteProtection",@"bool",nil,nil,nil,nil),TSetting(@"Secure password input",@"system.secureKeyboard",@"bool",nil,nil,nil,nil),TSetting(@"Shell integration",@"system.shellIntegration",@"bool",nil,nil,nil,nil),TSetting(@"Clipboard reads",@"system.clipboardRead",@"option",@[@"ask",@"allow",@"deny"],nil,nil,nil),
        TSetting(@"Clipboard writes",@"system.clipboardWrite",@"option",@[@"ask",@"allow",@"deny"],nil,nil,nil),TSetting(@"Check on launch",@"updates.checkOnLaunch",@"bool",nil,nil,nil,nil),
        TSetting(@"Bell style",@"system.bellStyle",@"option",@[@"sound",@"visual",@"both",@"none"],nil,nil,nil),
        TSetting(@"Update repository",@"updates.repository",@"option",TOptionsIncludingCurrent(config.updateRepository,@[@"sebastianmiletic/termatica"]),nil,nil,nil)
      ]},
      @{@"title":@"KEYBINDINGS",@"detail":@"every application shortcut",@"rows":bindingRows}
    ];
}
static NSString *TConfigDisplayValue(id value) {
    if(!value||value==NSNull.null)return @"unset";if([value isKindOfClass:NSNumber.class]){if(CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return [value boolValue]?@"ON":@"OFF";double number=[value doubleValue];return fabs(number-round(number))<0.0001?[NSString stringWithFormat:@"%.0f",number]:[NSString stringWithFormat:@"%.2f",number];}
    if([value isKindOfClass:NSString.class]){if(![value length])return @"DISABLED";NSString *token=[value lowercaseString];if([@[@"on",@"true",@"yes",@"1"] containsObject:token])return @"ON";if([@[@"off",@"false",@"no",@"0"] containsObject:token])return @"OFF";return value;}if([value isKindOfClass:NSArray.class]&&[value isEqual:TStandardPaletteHex()])return @"STANDARD 16";NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];NSString *json=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:[value description];return json.length>42?[[json substringToIndex:39] stringByAppendingString:@"..."]:json;
}
static BOOL TCommitUnifiedConfig(TConfig *config,NSMutableDictionary *dictionary,NSString **message) {
    TNormalizeConfigToggles(dictionary);NSError *error=nil;if(!TWriteJSONDictionary(dictionary,config.path,&error)){if(message)*message=[NSString stringWithFormat:@"FAILED: %@",error.localizedDescription?:@"could not write config"];return NO;}[config ensureEditableFile];[config reload];TPostCLICommand(@"reload");if(message)*message=@"SAVED + RELOADED";return YES;
}
static id TParseConfigInput(NSString *input,NSString *type) {
    if(!input.length)return nil;if([type isEqual:@"number"]||[type isEqual:@"number-theme"]){if([input.lowercaseString isEqual:@"theme"]&&[type hasSuffix:@"theme"])return @"theme";NSScanner *scanner=[NSScanner scannerWithString:input];double value=0;if([scanner scanDouble:&value]&&scanner.isAtEnd)return @(value);return nil;}
    if([type isEqual:@"bool"]||[type isEqual:@"bool-theme"]){NSString *lower=input.lowercaseString;if([lower isEqual:@"theme"]&&[type hasSuffix:@"theme"])return @"theme";if([@[@"on",@"true",@"yes",@"1"] containsObject:lower])return @"on";if([@[@"off",@"false",@"no",@"0"] containsObject:lower])return @"off";return nil;}
    if([type isEqual:@"json"]){NSData *data=[input dataUsingEncoding:NSUTF8StringEncoding];return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];}
    return input;
}
static BOOL TChangeConfigSetting(TConfig *config,NSDictionary *setting,NSInteger direction,NSString *promptValue,NSString **message) {
    NSMutableDictionary *dictionary=TReadActiveConfig(config);NSString *path=setting[@"path"],*type=setting[@"type"];id current=TConfigValueAtPath(dictionary,path);id next=nil;
    if(promptValue)next=TParseConfigInput(promptValue,type);
    else if([type hasPrefix:@"bool"]){if([type hasSuffix:@"theme"]){NSArray *options=@[@"theme",@"on",@"off"];NSString *token=[current isKindOfClass:NSString.class]?[current lowercaseString]:TConfigToggle(TConfigBool(current,NO));NSInteger index=[options indexOfObject:token];if(index==NSNotFound)index=0;next=options[(index+direction+(NSInteger)options.count)%(NSInteger)options.count];}else next=TConfigToggle(!TConfigBool(current,NO));}
    else if([type hasPrefix:@"option"]){NSMutableArray *options=[NSMutableArray array];if([type hasSuffix:@"theme"])[options addObject:@"theme"];[options addObjectsFromArray:setting[@"options"]?:@[]];NSInteger index=[options indexOfObject:current];if(index==NSNotFound)index=0;next=options[(index+direction+(NSInteger)options.count)%(NSInteger)options.count];}
    else if([type hasPrefix:@"number"]){if([type hasSuffix:@"theme"]&&[current isKindOfClass:NSString.class])next=setting[@"min"];else if([type hasSuffix:@"theme"]&&direction<0&&[current doubleValue]<=[setting[@"min"] doubleValue])next=@"theme";else{double value=[current doubleValue]+direction*[setting[@"step"] doubleValue];next=@(MAX([setting[@"min"] doubleValue],MIN([setting[@"max"] doubleValue],value)));}}
    if(!next){if(message)*message=@"INVALID VALUE";return NO;}TConfigSetValueAtPath(dictionary,path,next);return TCommitUnifiedConfig(config,dictionary,message);
}
static void TDrawUnifiedRoot(NSArray<NSDictionary *> *sections,NSUInteger selected,TConfig *config,NSString *message) {
    fputs("\033[2J\033[H\033[38;2;122;162;247m  TERMATICA CONFIG / SETTINGS\n\033[0m",stdout);fprintf(stdout,"\033[38;2;107;114;128m  current  %-24s  file  %s\033[0m\n\n",TActiveConfigName(config).UTF8String,config.path.fileSystemRepresentation);
    NSArray *titles=[sections valueForKey:@"title"],*details=[sections valueForKey:@"detail"];
    for(NSUInteger i=0;i<titles.count;i++){BOOL active=i==selected;fputs(active?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-20.20s  %-48.48s\033[0m\n",active?'>':' ',[titles[i] UTF8String],[details[i] UTF8String]);}
    fputs("\n\033[38;2;107;114;128m  UP/DOWN move   ENTER open   ESC/Q config files\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m  %s\033[0m",message.UTF8String);fflush(stdout);
}
static BOOL TReadMenuKey(unsigned char *key,NSInteger *direction) {
    *direction=0;if(read(STDIN_FILENO,key,1)!=1)return NO;if(*key!=27)return YES;
    struct pollfd descriptor={.fd=STDIN_FILENO,.events=POLLIN};if(poll(&descriptor,1,60)<=0){*key='q';return YES;}
    unsigned char prefix=0;if(read(STDIN_FILENO,&prefix,1)!=1||(prefix!='['&&prefix!='O')){*key='q';return YES;}
    descriptor.revents=0;if(poll(&descriptor,1,60)<=0){*key='q';return YES;}unsigned char final=0;if(read(STDIN_FILENO,&final,1)!=1){*key='q';return YES;}
    if(final=='A')*key='k';else if(final=='B')*key='j';else if(final=='C'){*key='l';*direction=1;}else if(final=='D'){*key='h';*direction=-1;}else *key='q';return YES;
}
static void TDrawConfigFilesHome(NSArray<NSString *> *names,NSUInteger selected,TConfig *config,NSString *message) {
    fputs("\033[2J\033[H\033[38;2;122;162;247m  TERMATICA CONFIG / CONFIG FILES\033[0m\n",stdout);fprintf(stdout,"\033[38;2;107;114;128m  folder  %s\033[0m\n\n",TConfigProfileDirectory().fileSystemRepresentation);
    BOOL current=selected==0;fputs(current?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-8s  %-24.24s  %s\033[0m\n",current?'>':' ',"CURRENT",TActiveConfigName(config).UTF8String,"open config settings");
    for(NSUInteger i=0;i<names.count;i++){BOOL highlighted=selected==i+1;fputs(highlighted?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-8s  %-24.24s  %s\033[0m\n",highlighted?'>':' ',"SAVED",names[i].UTF8String,"make current, then open settings");}
    if(!names.count)fputs("\n\033[38;2;107;114;128m  No saved config files. Press N to create one.\033[0m",stdout);
    fputs("\n\033[38;2;107;114;128m  ENTER settings   N new   R rename   D delete   ESC/Q quit\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m  %s\033[0m",message.UTF8String);fflush(stdout);
}
static BOOL TRunConfigFilesPanel(TConfig *config,struct termios original,struct termios raw,NSString **lastMessage) {
    NSUInteger selected=0;NSString *message=*lastMessage;while(!TMenuInterrupted){NSArray *names=TOtherConfigProfileNames(config);NSUInteger count=names.count+1;selected=MIN(selected,count-1);TDrawConfigFilesHome(names,selected,config,message);unsigned char key=0;NSInteger direction=0;if(!TReadMenuKey(&key,&direction))continue;if(key=='q'||key=='Q'){*lastMessage=message;return NO;}if(key=='j'||key=='J')selected=(selected+1)%count;else if(key=='k'||key=='K')selected=(selected+count-1)%count;else if(key=='\r'||key=='\n'){if(selected>0)message=TUseConfigNamed(names[selected-1],config);*lastMessage=message;return YES;}else if(key=='n'||key=='N'){NSString *name=TConfigPrompt(original,raw,@"new config name: ");message=name.length?TSaveConfigNamed(name,config):@"CANCELLED";if([message hasPrefix:@"[ SAVED"]){*lastMessage=message;return YES;}}else if(key=='r'||key=='R'){NSString *oldName=selected?names[selected-1]:TActiveConfigName(config);if(![NSFileManager.defaultManager fileExistsAtPath:TConfigProfilePath(oldName)]){message=@"CURRENT is not a saved config file";continue;}NSString *name=TConfigPrompt(original,raw,[NSString stringWithFormat:@"rename %@ to: ",oldName]);message=name.length?TRenameConfig(oldName,name,config):@"CANCELLED";}else if(key=='d'||key=='D'){NSString *name=selected?names[selected-1]:TActiveConfigName(config);if(![NSFileManager.defaultManager fileExistsAtPath:TConfigProfilePath(name)]){message=@"CURRENT is not a saved config file";continue;}NSString *answer=TConfigPrompt(original,raw,[NSString stringWithFormat:@"delete %@? [y/N]: ",name]);message=[answer.lowercaseString isEqual:@"y"]?TDeleteConfig(name,config):@"CANCELLED";}}
    *lastMessage=message;return NO;
}
static NSString *TRunSettingsPanel(TConfig *config,NSDictionary *section) {
    NSUInteger selected=0;NSString *message=nil;while(YES){NSArray *rows=section[@"rows"];selected=MIN(selected,rows.count?rows.count-1:0);NSMutableDictionary *dictionary=TReadActiveConfig(config);fputs("\033[2J\033[H",stdout);fprintf(stdout,"\033[38;2;122;162;247m  TERMATICA CONFIG / %s\033[0m\n\n",[section[@"title"] UTF8String]);
        for(NSUInteger i=0;i<rows.count;i++){NSDictionary *row=rows[i];BOOL active=i==selected;NSString *value=TConfigDisplayValue(TConfigValueAtPath(dictionary,row[@"path"]));fputs(active?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-24.24s  %-43.43s\033[0m\n",active?'>':' ',[row[@"label"] UTF8String],value.UTF8String);}
        fputs("\n\033[38;2;107;114;128m  UP/DOWN move   LEFT/RIGHT change   ENTER next choice   ESC/Q back\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m  %s\033[0m",message.UTF8String);fflush(stdout);unsigned char key=0;NSInteger direction=0;if(!TReadMenuKey(&key,&direction))continue;if(key=='q'||key=='Q')return message;if(!rows.count)continue;if(key=='j'||key=='J')selected=(selected+1)%rows.count;else if(key=='k'||key=='K')selected=(selected+rows.count-1)%rows.count;else if(key=='h'||key=='H'||key=='l'||key=='L'||key=='\r'||key=='\n')TChangeConfigSetting(config,rows[selected],direction?:((key=='h'||key=='H')?-1:1),nil,&message);}
}
static int TRunUnifiedConfigCLI(int argc,const char *argv[],TConfig *config) {
    if(argc>=3){NSString *action=[[NSString stringWithUTF8String:argv[2]] lowercaseString];if([action isEqual:@"list"]){fprintf(stdout,"current\t%s\n",TActiveConfigName(config).UTF8String);for(NSString *name in TOtherConfigProfileNames(config))fprintf(stdout,"saved\t%s\n",name.UTF8String);return 0;}if([action isEqual:@"get"]&&argc==4){id value=TConfigValueAtPath(TReadActiveConfig(config),[NSString stringWithUTF8String:argv[3]]);if(!value)return 1;fprintf(stdout,"%s\n",TConfigDisplayValue(value).UTF8String);return 0;}if([action isEqual:@"set"]&&argc>=5){NSString *path=[NSString stringWithUTF8String:argv[3]];NSMutableArray *parts=[NSMutableArray array];for(int i=4;i<argc;i++)[parts addObject:[NSString stringWithUTF8String:argv[i]]];NSString *input=[parts componentsJoinedByString:@" "];NSMutableDictionary *dictionary=TReadActiveConfig(config);id current=TConfigValueAtPath(dictionary,path),value=nil;BOOL toggle=[path hasPrefix:@"plugins."]||([current isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)current)==CFBooleanGetTypeID())||([current isKindOfClass:NSString.class]&&([@[@"on",@"off",@"true",@"false",@"yes",@"no"] containsObject:[current lowercaseString]]));if(toggle)value=TParseConfigInput(input,@"bool");else{NSData *data=[input dataUsingEncoding:NSUTF8StringEncoding];value=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil]?:input;}if(!value){fputs("termatica config: expected ON or OFF\n",stderr);return 2;}TConfigSetValueAtPath(dictionary,path,value);NSString *message=nil;if(!TCommitUnifiedConfig(config,dictionary,&message))return 1;id committed=TConfigValueAtPath(TReadActiveConfig(config),path);fprintf(stdout,"%s\t%s\n",path.UTF8String,TConfigDisplayValue(committed).UTF8String);return 0;}NSString *result=nil;if([action isEqual:@"create"]&&argc==4)result=TSaveConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"use"]&&argc==4)result=TUseConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"rename"]&&argc==5)result=TRenameConfig([NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[4]],config);else if([action isEqual:@"delete"]&&argc==4)result=TDeleteConfig([NSString stringWithUTF8String:argv[3]],config);else{fputs("usage: termatica config [list|get PATH|set PATH VALUE|create NAME|use NAME|rename OLD NEW|delete NAME]\n",stderr);return 2;}fprintf(stdout,"%s\n",result.UTF8String);return [result containsString:@"FAILED"]||[result containsString:@"INVALID"]||[result containsString:@"NOT FOUND"]||[result containsString:@"EXISTS"]?1:0;}
    struct termios original;if(!isatty(STDIN_FILENO)||!isatty(STDOUT_FILENO)||tcgetattr(STDIN_FILENO,&original)!=0){fputs("termatica config requires a terminal; use 'termatica config-file' for JSON or config subcommands for scripts.\n",stderr);return 2;}struct termios raw=original;raw.c_lflag&=~(ICANON|ECHO);raw.c_iflag&=~(IXON|ICRNL);raw.c_cc[VMIN]=1;raw.c_cc[VTIME]=0;tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);void(*previous)(int)=signal(SIGINT,TMenuSignal);TMenuInterrupted=0;NSString *message=nil;fputs("\033[?25l",stdout);
    while(!TMenuInterrupted&&TRunConfigFilesPanel(config,original,raw,&message)){NSArray *sections=TUnifiedConfigSections(config);NSUInteger selected=0;BOOL backToFiles=NO;while(!TMenuInterrupted&&!backToFiles){NSUInteger count=sections.count;selected=MIN(selected,count-1);TDrawUnifiedRoot(sections,selected,config,message);unsigned char key=0;NSInteger direction=0;if(!TReadMenuKey(&key,&direction))continue;if(key=='q'||key=='Q')backToFiles=YES;else if(key=='j'||key=='J')selected=(selected+1)%count;else if(key=='k'||key=='K')selected=(selected+count-1)%count;else if(key=='\r'||key=='\n')message=TRunSettingsPanel(config,sections[selected]);}}
    tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);signal(SIGINT,previous);fputs("\033[?25h\033[0m\n",stdout);return TMenuInterrupted?130:0;
}

static NSDictionary *TModuleItemNamed(NSString *identifier) {for(NSDictionary *item in TModuleItems())if([item[@"id"] isEqual:identifier])return item;return nil;}
static void TInstallConfiguredPlugins(TConfig *config) {
    for(NSString *identifier in config.pluginStates){
        if(!TConfigBool(config.pluginStates[identifier],NO)||[config isPluginInstalled:identifier])continue;
        NSDictionary *item=TModuleItemNamed(identifier);if(![item[@"kind"] isEqual:@"plugins"])continue;
        NSError *error=nil;if(!TInstallModule(item,config,&error))TLog(@"configured plugin %@ could not be installed: %@",identifier,error.localizedDescription);
    }
}

static int TRunEditorCLI(int argc,const char *argv[]) {
    NSDictionary *editors=@{@"vim":@[@"vim"],@"vi":@[@"vim"],@"nvim":@[@"nvim"],@"emacs":@[@"emacs",@"-nw"],@"nano":@[@"nano"],@"micro":@[@"micro"],@"hx":@[@"hx"],@"helix":@[@"hx"]};
    if(argc<3||!strcmp(argv[2],"list")){fputs("Terminal editors: vim, nvim, emacs, nano, micro, hx\nUsage: termatica editor <name> [file ...]\n",stdout);return argc<3?2:0;}
    NSString *name=[[NSString stringWithUTF8String:argv[2]] lowercaseString];NSArray<NSString *> *prefix=editors[name];if(!prefix){fprintf(stderr,"termatica: unsupported editor: %s\n",argv[2]);return 2;}
    NSUInteger extra=(NSUInteger)MAX(0,argc-3),count=prefix.count+extra;char **editorArgv=calloc(count+1,sizeof(char *));for(NSUInteger i=0;i<prefix.count;i++)editorArgv[i]=(char *)prefix[i].UTF8String;for(NSUInteger i=0;i<extra;i++)editorArgv[prefix.count+i]=(char *)argv[3+i];editorArgv[count]=NULL;execvp(editorArgv[0],editorArgv);fprintf(stderr,"termatica: %s is not installed or not in PATH\n",editorArgv[0]);free(editorArgv);return 127;
}

static NSString *TCompletionScript(NSString *shell) {
    NSString *commands=@"benchmark bench config config-file update reload editor run completions help version b c cf u r e x h v",*configActions=@"list get set create use rename delete",*editors=@"vim nvim emacs nano micro hx";
    if([shell isEqual:@"zsh"])return [NSString stringWithFormat:@"#compdef termatica t\nlocal -a commands\ncommands=(%@)\nif (( CURRENT == 2 )); then compadd -- $commands; return; fi\ncase $words[2] in\n  benchmark|bench|b) (( CURRENT == 3 )) && _values 'scope' all a ;;\n  config|c) (( CURRENT == 3 )) && _values 'action' %@ ;;\n  config-file|cf) (( CURRENT == 3 )) && _values 'action' path ;;\n  update|u) (( CURRENT == 3 )) && _values 'action' check ;;\n  editor|e) (( CURRENT == 3 )) && _values 'editor' %@ || _files ;;\n  completions) _values 'shell' zsh bash fish install path ;;\nesac\n",commands,configActions,editors];
    if([shell isEqual:@"bash"])return [NSString stringWithFormat:@"_termatica_complete() {\n  local cur=\"${COMP_WORDS[COMP_CWORD]}\" command=\"${COMP_WORDS[1]}\" words=\"%@\"\n  if (( COMP_CWORD == 1 )); then COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") ); return; fi\n  case \"$command\" in\n    benchmark|bench|b) words=\"all a\" ;;\n    config|c) words=\"%@\" ;;\n    config-file|cf) words=\"path\" ;;\n    update|u) words=\"check\" ;;\n    editor|e) words=\"%@\" ;;\n    completions) words=\"zsh bash fish install path\" ;;\n  esac\n  COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") )\n}\ncomplete -F _termatica_complete termatica t\n",commands,configActions,editors];
    if([shell isEqual:@"fish"])return [NSString stringWithFormat:@"for __termaticacmd in termatica t\ncomplete -c $__termaticacmd -f -n 'not __fish_seen_subcommand_from %@' -a '%@'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from benchmark bench b' -a 'all a'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from config c' -a '%@'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from config-file cf' -a 'path'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from update u' -a 'check'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from editor e' -a '%@'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish install path'\nend\n",commands,commands,configActions,editors];
    return nil;
}
static NSString *TZshCompletionBootstrap(void) {
    return @"typeset -g _termatica_completion_dir=\"${${(%):-%N}:A:h}\"\n"
           @"fpath=(\"$_termatica_completion_dir\" $fpath)\n"
           @"autoload -Uz compinit\n"
           @"if (( ! $+functions[compdef] )); then compinit -i; fi\n"
           @"autoload -Uz _termatica\n"
           @"compdef _termatica termatica t\n"
           @"unset _termatica_completion_dir\n";
}
static BOOL TAppendCompletionHook(NSString *path,NSString *marker,NSString *line) {
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];NSNumber *permissions=attributes[NSFilePosixPermissions]?:@0644;
    NSData *existingData=[NSData dataWithContentsOfFile:path];NSString *existing=existingData?[[NSString alloc]initWithData:existingData encoding:NSUTF8StringEncoding]:@"";
    if([existing containsString:marker])return YES;
    NSMutableString *next=[existing mutableCopy]?:[NSMutableString string];if(next.length&&![next hasSuffix:@"\n"])[next appendString:@"\n"];[next appendFormat:@"\n%@\n%@\n",marker,line];
    NSError *error=nil;BOOL ok=[[next dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:NSDataWritingAtomic error:&error];if(ok)[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:permissions} ofItemAtPath:path error:nil];return ok;
}
static BOOL TInstallCompletionFiles(NSString *root,BOOL integrateShell) {
    NSDictionary *files=@{@"_termatica":TCompletionScript(@"zsh"),@"termatica.zsh":TZshCompletionBootstrap(),@"termatica.bash":TCompletionScript(@"bash"),@"termatica.fish":TCompletionScript(@"fish")};
    for(NSString *name in files){NSString *path=[root stringByAppendingPathComponent:name];if(![[files[name] dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:NSDataWritingAtomic error:nil])return NO;[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0644} ofItemAtPath:path error:nil];}
    if(!integrateShell)return YES;
    NSString *shell=[NSProcessInfo.processInfo.environment[@"SHELL"] lastPathComponent].lowercaseString;
    if([shell containsString:@"zsh"]){NSString *line=@"[ -r \"$HOME/.config/termatica/completions/termatica.zsh\" ] && source \"$HOME/.config/termatica/completions/termatica.zsh\"";if(!TAppendCompletionHook([NSHomeDirectory() stringByAppendingPathComponent:@".zshrc"],@"# Termatica completions",line))return NO;}
    else if([shell containsString:@"bash"]){NSString *line=@"[ -r \"$HOME/.config/termatica/completions/termatica.bash\" ] && source \"$HOME/.config/termatica/completions/termatica.bash\"";if(!TAppendCompletionHook([NSHomeDirectory() stringByAppendingPathComponent:@".bashrc"],@"# Termatica completions",line))return NO;}
    else if([shell containsString:@"fish"]){NSString *fishRoot=[NSHomeDirectory() stringByAppendingPathComponent:@".config/fish/completions"];[NSFileManager.defaultManager createDirectoryAtPath:fishRoot withIntermediateDirectories:YES attributes:nil error:nil];NSData *fish=[files[@"termatica.fish"] dataUsingEncoding:NSUTF8StringEncoding];if(![fish writeToFile:[fishRoot stringByAppendingPathComponent:@"termatica.fish"] options:NSDataWritingAtomic error:nil])return NO;}
    return YES;
}
static int TRunCompletionsCLI(int argc,const char *argv[]) {
    if(argc<3){fputs("usage: termatica completions [zsh|bash|fish|install|path]\n",stderr);return 2;}NSString *action=[[NSString stringWithUTF8String:argv[2]] lowercaseString],*root=TEnsureDirectory(@"completions");if([action isEqual:@"path"]){fprintf(stdout,"%s\n",root.fileSystemRepresentation);return 0;}if([action isEqual:@"install"]){BOOL isolated=getenv("TERMATICA_CONFIG_DIR")!=NULL;if(!TInstallCompletionFiles(root,!isolated)){fputs("termatica completions: installation failed\n",stderr);return 1;}fprintf(stdout,"installed completions in %s%s\n",root.fileSystemRepresentation,isolated?"":" and activated them for the current shell family");return 0;}NSString *script=TCompletionScript(action);if(!script){fputs("termatica completions: expected zsh, bash, fish, install or path\n",stderr);return 2;}fputs(script.UTF8String,stdout);return 0;
}

static NSString *TCurrentVersion(void) {NSString *version=NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];return [version isKindOfClass:NSString.class]?version:@"0.0.0";}
static NSComparisonResult TCompareVersions(NSString *left,NSString *right) {NSString *a=[left hasPrefix:@"v"]?[left substringFromIndex:1]:left,*b=[right hasPrefix:@"v"]?[right substringFromIndex:1]:right;return [a compare:b options:NSNumericSearch];}
static NSData *TRunTaskOutput(NSString *executable,NSArray<NSString *> *arguments,NSString *directory,int *status,NSError **error) {
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:executable];task.arguments=arguments;if(directory.length)task.currentDirectoryURL=[NSURL fileURLWithPath:directory];NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;task.standardError=NSFileHandle.fileHandleWithNullDevice;
    if(![task launchAndReturnError:error]){if(status)*status=-1;return nil;}NSData *data=[pipe.fileHandleForReading readDataToEndOfFile];[task waitUntilExit];if(status)*status=task.terminationStatus;return data;
}
static BOOL TRunTask(NSString *executable,NSArray<NSString *> *arguments,NSString *directory,NSError **error) {int status=0;TRunTaskOutput(executable,arguments,directory,&status,error);if(status==0)return YES;if(error&&!*error)*error=[NSError errorWithDomain:@"TermaticaUpdate" code:status userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@ exited with status %d",executable.lastPathComponent,status]}];return NO;}
static NSDictionary *TLatestRelease(NSString *repository,NSError **error) {
    const char *override=getenv("TERMATICA_UPDATE_API");NSString *url=override&&*override?[NSString stringWithUTF8String:override]:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest",repository];
    int status=0;NSData *data=TRunTaskOutput(@"/usr/bin/curl",@[@"-fsSL",@"--connect-timeout",@"4",@"--max-time",@"15",@"-H",@"Accept: application/vnd.github+json",@"-H",@"X-GitHub-Api-Version: 2022-11-28",@"-A",@"Termatica-Updater",url],nil,&status,error);
    if(status!=0||!data.length){if(error&&!*error)*error=[NSError errorWithDomain:@"TermaticaUpdate" code:status userInfo:@{NSLocalizedDescriptionKey:@"could not reach the GitHub release service"}];return nil;}id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];if(![value isKindOfClass:NSDictionary.class]||![value[@"tag_name"] isKindOfClass:NSString.class]){if(error&&!*error)*error=[NSError errorWithDomain:@"TermaticaUpdate" code:2 userInfo:@{NSLocalizedDescriptionKey:@"GitHub returned invalid release metadata"}];return nil;}return value;
}
static NSDictionary *TReleaseAsset(NSDictionary *release,NSString *name) {for(NSDictionary *asset in [release[@"assets"] isKindOfClass:NSArray.class]?release[@"assets"]:@[])if([asset[@"name"] isEqual:name])return asset;return nil;}
static NSString *TSHA256(NSString *path,NSError **error) {int status=0;NSData *data=TRunTaskOutput(@"/usr/bin/shasum",@[@"-a",@"256",path],nil,&status,error);if(status!=0||!data.length)return nil;NSString *output=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];return [[[output componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] firstObject] lowercaseString];}
static BOOL TArchiveIsBounded(NSString *path,NSError **error) {
    int status=0;NSData *data=TRunTaskOutput(@"/usr/bin/zipinfo",@[@"-l",path],nil,&status,error);if(status!=0||!data.length)return NO;NSString *listing=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];NSUInteger entries=0;unsigned long long expanded=0;
    for(NSString *line in [listing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){NSArray *raw=[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];NSMutableArray *fields=[NSMutableArray array];for(NSString *field in raw)if(field.length)[fields addObject:field];if(fields.count<10||![fields[1] isEqual:@"2.1"])continue;entries++;expanded+=[fields[3] longLongValue];NSString *name=fields.lastObject;if(name.isAbsolutePath||[[name pathComponents] containsObject:@".."]||entries>4096||expanded>268435456ULL){if(error)*error=[NSError errorWithDomain:@"TermaticaUpdate" code:3 userInfo:@{NSLocalizedDescriptionKey:@"release archive exceeds safety limits"}];return NO;}}
    return entries>0;
}
static int TRunUpdateCLI(int argc,const char *argv[],TConfig *config) {
    BOOL checkOnly=argc>=3&&(!strcmp(argv[2],"check")||!strcmp(argv[2],"--check"));NSError *error=nil;fprintf(stdout,"Checking GitHub for Termatica updates...\n");NSDictionary *release=TLatestRelease(config.updateRepository,&error);if(!release){fprintf(stderr,"termatica update: %s\n",(error.localizedDescription?:@"update check failed").UTF8String);return 1;}
    NSString *tag=release[@"tag_name"],*current=TCurrentVersion();if(TCompareVersions(tag,current)!=NSOrderedDescending){fprintf(stdout,"Termatica %s is current. Latest GitHub release: %s.\n",current.UTF8String,tag.UTF8String);return 0;}fprintf(stdout,"Update available: %s -> %s\n",current.UTF8String,tag.UTF8String);if(checkOnly)return 10;
    NSDictionary *asset=TReleaseAsset(release,@"Termatica-macOS-universal.zip");NSString *download=[asset[@"browser_download_url"] isKindOfClass:NSString.class]?asset[@"browser_download_url"]:nil,*digest=[asset[@"digest"] isKindOfClass:NSString.class]?asset[@"digest"]:nil;NSString *expected=[digest hasPrefix:@"sha256:"]?[[digest substringFromIndex:7] lowercaseString]:@"";NSCharacterSet *hex=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];if(!download.length||expected.length!=64||[expected rangeOfCharacterFromSet:hex.invertedSet].location!=NSNotFound){fputs("termatica update: release is missing valid ZIP metadata or a SHA-256 digest\n",stderr);return 1;}
    NSString *temporary=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"termatica-update-%@",NSUUID.UUID.UUIDString]];if(![NSFileManager.defaultManager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]){fprintf(stderr,"termatica update: %s\n",error.localizedDescription.UTF8String);return 1;}NSString *zip=[temporary stringByAppendingPathComponent:@"Termatica.zip"],*unpacked=[temporary stringByAppendingPathComponent:@"unpacked"];fprintf(stdout,"Downloading %s...\n",tag.UTF8String);
    NSMutableArray *curl=[@[@"-fL",@"--connect-timeout",@"5",@"--max-time",@"120",@"--max-filesize",@"67108864",@"-A",@"Termatica-Updater"] mutableCopy];if(![download hasPrefix:@"file://"])[curl addObjectsFromArray:@[@"--proto",@"=https",@"--tlsv1.2"]];[curl addObjectsFromArray:@[@"-o",zip,download]];BOOL ok=TRunTask(@"/usr/bin/curl",curl,nil,&error);NSString *actual=ok?TSHA256(zip,&error):nil;if(!ok||![actual isEqual:expected]||!TArchiveIsBounded(zip,&error)){fprintf(stderr,"termatica update: %s\n",(error.localizedDescription?:@"download checksum did not match or archive was unsafe").UTF8String);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}
    [NSFileManager.defaultManager createDirectoryAtPath:unpacked withIntermediateDirectories:YES attributes:nil error:nil];if(!TRunTask(@"/usr/bin/ditto",@[@"-x",@"-k",zip,unpacked],nil,&error)){fprintf(stderr,"termatica update: %s\n",error.localizedDescription.UTF8String);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}NSString *source=[unpacked stringByAppendingPathComponent:@"Termatica.app"];NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[source stringByAppendingPathComponent:@"Contents/Info.plist"]];NSString *bundleID=info[@"CFBundleIdentifier"],*version=info[@"CFBundleShortVersionString"];if(![bundleID isEqual:@"com.termatica.Termatica"]||TCompareVersions(version,current)!=NSOrderedDescending||TCompareVersions(version,tag)!=NSOrderedSame){fputs("termatica update: downloaded app identity or version is invalid\n",stderr);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}if(!TRunTask(@"/usr/bin/codesign",@[@"--verify",@"--deep",@"--strict",source],nil,&error)){fprintf(stderr,"termatica update: signature verification failed: %s\n",error.localizedDescription.UTF8String);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}
    const char *targetOverride=getenv("TERMATICA_UPDATE_DESTINATION");NSString *target=targetOverride&&*targetOverride?[NSString stringWithUTF8String:targetOverride]:([NSBundle.mainBundle.bundlePath.pathExtension.lowercaseString isEqual:@"app"]&&[NSBundle.mainBundle.bundlePath hasPrefix:@"/Applications/"]?NSBundle.mainBundle.bundlePath:@"/Applications/Termatica.app");NSString *parent=target.stringByDeletingLastPathComponent,*token=NSUUID.UUID.UUIDString,*stage=[parent stringByAppendingPathComponent:[NSString stringWithFormat:@".Termatica-update-%@.app",token]],*backup=[parent stringByAppendingPathComponent:[NSString stringWithFormat:@".Termatica-backup-%@.app",token]];
    if(!TRunTask(@"/usr/bin/ditto",@[source,stage],nil,&error)){fprintf(stderr,"termatica update: cannot stage app in %s: %s\n",parent.fileSystemRepresentation,error.localizedDescription.UTF8String);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}NSFileManager *fm=NSFileManager.defaultManager;BOOL hadTarget=[fm fileExistsAtPath:target];if(hadTarget&&![fm moveItemAtPath:target toPath:backup error:&error])ok=NO;else if(![fm moveItemAtPath:stage toPath:target error:&error]){ok=NO;if(hadTarget)[fm moveItemAtPath:backup toPath:target error:nil];}else{ok=YES;if(hadTarget)[fm removeItemAtPath:backup error:nil];}
    [fm removeItemAtPath:temporary error:nil];if(!ok){fprintf(stderr,"termatica update: install failed: %s\n",(error.localizedDescription?:@"could not replace the application").UTF8String);return 1;}fprintf(stdout,"Updated Termatica to %s at %s. Restart the app to use it.\n",tag.UTF8String,target.fileSystemRepresentation);return 0;
}

static int TRunFreshBenchmarkMatrix(TConfig *config,BOOL allTerminals,NSString **artifactPath){
    NSString *script=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Benchmarks/benchmark-live-matrix.sh"];
    if(![NSFileManager.defaultManager isExecutableFileAtPath:script]){fprintf(stderr,"termatica benchmark: fresh comparison runner is missing at %s\n",script.fileSystemRepresentation);return 2;}
    NSString *appExecutable=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/MacOS/Termatica"];
    NSString *result=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"termatica-benchmark-result-%@",NSUUID.UUID.UUIDString]];
    NSTask *task=[NSTask new];task.launchPath=@"/bin/zsh";task.arguments=@[script,allTerminals?@"all":@"termatica",config.fontName?:@"Monaco",[NSString stringWithFormat:@"%.1f",config.fontSize],appExecutable,config.path?:@"",result];task.currentDirectoryURL=[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];task.standardInput=NSFileHandle.fileHandleWithNullDevice;task.standardOutput=NSFileHandle.fileHandleWithStandardOutput;task.standardError=NSFileHandle.fileHandleWithStandardError;NSError *error=nil;if(![task launchAndReturnError:&error]){fprintf(stderr,"termatica benchmark: could not start fresh comparison: %s\n",error.localizedDescription.UTF8String);return 2;}[task waitUntilExit];NSString *path=[[NSString stringWithContentsOfFile:result encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];[NSFileManager.defaultManager removeItemAtPath:result error:nil];if(artifactPath)*artifactPath=path.length?path:nil;return task.terminationReason==NSTaskTerminationReasonExit?task.terminationStatus:1;
}

static int TRunCLI(int argc, const char *argv[]) {
    NSString *arg=argc>1?[NSString stringWithUTF8String:argv[1]]:@"--help";
    NSDictionary *quick=@{@"b":@"benchmark",@"c":@"config",@"cf":@"config-file",@"u":@"update",@"r":@"reload",@"e":@"editor",@"x":@"run",@"h":@"help",@"v":@"version"};
    arg=quick[arg]?:arg;
    if([arg isEqual:@"--help"]||[arg isEqual:@"-h"]||[arg isEqual:@"help"]){
        fprintf(stdout,"Termatica %s\n\nUSAGE\n  t <command> [arguments]\n  termatica <command> [arguments]\n\nQUICK\n  t b                Benchmark Termatica now; use saved competitor results\n  t b a              Benchmark all installed comparison terminals now\n  t c                Open config files and settings\n  t cf               Open config.json\n  t u [check]        Update or check for an update\n  t r                Reload saved configuration\n  t e <name> ...     Run a terminal editor\n  t x <name> [text]  Run an enabled extension command\n  t h / t v          Help / version\n\nCONFIGURATION\n  config             Open the complete categorized terminal config UI\n  config-file        Open the authoritative config.json\n  config-file path   Print the authoritative config path\n\nUPDATES\n  update             Download, verify, and install the latest GitHub release\n  update check       Check GitHub without installing\n\nTOOLS\n  benchmark [all]    Benchmark Termatica only, or all comparison terminals\n  reload             Reload saved configuration in the running app\n  editor <name> ...  Run Vim, Neovim, Emacs, Nano, Micro, or Helix\n  run <name> [text]  Run an enabled extension command\n  completions        Generate or install shell completions\n\nFLAGS\n  --help             Show this guide\n  --version          Print the version\n",TCurrentVersion().UTF8String);return 0;
    }
    if([arg isEqual:@"--version"]||[arg isEqual:@"version"]){fprintf(stdout,"Termatica %s\n",TCurrentVersion().UTF8String);return 0;}
    if([arg isEqual:@"__benchmark-window-diagnostics"]){NSDictionary *reply=TRequestCLI(@{@"command":@"benchmarkDiagnostics"},3);if(!reply)return 1;NSData *json=[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingSortedKeys error:nil];if(!json)return 1;fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return [reply[@"ok"] boolValue]?0:1;}
    if([arg isEqual:@"benchmark"]||[arg isEqual:@"bench"]){BOOL allTerminals=NO;if(argc>=3){NSString *scope=[[NSString stringWithUTF8String:argv[2]] lowercaseString];if([scope isEqual:@"a"]||[scope isEqual:@"all"])allTerminals=YES;else{fprintf(stderr,"termatica benchmark: expected 't b' or 't b a'\n");return 2;}}if(argc>3){fprintf(stderr,"termatica benchmark: expected 't b' or 't b a'\n");return 2;}TConfig *benchmarkConfig=[TConfig new];fprintf(stdout,"Benchmarking %s now.\nThe active app stays open; benchmark terminals use isolated fresh processes.\n\n",allTerminals?"all installed comparison terminals":"Termatica");fflush(stdout);NSString *artifact=nil;int matrixStatus=TRunFreshBenchmarkMatrix(benchmarkConfig,allTerminals,&artifact);TPostCLICommand(@"activate");usleep(1000000);fputs("\nMeasuring the running Termatica app with its active configuration...\n",stdout);fflush(stdout);NSDictionary *reply=TRequestCLI(@{@"command":@"benchmark"},15);if(!reply){fputs("termatica benchmark: no reply from the running app. Restart Termatica once to activate the current benchmark service, then run 't b' again. Open terminals were not changed.\n",stderr);return 1;}NSDictionary *current=[reply[@"report"] isKindOfClass:NSDictionary.class]?reply[@"report"]:@{};BOOL shown=artifact.length&&TPostCLIRequest(@{@"command":@"showBenchmark",@"artifactPath":artifact,@"current":current});fprintf(stdout,"%s\n",shown?"Benchmark results opened in Termatica’s native results window.":"Benchmark finished, but the native results window could not be opened.");if(matrixStatus!=0)fputs("\nBenchmark was incomplete. Missing, failed, or timed-out rows remain N/A; no value was fabricated.\n",stderr);return [reply[@"ok"] boolValue]&&matrixStatus==0&&shown?0:1;}
    if([arg isEqual:@"editor"]||[arg isEqual:@"--editor"]||[arg isEqual:@"edit"]||[arg isEqual:@"--edit"])return TRunEditorCLI(argc,argv);
    if([arg isEqual:@"completions"]||[arg isEqual:@"--completions"])return TRunCompletionsCLI(argc,argv);
    if([arg isEqual:@"run"]||[arg isEqual:@"--run"]){if(argc<3){fputs("termatica: run requires an extension command name\n",stderr);return 2;}NSMutableArray *parts=[NSMutableArray array];for(int i=3;i<argc;i++)if(argv[i])[parts addObject:[NSString stringWithUTF8String:argv[i]]];BOOL sent=TPostCLIRequest(@{@"command":@"run",@"name":[NSString stringWithUTF8String:argv[2]],@"query":[parts componentsJoinedByString:@" "]});if(!sent){fputs("termatica: the Termatica app is not running\n",stderr);return 1;}return 0;}
    TConfig *config=[TConfig new];
    if([arg isEqual:@"config"])return TRunUnifiedConfigCLI(argc,argv,config);
    if([arg isEqual:@"config-file"]){[config ensureEditableFile];if(argc>=3&&!strcmp(argv[2],"path"))fprintf(stdout,"%s\n",config.path.fileSystemRepresentation);else{TOpenPath(config.path);fprintf(stdout,"opened %s\n",config.path.fileSystemRepresentation);}return 0;}
    if([arg isEqual:@"update"])return TRunUpdateCLI(argc,argv,config);
    if([arg isEqual:@"--reload"]||[arg isEqual:@"reload"]){TPostCLICommand(@"reload");fputs("reload requested\n",stdout);return 0;}
    fprintf(stderr,"termatica: unknown command: %s\nRun 'termatica --help'.\n",arg.UTF8String);return 2;
}

enum { TBold = 1, TItalic = 2, TUnderline = 4, TInverse = 8, TWide = 16, TContinuation = 32, TCluster = 64 };
enum { TStyleMask = TBold|TItalic|TUnderline|TInverse };
enum { TClusterBase = 0x110000 };

@interface TAppKitRenderBackend : NSObject <TRenderBackend>
@property(nonatomic,copy) void (^presentHandler)(TRenderSnapshot *snapshot);
@property(nonatomic,readwrite) uint64_t lastPresentedGeneration;
- (instancetype)initWithPresentHandler:(void (^)(TRenderSnapshot *snapshot))handler;
@end

@implementation TAppKitRenderBackend {
    BOOL _stopped;
}
- (instancetype)initWithPresentHandler:(void (^)(TRenderSnapshot *))handler {if((self=[super init]))_presentHandler=[handler copy];return self;}
- (NSString *)name {return @"appkit";}
- (BOOL)configureWithMetrics:(TRenderMetrics)metrics error:(NSError **)error {return metrics.rows&&metrics.columns&&metrics.viewportWidth>0&&metrics.viewportHeight>0;}
- (void)presentSnapshot:(TRenderSnapshot *)snapshot {if(_stopped||!snapshot.isValid||snapshot.generation<self.lastPresentedGeneration)return;self.lastPresentedGeneration=snapshot.generation;if(_presentHandler)_presentHandler(snapshot);}
- (void)invalidateCaches {}
- (void)shutdown {_stopped=YES;_presentHandler=nil;}
@end

@interface TTerminalView : NSView <NSTextInputClient>
@property TConfig *config;
@property CGFloat leadingOverlayInset;
@property CGFloat topContentInset;
@property (copy) void (^titleChanged)(NSString *title);
@property (copy) void (^cwdChanged)(NSString *cwd);
@property (copy) void (^focused)(void);
@property (copy) void (^tileDragBegan)(TTerminalView *terminal, NSEvent *event);
@property (copy) void (^tileDragMoved)(TTerminalView *terminal, NSEvent *event);
@property (copy) void (^tileDragEnded)(TTerminalView *terminal, NSEvent *event);
@property BOOL activeTerminal;
@property BOOL verticalSplit;
@property(weak) TTerminalView *splitAnchor;
@property BOOL tiledRendering;
@property NSString *launchDirectory;
@property (copy) void (^splitShortcut)(void);
@property (copy) void (^nextSplitShortcut)(void);
@property (copy) void (^prevSplitShortcut)(void);
- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config;
- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config deferPresentation:(BOOL)deferPresentation;
- (void)preparePresentation;
- (BOOL)startShell;
- (void)stopShellTerminating:(BOOL)terminate;
- (void)drainPendingData;
- (void)consumeData:(NSData *)data;
- (void)consumeBytes:(const uint8_t *)bytes length:(NSUInteger)length;
- (void)putASCIIBytes:(const uint8_t *)bytes length:(NSUInteger)length __attribute__((objc_direct));
- (void)putCodepoint:(uint32_t)codepoint __attribute__((objc_direct));
- (void)putCodepoints:(const uint32_t *)codepoints count:(NSUInteger)count __attribute__((objc_direct));
- (void)handleControl:(uint8_t)control __attribute__((objc_direct));
- (void)handleEscape:(uint8_t)finalByte __attribute__((objc_direct));
- (void)executeCSI:(uint8_t)command prefix:(uint8_t)prefix intermediate:(uint8_t)intermediate parameters:(const int *)parameters count:(NSUInteger)count __attribute__((objc_direct));
- (void)finishOSC:(NSString *)osc __attribute__((objc_direct));
- (void)sendString:(NSString *)string;
- (void)scrollByLines:(NSInteger)lines;
- (void)jumpToPromptDirection:(NSInteger)direction;
- (void)routeWheelLines:(NSInteger)lines event:(NSEvent *)event modifierFlags:(NSEventModifierFlags)modifiers;
- (BOOL)insertDroppedFileURLs:(NSArray<NSURL *> *)files;
- (NSString *)functionalKeySequenceForKeyCode:(unsigned short)key modifier:(NSInteger)modifier;
- (BOOL)shouldForwardApplicationMouseWithModifiers:(NSEventModifierFlags)modifiers;
- (void)startDiagnosticInputCapture;
- (NSData *)finishDiagnosticInputCapture;
- (void)reloadAppearance;
- (void)clearTerminal;
- (void)clearScrollbackPreservingPrompt;
- (void)releaseAnimationLayer;
- (BOOL)usesMetalRenderer;
- (NSString *)visibleText;
- (void)setHiddenPathEnabled:(BOOL)enabled;
- (NSString *)workingDirectory;
- (NSDictionary *)diagnosticState;
- (TRenderSnapshot *)renderSnapshot;
#if TERMATICA_BENCHMARKS
- (void)setDisplaySnapshotForRendererSelfTest:(TRenderSnapshot *)snapshot;
- (BOOL)configureRendererForSnapshotSelfTest:(TRenderSnapshot *)snapshot;
- (void)presentSnapshotForRendererSelfTest:(TRenderSnapshot *)snapshot;
- (NSDictionary *)metalFrameCaptureForRendererSelfTest;
- (NSDictionary *)metalCacheDiagnosticsForRendererSelfTest;
- (NSDictionary *)metalSchedulerDiagnosticsForRendererSelfTest;
- (void)purgeMetalCachesForRendererSelfTest;
#endif
- (void)configureRenderBackend;
- (void)fallbackToAppKitForError:(NSError *)error;
- (uint64_t)presentFrameForBenchmark;
- (uint64_t)presentFrameForBenchmarkWithScrollDelta:(NSInteger)delta;
- (void)renderImage:(CGImageRef)image atRow:(NSUInteger)row col:(NSUInteger)col width:(NSUInteger)w height:(NSUInteger)h scale:(BOOL)scale;
- (void)deleteImageWithID:(NSString *)imageID;
- (void)queryImageWithID:(NSString *)imageID;
- (void)parseSixel:(NSString *)data;
- (void)consumeKittyGraphicBytes:(const uint8_t *)bytes length:(NSUInteger)length;
- (void)parseIterm2Image:(NSString *)osc;
- (void)searchScrollback;
- (void)closeSearch;
- (void)executeSearch:(id)sender;
- (void)navigateSearch:(NSInteger)direction;
- (void)toggleSearchCase:(id)sender;
- (BOOL)cellInSearchResult:(NSUInteger)x y:(NSUInteger)y;
@end

static BOOL TKittyByteParameter(const uint8_t *bytes,NSUInteger headerEnd,uint8_t key,const uint8_t **value,NSUInteger *valueLength){
    for(NSUInteger start=1;start<headerEnd;){NSUInteger end=start;while(end<headerEnd&&bytes[end]!=',')end++;if(end>start+2&&bytes[start]==key&&bytes[start+1]=='='){if(value)*value=bytes+start+2;if(valueLength)*valueLength=end-start-2;return YES;}start=end+1;}return NO;
}
static NSUInteger TKittyByteInteger(const uint8_t *bytes,NSUInteger headerEnd,uint8_t key){
    const uint8_t *value=NULL;NSUInteger length=0,result=0;if(!TKittyByteParameter(bytes,headerEnd,key,&value,&length))return 0;for(NSUInteger i=0;i<length&&value[i]>='0'&&value[i]<='9';i++)result=result*10+value[i]-'0';return result;
}
static void TKittyByteControls(const uint8_t *bytes,NSUInteger headerEnd,uint8_t *action,BOOL *more){
    for(NSUInteger start=1;start<headerEnd;){NSUInteger end=start;while(end<headerEnd&&bytes[end]!=',')end++;if(end>start+2&&bytes[start+1]=='='){if(bytes[start]=='a')*action=bytes[start+2];else if(bytes[start]=='m')*more=bytes[start+2]=='1';}start=end+1;}
}
static BOOL TKittyBase64IsZero(const uint8_t *bytes,NSUInteger length){
    const uint64_t allA=UINT64_C(0x4141414141414141);while(length>=32){uint64_t a,b,c,d;memcpy(&a,bytes,8);memcpy(&b,bytes+8,8);memcpy(&c,bytes+16,8);memcpy(&d,bytes+24,8);if((a^allA)|(b^allA)|(c^allA)|(d^allA))break;bytes+=32;length-=32;}while(length>=8){uint64_t word;memcpy(&word,bytes,8);if(word!=allA)break;bytes+=8;length-=8;}while(length){uint8_t byte=*bytes++;if(byte!='A'&&byte!='=')return NO;length--;}return YES;
}
typedef struct {void *terminal;BOOL visible;} TDecodeContext;
static inline TTerminalView *TDecodeTerminal(void *context){return (__bridge TTerminalView *)((TDecodeContext *)context)->terminal;}
static void TTerminalASCII(void *context,const uint8_t *bytes,size_t length){((TDecodeContext *)context)->visible=YES;[TDecodeTerminal(context) putASCIIBytes:bytes length:length];}
static void TTerminalCodepoint(void *context,uint32_t codepoint){((TDecodeContext *)context)->visible=YES;[TDecodeTerminal(context) putCodepoint:codepoint];}
static void TTerminalCodepoints(void *context,const uint32_t *codepoints,size_t count){((TDecodeContext *)context)->visible=YES;[TDecodeTerminal(context) putCodepoints:codepoints count:count];}
static void TTerminalControl(void *context,uint8_t control){((TDecodeContext *)context)->visible=YES;[TDecodeTerminal(context) handleControl:control];}
static void TTerminalEscape(void *context,uint8_t finalByte){((TDecodeContext *)context)->visible=YES;[TDecodeTerminal(context) handleEscape:finalByte];}
static void TTerminalCSI(void *context,uint8_t finalByte,uint8_t prefix,uint8_t intermediate,const int *parameters,size_t count){((TDecodeContext *)context)->visible=YES;[TDecodeTerminal(context) executeCSI:finalByte prefix:prefix intermediate:intermediate parameters:parameters count:count];}
static void TTerminalString(void *context,const uint8_t *bytes,size_t length){
    if(!length)return;
    uint8_t first=bytes[0];
    if(first=='G'){((TDecodeContext *)context)->visible=YES;[TDecodeTerminal(context) consumeKittyGraphicBytes:bytes length:length];return;}
    BOOL recognized=first=='G'||first=='q'||first=='0'||first=='2'||first=='4'||first=='7'||first=='8'||first=='9'||first=='1'||first=='5'||(length>=3&&bytes[0]=='b'&&bytes[1]=='s'&&bytes[2]=='u')||(length>=3&&bytes[0]=='e'&&bytes[1]=='s'&&bytes[2]=='u');
    if(!recognized)return;
    ((TDecodeContext *)context)->visible=YES;
    NSString *value=[[NSString alloc]initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding]?:@"";
    [TDecodeTerminal(context) finishOSC:value];
}

@implementation TTerminalView {
    int _master;
    pid_t _pid;
    dispatch_source_t _readSource;
    dispatch_queue_t _parseQueue;
    dispatch_queue_t _writeQueue;
    dispatch_queue_t _imageQueue;
    NSObject *_ioLock;
    TCell *_cells;
    NSUInteger *_rowOrder;
    NSUInteger _cols, _rows, _cursorX, _cursorY, _savedX, _savedY;
    NSUInteger _scrollTop, _scrollBottom;
    NSMutableArray<NSData *> *_history;
    NSUInteger _historyStart;
    TCell *_historyCells;
    TCell *_historyBlankRow;
    NSUInteger _historyBlankCols;
    BOOL _historyBlankValid;
    NSUInteger _historyCapacity;
    NSUInteger _historyCount;
    NSUInteger _historyCols;
    NSMutableData *_scratchLine;
    NSMutableData *_glyphScratch;
    NSMutableData *_colorScratch;
    NSMutableData *_diagnosticInput;
    NSMutableArray<NSData *> *_pendingChunks;
    NSUInteger _pendingBytes;
    BOOL _drainScheduled;
    BOOL _displayScheduled;
    BOOL _refreshEnqueued;
    BOOL _readPaused;
    BOOL _backpressureReported;
    BOOL _freshLaunchAwaitingPrompt;
    NSInteger _historyOffset;
    NSUInteger _historyGeneration;
    CGFloat _scrollAccumulator;
    NSFont *_font, *_boldFont, *_italicFont;
    CGFloat _cellWidth, _cellHeight;
    uint32_t _currentFG, _currentBG;
    uint8_t _currentFlags;
    TDecoderState _decoder;
    BOOL _bracketedPaste, _cursorVisible;
    NSMutableDictionary<NSNumber *,NSDictionary *> *_attributeCache;
    NSMutableDictionary<NSNumber *,NSDictionary *> *_wideAttributeCache;
    NSMutableArray<NSString *> *_graphemes;
    NSMutableDictionary<NSString *,NSNumber *> *_graphemeIDs;
    uint64_t _graphemePairKeys[256];
    uint32_t _graphemePairValues[256];
    NSMutableDictionary<NSNumber *,NSString *> *_linksByCell;
    NSString *_currentLink;
    NSMutableArray<NSDictionary *> *_commandMarks;
    NSUInteger _kittyKeyboardFlags;
    NSUInteger _modifyOtherKeys;
    BOOL _alternateScreen;
    BOOL _g0SpecialGraphics, _g1SpecialGraphics, _activeG1;
    uint8_t _charsetDesignation;
    BOOL _applicationCursorKeys;
    BOOL _autoWrap;
    BOOL _alternateScroll;
    BOOL _focusReporting;
    NSUInteger _mouseTrackingMode;
    BOOL _utf8Mouse;
    BOOL _sgrMouse;
    BOOL _urxvtMouse;
    BOOL _pixelMouse;
    BOOL _synchronizedUpdates;
    BOOL _inlineViewportMode;
    NSUInteger _inlineViewportTop;
    NSData *_primaryScreen;
    NSData *_primaryUnderlineStyles;
    NSDictionary *_primaryInlineImages;
    NSDictionary *_primaryKittyImageIDs;
    NSUInteger _primaryCols, _primaryRows, _primaryCursorX, _primaryCursorY;
    BOOL _accessibilityUpdatePending;
    BOOL _secureInputEnabled;
    BOOL _damageValid, _damageFull;
    NSUInteger _damageMinX, _damageMinY, _damageMaxX, _damageMaxY;
    NSPoint _selectionStart, _selectionEnd;
    BOOL _selecting, _hasSelection, _tileDragging;
    BOOL _hiddenPathDesired;
    NSInteger _hiddenPathApplied;
    NSUInteger _hiddenPathGeneration;
    uint32_t _palette256[256];
    CGFloat _cachedGlyphAdvance;
    BOOL _palette256Valid;
    BOOL _cachedUnicodeRendering;
    BOOL _cachedOscIntegration;
    NSMutableDictionary *_inlineImages;
    NSMutableDictionary *_kittyImageIDs;
    NSMutableDictionary *_kittyStoredImages;
    NSMutableDictionary *_kittyPendingImages;
    NSMutableDictionary *_transparentKittyImages;
    NSMutableData *_kittyEncodedGraphic;
    NSString *_kittyGraphicHeader;
    BOOL _kittyEncodedAllZero;
    NSUInteger _kittyEncodedZeroPrefixLength;
    NSMutableDictionary *_animatedImages;
    dispatch_source_t _animationTimer;
    BOOL _cursorBlink;
    BOOL _cursorBlinkVisible;
    NSString *_applicationCursorStyle;
    NSAttributedString *_markedText;
    NSTextField *_imeView;
    dispatch_source_t _blinkTimer;
    BOOL _systemReduceMotion;
    NSString *_terminalTitle;
    uint8_t _currentUnderlineStyle;
    uint8_t *_underlineStyles;
    uint32_t _lastEmittedCodepoint;
    BOOL _hasLastEmittedCodepoint;
    NSString *_searchString;
    NSMutableArray *_searchResults;
    NSUInteger _searchIndex;
    NSTextField *_searchField;
    BOOL _searchActive;
    BOOL _searchCaseSensitive;
    NSTextField *_searchCounter;
    uint64_t _renderGeneration;
    uint32_t _unicodeWidthKeys[256];
    uint8_t _unicodeWidthValues[256];
    id<TRenderBackend> _renderBackend;
    TMetalRenderBackend *_metalBackend;
    TRenderSnapshot *_displaySnapshot;
    BOOL _metalFailed;
    double _lastSnapshotBuildMilliseconds;
    BOOL _presentationReady;
    BOOL _readSourceStarted;
    NSArray<NSNumber *> *_cachedPlainPalette;
 }

- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config {
    return [self initWithFrame:frame config:config deferPresentation:NO];
}
- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config deferPresentation:(BOOL)deferPresentation {
    if ((self = [super initWithFrame:frame])) {
        _config = config; _master = -1; _pid = -1; _hiddenPathApplied=-1; _history = [NSMutableArray array];_ioLock=[NSObject new];_parseQueue=dispatch_queue_create("com.termatica.core",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL,QOS_CLASS_USER_INTERACTIVE,0));
        TDecoderInit(&_decoder);_cursorVisible = YES;_autoWrap=YES;
        _currentFG = _currentBG = TDefaultColor;
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        self.wantsLayer=[self.config.renderer isEqual:@"metal"]||getenv("TERMATICA_RENDERER")!=NULL;
        self.layerContentsRedrawPolicy=NSViewLayerContentsRedrawOnSetNeedsDisplay;
        _cols=80;_rows=24;_scrollBottom=23;
        if(!deferPresentation)[self preparePresentation];
        self.accessibilityLabel = @"Terminal";
    }
    return self;
}
- (void)preparePresentation {
    if(_presentationReady)return;
    _scratchLine=[NSMutableData data];_glyphScratch=[NSMutableData data];_colorScratch=[NSMutableData data];_inlineImages=[NSMutableDictionary dictionary];_kittyImageIDs=[NSMutableDictionary dictionary];_kittyStoredImages=[NSMutableDictionary dictionary];_kittyPendingImages=[NSMutableDictionary dictionary];_transparentKittyImages=[NSMutableDictionary dictionary];_kittyEncodedGraphic=[NSMutableData data];_animatedImages=[NSMutableDictionary dictionary];_searchResults=[NSMutableArray array];_attributeCache=[NSMutableDictionary dictionary];_wideAttributeCache=[NSMutableDictionary dictionary];_graphemes=[NSMutableArray array];_graphemeIDs=[NSMutableDictionary dictionary];_linksByCell=[NSMutableDictionary dictionary];_commandMarks=[NSMutableArray array];
    [self reloadAppearance];
    [self configureRenderBackend];
    _presentationReady=YES;
    if(_readSource&&!_readSourceStarted){_readSourceStarted=YES;dispatch_resume(_readSource);}
}
- (void)dealloc {
    [self stopShellTerminating:YES];
    free(_cells);
    free(_rowOrder);
    free(_historyCells);
    free(_historyBlankRow);
    free(_underlineStyles);
    TDecoderDestroy(&_decoder);
    if(_animationTimer){dispatch_source_cancel(_animationTimer);_animationTimer=nil;}
    if(_blinkTimer){dispatch_source_cancel(_blinkTimer);_blinkTimer=nil;}
    [_renderBackend shutdown];
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)updateIMEView {if(!_markedText.length){_imeView.hidden=YES;return;}if(!_imeView){_imeView=[NSTextField labelWithAttributedString:_markedText];_imeView.bordered=NO;_imeView.drawsBackground=YES;_imeView.wantsLayer=YES;_imeView.layer.cornerRadius=3;[self addSubview:_imeView];}_imeView.attributedStringValue=_markedText;_imeView.font=_font?:[NSFont monospacedSystemFontOfSize:self.config.fontSize weight:NSFontWeightRegular];_imeView.textColor=self.config.foreground;_imeView.backgroundColor=[self.config.background colorWithAlphaComponent:0.96];NSSize size=[_markedText.string sizeWithAttributes:@{NSFontAttributeName:_imeView.font}];CGFloat left=self.config.padding+self.leadingOverlayInset+_cursorX*_cellWidth,top=self.config.padding+self.topContentInset+_cursorY*_cellHeight;_imeView.frame=NSMakeRect(MIN(left,MAX(0,self.bounds.size.width-MAX(_cellWidth,size.width+8))),MIN(top,MAX(0,self.bounds.size.height-_cellHeight)),MAX(_cellWidth,size.width+8),_cellHeight);_imeView.hidden=NO;}
- (BOOL)hasMarkedText{return _markedText.length>0;}
- (NSRange)markedRange{return _markedText.length?NSMakeRange(0,_markedText.length):NSMakeRange(NSNotFound,0);}
- (NSRange)selectedRange{return NSMakeRange(NSNotFound,0);}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selected replacementRange:(NSRange)replacement{if([value isKindOfClass:NSAttributedString.class])_markedText=[value copy];else _markedText=[[NSAttributedString alloc]initWithString:[value description]?:@""];[self updateIMEView];}
- (void)unmarkText{_markedText=nil;[self updateIMEView];}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText{return @[];}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual{return nil;}
- (void)insertText:(id)value replacementRange:(NSRange)replacement{NSString *text=[value isKindOfClass:NSAttributedString.class]?[value string]:[value description];[self unmarkText];if(text.length)[self sendString:text];_hasSelection=NO;[self setNeedsDisplay:YES];}
- (NSUInteger)characterIndexForPoint:(NSPoint)point{return NSNotFound;}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual{if(actual)*actual=range;NSRect cell=NSMakeRect(self.config.padding+self.leadingOverlayInset+_cursorX*_cellWidth,self.config.padding+self.topContentInset+_cursorY*_cellHeight,_cellWidth,_cellHeight);return [self.window convertRectToScreen:[self convertRect:cell toView:nil]];}
- (void)doCommandBySelector:(SEL)selector{if(selector==@selector(insertNewline:))[self sendString:@"\r"];else if(selector==@selector(deleteBackward:))[self sendString:@"\x7f"];else if(selector==@selector(insertTab:))[self sendString:@"\t"];else [self.nextResponder tryToPerform:selector with:self];}
- (void)disableSecureKeyboardInput {if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf disableSecureKeyboardInput];});return;}if(_secureInputEnabled){DisableSecureEventInput();_secureInputEnabled=NO;TLog(@"secure keyboard input disabled");}}
- (void)updateSecureKeyboardInput {if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf updateSecureKeyboardInput];});return;}int master=-1;@synchronized(_ioLock){master=_master;}struct termios attributes={0};BOOL shouldEnable=self.config.secureKeyboard&&self.window.firstResponder==self&&master>=0&&tcgetattr(master,&attributes)==0&&!(attributes.c_lflag&ECHO);if(shouldEnable&&!_secureInputEnabled){if(EnableSecureEventInput()==noErr){_secureInputEnabled=YES;TLog(@"secure keyboard input enabled while PTY echo is disabled");}}else if(!shouldEnable)[self disableSecureKeyboardInput];}
- (BOOL)becomeFirstResponder {BOOL accepted=[super becomeFirstResponder];if(accepted&&_focusReporting)[self sendString:@"\033[I"];if(accepted)[self updateSecureKeyboardInput];return accepted;}
- (BOOL)resignFirstResponder {if(_focusReporting)[self sendString:@"\033[O"];[self disableSecureKeyboardInput];return [super resignFirstResponder];}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {return YES;}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return self.config.backgroundOpacity >= 0.999 && !self.config.blur; }
- (BOOL)usesMetalRenderer {return _metalBackend!=nil;}
- (void)setNeedsDisplay:(BOOL)flag {
    if(flag&&_renderBackend){
        @synchronized(self){[self markAllDamage];}
        if(_metalBackend)[self refreshTextView];
        else{TRenderSnapshot *snapshot=[self renderSnapshot];[self takeDamageRect];[_renderBackend presentSnapshot:snapshot];}
        return;
    }
    [super setNeedsDisplay:flag];
}
- (void)markDamageX:(NSUInteger)x y:(NSUInteger)y width:(NSUInteger)width height:(NSUInteger)height __attribute__((objc_direct)) {
    if(!width||!height||!_cols||!_rows)return;NSUInteger maxX=MIN(_cols,x+width),maxY=MIN(_rows,y+height);if(x>=maxX||y>=maxY)return;
    if(!_damageValid){_damageValid=YES;_damageMinX=x;_damageMinY=y;_damageMaxX=maxX;_damageMaxY=maxY;}
    else{_damageMinX=MIN(_damageMinX,x);_damageMinY=MIN(_damageMinY,y);_damageMaxX=MAX(_damageMaxX,maxX);_damageMaxY=MAX(_damageMaxY,maxY);}
}
- (void)markAllDamage __attribute__((objc_direct)) {_damageValid=YES;_damageFull=YES;_damageMinX=_damageMinY=0;_damageMaxX=_cols;_damageMaxY=_rows;}
- (NSRect)takeDamageRect __attribute__((objc_direct)) {
    @synchronized(self){if(!_damageValid)return NSZeroRect;NSRect rect;if(_damageFull)rect=self.bounds;else{CGFloat pad=self.config.padding+self.leadingOverlayInset,top=self.config.padding+self.topContentInset;rect=NSMakeRect(pad+_damageMinX*_cellWidth,top+_damageMinY*_cellHeight,MAX(1,(_damageMaxX-_damageMinX)*_cellWidth),MAX(1,(_damageMaxY-_damageMinY)*_cellHeight));rect=NSIntersectionRect(NSInsetRect(rect,-1,-1),self.bounds);}_damageValid=_damageFull=NO;return rect;}
}
- (void)configureRenderBackend {
    if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf configureRenderBackend];});return;}
    const char *override=getenv("TERMATICA_RENDERER");NSString *desired=override&&*override?[NSString stringWithUTF8String:override]:self.config.renderer;
    if(![@[@"appkit",@"metal"] containsObject:desired])desired=@"appkit";
    if([desired isEqual:@"appkit"])_metalFailed=NO;
    TRenderMetrics metrics={_rows,_cols,_cellWidth,_cellHeight,self.window.screen.backingScaleFactor?:NSScreen.mainScreen.backingScaleFactor?:1,self.bounds.size.width,self.bounds.size.height};
    if(!metrics.rows||!metrics.columns||metrics.viewportWidth<=0||metrics.viewportHeight<=0)return;
    if(_renderBackend&&[_renderBackend.name isEqual:desired]&&!([desired isEqual:@"metal"]&&_metalFailed)){
        NSError *error=nil;if([_renderBackend configureWithMetrics:metrics error:&error]){if(_metalBackend)[_metalBackend setPresentationFrame:self.bounds scale:metrics.scale];return;}
        [self fallbackToAppKitForError:error];return;
    }
    [_renderBackend shutdown];_renderBackend=nil;_metalBackend=nil;
    if([desired isEqual:@"metal"]&&!_metalFailed){
        self.wantsLayer=YES;
        NSError *error=nil;TMetalRenderBackend *backend=[[TMetalRenderBackend alloc]initWithHostView:self error:&error];
        if(backend&&[backend configureWithMetrics:metrics error:&error]){
            __weak typeof(self) weakSelf=self;backend.failureHandler=^(NSError *failure){[weakSelf fallbackToAppKitForError:failure];};backend.redrawRequested=^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;@synchronized(self){[self markAllDamage];}[self refreshTextView];};
            _metalBackend=backend;_renderBackend=backend;backend.presentationLayer.hidden=NO;self.layer.contents=nil;[self markAllDamage];[self refreshTextView];TLog(@"renderer selected: metal");return;
        }
        _metalFailed=YES;TLog(@"Metal renderer unavailable: %@",error.localizedDescription?:@"unknown error");
    }
    __weak typeof(self) weakSelf=self;
    TAppKitRenderBackend *appkit=[[TAppKitRenderBackend alloc]initWithPresentHandler:^(TRenderSnapshot *snapshot){__strong typeof(weakSelf) self=weakSelf;if(!self)return;self->_displaySnapshot=snapshot;NSRange rows=snapshot.fullDamage?NSMakeRange(0,snapshot.metrics.rows):snapshot.damagedRows;if(!rows.length){[self setNeedsDisplayInRect:self.bounds];return;}CGFloat top=[snapshot.style[@"top"] doubleValue];NSRect damage=NSMakeRect(0,top+rows.location*snapshot.metrics.cellHeight,self.bounds.size.width,rows.length*snapshot.metrics.cellHeight);[self setNeedsDisplayInRect:NSIntersectionRect(NSInsetRect(damage,-1,-1),self.bounds)];}];
    NSError *error=nil;[appkit configureWithMetrics:metrics error:&error];_renderBackend=appkit;self.wantsLayer=self.tiledRendering;[self markAllDamage];[self refreshTextView];TLog(@"renderer selected: appkit");
}
- (void)fallbackToAppKitForError:(NSError *)error {
    if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf fallbackToAppKitForError:error];});return;}
    TLog(@"Metal renderer failure, falling back to AppKit: %@",error.localizedDescription?:@"unknown error");_metalFailed=YES;[_renderBackend shutdown];_renderBackend=nil;_metalBackend=nil;
    __weak typeof(self) weakSelf=self;TAppKitRenderBackend *appkit=[[TAppKitRenderBackend alloc]initWithPresentHandler:^(TRenderSnapshot *snapshot){__strong typeof(weakSelf) self=weakSelf;if(!self)return;self->_displaySnapshot=snapshot;[self setNeedsDisplayInRect:self.bounds];}];
    TRenderMetrics metrics={_rows,_cols,_cellWidth,_cellHeight,self.window.screen.backingScaleFactor?:NSScreen.mainScreen.backingScaleFactor?:1,self.bounds.size.width,self.bounds.size.height};[appkit configureWithMetrics:metrics error:nil];_renderBackend=appkit;[self markAllDamage];[_renderBackend presentSnapshot:[self renderSnapshot]];
}
- (uint64_t)presentFrameForBenchmark {
    @synchronized(self){[self markAllDamage];}
    CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();TRenderSnapshot *snapshot=[self renderSnapshot];_lastSnapshotBuildMilliseconds=(CFAbsoluteTimeGetCurrent()-start)*1000.0;[self takeDamageRect];[_renderBackend presentSnapshot:snapshot];return snapshot.generation;
}
- (uint64_t)presentFrameForBenchmarkWithScrollDelta:(NSInteger)delta {
    @synchronized(self){_historyOffset=MAX(0,MIN((NSInteger)_historyCount,_historyOffset+delta));_hasSelection=NO;[self markAllDamage];}
    return [self presentFrameForBenchmark];
}
- (void)reloadAppearance {
    @synchronized(self) {
    if(_historyCount>self.config.scrollback){
        NSUInteger drop=_historyCount-self.config.scrollback;
        _historyStart=(_historyStart+drop)%_historyCapacity;_historyCount=self.config.scrollback;
    }
    [_attributeCache removeAllObjects];[_wideAttributeCache removeAllObjects];_cachedPlainPalette=nil;
    _cachedUnicodeRendering = self.config.unicodeRendering;
    _cachedOscIntegration = self.config.oscIntegration;
    _font = [NSFont fontWithName:self.config.fontName size:self.config.fontSize] ?: [NSFont monospacedSystemFontOfSize:self.config.fontSize weight:NSFontWeightRegular];
    if(self.config.fontFeatures.count){
        NSMutableArray *features=[NSMutableArray array];
        for(NSString *fn in self.config.fontFeatures){
            NSNumber *ft=nil,*fs=nil;
            if([fn isEqualToString:@"liga"]){ft=@(1);fs=@(2);}else if([fn isEqualToString:@"calt"]){ft=@(0);fs=@(1);}else if([fn isEqualToString:@"ss01"]){ft=@(12);fs=@(0);}else if([fn isEqualToString:@"ss02"]){ft=@(13);fs=@(0);}else if([fn isEqualToString:@"zero"]){ft=@(6);fs=@(3);}
            if(ft&&fs)[features addObject:@{(__bridge NSString *)kCTFontFeatureTypeIdentifierKey:ft,(__bridge NSString *)kCTFontFeatureSelectorIdentifierKey:fs}];
        }
        if(features.count){
            NSDictionary *attrs=@{(__bridge NSString *)kCTFontNameAttribute:_font.fontName,(__bridge NSString *)kCTFontFeaturesAttribute:features,(__bridge NSString *)kCTFontSizeAttribute:@(self.config.fontSize)};
            CTFontDescriptorRef desc=CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
            if(desc){CTFontRef ctFont=CTFontCreateWithFontDescriptor(desc,self.config.fontSize,NULL);if(ctFont){_font=CFBridgingRelease(ctFont);}CFRelease(desc);}
        }
    }
    NSFontManager *fm = NSFontManager.sharedFontManager;
    _boldFont = [fm convertFont:_font toHaveTrait:NSBoldFontMask] ?: _font;
    _italicFont = [fm convertFont:_font toHaveTrait:NSItalicFontMask] ?: _font;
    NSDictionary *a = @{NSFontAttributeName:_font};
    NSSize size = [@"M" sizeWithAttributes:a];
    _cachedGlyphAdvance = size.width;
    _cellWidth = ceil(size.width);
    _cellHeight = ceil(_font.ascender - _font.descender + _font.leading + 2);
    for (NSUInteger i = 0; i < 16; i++) _palette256[i] = i < self.config.palette.count ? TRGB(self.config.palette[i]) : 0;
    const int levels[6] = {0,95,135,175,215,255};
    for (NSUInteger i = 16; i < 232; i++) { NSUInteger q=i-16,r=q/36,g=(q/6)%6,b=q%6; _palette256[i]=((uint32_t)levels[r]<<16)|((uint32_t)levels[g]<<8)|(uint32_t)levels[b]; }
    for (NSUInteger i = 232; i < 256; i++) { int v=8+(i-232)*10; _palette256[i]=((uint32_t)v<<16)|((uint32_t)v<<8)|(uint32_t)v; }
    _palette256Valid = YES;
    [self markAllDamage];
    [self resizeGrid];
    if(_renderBackend){[_renderBackend invalidateCaches];[self configureRenderBackend];}
    [self refreshTextView];
    [self setNeedsDisplay:YES];
    }
}
- (void)releaseAnimationLayer {if(self.layer.animationKeys.count){__weak TTerminalView *weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[weakSelf releaseAnimationLayer];});return;}[self.layer removeAllAnimations];self.wantsLayer=self.tiledRendering||[self usesMetalRenderer];}
- (TCell)blankCell { return (TCell){ .ch=' ', .fg=TDefaultColor, .bg=TDefaultColor, .flags=0 }; }
- (NSUInteger)physicalRowForRow:(NSUInteger)row {return _rowOrder?_rowOrder[row]:row;}
- (TCell *)cellsForRow:(NSUInteger)row {return _cells+[self physicalRowForRow:row]*_cols;}
- (void)resetRowOrder {if(_rowOrder)for(NSUInteger row=0;row<_rows;row++)_rowOrder[row]=row;}
- (void)normalizeRows {
    if(!_cells||!_rowOrder)return;BOOL orderedAlready=YES;for(NSUInteger row=0;row<_rows;row++)if(_rowOrder[row]!=row){orderedAlready=NO;break;}if(orderedAlready)return;
    TCell *ordered=malloc(_rows*_cols*sizeof(TCell));uint8_t *orderedUnderlines=_underlineStyles?malloc(_rows*_cols):NULL;if(!ordered||(_underlineStyles&&!orderedUnderlines)){free(ordered);free(orderedUnderlines);return;}
    for(NSUInteger y=0;y<_rows;y++){NSUInteger physical=_rowOrder[y];memcpy(ordered+y*_cols,_cells+physical*_cols,_cols*sizeof(TCell));if(orderedUnderlines)memcpy(orderedUnderlines+y*_cols,_underlineStyles+physical*_cols,_cols);}
    free(_cells);_cells=ordered;if(orderedUnderlines){free(_underlineStyles);_underlineStyles=orderedUnderlines;}[self resetRowOrder];/* Link keys are physical cell indexes. Clearing is safer than leaving a stale URL attached after materialization. */[_linksByCell removeAllObjects];
}
- (void)clearPhysicalRow:(NSUInteger)physical {
    TCell *row=_cells+physical*_cols;if(_historyBlankRow)memcpy(row,_historyBlankRow,_cols*sizeof(TCell));else{TCell blank=[self blankCell];for(NSUInteger x=0;x<_cols;x++)row[x]=blank;}
    if(_underlineStyles)memset(_underlineStyles+physical*_cols,0,_cols);if(_cachedOscIntegration&&_linksByCell.count)for(NSUInteger x=0;x<_cols;x++)[_linksByCell removeObjectForKey:@(physical*_cols+x)];
}
- (NSUInteger)rotateRowsUpFrom:(NSUInteger)top to:(NSUInteger)bottom {
    NSUInteger reused=_rowOrder[top];if(bottom>top)memmove(_rowOrder+top,_rowOrder+top+1,(bottom-top)*sizeof(NSUInteger));_rowOrder[bottom]=reused;return reused;
}
- (NSUInteger)rotateRowsDownFrom:(NSUInteger)top to:(NSUInteger)bottom {
    NSUInteger reused=_rowOrder[bottom];if(bottom>top)memmove(_rowOrder+top+1,_rowOrder+top,(bottom-top)*sizeof(NSUInteger));_rowOrder[top]=reused;return reused;
}
- (void)ensureBlankRow {
    if(_cols==0)return;
    if(_historyBlankRow&&_historyBlankCols==_cols&&_historyBlankValid)return;
    free(_historyBlankRow);_historyBlankRow=malloc(_cols*sizeof(TCell));
    _historyBlankCols=_historyBlankRow?_cols:0;if(_historyBlankRow){TCell blank=[self blankCell];for(NSUInteger i=0;i<_cols;i++)_historyBlankRow[i]=blank;_historyBlankValid=YES;}
}
- (void)addHistoryCells:(const TCell *)cells count:(NSUInteger)count __attribute__((objc_direct)) {
    NSUInteger limit=self.config.scrollback;if(!limit){[self ensureBlankRow];return;}
    NSUInteger cols=_cols,len=MIN(count,cols);
    [self ensureBlankRow];
    if(len==0)return;
    _historyGeneration++;
    BOOL columnsChanged=_historyCells&&_historyCols!=cols,needsGrowth=!_historyCells||columnsChanged||(_historyCount>=_historyCapacity&&_historyCapacity<limit);
    if(needsGrowth){
        NSUInteger oldCapacity=_historyCapacity,oldCount=columnsChanged?0:_historyCount,oldStart=_historyStart,oldCols=_historyCols;
        TCell *oldCells=_historyCells;
        NSUInteger newCap=MIN(limit,MAX((NSUInteger)256,columnsChanged?256:MAX((NSUInteger)1,oldCapacity*2)));
        TCell *newCells=malloc(newCap*cols*sizeof(TCell));
        if(!newCells)return;
        NSUInteger keep=MIN(oldCount,newCap);
        if(oldCells&&oldCols==cols)for(NSUInteger i=0;i<keep;i++)memcpy(newCells+i*cols,oldCells+((oldStart+i)%oldCapacity)*cols,cols*sizeof(TCell));
        free(oldCells);_historyCells=newCells;_historyCapacity=newCap;_historyCols=cols;_historyCount=keep;_historyStart=0;
    }
    NSUInteger dstIdx;
    if(_historyCount<limit){dstIdx=_historyCount;_historyCount++;}
    else{dstIdx=_historyStart;_historyStart=(_historyStart+1)%_historyCapacity;}
    TCell *dst=_historyCells+dstIdx*cols;
    if(len)memcpy(dst,cells,len*sizeof(TCell));
    if(len<cols)memcpy(dst+len,_historyBlankRow+len,(cols-len)*sizeof(TCell));
}
- (NSData *)historyLineAtIndex:(NSUInteger)index {
    if(!_historyCells||index>=_historyCount||_historyCols!=_cols)return _historyCount?[_history[(_historyStart+index)%_historyCount] copy]:nil;
    return [NSData dataWithBytesNoCopy:_historyCells+(((_historyStart+index)%_historyCapacity)*_historyCols) length:_historyCols*sizeof(TCell) freeWhenDone:NO];
}
- (void)clearHistory {[_history removeAllObjects];_historyStart=0;if(_historyCells){TCell blank=[self blankCell];for(NSUInteger i=0;i<_historyCapacity*_historyCols;i++)_historyCells[i]=blank;}_historyCount=0;}
- (void)resizeGrid {
    @synchronized(self) {
    CGFloat topInset=self.topContentInset,bottomInset=self.safeAreaInsets.bottom;
    CGFloat availableWidth=MAX(0.0,self.bounds.size.width-self.config.padding*2-self.leadingOverlayInset);
    CGFloat availableHeight=MAX(0.0,self.bounds.size.height-self.config.padding*2-topInset-bottomInset);
    NSUInteger cols=MAX((NSUInteger)2,(NSUInteger)floor(availableWidth/MAX(1.0,_cellWidth)));
    NSUInteger rows=MAX((NSUInteger)2,(NSUInteger)floor(availableHeight/MAX(1.0,_cellHeight)));
    if(cols == _cols && rows == _rows) return;
    TCell *next = calloc(cols * rows, sizeof(TCell));
    TCell blank = [self blankCell];
    for (NSUInteger i = 0; i < cols * rows; i++) next[i] = blank;
    if (_cells) {
        NSUInteger copyRows = MIN(rows, _rows), copyCols = MIN(cols, _cols);
        for (NSUInteger y = 0; y < copyRows; y++)
            memcpy(next + y * cols, [self cellsForRow:y], copyCols * sizeof(TCell));
        free(_cells);
    }
    _cells = next; _cols = cols; _rows = rows;free(_rowOrder);_rowOrder=malloc(rows*sizeof(NSUInteger));[self resetRowOrder];[_linksByCell removeAllObjects];free(_underlineStyles);_underlineStyles=calloc(cols*rows,sizeof(uint8_t));
    _cursorX = MIN(_cursorX, cols - 1); _cursorY = MIN(_cursorY, rows - 1);
    _scrollTop = 0; _scrollBottom = rows - 1;
    [self markAllDamage];
    if (_master >= 0) {
        struct winsize ws = { .ws_row=(unsigned short)rows, .ws_col=(unsigned short)cols,
                              .ws_xpixel=(unsigned short)self.bounds.size.width, .ws_ypixel=(unsigned short)self.bounds.size.height };
        ioctl(_master, TIOCSWINSZ, &ws);
    }
    }
}
- (void)setFrameSize:(NSSize)newSize { [super setFrameSize:newSize]; if(_presentationReady&&newSize.width>100&&newSize.height>80){[self resizeGrid];[self configureRenderBackend];} }
- (BOOL)startShell {
    if (_pid > 0) return YES;
    _freshLaunchAwaitingPrompt=self.config.shellIntegration;
    TLog(@"PTY preparation started");
    NSString *launchDirectory=self.launchDirectory;
    NSString *completionRoot=[TConfigDirectoryPath() stringByAppendingPathComponent:@"completions"];
    NSString *integrationRoot=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"ShellIntegration"],*shellName=self.config.shell.lastPathComponent.lowercaseString;
    struct winsize ws = { .ws_row=(unsigned short)_rows, .ws_col=(unsigned short)_cols };
    _pid = forkpty(&_master, NULL, NULL, &ws);
    if (_pid < 0) { TLog(@"forkpty failed: %s", strerror(errno)); return NO; }
    if (_pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("CLICOLOR", "1", 0);
        setenv("LSCOLORS", "Gxfxcxdxbxegedabagacad", 0);
        setenv("TERM_PROGRAM", "Termatica", 1);
        setenv("TERM_PROGRAM_VERSION", TCurrentVersion().UTF8String, 1);
        setenv("TERMATICA_COMPLETIONS",completionRoot.fileSystemRepresentation,1);
        if(self.config.shellIntegration){
            NSString *script=[integrationRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"termatica.%@",[shellName isEqual:@"zsh"]?@"zsh":([shellName isEqual:@"fish"]?@"fish":@"bash")]];setenv("TERMATICA_SHELL_INTEGRATION",script.fileSystemRepresentation,1);
            if([shellName isEqual:@"zsh"]){const char *original=getenv("ZDOTDIR");if(!original||!*original)original=getenv("HOME");if(original)setenv("TERMATICA_ORIGINAL_ZDOTDIR",original,1);setenv("ZDOTDIR",[[integrationRoot stringByAppendingPathComponent:@"zsh"] fileSystemRepresentation],1);}
            else if([shellName isEqual:@"fish"]){NSString *share=[integrationRoot stringByAppendingPathComponent:@"share"];const char *raw=getenv("XDG_DATA_DIRS");NSString *existing=raw&&*raw?[NSString stringWithUTF8String:raw]:@"/usr/local/share:/usr/share";setenv("XDG_DATA_DIRS",[[NSString stringWithFormat:@"%@:%@",share,existing] UTF8String],1);}
            else if([shellName isEqual:@"bash"]||[shellName isEqual:@"sh"]){setenv("BASH_ENV",script.fileSystemRepresentation,1);setenv("ENV",script.fileSystemRepresentation,1);}
        }
        NSString *hiddenPathScript=[[[TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"] stringByAppendingPathComponent:@"hidden-path"] stringByAppendingPathComponent:@"prompt.sh"];
        setenv("TERM_HP",hiddenPathScript.fileSystemRepresentation,1);
        if([self.config isPluginEnabled:@"hidden-path"])setenv("TERMATICA_HIDDEN_PATH","1",1);
        if(launchDirectory.length)chdir(launchDirectory.fileSystemRepresentation);
        NSString *bin=NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
        NSString *path=NSProcessInfo.processInfo.environment[@"PATH"]?:@"/usr/bin:/bin:/usr/sbin:/sbin";
        setenv("PATH",[[NSString stringWithFormat:@"%@:%@",bin,path] UTF8String],1);
        const char *shell = self.config.shell.fileSystemRepresentation;
        NSUInteger count = self.config.shellArguments.count;
        char **argv = calloc(count + 2, sizeof(char *));
        argv[0] = (char *)shell;
        for (NSUInteger i = 0; i < count; i++) argv[i + 1] = (char *)[self.config.shellArguments[i] UTF8String];
        argv[count + 1] = NULL;
        execv(shell, argv);
        _exit(127);
    }
    fcntl(_master, F_SETFL, O_NONBLOCK);
    _pendingChunks=[NSMutableArray array];
    TLog(@"PTY child forked");
    TLog(@"started %@ as pid %d on pty %d (%lux%lu)", self.config.shell, _pid, _master, _cols, _rows);
    __weak typeof(self) weakSelf = self;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _master, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    _readSource=source;
    dispatch_source_set_event_handler(source, ^{
        @autoreleasepool {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            int master=-1;@synchronized(self->_ioLock){if(self->_readSource!=source)return;master=self->_master;}
            const NSUInteger capacity=1048576;
            uint8_t *buffer=malloc(capacity);
            if(!buffer)return;
            NSUInteger length=0;BOOL reachedEOF=NO;int readError=0;
            while(length<capacity){
                ssize_t n=read(master,buffer+length,capacity-length);
                if(n>0){length+=(NSUInteger)n;continue;}
                if(n<0&&errno==EINTR)continue;
                if(n==0)reachedEOF=YES;
                else if(errno!=EAGAIN&&errno!=EWOULDBLOCK)readError=errno;
                break;
            }
            if (length > 0) {
                NSData *chunk=[NSData dataWithBytesNoCopy:buffer length:length freeWhenDone:YES];buffer=NULL;
                BOOL schedule=NO;@synchronized(self->_ioLock){if(self->_readSource!=source)return;[self->_pendingChunks addObject:chunk];self->_pendingBytes+=length;if(self->_pendingBytes>=4194304&&!self->_readPaused){self->_readPaused=YES;dispatch_suspend(source);if(!self->_backpressureReported){self->_backpressureReported=YES;TLog(@"PTY backpressure active at %lu queued bytes",(unsigned long)self->_pendingBytes);}}if(!self->_drainScheduled){self->_drainScheduled=YES;schedule=YES;}}
                if(schedule)dispatch_async(self->_parseQueue,^{[self drainPendingData];});
                if(reachedEOF||readError){if(readError)TLog(@"pty read failed after buffered output: %s",strerror(readError));[self stopShellTerminating:NO];}
            } else if(reachedEOF){TLog(@"shell pty reached EOF");[self stopShellTerminating:NO];}
            else if(readError){TLog(@"pty read failed: %s",strerror(readError));[self stopShellTerminating:YES];}
            free(buffer);
        }
    });
    dispatch_source_set_cancel_handler(source, ^{});
    if(_presentationReady){_readSourceStarted=YES;dispatch_resume(source);}
    _hiddenPathDesired=[self.config isPluginEnabled:@"hidden-path"];_hiddenPathApplied=_hiddenPathDesired?1:0;
    return YES;
}
- (void)stopShellTerminating:(BOOL)terminate {[self disableSecureKeyboardInput];dispatch_source_t source=nil;int master=-1;pid_t child=-1;@synchronized(_ioLock){source=_readSource;_readSource=nil;if(source&&!_readSourceStarted){_readSourceStarted=YES;dispatch_resume(source);}else if(source&&_readPaused){_readPaused=NO;dispatch_resume(source);}if(terminate){[_pendingChunks removeAllObjects];_pendingBytes=0;_drainScheduled=NO;_backpressureReported=NO;}master=_master;_master=-1;child=_pid;_pid=-1;}if(source)dispatch_source_cancel(source);if(master>=0)close(master);if(child>0){if(terminate)kill(child,SIGHUP);dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{int status=0;while(waitpid(child,&status,0)<0&&errno==EINTR){}});}}
- (void)drainPendingData {
    for(;;)@autoreleasepool{
        NSData *chunk=nil;dispatch_source_t resumeSource=nil;
        @synchronized(_ioLock){
            if(_pendingChunks.count){chunk=_pendingChunks.firstObject;[_pendingChunks removeObjectAtIndex:0];_pendingBytes-=MIN(_pendingBytes,chunk.length);}
            if(_readPaused&&_pendingBytes<=1048576&&_readSource){_readPaused=NO;resumeSource=_readSource;}
            if(!chunk)_drainScheduled=NO;
        }
        if(resumeSource)dispatch_resume(resumeSource);
        if(!chunk)return;
        if(chunk.length)[self consumeData:chunk];
    }
}
- (void)sendBytes:(const void *)bytes length:(NSUInteger)length {
    if(!length)return;if(_diagnosticInput){[_diagnosticInput appendBytes:bytes length:length];return;}if(!_writeQueue)_writeQueue=dispatch_queue_create("com.termatica.pty-write",DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);NSData *payload=[NSData dataWithBytes:bytes length:length];__weak typeof(self) weakSelf=self;
    dispatch_async(_writeQueue,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;const uint8_t *cursor=payload.bytes;NSUInteger remaining=payload.length;while(remaining){int master=-1;@synchronized(self->_ioLock){master=self->_master;}if(master<0){TLog(@"input dropped because PTY is closed");return;}ssize_t written=write(master,cursor,remaining);if(written>0){cursor+=written;remaining-=(NSUInteger)written;continue;}if(written<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){struct pollfd descriptor={.fd=master,.events=POLLOUT};if(poll(&descriptor,1,20)>=0)continue;}if(written<0&&errno==EINTR)continue;TLog(@"PTY input write failed: %s",strerror(errno));return;}});
}
- (void)startDiagnosticInputCapture {_diagnosticInput=[NSMutableData data];}
- (NSData *)finishDiagnosticInputCapture {NSData *captured=[_diagnosticInput copy]?:NSData.data;_diagnosticInput=nil;return captured;}
- (void)sendString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    [self sendBytes:data.bytes length:data.length];
}
- (void)applyHiddenPathGeneration:(NSUInteger)generation attempt:(NSUInteger)attempt {
    if(generation!=_hiddenPathGeneration||_master<0||_pid<=0)return;
    pid_t foreground=tcgetpgrp(_master);
    if(foreground!=_pid&&attempt<600){__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[weakSelf applyHiddenPathGeneration:generation attempt:attempt+1];});return;}
    NSInteger desired=_hiddenPathDesired?1:0;if(_hiddenPathApplied==desired)return;
    NSString *path=[[[TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"] stringByAppendingPathComponent:@"hidden-path"] stringByAppendingPathComponent:@"prompt.sh"];
    if(![NSFileManager.defaultManager fileExistsAtPath:path]){if(!desired)_hiddenPathApplied=0;return;}
    NSString *command=[NSString stringWithFormat:@" . \"$TERM_HP\" %@; printf '\\033[2J\\033[H'\r",desired?@"on":@"off"];
    [self sendString:command];
    _hiddenPathApplied=desired;TLog(@"hidden path prompt %@",desired?@"enabled":@"disabled");
}
- (void)setHiddenPathEnabled:(BOOL)enabled {
    _hiddenPathDesired=enabled;NSUInteger generation=++_hiddenPathGeneration;
    if(_hiddenPathApplied==(enabled?1:0))return;
    [self applyHiddenPathGeneration:generation attempt:0];
}
- (void)consumeData:(NSData *)data {
    [self consumeBytes:data.bytes length:data.length];
}
- (void)consumeBytes:(const uint8_t *)bytes length:(NSUInteger)length {
    @synchronized(self) {
    static BOOL reportedFirstShellOutput = NO;
    if (!reportedFirstShellOutput) {
        reportedFirstShellOutput = YES;
        TLog(@"first shell output after %.2f ms", (CFAbsoluteTimeGetCurrent() - TProcessStartedAt) * 1000.0);
    }
    BOOL followOutput=_historyOffset==0;NSUInteger historyGeneration=_historyGeneration,oldCursorX=_cursorX,oldCursorY=_cursorY;TDecodeContext decodeContext={.terminal=(__bridge void *)self};
    TDecoderSink sink={.context=&decodeContext,.ascii=TTerminalASCII,.codepoint=TTerminalCodepoint,.codepoints=TTerminalCodepoints,.control=TTerminalControl,.escape=TTerminalEscape,.csi=TTerminalCSI,.string=TTerminalString};
    TDecoderConsume(&_decoder,bytes,length,&sink);
    if(followOutput)_historyOffset=0;
    else _historyOffset=MIN((NSInteger)_historyCount,_historyOffset+(NSInteger)(_historyGeneration-historyGeneration));
    if(!decodeContext.visible)return;
    _renderGeneration++;
    [self markDamageX:oldCursorX y:oldCursorY width:1 height:1];[self markDamageX:_cursorX y:_cursorY width:1 height:1];
    [self refreshTextView];
    }
}
- (void)putASCIIBytes:(const uint8_t *)bytes length:(NSUInteger)length __attribute__((objc_direct)) {
    NSUInteger offset=0;
    if(_charsetDesignation&&length){BOOL special=bytes[0]=='0';if(_charsetDesignation=='(')_g0SpecialGraphics=special;else _g1SpecialGraphics=special;_charsetDesignation=0;offset=1;if(offset==length)return;}
    if((_activeG1?_g1SpecialGraphics:_g0SpecialGraphics)){for(;offset<length;offset++)[self putCodepoint:TDECSpecialGraphics(bytes[offset])];return;}
    BOOL tracksLinks=_cachedOscIntegration&&(_currentLink.length||_linksByCell.count);NSUInteger startX=_cursorX,startY=_cursorY;
    while(offset<length){
        if(_cursorX>=_cols){if(_autoWrap){_cursorX=0;[self lineFeed];}else{_cursorX=_cols-1;offset=length-1;}}
        TCell *row=[self cellsForRow:_cursorY];
        NSUInteger take=MIN(length-offset,_cols-_cursorX),base=_cursorX;
        for(NSUInteger i=0;i<take;i++){
            NSUInteger x=base+i;uint8_t previousFlags=row[x].flags;if(previousFlags&(TWide|TContinuation))[self clearWideCellAtX:x row:row];
            row[x]=(TCell){.ch=bytes[offset+i],.fg=_currentFG,.bg=_currentBG,.flags=_currentFlags};
            if(_underlineStyles&&(_currentUnderlineStyle||(previousFlags&TUnderline)))_underlineStyles[[self physicalRowForRow:_cursorY]*_cols+x]=_currentUnderlineStyle;
            if(tracksLinks){NSNumber *key=[self linkKeyForX:x y:_cursorY];if(_currentLink.length)_linksByCell[key]=_currentLink;else[_linksByCell removeObjectForKey:key];}
        }
        _cursorX+=take;offset+=take;
    }
    if(length){
        _lastEmittedCodepoint=bytes[length-1];_hasLastEmittedCodepoint=YES;
        NSUInteger endY=_cursorY,endX=_cursorX;
        if(endY==startY){[self markDamageX:startX y:startY width:MAX(1,endX-startX) height:1];}
        else{[self markDamageX:startX y:startY width:_cols-startX height:1];if(endY>startY+1)[self markDamageX:0 y:startY+1 width:_cols height:(endY-(startY+1))];[self markDamageX:0 y:endY width:endX height:1];}
    }
}
- (void)handleControl:(uint8_t)control __attribute__((objc_direct)) {
    if(control==7){dispatch_async(dispatch_get_main_queue(),^{NSString *bell=self.config.bellStyle?:@"sound";if([bell containsString:@"sound"])NSBeep();if([bell containsString:@"visual"]){CABasicAnimation *flash=[CABasicAnimation animationWithKeyPath:@"opacity"];flash.fromValue=@0.3;flash.toValue=@1;flash.duration=0.15;[self.layer addAnimation:flash forKey:@"termatica.bell"];}});return;}
    if(control==8){if(_cursorX)_cursorX--;return;}
    if(control==9){_cursorX=MIN(((_cursorX/8)+1)*8,_cols-1);return;}
    if(control==14){_activeG1=YES;return;}
    if(control==15){_activeG1=NO;return;}
    if(control==10||control==11||control==12){[self lineFeed];return;}
    if(control==13)_cursorX=0;
}
- (void)handleEscape:(uint8_t)finalByte __attribute__((objc_direct)) {
    if(finalByte=='('||finalByte==')'){_charsetDesignation=finalByte;}
    else if(finalByte=='7'){_savedX=_cursorX;_savedY=_cursorY;}
    else if(finalByte=='8'){_cursorX=MIN(_savedX,_cols-1);_cursorY=MIN(_savedY,_rows-1);}
    else if(finalByte=='D')[self lineFeed];
    else if(finalByte=='E'){_cursorX=0;[self lineFeed];}
    else if(finalByte=='M')[self reverseIndex];
    else if(finalByte=='c')[self resetTerminal];
}
static int TCSIParameter(const int *parameters,NSUInteger count,NSUInteger index,int defaultValue){return index<count&&parameters[index]?parameters[index]:defaultValue;}
- (int)privateModeStatus:(int)mode {BOOL known=YES,enabled=NO;if(mode==1)enabled=_applicationCursorKeys;else if(mode==7)enabled=_autoWrap;else if(mode==12)enabled=_cursorBlink;else if(mode==25)enabled=_cursorVisible;else if(mode==47||mode==1047||mode==1049)enabled=_alternateScreen;else if(mode==1000||mode==1002||mode==1003)enabled=_mouseTrackingMode==(NSUInteger)mode;else if(mode==1004)enabled=_focusReporting;else if(mode==1005)enabled=_utf8Mouse;else if(mode==1006)enabled=_sgrMouse;else if(mode==1007)enabled=_alternateScroll;else if(mode==1015)enabled=_urxvtMouse;else if(mode==1016)enabled=_pixelMouse;else if(mode==2004)enabled=_bracketedPaste;else if(mode==2026)enabled=_synchronizedUpdates;else known=NO;return known?(enabled?1:2):0;}
- (void)executeCSI:(uint8_t)command prefix:(uint8_t)prefix intermediate:(uint8_t)intermediate parameters:(const int *)parameters count:(NSUInteger)count __attribute__((objc_direct)) {
    int n=TCSIParameter(parameters,count,0,1);
    if(intermediate==' '&&command=='q'){int style=parameters[0];_applicationCursorStyle=(style==3||style==4)?@"underline":((style==5||style==6)?@"bar":@"block");_cursorBlink=style==0||style==1||style==3||style==5;[self startCursorBlink];[self setNeedsDisplay:YES];return;}
    if(intermediate=='$'&&command=='p'){NSString *leader=prefix?[NSString stringWithFormat:@"%c",prefix]:@"";for(NSUInteger i=0;i<count;i++){int mode=parameters[i],status=prefix=='?'?[self privateModeStatus:mode]:0;[self sendString:[NSString stringWithFormat:@"\033[%@%d;%d$y",leader,mode,status]];}return;}
    if((prefix=='>'||prefix=='=')&&command=='u'){_kittyKeyboardFlags=(NSUInteger)MAX(0,parameters[0]);return;}
    if(prefix=='<'&&command=='u'){_kittyKeyboardFlags=0;return;}
    if(prefix=='?'&&command=='u'){[self sendString:[NSString stringWithFormat:@"\033[?%luu",(unsigned long)_kittyKeyboardFlags]];return;}
    if(prefix=='>'&&command=='m'&&parameters[0]==4){_modifyOtherKeys=(NSUInteger)MAX(0,count>1?parameters[1]:0);return;}
    switch (command) {
        case 'A': _cursorY = n > (int)_cursorY ? 0 : _cursorY - n; break;
        case 'B': _cursorY = MIN(_rows - 1, _cursorY + n); break;
        case 'C': _cursorX = MIN(_cols - 1, _cursorX + n); break;
        case 'D': _cursorX = n > (int)_cursorX ? 0 : _cursorX - n; break;
        case 'E': _cursorY = MIN(_rows - 1, _cursorY + n); _cursorX = 0; break;
        case 'F': _cursorY = n > (int)_cursorY ? 0 : _cursorY - n; _cursorX = 0; break;
        case 'G': _cursorX = MIN(_cols - 1, (NSUInteger)(n - 1)); break;
        case 'H': case 'f': _cursorY = MIN(_rows - 1, (NSUInteger)(TCSIParameter(parameters,count,0,1) - 1)); _cursorX = MIN(_cols - 1, (NSUInteger)(TCSIParameter(parameters,count,1,1) - 1)); break;
        case 'd': _cursorY = MIN(_rows - 1, (NSUInteger)(n - 1)); break;
        case 'J': [self eraseDisplay:parameters[0]]; break;
        case 'K': [self eraseLine:parameters[0]]; break;
        case 'm': [self applySGRParameters:parameters count:count]; break;
        case 's': _savedX = _cursorX; _savedY = _cursorY; break;
        case 'u': _cursorX = MIN(_savedX, _cols-1); _cursorY = MIN(_savedY, _rows-1); break;
        case 'r': {
            NSUInteger top = (NSUInteger)(TCSIParameter(parameters,count,0,1) - 1);
            NSUInteger bottom = (NSUInteger)(TCSIParameter(parameters,count,1,(int)_rows) - 1);
            if (top < bottom && bottom < _rows) { _scrollTop = top; _scrollBottom = bottom; _cursorX = _cursorY = 0;if(_synchronizedUpdates&&!_alternateScreen&&_bracketedPaste&&_focusReporting&&_kittyKeyboardFlags&&(top||bottom+1<_rows)){_inlineViewportMode=YES;if(top==0&&bottom+1<_rows)_inlineViewportTop=bottom+1;} }
            break;
        }
        case 'h': case 'l': if(prefix)for(NSUInteger i=0;i<count;i++)[self setPrivateMode:parameters[i] enabled:command=='h'];break;
        case 'P': [self deleteCharacters:n]; break;
        case '@': [self insertCharacters:n]; break;
        case 'X': [self eraseCharacters:n]; break;
        case 'L': [self insertLines:n]; break;
        case 'M': [self deleteLines:n]; break;
        case 'n': if(parameters[0]==6)[self sendString:[NSString stringWithFormat:@"\033[%lu;%luR",_cursorY+1,_cursorX+1]];else if(parameters[0]==5)[self sendString:@"\033[0n"];break;
        case 't': if(parameters[0]==14)[self sendString:[NSString stringWithFormat:@"\033[4;%lu;%lut",(unsigned long)lrint(self.bounds.size.height),(unsigned long)lrint(self.bounds.size.width)]];else if(parameters[0]==18)[self sendString:[NSString stringWithFormat:@"\033[8;%lu;%lut",(unsigned long)_rows,(unsigned long)_cols]];break;
        case 'b': {
            if(!_hasLastEmittedCodepoint)break;
            if(_lastEmittedCodepoint>=32&&_lastEmittedCodepoint<127){
                uint8_t repeated[256];memset(repeated,(int)_lastEmittedCodepoint,sizeof(repeated));
                for(int remaining=n;remaining>0;remaining-=MIN(remaining,(int)sizeof(repeated)))[self putASCIIBytes:repeated length:(NSUInteger)MIN(remaining,(int)sizeof(repeated))];
            }else{
                uint32_t repeated[128];for(NSUInteger i=0;i<sizeof(repeated)/sizeof(repeated[0]);i++)repeated[i]=_lastEmittedCodepoint;
                for(int remaining=n;remaining>0;remaining-=MIN(remaining,(int)(sizeof(repeated)/sizeof(repeated[0]))))[self putCodepoints:repeated count:(NSUInteger)MIN(remaining,(int)(sizeof(repeated)/sizeof(repeated[0])))];
            }
            break;
        }
        case 'c': {
            if(prefix=='>')[self sendString:@"\033[>0;120;0c"];
            else if(!prefix||prefix=='?')[self sendString:@"\033[?1;2c"];
            break;
        }
        default: break;
    }
}
- (void)applySGRParameters:(const int *)parameters count:(NSUInteger)count {
    if(count==1&&parameters[0]==0){_currentFG=_currentBG=TDefaultColor;_currentFlags=0;_currentUnderlineStyle=0;return;}
    for(NSUInteger i=0;i<count;i++){
        int p=parameters[i];
        if (p == 0) { _currentFG = _currentBG = TDefaultColor; _currentFlags = 0; _currentUnderlineStyle=0; }
        else if (p == 1) _currentFlags |= TBold;
        else if (p == 3) _currentFlags |= TItalic;
        else if (p == 4) { _currentFlags |= TUnderline; _currentUnderlineStyle=1; if(i+1<count&&parameters[i+1]>=0&&parameters[i+1]<=5){_currentUnderlineStyle=(uint8_t)parameters[i+1];i++;} }
        else if (p == 7) _currentFlags |= TInverse;
        else if (p == 22) _currentFlags &= ~TBold;
        else if (p == 23) _currentFlags &= ~TItalic;
        else if (p == 24) { _currentFlags &= ~TUnderline; _currentUnderlineStyle=0; }
        else if (p == 27) _currentFlags &= ~TInverse;
        else if (p >= 30 && p <= 37) _currentFG = _palette256Valid ? _palette256[p - 30] : TRGB(self.config.palette[p - 30]);
        else if (p >= 40 && p <= 47) _currentBG = _palette256Valid ? _palette256[p - 40] : TRGB(self.config.palette[p - 40]);
        else if (p >= 90 && p <= 97) _currentFG = _palette256Valid ? _palette256[p - 90 + 8] : TRGB(self.config.palette[p - 90 + 8]);
        else if (p >= 100 && p <= 107) _currentBG = _palette256Valid ? _palette256[p - 100 + 8] : TRGB(self.config.palette[p - 100 + 8]);
        else if (p == 39) _currentFG = TDefaultColor;
        else if (p == 49) _currentBG = TDefaultColor;
        else if((p==38||p==48)&&i+1<count){
            uint32_t color = TDefaultColor;
            if(parameters[i+1]==5&&i+2<count){color=[self colorFor256:parameters[i+2]];i+=2;}
            else if(parameters[i+1]==2&&i+4<count){NSUInteger first=(i+5<count&&parameters[i+2]==0)?i+3:i+2;color=((parameters[first]&255)<<16)|((parameters[first+1]&255)<<8)|(parameters[first+2]&255);i=first+2;}
            if (p == 38) _currentFG = color; else _currentBG = color;
        }
    }
}
- (uint32_t)colorFor256:(int)i __attribute__((objc_direct)) {
    if (i < 16) return TRGB(self.config.palette[MAX(0, i)]);
    if (i < 232) { int q=i-16, r=q/36, g=(q/6)%6, b=q%6; int levels[]={0,95,135,175,215,255}; return (levels[r]<<16)|(levels[g]<<8)|levels[b]; }
    int v = 8 + (i - 232) * 10; return (v<<16)|(v<<8)|v;
}
- (void)enterAlternateScreen {
    if(_alternateScreen)return;_inlineViewportMode=NO;_inlineViewportTop=0;[self normalizeRows];_primaryScreen=[NSData dataWithBytes:_cells length:_cols*_rows*sizeof(TCell)];_primaryUnderlineStyles=_underlineStyles?[NSData dataWithBytes:_underlineStyles length:_cols*_rows]:nil;_primaryInlineImages=[_inlineImages copy];_primaryKittyImageIDs=[_kittyImageIDs copy];_inlineImages=[NSMutableDictionary dictionary];_kittyImageIDs=[NSMutableDictionary dictionary];_primaryCols=_cols;_primaryRows=_rows;_primaryCursorX=_cursorX;_primaryCursorY=_cursorY;_alternateScreen=YES;_historyOffset=0;[self eraseDisplay:2];_cursorX=_cursorY=0;[self markAllDamage];
}
- (void)leaveAlternateScreen {
    if(!_alternateScreen)return;TCell blank=[self blankCell];for(NSUInteger i=0;i<_cols*_rows;i++)_cells[i]=blank;if(_underlineStyles)memset(_underlineStyles,0,_cols*_rows);NSUInteger copyRows=MIN(_rows,_primaryRows),copyCols=MIN(_cols,_primaryCols);const TCell *saved=_primaryScreen.bytes;const uint8_t *savedUnderlines=_primaryUnderlineStyles.bytes;for(NSUInteger y=0;y<copyRows;y++){memcpy(_cells+y*_cols,saved+y*_primaryCols,copyCols*sizeof(TCell));if(_underlineStyles&&savedUnderlines)memcpy(_underlineStyles+y*_cols,savedUnderlines+y*_primaryCols,copyCols);}_cursorX=MIN(_primaryCursorX,_cols-1);_cursorY=MIN(_primaryCursorY,_rows-1);_inlineImages=[_primaryInlineImages mutableCopy]?:[NSMutableDictionary dictionary];_kittyImageIDs=[_primaryKittyImageIDs mutableCopy]?:[NSMutableDictionary dictionary];_primaryScreen=nil;_primaryUnderlineStyles=nil;_primaryInlineImages=nil;_primaryKittyImageIDs=nil;_alternateScreen=NO;_historyOffset=0;[self markAllDamage];
}
- (void)setPrivateMode:(int)mode enabled:(BOOL)enabled {
    if (mode == 25) _cursorVisible = enabled;
    else if (mode == 2004) {_bracketedPaste = enabled;if(!enabled){_inlineViewportMode=NO;_inlineViewportTop=0;}}
    else if (mode == 1049 || mode == 47 || mode == 1047) {if(enabled)[self enterAlternateScreen];else[self leaveAlternateScreen];}
    else if(mode==1)_applicationCursorKeys=enabled;
    else if(mode==7)_autoWrap=enabled;
    else if(mode==1004)_focusReporting=enabled;
    else if(mode==1007)_alternateScroll=enabled;
    else if(mode==1000||mode==1002||mode==1003)_mouseTrackingMode=enabled?(NSUInteger)mode:0;
    else if(mode==1005)_utf8Mouse=enabled;
    else if(mode==1006)_sgrMouse=enabled;
    else if(mode==1015)_urxvtMouse=enabled;
    else if(mode==1016)_pixelMouse=enabled;
    else if(mode==2026){_synchronizedUpdates=enabled;if(enabled&&!_alternateScreen&&_bracketedPaste&&_focusReporting&&_kittyKeyboardFlags)_inlineViewportMode=YES;}
    else if(mode==12){_cursorBlink=enabled;[self startCursorBlink];}
}
- (uint32_t)internGrapheme:(NSString *)value {
    NSNumber *existing=_graphemeIDs[value];if(existing)return existing.unsignedIntValue;
    if(_graphemes.count>=0xEEFFFF)return 0xFFFD;uint32_t token=(uint32_t)(TClusterBase+_graphemes.count);[_graphemes addObject:value];_graphemeIDs[value]=@(token);return token;
}
- (NSNumber *)linkKeyForX:(NSUInteger)x y:(NSUInteger)y {return @(([self physicalRowForRow:y]*_cols)+x);}
- (void)clearWideCellAtX:(NSUInteger)x row:(TCell *)row __attribute__((objc_direct)) {
    if(x>=_cols)return;if(row[x].flags&TWide){if(x+1<_cols)row[x+1]=[self blankCell];}
    else if((row[x].flags&TContinuation)&&x){row[x-1].flags&=~TWide;}
}
static inline BOOL TMayJoinGrapheme(uint32_t codepoint,uint32_t previous,uint8_t previousFlags) {
    if(previousFlags&TCluster)return YES;
    if(TUnicodeRegional(previous)||previous==0x200D)return YES;
    if(codepoint==0xFE0F||codepoint==0x200D||TUnicodeRegional(codepoint))return YES;
    if(codepoint>=0x300&&codepoint<=0x36F)return YES;
    if(codepoint<0x483||(codepoint>=0x1F000&&codepoint<0x1F3FB)||(codepoint>0x1F3FF&&codepoint<0xE0020))return NO;
    if(TUnicodeCombining(codepoint))return YES;
    BOOL jamo=(codepoint>=0x1100&&codepoint<=0x11FF)||(codepoint>=0xA960&&codepoint<=0xA97F)||(codepoint>=0xD7B0&&codepoint<=0xD7FF);
    BOOL previousJamo=(previous>=0x1100&&previous<=0x11FF)||(previous>=0xA960&&previous<=0xA97F)||(previous>=0xD7B0&&previous<=0xD7FF);
    return jamo&&previousJamo;
}
static inline NSUInteger TCachedUnicodeWidth(uint32_t cp,uint32_t *keys,uint8_t *values){
    NSUInteger index=(NSUInteger)((cp^(cp>>8))&255);if(keys[index]==cp)return values[index];NSUInteger width=TUnicodeWide(cp)?2:1;keys[index]=cp;values[index]=(uint8_t)width;return width;
}
- (void)putCodepoints:(const uint32_t *)codepoints count:(NSUInteger)count __attribute__((objc_direct)) {
    BOOL tracksLinks=_cachedOscIntegration&&(_currentLink.length||_linksByCell.count);
    TCell blank=(TCell){.ch=' ',.fg=TDefaultColor,.bg=TDefaultColor,.flags=0};
    NSUInteger startX=_cursorX,startY=_cursorY;
    for(NSUInteger i=0;i<count;i++){
        uint32_t cp=codepoints[i];
        BOOL commonCJK=cp>=0x2E80&&cp<=0xA4CF&&cp!=0x303F;
        BOOL ordinaryNarrow=cp<0x300||(cp>=0x370&&cp<0x483);
        if(_cachedUnicodeRendering&&!commonCJK&&!ordinaryNarrow&&_cursorX){
            TCell *row=[self cellsForRow:_cursorY];NSUInteger baseX=_cursorX-1;if((row[baseX].flags&TContinuation)&&baseX)baseX--;
            uint32_t previous=row[baseX].ch;uint8_t previousFlags=row[baseX].flags;
            if(TMayJoinGrapheme(cp,previous,previousFlags)){[self putCodepoint:cp];continue;}
        }
        NSUInteger width=_cachedUnicodeRendering?(commonCJK?2:(ordinaryNarrow?1:TCachedUnicodeWidth(cp,_unicodeWidthKeys,_unicodeWidthValues))):1;
        if(_cursorX>=_cols||_cursorX+width>_cols){
            if(_autoWrap){
                _cursorX=0;
                if(_alternateScreen&&_cursorY==_scrollBottom&&_scrollTop==0&&_scrollBottom==_rows-1){
                    _damageValid=_damageFull=YES;_damageMinX=_damageMinY=0;_damageMaxX=_cols;_damageMaxY=_rows;
                    NSUInteger physical=[self rotateRowsUpFrom:0 to:_rows-1];[self clearPhysicalRow:physical];
                }else [self lineFeed];
            }else _cursorX=_cols-width;
        }
        TCell *row=[self cellsForRow:_cursorY];uint8_t previousFlags=row[_cursorX].flags;
        if(previousFlags&TWide){if(_cursorX+1<_cols)row[_cursorX+1]=blank;}
        else if((previousFlags&TContinuation)&&_cursorX)row[_cursorX-1].flags&=~TWide;
        row[_cursorX]=(TCell){.ch=cp,.fg=_currentFG,.bg=_currentBG,.flags=_currentFlags|(width==2?TWide:0)};
        if(_underlineStyles&&(_currentUnderlineStyle||(previousFlags&TUnderline)))_underlineStyles[[self physicalRowForRow:_cursorY]*_cols+_cursorX]=_currentUnderlineStyle;
        if(tracksLinks){NSNumber *key=[self linkKeyForX:_cursorX y:_cursorY];if(_currentLink.length)_linksByCell[key]=_currentLink;else[_linksByCell removeObjectForKey:key];}
        if(width==2){row[_cursorX+1]=(TCell){.ch=0,.fg=_currentFG,.bg=_currentBG,.flags=TContinuation};if(tracksLinks){NSNumber *key=[self linkKeyForX:_cursorX+1 y:_cursorY];if(_currentLink.length)_linksByCell[key]=_currentLink;else[_linksByCell removeObjectForKey:key];}}
        _cursorX+=width;
    }
    if(count){
        _lastEmittedCodepoint=codepoints[count-1];_hasLastEmittedCodepoint=YES;
        NSUInteger endY=_cursorY,endX=_cursorX;
        if(endY==startY)[self markDamageX:startX y:startY width:MAX(1,endX-startX) height:1];
        else{[self markDamageX:startX y:startY width:_cols-startX height:1];if(endY>startY+1)[self markDamageX:0 y:startY+1 width:_cols height:endY-startY-1];[self markDamageX:0 y:endY width:MAX(1,endX) height:1];}
    }
}
- (void)putCodepoint:(uint32_t)cp __attribute__((objc_direct)) {
    if(_cachedUnicodeRendering&&_cursorX){
        TCell *row=[self cellsForRow:_cursorY];NSUInteger baseX=_cursorX-1;if((row[baseX].flags&TContinuation)&&baseX)baseX--;TCell *base=&row[baseX];
        if(TMayJoinGrapheme(cp,base->ch,base->flags)){
            uint64_t pairKey=((uint64_t)base->ch<<32)|cp;NSUInteger pairIndex=(NSUInteger)((pairKey^(pairKey>>29))&255);uint32_t cachedToken=_graphemePairKeys[pairIndex]==pairKey?_graphemePairValues[pairIndex]:0;
            BOOL joins=cachedToken!=0;
            if(!joins){
                BOOL combining=TUnicodeCombining(cp),regional=TUnicodeRegional(cp)&&TUnicodeRegional(base->ch),zwjTail=cp==0x200D,zwjHead=base->ch==0x200D;
                joins=combining||regional||zwjTail||zwjHead;
                if(!joins&&cp==0xFE0F)joins=YES;
            }
            if(joins&&base->ch!=' '&&!(base->flags&TContinuation)){
                uint32_t token=cachedToken;
                if(!token){NSString *candidate=nil;if(base->ch<TClusterBase){unichar scalars[4];NSUInteger scalarCount=TAppendUTF16(scalars,0,base->ch);scalarCount=TAppendUTF16(scalars,scalarCount,cp);candidate=[[NSString alloc]initWithCharacters:scalars length:scalarCount];}else{NSString *existing=[self stringForCodepoint:base->ch];NSString *scalar=[self stringForCodepoint:cp];candidate=[existing stringByAppendingString:scalar];}token=[self internGrapheme:candidate];_graphemePairKeys[pairIndex]=pairKey;_graphemePairValues[pairIndex]=token;}
                base->ch=token;base->flags|=TCluster;
                if((TUnicodeWide(cp)||cp==0xFE0F||cp==0x200D)&&!(base->flags&TWide)&&baseX+1<_cols){base->flags|=TWide;row[baseX+1]=(TCell){.ch=0,.fg=base->fg,.bg=base->bg,.flags=TContinuation};if(_cursorX==baseX+1)_cursorX++;}
                _lastEmittedCodepoint=cp;_hasLastEmittedCodepoint=YES;[self markDamageX:baseX y:_cursorY width:(base->flags&TWide)?2:1 height:1];return;
            }
        }
    }
    NSUInteger width=_cachedUnicodeRendering?TCachedUnicodeWidth(cp,_unicodeWidthKeys,_unicodeWidthValues):1;
    if (_cursorX >= _cols||(_cursorX+width>_cols)) {if(_autoWrap){_cursorX = 0; [self lineFeed];}else _cursorX=_cols-width;}
    TCell *row=[self cellsForRow:_cursorY];[self clearWideCellAtX:_cursorX row:row];TCell *c=row+_cursorX;
    c->ch = cp; c->fg = _currentFG; c->bg = _currentBG; c->flags = _currentFlags|(width==2?TWide:0);
    [self markDamageX:_cursorX y:_cursorY width:width height:1];
    BOOL tracksLinks=_cachedOscIntegration&&(_currentLink.length||_linksByCell.count);
    if(tracksLinks){NSNumber *linkKey=[self linkKeyForX:_cursorX y:_cursorY];if(_currentLink.length)_linksByCell[linkKey]=_currentLink;else[_linksByCell removeObjectForKey:linkKey];}
    if(width==2){row[_cursorX+1]=(TCell){.ch=0,.fg=_currentFG,.bg=_currentBG,.flags=TContinuation};if(tracksLinks){NSNumber *continuation=[self linkKeyForX:_cursorX+1 y:_cursorY];if(_currentLink.length)_linksByCell[continuation]=_currentLink;else[_linksByCell removeObjectForKey:continuation];}}
    _cursorX+=width;_lastEmittedCodepoint=cp;_hasLastEmittedCodepoint=YES;
}
- (void)lineFeed __attribute__((objc_direct)) {
    // Writing the final cell leaves an implicit pending wrap at columns.  A
    // real line-feed consumes that pending wrap; keeping it would line-feed a
    // second time when the next printable character arrives.
    if(_cursorX>=_cols&&_cols)_cursorX=_cols-1;
    if (_cursorY == _scrollBottom) [self scrollUp];
    else _cursorY = MIN(_rows - 1, _cursorY + 1);
}
- (void)scrollUp __attribute__((objc_direct)) {
    if(_alternateScreen&&_scrollTop==0&&_scrollBottom==_rows-1){
        _damageValid=_damageFull=YES;_damageMinX=_damageMinY=0;_damageMaxX=_cols;_damageMaxY=_rows;
        NSUInteger physical=[self rotateRowsUpFrom:0 to:_rows-1];[self clearPhysicalRow:physical];
        return;
    }
    [self markDamageX:0 y:_scrollTop width:_cols height:_scrollBottom-_scrollTop+1];
    if(!_alternateScreen&&_scrollTop==0){
        TCell *top=[self cellsForRow:0];NSUInteger used=_cols;TCell blank=[self blankCell];while(used){TCell cell=top[used-1];if(cell.ch!=blank.ch||cell.flags!=blank.flags||cell.fg!=blank.fg||cell.bg!=blank.bg)break;used--;}
        [self addHistoryCells:top count:MAX((NSUInteger)1,used)];
    }
    if (_scrollTop == 0 && _scrollBottom == _rows - 1) {
        NSUInteger physical=[self rotateRowsUpFrom:0 to:_rows-1];[self clearPhysicalRow:physical];return;
    }
    NSUInteger physical=[self rotateRowsUpFrom:_scrollTop to:_scrollBottom];[self clearPhysicalRow:physical];
}
- (void)reverseIndex {
    [self markDamageX:0 y:_scrollTop width:_cols height:_scrollBottom-_scrollTop+1];
    if (_cursorY > _scrollTop) { _cursorY--; return; }
    NSUInteger physical=[self rotateRowsDownFrom:_scrollTop to:_scrollBottom];[self clearPhysicalRow:physical];
}
- (void)clearLinksInRow:(NSUInteger)y from:(NSUInteger)start to:(NSUInteger)end {if(!_linksByCell.count||y>=_rows)return;for(NSUInteger x=start;x<MIN(end,_cols);x++)[_linksByCell removeObjectForKey:[self linkKeyForX:x y:y]];}
- (void)eraseDisplay:(int)mode {
    TCell blank=[self blankCell];
    if (mode==2 || mode==3) { for(NSUInteger i=0;i<_cols*_rows;i++) _cells[i]=blank;if(_underlineStyles)memset(_underlineStyles,0,_cols*_rows);[_linksByCell removeAllObjects];[self resetRowOrder];if(mode==3)[self clearHistory];[self markAllDamage]; }
    else if(mode==0){for(NSUInteger y=_cursorY;y<_rows;y++){TCell *row=[self cellsForRow:y];NSUInteger start=y==_cursorY?_cursorX:0,physical=[self physicalRowForRow:y];for(NSUInteger x=start;x<_cols;x++)row[x]=blank;if(_underlineStyles)memset(_underlineStyles+physical*_cols+start,0,_cols-start);[self clearLinksInRow:y from:start to:_cols];}[self markDamageX:0 y:_cursorY width:_cols height:_rows-_cursorY];}
    else if(mode==1){for(NSUInteger y=0;y<=_cursorY&&y<_rows;y++){TCell *row=[self cellsForRow:y];NSUInteger end=y==_cursorY?MIN(_cols,_cursorX+1):_cols,physical=[self physicalRowForRow:y];for(NSUInteger x=0;x<end;x++)row[x]=blank;if(_underlineStyles)memset(_underlineStyles+physical*_cols,0,end);[self clearLinksInRow:y from:0 to:end];}[self markDamageX:0 y:0 width:_cols height:MIN(_rows,_cursorY+1)];}
}
- (void)eraseLine:(int)mode {
    TCell blank=[self blankCell]; NSUInteger a=0,b=_cols;
    if(mode==0)a=_cursorX; else if(mode==1)b=MIN(_cols,_cursorX+1);
    TCell *row=[self cellsForRow:_cursorY];for(NSUInteger x=a;x<b;x++)row[x]=blank;if(_underlineStyles)memset(_underlineStyles+[self physicalRowForRow:_cursorY]*_cols+a,0,b-a);[self clearLinksInRow:_cursorY from:a to:b];[self markDamageX:a y:_cursorY width:b-a height:1];
}
- (void)eraseCharacters:(int)n { TCell b=[self blankCell],*row=[self cellsForRow:_cursorY];NSUInteger end=MIN(_cols,_cursorX+(NSUInteger)n);for(NSUInteger x=_cursorX;x<end;x++)row[x]=b;if(_underlineStyles)memset(_underlineStyles+[self physicalRowForRow:_cursorY]*_cols+_cursorX,0,end-_cursorX);[self clearLinksInRow:_cursorY from:_cursorX to:end];[self markDamageX:_cursorX y:_cursorY width:end-_cursorX height:1]; }
- (void)deleteCharacters:(int)n { NSUInteger count=MIN((NSUInteger)n,_cols-_cursorX);TCell b=[self blankCell],*row=[self cellsForRow:_cursorY];memmove(row+_cursorX,row+_cursorX+count,(_cols-_cursorX-count)*sizeof(TCell));for(NSUInteger x=_cols-count;x<_cols;x++)row[x]=b;if(_underlineStyles){uint8_t *styles=_underlineStyles+[self physicalRowForRow:_cursorY]*_cols;memmove(styles+_cursorX,styles+_cursorX+count,_cols-_cursorX-count);memset(styles+_cols-count,0,count);}[self clearLinksInRow:_cursorY from:_cursorX to:_cols];[self markDamageX:_cursorX y:_cursorY width:_cols-_cursorX height:1]; }
- (void)insertCharacters:(int)n { NSUInteger count=MIN((NSUInteger)n,_cols-_cursorX);TCell b=[self blankCell],*row=[self cellsForRow:_cursorY];memmove(row+_cursorX+count,row+_cursorX,(_cols-_cursorX-count)*sizeof(TCell));for(NSUInteger x=_cursorX;x<_cursorX+count;x++)row[x]=b;if(_underlineStyles){uint8_t *styles=_underlineStyles+[self physicalRowForRow:_cursorY]*_cols;memmove(styles+_cursorX+count,styles+_cursorX,_cols-_cursorX-count);memset(styles+_cursorX,0,count);}[self clearLinksInRow:_cursorY from:_cursorX to:_cols];[self markDamageX:_cursorX y:_cursorY width:_cols-_cursorX height:1]; }
- (void)insertLines:(int)n { if(_cursorY<_scrollTop||_cursorY>_scrollBottom)return;[self normalizeRows];NSUInteger count=MIN((NSUInteger)n,_scrollBottom-_cursorY+1);memmove(_cells+(_cursorY+count)*_cols,_cells+_cursorY*_cols,(_scrollBottom-_cursorY+1-count)*_cols*sizeof(TCell));if(_underlineStyles){memmove(_underlineStyles+(_cursorY+count)*_cols,_underlineStyles+_cursorY*_cols,(_scrollBottom-_cursorY+1-count)*_cols);memset(_underlineStyles+_cursorY*_cols,0,count*_cols);}TCell b=[self blankCell];for(NSUInteger i=_cursorY*_cols;i<(_cursorY+count)*_cols;i++)_cells[i]=b;[_linksByCell removeAllObjects];[self markDamageX:0 y:_cursorY width:_cols height:_scrollBottom-_cursorY+1]; }
- (void)deleteLines:(int)n { if(_cursorY<_scrollTop||_cursorY>_scrollBottom)return;[self normalizeRows];NSUInteger count=MIN((NSUInteger)n,_scrollBottom-_cursorY+1);memmove(_cells+_cursorY*_cols,_cells+(_cursorY+count)*_cols,(_scrollBottom-_cursorY+1-count)*_cols*sizeof(TCell));if(_underlineStyles){memmove(_underlineStyles+_cursorY*_cols,_underlineStyles+(_cursorY+count)*_cols,(_scrollBottom-_cursorY+1-count)*_cols);memset(_underlineStyles+(_scrollBottom-count+1)*_cols,0,count*_cols);}TCell b=[self blankCell];for(NSUInteger i=(_scrollBottom-count+1)*_cols;i<=_scrollBottom*_cols+_cols-1;i++)_cells[i]=b;[_linksByCell removeAllObjects];[self markDamageX:0 y:_cursorY width:_cols height:_scrollBottom-_cursorY+1]; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)finishOSC:(NSString *)osc __attribute__((objc_direct)) {
    if([osc hasPrefix:@"bsu"]||[osc hasPrefix:@"esu"]){_synchronizedUpdates=[osc hasPrefix:@"bsu"];return;}
    if([osc hasPrefix:@"1337;File="]){[self parseIterm2Image:osc];return;}
    if(osc.length>0&&[osc characterAtIndex:0]=='q'){[self parseSixel:osc];return;}
    NSArray *parts=[osc componentsSeparatedByString:@";"];
    if(parts.count>1 && ([parts[0] isEqualToString:@"0"]||[parts[0] isEqualToString:@"2"])) {
        NSString *title=[[parts subarrayWithRange:NSMakeRange(1,parts.count-1)] componentsJoinedByString:@";"];
        if(self.titleChanged){void(^changed)(NSString *)=[self.titleChanged copy];dispatch_async(dispatch_get_main_queue(),^{changed(title);});}
    } else if (self.config.oscIntegration&&[osc hasPrefix:@"7;file://"]) {
        NSString *urlString=[osc substringFromIndex:2]; NSURL *url=[NSURL URLWithString:urlString];
        if(url.path.length&&self.cwdChanged){void(^changed)(NSString *)=[self.cwdChanged copy];NSString *path=url.path;dispatch_async(dispatch_get_main_queue(),^{changed(path);});}
    } else if(self.config.oscIntegration&&[osc hasPrefix:@"8;"]){
        NSRange first=[osc rangeOfString:@";"],second=first.location==NSNotFound?NSMakeRange(NSNotFound,0):[osc rangeOfString:@";" options:0 range:NSMakeRange(NSMaxRange(first),osc.length-NSMaxRange(first))];NSString *url=second.location==NSNotFound?@"":[osc substringFromIndex:NSMaxRange(second)];_currentLink=url.length?url:nil;
    } else if([osc hasPrefix:@"133;"]){
        NSString *mark=parts.count>1?parts[1]:@"";
        // A new PTY is deliberately a fresh terminal. Anchor its first real shell
        // prompt after startup hooks have finished so no prior/startup cursor row can
        // make a reopened window begin partway down the viewport.
        if(_freshLaunchAwaitingPrompt&&[mark isEqual:@"A"]){_freshLaunchAwaitingPrompt=NO;[self eraseDisplay:2];[self clearHistory];_cursorX=_cursorY=0;[self resetRowOrder];_historyOffset=0;_inlineViewportMode=NO;_inlineViewportTop=0;[_commandMarks removeAllObjects];[_linksByCell removeAllObjects];[_inlineImages removeAllObjects];[self markAllDamage];TLog(@"Fresh shell prompt anchored at row zero");}
        if(self.config.oscIntegration){NSMutableDictionary *entry=[@{@"mark":mark,@"row":@(_historyCount+_cursorY)} mutableCopy];if([mark isEqual:@"D"]&&parts.count>2)entry[@"status"]=parts[2];[_commandMarks addObject:entry];if(_commandMarks.count>2048)[_commandMarks removeObjectsInRange:NSMakeRange(0,_commandMarks.count-2048)];}
    } else if(parts.count>=3&&[parts[0] isEqual:@"4"]){for(NSUInteger i=1;i+1<parts.count;i+=2){NSInteger index=[parts[i] integerValue];if(index<0||index>255)continue;if([parts[i+1] isEqual:@"?"]){[self sendString:[NSString stringWithFormat:@"\033]4;%ld;rgb:%02x%02x/%02x%02x/%02x%02x\033\\",(long)index,(unsigned)((_palette256[index]>>16)&255),(unsigned)((_palette256[index]>>16)&255),(unsigned)((_palette256[index]>>8)&255),(unsigned)((_palette256[index]>>8)&255),(unsigned)(_palette256[index]&255),(unsigned)(_palette256[index]&255)]];}else{uint32_t color=0;if(TParseOSCColor(parts[i+1],&color))_palette256[index]=color;}}_palette256Valid=YES;[self setNeedsDisplay:YES];
    } else if([parts[0] isEqual:@"104"]){if(parts.count==1){for(NSUInteger i=0;i<256;i++)_palette256[i]=[self colorFor256:(int)i];}else for(NSUInteger i=1;i<parts.count;i++){NSInteger index=[parts[i] integerValue];if(index>=0&&index<256)_palette256[index]=[self colorFor256:(int)index];}_palette256Valid=YES;[self setNeedsDisplay:YES];
    } else if(parts.count>1&&([parts[0] isEqual:@"10"]||[parts[0] isEqual:@"11"]||[parts[0] isEqual:@"12"])&&[parts[1] isEqual:@"?"]){
        NSColor *color=[parts[0] isEqual:@"10"]?self.config.foreground:([parts[0] isEqual:@"11"]?self.config.background:self.config.cursor);[self sendString:[NSString stringWithFormat:@"\033]%@;%@\033\\",parts[0],TOSCColor(color)]];
    } else if(parts.count>2&&[parts[0] isEqual:@"52"]){
        NSString *rawSelector=[parts[1] isKindOfClass:NSString.class]?parts[1]:@"",*selector=rawSelector.length?rawSelector:@"c",*payload=[[parts subarrayWithRange:NSMakeRange(2,parts.count-2)] componentsJoinedByString:@";"],*policy=[payload isEqual:@"?"]?self.config.clipboardRead:self.config.clipboardWrite;__weak typeof(self) weakSelf=self;
        dispatch_async(dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;BOOL allowed=[policy isEqual:@"allow"];if([policy isEqual:@"ask"]){NSAlert *alert=[NSAlert new];alert.messageText=[payload isEqual:@"?"]?@"Allow terminal clipboard access?":@"Allow terminal software to change the clipboard?";alert.informativeText=@"The request came from software running inside this terminal.";[alert addButtonWithTitle:@"Allow Once"];[alert addButtonWithTitle:@"Deny"];alert.alertStyle=NSAlertStyleWarning;allowed=[alert runModal]==NSAlertFirstButtonReturn;}if(!allowed){if([payload isEqual:@"?"])[self sendString:[NSString stringWithFormat:@"\033]52;%@;\033\\",selector]];return;}if([payload isEqual:@"?"]){NSString *text=[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]?:@"";NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];if(data.length>1048576)data=[data subdataWithRange:NSMakeRange(0,1048576)];[self sendString:[NSString stringWithFormat:@"\033]52;%@;%@\033\\",selector,[data base64EncodedStringWithOptions:0]]];}else if(payload.length<=1398104){NSData *data=[[NSData alloc]initWithBase64EncodedString:payload options:0];NSString *text=data.length<=1048576?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:nil;if(text){[NSPasteboard.generalPasteboard clearContents];[NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];}}});
    } else if(parts.count>1&&([parts[0] isEqual:@"9"]||[parts[0] isEqual:@"777"])){
        NSString *message=[[parts subarrayWithRange:NSMakeRange(1,parts.count-1)] componentsJoinedByString:@";"];if(message.length){dispatch_async(dispatch_get_main_queue(),^{NSUserNotification *notice=[NSUserNotification new];notice.title=@"Terminal";notice.informativeText=[message substringToIndex:MIN((NSUInteger)512,message.length)];[NSUserNotificationCenter.defaultUserNotificationCenter deliverNotification:notice];});}
    }
}
#pragma clang diagnostic pop
- (void)resetTerminal {TDecoderReset(&_decoder);_currentFG=_currentBG=TDefaultColor; _currentFlags=0; _cursorX=_cursorY=0;_scrollTop=0;_scrollBottom=_rows-1;_kittyKeyboardFlags=0;_modifyOtherKeys=0;_applicationCursorKeys=NO;_applicationCursorStyle=nil;_autoWrap=YES;_alternateScroll=NO;_focusReporting=NO;_mouseTrackingMode=0;_utf8Mouse=NO;_sgrMouse=NO;_urxvtMouse=NO;_pixelMouse=NO;_synchronizedUpdates=NO;_inlineViewportMode=NO;_inlineViewportTop=0;_g0SpecialGraphics=_g1SpecialGraphics=_activeG1=NO;_charsetDesignation=0;_hasLastEmittedCodepoint=NO;_currentLink=nil;[_commandMarks removeAllObjects];[_linksByCell removeAllObjects];if(_alternateScreen)[self leaveAlternateScreen];[self eraseDisplay:2]; }
- (void)clearTerminal { [self eraseDisplay:2]; _cursorX=_cursorY=0; [self clearHistory]; [self refreshTextView];[self setNeedsDisplay:YES]; }
- (void)clearScrollbackPreservingPrompt {
    [self clearHistory];_historyOffset=0;_hasSelection=NO;
    uint8_t formFeed=0x0C;[self sendBytes:&formFeed length:1];
    [self refreshTextView];[self setNeedsDisplay:YES];
}

- (const TCell *)lineAtVisibleIndex:(NSInteger)index temporary:(NSData **)temporary {
    if(_inlineViewportMode&&_historyOffset>0&&_inlineViewportTop>0&&_inlineViewportTop<_rows&&index>=(NSInteger)_inlineViewportTop&&index<(NSInteger)_rows)return [self cellsForRow:(NSUInteger)index];
    NSInteger totalHistory=(NSInteger)_historyCount;
    NSInteger first=totalHistory-(NSInteger)_historyOffset;
    NSInteger logical=first+index;
    if(logical<totalHistory && logical>=0){NSData *d=[self historyLineAtIndex:(NSUInteger)logical];NSUInteger full=_cols*sizeof(TCell);if(d.length>=full){*temporary=d;return d.bytes;}[_scratchLine setLength:full];TCell blank=[self blankCell],*cells=_scratchLine.mutableBytes;for(NSUInteger i=0;i<_cols;i++)cells[i]=blank;if(d.length)memcpy(cells,d.bytes,d.length);*temporary=_scratchLine;return cells;}
    NSInteger row=logical-totalHistory;
    if(row>=0 && row<(NSInteger)_rows)return [self cellsForRow:(NSUInteger)row];
    return NULL;
}
- (TRenderSnapshot *)renderSnapshot {
    @synchronized(self){
        NSUInteger cellCount=_rows*_cols;NSUInteger cellBytes=cellCount*sizeof(TCell);
        NSMutableData *cells=[NSMutableData dataWithLength:cellBytes];TCell *destination=cells.mutableBytes;
        if(_historyOffset==0&&!_inlineViewportMode){for(NSUInteger row=0;row<_rows;row++)memcpy(destination+row*_cols,[self cellsForRow:row],_cols*sizeof(TCell));}
        else{for(NSUInteger row=0;row<_rows;row++){NSData *hold=nil;const TCell *source=[self lineAtVisibleIndex:(NSInteger)row temporary:&hold];if(source)memcpy(destination+row*_cols,source,_cols*sizeof(TCell));}}
        NSMutableData *underlines=[NSMutableData dataWithLength:cellCount];if(_underlineStyles){uint8_t *destinationUnderlines=underlines.mutableBytes;for(NSUInteger row=0;row<_rows;row++)memcpy(destinationUnderlines+row*_cols,_underlineStyles+[self physicalRowForRow:row]*_cols,_cols);}
        NSUInteger maskLength=cellCount;static NSCache<NSNumber *,NSData *> *TZeroMasks=nil;static dispatch_once_t once;dispatch_once(&once,^{TZeroMasks=[NSCache new];TZeroMasks.countLimit=16;});
        NSNumber *maskKey=@(maskLength);NSData *zero=[TZeroMasks objectForKey:maskKey];if(!zero){zero=[[NSMutableData dataWithLength:maskLength] copy];[TZeroMasks setObject:zero forKey:maskKey];}
        NSData *selection=_hasSelection?[NSMutableData dataWithLength:maskLength]:zero,*search=_searchResults.count?[NSMutableData dataWithLength:maskLength]:zero,*links=(_historyOffset==0&&_linksByCell.count)?[NSMutableData dataWithLength:maskLength]:zero;
        if(_hasSelection){uint8_t *bytes=[(NSMutableData *)selection mutableBytes];for(NSUInteger row=0;row<_rows;row++)for(NSUInteger column=0;column<_cols;column++)bytes[row*_cols+column]=[self cellSelectedX:column y:row];}
        if(_searchResults.count){uint8_t *bytes=[(NSMutableData *)search mutableBytes];for(NSUInteger row=0;row<_rows;row++)for(NSUInteger column=0;column<_cols;column++)bytes[row*_cols+column]=[self cellInSearchResult:column y:row];}
        if(_historyOffset==0&&_linksByCell.count){uint8_t *bytes=[(NSMutableData *)links mutableBytes];for(NSUInteger row=0;row<_rows;row++)for(NSUInteger column=0;column<_cols;column++)bytes[row*_cols+column]=_linksByCell[[self linkKeyForX:column y:row]]!=nil;}
        CGFloat scale=self.window.screen.backingScaleFactor?:NSScreen.mainScreen.backingScaleFactor?:1;
        TRenderMetrics metrics={_rows,_cols,_cellWidth,_cellHeight,scale,self.bounds.size.width,self.bounds.size.height};
        NSRange damaged=_damageValid?NSMakeRange(_damageMinY,MAX((NSUInteger)1,_damageMaxY-_damageMinY)):NSMakeRange(0,0);
        if(!_cachedPlainPalette){NSMutableArray<NSNumber *> *plain=[NSMutableArray array];for(NSColor *color in self.config.plainTextPalette)[plain addObject:@(TRGB(color))];_cachedPlainPalette=[plain copy];}
        BOOL cursorActive=self.window.firstResponder==self||self.activeTerminal,pinnedInlineCursor=_inlineViewportMode&&_inlineViewportTop>0&&_cursorY>=_inlineViewportTop,cursorShown=_cursorVisible&&(_historyOffset==0||pinnedInlineCursor)&&(_cursorBlink?_cursorBlinkVisible:YES)&&cursorActive;
        NSFont *fallback=[NSFont monospacedSystemFontOfSize:self.config.fontSize weight:NSFontWeightRegular];
        NSDictionary *style=@{@"foreground":@(TRGB(self.config.foreground)),@"background":@(TRGB(self.config.background)),@"backgroundAlpha":@(self.config.background.alphaComponent),@"cursor":@(TRGB(self.config.cursor)),@"accent":@(TRGB(self.config.accent)),@"selection":@(TRGB(self.config.selection)),@"plainPalette":_cachedPlainPalette,@"colorize":@(self.config.colorizePlainText),@"font":_font?:fallback,@"boldFont":_boldFont?:_font?:fallback,@"italicFont":_italicFont?:_font?:fallback,@"left":@(self.config.padding+self.leadingOverlayInset),@"top":@(self.config.padding+self.topContentInset),@"cursorStyle":_applicationCursorStyle?:self.config.cursorStyle?:@"block",@"cursorFocused":@(cursorActive),@"cursorThickness":@(self.config->cursorThickness),@"cursorBlockOpacity":@(self.config->cursorBlockOpacity),@"cursorInactiveOpacity":@(self.config->cursorInactiveOpacity),@"scrollbarWidth":@(self.config->scrollbarWidth),@"scrollbarMargin":@(self.config->scrollbarMargin),@"scrollbarMinimumThumb":@(self.config->scrollbarMinimumThumb),@"scrollbarOpacity":@(self.config->scrollbarOpacity),@"glow":@(self.config.glow),@"scanlines":@(self.config.scanlines),@"scanlineSpacing":@(self.config->scanlineSpacing),@"scanlineThickness":@(self.config->scanlineThickness),@"vignette":@(self.config.vignette),@"vignetteLayers":@(self.config->vignetteLayers),@"tiled":@(self.tiledRendering)};
        NSUInteger presentedCursorX=_cols?MIN(_cursorX,_cols-1):0,presentedCursorY=_rows?MIN(_cursorY,_rows-1):0;
        return [[TRenderSnapshot alloc]initWithGeneration:++_renderGeneration metrics:metrics cells:cells underlineStyles:underlines selectionMask:selection searchMask:search linkMask:links graphemes:_graphemes style:style links:_linksByCell images:_inlineImages cursorX:presentedCursorX cursorY:presentedCursorY cursorVisible:cursorShown historyCount:_historyCount historyOffset:_historyOffset fullDamage:_damageFull damagedRows:damaged];
    }
}
#if TERMATICA_BENCHMARKS
- (void)setDisplaySnapshotForRendererSelfTest:(TRenderSnapshot *)snapshot {_displaySnapshot=snapshot;}
- (BOOL)configureRendererForSnapshotSelfTest:(TRenderSnapshot *)snapshot {if(!snapshot.isValid||!_renderBackend)return NO;NSError *error=nil;BOOL configured=[_renderBackend configureWithMetrics:snapshot.metrics error:&error];if(configured&&_metalBackend)[_metalBackend setPresentationFrame:self.bounds scale:snapshot.metrics.scale];return configured;}
- (void)presentSnapshotForRendererSelfTest:(TRenderSnapshot *)snapshot {if(snapshot.isValid&&_renderBackend)[_renderBackend presentSnapshot:snapshot];}
- (NSDictionary *)metalFrameCaptureForRendererSelfTest {
    return [_metalBackend validationFrameCapture]?:@{};
}
- (NSDictionary *)metalCacheDiagnosticsForRendererSelfTest {return [_metalBackend cacheDiagnostics]?:@{};}
- (NSDictionary *)metalSchedulerDiagnosticsForRendererSelfTest {return [_metalBackend schedulerDiagnostics]?:@{};}
- (void)purgeMetalCachesForRendererSelfTest {[_metalBackend purgeCachesForValidation];}
#endif
- (BOOL)cellSelectedX:(NSUInteger)x y:(NSUInteger)y {
    if(!_hasSelection)return NO;
    NSInteger a=(NSInteger)_selectionStart.y*(NSInteger)_cols+(NSInteger)_selectionStart.x;
    NSInteger b=(NSInteger)_selectionEnd.y*(NSInteger)_cols+(NSInteger)_selectionEnd.x;
    if(a>b){NSInteger t=a;a=b;b=t;} NSInteger p=(NSInteger)y*(NSInteger)_cols+(NSInteger)x;
    return p>=a&&p<=b;
}
- (NSString *)stringForCodepoint:(uint32_t)cp {if(cp>=TClusterBase){NSUInteger index=cp-TClusterBase;return index<_graphemes.count?_graphemes[index]:@"\uFFFD";}if(cp<=0xFFFF)return [NSString stringWithCharacters:(unichar[]){(unichar)(cp?:' ')} length:1];if(cp>0x10FFFF)return @"\uFFFD";uint32_t v=cp-0x10000;unichar pair[2]={(unichar)(0xD800+(v>>10)),(unichar)(0xDC00+(v&0x3FF))};return [NSString stringWithCharacters:pair length:2];}
- (void)refreshTextView {
    if(!NSThread.isMainThread){
        @synchronized(self){if(_synchronizedUpdates||_displayScheduled||_refreshEnqueued||self.hidden)return;_refreshEnqueued=YES;}
        __weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;@synchronized(self){self->_refreshEnqueued=NO;}[self refreshTextView];});return;
    }
    if(_synchronizedUpdates||_displayScheduled||self.hidden)return;_displayScheduled=YES;__weak typeof(self) weakSelf=self;
    NSScreen *screen=self.window.screen?:NSScreen.mainScreen;NSUInteger fps=(screen&&[screen respondsToSelector:@selector(maximumFramesPerSecond)])?screen.maximumFramesPerSecond:60;uint64_t delay=self.activeTerminal?MAX(4,MIN(8,1000/fps)):(fps>=100?8:16);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;self->_displayScheduled=NO;TRenderSnapshot *snapshot=[self renderSnapshot];NSRect damage=[self takeDamageRect];if(!NSIsEmptyRect(damage)&&self->_renderBackend)[self->_renderBackend presentSnapshot:snapshot];[self updateSecureKeyboardInput];if(NSWorkspace.sharedWorkspace.isVoiceOverEnabled&&!self->_accessibilityUpdatePending){self->_accessibilityUpdatePending=YES;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;self.accessibilityValue=[self visibleText];self->_accessibilityUpdatePending=NO;});}});
}
- (NSDictionary *)textAttributesForForeground:(uint32_t)foreground flags:(uint8_t)flags shadow:(NSShadow *)shadow underlineStyle:(uint8_t)underlineStyle {NSNumber *key=@((foreground<<16)|(flags<<8)|underlineStyle);NSDictionary *cached=_attributeCache[key];if(cached)return cached;NSFont *font=(flags&TBold)?_boldFont:((flags&TItalic)?_italicFont:_font);CGFloat glyphAdvance=font==_font?_cachedGlyphAdvance:[@"M" sizeWithAttributes:@{NSFontAttributeName:font}].width,cellKern=_cellWidth-glyphAdvance;NSMutableDictionary *attrs=[@{NSFontAttributeName:font,NSForegroundColorAttributeName:TColor(foreground),NSKernAttributeName:@(cellKern),NSLigatureAttributeName:@1} mutableCopy];if(shadow)attrs[NSShadowAttributeName]=shadow;if(flags&TUnderline){NSInteger style=NSUnderlineStyleSingle;if(underlineStyle==2)style=NSUnderlineStyleThick;else if(underlineStyle==3)style=NSUnderlineStyleSingle|NSUnderlinePatternDash;else if(underlineStyle==4)style=NSUnderlineStyleSingle|NSUnderlinePatternDot;else if(underlineStyle==5)style=NSUnderlineStyleSingle|NSUnderlinePatternDashDot;attrs[NSUnderlineStyleAttributeName]=@(style);}if(_attributeCache.count>=1024){NSEnumerator *e=[_attributeCache keyEnumerator];NSNumber *evict=[e nextObject];if(evict)[_attributeCache removeObjectForKey:evict];}_attributeCache[key]=attrs;return attrs;}
- (NSDictionary *)textAttributesForForeground:(uint32_t)foreground flags:(uint8_t)flags shadow:(NSShadow *)shadow {return [self textAttributesForForeground:foreground flags:flags shadow:shadow underlineStyle:0];}
- (NSDictionary *)snapshotTextAttributes:(TRenderSnapshot *)snapshot foreground:(uint32_t)foreground flags:(uint8_t)flags shadow:(NSShadow *)shadow underlineStyle:(uint8_t)underlineStyle {
    (void)snapshot;
    return [self textAttributesForForeground:foreground flags:flags shadow:shadow underlineStyle:underlineStyle];
}
- (NSDictionary *)wideSnapshotTextAttributes:(TRenderSnapshot *)snapshot foreground:(uint32_t)foreground flags:(uint8_t)flags shadow:(NSShadow *)shadow underlineStyle:(uint8_t)underlineStyle {
    (void)snapshot;NSNumber *key=@((foreground<<16)|(flags<<8)|underlineStyle);NSDictionary *cached=_wideAttributeCache[key];if(cached)return cached;
    NSMutableDictionary *attributes=[[self textAttributesForForeground:foreground flags:flags shadow:shadow underlineStyle:underlineStyle] mutableCopy];[attributes removeObjectForKey:NSKernAttributeName];
    if(_wideAttributeCache.count>=1024){NSNumber *evict=_wideAttributeCache.keyEnumerator.nextObject;if(evict)[_wideAttributeCache removeObjectForKey:evict];}_wideAttributeCache[key]=attributes;return attributes;
}
- (NSString *)stringForSnapshot:(TRenderSnapshot *)snapshot codepoint:(uint32_t)codepoint {
    if(codepoint>=TClusterBase){NSUInteger index=codepoint-TClusterBase;return index<snapshot.graphemes.count?snapshot.graphemes[index]:@"\uFFFD";}
    if(!codepoint)codepoint=' ';if(codepoint<=0xFFFF){unichar value=(unichar)codepoint;return [NSString stringWithCharacters:&value length:1];}
    if(codepoint>0x10FFFF)return @"\uFFFD";uint32_t value=codepoint-0x10000;unichar pair[2]={(unichar)(0xD800+(value>>10)),(unichar)(0xDC00+(value&0x3FF))};return [NSString stringWithCharacters:pair length:2];
}
- (void)drawRect:(NSRect)dirtyRect {
    TRenderSnapshot *snapshot=_displaySnapshot?:[self renderSnapshot];if(!snapshot.isValid)return;
    NSDictionary *style=snapshot.style;NSUInteger rows=snapshot.metrics.rows,columns=snapshot.metrics.columns;CGFloat cellWidth=snapshot.metrics.cellWidth,cellHeight=snapshot.metrics.cellHeight,left=[style[@"left"] doubleValue],top=[style[@"top"] doubleValue];
    uint32_t defaultForeground=[style[@"foreground"] unsignedIntValue],defaultBackground=[style[@"background"] unsignedIntValue],accent=[style[@"accent"] unsignedIntValue],selectionColor=[style[@"selection"] unsignedIntValue];
    [[TColor(defaultBackground) colorWithAlphaComponent:[style[@"backgroundAlpha"] doubleValue]]setFill];NSRectFill(dirtyRect);
    NSInteger firstRow=MAX(0,(NSInteger)floor((NSMinY(dirtyRect)-top)/MAX(1,cellHeight))),lastRow=MIN((NSInteger)rows,(NSInteger)ceil((NSMaxY(dirtyRect)-top)/MAX(1,cellHeight))),firstColumn=MAX(0,(NSInteger)floor((NSMinX(dirtyRect)-left)/MAX(1,cellWidth))),lastColumn=MIN((NSInteger)columns,(NSInteger)ceil((NSMaxX(dirtyRect)-left)/MAX(1,cellWidth)));if(lastRow<firstRow)lastRow=firstRow;if(lastColumn<firstColumn)lastColumn=firstColumn;
    NSShadow *shadow=nil;CGFloat glow=[style[@"glow"] doubleValue];if(glow>0){shadow=[NSShadow new];shadow.shadowColor=[TColor(accent) colorWithAlphaComponent:glow];shadow.shadowBlurRadius=1+glow*3;shadow.shadowOffset=NSZeroSize;}
    const TCell *allCells=snapshot.cells.bytes;const uint8_t *underlines=snapshot.underlineStyles.bytes,*selected=snapshot.selectionMask.bytes,*searched=snapshot.searchMask.bytes,*linked=snapshot.linkMask.bytes;NSArray<NSNumber *> *plain=style[@"plainPalette"];NSUInteger plainCount=[style[@"colorize"] boolValue]?MIN((NSUInteger)8,plain.count):0;
    [_glyphScratch setLength:MAX((NSUInteger)1,columns*2)*sizeof(unichar)];[_colorScratch setLength:MAX((NSUInteger)1,columns)*sizeof(uint32_t)];unichar *glyphs=_glyphScratch.mutableBytes;uint32_t *plainForegrounds=_colorScratch.mutableBytes;
    for(NSInteger y=firstRow;y<lastRow;y++){const TCell *line=allCells+y*columns;BOOL inToken=NO;NSUInteger token=0;
        for(NSUInteger column=0;column<columns;column++){BOOL whitespace=!line[column].ch||line[column].ch==' '||line[column].ch=='\t';if(whitespace)inToken=NO;else if(!inToken){inToken=YES;token++;}plainForegrounds[column]=plainCount&&!whitespace?[plain[(token-1)%plainCount] unsignedIntValue]:defaultForeground;}
        NSInteger x=firstColumn;while(x<lastColumn){NSUInteger index=y*columns+x;TCell cell=line[x];BOOL inverse=(cell.flags&TInverse)!=0;uint32_t background=inverse?(cell.fg==TDefaultColor?defaultForeground:cell.fg):(cell.bg==TDefaultColor?defaultBackground:cell.bg);if(searched[index])background=accent;NSInteger kind=selected[index]?1:(searched[index]?3:((cell.bg!=TDefaultColor||inverse)?2:0)),start=x;x++;while(x<lastColumn){NSUInteger nextIndex=y*columns+x;TCell next=line[x];BOOL nextInverse=(next.flags&TInverse)!=0;uint32_t nextBackground=nextInverse?(next.fg==TDefaultColor?defaultForeground:next.fg):(next.bg==TDefaultColor?defaultBackground:next.bg);if(searched[nextIndex])nextBackground=accent;NSInteger nextKind=selected[nextIndex]?1:(searched[nextIndex]?3:((next.bg!=TDefaultColor||nextInverse)?2:0));if(nextKind!=kind||(kind==2&&nextBackground!=background))break;x++;}if(kind){[TColor(kind==1?selectionColor:(kind==3?accent:background))setFill];NSRectFill(NSMakeRect(left+start*cellWidth,top+y*cellHeight,(x-start)*cellWidth,cellHeight));}}
        x=firstColumn;while(x<lastColumn){NSUInteger index=y*columns+x;TCell cell=line[x];if(cell.flags&TContinuation){x++;continue;}BOOL inverse=(cell.flags&TInverse)!=0;uint32_t foreground=inverse?(cell.bg==TDefaultColor?defaultBackground:cell.bg):(cell.fg==TDefaultColor?plainForegrounds[x]:cell.fg);uint8_t flags=(cell.flags&TStyleMask)|(linked[index]?TUnderline:0),underline=underlines[index];if(cell.flags&(TWide|TCluster)){NSString *text=[self stringForSnapshot:snapshot codepoint:cell.ch];[text drawAtPoint:NSMakePoint(left+x*cellWidth,top+y*cellHeight) withAttributes:[self wideSnapshotTextAttributes:snapshot foreground:foreground flags:flags shadow:shadow underlineStyle:underline]];x+=(cell.flags&TWide)?2:1;continue;}NSInteger start=x;NSUInteger length=0;BOOL hasGlyph=NO;while(x<lastColumn){NSUInteger nextIndex=y*columns+x;TCell next=line[x];if(next.flags&(TWide|TCluster|TContinuation))break;BOOL nextInverse=(next.flags&TInverse)!=0;uint32_t nextForeground=nextInverse?(next.bg==TDefaultColor?defaultBackground:next.bg):(next.fg==TDefaultColor?plainForegrounds[x]:next.fg);uint8_t nextFlags=(next.flags&TStyleMask)|(linked[nextIndex]?TUnderline:0);if(nextForeground!=foreground||nextFlags!=flags)break;uint32_t codepoint=next.ch?:' ';if(codepoint!=' ')hasGlyph=YES;length=TAppendUTF16(glyphs,length,codepoint);x++;}if(hasGlyph&&length){NSString *text=CFBridgingRelease(CFStringCreateWithCharactersNoCopy(NULL,glyphs,length,kCFAllocatorNull));[text drawAtPoint:NSMakePoint(left+start*cellWidth,top+y*cellHeight) withAttributes:[self snapshotTextAttributes:snapshot foreground:foreground flags:flags shadow:shadow underlineStyle:underline]];}}
    }
    if(snapshot.cursorVisible){NSString *cursorStyle=style[@"cursorStyle"]?:@"block";BOOL block=![cursorStyle isEqual:@"bar"]&&![cursorStyle isEqual:@"underline"],focused=[style[@"cursorFocused"] boolValue];CGFloat thickness=[style[@"cursorThickness"] doubleValue],blockOpacity=[style[@"cursorBlockOpacity"] doubleValue],inactiveOpacity=[style[@"cursorInactiveOpacity"] doubleValue];[[TColor([style[@"cursor"] unsignedIntValue]) colorWithAlphaComponent:focused?(block?blockOpacity:0.96):(block?inactiveOpacity:0.5)]setFill];NSRect cursorRect=NSMakeRect(left+snapshot.cursorX*cellWidth,top+snapshot.cursorY*cellHeight,cellWidth,cellHeight);if([cursorStyle isEqual:@"bar"])cursorRect.size.width=thickness;else if([cursorStyle isEqual:@"underline"]){cursorRect.origin.y+=cellHeight-thickness;cursorRect.size.height=thickness;}NSRectFillUsingOperation(cursorRect,NSCompositingOperationSourceOver);}
    for(NSNumber *key in snapshot.images){NSUInteger value=key.unsignedIntegerValue,row=value>>16,column=value&0xFFFF;CGImageRef image=(__bridge CGImageRef)snapshot.images[key];if(!image)continue;NSRect imageRect=NSMakeRect(left+column*cellWidth,top+row*cellHeight,CGImageGetWidth(image),CGImageGetHeight(image));if(NSIntersectsRect(imageRect,dirtyRect)){CGContextRef context=NSGraphicsContext.currentContext.CGContext;CGContextSaveGState(context);CGContextDrawImage(context,NSRectToCGRect(imageRect),image);CGContextRestoreGState(context);}}
    CGFloat scanlines=[style[@"scanlines"] doubleValue],scanlineSpacing=[style[@"scanlineSpacing"] doubleValue],scanlineThickness=[style[@"scanlineThickness"] doubleValue];if(scanlines>0){[[NSColor colorWithWhite:0 alpha:scanlines*0.10]setFill];for(CGFloat y=MAX(scanlineThickness,floor(NSMinY(dirtyRect)/scanlineSpacing)*scanlineSpacing);y<NSMaxY(dirtyRect);y+=scanlineSpacing)NSRectFillUsingOperation(NSMakeRect(NSMinX(dirtyRect),y,NSWidth(dirtyRect),scanlineThickness),NSCompositingOperationSourceOver);}
    CGFloat vignette=[style[@"vignette"] doubleValue];NSUInteger vignetteLayers=[style[@"vignetteLayers"] unsignedIntegerValue];if(vignette>0&&![style[@"tiled"] boolValue])for(NSUInteger i=0;i<vignetteLayers;i++){[[NSColor colorWithWhite:0 alpha:vignette*(vignetteLayers-i)/MAX(1.0,vignetteLayers*5.0)]setStroke];[[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds,i+0.5,i+0.5)]stroke];}
    if(snapshot.historyCount&&snapshot.historyOffset>0){CGFloat margin=[style[@"scrollbarMargin"] doubleValue],width=[style[@"scrollbarWidth"] doubleValue],track=MAX(1,NSHeight(self.bounds)-margin*2),total=snapshot.historyCount+rows,visible=rows,thumb=MAX([style[@"scrollbarMinimumThumb"] doubleValue],track*visible/MAX(visible,total)),progress=(CGFloat)snapshot.historyOffset/MAX(1,(CGFloat)snapshot.historyCount),y=margin+(track-thumb)*(1-progress);[[TColor(defaultForeground) colorWithAlphaComponent:[style[@"scrollbarOpacity"] doubleValue]]setFill];[[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMaxX(self.bounds)-margin,y,width,thumb) xRadius:width/2 yRadius:width/2]fill];}
}
- (NSPoint)cellForPoint:(NSPoint)p { NSInteger x=floor((p.x-self.config.padding-self.leadingOverlayInset)/_cellWidth),y=floor((p.y-self.config.padding-self.topContentInset)/_cellHeight); return NSMakePoint(MAX(0,MIN((NSInteger)_cols-1,x)),MAX(0,MIN((NSInteger)_rows-1,y))); }
- (NSUInteger)lastSelectableRow {
    TRenderSnapshot *snapshot=_displaySnapshot?:[self renderSnapshot];NSUInteger rows=snapshot.metrics.rows,columns=snapshot.metrics.columns,last=rows?MIN(snapshot.cursorY,rows-1):0;const TCell *cells=snapshot.cells.bytes;
    if(cells&&columns)for(NSUInteger y=rows;y>0;y--){NSUInteger row=y-1;BOOL occupied=NO;for(NSUInteger x=0;x<columns;x++){TCell cell=cells[row*columns+x];if((cell.ch&&cell.ch!=' '&&cell.ch!='\t')||cell.bg!=TDefaultColor||(cell.flags&TInverse)){occupied=YES;break;}}if(occupied){last=MAX(last,row);break;}}
    for(NSNumber *key in snapshot.images){NSUInteger value=key.unsignedIntegerValue,row=value>>16;CGImageRef image=(__bridge CGImageRef)snapshot.images[key];NSUInteger height=image?MAX((NSUInteger)1,(NSUInteger)ceil(CGImageGetHeight(image)/MAX((CGFloat)1,snapshot.metrics.cellHeight))):1;last=MAX(last,MIN(rows?rows-1:0,row+height-1));}
    return last;
}
- (BOOL)pointIsInSelectableContent:(NSPoint)local {
    NSInteger rawColumn=floor((local.x-self.config.padding-self.leadingOverlayInset)/MAX((CGFloat)1,_cellWidth)),rawRow=floor((local.y-self.config.padding-self.topContentInset)/MAX((CGFloat)1,_cellHeight));
    return rawColumn>=0&&rawColumn<(NSInteger)_cols&&rawRow>=0&&rawRow<(NSInteger)_rows&&(NSUInteger)rawRow<=[self lastSelectableRow];
}
- (void)sendMouseButton:(NSUInteger)button event:(NSEvent *)event release:(BOOL)release motion:(BOOL)motion {
    NSPoint local=[self convertPoint:event.locationInWindow fromView:nil],cell=[self cellForPoint:local];NSUInteger code=button+(motion?32:0);if(event.modifierFlags&NSEventModifierFlagShift)code+=4;if(event.modifierFlags&NSEventModifierFlagOption)code+=8;if(event.modifierFlags&NSEventModifierFlagControl)code+=16;NSUInteger x=_pixelMouse?(NSUInteger)MAX(1,floor(local.x)+1):(NSUInteger)cell.x+1,y=_pixelMouse?(NSUInteger)MAX(1,floor(local.y)+1):(NSUInteger)cell.y+1;
    if(_sgrMouse||_pixelMouse)[self sendString:[NSString stringWithFormat:@"\033[<%lu;%lu;%lu%c",(unsigned long)code,(unsigned long)x,(unsigned long)y,release?'m':'M']];
    else if(_urxvtMouse)[self sendString:[NSString stringWithFormat:@"\033[%lu;%lu;%luM",(unsigned long)(32+code),(unsigned long)x,(unsigned long)y]];
    else if(_utf8Mouse){uint8_t header[]={27,'[','M'};NSMutableData *sequence=[NSMutableData dataWithBytes:header length:sizeof(header)];uint32_t values[]={(uint32_t)(32+code),(uint32_t)(32+x),(uint32_t)(32+y)};for(NSUInteger i=0;i<3;i++){uint32_t value=MIN(values[i],(uint32_t)0x7FF);uint8_t encoded[2];if(value<0x80){encoded[0]=(uint8_t)value;[sequence appendBytes:encoded length:1];}else{encoded[0]=(uint8_t)(0xC0|(value>>6));encoded[1]=(uint8_t)(0x80|(value&0x3F));[sequence appendBytes:encoded length:2];}}[self sendBytes:sequence.bytes length:sequence.length];}
    else{uint8_t sequence[]={27,'[','M',(uint8_t)MIN(255,32+code),(uint8_t)MIN(255,32+x),(uint8_t)MIN(255,32+y)};[self sendBytes:sequence length:sizeof(sequence)];}
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *menu=[NSMenu new];
    [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Split Horizontal" action:@selector(splitHorizontal:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Split Vertical" action:@selector(splitVertical:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Search Scrollback" action:@selector(searchScrollback:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Clear Terminal" action:@selector(clearTerminal:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Reload Config" action:@selector(reloadConfig:) keyEquivalent:@""];
    for(NSMenuItem *item in menu.itemArray)item.target=self;
    return menu;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if([sender.draggingPasteboard.types containsObject:NSPasteboardTypeFileURL])return NSDragOperationCopy;
    return NSDragOperationNone;
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {return [sender.draggingPasteboard.types containsObject:NSPasteboardTypeFileURL];}
- (BOOL)insertDroppedFileURLs:(NSArray<NSURL *> *)files {
    NSMutableArray<NSString *> *paths=[NSMutableArray array];
    for(NSURL *url in files)if(url.isFileURL&&url.path.length)[paths addObject:TShellQuotedPath(url.path)];
    if(!paths.count)return NO;
    NSString *text=[paths componentsJoinedByString:@" "];
    if(_bracketedPaste)[self sendString:[NSString stringWithFormat:@"\033[200~%@\033[201~",text]];else[self sendString:text];
    return YES;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *files=[sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    if(self.focused)self.focused();if(!self.tiledRendering)[self.window makeFirstResponder:self];
    return [self insertDroppedFileURLs:files];
}
- (void)mouseDown:(NSEvent *)event {
    if(self.focused)self.focused();
    if(!self.tiledRendering)[self.window makeFirstResponder:self];
    if([self shouldForwardApplicationMouseWithModifiers:event.modifierFlags]){[self sendMouseButton:0 event:event release:NO motion:NO];return;}
    NSPoint local=[self convertPoint:event.locationInWindow fromView:nil];
    NSPoint cell=[self cellForPoint:local];if(self.config.oscIntegration&&_historyOffset==0&&(event.modifierFlags&NSEventModifierFlagCommand)){NSString *link=_linksByCell[[self linkKeyForX:(NSUInteger)cell.x y:(NSUInteger)cell.y]];NSURL *url=link.length?[NSURL URLWithString:link]:nil;if(url){[NSWorkspace.sharedWorkspace openURL:url];return;}}
    BOOL commandDrag=(event.modifierFlags&NSEventModifierFlagCommand)!=0;
    BOOL paddingDrag=local.y<=MAX(10,self.config.padding+self.topContentInset);
    if(self.tiledRendering&&(commandDrag||paddingDrag)&&self.tileDragBegan){_tileDragging=YES;_selecting=NO;_hasSelection=NO;self.tileDragBegan(self,event);return;}
    if(![self pointIsInSelectableContent:local]){_selecting=NO;_hasSelection=NO;[self setNeedsDisplay:YES];return;}
    _selectionStart=_selectionEnd=[self cellForPoint:local];_selecting=YES;_hasSelection=NO;[self setNeedsDisplay:YES];
}
- (BOOL)shouldForwardApplicationMouseWithModifiers:(NSEventModifierFlags)modifiers {return _mouseTrackingMode&&(modifiers&NSEventModifierFlagOption)&&!(modifiers&NSEventModifierFlagShift);}
- (void)mouseDragged:(NSEvent *)event {if(_mouseTrackingMode>=1002&&[self shouldForwardApplicationMouseWithModifiers:event.modifierFlags]){[self sendMouseButton:0 event:event release:NO motion:YES];return;}if(_tileDragging){if(self.tileDragMoved)self.tileDragMoved(self,event);return;}if(!_selecting)return;_selectionEnd=[self cellForPoint:[self convertPoint:event.locationInWindow fromView:nil]];_hasSelection=YES;[self setNeedsDisplay:YES];}
- (void)mouseUp:(NSEvent *)event {if([self shouldForwardApplicationMouseWithModifiers:event.modifierFlags]){[self sendMouseButton:0 event:event release:YES motion:NO];return;}if(_tileDragging){_tileDragging=NO;if(self.tileDragEnded)self.tileDragEnded(self,event);return;}_selecting=NO;}
- (void)scrollByLines:(NSInteger)lines {
    @synchronized(self) {
    if(!lines)return;NSInteger previous=_historyOffset;_historyOffset=MAX(0,MIN((NSInteger)_historyCount,_historyOffset+lines));if(previous!=_historyOffset){_hasSelection=NO;[self markAllDamage];TLog(@"scrollback %ld/%lu",(long)_historyOffset,(unsigned long)_historyCount);[self setNeedsDisplay:YES];}
    }
}
- (void)jumpToPromptDirection:(NSInteger)direction {
    @synchronized(self){if(!_commandMarks.count)return;NSInteger current=(NSInteger)_historyCount-_historyOffset,target=NSNotFound;if(direction<0){for(NSDictionary *mark in _commandMarks){if(![mark[@"mark"] isEqual:@"A"])continue;NSInteger row=[mark[@"row"] integerValue];if(row<current&&(target==NSNotFound||row>target))target=row;}}else{for(NSDictionary *mark in _commandMarks){if(![mark[@"mark"] isEqual:@"A"])continue;NSInteger row=[mark[@"row"] integerValue];if(row>current&&(target==NSNotFound||row<target))target=row;}}if(target!=NSNotFound){_historyOffset=MAX(0,MIN((NSInteger)_historyCount,(NSInteger)_historyCount-target));_hasSelection=NO;[self markAllDamage];[self setNeedsDisplay:YES];}}
}
- (void)routeWheelLines:(NSInteger)lines event:(NSEvent *)event modifierFlags:(NSEventModifierFlags)modifiers {
    BOOL shift=(modifiers&NSEventModifierFlagShift)!=0;
    // Wheel reporting is independent from click reporting. Mouse-aware TUIs such as
    // Codex can remain on the primary screen and still require button 64/65 wheel
    // reports. Keep ordinary clicks native, but forward wheels whenever the child
    // explicitly enabled a mouse mode. Shift-wheel is the local-history escape hatch.
    if(_mouseTrackingMode&&!shift){
        NSUInteger button=lines>0?64:65,events=MIN((NSInteger)8,labs(lines));
        for(NSUInteger i=0;i<events;i++)[self sendMouseButton:button event:event release:NO motion:NO];
        return;
    }
    // Codex writes finalized chat rows into terminal scrollback while keeping its
    // composer in a lower inline viewport. Scroll that native history locally and
    // never synthesize Ctrl-T, which replaces the composer with a transcript pager.
    if(_inlineViewportMode&&!shift){
        [self scrollByLines:lines];return;
    }
    // Some full-screen CLIs, including Codex, use the alternate screen but do not
    // advertise DEC 1007 alternate-scroll. Keep wheel navigation working there.
    if(_alternateScreen&&!shift){NSString *sequence=lines>0?(_applicationCursorKeys?@"\033OA":@"\033[A"):(_applicationCursorKeys?@"\033OB":@"\033[B");for(NSInteger i=0;i<MIN((NSInteger)32,labs(lines));i++)[self sendString:sequence];return;}
    [self scrollByLines:lines];
}
- (void)scrollWheel:(NSEvent *)event {
    CGFloat raw=event.scrollingDeltaY;if(fabs(raw)<0.001)raw=event.deltaY;NSInteger lines=0;
    if(event.hasPreciseScrollingDeltas){if(event.phase&NSEventPhaseBegan)_scrollAccumulator=0;_scrollAccumulator+=raw/MAX(2.0,_cellHeight*0.22);lines=(NSInteger)trunc(_scrollAccumulator);_scrollAccumulator-=lines;if(!lines&&(event.phase&(NSEventPhaseEnded|NSEventPhaseCancelled))&&fabs(_scrollAccumulator)>=0.12){lines=_scrollAccumulator>0?1:-1;_scrollAccumulator=0;}}
    else{lines=(NSInteger)llround(raw*3.0);if(!lines&&raw!=0)lines=raw>0?1:-1;}
    lines=MAX(-24,MIN(24,lines));
    if(!lines)return;
    TLog(@"wheel delta %.2f -> %ld lines history %ld/%lu alt %d mouse %lu",raw,(long)lines,(long)_historyOffset,(unsigned long)_historyCount,_alternateScreen,(unsigned long)_mouseTrackingMode);
    [self routeWheelLines:lines event:event modifierFlags:event.modifierFlags];
}
- (NSString *)selectedText {
    @synchronized(self) {
    if(!_hasSelection)return @"";NSInteger a=(NSInteger)_selectionStart.y*(NSInteger)_cols+(NSInteger)_selectionStart.x,b=(NSInteger)_selectionEnd.y*(NSInteger)_cols+(NSInteger)_selectionEnd.x;if(a>b){NSInteger t=a;a=b;b=t;}NSMutableString *s=[NSMutableString string];NSInteger firstRow=a/(NSInteger)_cols,lastRow=b/(NSInteger)_cols;for(NSInteger y=firstRow;y<=lastRow;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:y temporary:&hold];NSInteger x0=y==firstRow?a%(NSInteger)_cols:0,x1=y==lastRow?b%(NSInteger)_cols:(NSInteger)_cols-1;NSMutableString *row=[NSMutableString string];for(NSInteger x=x0;x<=x1;x++)if(!line||!(line[x].flags&TContinuation))[row appendString:[self stringForCodepoint:line?line[x].ch:' ']];while([row hasSuffix:@" "])[row deleteCharactersInRange:NSMakeRange(row.length-1,1)];[s appendString:row];if(y<lastRow)[s appendString:@"\n"];}return s;
    }
}
- (NSString *)visibleText {@synchronized(self){NSMutableArray *lines=[NSMutableArray array];for(NSUInteger y=0;y<_rows;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:(NSInteger)y temporary:&hold];NSMutableString *row=[NSMutableString string];for(NSUInteger x=0;x<_cols;x++)if(!line||!(line[x].flags&TContinuation))[row appendString:[self stringForCodepoint:line?line[x].ch:' ']];while([row hasSuffix:@" "])[row deleteCharactersInRange:NSMakeRange(row.length-1,1)];[lines addObject:row];}while(lines.count&&[lines.lastObject length]==0)[lines removeLastObject];return [lines componentsJoinedByString:@"\n"];}}
- (void)copy:(id)sender {NSString *s=[self selectedText];if(s.length){[NSPasteboard.generalPasteboard clearContents];[NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];}}
- (void)paste:(id)sender {
    NSString *s=[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];if(!s.length)return;BOOL multiline=[s rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location!=NSNotFound,unsafe=multiline&&(!_bracketedPaste||[s hasSuffix:@"\n"]||[s hasSuffix:@"\r"]||[s rangeOfString:@"\033"].location!=NSNotFound);
    if(self.config.pasteProtection&&unsafe){NSAlert *alert=[NSAlert new];alert.messageText=@"Paste commands into the terminal?";alert.informativeText=[NSString stringWithFormat:@"This paste contains %lu characters and can execute more than one line.",(unsigned long)s.length];[alert addButtonWithTitle:@"Paste"];[alert addButtonWithTitle:@"Cancel"];alert.alertStyle=NSAlertStyleWarning;if([alert runModal]!=NSAlertFirstButtonReturn)return;}
    if(_bracketedPaste)[self sendString:[NSString stringWithFormat:@"\033[200~%@\033[201~",s]];else[self sendString:s];
}
- (void)selectAll:(id)sender {_selectionStart=NSMakePoint(0,0);_selectionEnd=NSMakePoint(_cols-1,_rows-1);_hasSelection=YES;[self setNeedsDisplay:YES];}
- (uint32_t)firstScalar:(NSString *)value {if(!value.length)return 0;NSData *data=[value dataUsingEncoding:NSUTF32LittleEndianStringEncoding];uint32_t scalar=0;if(data.length>=4)memcpy(&scalar,data.bytes,4);return scalar;}
- (uint32_t)kittyCodeForKey:(unsigned short)key {
    switch(key){case 53:return 27;case 36:case 76:return 13;case 48:return 9;case 51:return 127;case 114:return 57348;case 117:return 57349;case 123:return 57350;case 124:return 57351;case 126:return 57352;case 125:return 57353;case 116:return 57354;case 121:return 57355;case 115:return 57356;case 119:return 57357;case 122:return 57364;case 120:return 57365;case 99:return 57366;case 118:return 57367;case 96:return 57368;case 97:return 57369;case 98:return 57370;case 100:return 57371;case 101:return 57372;case 109:return 57373;case 103:return 57374;case 111:return 57375;default:return 0;}
}
- (NSString *)functionalKeySequenceForKeyCode:(unsigned short)key modifier:(NSInteger)modifier {
    unichar final=0;NSInteger number=0;
    switch(key){case 123:final='D';break;case 124:final='C';break;case 125:final='B';break;case 126:final='A';break;case 115:final='H';break;case 119:final='F';break;case 122:final='P';break;case 120:final='Q';break;case 99:final='R';break;case 118:final='S';break;case 114:number=2;break;case 117:number=3;break;case 116:number=5;break;case 121:number=6;break;case 96:number=15;break;case 97:number=17;break;case 98:number=18;break;case 100:number=19;break;case 101:number=20;break;case 109:number=21;break;case 103:number=23;break;case 111:number=24;break;default:return nil;}
    if(_kittyKeyboardFlags){if(final)return [NSString stringWithFormat:@"\033[1;%ld%C",(long)modifier,final];return [NSString stringWithFormat:@"\033[%ld;%ld~",(long)number,(long)modifier];}
    if(final){if(modifier>1)return [NSString stringWithFormat:@"\033[1;%ld%C",(long)modifier,final];if(_applicationCursorKeys&&(key==123||key==124||key==125||key==126||key==115||key==119||key==122||key==120||key==99||key==118))return [NSString stringWithFormat:@"\033O%C",final];return [NSString stringWithFormat:@"\033[%C",final];}
    return modifier>1?[NSString stringWithFormat:@"\033[%ld;%ld~",(long)number,(long)modifier]:[NSString stringWithFormat:@"\033[%ld~",(long)number];
}
- (void)startCursorBlink {
    if(_blinkTimer){dispatch_source_cancel(_blinkTimer);_blinkTimer=nil;}
    if(!_cursorBlink||_systemReduceMotion)return;
    _cursorBlinkVisible=YES;
    _blinkTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(_blinkTimer,dispatch_time(DISPATCH_TIME_NOW,530*NSEC_PER_MSEC),530*NSEC_PER_MSEC,50*NSEC_PER_MSEC);
    __weak typeof(self) weakSelf=self;
    dispatch_source_set_event_handler(_blinkTimer,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;self->_cursorBlinkVisible=!self->_cursorBlinkVisible;[self setNeedsDisplay:YES];});
    dispatch_resume(_blinkTimer);
}
- (void)keyDown:(NSEvent *)e {
    [self updateSecureKeyboardInput];
    if(_searchActive){if(e.keyCode==36||e.keyCode==76){[self navigateSearch:(e.modifierFlags&NSEventModifierFlagShift)?-1:1];return;}if(e.keyCode==53){[self closeSearch];return;}}
    if(e.modifierFlags&NSEventModifierFlagCommand){if((e.modifierFlags&NSEventModifierFlagShift)&&[e.charactersIgnoringModifiers.lowercaseString isEqual:@"f"]){[self searchScrollback];return;}if((e.modifierFlags&NSEventModifierFlagShift)&&[e.charactersIgnoringModifiers.lowercaseString isEqual:@"d"]){void(^cb)(void)=self.splitShortcut;if(cb)cb();return;}if([e.charactersIgnoringModifiers.lowercaseString isEqual:@"d"]){void(^cb)(void)=self.splitShortcut;if(cb)cb();return;}if([e.charactersIgnoringModifiers.lowercaseString isEqual:@"]"]){void(^cb)(void)=self.nextSplitShortcut;if(cb)cb();return;}if([e.charactersIgnoringModifiers.lowercaseString isEqual:@"["]){void(^cb)(void)=self.prevSplitShortcut;if(cb)cb();return;}[super keyDown:e];return;}
    NSString *s=nil; unsigned short k=e.keyCode;NSEventModifierFlags mods=e.modifierFlags&NSEventModifierFlagDeviceIndependentFlagsMask;NSInteger modifier=1+((mods&NSEventModifierFlagShift)?1:0)+((mods&NSEventModifierFlagOption)?2:0)+((mods&NSEventModifierFlagControl)?4:0);
    if((mods&NSEventModifierFlagShift)&&!(mods&(NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl))){if(k==116){[self scrollByLines:MAX(1,(NSInteger)_rows-1)];return;}if(k==121){[self scrollByLines:-MAX(1,(NSInteger)_rows-1)];return;}if(k==115){[self scrollByLines:(NSInteger)_historyCount];return;}if(k==119){[self scrollByLines:-(NSInteger)_historyCount];return;}}
    if(_historyOffset){_historyOffset=0;[self setNeedsDisplay:YES];}
    if(_kittyKeyboardFlags&8){uint32_t code=[self kittyCodeForKey:k];if(!code)code=[self firstScalar:e.charactersIgnoringModifiers];if(code){[self sendString:[NSString stringWithFormat:@"\033[%u;%ldu",code,(long)modifier]];_hasSelection=NO;[self setNeedsDisplay:YES];return;}}
    if((_kittyKeyboardFlags&1)&&(k==53||(mods&(NSEventModifierFlagOption|NSEventModifierFlagControl)))){uint32_t code=[self kittyCodeForKey:k];if(!code)code=[self firstScalar:e.charactersIgnoringModifiers];if(code){[self sendString:[NSString stringWithFormat:@"\033[%u;%ldu",code,(long)modifier]];_hasSelection=NO;[self setNeedsDisplay:YES];return;}}
    if(_modifyOtherKeys>=2&&modifier>1){uint32_t code=[self firstScalar:e.charactersIgnoringModifiers];if(code&&code>=32){[self sendString:[NSString stringWithFormat:@"\033[27;%ld;%u~",(long)modifier,code]];_hasSelection=NO;[self setNeedsDisplay:YES];return;}}
    if(mods==NSEventModifierFlagOption){if(k==123)s=@"\033b";else if(k==124)s=@"\033f";else if(k==51)s=@"\033\x7f";}
    NSString *functional=s?nil:[self functionalKeySequenceForKeyCode:k modifier:modifier];if(functional){[self sendString:functional];_hasSelection=NO;[self setNeedsDisplay:YES];return;}
    if(!s&&(k==36||k==76))s=@"\r";else if(!s&&k==51)s=@"\x7f";else if(!s&&k==53)s=@"\x1b";else if(!s&&k==48)s=(mods&NSEventModifierFlagShift)?@"\x1b[Z":@"\t";
    else if(!s&&(mods&NSEventModifierFlagControl)){NSString *c=e.charactersIgnoringModifiers.lowercaseString;if(c.length){unichar ch=[c characterAtIndex:0];uint8_t b=0;if(ch>='a'&&ch<='z')b=(uint8_t)(ch-'a'+1);else if(ch==' '||ch=='@')b=0;else if(ch=='[')b=27;else if(ch=='\\')b=28;else if(ch==']')b=29;else if(ch=='^')b=30;else if(ch=='_')b=31;else if(ch=='?')b=127;else b=255;if(b!=255){[self sendBytes:&b length:1];return;}}}
    else if(!s&&!(mods&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption))){[self interpretKeyEvents:@[e]];return;}
    else if(!s){s=(mods&NSEventModifierFlagOption)?e.charactersIgnoringModifiers:e.characters;if((mods&NSEventModifierFlagOption)&&s.length)s=[@"\x1b" stringByAppendingString:s];}
    if(s.length)[self sendString:s];_hasSelection=NO;[self setNeedsDisplay:YES];
}
- (NSString *)workingDirectory {
    if (_pid > 0) {
        struct proc_vnodepathinfo info;
        int size = proc_pidinfo(_pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
        if (size == sizeof(info) && info.pvi_cdir.vip_path[0])
            return [NSString stringWithUTF8String:info.pvi_cdir.vip_path];
    }
    return self.launchDirectory.length?self.launchDirectory:NSFileManager.defaultManager.currentDirectoryPath;
}
- (NSDictionary *)diagnosticState {@synchronized(self){return @{@"history":@(_historyCount),@"offset":@(_historyOffset),@"cursorX":@(_cursorX),@"cursorY":@(_cursorY),@"alternate":@(_alternateScreen),@"inlineViewport":@(_inlineViewportMode),@"inlineViewportTop":@(_inlineViewportTop),@"synchronizedUpdates":@(_synchronizedUpdates),@"selecting":@(_selecting),@"selection":@(_hasSelection),@"rows":@(_rows),@"columns":@(_cols),@"mouseMode":@(_mouseTrackingMode),@"mouseEncoding":_pixelMouse?@"pixel-sgr":(_sgrMouse?@"sgr":(_urxvtMouse?@"urxvt":(_utf8Mouse?@"utf8":@"legacy"))),@"renderer":_renderBackend.name?:@"none",@"renderGeneration":@(_renderBackend.lastPresentedGeneration),@"metalFailed":@(_metalFailed),@"metalFrameChecksum":@(_metalBackend.lastFrameChecksum),@"metalFrameVaried":@(_metalBackend.lastFrameVariedPixels),@"snapshotBuildMs":@(_lastSnapshotBuildMilliseconds),@"metalSnapshotWaitMs":@(_metalBackend.lastSnapshotWaitMilliseconds),@"metalCPUEncodeMs":@(_metalBackend.lastCPUEncodeMilliseconds),@"metalGPUExecutionMs":@(_metalBackend.lastGPUExecutionMilliseconds),@"metalGPUCompletionMs":@(_metalBackend.lastGPUCompletionMilliseconds),@"metalPresentIntervalMs":@(_metalBackend.lastPresentIntervalMilliseconds)};}}
- (void)renderImage:(CGImageRef)image atRow:(NSUInteger)row col:(NSUInteger)col width:(NSUInteger)w height:(NSUInteger)h scale:(BOOL)doScale {
    if(!image)return;
    CGImageRef stored=CGImageRetain(image);NSUInteger srcW=CGImageGetWidth(stored),srcH=CGImageGetHeight(stored);
    if(doScale){NSUInteger maxW=_cols*_cellWidth,maxH=_rows*_cellHeight;if(srcW>maxW||srcH>maxH){CGFloat sc=MIN((CGFloat)maxW/srcW,(CGFloat)maxH/srcH);srcW=MAX(1,(NSUInteger)(srcW*sc));srcH=MAX(1,(NSUInteger)(srcH*sc));CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef ctx=cs?CGBitmapContextCreate(NULL,srcW,srcH,8,srcW*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast):NULL;if(ctx){CGContextSetRGBFillColor(ctx,0,0,0,0);CGContextFillRect(ctx,CGRectMake(0,0,srcW,srcH));CGContextDrawImage(ctx,CGRectMake(0,0,srcW,srcH),stored);CGImageRef scaled=CGBitmapContextCreateImage(ctx);if(scaled){CGImageRelease(stored);stored=scaled;}CGContextRelease(ctx);}if(cs)CGColorSpaceRelease(cs);}}
    NSNumber *key=@((row<<16)|col);_inlineImages[key]=CFBridgingRelease(stored);
    NSUInteger cellsW=MAX(1,(srcW+_cellWidth-1)/_cellWidth),cellsH=MAX(1,(srcH+_cellHeight-1)/_cellHeight);
    [self markDamageX:col y:row width:cellsW height:cellsH];[self refreshTextView];
}
- (void)deleteImageWithID:(NSString *)imageID {if(imageID){NSNumber *posKey=_kittyImageIDs[imageID];if(posKey)[_inlineImages removeObjectForKey:posKey];[_kittyImageIDs removeObjectForKey:imageID];[_kittyStoredImages removeObjectForKey:imageID];[_kittyPendingImages removeObjectForKey:imageID];[_animatedImages removeObjectForKey:imageID];[self setNeedsDisplay:YES];}else{[_inlineImages removeAllObjects];[_kittyImageIDs removeAllObjects];[_kittyStoredImages removeAllObjects];[_kittyPendingImages removeAllObjects];[_animatedImages removeAllObjects];[self setNeedsDisplay:YES];}}
- (void)waitForImageOperations {if(_imageQueue)dispatch_sync(_imageQueue,^{});if(_parseQueue)dispatch_sync(_parseQueue,^{});}
- (void)queryImageWithID:(NSString *)imageID {[self sendString:[NSString stringWithFormat:@"\033_Gi=%@,s=%lu,v=%lu,C=1;\033\\",imageID?:@"",(unsigned long)(_cols*_cellWidth),(unsigned long)(_rows*_cellHeight)]];}
- (void)parseSixel:(NSString *)data {
    NSUInteger cursorRow=_cursorY,cursorCol=_cursorX;NSUInteger maxWidth=_cols*_cellWidth,maxHeight=_rows*_cellHeight;if(maxWidth>4096)maxWidth=4096;if(maxHeight>4096)maxHeight=4096;
    uint32_t colors[1024]={0};colors[0]=0x000000;colors[1]=0xFFFFFF;int currentColor=0;NSUInteger sixelWidth=0,sixelHeight=0,x=0,band=0;
    NSUInteger pixelBufSize=maxWidth*maxHeight;uint8_t *pixels=calloc(pixelBufSize,4);if(!pixels)return;memset(pixels,0,pixelBufSize*4);
    for(NSUInteger i=1;i<data.length;i++){unichar ch=[data characterAtIndex:i];
        if(ch=='!'){NSUInteger rc=0;i++;while(i<data.length&&[data characterAtIndex:i]>='0'&&[data characterAtIndex:i]<='9'){rc=rc*10+[data characterAtIndex:i]-'0';i++;}if(!rc)rc=1;if(i+1<data.length){unichar sc=[data characterAtIndex:i+1];if(sc>=0x3f&&sc<=0x7e){int bits=sc-0x3f;for(NSUInteger r=0;r<rc;r++){for(int b=0;b<6;b++){if(bits&(1<<b)){NSUInteger px=x,py=band*6+b;if(px<maxWidth&&py<maxHeight){uint8_t *p=pixels+(py*maxWidth+px)*4;p[0]=(colors[currentColor]>>16)&0xFF;p[1]=(colors[currentColor]>>8)&0xFF;p[2]=colors[currentColor]&0xFF;p[3]=0xFF;}}x++;}}i++;}}continue;}
        if(ch=='#'){int reg=0;i++;BOOL isDef=NO;while(i<data.length&&[data characterAtIndex:i]>='0'&&[data characterAtIndex:i]<='9'){reg=reg*10+[data characterAtIndex:i]-'0';i++;}if(i<data.length&&[data characterAtIndex:i]==';'){isDef=YES;i++;}if(isDef&&i<data.length){int colorType=2;i++;if(i<data.length&&([data characterAtIndex:i]=='1'||[data characterAtIndex:i]=='2'||[data characterAtIndex:i]=='3')){colorType=[data characterAtIndex:i]-'0';i++;}while(i<data.length&&[data characterAtIndex:i]==';')i++;int v1=0,v2=0,v3=0;while(i<data.length&&[data characterAtIndex:i]>='0'&&[data characterAtIndex:i]<='9'){v1=v1*10+[data characterAtIndex:i]-'0';i++;}if(i<data.length&&[data characterAtIndex:i]==';'){i++;while(i<data.length&&[data characterAtIndex:i]>='0'&&[data characterAtIndex:i]<='9'){v2=v2*10+[data characterAtIndex:i]-'0';i++;}}if(i<data.length&&[data characterAtIndex:i]==';'){i++;while(i<data.length&&[data characterAtIndex:i]>='0'&&[data characterAtIndex:i]<='9'){v3=v3*10+[data characterAtIndex:i]-'0';i++;}}uint32_t r,g,b;if(colorType==1){double hh=v1/360.0,s=v2/100.0,l=v3/100.0;double c=(1-fabs(2*l-1))*s;double x2=c*(1-fabs(fmod(hh*6.0,2.0)-1.0));double m=l-c/2;double r1,g1,b1;if(hh<1.0/6.0){r1=c;g1=x2;b1=0;}else if(hh<2.0/6.0){r1=x2;g1=c;b1=0;}else if(hh<3.0/6.0){r1=0;g1=c;b1=x2;}else if(hh<4.0/6.0){r1=0;g1=x2;b1=c;}else if(hh<5.0/6.0){r1=x2;g1=0;b1=c;}else{r1=c;g1=0;b1=x2;}r=(uint32_t)((r1+m)*255);g=(uint32_t)((g1+m)*255);b=(uint32_t)((b1+m)*255);}else{r=(uint32_t)(v1*255/100);g=(uint32_t)(v2*255/100);b=(uint32_t)(v3*255/100);}if(reg<1024){colors[reg]=((r&0xFF)<<16)|((g&0xFF)<<8)|(b&0xFF);}currentColor=reg;}else{if(reg<1024){currentColor=reg;}}i--;continue;}
        if(ch=='"'){i++;while(i<data.length&&[data characterAtIndex:i]!='$'&&[data characterAtIndex:i]!='-'&&[data characterAtIndex:i]>=32)i++;i--;continue;}
        if(ch=='$'){x=0;continue;}
        if(ch=='-'){x=0;band++;continue;}
        if(ch>=0x3f&&ch<=0x7e){int bits=ch-0x3f;for(int b=0;b<6;b++){if(bits&(1<<b)){NSUInteger px=x,py=band*6+b;if(px<maxWidth&&py<maxHeight){uint8_t *p=pixels+(py*maxWidth+px)*4;p[0]=(colors[currentColor]>>16)&0xFF;p[1]=(colors[currentColor]>>8)&0xFF;p[2]=colors[currentColor]&0xFF;p[3]=0xFF;}}}x++;if(x>sixelWidth)sixelWidth=x;if(band*6+6>sixelHeight)sixelHeight=band*6+6;continue;}
    }
    if(sixelWidth&&sixelHeight){NSUInteger imgW=MIN(sixelWidth,maxWidth),imgH=MIN(sixelHeight,maxHeight);CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef ctx=CGBitmapContextCreate(pixels,maxWidth,maxHeight,8,maxWidth*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGImageRef image=ctx?CGBitmapContextCreateImage(ctx):NULL;if(ctx)CGContextRelease(ctx);if(cs)CGColorSpaceRelease(cs);if(image){CGImageRef subImage=CGImageCreateWithImageInRect(image,CGRectMake(0,0,imgW,imgH));if(subImage){CGImageRelease(image);image=subImage;}[self renderImage:image atRow:cursorRow col:cursorCol width:0 height:0 scale:YES];CGImageRelease(image);}_cursorY=MIN(_rows-1,cursorRow+(imgH+_cellHeight-1)/_cellHeight);_cursorX=0;}
    free(pixels);
}
- (void)consumeKittyGraphicBytes:(const uint8_t *)bytes length:(NSUInteger)length {
    if(length<2)return;
    if(!_imageQueue)_imageQueue=dispatch_queue_create("com.termatica.image",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));if(!_inlineImages)_inlineImages=[NSMutableDictionary dictionary];if(!_kittyImageIDs)_kittyImageIDs=[NSMutableDictionary dictionary];if(!_kittyStoredImages)_kittyStoredImages=[NSMutableDictionary dictionary];if(!_kittyPendingImages)_kittyPendingImages=[NSMutableDictionary dictionary];if(!_kittyEncodedGraphic)_kittyEncodedGraphic=[NSMutableData data];if(!_animatedImages)_animatedImages=[NSMutableDictionary dictionary];
    NSUInteger separator=NSNotFound;
    for(NSUInteger i=1;i<length;i++)if(bytes[i]==';'||bytes[i]==':'){separator=i;break;}
    if(separator==NSNotFound)return;
    const uint8_t *rawValue=NULL;NSUInteger rawLength=0;uint8_t action='t';BOOL more=NO;
    TKittyByteControls(bytes,separator,&action,&more);
    if(action=='q'||action=='d'){
        NSString *imageID=nil;if(TKittyByteParameter(bytes,separator,'i',&rawValue,&rawLength)&&rawLength)imageID=[[NSString alloc]initWithBytes:rawValue length:rawLength encoding:NSASCIIStringEncoding];
        if(action=='q'){[self queryImageWithID:imageID];return;}
        [self deleteImageWithID:imageID];return;
    }
    if(!_kittyGraphicHeader.length){_kittyGraphicHeader=[[NSString alloc]initWithBytes:bytes+1 length:separator-1 encoding:NSASCIIStringEncoding]?:@"";NSUInteger format=TKittyByteInteger(bytes,separator,'f'),width=TKittyByteInteger(bytes,separator,'s'),height=TKittyByteInteger(bytes,separator,'v');if(!format)format=32;_kittyEncodedAllZero=format==32;_kittyEncodedZeroPrefixLength=0;if(format==32&&width&&height&&width<=8192&&height<=8192){NSUInteger rawBytes=width*height*4,encodedCapacity=((rawBytes+2)/3)*4;if(encodedCapacity<=100663296)_kittyEncodedGraphic=[NSMutableData dataWithCapacity:encodedCapacity];}}
    NSUInteger payloadStart=separator+1;if(payloadStart<length){NSUInteger payloadLength=length-payloadStart,totalLength=_kittyEncodedGraphic.length+_kittyEncodedZeroPrefixLength;if(totalLength>100663296-payloadLength){[_kittyEncodedGraphic setLength:0];_kittyGraphicHeader=nil;_kittyEncodedAllZero=NO;_kittyEncodedZeroPrefixLength=0;return;}if(_kittyEncodedAllZero&&TKittyBase64IsZero(bytes+payloadStart,payloadLength))_kittyEncodedZeroPrefixLength+=payloadLength;else{if(_kittyEncodedAllZero){_kittyEncodedAllZero=NO;if(_kittyEncodedZeroPrefixLength){[_kittyEncodedGraphic setLength:_kittyEncodedZeroPrefixLength];memset(_kittyEncodedGraphic.mutableBytes,'A',_kittyEncodedZeroPrefixLength);_kittyEncodedZeroPrefixLength=0;}}[_kittyEncodedGraphic appendBytes:bytes+payloadStart length:payloadLength];}}
    if(more)return;
    NSData *encoded=_kittyEncodedGraphic;_kittyEncodedGraphic=[NSMutableData data];NSString *firstHeader=_kittyGraphicHeader?:@"";_kittyGraphicHeader=nil;BOOL allZero=_kittyEncodedAllZero;_kittyEncodedAllZero=NO;_kittyEncodedZeroPrefixLength=0;
    NSMutableDictionary *firstParams=[NSMutableDictionary dictionary];
    for(NSString *pair in [firstHeader componentsSeparatedByString:@","]){NSRange eq=[pair rangeOfString:@"="];if(eq.location!=NSNotFound)firstParams[[pair substringToIndex:eq.location]]=[pair substringFromIndex:eq.location+1];}
    NSString *requestedAction=firstParams[@"a"]?:@"t",*requestedID=firstParams[@"i"];
    if([requestedAction isEqual:@"p"]&&!encoded.length&&requestedID.length){NSDictionary *pending=_kittyPendingImages[requestedID];NSData *pendingData=pending[@"encoded"];NSDictionary *pendingParams=pending[@"params"];if(pendingData.length||[pending[@"transparent"] boolValue]){encoded=pendingData?:NSData.data;allZero=[pending[@"transparent"] boolValue];NSMutableDictionary *merged=[pendingParams mutableCopy]?:[NSMutableDictionary dictionary];[merged addEntriesFromDictionary:firstParams];firstParams=merged;}}
    if([requestedAction isEqual:@"t"]){if(requestedID.length)_kittyPendingImages[requestedID]=@{@"encoded":encoded?:NSData.data,@"params":[firstParams copy],@"transparent":@(allZero)};return;}
    __weak typeof(self) weakSelf=self;dispatch_queue_t parseQueue=_parseQueue;NSUInteger maximumWidth=_cols*_cellWidth,maximumHeight=_rows*_cellHeight;
    if(allZero){
        NSString *finalAction=firstParams[@"a"]?:@"t",*finalID=firstParams[@"i"];NSUInteger row=(NSUInteger)[firstParams[@"r"] integerValue],col=(NSUInteger)[firstParams[@"c"] integerValue],width=(NSUInteger)[firstParams[@"s"] integerValue],height=(NSUInteger)[firstParams[@"v"] integerValue];if(!width||!height||width>8192||height>8192)return;
        if(maximumWidth&&maximumHeight&&(width>maximumWidth||height>maximumHeight)){CGFloat scale=MIN((CGFloat)maximumWidth/width,(CGFloat)maximumHeight/height);width=MAX(1,(NSUInteger)(width*scale));height=MAX(1,(NSUInteger)(height*scale));}
        dispatch_async(_imageQueue,^{__strong typeof(weakSelf) imageSelf=weakSelf;if(!imageSelf)return;NSString *sizeKey=[NSString stringWithFormat:@"%lux%lu",(unsigned long)width,(unsigned long)height];id retainedImage=imageSelf->_transparentKittyImages[sizeKey];if(!retainedImage){CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGContextRef context=space?CGBitmapContextCreate(NULL,width,height,8,width*4,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast):NULL;if(space)CGColorSpaceRelease(space);if(!context)return;CGContextClearRect(context,CGRectMake(0,0,width,height));CGImageRef image=CGBitmapContextCreateImage(context);CGContextRelease(context);if(!image)return;retainedImage=CFBridgingRelease(image);if(imageSelf->_transparentKittyImages.count>=16)[imageSelf->_transparentKittyImages removeAllObjects];imageSelf->_transparentKittyImages[sizeKey]=retainedImage;}dispatch_async(parseQueue,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;CGImageRef decoded=(__bridge CGImageRef)retainedImage;if(finalID.length)self->_kittyStoredImages[finalID]=retainedImage;if([finalAction isEqual:@"T"]||[finalAction isEqual:@"p"]){NSUInteger targetRow=row?:self->_cursorY,targetCol=col?:self->_cursorX;[self renderImage:decoded atRow:targetRow col:targetCol width:0 height:0 scale:NO];if(finalID.length)self->_kittyImageIDs[finalID]=@((targetRow<<16)|targetCol);}});});return;
    }
    dispatch_async(_imageQueue,^{
        __strong typeof(weakSelf) imageSelf=weakSelf;if(!imageSelf)return;
        NSUInteger format=(NSUInteger)[firstParams[@"f"] integerValue],width=(NSUInteger)[firstParams[@"s"] integerValue],height=(NSUInteger)[firstParams[@"v"] integerValue];if(!format)format=32;
        CGImageRef image=NULL;
        BOOL transparent=format==32&&width&&height&&width<=8192&&height<=8192&&TKittyBase64IsZero(encoded.bytes,encoded.length);
        if(transparent){
            if(maximumWidth&&maximumHeight&&(width>maximumWidth||height>maximumHeight)){CGFloat scale=MIN((CGFloat)maximumWidth/width,(CGFloat)maximumHeight/height);width=MAX(1,(NSUInteger)(width*scale));height=MAX(1,(NSUInteger)(height*scale));}
            NSString *sizeKey=[NSString stringWithFormat:@"%lux%lu",(unsigned long)width,(unsigned long)height];id cached=imageSelf->_transparentKittyImages[sizeKey];if(cached)image=CGImageRetain((__bridge CGImageRef)cached);else{CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGContextRef context=space?CGBitmapContextCreate(NULL,width,height,8,width*4,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast):NULL;if(space)CGColorSpaceRelease(space);if(context){CGContextClearRect(context,CGRectMake(0,0,width,height));image=CGBitmapContextCreateImage(context);CGContextRelease(context);if(image){if(imageSelf->_transparentKittyImages.count>=16)[imageSelf->_transparentKittyImages removeAllObjects];imageSelf->_transparentKittyImages[sizeKey]=CFBridgingRelease(CGImageRetain(image));}}}
        }else{
            NSData *raw=[[NSData alloc]initWithBase64EncodedData:encoded options:0];if(!raw.length)return;
            if(format==32&&width&&height&&width<=8192&&height<=8192&&raw.length/4>=width*height){CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)raw);CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();if(provider&&space)image=CGImageCreate(width,height,8,32,width*4,space,(CGBitmapInfo)(kCGBitmapByteOrderDefault|kCGImageAlphaPremultipliedLast),provider,NULL,false,kCGRenderingIntentDefault);if(space)CGColorSpaceRelease(space);if(provider)CGDataProviderRelease(provider);}else{CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)raw,NULL);if(source){image=CGImageSourceCreateImageAtIndex(source,0,NULL);CFRelease(source);}}
        }
        if(!image)return;
        NSUInteger imageWidth=CGImageGetWidth(image),imageHeight=CGImageGetHeight(image);if(!transparent&&maximumWidth&&maximumHeight&&(imageWidth>maximumWidth||imageHeight>maximumHeight)){CGFloat scale=MIN((CGFloat)maximumWidth/imageWidth,(CGFloat)maximumHeight/imageHeight);NSUInteger scaledWidth=MAX(1,(NSUInteger)(imageWidth*scale)),scaledHeight=MAX(1,(NSUInteger)(imageHeight*scale));CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();CGContextRef context=colorSpace?CGBitmapContextCreate(NULL,scaledWidth,scaledHeight,8,scaledWidth*4,colorSpace,(CGBitmapInfo)kCGImageAlphaPremultipliedLast):NULL;if(context){CGContextDrawImage(context,CGRectMake(0,0,scaledWidth,scaledHeight),image);CGImageRef scaled=CGBitmapContextCreateImage(context);if(scaled){CGImageRelease(image);image=scaled;}CGContextRelease(context);}if(colorSpace)CGColorSpaceRelease(colorSpace);}
        id retainedImage=CFBridgingRelease(image);NSString *finalAction=firstParams[@"a"]?:@"t",*finalID=firstParams[@"i"];NSUInteger row=(NSUInteger)[firstParams[@"r"] integerValue],col=(NSUInteger)[firstParams[@"c"] integerValue];
        dispatch_async(parseQueue,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;CGImageRef decoded=(__bridge CGImageRef)retainedImage;if(finalID.length)self->_kittyStoredImages[finalID]=retainedImage;if([finalAction isEqual:@"T"]||[finalAction isEqual:@"p"]){NSUInteger targetRow=row?:self->_cursorY,targetCol=col?:self->_cursorX;[self renderImage:decoded atRow:targetRow col:targetCol width:0 height:0 scale:NO];if(finalID.length)self->_kittyImageIDs[finalID]=@((targetRow<<16)|targetCol);}});
    });
}
- (void)startAnimationTimer {if(_animationTimer)return;uint64_t delay=100;for(NSString *imageID in _animatedImages){NSDictionary *anim=_animatedImages[imageID];NSArray *delays=anim[@"delays"];if(delays.count){NSUInteger cur=[anim[@"current"] unsignedIntegerValue];if(cur<delays.count){uint64_t d=[delays[cur] unsignedIntegerValue];delay=MIN(delay,d);}}}delay=MAX(UINT64_C(1),delay);dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());if(!timer)return;dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,delay*NSEC_PER_MSEC),delay*NSEC_PER_MSEC,10*NSEC_PER_MSEC);__weak typeof(self) weakSelf=self;dispatch_source_set_event_handler(timer,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;[self advanceAnimation];dispatch_source_t active=self->_animationTimer;if(active&&active==timer){dispatch_source_cancel(active);self->_animationTimer=nil;[self startAnimationTimer];}});dispatch_resume(timer);_animationTimer=timer;}
- (void)advanceAnimation {if(!_animatedImages.count){if(_animationTimer){dispatch_source_cancel(_animationTimer);_animationTimer=nil;}return;}for(NSString *imageID in _animatedImages.allKeys){NSMutableDictionary *anim=[_animatedImages[imageID] mutableCopy];NSUInteger count=[anim[@"count"] unsignedIntegerValue],current=[anim[@"current"] unsignedIntegerValue];current=(current+1)%count;anim[@"current"]=@(current);_animatedImages[imageID]=anim;NSNumber *posKey=_kittyImageIDs[imageID];if(!posKey)continue;NSDictionary *frames=anim[@"frames"];id frameObject=frames[@(current)];CGImageRef frame=(__bridge CGImageRef)frameObject;if(!frame)continue;_inlineImages[posKey]=frameObject;NSUInteger v=posKey.unsignedIntegerValue,row=v>>16,col=v&0xFFFF;NSUInteger cellsW=MAX(1,(CGImageGetWidth(frame)+_cellWidth-1)/_cellWidth),cellsH=MAX(1,(CGImageGetHeight(frame)+_cellHeight-1)/_cellHeight);[self markDamageX:col y:row width:cellsW height:cellsH];}[self refreshTextView];}
- (void)parseIterm2Image:(NSString *)osc {
    NSUInteger cursorRow=_cursorY,cursorCol=_cursorX;NSString *body=[osc substringFromIndex:@"1337;File=".length];NSUInteger colonLoc=[body rangeOfString:@":"].location;
    NSString *params=colonLoc==NSNotFound?body:[body substringToIndex:colonLoc];NSString *base64=colonLoc==NSNotFound?@"":[body substringFromIndex:colonLoc+1];
    NSUInteger destWidth=0,destHeight=0;BOOL preserveAspect=YES,inlineMode=YES;
    for(NSString *pair in [params componentsSeparatedByString:@";"]){NSRange eq=[pair rangeOfString:@"="];if(eq.location==NSNotFound)continue;NSString *key=[pair substringToIndex:eq.location],*value=[pair substringFromIndex:eq.location+1];if([key isEqual:@"width"])destWidth=[value integerValue];else if([key isEqual:@"height"])destHeight=[value integerValue];else if([key isEqual:@"preserveAspectRatio"])preserveAspect=[value boolValue];else if([key isEqual:@"inline"])inlineMode=[value boolValue];}
    if(!base64.length)return;NSData *rawData=[[NSData alloc]initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];if(!rawData.length)return;
    CGImageSourceRef src=CGImageSourceCreateWithData((__bridge CFDataRef)rawData,NULL);if(!src)return;CGImageRef image=CGImageSourceCreateImageAtIndex(src,0,NULL);CFRelease(src);if(!image)return;
    NSUInteger imgW=CGImageGetWidth(image),imgH=CGImageGetHeight(image);
    if(destWidth>0||destHeight>0){if(destWidth==0)destWidth=imgW;if(destHeight==0)destHeight=imgH;if(preserveAspect){CGFloat sc=MIN((CGFloat)destWidth/imgW,(CGFloat)destHeight/imgH);destWidth=MAX(1,(NSUInteger)(imgW*sc));destHeight=MAX(1,(NSUInteger)(imgH*sc));}CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef ctx=cs?CGBitmapContextCreate(NULL,destWidth,destHeight,8,destWidth*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast):NULL;if(ctx){CGContextSetRGBFillColor(ctx,0,0,0,0);CGContextFillRect(ctx,CGRectMake(0,0,destWidth,destHeight));CGContextDrawImage(ctx,CGRectMake(0,0,destWidth,destHeight),image);CGImageRef scaled=CGBitmapContextCreateImage(ctx);if(scaled){CGImageRelease(image);image=scaled;}CGContextRelease(ctx);}if(cs)CGColorSpaceRelease(cs);}
    NSUInteger renderedHeight=CGImageGetHeight(image);[self renderImage:image atRow:cursorRow col:cursorCol width:0 height:0 scale:YES];CGImageRelease(image);
    if(inlineMode){NSUInteger cellsH=(renderedHeight+_cellHeight-1)/_cellHeight;_cursorY=MIN(_rows-1,cursorRow+cellsH);_cursorX=0;}
}
- (void)searchScrollback {
    dispatch_async(dispatch_get_main_queue(),^{
        if(self->_searchActive){[self closeSearch];return;}
        self->_searchActive=YES;
        CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
        CGFloat barH=self.config->searchOverlayHeight,barW=MIN(self.config->searchOverlayWidth,MAX(180,w-self.config.padding*2));
        CGFloat barX=w-barW-self.config.padding-self.leadingOverlayInset-4;
        CGFloat barY=h-barH-self.config.padding-self.safeAreaInsets.bottom-4;
        NSView *overlay=[[NSView alloc]initWithFrame:NSMakeRect(barX,barY,barW,barH)];
        overlay.wantsLayer=YES;overlay.layer.cornerRadius=self.config->searchOverlayCornerRadius;overlay.layer.masksToBounds=YES;
        overlay.layer.backgroundColor=[self.config.panel colorWithAlphaComponent:0.96].CGColor;
        overlay.layer.borderColor=[self.config.accent colorWithAlphaComponent:0.5].CGColor;
        overlay.layer.borderWidth=1;
        CGFloat controlHeight=MIN(22,barH-8),counterWidth=MIN(100,barW*0.28),caseWidth=30,fieldWidth=MAX(70,barW-8-4-caseWidth-counterWidth-8);
        self->_searchField=[[NSTextField alloc]initWithFrame:NSMakeRect(8,(barH-controlHeight)/2,fieldWidth,controlHeight)];
        self->_searchField.placeholderString=@"Search scrollback";
        self->_searchField.target=self;self->_searchField.action=@selector(executeSearch:);
        self->_searchField.bezelStyle=NSTextFieldRoundedBezel;
        self->_searchField.textColor=self.config.foreground;
        self->_searchField.font=[NSFont fontWithName:self.config.fontName size:self.config.fontSize]?:[NSFont monospacedSystemFontOfSize:self.config.fontSize weight:NSFontWeightRegular];
        self->_searchField.backgroundColor=self.config.panel;
        NSButton *caseBtn=[NSButton checkboxWithTitle:@"Aa" target:self action:@selector(toggleSearchCase:)];
        caseBtn.frame=NSMakeRect(8+fieldWidth+4,(barH-controlHeight)/2,caseWidth,controlHeight);caseBtn.contentTintColor=self.config.accent;
        self->_searchCounter=[[NSTextField alloc]initWithFrame:NSMakeRect(barW-counterWidth-8,(barH-controlHeight)/2,counterWidth,controlHeight)];
        self->_searchCounter.editable=NO;self->_searchCounter.bezeled=NO;self->_searchCounter.stringValue=@"";
        self->_searchCounter.alignment=NSTextAlignmentRight;
        self->_searchCounter.textColor=self.config.muted?:self.config.foreground;
        self->_searchCounter.font=[NSFont fontWithName:self.config.fontName size:11]?:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        [overlay addSubview:self->_searchField];[overlay addSubview:caseBtn];[overlay addSubview:self->_searchCounter];
        [overlay setValue:@(0x5345) forKey:@"tag"];
        [self addSubview:overlay];
        CABasicAnimation *slide=[CABasicAnimation animationWithKeyPath:@"opacity"];slide.fromValue=@0;slide.toValue=@1;slide.duration=self.config->layoutAnimationDuration/MAX(0.25,self.config.animationSpeed);[overlay.layer addAnimation:slide forKey:@"fade"];
        [self.window makeFirstResponder:self->_searchField];
    });
}
- (void)closeSearch {
    _searchActive=NO;_searchString=nil;_searchCaseSensitive=NO;[_searchResults removeAllObjects];
    [_searchField removeFromSuperview];_searchField=nil;
    [_searchCounter removeFromSuperview];_searchCounter=nil;
    for(NSView *v in self.subviews)if([v respondsToSelector:@selector(valueForKey:)]&&[[v valueForKey:@"tag"] unsignedIntegerValue]==0x5345){[v removeFromSuperview];break;}
    _historyOffset=0;[self setNeedsDisplay:YES];
}
- (void)executeSearch:(id)sender {
    NSString *query=_searchField.stringValue;
    if(!query.length){[self closeSearch];return;}
    _searchString=query;[_searchResults removeAllObjects];_searchIndex=0;
    NSUInteger regexOpts=_searchCaseSensitive?0:NSRegularExpressionCaseInsensitive;
    NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:query options:regexOpts error:nil]?:[NSRegularExpression regularExpressionWithPattern:[NSRegularExpression escapedPatternForString:query] options:regexOpts error:nil];
    if(!regex)return;
    @synchronized(self){
    for(NSInteger y=0;y<(NSInteger)(_historyCount+_rows);y++){
        NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:y-(NSInteger)_historyCount temporary:&hold];
        if(!line)continue;
        NSMutableString *rowText=[NSMutableString string];
        for(NSUInteger x=0;x<_cols;x++){if(!(line[x].flags&TContinuation))[rowText appendString:[self stringForCodepoint:line[x].ch?:' ']];}
        NSString *trimmed=[rowText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSArray *matches=[regex matchesInString:trimmed options:0 range:NSMakeRange(0,trimmed.length)];
        for(NSTextCheckingResult *m in matches)[_searchResults addObject:@{@"row":@(y),@"range":NSStringFromRange(m.range)}];
    }
    }
    if(_searchCounter)_searchCounter.stringValue=[NSString stringWithFormat:@"%lu/%lu",(unsigned long)(_searchResults.count?_searchIndex+1:0),(unsigned long)_searchResults.count];
    if(_searchResults.count)[self navigateSearch:1];else NSBeep();
}
- (void)navigateSearch:(NSInteger)direction {
    if(!_searchResults.count)return;
    _searchIndex=(_searchIndex+direction+_searchResults.count)%_searchResults.count;
    if(_searchCounter)_searchCounter.stringValue=[NSString stringWithFormat:@"%lu/%lu",(unsigned long)(_searchIndex+1),(unsigned long)_searchResults.count];
    NSDictionary *result=_searchResults[_searchIndex];
    NSInteger row=[result[@"row"] integerValue];
    NSInteger histRow=row-(NSInteger)_historyCount;
    if(histRow<0){_historyOffset=MIN((NSInteger)_historyCount,(NSInteger)_historyCount-(row-(NSInteger)_historyCount));[self setNeedsDisplay:YES];}else{_historyOffset=0;[self setNeedsDisplay:YES];}
}
- (void)toggleSearchCase:(id)sender{_searchCaseSensitive=[(NSButton *)sender state]==NSControlStateValueOn;[self executeSearch:nil];}
- (BOOL)cellInSearchResult:(NSUInteger)x y:(NSUInteger)y {
    if(!_searchActive||!_searchResults.count)return NO;
    NSDictionary *result=_searchResults[_searchIndex];
    NSInteger resultRow=[result[@"row"] integerValue];
    if((NSInteger)y+_historyOffset!=resultRow-(NSInteger)_historyCount)return NO;
    NSRange r=NSRangeFromString(result[@"range"]);
    return x>=r.location&&x<NSMaxRange(r);
}
@end

@class TWindowController;

@interface TExtensionHost : NSObject
@property NSMutableArray<NSDictionary *> *commands;
@property TConfig *config;
@property (copy) void (^commandsChanged)(void);
@property(weak) TTerminalView *activeTerminal;
- (void)loadExtensions;
- (void)unloadExtensions;
- (void)executeCommand:(NSDictionary *)command context:(NSDictionary *)context terminal:(TTerminalView *)terminal;
@end

@implementation TExtensionHost { NSMutableDictionary<NSString *,NSPipe *> *_inputs; NSMutableDictionary<NSString *,NSTask *> *_tasks; }
- (instancetype)init { if((self=[super init])){_commands=[NSMutableArray array];_inputs=[NSMutableDictionary dictionary];_tasks=[NSMutableDictionary dictionary];}return self; }
- (NSString *)directory { return [TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"]; }
- (void)unloadExtensions {for(NSTask *task in _tasks.allValues){[(NSPipe *)task.standardOutput fileHandleForReading].readabilityHandler=nil;if(task.isRunning)[task terminate];}[_tasks removeAllObjects];[_inputs removeAllObjects];[_commands removeAllObjects];self.activeTerminal=nil;if(self.commandsChanged)self.commandsChanged();}
- (void)loadExtensions {
    [self unloadExtensions];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in [fm contentsOfDirectoryAtPath:self.directory error:nil] ?: @[]) {
        if(!TSafeIdentifier(name)){TLog(@"ignored extension with unsafe directory name: %@",name);continue;}
        if(![self.config isPluginEnabled:name]){TLog(@"plugin %@ disabled",name);continue;}
        NSString *root = [self.directory stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"extension.json"]];
        if (!data) continue;
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *entry = manifest[@"entry"];
        NSString *identifier = manifest[@"id"] ?: name;
        if (!TSafeIdentifier(identifier)||!entry.length){TLog(@"ignored extension %@ with invalid manifest",name);continue;}
        NSArray *builtIn=TBuiltInCommands(name);if(builtIn.count||[@[@"hyprland-layout",@"hidden-path",@"unicode-rendering",@"osc-integration",@"borderless-window"] containsObject:name]){for(NSDictionary *definition in builtIn){NSMutableDictionary *command=[definition mutableCopy];command[@"extension"]=identifier;[_commands addObject:command];}TLog(@"plugin %@ loaded declaratively without a helper process",name);continue;}
        NSString *path = [root stringByAppendingPathComponent:entry];
        if(!TSafeExtensionExecutable(root,entry)){TLog(@"ignored extension %@ because its entry is unsafe, not user-owned, or writable by other users",name);continue;}

        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:path];
        task.currentDirectoryURL = [NSURL fileURLWithPath:root];
        NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe];
        task.standardInput = input; task.standardOutput = output; task.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
        env[@"TERMATICA_EXTENSION_ID"] = identifier;
        env[@"TERMATICA_PROTOCOL_VERSION"] = @"1";
        task.environment = env;

        __weak typeof(self) weakSelf = self;
        __block NSMutableData *pending = [NSMutableData data];
        output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *chunk = handle.availableData;
            if (!chunk.length) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [pending appendData:chunk];
                if(pending.length>1048576){TLog(@"extension %@ exceeded its output buffer limit",identifier);[pending setLength:0];if(task.isRunning)[task terminate];return;}
                while (YES) {
                    const uint8_t *bytes = pending.bytes;
                    NSUInteger newline = NSNotFound;
                    for (NSUInteger i = 0; i < pending.length; i++) if (bytes[i] == '\n') { newline = i; break; }
                    if (newline == NSNotFound){if(pending.length>65536){TLog(@"extension %@ emitted an oversized message",identifier);[pending setLength:0];if(task.isRunning)[task terminate];}break;}
                    NSData *line = [pending subdataWithRange:NSMakeRange(0, newline)];
                    [pending replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
                    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                    NSString *method = message[@"method"];
                    if ([method isEqual:@"command.register"]) {
                        NSMutableDictionary *command = [message[@"params"] mutableCopy];
                        if (command[@"id"] && command[@"title"]) {
                            command[@"extension"] = identifier;
                            [weakSelf.commands addObject:command];
                            if (weakSelf.commandsChanged) weakSelf.commandsChanged();
                        }
                    } else if ([method isEqual:@"terminal.sendText"]) {
                        NSString *text = message[@"params"][@"text"];
                        if (text.length) [weakSelf.activeTerminal sendString:text];
                    } else if ([method isEqual:@"ui.notify"]) {
                        NSString *text = message[@"params"][@"message"];
                        if (text.length) TLog(@"extension %@: %@", identifier, text);
                    }
                }
            });
        };
        NSError *error = nil;
        if ([task launchAndReturnError:&error]) {
            _tasks[identifier] = task; _inputs[identifier] = input;
            [self send:@{@"jsonrpc":@"2.0", @"method":@"initialize",
                         @"params":@{@"protocolVersion":@1, @"appVersion":TCurrentVersion()}} to:identifier];
        } else TLog(@"extension %@ failed to launch: %@", identifier, error.localizedDescription);
    }
    if (self.commandsChanged) self.commandsChanged();
}
- (void)send:(NSDictionary *)message to:(NSString *)identifier {NSPipe *pipe=_inputs[identifier];if(!pipe)return;NSData *json=[NSJSONSerialization dataWithJSONObject:message options:0 error:nil];NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];@try{[pipe.fileHandleForWriting writeData:line];}@catch(NSException *e){} }
- (void)executeCommand:(NSDictionary *)command context:(NSDictionary *)context terminal:(TTerminalView *)terminal {NSString *nativeCommand=command[@"terminalCommand"];if(nativeCommand.length){NSString *query=context[@"query"]?:@"";NSString *text=[NSString stringWithFormat:@"%@%@\r",nativeCommand,query.length?[NSString stringWithFormat:@" %@",TShellQuote(query)]:@""];[terminal sendString:text];return;}NSString *ext=command[@"extension"];if(!ext)return;self.activeTerminal=terminal;NSMutableDictionary *params=[context mutableCopy];params[@"id"]=command[@"id"]?:@"";[self send:@{@"jsonrpc":@"2.0",@"method":@"command.execute",@"params":params} to:ext];}
@end

@interface TTabButton : NSButton
@property TConfig *config;
@property BOOL selectedTab;
@property BOOL hovered;
@property NSTrackingArea *hoverTrackingArea;
- (void)applyStyleAnimated:(BOOL)animated;
@end

@implementation TTabButton
- (instancetype)initWithFrame:(NSRect)frameRect {if((self=[super initWithFrame:frameRect])){self.bordered=NO;self.wantsLayer=YES;self.layer.masksToBounds=YES;self.alignment=NSTextAlignmentCenter;self.focusRingType=NSFocusRingTypeNone;}return self;}
- (void)updateTrackingAreas {[super updateTrackingAreas];if(self.hoverTrackingArea)[self removeTrackingArea:self.hoverTrackingArea];self.hoverTrackingArea=[[NSTrackingArea alloc]initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];[self addTrackingArea:self.hoverTrackingArea];}
- (void)mouseEntered:(NSEvent *)event {self.hovered=YES;[self applyStyleAnimated:YES];}
- (void)mouseExited:(NSEvent *)event {self.hovered=NO;[self applyStyleAnimated:YES];}
- (void)applyStyleAnimated:(BOOL)animated {self.layer.cornerRadius=self.config->tabButtonCornerRadius;self.font=[NSFont fontWithName:self.config.fontName size:self.config->tabButtonFontSize]?:[NSFont monospacedDigitSystemFontOfSize:self.config->tabButtonFontSize weight:NSFontWeightMedium];NSColor *fill=self.selectedTab?[self.config.accent colorWithAlphaComponent:self.config->tabSelectedOpacity]:(self.hovered?[self.config.selection colorWithAlphaComponent:self.config->tabHoverOpacity]:NSColor.clearColor);self.layer.backgroundColor=fill.CGColor;self.contentTintColor=(self.selectedTab||self.hovered)?self.config.foreground:self.config.muted;CGFloat opacity=self.selectedTab?1:(self.hovered?0.94:0.72);if(!animated){self.alphaValue=opacity;return;}[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=self.config->layoutAnimationDuration/MAX(0.25,self.config.animationSpeed);context.timingFunction=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];self.animator.alphaValue=opacity;} completionHandler:nil];}
@end

@interface TTabRailView : NSView
@property TConfig *config;
@property NSUInteger tabCount;
@end

@implementation TTabRailView
- (BOOL)isFlipped{return YES;}
- (BOOL)isOpaque{return NO;}
- (void)drawRect:(NSRect)dirtyRect {NSRect box=NSInsetRect(self.bounds,0.5,0.5);NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:box xRadius:self.config->tabRailCornerRadius yRadius:self.config->tabRailCornerRadius];CGFloat fillAlpha=self.config.blur?self.config->tabRailBlurOpacity:self.config->tabRailOpacity;[[self.config.panel colorWithAlphaComponent:fillAlpha]setFill];[shape fill];if(self.config.hyprlandLayout)return;if(!self.config.blur){[[self.config.muted colorWithAlphaComponent:MIN(1,self.config->tabHoverOpacity*0.47)]setStroke];shape.lineWidth=1;[shape stroke];}if(self.tabCount>1){CGFloat inset=self.config->tabButtonInset,item=(self.bounds.size.height-inset*2)/self.tabCount;[[self.config.muted colorWithAlphaComponent:self.config.blur?self.config->tabRailBlurOpacity*0.38:self.config->tabSelectedOpacity*0.77]setStroke];for(NSUInteger i=1;i<self.tabCount;i++){NSBezierPath *line=[NSBezierPath bezierPath];[line moveToPoint:NSMakePoint(inset+self.config->tabRailMargin/2,inset+i*item)];[line lineToPoint:NSMakePoint(self.bounds.size.width-inset-self.config->tabRailMargin/2,inset+i*item)];line.lineWidth=1;[line stroke];}}}
@end

@interface TTabEdgeView : NSView
@property TConfig *config;
@end

@implementation TTabEdgeView
- (BOOL)isOpaque{return NO;}
- (void)drawRect:(NSRect)dirtyRect {NSBezierPath *arrow=[NSBezierPath bezierPath];CGFloat mid=NSMidY(self.bounds),half=MIN(4,NSHeight(self.bounds)*0.3),left=MAX(1,self.config->tabCollapsedPeek*0.35),right=MIN(NSWidth(self.bounds)-1,left+4);[arrow moveToPoint:NSMakePoint(left,mid-half)];[arrow lineToPoint:NSMakePoint(right,mid)];[arrow lineToPoint:NSMakePoint(left,mid+half)];arrow.lineWidth=1.5;arrow.lineCapStyle=NSLineCapStyleRound;arrow.lineJoinStyle=NSLineJoinStyleRound;[[self.config.foreground colorWithAlphaComponent:self.config->tabEdgeOpacity]setStroke];[arrow stroke];}
@end

static void TAnimateCenterReveal(NSView *view,CFTimeInterval duration,CGFloat radius,NSString *key,dispatch_block_t completion) {
    if(!view||NSIsEmptyRect(view.bounds)){if(completion)completion();return;}
    [view layoutSubtreeIfNeeded];
    view.wantsLayer=YES;
    [view.layer removeAnimationForKey:[key stringByAppendingString:@".fade"]];
    [view.layer removeAnimationForKey:[key stringByAppendingString:@".settle"]];
    CAShapeLayer *mask=[CAShapeLayer layer];mask.frame=view.bounds;mask.fillColor=NSColor.blackColor.CGColor;
    mask.actions=@{@"path":NSNull.null,@"position":NSNull.null,@"bounds":NSNull.null};
    NSRect endRect=view.bounds,startRect=NSMakeRect(NSMidX(endRect)-3,NSMidY(endRect)-3,6,6);
    CGPathRef start=CGPathCreateWithRoundedRect(NSRectToCGRect(startRect),3,3,NULL);
    CGPathRef end=CGPathCreateWithRoundedRect(NSRectToCGRect(endRect),radius,radius,NULL);
    mask.path=end;view.layer.mask=mask;
    CABasicAnimation *reveal=[CABasicAnimation animationWithKeyPath:@"path"];reveal.fromValue=(__bridge id)start;reveal.toValue=(__bridge id)end;reveal.duration=duration;reveal.timingFunction=[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f];[mask addAnimation:reveal forKey:key];
    CGPathRelease(start);CGPathRelease(end);
    __weak NSView *weakView=view;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((duration+0.02)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{NSView *strongView=weakView;if(strongView.layer.mask==mask)strongView.layer.mask=nil;if(completion)completion();});
}

@interface TTerminalWindow : NSWindow
@end
@implementation TTerminalWindow
- (BOOL)canBecomeKeyWindow {return YES;}
- (BOOL)canBecomeMainWindow {return YES;}
@end

@interface TWindowController : NSWindowController <NSWindowDelegate>
@property TTerminalView *terminal;
@property NSMutableArray<TTerminalView *> *terminals;
@property TConfig *config;
@property TExtensionHost *extensions;
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions;
- (void)addTab;
- (void)addVerticalTab;
- (void)closeTab;
- (void)selectTabNumber:(NSInteger)number;
- (void)reloadConfig;
- (void)routeKeyEvent:(NSEvent *)event;
- (TTerminalView *)terminalAtRootPoint:(NSPoint)point;
- (BOOL)routeScrollEvent:(NSEvent *)event;
- (void)animateLaunchReveal;
- (BOOL)executeExtensionNamed:(NSString *)name query:(NSString *)query;
- (TTerminalView *)newTerminal;
- (TTerminalView *)newTerminalDeferred:(BOOL)deferred;
- (NSArray<NSValue *> *)hyprlandFrames;
- (void)layoutTabs;
- (void)swapLayoutPositionOfTerminal:(TTerminalView *)first withTerminal:(TTerminalView *)second;
@end

@implementation TWindowController { NSString *_cwd; NSView *_root; NSVisualEffectView *_effect; TTabRailView *_tabRail; TTabEdgeView *_tabEdge; NSMutableArray<TTabButton *> *_tabButtons; BOOL _animateTabLayout; BOOL _hyprlandApplied; NSRect _preHyprlandFrame; TTerminalView *_draggingTerminal; TTerminalView *_dragSwapTarget; NSPoint _dragOffset; TTerminalView *_enteringTerminal; NSTimer *_tabHideTimer; NSTrackingArea *_tabHoverArea; NSRect _tabRailTargetFrame; BOOL _tabRailVisible; BOOL _mouseInTabArea; BOOL _revealRailAfterLayout; }
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions {
    if((self=[super initWithWindow:nil])){_config=config;_extensions=extensions;_terminals=[NSMutableArray array];_tabButtons=[NSMutableArray array];
        TTerminalView *terminal=[self newTerminalDeferred:YES];[_terminals addObject:terminal];[terminal startShell];self.terminal=terminal;self.extensions.activeTerminal=terminal;
        NSWindow *window=[[TTerminalWindow alloc]initWithContentRect:NSMakeRect(0,0,config->initialWindowWidth,config->initialWindowHeight) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];self.window=window;
        window.delegate=(id)self;window.title=@"Termatica";window.titleVisibility=NSWindowTitleHidden;window.titlebarAppearsTransparent=YES;window.styleMask|=NSWindowStyleMaskFullSizeContentView;window.minSize=NSMakeSize(config->minimumWindowWidth,config->minimumWindowHeight);window.tabbingMode=NSWindowTabbingModeDisallowed;window.movableByWindowBackground=NO;window.restorable=NO;[window center];
        _root=[[NSView alloc]initWithFrame:window.contentView.bounds];_root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;window.contentView=_root;
        _tabRail=[[TTabRailView alloc]initWithFrame:NSZeroRect];_tabRail.config=config;_tabRail.wantsLayer=YES;[_root addSubview:_tabRail];
        _tabEdge=[[TTabEdgeView alloc]initWithFrame:NSZeroRect];_tabEdge.config=config;_tabEdge.wantsLayer=YES;_tabEdge.hidden=YES;_tabEdge.alphaValue=0;[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];
        for(TTerminalView *terminal in _terminals)[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];
        [self rebuildTabs];[self layoutTabs];[self focusTerminal:self.terminal];
        [self applyAppearance];
        NSArray<TTerminalView *> *initialTerminals=[_terminals copy];__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_MSEC),dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;for(TTerminalView *terminal in initialTerminals)if([self->_terminals containsObject:terminal])[terminal preparePresentation];[self layoutTabs];if(self.terminal)[self focusTerminal:self.terminal];});
    }return self;
}
- (BOOL)hasVerticalSplit {for(TTerminalView *terminal in _terminals)if(terminal.verticalSplit)return YES;return NO;}
- (BOOL)usesTiledLayout {return _terminals.count>1&&(self.config.hyprlandLayout||[self hasVerticalSplit]);}
- (BOOL)tabRailAvailable {return _terminals.count>1&&!self.config.hyprlandLayout;}
- (CFTimeInterval)animationDuration:(CFTimeInterval)duration {return duration/MAX(0.25,self.config.animationSpeed);}
- (void)updateTerminalTabInsets {for(TTerminalView *terminal in _terminals)if(terminal.leadingOverlayInset!=0){terminal.leadingOverlayInset=0;[terminal resizeGrid];[terminal setNeedsDisplay:YES];}}
- (void)suppressTabRail {
    [_tabHideTimer invalidate];_tabHideTimer=nil;if(_tabHoverArea){[_root removeTrackingArea:_tabHoverArea];_tabHoverArea=nil;}_tabRailVisible=NO;_revealRailAfterLayout=NO;_tabRailTargetFrame=NSZeroRect;_tabRail.hidden=YES;_tabRail.alphaValue=0;_tabEdge.hidden=YES;_tabEdge.alphaValue=0;
}
- (void)updateTabHoverArea {
    if(_tabHoverArea){[_root removeTrackingArea:_tabHoverArea];_tabHoverArea=nil;}if(![self tabRailAvailable])return;
    CGFloat peek=self.config->tabCollapsedPeek,edgeHeight=MAX(20,self.config->tabMaximumHeight);NSRect edge=NSMakeRect(0,NSMaxY(_tabRailTargetFrame)-edgeHeight,MAX(4,peek+3),edgeHeight);_tabEdge.frame=edge;NSRect hover=NSUnionRect(_tabRailTargetFrame,edge);hover=NSInsetRect(hover,-self.config->tabRailMargin*0.75,-self.config->tabRailMargin*0.75);_tabHoverArea=[[NSTrackingArea alloc]initWithRect:hover options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow owner:self userInfo:nil];[_root addTrackingArea:_tabHoverArea];
}
- (void)scheduleTabRailHide {
    [_tabHideTimer invalidate];_tabHideTimer=nil;if(!self.config.tabAutoHide||!_tabRailVisible||![self tabRailAvailable])return;__weak typeof(self) weakSelf=self;_tabHideTimer=[NSTimer timerWithTimeInterval:self.config.tabHideDelay repeats:NO block:^(NSTimer *timer){__strong typeof(weakSelf) self=weakSelf;if(self)[self hideTabRail];}];[NSRunLoop.mainRunLoop addTimer:_tabHideTimer forMode:NSRunLoopCommonModes];
}
- (void)revealTabRail {
    if(![self tabRailAvailable]||NSIsEmptyRect(_tabRailTargetFrame)){[self suppressTabRail];return;}[_tabHideTimer invalidate];_tabHideTimer=nil;BOOL wasVisible=_tabRailVisible;_tabRailVisible=YES;[self updateTerminalTabInsets];[_tabRail.layer removeAnimationForKey:@"termatica.rail.fold"];[_tabEdge.layer removeAnimationForKey:@"termatica.edge.reveal"];NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+self.config->tabCollapsedPeek;_tabRail.hidden=NO;if(!wasVisible){_tabRail.frame=collapsed;_tabRail.alphaValue=0;if(self.config.tabAnimations){CAKeyframeAnimation *unfold=[CAKeyframeAnimation animationWithKeyPath:@"transform"];unfold.values=@[[NSValue valueWithCATransform3D:CATransform3DConcat(CATransform3DMakeTranslation(-10,0,0),CATransform3DMakeScale(0.78,0.90,1))],[NSValue valueWithCATransform3D:CATransform3DMakeScale(0.97,0.99,1)],[NSValue valueWithCATransform3D:CATransform3DIdentity]];unfold.keyTimes=@[@0,@0.62,@1];unfold.duration=[self animationDuration:self.config->terminalAnimationDuration];unfold.timingFunctions=@[[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f],[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f]];[_tabRail.layer addAnimation:unfold forKey:@"termatica.rail.unfold"];}}_tabEdge.hidden=NO;CAMediaTimingFunction *settle=[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f];[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=self.config.tabAnimations?[self animationDuration:self.config->terminalAnimationDuration]:0;context.timingFunction=settle;_tabRail.animator.frame=_tabRailTargetFrame;_tabRail.animator.alphaValue=1;_tabEdge.animator.alphaValue=0;} completionHandler:^{if(self->_tabRailVisible)self->_tabEdge.hidden=YES;}];[self scheduleTabRailHide];
}
- (void)hideTabRail {
    if(!_tabRailVisible||_terminals.count<2)return;if(_mouseInTabArea){[self scheduleTabRailHide];return;}[_tabHideTimer invalidate];_tabHideTimer=nil;_tabRailVisible=NO;NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+self.config->tabCollapsedPeek;_tabEdge.hidden=NO;_tabEdge.alphaValue=0;if(self.config.tabAnimations){[_tabRail.layer removeAnimationForKey:@"termatica.rail.unfold"];CAKeyframeAnimation *fold=[CAKeyframeAnimation animationWithKeyPath:@"transform"];fold.values=@[[NSValue valueWithCATransform3D:CATransform3DIdentity],[NSValue valueWithCATransform3D:CATransform3DConcat(CATransform3DMakeTranslation(-3,0,0),CATransform3DMakeScale(0.94,0.98,1))],[NSValue valueWithCATransform3D:CATransform3DConcat(CATransform3DMakeTranslation(-12,0,0),CATransform3DMakeScale(0.72,0.86,1))]];fold.keyTimes=@[@0,@0.34,@1];fold.duration=[self animationDuration:self.config->terminalAnimationDuration];fold.timingFunctions=@[[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f],[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f]];[_tabRail.layer addAnimation:fold forKey:@"termatica.rail.fold"];CABasicAnimation *edgeReveal=[CABasicAnimation animationWithKeyPath:@"transform.scale"];edgeReveal.fromValue=@0.58;edgeReveal.toValue=@1;edgeReveal.duration=[self animationDuration:self.config->layoutAnimationDuration];edgeReveal.timingFunction=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];[_tabEdge.layer addAnimation:edgeReveal forKey:@"termatica.edge.reveal"];}CAMediaTimingFunction *settle=[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f];[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=self.config.tabAnimations?[self animationDuration:self.config->terminalAnimationDuration]:0;context.timingFunction=settle;_tabRail.animator.frame=collapsed;_tabRail.animator.alphaValue=0;_tabEdge.animator.alphaValue=self.config->tabEdgeOpacity;} completionHandler:^{if(!self->_tabRailVisible){self->_tabRail.hidden=YES;[self updateTerminalTabInsets];}}];
}
- (void)mouseEntered:(NSEvent *)event {if(event.trackingArea==_tabHoverArea){_mouseInTabArea=YES;[self revealTabRail];}}
- (void)mouseExited:(NSEvent *)event {if(event.trackingArea==_tabHoverArea){_mouseInTabArea=NO;[self scheduleTabRailHide];}}
- (void)assignFrame:(NSRect)frame toTerminal:(TTerminalView *)terminal frames:(NSMutableArray<NSValue *> *)frames {
    NSUInteger index=[_terminals indexOfObject:terminal];if(index==NSNotFound)return;
    NSMutableArray<TTerminalView *> *children=[NSMutableArray array];for(TTerminalView *item in _terminals)if(item.splitAnchor==terminal)[children addObject:item];
    if(!children.count){frames[index]=[NSValue valueWithRect:frame];return;}
    NSUInteger count=children.count+1;CGFloat gap=self.config.tileGap,height=(NSHeight(frame)-gap*(count-1))/count;
    NSRect own=NSMakeRect(NSMinX(frame),NSMaxY(frame)-height,NSWidth(frame),height);frames[index]=[NSValue valueWithRect:own];
    for(NSUInteger i=0;i<children.count;i++){NSRect child=NSMakeRect(NSMinX(frame),NSMaxY(frame)-(i+2)*height-(i+1)*gap,NSWidth(frame),height);[self assignFrame:child toTerminal:children[i] frames:frames];}
}
- (NSArray<NSValue *> *)hyprlandFrames {
    CGFloat w=_root.bounds.size.width,h=_root.bounds.size.height,gap=self.config.tileGap;
    NSUInteger count=_terminals.count;
    NSMutableArray<NSValue *> *frames=[NSMutableArray arrayWithCapacity:count];for(NSUInteger i=0;i<count;i++)[frames addObject:[NSValue valueWithRect:NSZeroRect]];
    NSMutableArray<TTerminalView *> *roots=[NSMutableArray array];for(TTerminalView *terminal in _terminals)if(!terminal.splitAnchor||![_terminals containsObject:terminal.splitAnchor])[roots addObject:terminal];
    NSUInteger columns=roots.count>1?(NSUInteger)ceil(sqrt((double)roots.count)):1,rows=roots.count>1?(NSUInteger)ceil((double)roots.count/columns):1;
    for(NSUInteger i=0;i<roots.count;i++){NSUInteger row=i/columns,column=i%columns,countInRow=MIN(columns,roots.count-row*columns);CGFloat cellWidth=(w-gap*(countInRow-1))/countInRow,cellHeight=(h-gap*(rows-1))/rows;NSRect frame=NSMakeRect(column*(cellWidth+gap),h-(row+1)*cellHeight-row*gap,cellWidth,cellHeight);[self assignFrame:frame toTerminal:roots[i] frames:frames];}
    return frames;
}
- (void)swapLayoutPositionOfTerminal:(TTerminalView *)first withTerminal:(TTerminalView *)second {
    if(!first||!second||first==second)return;
    NSUInteger firstIndex=[_terminals indexOfObject:first],secondIndex=[_terminals indexOfObject:second];
    if(firstIndex==NSNotFound||secondIndex==NSNotFound)return;
    TTerminalView *firstParent=[_terminals containsObject:first.splitAnchor]?first.splitAnchor:nil;
    TTerminalView *secondParent=[_terminals containsObject:second.splitAnchor]?second.splitAnchor:nil;
    for(TTerminalView *item in _terminals){
        if(item==first||item==second)continue;
        if(item.splitAnchor==first)item.splitAnchor=second;
        else if(item.splitAnchor==second)item.splitAnchor=first;
    }
    first.splitAnchor=secondParent==first?second:secondParent;
    second.splitAnchor=firstParent==second?first:firstParent;
    if(first.splitAnchor==first)first.splitAnchor=nil;
    if(second.splitAnchor==second)second.splitAnchor=nil;
    [_terminals exchangeObjectAtIndex:firstIndex withObjectAtIndex:secondIndex];
}
- (void)updateEffectMask {
    if(!_effect)return;
    if(![self usesTiledLayout]){_effect.layer.mask=nil;return;}
    CAShapeLayer *mask=[_effect.layer.mask isKindOfClass:CAShapeLayer.class]?(CAShapeLayer *)_effect.layer.mask:[CAShapeLayer layer];
    CGMutablePathRef path=CGPathCreateMutable();
    for(TTerminalView *terminal in _terminals)CGPathAddRoundedRect(path,NULL,NSRectToCGRect(terminal.frame),self.config->tileCornerRadius,self.config->tileCornerRadius);
    mask.frame=_effect.bounds;mask.path=path;mask.fillColor=NSColor.blackColor.CGColor;_effect.layer.mask=mask;CGPathRelease(path);
}
- (void)beginDraggingTerminal:(TTerminalView *)terminal event:(NSEvent *)event {
    if(![self usesTiledLayout]||![_terminals containsObject:terminal])return;
    [self focusTerminal:terminal];_draggingTerminal=terminal;_dragSwapTarget=nil;
    NSPoint point=[_root convertPoint:event.locationInWindow fromView:nil];_dragOffset=NSMakePoint(point.x-NSMinX(terminal.frame),point.y-NSMinY(terminal.frame));
    terminal.autoresizingMask=NSViewNotSizable;terminal.wantsLayer=YES;[terminal.layer removeAllAnimations];terminal.layer.zPosition=20;terminal.layer.borderWidth=1.5;terminal.layer.borderColor=[self.config.accent colorWithAlphaComponent:0.82].CGColor;[_root addSubview:terminal positioned:NSWindowAbove relativeTo:nil];
}
- (void)dragTerminal:(TTerminalView *)terminal event:(NSEvent *)event {
    if(terminal!=_draggingTerminal)return;
    NSPoint point=[_root convertPoint:event.locationInWindow fromView:nil];NSRect frame=terminal.frame;
    frame.origin.x=MAX(0,MIN(_root.bounds.size.width-frame.size.width,point.x-_dragOffset.x));frame.origin.y=MAX(0,MIN(_root.bounds.size.height-frame.size.height,point.y-_dragOffset.y));[terminal setFrameOrigin:frame.origin];
    NSArray<NSValue *> *slots=[self hyprlandFrames];
    TTerminalView *target=nil;CGFloat bestOverlap=0;
    for(NSUInteger index=0;index<_terminals.count&&index<slots.count;index++){
        TTerminalView *candidate=_terminals[index];if(candidate==terminal)continue;NSRect slot=slots[index].rectValue;if(NSIsEmptyRect(slot))continue;
        if(NSPointInRect(point,slot)){target=candidate;break;}
        NSRect overlap=NSIntersectionRect(frame,slot);CGFloat area=NSIsEmptyRect(overlap)?0:NSWidth(overlap)*NSHeight(overlap);if(area>bestOverlap){bestOverlap=area;target=candidate;}
    }
    if(target&&target!=_dragSwapTarget){
        _dragSwapTarget=target;[self swapLayoutPositionOfTerminal:terminal withTerminal:target];_animateTabLayout=YES;[self layoutTabs];
    }else if(!target){
        _dragSwapTarget=nil;
    }
    [self updateEffectMask];
}
- (void)endDraggingTerminal:(TTerminalView *)terminal event:(NSEvent *)event {
    if(terminal!=_draggingTerminal)return;terminal.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;terminal.layer.zPosition=0;terminal.layer.borderWidth=0;terminal.layer.borderColor=nil;_draggingTerminal=nil;_dragSwapTarget=nil;_animateTabLayout=YES;[self layoutTabs];[self focusTerminal:terminal];
}
- (TTerminalView *)newTerminal {
    return [self newTerminalDeferred:NO];
}
- (TTerminalView *)newTerminalDeferred:(BOOL)deferred {
    TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSZeroRect config:self.config deferPresentation:deferred];terminal.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;__weak typeof(self) weakSelf=self;__weak TTerminalView *weakTerminal=terminal;terminal.titleChanged=^(NSString *title){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self.window.title=title.length?title:@"Termatica";};terminal.cwdChanged=^(NSString *cwd){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self->_cwd=cwd;};terminal.focused=^{__strong typeof(weakSelf) self=weakSelf;if(self&&weakTerminal)[self focusTerminal:weakTerminal];};terminal.tileDragBegan=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self beginDraggingTerminal:tile event:event];};terminal.tileDragMoved=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self dragTerminal:tile event:event];};terminal.tileDragEnded=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self endDraggingTerminal:tile event:event];};terminal.accessibilityHelp=@"Command-drag, or drag from the top padding, to rearrange this Hyprland terminal.";terminal.splitShortcut=^{__strong typeof(weakSelf) self=weakSelf;if(self)[self addTabWithVerticalSplit:NO];};terminal.nextSplitShortcut=^{__strong typeof(weakSelf) self=weakSelf;if(self){NSUInteger idx=[self.terminals indexOfObject:self.terminal];if(idx!=NSNotFound&&idx+1<self.terminals.count){[self focusTerminal:self.terminals[idx+1]];}}};terminal.prevSplitShortcut=^{__strong typeof(weakSelf) self=weakSelf;if(self){NSUInteger idx=[self.terminals indexOfObject:self.terminal];if(idx!=NSNotFound&&idx>0){[self focusTerminal:self.terminals[idx-1]];}}};return terminal;
}
- (void)updateTabSelectionAnimated:(BOOL)animated {NSUInteger active=[_terminals indexOfObject:self.terminal];for(NSUInteger i=0;i<_tabButtons.count;i++){TTabButton *button=_tabButtons[i];BOOL selected=i==active;if(button.selectedTab!=selected){button.selectedTab=selected;[button applyStyleAnimated:animated];}}if([self tabRailAvailable])[self revealTabRail];}
- (void)focusTerminal:(TTerminalView *)terminal {if(!terminal||![_terminals containsObject:terminal])return;if(self.terminal!=terminal){self.terminal=terminal;_cwd=[terminal workingDirectory];if([self usesTiledLayout])[self updateTabSelectionAnimated:YES];else{[self rebuildTabs];[self layoutTabs];}}for(TTerminalView *item in _terminals)item.activeTerminal=item==terminal;self.extensions.activeTerminal=terminal;[terminal setNeedsDisplay:YES];[self.window makeFirstResponder:terminal];}
- (void)animateLaunchReveal {
    if(!self.config.tabAnimations)return;
    [self layoutTabs];
    [_root layoutSubtreeIfNeeded];
    [self.window displayIfNeeded];
    __weak typeof(self) weakSelf=self;TAnimateCenterReveal(_root,[self animationDuration:self.config->launchAnimationDuration],self.config.topBar?0:self.config->windowCornerRadius,@"termatica.launch.center",^{__strong typeof(weakSelf) self=weakSelf;if(self&&!self->_effect&&![self usesTiledLayout])self->_root.wantsLayer=NO;});
}
- (void)animateNewTerminal:(TTerminalView *)terminal {
    if(!self.config.tabAnimations)return;CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];
    BOOL tiled=[self usesTiledLayout];__weak TTerminalView *weakTerminal=terminal;TAnimateCenterReveal(terminal,[self animationDuration:self.config->terminalAnimationDuration],tiled?self.config->tileCornerRadius:0,@"termatica.terminal.center",^{if(!tiled)[weakTerminal releaseAnimationLayer];});
    if(_tabButtons.count>1){TTabButton *button=_tabButtons.lastObject,*previous=_tabButtons[_tabButtons.count-2];CABasicAnimation *move=[CABasicAnimation animationWithKeyPath:@"position"];move.fromValue=[NSValue valueWithPoint:previous.layer.position];move.toValue=[NSValue valueWithPoint:button.layer.position];move.duration=[self animationDuration:0.12];move.timingFunction=ease;[button.layer addAnimation:move forKey:@"termatica.bubble.move"];CABasicAnimation *bubble=[CABasicAnimation animationWithKeyPath:@"transform.scale"];bubble.fromValue=@0.78;bubble.toValue=@1;bubble.duration=[self animationDuration:0.11];bubble.timingFunction=ease;[button.layer addAnimation:bubble forKey:@"termatica.bubble.pop"];}
}
- (void)cancelTileAnimation {_enteringTerminal=nil;}
- (void)addTabWithVerticalSplit:(BOOL)verticalSplit {[self cancelTileAnimation];BOOL animate=_terminals.count>0&&_terminals.count<6,wasTiled=[self usesTiledLayout];TTerminalView *anchor=self.terminal,*terminal=[self newTerminal];terminal.launchDirectory=anchor?[anchor workingDirectory]:_cwd;terminal.verticalSplit=verticalSplit;terminal.splitAnchor=verticalSplit?anchor:nil;[terminal startShell];if(verticalSplit&&anchor){NSUInteger index=[_terminals indexOfObject:anchor];[_terminals insertObject:terminal atIndex:index==NSNotFound?_terminals.count:index+1];}else [_terminals addObject:terminal];if(animate&&self.config.tabAnimations&&[self usesTiledLayout])_enteringTerminal=terminal;[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];self.terminal=terminal;self.extensions.activeTerminal=terminal;_animateTabLayout=animate;BOOL changedTiling=wasTiled!=[self usesTiledLayout];if(changedTiling)[self applyAppearance];else{[self rebuildTabs];[self layoutTabs];}if(animate&&![self usesTiledLayout])[self animateNewTerminal:terminal];[self focusTerminal:terminal];}
- (void)addTab {[self addTabWithVerticalSplit:NO];}
- (void)addVerticalTab {[self addTabWithVerticalSplit:YES];}
- (void)closeTab {[self cancelTileAnimation];TTerminalView *closing=self.terminal;if(!closing)return;if(_terminals.count<=1){[_terminals removeAllObjects];self.terminal=nil;self.extensions.activeTerminal=nil;[closing stopShellTerminating:YES];[closing removeFromSuperview];[self.window close];return;}BOOL wasTiled=[self usesTiledLayout],animate=_terminals.count<=6;NSUInteger index=[_terminals indexOfObject:closing];for(TTerminalView *item in _terminals)if(item.splitAnchor==closing&&item.splitAnchor!=item)item.splitAnchor=closing.splitAnchor;[_terminals removeObjectAtIndex:index];[closing stopShellTerminating:YES];[closing removeFromSuperview];self.terminal=_terminals[MIN(index,_terminals.count-1)];self.extensions.activeTerminal=self.terminal;_animateTabLayout=animate;if(wasTiled!=[self usesTiledLayout])[self applyAppearance];else{[self rebuildTabs];[self layoutTabs];}[self focusTerminal:self.terminal];}
- (void)selectTabButton:(NSButton *)sender {[self selectTabNumber:sender.tag+1];}
- (void)selectTabNumber:(NSInteger)number {
    NSInteger index=number-1;if(index<0||index>=(NSInteger)_terminals.count)return;NSUInteger oldIndex=[_terminals indexOfObject:self.terminal];if((NSUInteger)index==oldIndex){[self focusTerminal:self.terminal];return;}
    TTerminalView *old=self.terminal,*next=_terminals[(NSUInteger)index];self.terminal=next;_cwd=[next workingDirectory];self.extensions.activeTerminal=next;if([self usesTiledLayout]){[self updateTabSelectionAnimated:YES];[self focusTerminal:next];[next setNeedsDisplay:YES];return;}[self rebuildTabs];[self layoutTabs];
    if(self.config.tabAnimations&&![self usesTiledLayout]){old.wantsLayer=next.wantsLayer=YES;CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];old.hidden=NO;next.hidden=NO;CGFloat direction=(NSUInteger)index>oldIndex?1:-1;CABasicAnimation *incoming=[CABasicAnimation animationWithKeyPath:@"transform.translation.x"];incoming.fromValue=@(direction*20);incoming.toValue=@0;incoming.duration=[self animationDuration:0.12];incoming.timingFunction=ease;[next.layer addAnimation:incoming forKey:@"termatica.tab.slide.in"];CABasicAnimation *outgoing=[CABasicAnimation animationWithKeyPath:@"transform.translation.x"];outgoing.fromValue=@0;outgoing.toValue=@(-direction*14);outgoing.duration=[self animationDuration:0.10];outgoing.timingFunction=ease;[old.layer addAnimation:outgoing forKey:@"termatica.tab.slide.out"];CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];fade.fromValue=@1;fade.toValue=@0;fade.duration=[self animationDuration:0.10];fade.timingFunction=ease;[old.layer addAnimation:fade forKey:@"termatica.tab.fade.out"];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self animationDuration:0.13]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{old.hidden=YES;[old releaseAnimationLayer];[next releaseAnimationLayer];});}
    [self focusTerminal:next];[next setNeedsDisplay:YES];
}
- (void)rebuildTabs {
    for(TTabButton *button in _tabButtons)[button removeFromSuperview];[_tabButtons removeAllObjects];_tabRail.tabCount=_terminals.count;
    if(![self tabRailAvailable]){[self suppressTabRail];TLog(@"tab count %lu, rail suppressed%@",(unsigned long)_terminals.count,self.config.hyprlandLayout?@" in Hyprland mode":@"");return;}
    _revealRailAfterLayout=YES;NSUInteger active=[_terminals indexOfObject:self.terminal];for(NSUInteger i=0;i<_terminals.count;i++){TTabButton *button=[[TTabButton alloc]initWithFrame:NSZeroRect];button.config=self.config;button.title=[NSString stringWithFormat:@"%lu",(unsigned long)i+1];button.target=self;button.action=@selector(selectTabButton:);button.tag=(NSInteger)i;button.selectedTab=i==active;button.accessibilityLabel=[NSString stringWithFormat:@"Terminal tab %lu",(unsigned long)i+1];[button applyStyleAnimated:NO];[_tabRail addSubview:button];[_tabButtons addObject:button];}[_root addSubview:_tabRail positioned:NSWindowAbove relativeTo:nil];[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];[_tabRail setNeedsDisplay:YES];TLog(@"tab count %lu, rail ready",(unsigned long)_terminals.count);
}
- (void)layoutTabs {
    CGFloat w=_root.bounds.size.width,h=_root.bounds.size.height;BOOL tile=[self usesTiledLayout],animate=_animateTabLayout&&self.config.tabAnimations;NSArray<NSValue *> *slots=tile?[self hyprlandFrames]:@[];CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];
    NSMutableArray<NSValue *> *fromFrames=[NSMutableArray arrayWithCapacity:_terminals.count],*toFrames=[NSMutableArray arrayWithCapacity:_terminals.count];
    for(NSUInteger i=0;i<_terminals.count;i++){
        TTerminalView *terminal=_terminals[i];NSRect target=tile?slots[i].rectValue:NSMakeRect(0,0,w,h),prior=terminal.frame;
        NSRect animationStart=prior;if(tile&&prior.size.width<1){animationStart=NSInsetRect(target,NSWidth(target)*0.06,NSHeight(target)*0.10);if(terminal.splitAnchor){NSUInteger anchorIndex=[_terminals indexOfObject:terminal.splitAnchor];if(anchorIndex!=NSNotFound&&anchorIndex<fromFrames.count){NSRect anchor=fromFrames[anchorIndex].rectValue;animationStart.origin.y=MAX(NSMinY(target),MIN(NSMaxY(target)-NSHeight(animationStart),NSMinY(anchor)-NSHeight(animationStart)*0.24));}}}
        [fromFrames addObject:[NSValue valueWithRect:animationStart]];[toFrames addObject:[NSValue valueWithRect:target]];
        terminal.hidden=tile?NO:terminal!=self.terminal;terminal.leadingOverlayInset=0;terminal.topContentInset=self.config.topBar?0:6;terminal.activeTerminal=terminal==self.terminal;terminal.tiledRendering=tile;
        if(terminal!=_draggingTerminal){terminal.frame=target;[terminal resizeGrid];}
        if(tile)TLog(@"tile %lu frame %.0f,%.0f %.0fx%.0f anchor %@",(unsigned long)i+1,target.origin.x,target.origin.y,target.size.width,target.size.height,terminal.splitAnchor?[NSString stringWithFormat:@"%lu",(unsigned long)[_terminals indexOfObject:terminal.splitAnchor]+1]:@"root");
        if(terminal==_draggingTerminal)continue;
        BOOL animateTerminal=animate&&(!tile||!_enteringTerminal||terminal==_enteringTerminal);
        terminal.wantsLayer=tile||animateTerminal||[terminal usesMetalRenderer];terminal.layer.cornerRadius=tile?self.config->tileCornerRadius:0;terminal.layer.masksToBounds=tile;
        if(animateTerminal&&animationStart.size.width>0&&!NSEqualRects(animationStart,target)){CGFloat sx=animationStart.size.width/target.size.width,sy=animationStart.size.height/target.size.height,dx=NSMidX(animationStart)-NSMidX(target),dy=NSMidY(animationStart)-NSMidY(target);CATransform3D from=CATransform3DConcat(CATransform3DMakeTranslation(dx,dy,0),CATransform3DMakeScale(sx,sy,1));CABasicAnimation *snap=[CABasicAnimation animationWithKeyPath:@"transform"];snap.fromValue=[NSValue valueWithCATransform3D:from];snap.toValue=[NSValue valueWithCATransform3D:CATransform3DIdentity];snap.duration=[self animationDuration:self.config->layoutAnimationDuration];snap.timingFunction=ease;[terminal.layer addAnimation:snap forKey:@"termatica.hypr.snap"];if(terminal==_enteringTerminal){CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];fade.fromValue=@0;fade.toValue=@1;fade.duration=[self animationDuration:self.config->layoutAnimationDuration*0.75];fade.timingFunction=ease;[terminal.layer addAnimation:fade forKey:@"termatica.hypr.fade"];}if(!tile){__weak TTerminalView *weakTerminal=terminal;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self animationDuration:self.config->layoutAnimationDuration+0.02]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[weakTerminal releaseAnimationLayer];});}}
    }
    [self cancelTileAnimation];
    [self updateEffectMask];
    if(![self tabRailAvailable]){_animateTabLayout=NO;[self suppressTabRail];[self updateTerminalTabInsets];return;}
    CGFloat margin=self.config->tabRailMargin,inset=self.config->tabButtonInset,topInset=MAX(self.config->tabMaximumHeight+margin*2,_root.safeAreaInsets.top+margin),available=MAX(self.config->tabMinimumHeight+inset*2,h-topInset-margin),itemHeight=MIN(self.config->tabMaximumHeight,floor((available-inset*2)/_terminals.count));itemHeight=MAX(self.config->tabMinimumHeight,itemHeight);CGFloat railWidth=self.config.tabRailWidth,railHeight=inset*2+itemHeight*_terminals.count;_tabRailTargetFrame=NSMakeRect(margin,MAX(margin,h-topInset-railHeight-margin),railWidth,railHeight);for(NSUInteger i=0;i<_tabButtons.count;i++)_tabButtons[i].frame=NSMakeRect(inset,inset+i*itemHeight,MAX(1,railWidth-inset*2),itemHeight);[self updateTabHoverArea];TLog(@"tab rail frame %.0f,%.0f %.0fx%.0f",_tabRailTargetFrame.origin.x,_tabRailTargetFrame.origin.y,_tabRailTargetFrame.size.width,_tabRailTargetFrame.size.height);BOOL reveal=_revealRailAfterLayout;_revealRailAfterLayout=NO;_animateTabLayout=NO;if(reveal)[self revealTabRail];else if(_tabRailVisible)_tabRail.frame=_tabRailTargetFrame;else{NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+self.config->tabCollapsedPeek;_tabRail.frame=collapsed;}[_root addSubview:_tabRail positioned:NSWindowAbove relativeTo:nil];[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];[_tabRail setNeedsDisplay:YES];
}
- (void)windowDidResize:(NSNotification *)notification {[self layoutTabs];}
- (void)windowDidBecomeKey:(NSNotification *)notification {if(self.terminal)[self focusTerminal:self.terminal];}
- (void)routeKeyEvent:(NSEvent *)event {if(self.terminal)[self.terminal keyDown:event];}
- (TTerminalView *)terminalAtRootPoint:(NSPoint)point {for(TTerminalView *terminal in _terminals.reverseObjectEnumerator)if(!terminal.hidden&&NSPointInRect(point,terminal.frame))return terminal;return _terminals.count==1?_terminals.firstObject:nil;}
- (BOOL)routeScrollEvent:(NSEvent *)event {
    NSPoint point=[_root convertPoint:event.locationInWindow fromView:nil];TTerminalView *target=[self terminalAtRootPoint:point];
    if(!target)return NO;
    NSUInteger index=[_terminals indexOfObject:target];TLog(@"wheel routed to terminal %lu at %.0f,%.0f",(unsigned long)index+1,point.x,point.y);
    [target scrollWheel:event];return YES;
}
- (void)applyAppearance {
    BOOL tiled=[self usesTiledLayout];
    BOOL wantsBlur=self.config.blur&&(!tiled||self.config.hyprlandBlur)&&getenv("TERMATICA_NO_BLUR")==NULL;
    BOOL opaque=self.config.backgroundOpacity>=0.999&&self.config.windowOpacity>=0.999&&!wantsBlur,borderless=!self.config.topBar,transparentFrame=borderless||tiled;
    BOOL animateWindow=self.window.isVisible&&self.config.tabAnimations;
    if(self.config.hyprlandLayout){
        if(!_hyprlandApplied&&_preHyprlandFrame.size.width==0)_preHyprlandFrame=self.window.frame;
        NSScreen *screen=self.window.screen?:NSScreen.mainScreen;
        NSRect visibleFrame=screen?screen.visibleFrame:NSZeroRect;
        if(visibleFrame.size.width>=480&&visibleFrame.size.height>=280){
            NSRect target=NSInsetRect(visibleFrame,self.config.screenInset,self.config.screenInset);
            if(!NSEqualRects(self.window.frame,target))[self.window setFrame:target display:YES animate:animateWindow];
        }
        _hyprlandApplied=YES;
    }else if(_hyprlandApplied){if(_preHyprlandFrame.size.width>0)[self.window setFrame:_preHyprlandFrame display:YES animate:animateWindow];_hyprlandApplied=NO;}
    NSWindowStyleMask fullscreen=self.window.styleMask&NSWindowStyleMaskFullScreen;self.window.styleMask=fullscreen|NSWindowStyleMaskResizable|(self.config.topBar?(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskFullSizeContentView):NSWindowStyleMaskBorderless);self.window.titleVisibility=NSWindowTitleHidden;self.window.titlebarAppearsTransparent=YES;self.window.titlebarSeparatorStyle=NSTitlebarSeparatorStyleNone;self.window.movableByWindowBackground=NO;self.window.hasShadow=self.config->windowShadow;self.window.minSize=NSMakeSize(self.config->minimumWindowWidth,self.config->minimumWindowHeight);
    _root.wantsLayer=borderless;_root.layer.backgroundColor=NSColor.clearColor.CGColor;_root.layer.cornerRadius=borderless?self.config->windowCornerRadius:0;_root.layer.masksToBounds=borderless;_root.layer.borderWidth=0;_root.layer.borderColor=nil;
    for(NSUInteger type=NSWindowCloseButton;type<=NSWindowZoomButton;type++)[[self.window standardWindowButton:(NSWindowButton)type] setHidden:borderless];self.window.alphaValue=self.config.windowOpacity;self.window.opaque=transparentFrame?NO:opaque;self.window.backgroundColor=(transparentFrame||!opaque)?NSColor.clearColor:self.config.background;_tabRail.config=self.config;
    if(wantsBlur&&!_effect){_effect=[[NSVisualEffectView alloc]initWithFrame:_root.bounds];_effect.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;_effect.blendingMode=NSVisualEffectBlendingModeBehindWindow;_effect.wantsLayer=YES;[_root addSubview:_effect positioned:NSWindowBelow relativeTo:nil];}else if(!wantsBlur&&_effect){[_effect removeFromSuperview];_effect=nil;}
    _effect.state=wantsBlur?NSVisualEffectStateActive:NSVisualEffectStateInactive;
    if([self.config.blurMaterial isEqual:@"sidebar"])_effect.material=NSVisualEffectMaterialSidebar;else if([self.config.blurMaterial isEqual:@"menu"])_effect.material=NSVisualEffectMaterialMenu;else if([self.config.blurMaterial isEqual:@"popover"])_effect.material=NSVisualEffectMaterialPopover;else if([self.config.blurMaterial isEqual:@"under-window"])_effect.material=NSVisualEffectMaterialUnderWindowBackground;else _effect.material=NSVisualEffectMaterialHUDWindow;
    for(TTerminalView *terminal in _terminals)[terminal setNeedsDisplay:YES];[self rebuildTabs];[self layoutTabs];if(self.terminal)[self focusTerminal:self.terminal];
}
- (void)reloadConfig {[self.config reload];BOOL hiddenPath=[self.config isPluginEnabled:@"hidden-path"];for(TTerminalView *terminal in _terminals){[terminal reloadAppearance];[terminal setHiddenPathEnabled:hiddenPath];}[self applyAppearance];}
- (BOOL)executeExtensionNamed:(NSString *)name query:(NSString *)query {NSString *needle=[name hasPrefix:@"/"]?name:[@"/" stringByAppendingString:name];for(NSDictionary *command in self.extensions.commands){if([command[@"slash"] isEqual:needle]||[command[@"id"] isEqual:name]){NSDictionary *ctx=@{@"query":query?:@"",@"cwd":_cwd?:[self.terminal workingDirectory],@"selection":[self.terminal selectedText]?:@"",@"screen":[self.terminal visibleText]?:@""};[self.extensions executeCommand:command context:ctx terminal:self.terminal];return YES;}}return NO;}
@end
static double TMedianDoubles(double *values,NSUInteger count){if(!count)return 0;for(NSUInteger i=1;i<count;i++){double value=values[i];NSUInteger j=i;while(j&&values[j-1]>value){values[j]=values[j-1];j--;}values[j]=value;}return count&1?values[count/2]:(values[count/2-1]+values[count/2])/2;}
static double TAppFootprintMiB(void){struct rusage_info_v4 usage={0};return proc_pid_rusage(getpid(),RUSAGE_INFO_V4,(rusage_info_t *)&usage)==0?(double)usage.ri_phys_footprint/1048576.0:0;}
static NSData *TBenchmarkPattern(NSString *pattern,NSUInteger bytes){NSData *unit=[pattern dataUsingEncoding:NSUTF8StringEncoding];NSMutableData *data=[NSMutableData dataWithCapacity:bytes];while(data.length+unit.length<=bytes)[data appendData:unit];if(data.length<bytes)[data appendBytes:unit.bytes length:bytes-data.length];return data;}
static double TInAppThroughput(TConfig *config,NSData *data){double runs[3]={0};for(NSUInteger run=0;run<3;run++){@autoreleasepool{TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,720,440) config:config deferPresentation:NO];CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();[terminal consumeData:data];runs[run]=(double)data.length/1048576.0/MAX(0.000001,CFAbsoluteTimeGetCurrent()-start);}}return TMedianDoubles(runs,3);}
static NSDictionary *TInAppFrameResult(TTerminalView *terminal,NSUInteger frames){NSBitmapImageRep *bitmap=[terminal bitmapImageRepForCachingDisplayInRect:terminal.bounds];if(!bitmap)return @{@"p50":@0,@"p95":@0,@"fps":@0};double *times=calloc(frames,sizeof(double));for(NSUInteger i=0;i<frames;i++){@autoreleasepool{CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();[terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];times[i]=(CFAbsoluteTimeGetCurrent()-start)*1000.0;}}double p50=TMedianDoubles(times,frames),p95=times[(NSUInteger)floor((frames-1)*0.95)],fps=p50>0?1000.0/p50:0;free(times);return @{@"p50":@(p50),@"p95":@(p95),@"fps":@(fps)};}
static NSDictionary *TRunInAppBenchmark(TConfig *config,TTerminalView *active,NSUInteger windows,NSUInteger terminals){@autoreleasepool{
    double memoryBefore=TAppFootprintMiB();NSUInteger bytes=1024*1024;NSDictionary *patterns=@{@"ASCII":@"benchmark plain terminal text 0123456789 abcdefghijklmnopqrstuvwxyz\r\n",@"Unicode":@"Unicode λ漢字🙂 composed é emoji 👩‍💻\r\n",@"Dense":@"\033[38;5;45mA\033[48;5;234mB\033[1mC\033[4mD\033[0m",@"CSI":@"\033[38;2;89;194;255mcyan\033[0m \033[1mbold\033[0m \033[4:3munderline\033[0m \033[2Kbenchmark\r\n",@"Scrolling":@"\033[2;20rbenchmark scrolling row 0123456789 abcdefghijklmnopqrstuvwxyz\r\n"};NSMutableDictionary *rates=[NSMutableDictionary dictionary];for(NSString *name in @[@"ASCII",@"Unicode",@"Dense",@"CSI",@"Scrolling"]){NSData *data=TBenchmarkPattern(patterns[name],bytes);rates[name]=@(TInAppThroughput(config,data));}
    TTerminalView *render=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,720,440) config:config deferPresentation:NO];[render consumeData:TBenchmarkPattern(patterns[@"Unicode"],128*1024)];NSDictionary *textFrame=TInAppFrameResult(render,20);
    uint8_t pixels[64*64*4];for(NSUInteger y=0;y<64;y++)for(NSUInteger x=0;x<64;x++){NSUInteger p=(y*64+x)*4;pixels[p]=(uint8_t)(x*4);pixels[p+1]=(uint8_t)(y*4);pixels[p+2]=0xD0;pixels[p+3]=0xFF;}CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef ctx=CGBitmapContextCreate(pixels,64,64,8,64*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGImageRef image=ctx?CGBitmapContextCreateImage(ctx):NULL;if(image){[render renderImage:image atRow:1 col:1 width:0 height:0 scale:NO];CGImageRelease(image);}if(ctx)CGContextRelease(ctx);if(cs)CGColorSpaceRelease(cs);NSDictionary *imageFrame=TInAppFrameResult(render,20);NSDictionary *state=active.diagnosticState;NSScreen *screen=active.window.screen?:NSScreen.mainScreen;NSUInteger displayFPS=[screen respondsToSelector:@selector(maximumFramesPerSecond)]?screen.maximumFramesPerSecond:60;double memoryAfter=TAppFootprintMiB();NSString *build=[NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] description]?:@"unknown";
    NSDictionary *metadata=@{@"Version":[NSString stringWithFormat:@"%@ (build %@)",TCurrentVersion(),build],@"Config":TActiveConfigName(config),@"Renderer":state[@"renderer"]?:config.renderer,@"Font":[NSString stringWithFormat:@"%@ %.1f",config.fontName,config.fontSize],@"Display":[NSString stringWithFormat:@"%lu Hz",(unsigned long)displayFPS],@"Memory":[NSString stringWithFormat:@"%.1f -> %.1f MiB",memoryBefore,memoryAfter],@"Open state":[NSString stringWithFormat:@"%lu window(s), %lu terminal(s), unchanged",(unsigned long)windows,(unsigned long)terminals]};
    NSArray *metrics=@[
      @{@"workload":@"ASCII parser/model",@"rate":[NSString stringWithFormat:@"%.1f MiB/s",[rates[@"ASCII"] doubleValue]]},
      @{@"workload":@"Unicode parser/model",@"rate":[NSString stringWithFormat:@"%.1f MiB/s",[rates[@"Unicode"] doubleValue]]},
      @{@"workload":@"Dense cells/model",@"rate":[NSString stringWithFormat:@"%.1f MiB/s",[rates[@"Dense"] doubleValue]]},
      @{@"workload":@"CSI parser/model",@"rate":[NSString stringWithFormat:@"%.1f MiB/s",[rates[@"CSI"] doubleValue]]},
      @{@"workload":@"Scrolling region/model",@"rate":[NSString stringWithFormat:@"%.1f MiB/s",[rates[@"Scrolling"] doubleValue]]},
      @{@"workload":@"Offscreen text paint",@"rate":[NSString stringWithFormat:@"%.1f FPS",[textFrame[@"fps"] doubleValue]],@"p50":[NSString stringWithFormat:@"%.3f ms",[textFrame[@"p50"] doubleValue]],@"p95":[NSString stringWithFormat:@"%.3f ms",[textFrame[@"p95"] doubleValue]]},
      @{@"workload":@"Offscreen image paint",@"rate":[NSString stringWithFormat:@"%.1f FPS",[imageFrame[@"fps"] doubleValue]],@"p50":[NSString stringWithFormat:@"%.3f ms",[imageFrame[@"p50"] doubleValue]],@"p95":[NSString stringWithFormat:@"%.3f ms",[imageFrame[@"p95"] doubleValue]]}
    ];return @{@"ok":@YES,@"report":@{@"metadata":metadata,@"metrics":metrics}};}}

@interface TBenchmarkResultsController : NSWindowController
@property NSArray<NSDictionary *> *comparisonRows;
@property NSArray<NSDictionary *> *currentRows;
@property NSArray<NSDictionary *> *statusRows;
@property NSTextView *comparisonTextView;
- (instancetype)initWithArtifactPath:(NSString *)path current:(NSDictionary *)current;
- (NSDictionary *)diagnostics;
@end

static NSArray<NSArray<NSString *> *> *TReadBenchmarkTSV(NSString *path) {
    NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];if(!data||data.length>1048576)return @[];NSString *text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];if(!text)return @[];NSMutableArray *rows=[NSMutableArray array];for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){if(!line.length)continue;[rows addObject:[line componentsSeparatedByString:@"\t"]];}return rows;
}
static NSString *TBenchmarkDisplayName(NSString *name) {NSDictionary *names=@{@"termatica":@"Termatica",@"kitty":@"Kitty",@"ghostty":@"Ghostty",@"alacritty":@"Alacritty",@"wezterm":@"WezTerm",@"rio":@"Rio"};return names[name.lowercaseString]?:name;}
static NSString *TBenchmarkDisplayTime(NSString *stamp) {if(stamp.length==16&&[stamp characterAtIndex:8]=='T'&&[stamp characterAtIndex:15]=='Z')return [NSString stringWithFormat:@"%@-%@-%@ %@:%@Z",[stamp substringWithRange:NSMakeRange(0,4)],[stamp substringWithRange:NSMakeRange(4,2)],[stamp substringWithRange:NSMakeRange(6,2)],[stamp substringWithRange:NSMakeRange(9,2)],[stamp substringWithRange:NSMakeRange(11,2)]];return stamp?:@"";}
static NSString *TBenchmarkRepeat(NSString *value,NSUInteger count){return [@"" stringByPaddingToLength:count withString:value startingAtIndex:0];}
static NSString *TBenchmarkPad(NSString *value,NSUInteger width,BOOL right){value=value?:@"";if(value.length>=width)return value;NSString *padding=TBenchmarkRepeat(@" ",width-value.length);return right?[padding stringByAppendingString:value]:[value stringByAppendingString:padding];}
static void TBenchmarkAppend(NSMutableAttributedString *output,NSString *value,BOOL bold){NSFont *font=[NSFont monospacedSystemFontOfSize:11 weight:bold?NSFontWeightBold:NSFontWeightRegular];[output appendAttributedString:[[NSAttributedString alloc]initWithString:value attributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:NSColor.labelColor}]];}
static double TBenchmarkGeo(NSArray<NSString *> *values){double total=0;NSUInteger count=0;for(NSString *value in values){double number=value.doubleValue;if(number>0){total+=log(number);count++;}}return count==values.count&&count?exp(total/count):0;}
static NSAttributedString *TBenchmarkComparisonText(NSArray<NSDictionary *> *rows,NSArray<NSDictionary *> *statusRows){
    NSArray *keys=@[@"termatica",@"kitty",@"ghostty",@"alacritty",@"wezterm",@"rio"],*headers=@[@"TERM",@"ASCII",@"UNICODE",@"GRAPHEME",@"CSI",@"ESCAPES",@"IMAGES",@"GEO"];NSMutableAttributedString *output=[NSMutableAttributedString new];NSMutableDictionary *geos=[NSMutableDictionary dictionary];
    for(NSString *mode in @[@"parser",@"render"]){NSArray *modeRows=[rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [row[@"mode"] isEqual:mode];}]];if(!modeRows.count)continue;NSMutableArray *table=[NSMutableArray array];for(NSString *key in keys){NSMutableArray *values=[NSMutableArray array];for(NSDictionary *row in modeRows)[values addObject:row[key]?:@"n/a"];double geo=TBenchmarkGeo(values);geos[[NSString stringWithFormat:@"%@:%@",mode,key]]=geo?@(geo):@0;NSMutableArray *cells=[NSMutableArray arrayWithObject:TBenchmarkDisplayName(key)];[cells addObjectsFromArray:values];[cells addObject:geo?[NSString stringWithFormat:@"%.1f",geo]:@"n/a"];[table addObject:cells];}NSUInteger widths[8]={0};double maximums[8]={0};for(NSUInteger column=0;column<8;column++){widths[column]=[headers[column] length];for(NSArray *cells in table){widths[column]=MAX(widths[column],[cells[column] length]);if(column&&![cells[column] isEqual:@"n/a"])maximums[column]=MAX(maximums[column],[cells[column] doubleValue]);}}TBenchmarkAppend(output,[[mode uppercaseString] stringByAppendingString:@" - MiB/s\n"],YES);for(NSUInteger column=0;column<8;column++){if(column)TBenchmarkAppend(output,@" |",NO);TBenchmarkAppend(output,TBenchmarkPad(headers[column],widths[column],column>0),YES);}TBenchmarkAppend(output,@"\n",NO);for(NSUInteger column=0;column<8;column++){if(column)TBenchmarkAppend(output,@"+",NO);TBenchmarkAppend(output,TBenchmarkRepeat(@"-",widths[column]+(column?1:0)),NO);}TBenchmarkAppend(output,@"\n",NO);for(NSArray *cells in table){for(NSUInteger column=0;column<8;column++){if(column)TBenchmarkAppend(output,@" |",NO);BOOL winner=column>0&&![cells[column] isEqual:@"n/a"]&&maximums[column]>0&&fabs([cells[column] doubleValue]-maximums[column])<0.0001;TBenchmarkAppend(output,TBenchmarkPad(cells[column],widths[column],column>0),winner);}TBenchmarkAppend(output,@"\n",NO);}TBenchmarkAppend(output,@"\n",NO);}
    NSDictionary *summary=nil;for(NSDictionary *row in rows)if([row[@"mode"] isEqual:@"summary"]){summary=row;break;}if(summary){NSArray *summaryHeaders=@[@"TERM",@"PARSE",@"RENDER",@"MB/s",@"MS/MiB",@"SCORE",@"SRC"];NSMutableArray *table=[NSMutableArray array];double maximum=0;for(NSString *key in keys)maximum=MAX(maximum,[summary[key] doubleValue]);for(NSString *key in keys){double combined=[summary[key] doubleValue],parse=[geos[[NSString stringWithFormat:@"parser:%@",key]] doubleValue],render=[geos[[NSString stringWithFormat:@"render:%@",key]] doubleValue];NSString *source=@"NONE";for(NSDictionary *status in statusRows)if([status[@"terminal"] isEqual:TBenchmarkDisplayName(key)]){source=status[@"source"]?:source;break;}[table addObject:@[TBenchmarkDisplayName(key),parse?[NSString stringWithFormat:@"%.1f",parse]:@"n/a",render?[NSString stringWithFormat:@"%.1f",render]:@"n/a",combined?[NSString stringWithFormat:@"%.1f",combined]:@"n/a",combined?[NSString stringWithFormat:@"%.2f",1000.0/combined]:@"n/a",combined&&maximum?[NSString stringWithFormat:@"%.0f",100.0*combined/maximum]:@"n/a",source]];}NSUInteger widths[7]={0};for(NSUInteger column=0;column<7;column++){widths[column]=[summaryHeaders[column] length];for(NSArray *cells in table)widths[column]=MAX(widths[column],[cells[column] length]);}TBenchmarkAppend(output,@"SUMMARY - 12-workload geometric mean\n",YES);for(NSUInteger column=0;column<7;column++){if(column)TBenchmarkAppend(output,@" |",NO);TBenchmarkAppend(output,TBenchmarkPad(summaryHeaders[column],widths[column],column>0),YES);}TBenchmarkAppend(output,@"\n",NO);for(NSUInteger column=0;column<7;column++){if(column)TBenchmarkAppend(output,@"+",NO);TBenchmarkAppend(output,TBenchmarkRepeat(@"-",widths[column]+(column?1:0)),NO);}TBenchmarkAppend(output,@"\n",NO);for(NSArray *cells in table){BOOL winner=maximum>0&&fabs([cells[3] doubleValue]-maximum)<0.0001;for(NSUInteger column=0;column<7;column++){if(column)TBenchmarkAppend(output,@" |",NO);TBenchmarkAppend(output,TBenchmarkPad(cells[column],widths[column],column>0),winner);}TBenchmarkAppend(output,@"\n",NO);}}
    if(!output.length)TBenchmarkAppend(output,@"No benchmark results were found in this artifact.\n",NO);return output;
}

@implementation TBenchmarkResultsController
- (NSTextField *)label:(NSString *)text bold:(BOOL)bold alignment:(NSTextAlignment)alignment {NSTextField *label=[NSTextField labelWithString:text?:@""];label.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:bold?NSFontWeightBold:NSFontWeightRegular];label.alignment=alignment;label.lineBreakMode=NSLineBreakByTruncatingTail;label.maximumNumberOfLines=1;return label;}
- (NSGridView *)gridWithRows:(NSArray<NSArray<NSView *> *> *)rows widths:(NSArray<NSNumber *> *)widths {NSGridView *grid=[NSGridView gridViewWithViews:rows];grid.rowSpacing=7;grid.columnSpacing=12;grid.xPlacement=NSGridCellPlacementFill;grid.yPlacement=NSGridCellPlacementCenter;NSInteger columns=MIN((NSInteger)widths.count,grid.numberOfColumns);for(NSInteger index=0;index<columns;index++)[grid columnAtIndex:index].width=widths[(NSUInteger)index].doubleValue;for(NSInteger index=0;index<grid.numberOfRows;index++){[grid rowAtIndex:index].topPadding=2;[grid rowAtIndex:index].bottomPadding=2;}return grid;}
- (NSView *)holderForGrid:(NSGridView *)grid {NSView *holder=[NSView new];grid.translatesAutoresizingMaskIntoConstraints=NO;[holder addSubview:grid];[NSLayoutConstraint activateConstraints:@[[grid.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor constant:14],[grid.topAnchor constraintEqualToAnchor:holder.topAnchor constant:14],[grid.trailingAnchor constraintLessThanOrEqualToAnchor:holder.trailingAnchor constant:-14],[grid.bottomAnchor constraintLessThanOrEqualToAnchor:holder.bottomAnchor constant:-14]]];return holder;}
- (instancetype)initWithArtifactPath:(NSString *)path current:(NSDictionary *)current {
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,660,430) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];if(!(self=[super initWithWindow:window]))return nil;window.title=@"Termatica Benchmark Results";window.minSize=NSMakeSize(560,360);window.releasedWhenClosed=NO;
    NSArray *matrix=TReadBenchmarkTSV([path stringByAppendingPathComponent:@"matrix.tsv"]);NSMutableArray *comparison=[NSMutableArray array];for(NSUInteger index=1;index<matrix.count;index++){NSArray *fields=matrix[index];if(fields.count<8)continue;[comparison addObject:@{@"mode":fields[0],@"workload":fields[1],@"termatica":fields[2],@"kitty":fields[3],@"ghostty":fields[4],@"alacritty":fields[5],@"wezterm":fields[6],@"rio":fields[7]}];}self.comparisonRows=comparison;
    NSArray *manifest=TReadBenchmarkTSV([path stringByAppendingPathComponent:@"manifest.tsv"]);NSMutableArray *status=[NSMutableArray array];for(NSArray *fields in manifest){if(fields.count<5||[@[@"timestamp_utc",@"repetitions",@"font",@"mode"] containsObject:fields[0]])continue;[status addObject:@{@"terminal":TBenchmarkDisplayName(fields[0]),@"status":fields[1],@"source":fields[2],@"measured":TBenchmarkDisplayTime(fields[3]),@"version":fields[4]}];}self.statusRows=status;
    NSMutableArray *currentRows=[NSMutableArray array];NSDictionary *metadata=[current[@"metadata"] isKindOfClass:NSDictionary.class]?current[@"metadata"]:@{};for(NSString *key in @[@"Version",@"Config",@"Renderer",@"Font",@"Display",@"Memory",@"Open state"])if(metadata[key])[currentRows addObject:@{@"field":key,@"rate":[metadata[key] description],@"p50":@"",@"p95":@""}];for(NSDictionary *metric in [current[@"metrics"] isKindOfClass:NSArray.class]?current[@"metrics"]:@[])if([metric isKindOfClass:NSDictionary.class])[currentRows addObject:@{@"field":metric[@"workload"]?:@"",@"rate":metric[@"rate"]?:@"",@"p50":metric[@"p50"]?:@"",@"p95":metric[@"p95"]?:@""}];self.currentRows=currentRows;
    NSTabView *tabs=[[NSTabView alloc]initWithFrame:window.contentView.bounds];tabs.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    NSTabViewItem *comparisonItem=[[NSTabViewItem alloc]initWithIdentifier:@"Comparison"];comparisonItem.label=@"Comparison";NSScrollView *comparisonScroll=[[NSScrollView alloc]initWithFrame:NSZeroRect];comparisonScroll.hasVerticalScroller=YES;comparisonScroll.hasHorizontalScroller=YES;comparisonScroll.autohidesScrollers=YES;comparisonScroll.borderType=NSNoBorder;self.comparisonTextView=[[NSTextView alloc]initWithFrame:NSMakeRect(0,0,900,600)];self.comparisonTextView.editable=NO;self.comparisonTextView.selectable=YES;self.comparisonTextView.drawsBackground=NO;self.comparisonTextView.textContainerInset=NSMakeSize(14,12);self.comparisonTextView.horizontallyResizable=YES;self.comparisonTextView.verticallyResizable=YES;self.comparisonTextView.autoresizingMask=NSViewWidthSizable;self.comparisonTextView.maxSize=NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);self.comparisonTextView.textContainer.containerSize=NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);self.comparisonTextView.textContainer.widthTracksTextView=NO;self.comparisonTextView.textStorage.attributedString=TBenchmarkComparisonText(self.comparisonRows,self.statusRows);comparisonScroll.documentView=self.comparisonTextView;comparisonItem.view=comparisonScroll;[tabs addTabViewItem:comparisonItem];
    NSMutableArray *currentViews=[NSMutableArray arrayWithObject:@[[self label:@"Field / workload" bold:YES alignment:NSTextAlignmentLeft],[self label:@"Value / rate" bold:YES alignment:NSTextAlignmentLeft],[self label:@"P50" bold:YES alignment:NSTextAlignmentRight],[self label:@"P95" bold:YES alignment:NSTextAlignmentRight]]];for(NSDictionary *row in self.currentRows)[currentViews addObject:@[[self label:row[@"field"] bold:NO alignment:NSTextAlignmentLeft],[self label:row[@"rate"] bold:NO alignment:NSTextAlignmentLeft],[self label:row[@"p50"] bold:NO alignment:NSTextAlignmentRight],[self label:row[@"p95"] bold:NO alignment:NSTextAlignmentRight]]];NSGridView *currentGrid=[self gridWithRows:currentViews widths:@[@210,@220,@75,@75]];NSTabViewItem *currentItem=[[NSTabViewItem alloc]initWithIdentifier:@"Current App"];currentItem.label=@"Current App";currentItem.view=[self holderForGrid:currentGrid];[tabs addTabViewItem:currentItem];
    NSMutableArray *statusViews=[NSMutableArray arrayWithObject:@[[self label:@"Terminal" bold:YES alignment:NSTextAlignmentLeft],[self label:@"Status" bold:YES alignment:NSTextAlignmentLeft],[self label:@"Source" bold:YES alignment:NSTextAlignmentLeft],[self label:@"Measured UTC" bold:YES alignment:NSTextAlignmentLeft],[self label:@"Version" bold:YES alignment:NSTextAlignmentLeft]]];for(NSDictionary *row in self.statusRows)[statusViews addObject:@[[self label:row[@"terminal"] bold:NO alignment:NSTextAlignmentLeft],[self label:row[@"status"] bold:NO alignment:NSTextAlignmentLeft],[self label:row[@"source"] bold:NO alignment:NSTextAlignmentLeft],[self label:row[@"measured"] bold:NO alignment:NSTextAlignmentLeft],[self label:row[@"version"] bold:NO alignment:NSTextAlignmentLeft]]];NSGridView *statusGrid=[self gridWithRows:statusViews widths:@[@90,@70,@65,@140,@220]];NSTabViewItem *statusItem=[[NSTabViewItem alloc]initWithIdentifier:@"Run Status"];statusItem.label=@"Run Status";statusItem.view=[self holderForGrid:statusGrid];[tabs addTabViewItem:statusItem];
    [window.contentView addSubview:tabs];[window center];return self;
}
- (NSDictionary *)diagnostics {NSString *text=self.comparisonTextView.string?:@"";return @{@"ok":@YES,@"comparisonRows":@(self.comparisonRows.count),@"statusRows":@(self.statusRows.count),@"currentRows":@(self.currentRows.count),@"textLength":@(text.length),@"textWidth":@(self.comparisonTextView.frame.size.width),@"textHeight":@(self.comparisonTextView.frame.size.height),@"containsParser":@([text containsString:@"PARSER"]),@"containsRender":@([text containsString:@"RENDER"]),@"containsSummary":@([text containsString:@"SUMMARY"])};}
@end

static void TApplyMenuShortcut(NSMenuItem *item,NSString *spec) {if(!spec.length){item.keyEquivalent=@"";item.keyEquivalentModifierMask=0;return;}NSArray<NSString *> *parts=[spec.lowercaseString componentsSeparatedByString:@"+"];NSEventModifierFlags mask=0;NSString *key=parts.lastObject;for(NSString *part in parts){if([part isEqual:@"cmd"]||[part isEqual:@"command"])mask|=NSEventModifierFlagCommand;else if([part isEqual:@"shift"])mask|=NSEventModifierFlagShift;else if([part isEqual:@"option"]||[part isEqual:@"alt"])mask|=NSEventModifierFlagOption;else if([part isEqual:@"control"]||[part isEqual:@"ctrl"])mask|=NSEventModifierFlagControl;}if([key isEqual:@"plus"])key=@"+";else if([key isEqual:@"space"])key=@" ";item.keyEquivalent=key?:@"";item.keyEquivalentModifierMask=mask;}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@interface TAppDelegate : NSObject <NSApplicationDelegate,NSUserNotificationCenterDelegate>
@property TConfig *config;
@property TExtensionHost *extensions;
@property NSMutableArray<TWindowController *> *windows;
@property TBenchmarkResultsController *benchmarkResults;
- (TWindowController *)active;
@end

@interface TApplication : NSApplication
@end

@implementation TApplication
- (void)sendEvent:(NSEvent *)event {
    if(event.type==NSEventTypeScrollWheel){NSWindow *target=event.window?:NSApp.keyWindow;TWindowController *controller=[target.windowController isKindOfClass:TWindowController.class]?(TWindowController *)target.windowController:[(TAppDelegate *)self.delegate active];if(controller&&target==controller.window&&[controller routeScrollEvent:event])return;}
    if(event.type==NSEventTypeKeyDown){NSEventModifierFlags mods=event.modifierFlags&NSEventModifierFlagDeviceIndependentFlagsMask,command=NSEventModifierFlagCommand,commandShift=NSEventModifierFlagCommand|NSEventModifierFlagShift,relevant=mods&(NSEventModifierFlagCommand|NSEventModifierFlagShift|NSEventModifierFlagOption|NSEventModifierFlagControl);NSString *key=event.charactersIgnoringModifiers.lowercaseString;if(event.isARepeat&&[key isEqual:@"t"]&&(relevant==command||relevant==commandShift))return;if(relevant==commandShift&&[key isEqual:@"t"]&&[self sendAction:@selector(newVerticalTab:) to:self.delegate from:self])return;if(relevant==command){if([key isEqual:@"t"]&&[self sendAction:@selector(newTab:) to:self.delegate from:self])return;if([key isEqual:@"w"]&&[self sendAction:@selector(closeTab:) to:self.delegate from:self])return;if([key isEqual:@"k"]&&[self sendAction:@selector(clearTerminal:) to:self.delegate from:self])return;if(key.length==1&&[key characterAtIndex:0]>='1'&&[key characterAtIndex:0]<='9'){NSMenuItem *sender=[NSMenuItem new];sender.tag=[key integerValue];if([self sendAction:@selector(selectTab:) to:self.delegate from:sender])return;}}if(!(mods&NSEventModifierFlagCommand)){NSWindow *target=event.window?:NSApp.keyWindow;TWindowController *controller=[target.windowController isKindOfClass:TWindowController.class]?(TWindowController *)target.windowController:[(TAppDelegate *)self.delegate active];if(controller&&target==controller.window){[controller routeKeyEvent:event];return;}}}
    [super sendEvent:event];
}
@end

@implementation TAppDelegate {int _cliSocket;dispatch_source_t _cliSource;}
- (void)startCLIListener {_cliSocket=socket(AF_UNIX,SOCK_DGRAM,0);if(_cliSocket<0){TLog(@"CLI socket creation failed");return;}NSString *path=TCLISocketPath();if(!TRemoveOwnedSocket(path)){TLog(@"refusing to replace untrusted CLI socket at %@",path);close(_cliSocket);_cliSocket=-1;return;}struct sockaddr_un address={0};address.sun_family=AF_UNIX;strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path));address.sun_len=(uint8_t)(offsetof(struct sockaddr_un,sun_path)+strlen(address.sun_path)+1);if(bind(_cliSocket,(struct sockaddr *)&address,address.sun_len)<0){TLog(@"CLI socket bind failed: %s",strerror(errno));close(_cliSocket);_cliSocket=-1;return;}chmod(path.fileSystemRepresentation,0600);fcntl(_cliSocket,F_SETFL,O_NONBLOCK);fcntl(_cliSocket,F_SETFD,FD_CLOEXEC);int socketFD=_cliSocket;_cliSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,(uintptr_t)socketFD,0,dispatch_get_main_queue());__weak typeof(self) weakSelf=self;dispatch_source_set_event_handler(_cliSource,^{uint8_t buffer[8192];ssize_t size=0;while((size=recv(socketFD,buffer,sizeof(buffer),0))>0){NSDictionary *request=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buffer length:(NSUInteger)size] options:0 error:nil];if([request isKindOfClass:NSDictionary.class])[weakSelf handleCLIRequest:request];}});dispatch_source_set_cancel_handler(_cliSource,^{close(socketFD);TRemoveOwnedSocket(path);});dispatch_resume(_cliSource);TLog(@"CLI socket listening at %@ with mode 0600",path);}
- (void)checkForUpdatesOnLaunch {
    if(!self.config.updateCheckOnLaunch||!self.config.updateRepository.length)return;NSString *repository=[self.config.updateRepository copy];dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *error=nil;NSDictionary *release=TLatestRelease(repository,&error);NSString *tag=release[@"tag_name"];if(!tag||TCompareVersions(tag,TCurrentVersion())!=NSOrderedDescending){if(error)TLog(@"launch update check failed: %@",error.localizedDescription);return;}TLog(@"launch update check found %@",tag);dispatch_async(dispatch_get_main_queue(),^{NSUserNotification *notice=[NSUserNotification new];notice.title=[NSString stringWithFormat:@"Termatica %@ is available",tag];notice.informativeText=@"Click Install Now to download, verify, and install it.";notice.soundName=NSUserNotificationDefaultSoundName;notice.hasActionButton=YES;notice.actionButtonTitle=@"Install Now";notice.otherButtonTitle=@"Later";notice.userInfo=@{@"tag":tag,@"repository":repository};NSUserNotificationCenter.defaultUserNotificationCenter.delegate=self;[NSUserNotificationCenter.defaultUserNotificationCenter deliverNotification:notice];NSApp.dockTile.badgeLabel=@"UP";TWindowController *controller=[self active];controller.window.title=[NSString stringWithFormat:@"Termatica · %@ available",tag];});});
}
- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification {if(notification.activationType==NSUserNotificationActivationTypeActionButtonClicked){NSString *cliPath=[NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent];cliPath=[cliPath stringByAppendingPathComponent:@"termatica"];NSTask *task=[[NSTask alloc]init];task.launchPath=cliPath;task.arguments=@[@"update"];[task launch];}}
- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification{return YES;}
#pragma clang diagnostic pop
- (void)applicationDidFinishLaunching:(NSNotification *)notification {TLog(@"application delegate started");_cliSocket=-1;_config=[TConfig new];TLog(@"configuration ready");_windows=[NSMutableArray array];TWindowController *controller=[[TWindowController alloc]initWithConfig:self.config extensions:nil];[self.windows addObject:controller];controller.window.initialFirstResponder=controller.terminal;[controller.window makeFirstResponder:controller.terminal];[controller showWindow:nil];dispatch_async(dispatch_get_main_queue(),^{[controller animateLaunchReveal];});_extensions=[TExtensionHost new];_extensions.config=_config;controller.extensions=_extensions;_extensions.activeTerminal=controller.terminal;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{TInstallConfiguredPlugins(self.config);[self.config reload];[self buildMenu];[self startCLIListener];[self.extensions loadExtensions];[self startConfigWatcher];});dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self checkForUpdatesOnLaunch];});}
- (void)startConfigWatcher {NSString *path=_config.path;int fd=open(path.fileSystemRepresentation,O_EVTONLY);if(fd<0)return;dispatch_source_t src=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,fd,DISPATCH_VNODE_DELETE|DISPATCH_VNODE_WRITE|DISPATCH_VNODE_REVOKE,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));__weak typeof(self) weakSelf=self;__block dispatch_source_t prev=nil;dispatch_source_set_event_handler(src,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self reloadAll];});if(prev)dispatch_cancel(prev);prev=src;});dispatch_source_set_cancel_handler(src,^{close(fd);});dispatch_resume(src);}
- (void)applicationWillTerminate:(NSNotification *)notification {if(_cliSource){dispatch_source_cancel(_cliSource);_cliSource=nil;}else if(_cliSocket>=0){close(_cliSocket);TRemoveOwnedSocket(TCLISocketPath());_cliSocket=-1;}}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
- (void)newWindow:(id)sender {TWindowController *controller=[[TWindowController alloc]initWithConfig:self.config extensions:self.extensions];[self.windows addObject:controller];controller.window.initialFirstResponder=controller.terminal;[controller.window makeFirstResponder:controller.terminal];[controller animateLaunchReveal];[controller showWindow:nil];}
- (TWindowController *)active {return (TWindowController *)NSApp.keyWindow.windowController?:self.windows.lastObject;}
- (void)newTab:(id)sender {TLog(@"new tab shortcut");[[self active] addTab];}
- (void)newVerticalTab:(id)sender {TLog(@"new vertical terminal shortcut");[[self active] addVerticalTab];}
- (void)closeTab:(id)sender {TLog(@"close tab shortcut");[[self active] closeTab];}
- (void)selectTab:(NSMenuItem *)sender {[[self active] selectTabNumber:sender.tag];}
- (void)reloadConfig:(id)sender{[self reloadAll];}
- (void)clearTerminal:(id)sender{TLog(@"clear scrollback while preserving prompt");[[self active].terminal clearScrollbackPreservingPrompt];}
- (void)zoomIn:(id)sender{self.config.fontSize=MIN(48,self.config.fontSize+1);for(TTerminalView *terminal in [self active].terminals)[terminal reloadAppearance];}
- (void)zoomOut:(id)sender{self.config.fontSize=MAX(8,self.config.fontSize-1);for(TTerminalView *terminal in [self active].terminals)[terminal reloadAppearance];}
- (void)zoomReset:(id)sender{self.config.fontSize=11;for(TTerminalView *terminal in [self active].terminals)[terminal reloadAppearance];}
- (void)previousPrompt:(id)sender{[[self active].terminal jumpToPromptDirection:-1];}
- (void)searchScrollback:(id)sender{[[self active].terminal searchScrollback];}
- (void)splitHorizontal:(id)sender{[[self active] addTabWithVerticalSplit:NO];}
- (void)splitVertical:(id)sender{[[self active] addTabWithVerticalSplit:YES];}
- (void)nextSplit:(id)sender{TWindowController *wc=[self active];if(wc){NSUInteger idx=[wc.terminals indexOfObject:wc.terminal];if(idx!=NSNotFound&&idx+1<wc.terminals.count){wc.terminal=wc.terminals[idx+1];[wc focusTerminal:wc.terminal];}}}
- (void)previousSplit:(id)sender{TWindowController *wc=[self active];if(wc){NSUInteger idx=[wc.terminals indexOfObject:wc.terminal];if(idx!=NSNotFound&&idx>0){wc.terminal=wc.terminals[idx-1];[wc focusTerminal:wc.terminal];}}}
- (void)nextPrompt:(id)sender{[[self active].terminal jumpToPromptDirection:1];}
- (void)openConfig:(id)sender{[[self active].terminal sendString:@"termatica config\n"];}
- (void)reloadAll {NSDictionary *priorBindings=self.config.keybindings;[self.config ensureEditableFile];[self.config reload];TInstallConfiguredPlugins(self.config);[self.config reload];if(![priorBindings isEqualToDictionary:self.config.keybindings])[self buildMenu];[self.extensions loadExtensions];for(TWindowController *window in self.windows)[window reloadConfig];}
- (void)handleCLIRequest:(NSDictionary *)request {NSString *command=request[@"command"];if([command isEqual:@"reload"])[self reloadAll];else if([command isEqual:@"activate"]){[NSApp activateIgnoringOtherApps:YES];TWindowController *controller=[self active];[controller.window makeKeyAndOrderFront:nil];[controller.window makeFirstResponder:controller.terminal];}else if([command isEqual:@"run"]&&![[self active] executeExtensionNamed:request[@"name"] query:request[@"query"]])TLog(@"extension command not found: %@",request[@"name"]);else if([command isEqual:@"benchmark"]){TWindowController *controller=[self active];NSUInteger terminals=0;for(TWindowController *window in self.windows)terminals+=window.terminals.count;NSDictionary *reply=controller?TRunInAppBenchmark(self.config,controller.terminal,self.windows.count,terminals):@{@"ok":@NO};TSendCLIReply(request[@"replyPath"],reply);}else if([command isEqual:@"showBenchmark"]){NSString *path=[request[@"artifactPath"] isKindOfClass:NSString.class]?request[@"artifactPath"]:nil;BOOL directory=NO;if(path.length&&[NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory]&&directory){self.benchmarkResults=[[TBenchmarkResultsController alloc]initWithArtifactPath:path current:[request[@"current"] isKindOfClass:NSDictionary.class]?request[@"current"]:@{}];[NSApp activateIgnoringOtherApps:YES];[self.benchmarkResults showWindow:nil];[self.benchmarkResults.window makeKeyAndOrderFront:nil];}}else if([command isEqual:@"benchmarkDiagnostics"])TSendCLIReply(request[@"replyPath"],self.benchmarkResults?[self.benchmarkResults diagnostics]:@{@"ok":@NO,@"error":@"benchmark window is not open"});else if([command isEqual:@"quit"])[NSApp terminate:nil];}
- (void)buildMenu {
    NSDictionary *keys=self.config.keybindings;NSMenu *main=[NSMenu new];NSApp.mainMenu=main;
    NSMenuItem *appItem=[NSMenuItem new];[main addItem:appItem];NSMenu *app=[NSMenu new];appItem.submenu=app;[app addItemWithTitle:@"About Termatica" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];[app addItem:NSMenuItem.separatorItem];NSMenuItem *config=[app addItemWithTitle:@"Open Configuration…" action:@selector(openConfig:) keyEquivalent:@""];TApplyMenuShortcut(config,keys[@"openConfig"]);[app addItem:NSMenuItem.separatorItem];[app addItemWithTitle:@"Hide Termatica" action:@selector(hide:) keyEquivalent:@"h"];[app addItemWithTitle:@"Quit Termatica" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *shellItem=[NSMenuItem new];[main addItem:shellItem];NSMenu *shell=[[NSMenu alloc]initWithTitle:@"Shell"];shellItem.submenu=shell;NSMenuItem *newWindow=[shell addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@""];TApplyMenuShortcut(newWindow,keys[@"newWindow"]);NSMenuItem *newTab=[shell addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@""];TApplyMenuShortcut(newTab,keys[@"newTab"]);NSMenuItem *newVerticalTab=[shell addItemWithTitle:@"New Vertical Terminal" action:@selector(newVerticalTab:) keyEquivalent:@""];TApplyMenuShortcut(newVerticalTab,keys[@"newVerticalTab"]);NSMenuItem *closeTab=[shell addItemWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@""];TApplyMenuShortcut(closeTab,keys[@"closeTab"]);[shell addItem:NSMenuItem.separatorItem];NSMenuItem *clear=[shell addItemWithTitle:@"Clear Terminal" action:@selector(clearTerminal:) keyEquivalent:@""];TApplyMenuShortcut(clear,keys[@"clearTerminal"]);NSMenuItem *reload=[shell addItemWithTitle:@"Reload Configuration" action:@selector(reloadConfig:) keyEquivalent:@""];TApplyMenuShortcut(reload,keys[@"reload"]);[shell addItem:NSMenuItem.separatorItem];for(NSInteger i=1;i<=9;i++){NSMenuItem *tab=[shell addItemWithTitle:[NSString stringWithFormat:@"Select Tab %ld",(long)i] action:@selector(selectTab:) keyEquivalent:@""];tab.tag=i;tab.target=self;NSString *name=[NSString stringWithFormat:@"tab%ld",(long)i],*fallback=[NSString stringWithFormat:@"cmd+%ld",(long)i];TApplyMenuShortcut(tab,keys[name]?:fallback);}
    NSMenuItem *editItem=[NSMenuItem new];[main addItem:editItem];NSMenu *edit=[[NSMenu alloc]initWithTitle:@"Edit"];editItem.submenu=edit;NSMenuItem *copy=[edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];TApplyMenuShortcut(copy,keys[@"copy"]);NSMenuItem *paste=[edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];TApplyMenuShortcut(paste,keys[@"paste"]);NSMenuItem *selectAll=[edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@""];TApplyMenuShortcut(selectAll,keys[@"selectAll"]);
    NSMenuItem *viewItem=[NSMenuItem new];[main addItem:viewItem];NSMenu *view=[[NSMenu alloc]initWithTitle:@"View"];viewItem.submenu=view;NSMenuItem *zoomIn=[view addItemWithTitle:@"Increase Text Size" action:@selector(zoomIn:) keyEquivalent:@""];TApplyMenuShortcut(zoomIn,keys[@"zoomIn"]);NSMenuItem *zoomOut=[view addItemWithTitle:@"Decrease Text Size" action:@selector(zoomOut:) keyEquivalent:@""];TApplyMenuShortcut(zoomOut,keys[@"zoomOut"]);NSMenuItem *zoomReset=[view addItemWithTitle:@"Reset Text Size" action:@selector(zoomReset:) keyEquivalent:@""];TApplyMenuShortcut(zoomReset,keys[@"zoomReset"]);[view addItem:NSMenuItem.separatorItem];NSMenuItem *previousPrompt=[view addItemWithTitle:@"Previous Prompt" action:@selector(previousPrompt:) keyEquivalent:@""];TApplyMenuShortcut(previousPrompt,keys[@"previousPrompt"]);NSMenuItem *nextPrompt=[view addItemWithTitle:@"Next Prompt" action:@selector(nextPrompt:) keyEquivalent:@""];TApplyMenuShortcut(nextPrompt,keys[@"nextPrompt"]);NSMenuItem *search=[view addItemWithTitle:@"Search Scrollback" action:@selector(searchScrollback:) keyEquivalent:@""];TApplyMenuShortcut(search,keys[@"searchScrollback"]);NSMenuItem *splitH=[view addItemWithTitle:@"Split Horizontal" action:@selector(splitHorizontal:) keyEquivalent:@""];TApplyMenuShortcut(splitH,keys[@"splitHorizontal"]);NSMenuItem *splitV=[view addItemWithTitle:@"Split Vertical" action:@selector(splitVertical:) keyEquivalent:@""];TApplyMenuShortcut(splitV,keys[@"splitVertical"]);[view addItem:NSMenuItem.separatorItem];NSMenuItem *nextSplit=[view addItemWithTitle:@"Next Split" action:@selector(nextSplit:) keyEquivalent:@""];TApplyMenuShortcut(nextSplit,keys[@"nextSplit"]);NSMenuItem *prevSplit=[view addItemWithTitle:@"Previous Split" action:@selector(previousSplit:) keyEquivalent:@""];TApplyMenuShortcut(prevSplit,keys[@"previousSplit"]);
    for(NSMenuItem *item in main.itemArray)for(NSMenuItem *child in item.submenu.itemArray)if(child.action&&child.target==nil&&child.action!=@selector(copy:)&&child.action!=@selector(paste:)&&child.action!=@selector(selectAll:))child.target=self;
}
@end
#if TERMATICA_BENCHMARKS
static double TPercentile(double *values,NSUInteger count,double percentile);
static int TRunTerminalSelfTest(void) {
    [TApplication sharedApplication];
    TConfig *freshConfig=[TConfig new];freshConfig.oscIntegration=NO;TTerminalView *fresh=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,800,500) config:freshConfig];
    [fresh consumeData:[@"stale-row-a\r\nstale-row-b\r\n" dataUsingEncoding:NSUTF8StringEncoding]];[fresh setValue:@YES forKey:@"freshLaunchAwaitingPrompt"];
    [fresh consumeData:[@"\033]133;A\aCoding/Termatica ; " dataUsingEncoding:NSUTF8StringEncoding]];NSDictionary *freshState=fresh.diagnosticState;
    if([freshState[@"cursorY"] unsignedIntegerValue]!=0||[freshState[@"history"] unsignedIntegerValue]!=0||![[fresh visibleText] isEqual:@"Coding/Termatica ;"])return 50;
    [fresh consumeData:[@"\r\nsecond-prompt\033]133;A\a" dataUsingEncoding:NSUTF8StringEncoding]];if(![[fresh visibleText] containsString:@"Coding/Termatica ;\nsecond-prompt"])return 51;
    TTerminalView *wrapTerminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,800,500) config:freshConfig];NSUInteger wrapColumns=[wrapTerminal.diagnosticState[@"columns"] unsignedIntegerValue];NSMutableString *fullLine=[NSMutableString stringWithCapacity:wrapColumns];for(NSUInteger i=0;i<wrapColumns;i++)[fullLine appendString:@"W"];[fullLine appendString:@"\nX"];[wrapTerminal consumeData:[fullLine dataUsingEncoding:NSUTF8StringEncoding]];TRenderSnapshot *wrapSnapshot=wrapTerminal.renderSnapshot;if([wrapTerminal.diagnosticState[@"cursorY"] unsignedIntegerValue]!=1||wrapSnapshot.cursorX>=wrapSnapshot.metrics.columns)return 61;
    TTerminalView *regionTerminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,800,500) config:freshConfig];
    [regionTerminal consumeData:[@"\033[2J\033[1;1HTOP\033[2;4r\033[2;1HA\033[3;1HB\033[4;1HC\033[4;1H\n" dataUsingEncoding:NSUTF8StringEncoding]];
    TRenderSnapshot *regionSnapshot=regionTerminal.renderSnapshot;const TCell *regionCells=regionSnapshot.cells.bytes;NSUInteger regionColumns=regionSnapshot.metrics.columns;
    if(regionCells[0].ch!='T'||regionCells[regionColumns].ch!='B'||regionCells[2*regionColumns].ch!='C'||regionCells[3*regionColumns].ch!=' ')return 62;
    [regionTerminal consumeData:[@"\033[2;1H\033M" dataUsingEncoding:NSUTF8StringEncoding]];regionSnapshot=regionTerminal.renderSnapshot;regionCells=regionSnapshot.cells.bytes;regionColumns=regionSnapshot.metrics.columns;
    if(regionCells[0].ch!='T'||regionCells[regionColumns].ch!=' '||regionCells[2*regionColumns].ch!='B'||regionCells[3*regionColumns].ch!='C')return 63;
    TConfig *config=[TConfig new];config.scrollback=1000;config.unicodeRendering=YES;config.clipboardRead=@"deny";config.clipboardWrite=@"deny";
    TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,800,500) config:config];
    NSMutableString *lines=[NSMutableString string];for(NSUInteger i=0;i<240;i++)[lines appendFormat:@"scroll-line-%03lu\r\n",(unsigned long)i];
    [terminal consumeData:[lines dataUsingEncoding:NSUTF8StringEncoding]];TRenderSnapshot *renderSnapshot=[terminal renderSnapshot];if(renderSnapshot.cells.length!=renderSnapshot.metrics.rows*renderSnapshot.metrics.columns*sizeof(TCell)||renderSnapshot.generation==0)return 23;
    NSDictionary *initial=terminal.diagnosticState;if([initial[@"history"] unsignedIntegerValue]<100)return 1;
    [terminal scrollByLines:12];NSInteger offset=[terminal.diagnosticState[@"offset"] integerValue];if(offset!=12)return 2;
    [terminal consumeData:[@"anchored-a\r\nanchored-b\r\n" dataUsingEncoding:NSUTF8StringEncoding]];if([terminal.diagnosticState[@"offset"] integerValue]<=offset)return 3;
    [terminal scrollByLines:-100000];if([terminal.diagnosticState[@"offset"] integerValue]!=0)return 4;
    CGEventRef wheelEvent=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitLine,1,3);CGEventSetFlags(wheelEvent,0);NSEvent *wheel=[NSEvent eventWithCGEvent:wheelEvent];CFRelease(wheelEvent);[terminal routeWheelLines:3 event:wheel modifierFlags:0];
    if([terminal.diagnosticState[@"offset"] integerValue]<=0)return 5;[terminal scrollByLines:-100000];
    NSUInteger primaryHistory=[terminal.diagnosticState[@"history"] unsignedIntegerValue];
    NSMutableString *alternateLines=[NSMutableString stringWithString:@"PRIMARY-MARKER\033[?1049hALTERNATE-MARKER\r\n"];
    for(NSUInteger i=0;i<120;i++)[alternateLines appendFormat:@"alternate-line-%03lu\r\n",(unsigned long)i];
    [alternateLines appendString:@"\033[?1049l"];
    [terminal consumeData:[alternateLines dataUsingEncoding:NSUTF8StringEncoding]];
    if(![[terminal visibleText] containsString:@"PRIMARY-MARKER"]||[terminal.diagnosticState[@"alternate"] boolValue])return 6;
    if([terminal.diagnosticState[@"history"] unsignedIntegerValue]!=primaryHistory)return 24;
    [terminal consumeData:[@"\r\nREP:A\033[3b" dataUsingEncoding:NSUTF8StringEncoding]];
    if(![[terminal visibleText] containsString:@"REP:AAAA"])return 25;
    [terminal consumeData:[@"\033[?2026h" dataUsingEncoding:NSUTF8StringEncoding]];if(![terminal.diagnosticState[@"synchronizedUpdates"] boolValue])return 26;
    [terminal consumeData:[@"\033[?2026l\033]bsu\a" dataUsingEncoding:NSUTF8StringEncoding]];if(![terminal.diagnosticState[@"synchronizedUpdates"] boolValue])return 27;
    [terminal consumeData:[@"\033]esu\a" dataUsingEncoding:NSUTF8StringEncoding]];if([terminal.diagnosticState[@"synchronizedUpdates"] boolValue])return 28;
    [terminal consumeData:[@"\r\n\033[4:3;38;2;89;194;255mUNICODE:λ漢字🙂 e\u0301\033[0m" dataUsingEncoding:NSUTF8StringEncoding]];
    if(![[terminal visibleText] containsString:@"UNICODE:λ漢字🙂 e\u0301"])return 29;
    NSString *complexUnicode=@"\r\nGRAPHEME:🇦🇺 👩🏽‍💻 하 क्षि";[terminal consumeData:[complexUnicode dataUsingEncoding:NSUTF8StringEncoding]];
    if(![[terminal visibleText] containsString:@"GRAPHEME:🇦🇺 👩🏽‍💻 하 क्षि"])return 49;
    NSString *tinyPNG=@"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";[terminal consumeData:[[NSString stringWithFormat:@"\033]1337;File=inline=1:%@\a",tinyPNG] dataUsingEncoding:NSUTF8StringEncoding]];if(!terminal.renderSnapshot.images.count)return 32;
    NSUInteger baselineImages=terminal.renderSnapshot.images.count;[terminal consumeData:[@"\033[?1049h\033_Ga=T,f=32,s=1,v=1,i=101;/wAA/w==\033\\" dataUsingEncoding:NSUTF8StringEncoding]];[terminal waitForImageOperations];if(!terminal.renderSnapshot.images.count)return 66;[terminal consumeData:[@"\033[?1049l" dataUsingEncoding:NSUTF8StringEncoding]];[terminal waitForImageOperations];if(terminal.renderSnapshot.images.count!=baselineImages)return 67;
    [terminal consumeData:[@"\033_Ga=T,f=32,s=1,v=1,i=99,r=2,c=2;/wAA/w==\033\\" dataUsingEncoding:NSUTF8StringEncoding]];[terminal waitForImageOperations];if(terminal.renderSnapshot.images.count<=baselineImages)return 33;
    [terminal consumeData:[@"\033_Ga=d,i=99;\033\\" dataUsingEncoding:NSUTF8StringEncoding]];[terminal waitForImageOperations];if(terminal.renderSnapshot.images.count!=baselineImages)return 34;
    [terminal consumeData:[@"\033_Ga=t,f=32,s=1,v=1,i=100;/wAA/w==\033\\" dataUsingEncoding:NSUTF8StringEncoding]];if(terminal.renderSnapshot.images.count!=baselineImages)return 63;[terminal consumeData:[@"\033_Ga=p,i=100,r=3,c=3;\033\\" dataUsingEncoding:NSUTF8StringEncoding]];[terminal waitForImageOperations];if(terminal.renderSnapshot.images.count<=baselineImages)return 64;[terminal consumeData:[@"\033_Ga=d,i=100;\033\\" dataUsingEncoding:NSUTF8StringEncoding]];[terminal waitForImageOperations];if(terminal.renderSnapshot.images.count!=baselineImages)return 65;
    NSBitmapImageRep *validationBitmap=[terminal bitmapImageRepForCachingDisplayInRect:terminal.bounds];if(!validationBitmap)return 30;[terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:validationBitmap];
    const uint8_t *validationPixels=validationBitmap.bitmapData;NSUInteger validationBytes=validationBitmap.bytesPerRow*validationBitmap.pixelsHigh;BOOL variedPixels=NO;if(validationPixels&&validationBytes>=4){uint32_t firstPixel=0;memcpy(&firstPixel,validationPixels,sizeof(firstPixel));for(NSUInteger i=4;i+4<=validationBytes;i+=4){uint32_t pixel=0;memcpy(&pixel,validationPixels+i,sizeof(pixel));if(pixel!=firstPixel){variedPixels=YES;break;}}}if(!variedPixels)return 31;
    [terminal consumeData:[@"\033[>1u" dataUsingEncoding:NSUTF8StringEncoding]];
    if(![[terminal functionalKeySequenceForKeyCode:126 modifier:1] isEqual:@"\033[1;1A"])return 7;
    if(![[terminal functionalKeySequenceForKeyCode:125 modifier:2] isEqual:@"\033[1;2B"])return 8;
    NSEvent *up=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:126];
    [terminal startDiagnosticInputCapture];[terminal keyDown:up];
    if(![[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding] isEqual:@"\033[1;1A"])return 9;
    [terminal consumeData:[@"\033[<u\033[?1h" dataUsingEncoding:NSUTF8StringEncoding]];
    if(![[terminal functionalKeySequenceForKeyCode:123 modifier:1] isEqual:@"\033OD"])return 10;
    [terminal consumeData:[@"\033[<u" dataUsingEncoding:NSUTF8StringEncoding]];
    NSArray<NSDictionary *> *optionCases=@[@{@"key":@123,@"characters":@"",@"expected":@"\033b"},@{@"key":@124,@"characters":@"",@"expected":@"\033f"},@{@"key":@51,@"characters":@"\x7f",@"expected":@"\033\x7f"}];
    for(NSDictionary *optionCase in optionCases){NSEvent *optionEvent=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagOption timestamp:0 windowNumber:0 context:nil characters:optionCase[@"characters"] charactersIgnoringModifiers:optionCase[@"characters"] isARepeat:NO keyCode:[optionCase[@"key"] unsignedShortValue]];[terminal startDiagnosticInputCapture];[terminal keyDown:optionEvent];NSString *reported=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];if(![reported isEqual:optionCase[@"expected"]])return 57;}
    [terminal consumeData:[@"\033[?1049h" dataUsingEncoding:NSUTF8StringEncoding]];
    [terminal startDiagnosticInputCapture];[terminal routeWheelLines:3 event:wheel modifierFlags:0];
    NSString *alternateScrollReport=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];
    if(![alternateScrollReport containsString:@"\033OA"])return 22;
    [terminal consumeData:[@"\033[?1049l" dataUsingEncoding:NSUTF8StringEncoding]];
    NSUInteger inlineHistoryBefore=[terminal.diagnosticState[@"history"] unsignedIntegerValue];
    [terminal consumeData:[@"\033[r\033[2J\033[HINLINE-HISTORY\033[10;1HPINNED-COMPOSER\033[?2004h\033[>7u\033[?1004h\033[?2026h\033[1;8r\033[8;1H\n\033[?2026l\033[r" dataUsingEncoding:NSUTF8StringEncoding]];
    if([terminal.diagnosticState[@"history"] unsignedIntegerValue]!=inlineHistoryBefore+1||[terminal.diagnosticState[@"inlineViewportTop"] unsignedIntegerValue]!=8)return 35;
    [terminal startDiagnosticInputCapture];[terminal routeWheelLines:3 event:wheel modifierFlags:0];
    NSData *codexUpReport=[terminal finishDiagnosticInputCapture];
    NSString *inlineScrolledText=[terminal visibleText];
    if(codexUpReport.length||[terminal.diagnosticState[@"offset"] integerValue]<=0||![inlineScrolledText containsString:@"INLINE-HISTORY"]||![inlineScrolledText containsString:@"PINNED-COMPOSER"])return 36;
    [terminal startDiagnosticInputCapture];[terminal routeWheelLines:-3 event:wheel modifierFlags:0];
    if([terminal finishDiagnosticInputCapture].length||[terminal.diagnosticState[@"offset"] integerValue]!=0)return 37;
    [terminal consumeData:[@"\033[?2004l" dataUsingEncoding:NSUTF8StringEncoding]];[terminal scrollByLines:-100000];[terminal startDiagnosticInputCapture];[terminal routeWheelLines:3 event:wheel modifierFlags:0];
    if([terminal finishDiagnosticInputCapture].length||[terminal.diagnosticState[@"offset"] integerValue]<=0||[terminal.diagnosticState[@"inlineViewport"] boolValue])return 38;
    [terminal scrollByLines:-100000];
    [terminal consumeData:[@"\033[?1000;1006h" dataUsingEncoding:NSUTF8StringEncoding]];
    if([terminal shouldForwardApplicationMouseWithModifiers:0])return 11;
    if(![terminal shouldForwardApplicationMouseWithModifiers:NSEventModifierFlagOption])return 12;
    if(![terminal.diagnosticState[@"mouseEncoding"] isEqual:@"sgr"])return 13;
    [terminal startDiagnosticInputCapture];[terminal routeWheelLines:3 event:wheel modifierFlags:0];
    NSString *wheelReport=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];
    if(![wheelReport containsString:@"\033[<64;"]){fprintf(stderr,"mouse wheel report mismatch: %s\n",wheelReport.UTF8String);return 14;}
    [terminal scrollByLines:-100000];[terminal startDiagnosticInputCapture];[terminal routeWheelLines:3 event:wheel modifierFlags:NSEventModifierFlagShift];
    if([terminal finishDiagnosticInputCapture].length||[terminal.diagnosticState[@"offset"] integerValue]<=0)return 15;
    [terminal scrollByLines:-100000];
    [terminal startDiagnosticInputCapture];[terminal consumeData:[@"\033]10;?\a" dataUsingEncoding:NSUTF8StringEncoding]];NSString *colorReply=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];if(![colorReply containsString:@"\033]10;rgb:"])return 16;
    [terminal startDiagnosticInputCapture];[terminal consumeData:[@"\033[>c\033[c" dataUsingEncoding:NSUTF8StringEncoding]];NSString *deviceReplies=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];if(![deviceReplies isEqual:@"\033[>0;120;0c\033[?1;2c"])return 43;
    [terminal clearTerminal];[terminal consumeData:[@"\033(0lqkx m j\033(B ASCII \033)0\016lqk\017" dataUsingEncoding:NSUTF8StringEncoding]];NSString *graphicsText=[terminal visibleText];if(![graphicsText containsString:@"┌─┐│ └ ┘ ASCII ┌─┐"]||[graphicsText containsString:@"lqk"])return 44;
    TTerminalView *clickTerminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,800,500) config:config];[clickTerminal consumeData:[@"content" dataUsingEncoding:NSUTF8StringEncoding]];TRenderSnapshot *clickSnapshot=clickTerminal.renderSnapshot;CGFloat clickX=[clickSnapshot.style[@"left"] doubleValue]+clickSnapshot.metrics.cellWidth*2,clickY=[clickSnapshot.style[@"top"] doubleValue]+clickSnapshot.metrics.cellHeight*10.5;NSEvent *blankDown=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(clickX,clickY) modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:2 clickCount:1 pressure:1];[clickTerminal mouseDown:blankDown];if([clickTerminal.diagnosticState[@"selecting"] boolValue]||[clickTerminal.diagnosticState[@"selection"] boolValue])return 62;
    TConfig *fontConfig=[TConfig new];fontConfig.fontName=@"Monaco";TTabButton *fontButton=[[TTabButton alloc]initWithFrame:NSMakeRect(0,0,32,32)];fontButton.config=fontConfig;[fontButton applyStyleAnimated:NO];if(![fontButton.font.familyName containsString:@"Monaco"])return 63;
    NSEvent *down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(400,250) modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
    NSEvent *mouseUp=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSMakePoint(400,250) modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:0];
    [terminal startDiagnosticInputCapture];[terminal mouseDown:down];[terminal mouseUp:mouseUp];
    if([terminal finishDiagnosticInputCapture].length)return 17;
    if(![terminal.registeredDraggedTypes containsObject:NSPasteboardTypeFileURL])return 39;
    [terminal consumeData:[@"\033[?2004h" dataUsingEncoding:NSUTF8StringEncoding]];
    [terminal startDiagnosticInputCapture];
    if(![terminal insertDroppedFileURLs:@[[NSURL fileURLWithPath:@"/tmp/Termatica drop's.txt"],[NSURL fileURLWithPath:@"/tmp/second file.md"]]])return 40;
    NSString *dropReport=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];
    if(![dropReport isEqual:@"\033[200~'/tmp/Termatica drop'\\''s.txt' '/tmp/second file.md'\033[201~"])return 41;
    [terminal consumeData:[@"\033[?2004l" dataUsingEncoding:NSUTF8StringEncoding]];
    [terminal clearTerminal];[terminal consumeData:[@"\033[38:2::1:2:3mX\033[0m" dataUsingEncoding:NSUTF8StringEncoding]];TRenderSnapshot *colonColorSnapshot=terminal.renderSnapshot;const TCell *colonColorCells=colonColorSnapshot.cells.bytes;if(!colonColorCells||((colonColorCells[0].fg&0xFFFFFF)!=0x010203))return 58;
    [terminal consumeData:[@"\033[5 q" dataUsingEncoding:NSUTF8StringEncoding]];if(![terminal.renderSnapshot.style[@"cursorStyle"] isEqual:@"bar"])return 59;[terminal consumeData:[@"\033[3 q" dataUsingEncoding:NSUTF8StringEncoding]];if(![terminal.renderSnapshot.style[@"cursorStyle"] isEqual:@"underline"])return 60;
    [terminal startDiagnosticInputCapture];[terminal consumeData:[@"\033[?2004h\033[?2004$p\033[?9999$p\033[4$p\033[14t\033[18t" dataUsingEncoding:NSUTF8StringEncoding]];NSString *queryReplies=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];if(![queryReplies containsString:@"\033[?2004;1$y"]||![queryReplies containsString:@"\033[?9999;0$y"]||![queryReplies containsString:@"\033[4;0$y"]||![queryReplies containsString:@"\033[4;"]||![queryReplies containsString:@"\033[8;"])return 61;[terminal consumeData:[@"\033[?2004l" dataUsingEncoding:NSUTF8StringEncoding]];
    [terminal startDiagnosticInputCapture];[terminal consumeData:[@"\033]4;1;#010203\a\033]4;1;?\a\033]104\a" dataUsingEncoding:NSUTF8StringEncoding]];NSString *paletteReply=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];if(![paletteReply containsString:@"\033]4;1;rgb:0101/0202/0303\033\\"]){fprintf(stderr,"OSC 4 reply mismatch: %s\n",paletteReply.UTF8String);return 62;}
    [terminal startDiagnosticInputCapture];[terminal setMarkedText:@"漢" selectedRange:NSMakeRange(1,0) replacementRange:NSMakeRange(NSNotFound,0)];if(!terminal.hasMarkedText)return 63;[terminal insertText:@"漢" replacementRange:NSMakeRange(NSNotFound,0)];NSString *imeReport=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];if(terminal.hasMarkedText||![imeReport isEqual:@"漢"])return 64;
    TConfig *tiledConfig=[TConfig new];tiledConfig.hyprlandLayout=YES;tiledConfig.tabAnimations=NO;tiledConfig.shell=@"/usr/bin/true";tiledConfig.shellArguments=@[];
    TWindowController *tiles=[[TWindowController alloc]initWithConfig:tiledConfig extensions:nil];[tiles addTab];
    if(tiles.terminals.count!=2)return 18;
    for(TTerminalView *tile in tiles.terminals)if([tiles terminalAtRootPoint:NSMakePoint(NSMidX(tile.frame),NSMidY(tile.frame))]!=tile)return 19;
    TTerminalView *leftRoot=tiles.terminals[0],*rightRoot=tiles.terminals[1];tiles.terminal=leftRoot;[tiles addVerticalTab];[tiles layoutTabs];TTerminalView *quarter=tiles.terminal;
    if(tiles.terminals.count!=3||NSHeight(quarter.frame)>=NSHeight(rightRoot.frame))return 52;
    tiledConfig.tabAnimations=YES;NSRect quarterSlot=quarter.frame,halfSlot=rightRoot.frame;NSEvent *dragDown=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(NSMidX(quarterSlot),NSMidY(quarterSlot)) modifierFlags:NSEventModifierFlagCommand timestamp:1 windowNumber:tiles.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];NSEvent *dragMove=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged location:NSMakePoint(NSMidX(halfSlot),NSMidY(halfSlot)) modifierFlags:NSEventModifierFlagCommand timestamp:2 windowNumber:tiles.window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1];NSEvent *dragUp=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSMakePoint(NSMidX(halfSlot),NSMidY(halfSlot)) modifierFlags:NSEventModifierFlagCommand timestamp:3 windowNumber:tiles.window.windowNumber context:nil eventNumber:3 clickCount:1 pressure:0];[quarter mouseDown:dragDown];[quarter mouseDragged:dragMove];[quarter mouseUp:dragUp];
    if(!NSEqualRects(quarter.frame,halfSlot)||!NSEqualRects(rightRoot.frame,quarterSlot))return 53;
    if(![quarter.layer animationForKey:@"termatica.hypr.snap"]||![rightRoot.layer animationForKey:@"termatica.hypr.snap"])return 56;
    for(TTerminalView *tile in tiles.terminals){TTerminalView *cursor=tile;NSUInteger depth=0;while(cursor.splitAnchor&&[tiles.terminals containsObject:cursor.splitAnchor]){cursor=cursor.splitAnchor;if(++depth>tiles.terminals.count)return 54;}}
    for(TTerminalView *tile in tiles.terminals)if([tiles terminalAtRootPoint:NSMakePoint(NSMidX(tile.frame),NSMidY(tile.frame))]!=tile)return 55;
    for(TTerminalView *tile in tiles.terminals)[tile stopShellTerminating:YES];[tiles.window close];
    fprintf(stdout,"terminal-self-test ok history=%lu rows=%lu columns=%lu keyboard=kitty+legacy mouse=native-click+tui-wheel wheel=normal+hyprland layout=arbitrary-slot-swap\n",(unsigned long)[initial[@"history"] unsignedIntegerValue],(unsigned long)[initial[@"rows"] unsignedIntegerValue],(unsigned long)[initial[@"columns"] unsignedIntegerValue]);
    return 0;
}

static void TParityWriteASCII(TCell *cells,NSUInteger rows,NSUInteger columns,NSUInteger row,NSUInteger column,const char *text,uint8_t flags,uint32_t foreground,uint32_t background) {
    if(!cells||row>=rows||!text)return;
    for(NSUInteger index=0;text[index]&&column+index<columns;index++)cells[row*columns+column+index]=(TCell){.ch=(uint8_t)text[index],.flags=flags,.fg=foreground,.bg=background};
}

static CGImageRef TParityCheckerImage(void) {
    const size_t width=36,height=24,bytesPerRow=width*4;
    CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();CGContextRef context=colorSpace?CGBitmapContextCreate(NULL,width,height,8,bytesPerRow,colorSpace,(CGBitmapInfo)(kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little)):NULL;if(colorSpace)CGColorSpaceRelease(colorSpace);
    if(!context)return NULL;
    CGContextSetRGBFillColor(context,0.08,0.16,0.32,1);CGContextFillRect(context,CGRectMake(0,0,width,height));
    CGContextSetRGBFillColor(context,0.95,0.28,0.18,1);CGContextFillRect(context,CGRectMake(0,0,width/2,height/2));
    CGContextSetRGBFillColor(context,0.18,0.82,0.42,1);CGContextFillRect(context,CGRectMake(width/2,height/2,width/2,height/2));
    CGImageRef image=CGBitmapContextCreateImage(context);CGContextRelease(context);return image;
}

static TRenderSnapshot *TParityFixture(TRenderSnapshot *seed,uint64_t generation,NSString *cursorStyle,BOOL cursorFocused,BOOL effects,BOOL tiled,BOOL partialDamage,CGFloat scale) {
    TRenderMetrics metrics=seed.metrics;metrics.scale=MAX(1,scale);NSUInteger rows=metrics.rows,columns=metrics.columns,count=rows*columns;
    NSMutableData *cellData=[NSMutableData dataWithLength:count*sizeof(TCell)],*underlineData=[NSMutableData dataWithLength:count],*selectionData=[NSMutableData dataWithLength:count],*searchData=[NSMutableData dataWithLength:count],*linkData=[NSMutableData dataWithLength:count];
    TCell *cells=cellData.mutableBytes;uint8_t *underlines=underlineData.mutableBytes,*selection=selectionData.mutableBytes,*search=searchData.mutableBytes,*links=linkData.mutableBytes;
    TCell blank={.ch=' ',.flags=0,.fg=TDefaultColor,.bg=TDefaultColor};for(NSUInteger index=0;index<count;index++)cells[index]=blank;for(NSUInteger row=0;row<MIN((NSUInteger)12,rows);row++)for(NSUInteger column=0;column<MIN((NSUInteger)32,columns);column++)cells[row*columns+column]=(TCell){.ch='M',.flags=0,.fg=TDefaultColor,.bg=TDefaultColor};
    TParityWriteASCII(cells,rows,columns,0,0,"ASCII plain 0123456789",0,TDefaultColor,TDefaultColor);
    TParityWriteASCII(cells,rows,columns,1,0,"BOLD",TBold,0xF4D35E,TDefaultColor);TParityWriteASCII(cells,rows,columns,1,6,"ITALIC",TItalic,0x8BE9FD,TDefaultColor);TParityWriteASCII(cells,rows,columns,1,14,"INVERSE",TInverse,0xF8F8F2,0x303040);
    if(rows>2&&columns>15){NSUInteger base=2*columns;cells[base]=(TCell){.ch=0x03BB,.fg=TDefaultColor,.bg=TDefaultColor};cells[base+2]=(TCell){.ch=0x0416,.fg=0xBD93F9,.bg=TDefaultColor};cells[base+4]=(TCell){.ch=0x6F22,.flags=TWide,.fg=TDefaultColor,.bg=TDefaultColor};cells[base+5]=(TCell){.ch=' ',.flags=TContinuation,.fg=TDefaultColor,.bg=TDefaultColor};cells[base+7]=(TCell){.ch=0x1F642,.flags=TWide,.fg=TDefaultColor,.bg=TDefaultColor};cells[base+8]=(TCell){.ch=' ',.flags=TContinuation,.fg=TDefaultColor,.bg=TDefaultColor};cells[base+10]=(TCell){.ch=0xFFFFFFu,.fg=TDefaultColor,.bg=TDefaultColor};}
    NSArray<NSString *> *graphemes=@[@"e\u0301",@"👩🏽‍💻",@"🇦🇺",@"❤️",@"क्ष",@"نّ",@"ก้",@"✈️",@"☹︎"];
    if(rows>3&&columns>=graphemes.count*3){NSUInteger base=3*columns;for(NSUInteger index=0;index<graphemes.count;index++){NSUInteger column=index*3;cells[base+column]=(TCell){.ch=(uint32_t)(TClusterBase+index),.flags=(uint8_t)(TCluster|TWide),.fg=TDefaultColor,.bg=TDefaultColor};cells[base+column+1]=(TCell){.ch=' ',.flags=TContinuation,.fg=TDefaultColor,.bg=TDefaultColor};}}
    if(rows>4){TParityWriteASCII(cells,rows,columns,4,0,"UNDERLINES",TUnderline,0xFF79C6,TDefaultColor);for(NSUInteger index=0;index<MIN((NSUInteger)5,columns);index++)underlines[4*columns+index]=index+1;}
    if(rows>5){TParityWriteASCII(cells,rows,columns,5,0,"SELECTED CELLS",0,TDefaultColor,TDefaultColor);for(NSUInteger index=0;index<MIN((NSUInteger)8,columns);index++)selection[5*columns+index]=1;}
    if(rows>6){TParityWriteASCII(cells,rows,columns,6,0,"SEARCH MATCH",0,TDefaultColor,TDefaultColor);for(NSUInteger index=0;index<MIN((NSUInteger)6,columns);index++)search[6*columns+7+index]=1;}
    NSMutableDictionary<NSNumber *,NSString *> *linkTargets=[NSMutableDictionary dictionary];if(rows>7){TParityWriteASCII(cells,rows,columns,7,0,"HYPERLINK",0,0x50FA7B,TDefaultColor);for(NSUInteger index=0;index<MIN((NSUInteger)9,columns);index++){NSUInteger cell=7*columns+index;links[cell]=1;linkTargets[@(cell)]=@"https://example.invalid/termatica-parity";}}
    if(rows>8){TParityWriteASCII(cells,rows,columns,8,0,"TRUECOLOR",0,0x12D6DF,0x402060);}
    if(rows>11){for(NSUInteger row=10;row<=11;row++)for(NSUInteger column=0;column<MIN((NSUInteger)24,columns);column++)cells[row*columns+column]=(TCell){.ch=' ',.flags=0,.fg=TDefaultColor,.bg=row==10?0x7A2040:0x204E78};TParityWriteASCII(cells,rows,columns,10,1,"COLOUR BLOCK",TBold,0xFFFFFF,0x7A2040);TParityWriteASCII(cells,rows,columns,11,1,"PARITY MARKER",0,0xFFFFFF,0x204E78);}
    CGImageRef checker=TParityCheckerImage();NSDictionary *images=@{};if(checker&&rows>9&&columns>20)images=@{@((9u<<16)|18u):CFBridgingRelease(checker)};else if(checker)CGImageRelease(checker);
    NSMutableDictionary *style=[seed.style mutableCopy];style[@"backgroundAlpha"]=@1;style[@"cursorStyle"]=cursorStyle;style[@"cursorFocused"]=@(cursorFocused);style[@"colorize"]=@YES;style[@"glow"]=effects?@0.45:@0;style[@"scanlines"]=effects?@0.8:@0;style[@"scanlineSpacing"]=@4;style[@"scanlineThickness"]=@1;style[@"vignette"]=effects?@0.7:@0;style[@"vignetteLayers"]=@8;style[@"tiled"]=@(tiled);
    NSUInteger cursorX=MIN((NSUInteger)14,columns-1),cursorY=MIN((NSUInteger)10,rows-1);NSRange damaged=partialDamage?NSMakeRange(MIN((NSUInteger)4,rows-1),MIN((NSUInteger)4,rows-MIN((NSUInteger)4,rows-1))):NSMakeRange(0,rows);
    return [[TRenderSnapshot alloc]initWithGeneration:generation metrics:metrics cells:[cellData copy] underlineStyles:[underlineData copy] selectionMask:[selectionData copy] searchMask:[searchData copy] linkMask:[linkData copy] graphemes:graphemes style:[style copy] links:linkTargets images:images cursorX:cursorX cursorY:cursorY cursorVisible:YES historyCount:240 historyOffset:80 fullDamage:!partialDamage damagedRows:damaged];
}

static BOOL TValidateParityFixture(NSString *name,TRenderSnapshot *snapshot,NSString **failure) {
    if(!snapshot.isValid){if(failure)*failure=[NSString stringWithFormat:@"%@ invalid snapshot",name];return NO;}
    NSUInteger count=snapshot.metrics.rows*snapshot.metrics.columns;const TCell *cells=snapshot.cells.bytes;const uint8_t *underlines=snapshot.underlineStyles.bytes,*selection=snapshot.selectionMask.bytes,*search=snapshot.searchMask.bytes,*links=snapshot.linkMask.bytes;NSUInteger bold=0,italic=0,inverse=0,wide=0,continuation=0,cluster=0,selected=0,searched=0,linked=0;BOOL underlineStyles[6]={0};
    for(NSUInteger index=0;index<count;index++){uint8_t flags=cells[index].flags;bold+=(flags&TBold)!=0;italic+=(flags&TItalic)!=0;inverse+=(flags&TInverse)!=0;wide+=(flags&TWide)!=0;continuation+=(flags&TContinuation)!=0;cluster+=(flags&TCluster)!=0;selected+=selection[index]!=0;searched+=search[index]!=0;linked+=links[index]!=0;if(underlines[index]<=5)underlineStyles[underlines[index]]=YES;}
    BOOL allUnderlines=YES;for(NSUInteger index=1;index<=5;index++)allUnderlines&=underlineStyles[index];
    BOOL scriptCorpus=[snapshot.graphemes containsObject:@"क्ष"]&&[snapshot.graphemes containsObject:@"نّ"]&&[snapshot.graphemes containsObject:@"ก้"]&&[snapshot.graphemes containsObject:@"✈️"]&&[snapshot.graphemes containsObject:@"☹︎"];
    BOOL complete=bold&&italic&&inverse&&wide&&continuation&&cluster>=9&&selected&&searched&&linked&&allUnderlines&&snapshot.graphemes.count>=9&&scriptCorpus&&snapshot.images.count&&snapshot.links.count&&snapshot.cursorVisible&&snapshot.historyCount&&snapshot.historyOffset>0;
    if(!complete&&failure)*failure=[NSString stringWithFormat:@"%@ incomplete corpus bold=%lu italic=%lu inverse=%lu wide=%lu continuation=%lu cluster=%lu selection=%lu search=%lu links=%lu underlines=%d graphemes=%lu images=%lu",name,(unsigned long)bold,(unsigned long)italic,(unsigned long)inverse,(unsigned long)wide,(unsigned long)continuation,(unsigned long)cluster,(unsigned long)selected,(unsigned long)searched,(unsigned long)linked,allUnderlines,(unsigned long)snapshot.graphemes.count,(unsigned long)snapshot.images.count];
    return complete;
}

static TRenderSnapshot *TParityContractVariant(TRenderSnapshot *source,TRenderMetrics metrics,NSData *cells,NSData *selection,NSUInteger cursorX,NSRange damagedRows) {
    return [[TRenderSnapshot alloc]initWithGeneration:source.generation metrics:metrics cells:cells?:source.cells underlineStyles:source.underlineStyles selectionMask:selection?:source.selectionMask searchMask:source.searchMask linkMask:source.linkMask graphemes:source.graphemes style:source.style links:source.links images:source.images cursorX:cursorX cursorY:source.cursorY cursorVisible:source.cursorVisible historyCount:source.historyCount historyOffset:source.historyOffset fullDamage:source.fullDamage damagedRows:damagedRows];
}

static BOOL TValidateParityContractRejections(TRenderSnapshot *valid,NSString **failure) {
    TRenderMetrics emptyMetrics=valid.metrics;emptyMetrics.rows=0;NSArray<NSDictionary *> *invalid=@[
        @{@"name":@"zero-rows",@"snapshot":TParityContractVariant(valid,emptyMetrics,nil,nil,valid.cursorX,valid.damagedRows)},
        @{@"name":@"short-cells",@"snapshot":TParityContractVariant(valid,valid.metrics,NSData.data,nil,valid.cursorX,valid.damagedRows)},
        @{@"name":@"short-selection",@"snapshot":TParityContractVariant(valid,valid.metrics,nil,NSData.data,valid.cursorX,valid.damagedRows)},
        @{@"name":@"cursor-out-of-range",@"snapshot":TParityContractVariant(valid,valid.metrics,nil,nil,valid.metrics.columns,valid.damagedRows)},
        @{@"name":@"damage-out-of-range",@"snapshot":TParityContractVariant(valid,valid.metrics,nil,nil,valid.cursorX,NSMakeRange(valid.metrics.rows,1))}
    ];
    for(NSDictionary *item in invalid)if([item[@"snapshot"] isValid]){if(failure)*failure=[NSString stringWithFormat:@"invalid snapshot accepted: %@",item[@"name"]];return NO;}return YES;
}

static NSDictionary *TCaptureAppKitParityFrame(TTerminalView *view,TRenderSnapshot *snapshot) {
    NSUInteger width=(NSUInteger)ceil(snapshot.metrics.viewportWidth*snapshot.metrics.scale),height=(NSUInteger)ceil(snapshot.metrics.viewportHeight*snapshot.metrics.scale),bytesPerRow=width*4;if(!width||!height)return @{};
    CGFloat sourceScale=MAX((CGFloat)2,snapshot.metrics.scale);NSUInteger sourceWidth=(NSUInteger)ceil(snapshot.metrics.viewportWidth*sourceScale),sourceHeight=(NSUInteger)ceil(snapshot.metrics.viewportHeight*sourceScale),sourceStride=sourceWidth*4;NSMutableData *sourcePixels=[NSMutableData dataWithLength:sourceStride*sourceHeight];CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();CGContextRef source=colorSpace?CGBitmapContextCreate(sourcePixels.mutableBytes,sourceWidth,sourceHeight,8,sourceStride,colorSpace,(CGBitmapInfo)(kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little)):NULL;if(colorSpace)CGColorSpaceRelease(colorSpace);if(!source)return @{};
    CGContextScaleCTM(source,sourceScale,sourceScale);NSGraphicsContext *context=[NSGraphicsContext graphicsContextWithCGContext:source flipped:YES];[view setDisplaySnapshotForRendererSelfTest:snapshot];[NSGraphicsContext saveGraphicsState];NSGraphicsContext.currentContext=context;[view drawRect:view.bounds];[NSGraphicsContext restoreGraphicsState];CGContextFlush(source);CGContextRelease(source);
    NSMutableData *pixels=[NSMutableData dataWithLength:bytesPerRow*height];const uint8_t *sourceBytes=sourcePixels.bytes;uint8_t *targetBytes=pixels.mutableBytes;for(NSUInteger y=0;y<height;y++){NSUInteger sy0=y*sourceHeight/height,sy1=MAX(sy0+1,(y+1)*sourceHeight/height);for(NSUInteger x=0;x<width;x++){NSUInteger sx0=x*sourceWidth/width,sx1=MAX(sx0+1,(x+1)*sourceWidth/width);uint64_t totals[4]={0};NSUInteger samples=0;for(NSUInteger sy=sy0;sy<sy1;sy++){const uint8_t *row=sourceBytes+sy*sourceStride;for(NSUInteger sx=sx0;sx<sx1;sx++){for(NSUInteger channel=0;channel<4;channel++)totals[channel]+=row[sx*4+channel];samples++;}}for(NSUInteger channel=0;channel<4;channel++)targetBytes[y*bytesPerRow+x*4+channel]=(uint8_t)(totals[channel]/MAX((NSUInteger)1,samples));}}
    return @{@"pixels":[pixels copy],@"width":@(width),@"height":@(height),@"bytesPerRow":@(bytesPerRow),@"generation":@(snapshot.generation)};
}

static double TParityBlockRMS(NSDictionary *appkit,NSDictionary *metal,TRenderSnapshot *snapshot,BOOL flipAppKit) {
    NSData *a=appkit[@"pixels"],*b=metal[@"pixels"];NSUInteger width=[metal[@"width"] unsignedIntegerValue],height=[metal[@"height"] unsignedIntegerValue],aWidth=[appkit[@"width"] unsignedIntegerValue],aHeight=[appkit[@"height"] unsignedIntegerValue],aStride=[appkit[@"bytesPerRow"] unsignedIntegerValue],bStride=[metal[@"bytesPerRow"] unsignedIntegerValue];if(!a.length||!b.length||width!=aWidth||height!=aHeight||!aStride||!bStride)return DBL_MAX;
    CGFloat scale=snapshot.metrics.scale,left=[snapshot.style[@"left"] doubleValue],top=[snapshot.style[@"top"] doubleValue];NSUInteger contentWidth=MIN(width,(NSUInteger)ceil((left+MIN((NSUInteger)32,snapshot.metrics.columns)*snapshot.metrics.cellWidth)*scale)),contentHeight=MIN(height,(NSUInteger)ceil((top+MIN((NSUInteger)12,snapshot.metrics.rows)*snapshot.metrics.cellHeight)*scale));if(!contentWidth||!contentHeight)return DBL_MAX;
    const uint8_t *ap=a.bytes,*bp=b.bytes;NSUInteger gridX=MIN((NSUInteger)40,contentWidth),gridY=MIN((NSUInteger)24,contentHeight);double squared=0;NSUInteger samples=0;
    for(NSUInteger gy=0;gy<gridY;gy++)for(NSUInteger gx=0;gx<gridX;gx++){NSUInteger x0=gx*contentWidth/gridX,x1=MAX(x0+1,(gx+1)*contentWidth/gridX),y0=gy*contentHeight/gridY,y1=MAX(y0+1,(gy+1)*contentHeight/gridY);double av[3]={0},bv[3]={0};NSUInteger pixels=0;for(NSUInteger y=y0;y<y1;y+=2){NSUInteger ay=flipAppKit?height-1-y:y;const uint8_t *arow=ap+ay*aStride,*brow=bp+y*bStride;for(NSUInteger x=x0;x<x1;x+=2){for(NSUInteger channel=0;channel<3;channel++){av[channel]+=arow[x*4+channel];bv[channel]+=brow[x*4+channel];}pixels++;}}if(!pixels)continue;for(NSUInteger channel=0;channel<3;channel++){double delta=(av[channel]-bv[channel])/(pixels*255.0);squared+=delta*delta;samples++;}}
    return samples?sqrt(squared/samples):DBL_MAX;
}

static NSDictionary *TParityCellVerticalFlipFrame(NSDictionary *frame,TRenderSnapshot *snapshot) {
    NSData *source=frame[@"pixels"];NSUInteger width=[frame[@"width"] unsignedIntegerValue],height=[frame[@"height"] unsignedIntegerValue],stride=[frame[@"bytesPerRow"] unsignedIntegerValue];if(!source.length||!width||!height||stride<width*4)return @{};NSMutableData *pixels=[source mutableCopy];const uint8_t *input=source.bytes;uint8_t *output=pixels.mutableBytes;CGFloat scale=snapshot.metrics.scale,left=[snapshot.style[@"left"] doubleValue]*scale,top=[snapshot.style[@"top"] doubleValue]*scale,cellHeight=snapshot.metrics.cellHeight*scale;NSUInteger x0=MIN(width,(NSUInteger)floor(MAX(0,left))),x1=MIN(width,(NSUInteger)ceil(MAX(0,left+snapshot.metrics.columns*snapshot.metrics.cellWidth*scale)));for(NSUInteger row=0;row<snapshot.metrics.rows;row++){NSUInteger y0=MIN(height,(NSUInteger)floor(MAX(0,top+row*cellHeight))),y1=MIN(height,(NSUInteger)ceil(MAX(0,top+(row+1)*cellHeight)));if(y1<=y0)continue;for(NSUInteger y=y0;y<y1;y++){NSUInteger sourceY=y0+y1-1-y;memcpy(output+y*stride+x0*4,input+sourceY*stride+x0*4,(x1-x0)*4);}}return @{@"pixels":[pixels copy],@"width":@(width),@"height":@(height),@"bytesPerRow":@(stride),@"generation":frame[@"generation"]?:@0};
}

static NSDictionary *TParityBackgroundOnlyFrame(NSDictionary *frame,TRenderSnapshot *snapshot) {
    NSUInteger width=[frame[@"width"] unsignedIntegerValue],height=[frame[@"height"] unsignedIntegerValue],bytesPerRow=[frame[@"bytesPerRow"] unsignedIntegerValue];if(!width||!height||bytesPerRow<width*4)return @{};NSMutableData *pixels=[NSMutableData dataWithLength:bytesPerRow*height];uint8_t *bytes=pixels.mutableBytes;uint32_t rgb=[snapshot.style[@"background"] unsignedIntValue];uint8_t red=(rgb>>16)&255,green=(rgb>>8)&255,blue=rgb&255,alpha=(uint8_t)lrint(MAX(0,MIN(1,[snapshot.style[@"backgroundAlpha"] doubleValue]))*255.0);for(NSUInteger y=0;y<height;y++){uint8_t *row=bytes+y*bytesPerRow;for(NSUInteger x=0;x<width;x++){row[x*4]=blue;row[x*4+1]=green;row[x*4+2]=red;row[x*4+3]=alpha;}}return @{@"pixels":[pixels copy],@"width":@(width),@"height":@(height),@"bytesPerRow":@(bytesPerRow),@"generation":frame[@"generation"]?:@0};
}

static void TWriteParityPPM(NSDictionary *frame,NSString *path) {
    NSData *pixels=frame[@"pixels"];NSUInteger width=[frame[@"width"] unsignedIntegerValue],height=[frame[@"height"] unsignedIntegerValue],stride=[frame[@"bytesPerRow"] unsignedIntegerValue];if(!pixels.length||!width||!height||stride<width*4||!path.length)return;
    NSMutableData *ppm=[NSMutableData data];NSData *header=[[NSString stringWithFormat:@"P6\n%lu %lu\n255\n",(unsigned long)width,(unsigned long)height] dataUsingEncoding:NSASCIIStringEncoding];[ppm appendData:header];const uint8_t *source=pixels.bytes;NSMutableData *row=[NSMutableData dataWithLength:width*3];uint8_t *rgb=row.mutableBytes;for(NSUInteger y=0;y<height;y++){const uint8_t *bgra=source+y*stride;for(NSUInteger x=0;x<width;x++){rgb[x*3]=bgra[x*4+2];rgb[x*3+1]=bgra[x*4+1];rgb[x*3+2]=bgra[x*4];}[ppm appendData:row];}[ppm writeToFile:path atomically:YES];
}

static NSArray<NSDictionary *> *TParityCorpus(TRenderSnapshot *seed) {
    return @[
        @{@"name":@"text-styles-unicode-1x",@"snapshot":TParityFixture(seed,1001,@"block",YES,NO,NO,NO,1)},
        @{@"name":@"text-styles-unicode-2x",@"snapshot":TParityFixture(seed,1002,@"block",YES,NO,NO,NO,2)},
        @{@"name":@"cursor-bar",@"snapshot":TParityFixture(seed,1003,@"bar",YES,NO,NO,NO,seed.metrics.scale)},
        @{@"name":@"cursor-underline-inactive",@"snapshot":TParityFixture(seed,1004,@"underline",NO,NO,NO,NO,seed.metrics.scale)},
        @{@"name":@"effects",@"snapshot":TParityFixture(seed,1005,@"block",YES,YES,NO,NO,seed.metrics.scale)},
        @{@"name":@"tiled-effects",@"snapshot":TParityFixture(seed,1006,@"block",YES,YES,YES,NO,seed.metrics.scale)},
        @{@"name":@"partial-damage-history-image",@"snapshot":TParityFixture(seed,1007,@"block",YES,NO,NO,YES,seed.metrics.scale)}
    ];
}

static int TRunRendererParityCorpus(void) {
    if(getenv("CI")){
        TConfig *headlessConfig=[TConfig new];headlessConfig.renderer=@"appkit";headlessConfig.shell=@"/usr/bin/true";headlessConfig.shellArguments=@[];TTerminalView *headless=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,720,440) config:headlessConfig];NSArray<NSDictionary *> *fixtures=TParityCorpus(headless.renderSnapshot);
        for(NSDictionary *fixture in fixtures){NSString *failure=nil;if(!TValidateParityFixture(fixture[@"name"],fixture[@"snapshot"],&failure)){fprintf(stderr,"renderer-parity-self-test failed stage=headless-semantic fixture=%s reason=%s\n",[fixture[@"name"] UTF8String],failure.UTF8String);return 70;}}
        NSString *contractFailure=nil;if(!TValidateParityContractRejections(fixtures.firstObject[@"snapshot"],&contractFailure)){fprintf(stderr,"renderer-parity-self-test failed stage=headless-contract reason=%s\n",contractFailure.UTF8String);return 76;}
        fprintf(stdout,"renderer-parity-self-test ok mode=headless-ci semantic=exact malformed=rejected fixtures=%lu pixel-gate=requires-metal-host\n",(unsigned long)fixtures.count);return 0;
    }
    setenv("TERMATICA_METAL_VALIDATE_PIXELS","1",1);TConfig *appkitConfig=[TConfig new],*metalConfig=[TConfig new];appkitConfig.renderer=@"appkit";metalConfig.renderer=@"metal";appkitConfig.blur=metalConfig.blur=NO;appkitConfig.shell=metalConfig.shell=@"/usr/bin/true";appkitConfig.shellArguments=metalConfig.shellArguments=@[];
    NSRect frame=NSMakeRect(0,0,720,440);NSWindow *appkitWindow=[[NSWindow alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO],*metalWindow=[[NSWindow alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];TTerminalView *appkit=[[TTerminalView alloc]initWithFrame:appkitWindow.contentView.bounds config:appkitConfig],*metal=[[TTerminalView alloc]initWithFrame:metalWindow.contentView.bounds config:metalConfig];appkit.activeTerminal=metal.activeTerminal=YES;appkitWindow.contentView=appkit;metalWindow.contentView=metal;[appkitWindow orderFront:nil];[metalWindow orderFront:nil];[appkitWindow displayIfNeeded];[metalWindow displayIfNeeded];NSDate *ready=[NSDate dateWithTimeIntervalSinceNow:0.05];while(ready.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:ready];unsetenv("TERMATICA_METAL_VALIDATE_PIXELS");
    TRenderSnapshot *seed=appkit.renderSnapshot;NSArray<NSDictionary *> *fixtures=TParityCorpus(seed);
    for(NSDictionary *fixture in fixtures){NSString *failure=nil;if(!TValidateParityFixture(fixture[@"name"],fixture[@"snapshot"],&failure)){fprintf(stderr,"renderer-parity-self-test failed stage=semantic fixture=%s reason=%s\n",[fixture[@"name"] UTF8String],failure.UTF8String);[appkitWindow close];[metalWindow close];return 70;}}
    NSString *contractFailure=nil;if(!TValidateParityContractRejections(fixtures.firstObject[@"snapshot"],&contractFailure)){fprintf(stderr,"renderer-parity-self-test failed stage=contract reason=%s\n",contractFailure.UTF8String);[appkitWindow close];[metalWindow close];return 76;}
    if(![metal.diagnosticState[@"renderer"] isEqual:@"metal"]){[appkitWindow close];[metalWindow close];fprintf(stdout,"renderer-parity-self-test ok semantic-only metal=unavailable fixtures=%lu\n",(unsigned long)fixtures.count);return 0;}
    double worst=0,backgroundOnlyRMS=0;NSMutableDictionary<NSNumber *,NSNumber *> *orientations=[NSMutableDictionary dictionary];
    for(NSDictionary *fixture in fixtures){
        NSString *name=fixture[@"name"];TRenderSnapshot *snapshot=fixture[@"snapshot"];
        if(![appkit configureRendererForSnapshotSelfTest:snapshot]||![metal configureRendererForSnapshotSelfTest:snapshot]){fprintf(stderr,"renderer-parity-self-test failed stage=configure fixture=%s scale=%.1f\n",name.UTF8String,snapshot.metrics.scale);[appkitWindow close];[metalWindow close];return 75;}
        NSDictionary *appkitFrame=TCaptureAppKitParityFrame(appkit,snapshot);[metal presentSnapshotForRendererSelfTest:snapshot];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
        while([metal.diagnosticState[@"renderGeneration"] unsignedLongLongValue]<snapshot.generation&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        NSDictionary *metalFrame=[metal metalFrameCaptureForRendererSelfTest];
        NSString *dumpDirectory=[NSProcessInfo.processInfo.environment objectForKey:@"TERMATICA_PARITY_DUMP_DIR"];if(dumpDirectory.length){NSString *safeName=[name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];TWriteParityPPM(appkitFrame,[dumpDirectory stringByAppendingPathComponent:[safeName stringByAppendingString:@"-appkit.ppm"]]);TWriteParityPPM(metalFrame,[dumpDirectory stringByAppendingPathComponent:[safeName stringByAppendingString:@"-metal.ppm"]]);}
        if([metalFrame[@"generation"] unsignedLongLongValue]<snapshot.generation){fprintf(stderr,"renderer-parity-self-test failed stage=metal-timeout fixture=%s expected=%llu actual=%llu\n",name.UTF8String,(unsigned long long)snapshot.generation,(unsigned long long)[metalFrame[@"generation"] unsignedLongLongValue]);[appkitWindow close];[metalWindow close];return 71;}
        if([metalFrame[@"colorGlyphs"] unsignedIntegerValue]<3){fprintf(stderr,"renderer-parity-self-test failed stage=color-glyph-path fixture=%s color-glyphs=%lu required=3\n",name.UTF8String,(unsigned long)[metalFrame[@"colorGlyphs"] unsignedIntegerValue]);[appkitWindow close];[metalWindow close];return 77;}
        if([metalFrame[@"fallbackGlyphs"] unsignedIntegerValue]<1){fprintf(stderr,"renderer-parity-self-test failed stage=fallback-glyph-path fixture=%s fallback-glyphs=%lu required=1\n",name.UTF8String,(unsigned long)[metalFrame[@"fallbackGlyphs"] unsignedIntegerValue]);[appkitWindow close];[metalWindow close];return 78;}
        double direct=TParityBlockRMS(appkitFrame,metalFrame,snapshot,NO),flipped=TParityBlockRMS(appkitFrame,metalFrame,snapshot,YES);BOOL useFlip=flipped<direct;double rms=MIN(direct,flipped),cellFlippedRMS=TParityBlockRMS(appkitFrame,TParityCellVerticalFlipFrame(metalFrame,snapshot),snapshot,useFlip);NSNumber *scaleKey=@(snapshot.metrics.scale),*knownOrientation=orientations[scaleKey];
        if(!knownOrientation)orientations[scaleKey]=@(useFlip);else if(knownOrientation.boolValue!=useFlip){fprintf(stderr,"renderer-parity-self-test failed stage=capture-orientation fixture=%s scale=%.1f direct=%.4f flipped=%.4f\n",name.UTF8String,snapshot.metrics.scale,direct,flipped);[appkitWindow close];[metalWindow close];return 72;}
        if([fixture isEqual:fixtures.firstObject])backgroundOnlyRMS=TParityBlockRMS(appkitFrame,TParityBackgroundOnlyFrame(metalFrame,snapshot),snapshot,useFlip);
        if(!isfinite(rms)||rms>0.22){fprintf(stderr,"renderer-parity-self-test failed stage=visual fixture=%s rms=%.4f limit=0.2200 direct=%.4f flipped=%.4f negative=%.4f\n",name.UTF8String,rms,direct,flipped,backgroundOnlyRMS);[appkitWindow close];[metalWindow close];return 73;}
        if(![name containsString:@"effects"]&&rms>0.12){fprintf(stderr,"renderer-parity-self-test failed stage=glyph-fidelity fixture=%s rms=%.4f limit=0.1200\n",name.UTF8String,rms);[appkitWindow close];[metalWindow close];return 80;}
        if(!isfinite(cellFlippedRMS)||cellFlippedRMS<=rms+0.005){fprintf(stderr,"renderer-parity-self-test failed stage=glyph-orientation fixture=%s normal=%.4f cell-flipped=%.4f required-margin=0.0050\n",name.UTF8String,rms,cellFlippedRMS);[appkitWindow close];[metalWindow close];return 79;}
        worst=MAX(worst,rms);fprintf(stdout,"renderer-parity fixture=%s scale=%.1f rms=%.4f cell-flipped=%.4f orientation=%s color-glyphs=%lu fallback-glyphs=%lu\n",name.UTF8String,snapshot.metrics.scale,rms,cellFlippedRMS,useFlip?"normalized-flipped":"direct",(unsigned long)[metalFrame[@"colorGlyphs"] unsignedIntegerValue],(unsigned long)[metalFrame[@"fallbackGlyphs"] unsignedIntegerValue]);
    }
    if(!isfinite(backgroundOnlyRMS)||backgroundOnlyRMS<=0.22){fprintf(stderr,"renderer-parity-self-test failed stage=negative-control background-only-rms=%.4f required-above=0.2200\n",backgroundOnlyRMS);[appkitWindow close];[metalWindow close];return 74;}
    [appkitWindow close];[metalWindow close];fprintf(stdout,"renderer-parity-self-test ok fixtures=%lu semantic=exact visual-rms-max=%.4f limit=0.2200 negative-control=%.4f\n",(unsigned long)fixtures.count,worst,backgroundOnlyRMS);return 0;
}

static CGImageRef TCacheFixtureImage(NSUInteger index) {
    const size_t width=512,height=512,bytesPerRow=width*4;CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();CGContextRef context=colorSpace?CGBitmapContextCreate(NULL,width,height,8,bytesPerRow,colorSpace,(CGBitmapInfo)(kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little)):NULL;if(colorSpace)CGColorSpaceRelease(colorSpace);if(!context)return NULL;CGFloat red=((index*53)%251)/250.0,green=((index*97)%241)/240.0,blue=((index*149)%239)/238.0;CGContextSetRGBFillColor(context,red,green,blue,1);CGContextFillRect(context,CGRectMake(0,0,width,height));CGContextSetRGBFillColor(context,1-red,1-green,1-blue,1);CGContextFillRect(context,CGRectMake(index%64,index%48,128,96));CGImageRef image=CGBitmapContextCreateImage(context);CGContextRelease(context);return image;
}

static TRenderSnapshot *TCacheFixtureSnapshot(TRenderSnapshot *source,uint64_t generation,NSDictionary *images) {
    return [[TRenderSnapshot alloc]initWithGeneration:generation metrics:source.metrics cells:source.cells underlineStyles:source.underlineStyles selectionMask:source.selectionMask searchMask:source.searchMask linkMask:source.linkMask graphemes:source.graphemes style:source.style links:source.links images:images cursorX:source.cursorX cursorY:source.cursorY cursorVisible:source.cursorVisible historyCount:source.historyCount historyOffset:source.historyOffset fullDamage:YES damagedRows:NSMakeRange(0,source.metrics.rows)];
}

static TRenderSnapshot *TDenseGlyphCacheSnapshot(TRenderSnapshot *source,uint64_t generation) {
    NSUInteger count=source.metrics.rows*source.metrics.columns,denseCount=MIN(count,(NSUInteger)1200);NSMutableData *cells=[NSMutableData dataWithLength:count*sizeof(TCell)],*underlines=[NSMutableData dataWithLength:count],*selection=[NSMutableData dataWithLength:count],*search=[NSMutableData dataWithLength:count],*links=[NSMutableData dataWithLength:count];TCell *values=cells.mutableBytes;TCell blank={.ch=' ',.fg=TDefaultColor,.bg=TDefaultColor};for(NSUInteger index=0;index<count;index++)values[index]=blank;for(NSUInteger index=0;index<denseCount;index++){uint32_t scalar=(uint32_t)(0x0100+(index%0xC000));if(scalar>=0xD800&&scalar<=0xDFFF)scalar+=0x800;values[index]=(TCell){.ch=scalar,.fg=TDefaultColor,.bg=TDefaultColor};}return [[TRenderSnapshot alloc]initWithGeneration:generation metrics:source.metrics cells:cells underlineStyles:underlines selectionMask:selection searchMask:search linkMask:links graphemes:@[] style:source.style links:@{} images:@{} cursorX:0 cursorY:0 cursorVisible:NO historyCount:0 historyOffset:0 fullDamage:YES damagedRows:NSMakeRange(0,source.metrics.rows)];
}

static BOOL TWaitForMetalGeneration(TTerminalView *terminal,uint64_t generation,NSTimeInterval seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];while([terminal.diagnosticState[@"renderGeneration"] unsignedLongLongValue]<generation&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];return [terminal.diagnosticState[@"renderGeneration"] unsignedLongLongValue]>=generation;
}

static int TRunRendererCacheSelfTest(void) {
    if(getenv("CI")){TConfig *headlessConfig=[TConfig new];headlessConfig.renderer=@"appkit";headlessConfig.shell=@"/usr/bin/true";headlessConfig.shellArguments=@[];TTerminalView *headless=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,720,440) config:headlessConfig];TRenderSnapshot *base=TParityFixture(headless.renderSnapshot,2001,@"block",YES,NO,NO,NO,2),*dense=TDenseGlyphCacheSnapshot(base,2002);if(!base.isValid||!dense.isValid){fputs("renderer-cache-self-test failed stage=headless-snapshots\n",stderr);return 80;}fputs("renderer-cache-self-test ok mode=headless-ci semantic=exact gpu-cache-gate=requires-metal-host\n",stdout);return 0;}
    [TApplication sharedApplication];TConfig *config=[TConfig new];config.renderer=@"metal";config.blur=NO;config.shell=@"/usr/bin/true";config.shellArguments=@[];NSRect frame=NSMakeRect(0,0,720,440);NSWindow *window=[[NSWindow alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];window.releasedWhenClosed=NO;TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:window.contentView.bounds config:config];terminal.activeTerminal=YES;window.contentView=terminal;[window orderFront:nil];[window displayIfNeeded];if(![terminal.diagnosticState[@"renderer"] isEqual:@"metal"]){[window close];fputs("renderer-cache-self-test ok metal=unavailable semantic-only\n",stdout);return 0;}
    TRenderSnapshot *base=TParityFixture(terminal.renderSnapshot,2001,@"block",YES,NO,NO,NO,2);if(![terminal configureRendererForSnapshotSelfTest:base]){[window close];fputs("renderer-cache-self-test failed stage=configure\n",stderr);return 80;}[terminal presentSnapshotForRendererSelfTest:base];if(!TWaitForMetalGeneration(terminal,base.generation,3)){[window close];fputs("renderer-cache-self-test failed stage=base-timeout\n",stderr);return 81;}NSDictionary *baseStats=[terminal metalCacheDiagnosticsForRendererSelfTest];if(![baseStats[@"colorAtlasAllocated"] boolValue]||![baseStats[@"glyphEntries"] unsignedIntegerValue]||[baseStats[@"imageEntries"] unsignedIntegerValue]!=1){[window close];fprintf(stderr,"renderer-cache-self-test failed stage=lazy-base stats=%s\n",baseStats.description.UTF8String);return 82;}
    TRenderSnapshot *dense=TDenseGlyphCacheSnapshot(base,2002);[terminal presentSnapshotForRendererSelfTest:dense];if(!TWaitForMetalGeneration(terminal,dense.generation,20)){NSDictionary *state=terminal.diagnosticState,*cache=[terminal metalCacheDiagnosticsForRendererSelfTest];[window close];fprintf(stderr,"renderer-cache-self-test failed stage=glyph-pages-timeout state=%s cache=%s\n",state.description.UTF8String,cache.description.UTF8String);return 83;}NSDictionary *denseStats=[terminal metalCacheDiagnosticsForRendererSelfTest];if([denseStats[@"monoAtlasPages"] unsignedIntegerValue]<2||[denseStats[@"monoAtlasPages"] unsignedIntegerValue]>4||![terminal.diagnosticState[@"renderer"] isEqual:@"metal"]){[window close];fprintf(stderr,"renderer-cache-self-test failed stage=glyph-pages stats=%s renderer=%s\n",denseStats.description.UTF8String,[terminal.diagnosticState[@"renderer"] UTF8String]);return 84;}
    NSMutableDictionary *pressureImages=[NSMutableDictionary dictionary];for(NSUInteger index=0;index<40;index++){CGImageRef image=TCacheFixtureImage(index);if(!image){[window close];fputs("renderer-cache-self-test failed stage=image-fixture\n",stderr);return 85;}pressureImages[@(((index/10)<<16)|(index%10))]=CFBridgingRelease(image);}TRenderSnapshot *pressure=TCacheFixtureSnapshot(base,2003,pressureImages);[terminal presentSnapshotForRendererSelfTest:pressure];if(!TWaitForMetalGeneration(terminal,pressure.generation,5)){[window close];fputs("renderer-cache-self-test failed stage=pressure-timeout\n",stderr);return 86;}NSDictionary *pressureStats=[terminal metalCacheDiagnosticsForRendererSelfTest];NSUInteger imageBytes=[pressureStats[@"imageBytes"] unsignedIntegerValue],imageBudget=[pressureStats[@"imageBudget"] unsignedIntegerValue];if(imageBytes>imageBudget||[pressureStats[@"imageEntries"] unsignedIntegerValue]>=pressureImages.count||![pressureStats[@"imageEvictions"] unsignedIntegerValue]){[window close];fprintf(stderr,"renderer-cache-self-test failed stage=image-bound stats=%s\n",pressureStats.description.UTF8String);return 87;}
    NSMutableDictionary *warmImages=[NSMutableDictionary dictionary];NSUInteger retained=0;for(NSNumber *key in pressureImages){warmImages[key]=pressureImages[key];if(++retained==16)break;}for(uint64_t generation=2004;generation<2244;generation++){TRenderSnapshot *frameSnapshot=TCacheFixtureSnapshot(base,generation,warmImages);[terminal presentSnapshotForRendererSelfTest:frameSnapshot];if(!TWaitForMetalGeneration(terminal,generation,2)){[window close];fprintf(stderr,"renderer-cache-self-test failed stage=soak-timeout generation=%llu\n",(unsigned long long)generation);return 88;}}NSDictionary *soakStats=[terminal metalCacheDiagnosticsForRendererSelfTest];if([soakStats[@"imageBytes"] unsignedIntegerValue]>[soakStats[@"imageBudget"] unsignedIntegerValue]||[soakStats[@"imageEntries"] unsignedIntegerValue]>32){[window close];fprintf(stderr,"renderer-cache-self-test failed stage=soak-bound stats=%s\n",soakStats.description.UTF8String);return 89;}
    [terminal purgeMetalCachesForRendererSelfTest];NSDictionary *purged=[terminal metalCacheDiagnosticsForRendererSelfTest];if([purged[@"glyphEntries"] unsignedIntegerValue]||[purged[@"imageEntries"] unsignedIntegerValue]||[purged[@"imageBytes"] unsignedIntegerValue]||[purged[@"colorAtlasAllocated"] boolValue]||[purged[@"monoAtlasPages"] unsignedIntegerValue]!=1||![purged[@"memoryPurges"] unsignedIntegerValue]){[window close];fprintf(stderr,"renderer-cache-self-test failed stage=purge stats=%s\n",purged.description.UTF8String);return 90;}TRenderSnapshot *recovered=TCacheFixtureSnapshot(base,2244,base.images);[terminal presentSnapshotForRendererSelfTest:recovered];if(!TWaitForMetalGeneration(terminal,recovered.generation,3)){[window close];fputs("renderer-cache-self-test failed stage=recovery-timeout\n",stderr);return 91;}NSDictionary *recoveredStats=[terminal metalCacheDiagnosticsForRendererSelfTest];if(![recoveredStats[@"colorAtlasAllocated"] boolValue]||![recoveredStats[@"glyphEntries"] unsignedIntegerValue]||[recoveredStats[@"imageEntries"] unsignedIntegerValue]!=1){[window close];fprintf(stderr,"renderer-cache-self-test failed stage=recovery stats=%s\n",recoveredStats.description.UTF8String);return 92;}[window close];fprintf(stdout,"renderer-cache-self-test ok mono-pages=%lu image-bytes=%lu budget=%lu evictions=%lu soak-frames=240 purge-recovery=yes cache-bytes=%lu\n",(unsigned long)[denseStats[@"monoAtlasPages"] unsignedIntegerValue],(unsigned long)imageBytes,(unsigned long)imageBudget,(unsigned long)[pressureStats[@"imageEvictions"] unsignedIntegerValue],(unsigned long)[recoveredStats[@"totalCacheBytes"] unsignedIntegerValue]);return 0;
}

static int TRunRendererSchedulerSelfTest(void) {
    if(getenv("CI")){TConfig *config=[TConfig new];config.renderer=@"appkit";config.shell=@"/usr/bin/true";config.shellArguments=@[];TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,720,440) config:config];TRenderSnapshot *snapshot=TParityFixture(terminal.renderSnapshot,4000,@"block",YES,NO,NO,NO,2);if(!snapshot.isValid){fputs("renderer-scheduler-self-test failed stage=headless-snapshot\n",stderr);return 100;}fputs("renderer-scheduler-self-test ok mode=headless-ci semantic=exact display-link-gate=requires-metal-host\n",stdout);return 0;}
    [TApplication sharedApplication];TConfig *config=[TConfig new];config.renderer=@"metal";config.blur=NO;config.shell=@"/usr/bin/true";config.shellArguments=@[];NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,720,440) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];window.releasedWhenClosed=NO;TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:window.contentView.bounds config:config];terminal.activeTerminal=YES;window.contentView=terminal;[window orderFront:nil];[window displayIfNeeded];if(![terminal.diagnosticState[@"renderer"] isEqual:@"metal"]){[window close];fputs("renderer-scheduler-self-test ok metal=unavailable semantic-only\n",stdout);return 0;}
    TRenderSnapshot *base=TParityFixture(terminal.renderSnapshot,4000,@"block",YES,NO,NO,NO,2);if(![terminal configureRendererForSnapshotSelfTest:base]){[window close];fputs("renderer-scheduler-self-test failed stage=configure\n",stderr);return 101;}[terminal presentSnapshotForRendererSelfTest:base];if(!TWaitForMetalGeneration(terminal,base.generation,3)){[window close];fputs("renderer-scheduler-self-test failed stage=initial-timeout\n",stderr);return 102;}
    const uint64_t first=4001,last=5000;for(uint64_t generation=first;generation<=last;generation++)[terminal presentSnapshotForRendererSelfTest:TCacheFixtureSnapshot(base,generation,base.images)];if(!TWaitForMetalGeneration(terminal,last,5)){NSDictionary *stats=[terminal metalSchedulerDiagnosticsForRendererSelfTest];[window close];fprintf(stderr,"renderer-scheduler-self-test failed stage=burst-timeout stats=%s\n",stats.description.UTF8String);return 103;}
    [terminal presentSnapshotForRendererSelfTest:TCacheFixtureSnapshot(base,3999,base.images)];NSDictionary *stats=[terminal metalSchedulerDiagnosticsForRendererSelfTest];BOOL valid=[stats[@"displayLinkActive"] boolValue]&&[stats[@"pendingSnapshots"] unsignedIntegerValue]<=1&&[stats[@"maximumInFlightFrames"] unsignedIntegerValue]<=2&&[stats[@"coalescedSnapshots"] unsignedIntegerValue]>0&&[stats[@"generationReversals"] unsignedIntegerValue]==0&&[stats[@"lastAcceptedGeneration"] unsignedLongLongValue]==last&&[stats[@"lastSubmittedGeneration"] unsignedLongLongValue]==last;if(!valid){[window close];fprintf(stderr,"renderer-scheduler-self-test failed stage=bounded-monotonic stats=%s\n",stats.description.UTF8String);return 104;}
    TRenderMetrics resized=base.metrics;resized.viewportWidth+=17;resized.viewportHeight+=13;TRenderSnapshot *resizeSnapshot=[[TRenderSnapshot alloc]initWithGeneration:last+1 metrics:resized cells:base.cells underlineStyles:base.underlineStyles selectionMask:base.selectionMask searchMask:base.searchMask linkMask:base.linkMask graphemes:base.graphemes style:base.style links:base.links images:base.images cursorX:base.cursorX cursorY:base.cursorY cursorVisible:base.cursorVisible historyCount:base.historyCount historyOffset:base.historyOffset fullDamage:YES damagedRows:NSMakeRange(0,resized.rows)];CFAbsoluteTime resizeStart=CFAbsoluteTimeGetCurrent();if(![terminal configureRendererForSnapshotSelfTest:resizeSnapshot]){[window close];fputs("renderer-scheduler-self-test failed stage=resize-configure\n",stderr);return 105;}[terminal presentSnapshotForRendererSelfTest:resizeSnapshot];if(!TWaitForMetalGeneration(terminal,last+1,2)){[window close];fputs("renderer-scheduler-self-test failed stage=resize-timeout\n",stderr);return 106;}double resizeMilliseconds=(CFAbsoluteTimeGetCurrent()-resizeStart)*1000.0;stats=[terminal metalSchedulerDiagnosticsForRendererSelfTest];[window close];fprintf(stdout,"renderer-scheduler-self-test ok burst=%llu coalesced=%lu max-in-flight=%lu reversals=%lu resize-ms=%.3f display-link=yes\n",(unsigned long long)(last-first+1),(unsigned long)[stats[@"coalescedSnapshots"] unsignedIntegerValue],(unsigned long)[stats[@"maximumInFlightFrames"] unsignedIntegerValue],(unsigned long)[stats[@"generationReversals"] unsignedIntegerValue],resizeMilliseconds);return 0;
}

static int TRunRendererSelfTest(void) {
    [TApplication sharedApplication];
    BOOL headlessCI=getenv("CI")!=NULL;
    if(headlessCI){
        setenv("TERMATICA_METAL_FORCE_FAILURE","1",1);TConfig *headlessConfig=[TConfig new];headlessConfig.renderer=@"metal";TTerminalView *headless=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,640,400) config:headlessConfig];unsetenv("TERMATICA_METAL_FORCE_FAILURE");
        NSDictionary *headlessState=headless.diagnosticState;if(![headlessState[@"renderer"] isEqual:@"appkit"]||![headlessState[@"metalFailed"] boolValue]){fprintf(stderr,"renderer-self-test failed stage=headless-fallback renderer=%s metalFailed=%d\n",[headlessState[@"renderer"] UTF8String],[headlessState[@"metalFailed"] boolValue]);return 46;}
        [headless consumeData:[@"headless fallback renders" dataUsingEncoding:NSUTF8StringEncoding]];if(![[headless visibleText] containsString:@"headless fallback renders"]){fprintf(stderr,"renderer-self-test failed stage=headless-content\n");return 47;}
        fprintf(stdout,"renderer-self-test ok mode=headless-ci fallback=appkit\n");return 0;
    }
    setenv("TERMATICA_METAL_VALIDATE_PIXELS","1",1);
    TConfig *config=[TConfig new];config.renderer=@"metal";config.blur=NO;config.glow=config.scanlines=config.vignette=0;config.shell=@"/usr/bin/true";config.shellArguments=@[];
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,720,440) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:window.contentView.bounds config:config];terminal.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;terminal.activeTerminal=YES;window.contentView=terminal;
    unsetenv("TERMATICA_METAL_VALIDATE_PIXELS");
    if(![terminal.diagnosticState[@"renderer"] isEqual:@"metal"]){window.contentView=nil;terminal=nil;window=nil;fprintf(stdout,"renderer-self-test ok metal=unavailable fallback=appkit\n");return 0;}
    [window makeFirstResponder:terminal];[window orderFront:nil];
    NSString *tinyPNG=@"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";NSString *fixture=[NSString stringWithFormat:@"\033[2J\033[HMetal ASCII \033[31mred\033[0m λ漢字🙂 e\u0301\r\n\033[4:3munderline\033[0m\033]1337;File=inline=1:%@\a",tinyPNG];
    [terminal consumeData:[fixture dataUsingEncoding:NSUTF8StringEncoding]];
    TRenderSnapshot *first=[terminal renderSnapshot],*second=[terminal renderSnapshot];if(!first.isValid||!second.isValid||second.generation<=first.generation){fprintf(stderr,"renderer-self-test failed stage=snapshot first=%llu second=%llu\n",(unsigned long long)first.generation,(unsigned long long)second.generation);[window close];return 40;}
    [terminal setNeedsDisplay:YES];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while((![terminal.diagnosticState[@"metalFrameVaried"] boolValue]||[terminal.diagnosticState[@"renderGeneration"] unsignedLongLongValue]<second.generation)&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    NSDictionary *state=terminal.diagnosticState;if(![state[@"renderer"] isEqual:@"metal"]||[state[@"renderGeneration"] unsignedLongLongValue]==0||![state[@"metalFrameVaried"] boolValue]||[state[@"metalFrameChecksum"] unsignedLongLongValue]==0){fprintf(stderr,"renderer-self-test failed stage=pixel-readback renderer=%s generation=%llu varied=%d checksum=%llu\n",[state[@"renderer"] UTF8String],(unsigned long long)[state[@"renderGeneration"] unsignedLongLongValue],[state[@"metalFrameVaried"] boolValue],(unsigned long long)[state[@"metalFrameChecksum"] unsignedLongLongValue]);[window close];return 41;}
    for(NSUInteger i=0;i<50;i++){[terminal setFrameSize:NSMakeSize(640+(i%7)*17,380+(i%5)*13)];uint64_t generation=[terminal presentFrameForBenchmark];NSDate *resizeDeadline=[NSDate dateWithTimeIntervalSinceNow:1];while([terminal.diagnosticState[@"renderGeneration"] unsignedLongLongValue]<generation&&resizeDeadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];if([terminal.diagnosticState[@"renderGeneration"] unsignedLongLongValue]<generation){fprintf(stderr,"renderer-self-test failed stage=resize-timeout iteration=%lu\n",(unsigned long)i);[window close];return 48;}if(![terminal.diagnosticState[@"renderer"] isEqual:@"metal"]){fprintf(stderr,"renderer-self-test failed stage=resize iteration=%lu\n",(unsigned long)i);[window close];return 44;}}
    setenv("TERMATICA_METAL_FORCE_COMMAND_FAILURE","1",1);[terminal presentFrameForBenchmark];NSDate *failureDeadline=[NSDate dateWithTimeIntervalSinceNow:2];while([terminal.diagnosticState[@"renderer"] isEqual:@"metal"]&&failureDeadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];unsetenv("TERMATICA_METAL_FORCE_COMMAND_FAILURE");if(![terminal.diagnosticState[@"renderer"] isEqual:@"appkit"]||![[terminal visibleText] containsString:@"Metal ASCII"]){fprintf(stderr,"renderer-self-test failed stage=command-fallback renderer=%s text=%s\n",[terminal.diagnosticState[@"renderer"] UTF8String],[terminal visibleText].UTF8String);[window close];return 45;}
    [window close];terminal=nil;window=nil;
    setenv("TERMATICA_METAL_FORCE_FAILURE","1",1);TConfig *fallbackConfig=[TConfig new];fallbackConfig.renderer=@"metal";TTerminalView *fallback=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,640,400) config:fallbackConfig];unsetenv("TERMATICA_METAL_FORCE_FAILURE");
    NSDictionary *fallbackState=fallback.diagnosticState;if(![fallbackState[@"renderer"] isEqual:@"appkit"]||![fallbackState[@"metalFailed"] boolValue]){fprintf(stderr,"renderer-self-test failed stage=init-fallback renderer=%s metalFailed=%d\n",[fallbackState[@"renderer"] UTF8String],[fallbackState[@"metalFailed"] boolValue]);return 42;}
    [fallback consumeData:[@"fallback still renders" dataUsingEncoding:NSUTF8StringEncoding]];NSBitmapImageRep *bitmap=[fallback bitmapImageRepForCachingDisplayInRect:fallback.bounds];if(!bitmap){fprintf(stderr,"renderer-self-test failed stage=appkit-bitmap\n");return 43;}[fallback cacheDisplayInRect:fallback.bounds toBitmapImageRep:bitmap];
    fprintf(stdout,"renderer-self-test ok mode=pixel-readback metal-generation=%llu checksum=%llu fallback=appkit\n",(unsigned long long)[state[@"renderGeneration"] unsignedLongLongValue],(unsigned long long)[state[@"metalFrameChecksum"] unsignedLongLongValue]);return 0;
}

static int TRunRendererSwitchSelfTest(void) {
    [TApplication sharedApplication];
    if(getenv("CI")){
        TConfig *headlessConfig=[TConfig new];headlessConfig.renderer=@"appkit";headlessConfig.shell=@"/usr/bin/true";headlessConfig.shellArguments=@[];TTerminalView *headless=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,720,440) config:headlessConfig];[headless consumeData:[@"Headless renderer switch preserves λ漢字🙂" dataUsingEncoding:NSUTF8StringEncoding]];
        setenv("TERMATICA_METAL_FORCE_FAILURE","1",1);headlessConfig.renderer=@"metal";[headless reloadAppearance];unsetenv("TERMATICA_METAL_FORCE_FAILURE");NSDictionary *fallbackState=headless.diagnosticState;if(![fallbackState[@"renderer"] isEqual:@"appkit"]||![fallbackState[@"metalFailed"] boolValue]||![[headless visibleText] containsString:@"λ漢字🙂"]){fprintf(stderr,"renderer-switch-self-test failed stage=headless-fallback renderer=%s metalFailed=%d\n",[fallbackState[@"renderer"] UTF8String],[fallbackState[@"metalFailed"] boolValue]);return 100;}
        headlessConfig.renderer=@"appkit";[headless reloadAppearance];if(![headless.diagnosticState[@"renderer"] isEqual:@"appkit"]){fputs("renderer-switch-self-test failed stage=headless-appkit-restore\n",stderr);return 101;}fputs("renderer-switch-self-test ok mode=headless-ci forced-fallback=appkit state-preserved=yes\n",stdout);return 0;
    }
    TConfig *config=[TConfig new];config.renderer=@"appkit";config.blur=NO;config.glow=config.scanlines=config.vignette=0;config.shell=@"/usr/bin/true";config.shellArguments=@[];
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,720,440) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:window.contentView.bounds config:config];terminal.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;terminal.activeTerminal=YES;window.contentView=terminal;[window orderFront:nil];[window displayIfNeeded];
    NSString *fixture=@"Renderer switch keeps ASCII, Unicode λ漢字🙂, combining e\u0301, and terminal state";[terminal consumeData:[fixture dataUsingEncoding:NSUTF8StringEncoding]];
    if(![terminal.diagnosticState[@"renderer"] isEqual:@"appkit"]){fprintf(stderr,"renderer-switch-self-test failed stage=initial-appkit renderer=%s\n",[terminal.diagnosticState[@"renderer"] UTF8String]);[window close];return 93;}
    for(NSUInteger cycle=0;cycle<3;cycle++){
        config.renderer=@"metal";[terminal reloadAppearance];NSDictionary *metalState=terminal.diagnosticState;
        if(![metalState[@"renderer"] isEqual:@"metal"]){if([metalState[@"metalFailed"] boolValue]){[window close];fputs("renderer-switch-self-test ok metal=unavailable semantic-only appkit-state-preserved=yes\n",stdout);return 0;}fprintf(stderr,"renderer-switch-self-test failed stage=select-metal cycle=%lu renderer=%s\n",(unsigned long)cycle,[metalState[@"renderer"] UTF8String]);[window close];return 94;}
        uint64_t generation=[terminal presentFrameForBenchmark];if(!TWaitForMetalGeneration(terminal,generation,3)){fprintf(stderr,"renderer-switch-self-test failed stage=metal-present cycle=%lu expected=%llu actual=%llu\n",(unsigned long)cycle,(unsigned long long)generation,(unsigned long long)[terminal.diagnosticState[@"renderGeneration"] unsignedLongLongValue]);[window close];return 95;}
        if(![[terminal visibleText] containsString:@"Renderer switch keeps ASCII"]||![[terminal visibleText] containsString:@"λ漢字🙂"]){fprintf(stderr,"renderer-switch-self-test failed stage=metal-content cycle=%lu\n",(unsigned long)cycle);[window close];return 96;}
        config.renderer=@"appkit";[terminal reloadAppearance];if(![terminal.diagnosticState[@"renderer"] isEqual:@"appkit"]){fprintf(stderr,"renderer-switch-self-test failed stage=select-appkit cycle=%lu renderer=%s\n",(unsigned long)cycle,[terminal.diagnosticState[@"renderer"] UTF8String]);[window close];return 97;}
        NSBitmapImageRep *bitmap=[terminal bitmapImageRepForCachingDisplayInRect:terminal.bounds];if(!bitmap){fprintf(stderr,"renderer-switch-self-test failed stage=appkit-surface cycle=%lu\n",(unsigned long)cycle);[window close];return 98;}[terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];
        if(![[terminal visibleText] containsString:@"terminal state"]){fprintf(stderr,"renderer-switch-self-test failed stage=appkit-content cycle=%lu\n",(unsigned long)cycle);[window close];return 99;}
    }
    [window close];fputs("renderer-switch-self-test ok cycles=3 appkit-to-metal=yes metal-to-appkit=yes state-preserved=yes\n",stdout);return 0;
}

static void TWriteBenchmarkJSON(NSData *json) {const uint8_t *bytes=json.bytes;NSUInteger remaining=json.length;while(remaining){ssize_t written=write(STDOUT_FILENO,bytes,remaining);if(written<=0)break;bytes+=written;remaining-=(NSUInteger)written;}write(STDOUT_FILENO,"\n",1);}

static int TRunMetalBenchmark(NSUInteger requestedFrames) {
    [TApplication sharedApplication];NSUInteger frames=MAX((NSUInteger)30,MIN((NSUInteger)1200,requestedFrames?:240));
    TConfig *config=[TConfig new];config.renderer=@"metal";config.blur=NO;config.glow=config.scanlines=config.vignette=0;config.shell=@"/usr/bin/true";config.shellArguments=@[];config.scrollback=10000;
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1000,700) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];window.releasedWhenClosed=NO;TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:window.contentView.bounds config:config];terminal.activeTerminal=YES;window.contentView=terminal;[window makeFirstResponder:terminal];[window orderFront:nil];
    if(![terminal.diagnosticState[@"renderer"] isEqual:@"metal"]){[window close];fputs("Metal unavailable\n",stderr);return 2;}
    NSMutableString *history=[NSMutableString string];for(NSUInteger i=0;i<5000;i++)[history appendFormat:@"metal-frame-%05lu ASCII λ漢字🙂 e\u0301 \033[38;2;89;194;255mcolor\033[0m\r\n",(unsigned long)i];[terminal consumeData:[history dataUsingEncoding:NSUTF8StringEncoding]];[terminal scrollByLines:1000];
    for(NSUInteger i=0;i<8;i++){uint64_t generation=[terminal presentFrameForBenchmarkWithScrollDelta:0];while([terminal.diagnosticState[@"renderGeneration"] unsignedLongLongValue]<generation)usleep(25);}
    double *paint=calloc(frames,sizeof(double)),*snapshotBuild=calloc(frames,sizeof(double)),*cpuEncode=calloc(frames,sizeof(double)),*gpuExecution=calloc(frames,sizeof(double)),*snapshotWait=calloc(frames,sizeof(double)),*gpuCompletion=calloc(frames,sizeof(double)),*presentInterval=calloc(frames,sizeof(double));for(NSUInteger i=0;i<frames;i++){@autoreleasepool{uint64_t generation=[terminal presentFrameForBenchmarkWithScrollDelta:(i%120)<60?1:-1];while([terminal.diagnosticState[@"renderGeneration"] unsignedLongLongValue]<generation)usleep(25);NSDictionary *timing=terminal.diagnosticState;snapshotBuild[i]=[timing[@"snapshotBuildMs"] doubleValue];cpuEncode[i]=[timing[@"metalCPUEncodeMs"] doubleValue];gpuExecution[i]=[timing[@"metalGPUExecutionMs"] doubleValue];snapshotWait[i]=[timing[@"metalSnapshotWaitMs"] doubleValue];gpuCompletion[i]=[timing[@"metalGPUCompletionMs"] doubleValue];presentInterval[i]=[timing[@"metalPresentIntervalMs"] doubleValue];paint[i]=snapshotBuild[i]+cpuEncode[i]+gpuExecution[i];}}
    NSDictionary *(^percentiles)(double *)=^NSDictionary *(double *values){return @{@"p50":@(TPercentile(values,frames,0.50)),@"p95":@(TPercentile(values,frames,0.95)),@"p99":@(TPercentile(values,frames,0.99))};};NSUInteger missed60=0,missed120=0,missed240=0;for(NSUInteger i=0;i<frames;i++){if(paint[i]>16.667)missed60++;if(paint[i]>8.333)missed120++;if(paint[i]>4.167)missed240++;}NSDictionary *paintStats=percentiles(paint),*snapshotStats=percentiles(snapshotBuild),*encodeStats=percentiles(cpuEncode),*gpuStats=percentiles(gpuExecution),*waitStats=percentiles(snapshotWait),*completionStats=percentiles(gpuCompletion),*intervalStats=percentiles(presentInterval);free(paint);free(snapshotBuild);free(cpuEncode);free(gpuExecution);free(snapshotWait);free(gpuCompletion);free(presentInterval);uint64_t generation=[terminal.diagnosticState[@"renderGeneration"] unsignedLongLongValue];NSDictionary *cache=[terminal metalCacheDiagnosticsForRendererSelfTest],*scheduler=[terminal metalSchedulerDiagnosticsForRendererSelfTest];[window close];
    NSDictionary *result=@{@"schema_version":@5,@"engine":@"Termatica Core/Metal",@"methodology":@"snapshot build plus CPU command encoding plus GPU execution; excludes refresh wait, display-vsync wait, and scanout; scheduler timings are reported separately",@"frames":@(frames),@"generation":@(generation),@"cache":cache?:@{},@"scheduler":scheduler?:@{},@"paint_ms":@{@"p50":paintStats[@"p50"],@"p95":paintStats[@"p95"],@"p99":paintStats[@"p99"],@"over_60hz_budget":@(missed60),@"over_120hz_budget":@(missed120),@"over_240hz_budget":@(missed240)},@"stages_ms":@{@"snapshot_build":snapshotStats,@"cpu_encode":encodeStats,@"gpu_execution":gpuStats,@"snapshot_wait":waitStats,@"gpu_completion":completionStats,@"present_interval":intervalStats}};NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];TWriteBenchmarkJSON(json);return 0;
}

static int TRunCoreBenchmark(NSUInteger requestedBytes) {
    [TApplication sharedApplication];NSUInteger bytes=MAX((NSUInteger)1048576,MIN((NSUInteger)268435456,requestedBytes?:33554432));TConfig *config=[TConfig new];config.scrollback=2000;TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,1200,800) config:config];NSArray<NSDictionary *> *cases=@[@{@"name":@"ascii",@"pattern":@"benchmark plain terminal text 0123456789 abcdefghijklmnopqrstuvwxyz\r\n"},@{@"name":@"unicode",@"pattern":@"Unicode λ漢字🙂 composed e\u0301 terminal rendering\r\n"},@{@"name":@"csi",@"pattern":@"\033[38;2;89;194;255mcyan\033[0m \033[1mbold\033[0m \033[2Kbenchmark\r\n"}];NSMutableArray *results=[NSMutableArray array];
    for(NSDictionary *item in cases){NSData *pattern=[item[@"pattern"] dataUsingEncoding:NSUTF8StringEncoding];NSMutableData *chunk=[NSMutableData dataWithCapacity:32768];while(chunk.length+pattern.length<=32768)[chunk appendData:pattern];NSUInteger consumed=0;CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();while(consumed<bytes){NSUInteger take=MIN(chunk.length,bytes-consumed);[terminal consumeData:take==chunk.length?chunk:[chunk subdataWithRange:NSMakeRange(0,take)]];consumed+=take;}double seconds=CFAbsoluteTimeGetCurrent()-start,mbps=(double)consumed/1048576.0/MAX(0.000001,seconds);[results addObject:@{@"case":item[@"name"],@"bytes":@(consumed),@"seconds":@(seconds),@"mib_per_second":@(mbps)}];}
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"engine":@"Termatica Core/AppKit",@"bytes_per_case":@(bytes),@"results":results} options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];TWriteBenchmarkJSON(json);return 0;
}

typedef struct {uint64_t hash;NSUInteger asciiBytes,codepoints,controls,escapes,csi,strings;} TDecoderMetrics;
typedef struct {uint32_t values[16];NSUInteger count;} TDecoderCodepointCapture;
static void TCaptureCodepoints(void *context,const uint32_t *values,size_t count){TDecoderCodepointCapture *capture=context;for(size_t i=0;i<count&&capture->count<16;i++)capture->values[capture->count++]=values[i];}
static inline void TDecoderMetricMix(TDecoderMetrics *metrics,uint64_t value){metrics->hash^=value+0x9e3779b97f4a7c15ULL+(metrics->hash<<6)+(metrics->hash>>2);}
static void TMetricASCII(void *context,const uint8_t *bytes,size_t length){TDecoderMetrics *m=context;m->asciiBytes+=length;for(size_t i=0;i<length;i++)TDecoderMetricMix(m,bytes[i]);}
static void TMetricCodepoint(void *context,uint32_t value){TDecoderMetrics *m=context;m->codepoints++;TDecoderMetricMix(m,0x100000000ULL|value);}
static void TMetricControl(void *context,uint8_t value){TDecoderMetrics *m=context;m->controls++;TDecoderMetricMix(m,0x200000000ULL|value);}
static void TMetricEscape(void *context,uint8_t value){TDecoderMetrics *m=context;m->escapes++;TDecoderMetricMix(m,0x300000000ULL|value);}
static void TMetricCSI(void *context,uint8_t finalByte,uint8_t prefix,uint8_t intermediate,const int *parameters,size_t count){TDecoderMetrics *m=context;m->csi++;TDecoderMetricMix(m,0x400000000ULL|((uint64_t)prefix<<16)|((uint64_t)intermediate<<8)|finalByte);for(size_t i=0;i<count;i++)TDecoderMetricMix(m,(uint32_t)parameters[i]);}
static void TMetricString(void *context,const uint8_t *bytes,size_t length){TDecoderMetrics *m=context;m->strings++;TDecoderMetricMix(m,0x500000000ULL|length);for(size_t i=0;i<length;i++)TDecoderMetricMix(m,bytes[i]);}
static TDecoderSink TMetricSink(TDecoderMetrics *metrics){return (TDecoderSink){.context=metrics,.ascii=TMetricASCII,.codepoint=TMetricCodepoint,.control=TMetricControl,.escape=TMetricEscape,.csi=TMetricCSI,.string=TMetricString};}

static int TRunDecoderSelfTest(void) {
    NSMutableData *fixture=[[@"plain λ漢字🙂 e\u0301\r\n\033[38;2;89;194;255mcolor\033[0m\033]0;title\a\033Pbsu\033\\" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];const uint8_t invalid[]={0xF0,0x28,0x8C,0x28};[fixture appendBytes:invalid length:sizeof(invalid)];
    TDecoderMetrics expected={.hash=1469598103934665603ULL};TDecoderState decoder;TDecoderInit(&decoder);TDecoderSink sink=TMetricSink(&expected);TDecoderConsume(&decoder,fixture.bytes,fixture.length,&sink);TDecoderDestroy(&decoder);
    for(NSUInteger chunkSize=1;chunkSize<=31;chunkSize++){
        TDecoderMetrics actual={.hash=1469598103934665603ULL};TDecoderInit(&decoder);sink=TMetricSink(&actual);
        for(NSUInteger offset=0;offset<fixture.length;offset+=chunkSize){NSUInteger length=MIN(chunkSize,fixture.length-offset);TDecoderConsume(&decoder,(const uint8_t *)fixture.bytes+offset,length,&sink);}
        TDecoderDestroy(&decoder);
        if(memcmp(&expected,&actual,sizeof(expected))!=0){fprintf(stderr,"decoder chunk mismatch at %lu\n",(unsigned long)chunkSize);return 1;}
    }
    NSMutableData *ignoredOSC=[NSMutableData data];NSMutableData *payload=[NSMutableData dataWithLength:8024];memset(payload.mutableBytes,'x',payload.length);
    for(NSUInteger i=0;i<3;i++){[ignoredOSC appendBytes:"\033]6;" length:4];[ignoredOSC appendData:payload];[ignoredOSC appendBytes:"\a" length:1];}[ignoredOSC appendBytes:"after" length:5];
    const NSUInteger ignoredChunks[]={1,2,3,4,7,31,255,4096,8024,8192};
    for(NSUInteger test=0;test<sizeof(ignoredChunks)/sizeof(ignoredChunks[0]);test++){
        NSUInteger chunkSize=ignoredChunks[test];TDecoderMetrics actual={.hash=1469598103934665603ULL};TDecoderInit(&decoder);sink=TMetricSink(&actual);
        for(NSUInteger offset=0;offset<ignoredOSC.length;offset+=chunkSize){NSUInteger length=MIN(chunkSize,ignoredOSC.length-offset);TDecoderConsume(&decoder,(const uint8_t *)ignoredOSC.bytes+offset,length,&sink);}
        TDecoderDestroy(&decoder);
        if(actual.strings!=0||actual.asciiBytes!=5){fprintf(stderr,"ignored OSC 6 mismatch at %lu strings=%lu ascii=%lu\n",(unsigned long)chunkSize,(unsigned long)actual.strings,(unsigned long)actual.asciiBytes);return 2;}
    }
    const uint8_t validation[]={0xC0,0xAF,0xED,0xA0,0x80,0xF4,0x90,0x80,0x80,0xF0,0x9F,0x99,0x82,'\n'};const uint32_t validExpected[]={0xFFFD,0xFFFD,0xFFFD,0xFFFD,0x1F642};TDecoderCodepointCapture capture={0};TDecoderInit(&decoder);TDecoderSink validationSink={.context=&capture,.codepoints=TCaptureCodepoints};TDecoderConsume(&decoder,validation,sizeof(validation),&validationSink);TDecoderDestroy(&decoder);if(capture.count!=5||memcmp(capture.values,validExpected,sizeof(validExpected))!=0){fprintf(stderr,"UTF-8 scalar validation mismatch count=%lu\n",(unsigned long)capture.count);return 3;}
    fprintf(stdout,"decoder-self-test ok hash=%llu\n",(unsigned long long)expected.hash);return 0;
}

static int TRunDecoderBenchmark(NSUInteger requestedBytes) {
    NSUInteger bytes=MAX((NSUInteger)1048576,MIN((NSUInteger)268435456,requestedBytes?:33554432));
    NSArray<NSDictionary *> *cases=@[@{@"name":@"ascii",@"pattern":@"benchmark plain terminal text 0123456789 abcdefghijklmnopqrstuvwxyz\r\n"},@{@"name":@"unicode",@"pattern":@"Unicode λ漢字🙂 composed e\u0301 terminal decoding\r\n"},@{@"name":@"csi",@"pattern":@"\033[38;2;89;194;255mcyan\033[0m \033[1mbold\033[0m \033[2Kbenchmark\r\n"}];
    NSMutableArray *results=[NSMutableArray array];
    for(NSDictionary *item in cases){
        NSData *pattern=[item[@"pattern"] dataUsingEncoding:NSUTF8StringEncoding];NSMutableData *chunk=[NSMutableData dataWithCapacity:32768];while(chunk.length+pattern.length<=32768)[chunk appendData:pattern];
        TDecoderState decoder;TDecoderInit(&decoder);TDecoderMetrics metrics={.hash=1469598103934665603ULL};TDecoderSink sink=TMetricSink(&metrics);NSUInteger consumed=0;CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
        while(consumed<bytes){NSUInteger take=MIN(chunk.length,bytes-consumed);TDecoderConsume(&decoder,chunk.bytes,take,&sink);consumed+=take;}
        double seconds=CFAbsoluteTimeGetCurrent()-start;TDecoderDestroy(&decoder);[results addObject:@{@"case":item[@"name"],@"bytes":@(consumed),@"seconds":@(seconds),@"mib_per_second":@((double)consumed/1048576.0/MAX(0.000001,seconds)),@"event_hash":@(metrics.hash)}];
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"schema_version":@1,@"engine":@"Termatica C decoder",@"bytes_per_case":@(bytes),@"results":results} options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];TWriteBenchmarkJSON(json);return 0;
}

static int TCompareDouble(const void *left,const void *right){double a=*(const double *)left,b=*(const double *)right;return a<b?-1:(a>b?1:0);}
static double TPercentile(double *values,NSUInteger count,double percentile){if(!count)return 0;qsort(values,count,sizeof(double),TCompareDouble);NSUInteger index=(NSUInteger)MIN((double)(count-1),ceil(percentile*(double)count)-1);return values[index];}
static NSDictionary *TRunEquivalentRendererCase(NSString *renderer,NSUInteger frames) {
    TConfig *config=[TConfig new];config.renderer=renderer;config.scrollback=10000;config.blur=NO;config.glow=config.scanlines=config.vignette=0;config.unicodeRendering=YES;config.shell=@"/usr/bin/true";config.shellArguments=@[];NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1000,700) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];window.releasedWhenClosed=NO;TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:window.contentView.bounds config:config];terminal.activeTerminal=YES;window.contentView=terminal;[window makeFirstResponder:terminal];[window orderFront:nil];[window displayIfNeeded];BOOL metal=[renderer isEqual:@"metal"];if(metal&&![terminal.diagnosticState[@"renderer"] isEqual:@"metal"]){[window close];return @{@"available":@NO,@"reason":@"Metal unavailable"};}
    NSMutableString *history=[NSMutableString string];for(NSUInteger i=0;i<5000;i++)[history appendFormat:@"renderer-frame-%05lu ASCII λ漢字🙂 é \033[38;2;89;194;255mcolor\033[0m\r\n",(unsigned long)i];[terminal consumeData:[history dataUsingEncoding:NSUTF8StringEncoding]];[terminal scrollByLines:1000];NSBitmapImageRep *bitmap=metal?nil:[terminal bitmapImageRepForCachingDisplayInRect:terminal.bounds];if(!metal&&!bitmap){[window close];return @{@"available":@NO,@"reason":@"AppKit bitmap allocation failed"};}
    for(NSUInteger i=0;i<8;i++){uint64_t generation=[terminal presentFrameForBenchmarkWithScrollDelta:0];if(metal){if(!TWaitForMetalGeneration(terminal,generation,3)){[window close];return @{@"available":@NO,@"reason":@"Metal warmup timeout"};}}else [terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];}
    double *work=calloc(frames,sizeof(double)),*snapshotWait=calloc(frames,sizeof(double)),*cpuEncode=calloc(frames,sizeof(double)),*gpuExecution=calloc(frames,sizeof(double)),*gpuCompletion=calloc(frames,sizeof(double)),*presentInterval=calloc(frames,sizeof(double));BOOL completed=YES;for(NSUInteger i=0;i<frames;i++){@autoreleasepool{CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();uint64_t generation=[terminal presentFrameForBenchmarkWithScrollDelta:(i%120)<60?1:-1];if(metal){if(!TWaitForMetalGeneration(terminal,generation,3)){completed=NO;break;}NSDictionary *timing=terminal.diagnosticState;work[i]=[timing[@"snapshotBuildMs"] doubleValue]+[timing[@"metalCPUEncodeMs"] doubleValue]+[timing[@"metalGPUExecutionMs"] doubleValue];snapshotWait[i]=[timing[@"metalSnapshotWaitMs"] doubleValue];cpuEncode[i]=[timing[@"metalCPUEncodeMs"] doubleValue];gpuExecution[i]=[timing[@"metalGPUExecutionMs"] doubleValue];gpuCompletion[i]=[timing[@"metalGPUCompletionMs"] doubleValue];presentInterval[i]=[timing[@"metalPresentIntervalMs"] doubleValue];}else{[terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];work[i]=(CFAbsoluteTimeGetCurrent()-start)*1000.0;}}}
    if(!completed){free(work);free(snapshotWait);free(cpuEncode);free(gpuExecution);free(gpuCompletion);free(presentInterval);[window close];return @{@"available":@NO,@"reason":@"renderer frame timeout"};}NSUInteger over60=0,over120=0,over240=0;for(NSUInteger i=0;i<frames;i++){over60+=work[i]>16.667;over120+=work[i]>8.333;over240+=work[i]>4.167;}NSDictionary *(^percentiles)(double *)=^NSDictionary *(double *values){return @{@"p50":@(TPercentile(values,frames,0.50)),@"p95":@(TPercentile(values,frames,0.95)),@"p99":@(TPercentile(values,frames,0.99))};};NSDictionary *workStats=percentiles(work),*waitStats=percentiles(snapshotWait),*encodeStats=percentiles(cpuEncode),*gpuStats=percentiles(gpuExecution),*completionStats=percentiles(gpuCompletion),*intervalStats=percentiles(presentInterval),*scheduler=metal?[terminal metalSchedulerDiagnosticsForRendererSelfTest]:@{};free(work);free(snapshotWait);free(cpuEncode);free(gpuExecution);free(gpuCompletion);free(presentInterval);[window close];return @{@"available":@YES,@"frames":@(frames),@"work_ms":@{@"p50":workStats[@"p50"],@"p95":workStats[@"p95"],@"p99":workStats[@"p99"],@"over_60hz_budget":@(over60),@"over_120hz_budget":@(over120),@"over_240hz_budget":@(over240)},@"snapshot_wait_ms":waitStats,@"cpu_encode_ms":encodeStats,@"gpu_execution_ms":gpuStats,@"gpu_completion_ms":completionStats,@"present_interval_ms":intervalStats,@"scheduler":scheduler};
}
static inline uint64_t TBenchmarkNanoseconds(void){return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);}
static double TUsageSeconds(struct rusage usage){return usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1000000.0+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1000000.0;}
static BOOL TProcessEnergy(struct rusage_info_v6 *usage){memset(usage,0,sizeof(*usage));return proc_pid_rusage(getpid(),RUSAGE_INFO_V6,(rusage_info_t *)usage)==0;}
static int TRunExperienceBenchmark(NSUInteger requestedFrames,double requestedSeconds) {
    [TApplication sharedApplication];NSUInteger frames=MAX((NSUInteger)30,MIN((NSUInteger)1200,requestedFrames?:240));double sustainedSeconds=MAX(0.5,MIN(30.0,requestedSeconds>0?requestedSeconds:3.0));TConfig *config=[TConfig new];config.scrollback=10000;config.blur=NO;config.glow=config.scanlines=config.vignette=0;config.unicodeRendering=YES;TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,1000,700) config:config];
    NSMutableString *history=[NSMutableString string];for(NSUInteger i=0;i<5000;i++)[history appendFormat:@"frame-%05lu  ascii terminal rendering and scrollback  != -> 0123456789\r\n",(unsigned long)i];[terminal consumeData:[history dataUsingEncoding:NSUTF8StringEncoding]];[terminal scrollByLines:1000];
    NSBitmapImageRep *bitmap=[terminal bitmapImageRepForCachingDisplayInRect:terminal.bounds];if(!bitmap){fputs("could not allocate render benchmark surface\n",stderr);return 2;}double *paint=calloc(frames,sizeof(double)),*interaction=calloc(frames,sizeof(double)),*inputMapping=calloc(frames,sizeof(double)),*echoParse=calloc(frames,sizeof(double)),*inputPaint=calloc(frames,sizeof(double)),*keyToPaint=calloc(frames,sizeof(double));
    [terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];
    NSEvent *keyEvent=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"x" charactersIgnoringModifiers:@"x" isARepeat:NO keyCode:7];
    for(NSUInteger i=0;i<frames;i++){@autoreleasepool{NSInteger direction=(i%120)<60?1:-1;CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();[terminal scrollByLines:direction];[terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];paint[i]=(CFAbsoluteTimeGetCurrent()-start)*1000.0;NSString *update=[NSString stringWithFormat:@"\rinteraction-%06lu",(unsigned long)i];start=CFAbsoluteTimeGetCurrent();[terminal consumeData:[update dataUsingEncoding:NSUTF8StringEncoding]];[terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];interaction[i]=(CFAbsoluteTimeGetCurrent()-start)*1000.0;[terminal startDiagnosticInputCapture];uint64_t totalStart=TBenchmarkNanoseconds();[terminal keyDown:keyEvent];NSData *loopback=[terminal finishDiagnosticInputCapture];uint64_t mapped=TBenchmarkNanoseconds();[terminal consumeData:loopback];uint64_t parsed=TBenchmarkNanoseconds();[terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];uint64_t painted=TBenchmarkNanoseconds();inputMapping[i]=(double)(mapped-totalStart)/1e6;echoParse[i]=(double)(parsed-mapped)/1e6;inputPaint[i]=(double)(painted-parsed)/1e6;keyToPaint[i]=(double)(painted-totalStart)/1e6;}}
    NSData *pattern=[@"sustained terminal output λ漢字🙂 \033[38;2;89;194;255mcolor\033[0m 0123456789\r\n" dataUsingEncoding:NSUTF8StringEncoding];NSMutableData *chunk=[NSMutableData dataWithCapacity:65536];while(chunk.length+pattern.length<=65536)[chunk appendData:pattern];struct rusage before={0},after={0};struct rusage_info_v6 energyBefore={0},energyAfter={0};BOOL energySupported=TProcessEnergy(&energyBefore);getrusage(RUSAGE_SELF,&before);CFAbsoluteTime sustainedStart=CFAbsoluteTimeGetCurrent(),deadline=sustainedStart+sustainedSeconds;NSUInteger bytes=0;NSMutableArray<NSNumber *> *windows=[NSMutableArray array];CFAbsoluteTime windowStart=sustainedStart;NSUInteger windowBytes=0;while(CFAbsoluteTimeGetCurrent()<deadline){[terminal consumeData:chunk];bytes+=chunk.length;windowBytes+=chunk.length;CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();if(now-windowStart>=0.25){[windows addObject:@((double)windowBytes/1048576.0/(now-windowStart))];windowStart=now;windowBytes=0;}}CFAbsoluteTime sustainedEnd=CFAbsoluteTimeGetCurrent();getrusage(RUSAGE_SELF,&after);energySupported=energySupported&&TProcessEnergy(&energyAfter)&&energyAfter.ri_energy_nj>=energyBefore.ri_energy_nj;double wall=sustainedEnd-sustainedStart,cpu=TUsageSeconds(after)-TUsageSeconds(before),mean=0,minimum=DBL_MAX,energyJoules=energySupported?(double)(energyAfter.ri_energy_nj-energyBefore.ri_energy_nj)/1e9:0;for(NSNumber *number in windows){mean+=number.doubleValue;minimum=MIN(minimum,number.doubleValue);}if(windows.count)mean/=windows.count;double variance=0;for(NSNumber *number in windows){double delta=number.doubleValue-mean;variance+=delta*delta;}double coefficient=windows.count&&mean>0?sqrt(variance/windows.count)/mean:0;
    double paintP50=TPercentile(paint,frames,0.50),paintP95=TPercentile(paint,frames,0.95),paintP99=TPercentile(paint,frames,0.99),interactionP50=TPercentile(interaction,frames,0.50),interactionP95=TPercentile(interaction,frames,0.95),interactionP99=TPercentile(interaction,frames,0.99),mappingP50=TPercentile(inputMapping,frames,0.50),mappingP95=TPercentile(inputMapping,frames,0.95),mappingP99=TPercentile(inputMapping,frames,0.99),parseP50=TPercentile(echoParse,frames,0.50),parseP95=TPercentile(echoParse,frames,0.95),parseP99=TPercentile(echoParse,frames,0.99),inputPaintP50=TPercentile(inputPaint,frames,0.50),inputPaintP95=TPercentile(inputPaint,frames,0.95),inputPaintP99=TPercentile(inputPaint,frames,0.99),keyP50=TPercentile(keyToPaint,frames,0.50),keyP95=TPercentile(keyToPaint,frames,0.95),keyP99=TPercentile(keyToPaint,frames,0.99);NSUInteger missed60=0,missed120=0,missed240=0;for(NSUInteger i=0;i<frames;i++){if(paint[i]>16.667)missed60++;if(paint[i]>8.333)missed120++;if(paint[i]>4.167)missed240++;}free(paint);free(interaction);free(inputMapping);free(echoParse);free(inputPaint);free(keyToPaint);
    NSDictionary *rendererComparison=@{@"methodology":@"identical 1000x700 Unicode/ANSI viewport, full-row scroll damage, eight warmup frames, and equal measured frame counts; AppKit work is snapshot plus offscreen CoreText paint, Metal work is snapshot plus CPU encoding plus GPU execution; display wait is reported separately",@"appkit":TRunEquivalentRendererCase(@"appkit",frames),@"metal":TRunEquivalentRendererCase(@"metal",frames)};NSDictionary *result=@{@"schema_version":@5,@"engine":@"Termatica Core/AppKit",@"methodology":@{@"paint":@"warmed offscreen full-surface AppKit cacheDisplay of an ASCII terminal viewport after one-line scroll",@"key_to_paint":@"synthetic NSEvent through Termatica input mapping, looped back as immediate PTY echo, parsed and painted to a full-surface AppKit bitmap; software lower bound, not physical key-to-photon",@"energy":@"macOS process-attributed ri_energy_nj during sustained Unicode/ANSI parsing; excludes display and whole-system energy"},@"frames":@(frames),@"paint_ms":@{@"p50":@(paintP50),@"p95":@(paintP95),@"p99":@(paintP99),@"over_60hz_budget":@(missed60),@"over_120hz_budget":@(missed120),@"over_240hz_budget":@(missed240)},@"parse_to_paint_ms":@{@"p50":@(interactionP50),@"p95":@(interactionP95),@"p99":@(interactionP99)},@"input_latency_stage_ms":@{@"event_mapping":@{@"p50":@(mappingP50),@"p95":@(mappingP95),@"p99":@(mappingP99)},@"echo_parse":@{@"p50":@(parseP50),@"p95":@(parseP95),@"p99":@(parseP99)},@"appkit_paint":@{@"p50":@(inputPaintP50),@"p95":@(inputPaintP95),@"p99":@(inputPaintP99)}},@"key_to_paint_lower_bound_ms":@{@"p50":@(keyP50),@"p95":@(keyP95),@"p99":@(keyP99)},@"process_energy":@{@"supported":@(energySupported),@"joules":@(energyJoules),@"average_watts":@(wall>0?energyJoules/wall:0),@"joules_per_gib":@(bytes?energyJoules/((double)bytes/1073741824.0):0)},@"sustained":@{@"wall_seconds":@(wall),@"bytes":@(bytes),@"mib_per_second":@((double)bytes/1048576.0/wall),@"minimum_250ms_window_mib_per_second":@(minimum==DBL_MAX?0:minimum),@"window_coefficient_of_variation":@(coefficient),@"cpu_seconds":@(cpu),@"cpu_seconds_per_wall_second":@(cpu/wall)},@"renderer_comparison":rendererComparison};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];TWriteBenchmarkJSON(json);return 0;
}
static int TRunBenchmarkResultsSelfTest(void) {
    [TApplication sharedApplication];NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"termatica-native-results-%@",NSUUID.UUID.UUIDString]];if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil])return 70;
    NSString *matrix=@"mode\tworkload\ttermatica\tkitty\tghostty\talacritty\twezterm\trio\nparser\tASCII\t10.0\t20.0\t8.0\t12.0\t5.0\t9.0\nparser\tUnicode\t10.0\t19.0\t8.0\t12.0\t5.0\t9.0\nparser\tUnique graphemes\t10.0\t18.0\t8.0\t12.0\t5.0\t9.0\nparser\tCSI-heavy\t10.0\t17.0\t8.0\t12.0\t5.0\t9.0\nparser\tLong escapes\t10.0\t16.0\t8.0\t12.0\t5.0\t9.0\nparser\tImage stream\t10.0\t15.0\t8.0\t12.0\t5.0\t9.0\nrender\tASCII\t11.0\t20.0\t8.0\t12.0\t5.0\t9.0\nrender\tUnicode\t11.0\t19.0\t8.0\t12.0\t5.0\t9.0\nrender\tUnique graphemes\t11.0\t18.0\t8.0\t12.0\t5.0\t9.0\nrender\tCSI-heavy\t11.0\t17.0\t8.0\t12.0\t5.0\t9.0\nrender\tLong escapes\t11.0\t16.0\t8.0\t12.0\t5.0\t9.0\nrender\tImage stream\t11.0\t15.0\t8.0\t12.0\t5.0\t9.0\nsummary\t12-workload geo mean\t10.5\t17.4\t8.0\t12.0\t5.0\t9.0\n";NSString *manifest=@"timestamp_utc\t20260810T000000Z\nrepetitions\t1\nfont\tMonaco 11\nmode\ttermatica\ntermatica\tOK\tFRESH\t20260810T000000Z\tTermatica 1.5.0\nkitty\tOK\tSAVED\t20260809T000000Z\tkitty\nghostty\tOK\tSAVED\t20260809T000000Z\tGhostty\nalacritty\tOK\tSAVED\t20260809T000000Z\talacritty\nwezterm\tOK\tSAVED\t20260809T000000Z\twezterm\nrio\tOK\tSAVED\t20260809T000000Z\trio\n";[matrix writeToFile:[directory stringByAppendingPathComponent:@"matrix.tsv"] atomically:YES encoding:NSUTF8StringEncoding error:nil];[manifest writeToFile:[directory stringByAppendingPathComponent:@"manifest.tsv"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    TBenchmarkResultsController *controller=[[TBenchmarkResultsController alloc]initWithArtifactPath:directory current:@{@"metadata":@{@"Version":@"1.5.0"},@"metrics":@[@{@"workload":@"ASCII",@"rate":@"10 MiB/s"}]}];@try{[controller.window.contentView layoutSubtreeIfNeeded];}@catch(NSException *exception){fprintf(stderr,"benchmark-results-self-test exception name=%s reason=%s\n",exception.name.UTF8String,exception.reason.UTF8String);[controller close];[NSFileManager.defaultManager removeItemAtPath:directory error:nil];return 72;}NSString *text=controller.comparisonTextView.string;NSRange winnerRange=[text rangeOfString:@"20.0"];NSFont *winnerFont=winnerRange.location==NSNotFound?nil:[controller.comparisonTextView.textStorage attribute:NSFontAttributeName atIndex:winnerRange.location effectiveRange:nil];BOOL bold=winnerFont&&([NSFontManager.sharedFontManager traitsOfFont:winnerFont]&NSBoldFontMask);BOOL compact=controller.window.contentLayoutRect.size.width<=660&&controller.window.contentLayoutRect.size.height<=430;BOOL geometry=controller.comparisonTextView.frame.size.width>0&&controller.comparisonTextView.frame.size.height>0;BOOL complete=[text containsString:@"PARSER"]&&[text containsString:@"RENDER"]&&[text containsString:@"SUMMARY"]&&[text containsString:@"Kitty"]&&[text containsString:@"MS/MiB"]&&[text containsString:@"SAVED"];BOOL noWrap=!controller.comparisonTextView.textContainer.widthTracksTextView&&controller.comparisonTextView.horizontallyResizable;BOOL valid=geometry&&controller.comparisonRows.count==13&&controller.statusRows.count==6&&controller.currentRows.count==2&&complete&&noWrap;if(!compact||!valid||!bold)fprintf(stderr,"benchmark-results-self-test failed compact=%d valid=%d geometry=%d complete=%d noWrap=%d bold=%d size=%.0fx%.0f text=%.0fx%.0f comparison=%lu status=%lu current=%lu length=%lu\n",compact,valid,geometry,complete,noWrap,bold,controller.window.contentLayoutRect.size.width,controller.window.contentLayoutRect.size.height,controller.comparisonTextView.frame.size.width,controller.comparisonTextView.frame.size.height,(unsigned long)controller.comparisonRows.count,(unsigned long)controller.statusRows.count,(unsigned long)controller.currentRows.count,(unsigned long)text.length);[controller close];[NSFileManager.defaultManager removeItemAtPath:directory error:nil];if(!compact||!valid||!bold)return 71;fputs("benchmark-results-self-test ok adaptive-text all-data no-wrap winner=bold\n",stdout);return 0;
}
#endif

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TProcessStartedAt = CFAbsoluteTimeGetCurrent();
        NSString *invoked=[NSString stringWithUTF8String:argv[0]].lastPathComponent;
#if TERMATICA_BENCHMARKS
        if(argc>1&&!strcmp(argv[1],"--terminal-self-test"))return TRunTerminalSelfTest();
        if(argc>1&&!strcmp(argv[1],"--renderer-self-test"))return TRunRendererSelfTest();
        if(argc>1&&!strcmp(argv[1],"--renderer-switch-self-test"))return TRunRendererSwitchSelfTest();
        if(argc>1&&!strcmp(argv[1],"--renderer-parity-self-test"))return TRunRendererParityCorpus();
        if(argc>1&&!strcmp(argv[1],"--renderer-cache-self-test"))return TRunRendererCacheSelfTest();
        if(argc>1&&!strcmp(argv[1],"--renderer-scheduler-self-test"))return TRunRendererSchedulerSelfTest();
        if(argc>1&&!strcmp(argv[1],"--benchmark-results-self-test"))return TRunBenchmarkResultsSelfTest();
        if(argc>1&&!strcmp(argv[1],"--benchmark-metal"))return TRunMetalBenchmark(argc>2?(NSUInteger)strtoull(argv[2],NULL,10):240);
        if(argc>1&&!strcmp(argv[1],"--decoder-self-test"))return TRunDecoderSelfTest();
        if(argc>1&&!strcmp(argv[1],"--benchmark-decoder"))return TRunDecoderBenchmark(argc>2?(NSUInteger)strtoull(argv[2],NULL,10):33554432);
        if(argc>1&&!strcmp(argv[1],"--benchmark-core"))return TRunCoreBenchmark(argc>2?(NSUInteger)strtoull(argv[2],NULL,10):33554432);
        if(argc>1&&!strcmp(argv[1],"--benchmark-experience"))return TRunExperienceBenchmark(argc>2?(NSUInteger)strtoull(argv[2],NULL,10):240,argc>3?strtod(argv[3],NULL):3.0);
#endif
        if(argc==1&&([invoked isEqual:@"termatica"]||[invoked isEqual:@"t"]))return TRunCLI(argc,argv);
        if(argc>1)return TRunCLI(argc,argv);
        TApplication *app=TApplication.sharedApplication;
        TAppDelegate *delegate=[TAppDelegate new];
        app.delegate=delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
