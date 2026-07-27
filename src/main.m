#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <util.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <signal.h>
#import <stdarg.h>
#import <libproc.h>
#import <poll.h>
#import <string.h>
#import <termios.h>

static const uint32_t TDefaultColor = 0xFFFFFFFFu;
static CFAbsoluteTime TProcessStartedAt;
static void TLog(NSString *format, ...);

static NSString *TConfigDirectoryPath(void) {
    const char *override = getenv("TERMATICA_CONFIG_DIR");
    if (override && *override) return [[NSString stringWithUTF8String:override] stringByExpandingTildeInPath];
    return [@"~/.config/termatica" stringByExpandingTildeInPath];
}

static NSString *TCLISocketPath(void) {const char *path=TConfigDirectoryPath().stringByStandardizingPath.fileSystemRepresentation;uint32_t hash=2166136261u;for(const unsigned char *byte=(const unsigned char *)path;*byte;byte++)hash=(hash^*byte)*16777619u;return [NSString stringWithFormat:@"/tmp/termatica-%u-%08x.sock",getuid(),hash];}
static NSString *TSessionPath(void) {return [TConfigDirectoryPath() stringByAppendingPathComponent:@"session.json"];}

static NSString *TEnsureDirectory(NSString *name) {
    NSString *path = name.length ? [TConfigDirectoryPath() stringByAppendingPathComponent:name] : TConfigDirectoryPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

static void TInvalidateSessionSnapshot(void) {
    NSString *path=TSessionPath();
    if(![NSFileManager.defaultManager fileExistsAtPath:path])return;
    NSError *error=nil;
    if(![NSFileManager.defaultManager removeItemAtPath:path error:&error])
        TLog(@"could not invalidate session snapshot: %@",error.localizedDescription);
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

static void TLog(NSString *format, ...) {
    if (!getenv("TERMATICA_VERBOSE")) return;
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "[Termatica] %s\n", message.UTF8String);
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

static NSArray<NSString *> *TStandardPaletteHex(void) {return @[@"#1B1D23",@"#E06C75",@"#98C379",@"#E5C07B",@"#61AFEF",@"#C678DD",@"#56B6C2",@"#D7DAE0",@"#5C6370",@"#F07178",@"#AAD94C",@"#FFB454",@"#59C2FF",@"#D2A6FF",@"#95E6CB",@"#EEF1F5"];}

static NSUInteger TAppendUTF16(unichar *buffer,NSUInteger length,uint32_t codepoint) {
    if(!codepoint)codepoint=' ';
    if(codepoint<=0xFFFF){buffer[length++]=(unichar)codepoint;return length;}
    if(codepoint>0x10FFFF)codepoint=0xFFFD;
    uint32_t value=codepoint-0x10000;
    buffer[length++]=(unichar)(0xD800+(value>>10));
    buffer[length++]=(unichar)(0xDC00+(value&0x3FF));
    return length;
}

static BOOL TUnicodeCombining(uint32_t cp) {
    return (cp>=0x0300&&cp<=0x036F)||(cp>=0x0483&&cp<=0x0489)||(cp>=0x0591&&cp<=0x05BD)||(cp>=0x05BF&&cp<=0x05C7)||(cp>=0x0610&&cp<=0x061A)||(cp>=0x064B&&cp<=0x065F)||(cp>=0x0670&&cp<=0x0670)||(cp>=0x06D6&&cp<=0x06ED)||(cp>=0x0711&&cp<=0x0711)||(cp>=0x0730&&cp<=0x074A)||(cp>=0x07A6&&cp<=0x07B0)||(cp>=0x07EB&&cp<=0x07F3)||(cp>=0x0816&&cp<=0x082D)||(cp>=0x08D3&&cp<=0x0903)||(cp>=0x093A&&cp<=0x094F)||(cp>=0x0981&&cp<=0x09CD)||(cp>=0x0A01&&cp<=0x0A4D)||(cp>=0x0A81&&cp<=0x0ACD)||(cp>=0x0B01&&cp<=0x0BCD)||(cp>=0x0C00&&cp<=0x0CCD)||(cp>=0x0D00&&cp<=0x0D4D)||(cp>=0x0E31&&cp<=0x0E4E)||(cp>=0x0EB1&&cp<=0x0ECD)||(cp>=0x0F18&&cp<=0x0FBC)||(cp>=0x102B&&cp<=0x103E)||(cp>=0x17B4&&cp<=0x17D3)||(cp>=0x1AB0&&cp<=0x1AFF)||(cp>=0x1DC0&&cp<=0x1DFF)||(cp>=0x20D0&&cp<=0x20FF)||(cp>=0xFE00&&cp<=0xFE0F)||(cp>=0xFE20&&cp<=0xFE2F)||(cp>=0x1F3FB&&cp<=0x1F3FF)||(cp>=0xE0020&&cp<=0xE007F)||(cp>=0xE0100&&cp<=0xE01EF)||cp==0x200D;
}
static BOOL TUnicodeRegional(uint32_t cp){return cp>=0x1F1E6&&cp<=0x1F1FF;}
static BOOL TUnicodeWide(uint32_t cp) {
    return cp>=0x1100&&((cp<=0x115F)||(cp==0x2329||cp==0x232A)||(cp>=0x2E80&&cp<=0xA4CF&&cp!=0x303F)||(cp>=0xAC00&&cp<=0xD7A3)||(cp>=0xF900&&cp<=0xFAFF)||(cp>=0xFE10&&cp<=0xFE19)||(cp>=0xFE30&&cp<=0xFE6F)||(cp>=0xFF00&&cp<=0xFF60)||(cp>=0xFFE0&&cp<=0xFFE6)||(cp>=0x1F000&&cp<=0x1FAFF)||(cp>=0x20000&&cp<=0x3FFFD));
}

@interface TConfig : NSObject
@property NSString *path;
@property NSString *shell;
@property NSArray<NSString *> *shellArguments;
@property NSString *fontName;
@property CGFloat fontSize;
@property CGFloat padding;
@property NSUInteger scrollback;
@property BOOL skeleterm;
@property BOOL hyprlandLayout;
@property NSDictionary<NSString *,NSNumber *> *pluginStates;
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
- (void)reload;
- (void)ensureEditableFile;
- (NSArray<NSString *> *)installedThemeNames;
- (void)useThemeNamed:(NSString *)name;
- (void)applySkeleterm;
- (BOOL)isPluginInstalled:(NSString *)identifier;
- (BOOL)isPluginEnabled:(NSString *)identifier;
- (void)setPlugin:(NSString *)identifier enabled:(BOOL)enabled;
@end

@implementation TConfig
- (instancetype)init {
    if ((self = [super init])) {
        _path = [TConfigDirectoryPath() stringByAppendingPathComponent:@"config.json"];
        [self ensureEditableFile];
        [self reload];
    }
    return self;
}
- (NSDictionary *)defaults {
    return @{
        @"shell": NSProcessInfo.processInfo.environment[@"SHELL"] ?: @"/bin/zsh",
        @"shellArguments": @[@"-l"], @"fontName": @"Monaco", @"fontSize": @11,
        @"padding": @12, @"scrollback": @2000,
        @"theme": @"terminal-default",
        @"themeOptions": @[@"terminal-default",@"amber-crt",@"ghost-glass",@"green-screen"],
        @"textColorMode": @"ansi", @"skeleterm": @NO,
        @"plugins": @{
            @"hello":@NO,@"pi-bridge":@NO,@"editor-deck":@NO,
            @"vim-control":@NO,@"neovim-control":@NO,@"emacs-control":@NO,
            @"nano-control":@NO,@"micro-control":@NO,@"helix-control":@NO,
            @"hidden-path":@NO,@"hyprland-layout":@NO,@"unicode-rendering":@NO,
            @"osc-integration":@NO,@"borderless-window":@NO
        },
        @"appearance": @{
            @"backgroundOpacity":@"theme",@"windowOpacity":@"theme",@"blur":@"theme",
            @"blurMaterial":@"theme",@"glow":@"theme",@"scanlines":@"theme",
            @"vignette":@"theme",@"cursorStyle":@"theme"
        },
        @"colors": @{@"foreground":@"theme",@"cursor":@"theme",@"palette":@"theme"},
        @"tabs": @{@"railWidth":@34,@"animations":@YES,@"animationSpeed":@1.35,@"autoHide":@YES,@"hideDelay":@5,@"tileGap":@10,@"screenInset":@18,@"hyprlandBlur":@NO},
        @"updates": @{@"checkOnLaunch":@YES,@"repository":@"sebastianmiletic/termatica"},
        @"keybindings": @{@"openConfig":@"cmd+,",@"newWindow":@"cmd+n",@"newTab":@"cmd+t",@"newVerticalTab":@"cmd+shift+t",@"closeTab":@"cmd+w",@"clearTerminal":@"cmd+k",@"reload":@"cmd+r",@"copy":@"cmd+c",@"paste":@"cmd+v",@"selectAll":@"cmd+a",@"zoomIn":@"cmd+plus",@"zoomOut":@"cmd+-",@"zoomReset":@"cmd+0"}
    };
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
    self.fontSize = MAX(8, MIN(48, [d[@"fontSize"] doubleValue] ?: 11));
    self.padding = MAX(0, MIN(40, [d[@"padding"] doubleValue]));
    self.scrollback = MAX(100, MIN(100000, [d[@"scrollback"] unsignedIntegerValue] ?: 2000));
    self.skeleterm=[d[@"skeleterm"] boolValue];
    NSDictionary *updates=[d[@"updates"] isKindOfClass:NSDictionary.class]?d[@"updates"]:@{};self.updateCheckOnLaunch=updates[@"checkOnLaunch"]?[updates[@"checkOnLaunch"] boolValue]:YES;self.updateRepository=[updates[@"repository"] isKindOfClass:NSString.class]?updates[@"repository"]:@"sebastianmiletic/termatica";
    self.pluginStates=[d[@"plugins"] isKindOfClass:NSDictionary.class]?d[@"plugins"]:@{};
    self.unicodeRendering=[self isPluginEnabled:@"unicode-rendering"];
    self.oscIntegration=[self isPluginEnabled:@"osc-integration"];
    self.hyprlandLayout=[self isPluginEnabled:@"hyprland-layout"];
    NSDictionary *tabs=[d[@"tabs"] isKindOfClass:NSDictionary.class]?d[@"tabs"]:@{};self.tabRailWidth=MAX(28,MIN(64,[tabs[@"railWidth"] doubleValue]?:34));self.tabAnimations=tabs[@"animations"]?[tabs[@"animations"] boolValue]:YES;self.animationSpeed=MAX(0.25,MIN(4,[tabs[@"animationSpeed"] doubleValue]?:1.35));self.tabAutoHide=tabs[@"autoHide"]?[tabs[@"autoHide"] boolValue]:YES;self.tabHideDelay=MAX(1,MIN(30,[tabs[@"hideDelay"] doubleValue]?:5));self.tileGap=MAX(0,MIN(24,[tabs[@"tileGap"] doubleValue]?:10));self.screenInset=MAX(8,MIN(80,[tabs[@"screenInset"] doubleValue]?:18));self.hyprlandBlur=tabs[@"hyprlandBlur"]?[tabs[@"hyprlandBlur"] boolValue]:NO;
    id rawTheme=d[@"theme"];self.themeName=[rawTheme isKindOfClass:NSString.class]?rawTheme:@"custom";
    NSDictionary *theme=[rawTheme isKindOfClass:NSDictionary.class]?rawTheme:[self themeNamed:self.themeName];if(!theme)theme=[self fallbackTheme];
    NSDictionary *themeAppearance=[theme[@"appearance"] isKindOfClass:NSDictionary.class]?theme[@"appearance"]:@{};
    NSMutableDictionary *appearance=[themeAppearance mutableCopy];
    NSDictionary *configAppearance=[d[@"appearance"] isKindOfClass:NSDictionary.class]?d[@"appearance"]:@{};for(NSString *key in configAppearance){id value=configAppearance[key];if(![value isKindOfClass:NSString.class]||![value isEqual:@"theme"])appearance[key]=value;}
    NSDictionary *userTabs=[user[@"tabs"] isKindOfClass:NSDictionary.class]?user[@"tabs"]:@{};if(!userTabs[@"hyprlandBlur"]&&appearance[@"hyprlandBlur"])self.hyprlandBlur=[appearance[@"hyprlandBlur"] boolValue];
    self.backgroundOpacity=MAX(0.08,MIN(1.0,appearance[@"backgroundOpacity"]?[appearance[@"backgroundOpacity"] doubleValue]:0.90));
    self.windowOpacity=MAX(0.20,MIN(1.0,appearance[@"windowOpacity"]?[appearance[@"windowOpacity"] doubleValue]:1.0));
    self.blur=appearance[@"blur"]?[appearance[@"blur"] boolValue]:YES;
    self.topBar=![self isPluginEnabled:@"borderless-window"];
    self.blurMaterial=[appearance[@"blurMaterial"] isKindOfClass:NSString.class]?appearance[@"blurMaterial"]:@"hud";
    self.glow=MAX(0,MIN(1,[appearance[@"glow"] doubleValue]));self.scanlines=MAX(0,MIN(1,[appearance[@"scanlines"] doubleValue]));self.vignette=MAX(0,MIN(1,[appearance[@"vignette"] doubleValue]));
    self.cursorStyle=[appearance[@"cursorStyle"] isKindOfClass:NSString.class]?appearance[@"cursorStyle"]:@"block";
    NSMutableDictionary *bindings=[[[self defaults] objectForKey:@"keybindings"] mutableCopy];if([d[@"keybindings"] isKindOfClass:NSDictionary.class])[bindings addEntriesFromDictionary:d[@"keybindings"]];self.keybindings=bindings;
    NSDictionary *colorOverrides=[d[@"colors"] isKindOfClass:NSDictionary.class]?d[@"colors"]:@{};
    self.background = [THexColor(theme[@"background"], THexColor(@"#101216", NSColor.blackColor)) colorWithAlphaComponent:self.backgroundOpacity];
    self.foreground = THexColor(colorOverrides[@"foreground"]?:theme[@"foreground"], THexColor(@"#D8DEE9", NSColor.textColor));
    self.cursor = THexColor(colorOverrides[@"cursor"]?:theme[@"cursor"], THexColor(@"#EEF1F5", NSColor.textColor));
    self.accent = THexColor(theme[@"accent"], self.cursor);
    self.panel=THexColor(theme[@"panel"],THexColor(@"#151820",NSColor.windowBackgroundColor));self.muted=THexColor(theme[@"muted"],THexColor(@"#6B7280",NSColor.secondaryLabelColor));self.selection=THexColor(theme[@"selection"],THexColor(@"#2B3445",self.accent));
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
- (void)useThemeNamed:(NSString *)name {if(![self themeNamed:name])return;[self ensureEditableFile];NSData *data=[NSData dataWithContentsOfFile:self.path];NSMutableDictionary *d=[NSMutableDictionary dictionary];id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;if([parsed isKindOfClass:NSDictionary.class])[d addEntriesFromDictionary:parsed];d[@"theme"]=name;d[@"skeleterm"]=@NO;[d removeObjectForKey:@"profile"];[[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil] writeToFile:self.path atomically:YES];[self reload];}
- (void)ensureEditableFile {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = self.path.stringByDeletingLastPathComponent;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *existingData=[NSData dataWithContentsOfFile:self.path];
    id parsed=existingData?[NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil]:nil;
    NSDictionary *existing=[parsed isKindOfClass:NSDictionary.class]?parsed:@{};
    NSMutableDictionary *normalized=[[self defaults] mutableCopy];
    [normalized addEntriesFromDictionary:existing];
    for(NSString *key in @[@"appearance",@"colors",@"tabs",@"updates",@"keybindings"]){
        NSMutableDictionary *nested=[[self defaults][key] mutableCopy];
        if([existing[key] isKindOfClass:NSDictionary.class])[nested addEntriesFromDictionary:existing[key]];
        normalized[key]=nested;
    }
    NSDictionary *defaultPlugins=[self defaults][@"plugins"];
    NSDictionary *configuredPlugins=[existing[@"plugins"] isKindOfClass:NSDictionary.class]?existing[@"plugins"]:nil;
    NSMutableDictionary *plugins=[defaultPlugins mutableCopy];
    if(configuredPlugins)[plugins addEntriesFromDictionary:configuredPlugins];
    else {
        NSSet *legacyDisabled=[NSSet setWithArray:[existing[@"disabledPlugins"] isKindOfClass:NSArray.class]?existing[@"disabledPlugins"]:@[]];
        for(NSString *identifier in defaultPlugins)
            plugins[identifier]=[NSNumber numberWithBool:[self isPluginInstalled:identifier]&&![legacyDisabled containsObject:identifier]];
        NSString *extensionRoot=[TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"];
        for(NSString *identifier in [fm contentsOfDirectoryAtPath:extensionRoot error:nil]?:@[])
            if(TSafeIdentifier(identifier)&&![identifier hasPrefix:@"."])plugins[identifier]=[NSNumber numberWithBool:![legacyDisabled containsObject:identifier]];
        NSDictionary *legacyAppearance=[existing[@"appearance"] isKindOfClass:NSDictionary.class]?existing[@"appearance"]:@{};
        if(legacyAppearance[@"topBar"]&&![legacyAppearance[@"topBar"] boolValue])plugins[@"borderless-window"]=@YES;
    }
    for(NSString *identifier in [plugins.allKeys copy])if([identifier hasPrefix:@"."])[plugins removeObjectForKey:identifier];
    normalized[@"plugins"]=plugins;
    normalized[@"themeOptions"]=[self installedThemeNames];
    NSMutableDictionary *appearance=[normalized[@"appearance"] mutableCopy];
    [appearance removeObjectForKey:@"topBar"];
    normalized[@"appearance"]=appearance;
    [normalized removeObjectForKey:@"disabledPlugins"];
    [normalized removeObjectForKey:@"session"];
    if(!existingData||![normalized isEqualToDictionary:existing]){
        NSData *data=[NSJSONSerialization dataWithJSONObject:normalized options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
        if([data writeToFile:self.path options:NSDataWritingAtomic error:nil])
            [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:self.path error:nil];
    }
}
- (NSMutableDictionary *)editableDictionary {
    [self ensureEditableFile];NSData *data=[NSData dataWithContentsOfFile:self.path];id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;return [parsed isKindOfClass:NSDictionary.class]?[parsed mutableCopy]:[[self defaults] mutableCopy];
}
- (void)writeEditableDictionary:(NSDictionary *)dictionary {
    NSData *data=[NSJSONSerialization dataWithJSONObject:dictionary options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];if([data writeToFile:self.path options:NSDataWritingAtomic error:nil])[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:self.path error:nil];[self ensureEditableFile];[self reload];
}
- (void)applySkeleterm {
    NSMutableDictionary *d=[self editableDictionary];[d removeObjectForKey:@"profile"];d[@"skeleterm"]=@YES;d[@"theme"]=@"terminal-default";d[@"scrollback"]=@300;d[@"appearance"]=@{@"backgroundOpacity":@1,@"windowOpacity":@1,@"blur":@NO,@"glow":@0,@"scanlines":@0,@"vignette":@0,@"cursorStyle":@"block"};[self writeEditableDictionary:d];
}
- (BOOL)isPluginInstalled:(NSString *)identifier {return identifier.length&&[NSFileManager.defaultManager fileExistsAtPath:[[TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"] stringByAppendingPathComponent:identifier]];}
- (BOOL)isPluginEnabled:(NSString *)identifier {return [self isPluginInstalled:identifier]&&[self.pluginStates[identifier] boolValue];}
- (void)setPlugin:(NSString *)identifier enabled:(BOOL)enabled {if(!TSafeIdentifier(identifier))return;NSMutableDictionary *d=[self editableDictionary];NSDictionary *configured=[d[@"plugins"] isKindOfClass:NSDictionary.class]?d[@"plugins"]:@{};NSMutableDictionary *plugins=[configured mutableCopy];plugins[identifier]=@(enabled);d[@"plugins"]=plugins;[self writeEditableDictionary:d];}
@end

static BOOL TPostCLIRequest(NSDictionary *request) {
    NSData *payload=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];if(!payload.length||payload.length>8192)return NO;int socketFD=socket(AF_UNIX,SOCK_DGRAM,0);if(socketFD<0)return NO;struct sockaddr_un address={0};address.sun_family=AF_UNIX;strlcpy(address.sun_path,TCLISocketPath().fileSystemRepresentation,sizeof(address.sun_path));address.sun_len=(uint8_t)(offsetof(struct sockaddr_un,sun_path)+strlen(address.sun_path)+1);ssize_t sent=sendto(socketFD,payload.bytes,payload.length,0,(struct sockaddr *)&address,address.sun_len);if(sent<0)TLog(@"CLI socket send failed: %s",strerror(errno));close(socketFD);return sent==(ssize_t)payload.length;
}
static void TPostCLICommand(NSString *command) {TPostCLIRequest(@{@"command":command?:@""});}

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

static BOOL TThemeInstalled(NSString *identifier) {NSString *user=[[TConfigDirectoryPath() stringByAppendingPathComponent:@"themes"] stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];NSString *bundled=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[NSString stringWithFormat:@"Themes/%@.json",identifier]];return [NSFileManager.defaultManager fileExistsAtPath:user]||[NSFileManager.defaultManager fileExistsAtPath:bundled];}

static NSString *TModuleState(NSDictionary *item,TConfig *config) {NSString *identifier=item[@"id"],*kind=item[@"kind"];if([kind isEqual:@"plugins"]){if(![config isPluginInstalled:identifier])return @"GET";return [config isPluginEnabled:identifier]?@"ON":@"OFF";}if([kind isEqual:@"themes"]){if(!TThemeInstalled(identifier))return @"GET";return [config.themeName isEqual:identifier]?@"ON":@"OFF";}return @"OFF";}

static BOOL TActivateModule(NSDictionary *item,TConfig *config,NSString **result,NSError **error) {NSString *identifier=item[@"id"],*kind=item[@"kind"];if([kind isEqual:@"plugins"]){if(![config isPluginInstalled:identifier]){BOOL ok=TInstallModule(item,config,error);if(ok&&result)*result=@"INSTALLED + ON";return ok;}BOOL enabled=![config isPluginEnabled:identifier];[config setPlugin:identifier enabled:enabled];if(result)*result=enabled?@"ENABLED":@"DISABLED";return YES;}if([kind isEqual:@"themes"]&&[config.themeName isEqual:identifier]){if(![identifier isEqual:@"terminal-default"])[config useThemeNamed:@"terminal-default"];if(result)*result=[identifier isEqual:@"terminal-default"]?@"STILL ON":@"DISABLED";return YES;}BOOL ok=TInstallModule(item,config,error);if(ok&&result)*result=[kind isEqual:@"themes"]?@"ACTIVE":@"INSTALLED";return ok;}

static volatile sig_atomic_t TMenuInterrupted=0;
static void TMenuSignal(int signalNumber){TMenuInterrupted=1;}

static NSString *TConfigProfileDirectory(void){return TEnsureDirectory(@"configs");}
static NSString *TConfigProfilePath(NSString *name){return [[TConfigProfileDirectory() stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"json"];}
static NSArray<NSString *> *TConfigProfileNames(void){NSMutableArray<NSString *> *names=[NSMutableArray array];for(NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:TConfigProfileDirectory() error:nil]?:@[]){NSString *name=file.stringByDeletingPathExtension;if([file.pathExtension.lowercaseString isEqual:@"json"]&&TSafeIdentifier(name))[names addObject:name];}return [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];}
static NSMutableDictionary *TReadActiveConfig(TConfig *config){[config ensureEditableFile];NSData *data=[NSData dataWithContentsOfFile:config.path];id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;return [value isKindOfClass:NSDictionary.class]?[value mutableCopy]:[NSMutableDictionary dictionary];}
static BOOL TWriteJSONDictionary(NSDictionary *dictionary,NSString *path,NSError **error){NSData *data=[NSJSONSerialization dataWithJSONObject:dictionary options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];if(!data)return NO;BOOL ok=[data writeToFile:path options:NSDataWritingAtomic error:error];if(ok)[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];return ok;}
static NSString *TActiveConfigName(TConfig *config){id name=TReadActiveConfig(config)[@"configName"];return [name isKindOfClass:NSString.class]?name:@"custom";}
static BOOL TValidConfigName(NSString *name){return TSafeIdentifier(name)&&![name isEqual:@"config"]&&![name isEqual:@"session"];}
static NSString *TSaveConfigNamed(NSString *name,TConfig *config){if(!TValidConfigName(name))return @"[ INVALID ] use letters, numbers, dot, dash or underscore";NSMutableDictionary *active=TReadActiveConfig(config);active[@"configName"]=name;NSError *error=nil;if(!TWriteJSONDictionary(active,TConfigProfilePath(name),&error)||!TWriteJSONDictionary(active,config.path,&error))return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not save config"];[config reload];TPostCLICommand(@"reload");return [NSString stringWithFormat:@"[ SAVED + ACTIVE ] %@",name];}
static NSString *TUseConfigNamed(NSString *name,TConfig *config){if(!TValidConfigName(name))return @"[ INVALID ] config name";NSData *data=[NSData dataWithContentsOfFile:TConfigProfilePath(name)];id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;if(![value isKindOfClass:NSDictionary.class])return [NSString stringWithFormat:@"[ NOT FOUND ] %@",name];NSMutableDictionary *active=[value mutableCopy];active[@"configName"]=name;NSError *error=nil;if(!TWriteJSONDictionary(active,config.path,&error))return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not activate config"];[config reload];TPostCLICommand(@"reload");return [NSString stringWithFormat:@"[ ACTIVE ] %@",name];}
static NSString *TRenameConfig(NSString *oldName,NSString *newName,TConfig *config){if(!TValidConfigName(oldName)||!TValidConfigName(newName))return @"[ INVALID ] config name";NSString *oldPath=TConfigProfilePath(oldName),*newPath=TConfigProfilePath(newName);NSFileManager *fm=NSFileManager.defaultManager;if(![fm fileExistsAtPath:oldPath])return [NSString stringWithFormat:@"[ NOT FOUND ] %@",oldName];if([fm fileExistsAtPath:newPath])return [NSString stringWithFormat:@"[ EXISTS ] %@",newName];NSError *error=nil;if(![fm moveItemAtPath:oldPath toPath:newPath error:&error])return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not rename config"];NSData *data=[NSData dataWithContentsOfFile:newPath];id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;NSMutableDictionary *profile=[value isKindOfClass:NSDictionary.class]?[value mutableCopy]:[NSMutableDictionary dictionary];profile[@"configName"]=newName;TWriteJSONDictionary(profile,newPath,nil);if([TActiveConfigName(config) isEqual:oldName]){NSMutableDictionary *active=TReadActiveConfig(config);active[@"configName"]=newName;TWriteJSONDictionary(active,config.path,nil);[config reload];TPostCLICommand(@"reload");}return [NSString stringWithFormat:@"[ RENAMED ] %@ -> %@",oldName,newName];}
static NSString *TDeleteConfig(NSString *name,TConfig *config){if(!TValidConfigName(name))return @"[ INVALID ] config name";NSString *path=TConfigProfilePath(name);if(![NSFileManager.defaultManager fileExistsAtPath:path])return [NSString stringWithFormat:@"[ NOT FOUND ] %@",name];NSError *error=nil;if(![NSFileManager.defaultManager removeItemAtPath:path error:&error])return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not delete config"];if([TActiveConfigName(config) isEqual:name]){NSMutableDictionary *active=TReadActiveConfig(config);[active removeObjectForKey:@"configName"];TWriteJSONDictionary(active,config.path,nil);[config reload];}return [NSString stringWithFormat:@"[ DELETED ] %@",name];}
static void TDrawConfigBrowser(NSArray<NSString *> *names,NSUInteger selected,TConfig *config,NSString *message){fputs("\033[2J\033[H\033[38;2;122;162;247m  TERMATICA CONFIG / CONFIG FILES\033[0m\n",stdout);fprintf(stdout,"\033[38;2;107;114;128m  folder  %s\n  active  %s\033[0m\n\n",TConfigProfileDirectory().fileSystemRepresentation,TActiveConfigName(config).UTF8String);if(!names.count)fputs("\033[38;2;216;222;233m   No saved configurations. Press N to create one from the current settings.\033[0m\n",stdout);for(NSUInteger i=0;i<names.count;i++){BOOL highlighted=i==selected,active=[names[i] isEqual:TActiveConfigName(config)];if(highlighted)fputs("\033[48;2;43;52;69m\033[38;2;238;241;245m",stdout);else fputs("\033[38;2;216;222;233m",stdout);fprintf(stdout," %c %2lu  %-7s  %-52s\033[0m\n",highlighted?'>':' ',(unsigned long)i+1,active?"ACTIVE":"SAVED",names[i].UTF8String);}if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m  %s\033[0m",message.UTF8String);fflush(stdout);}
static NSString *TConfigPrompt(struct termios original,struct termios raw,NSString *prompt){tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);fputs("\033[?25h\n",stdout);fprintf(stdout,"%s",prompt.UTF8String);fflush(stdout);char input[2048]={0};NSString *answer=@"";if(fgets(input,sizeof(input),stdin))answer=[[NSString stringWithUTF8String:input] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);fputs("\033[?25l",stdout);return answer;}
static int TRunConfigBrowser(TConfig *config){
    struct termios original;BOOL interactive=isatty(STDIN_FILENO)&&isatty(STDOUT_FILENO)&&tcgetattr(STDIN_FILENO,&original)==0;NSString *message=nil;
    if(interactive){struct termios raw=original;raw.c_lflag&=~(ICANON|ECHO);raw.c_iflag&=~(IXON|ICRNL);raw.c_cc[VMIN]=1;raw.c_cc[VTIME]=0;tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);void(*previous)(int)=signal(SIGINT,TMenuSignal);TMenuInterrupted=0;NSUInteger selected=0;fputs("\033[?25l",stdout);while(!TMenuInterrupted){NSArray *names=TConfigProfileNames();if(names.count)selected=MIN(selected,names.count-1);else selected=0;TDrawConfigBrowser(names,selected,config,message);unsigned char key=0;if(read(STDIN_FILENO,&key,1)!=1)continue;if(key=='q'||key=='Q')break;if((key=='\r'||key=='\n')&&names.count){message=TUseConfigNamed(names[selected],config);continue;}if((key=='j'||key=='J')&&names.count){selected=(selected+1)%names.count;continue;}if((key=='k'||key=='K')&&names.count){selected=(selected+names.count-1)%names.count;continue;}if(key=='s'||key=='S'){NSString *name=TConfigPrompt(original,raw,@"save current config as: ");message=name.length?TSaveConfigNamed(name,config):@"[ CANCELLED ]";continue;}if((key=='r'||key=='R')&&names.count){NSString *name=TConfigPrompt(original,raw,[NSString stringWithFormat:@"rename %@ to: ",names[selected]]);message=name.length?TRenameConfig(names[selected],name,config):@"[ CANCELLED ]";continue;}if((key=='d'||key=='D')&&names.count){NSString *answer=TConfigPrompt(original,raw,[NSString stringWithFormat:@"delete %@? [y/N]: ",names[selected]]);message=[answer.lowercaseString isEqual:@"y"]?TDeleteConfig(names[selected],config):@"[ CANCELLED ]";continue;}if(key==27){unsigned char sequence[2]={0};if(read(STDIN_FILENO,&sequence[0],1)==1&&read(STDIN_FILENO,&sequence[1],1)==1&&sequence[0]=='['&&names.count){if(sequence[1]=='A')selected=(selected+names.count-1)%names.count;else if(sequence[1]=='B')selected=(selected+1)%names.count;}}}tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);signal(SIGINT,previous);fputs("\033[?25h\033[0m\n",stdout);return TMenuInterrupted?130:0;}
    char input[256]={0};while(YES){NSArray *names=TConfigProfileNames();TDrawConfigBrowser(names,NSNotFound,config,message);fputs("\ncommands: save NAME | use NAME | rename OLD NEW | delete NAME | list | q\nconfigs> ",stdout);fflush(stdout);if(!fgets(input,sizeof(input),stdin))return 0;NSString *line=[[NSString stringWithUTF8String:input] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSArray *parts=[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];NSMutableArray *args=[NSMutableArray array];for(NSString *part in parts)if(part.length)[args addObject:part];if(!args.count||[args[0] isEqual:@"q"]||[args[0] isEqual:@"quit"])return 0;if([args[0] isEqual:@"save"]&&args.count==2)message=TSaveConfigNamed(args[1],config);else if([args[0] isEqual:@"use"]&&args.count==2)message=TUseConfigNamed(args[1],config);else if([args[0] isEqual:@"rename"]&&args.count==3)message=TRenameConfig(args[1],args[2],config);else if([args[0] isEqual:@"delete"]&&args.count==2)message=TDeleteConfig(args[1],config);else if([args[0] isEqual:@"list"])message=[NSString stringWithFormat:@"[ %lu SAVED ]",(unsigned long)names.count];else message=@"[ INVALID ] expected save, use, rename, delete, list or q";}
}
static int __attribute__((unused)) TRunConfigsCLI(int argc,const char *argv[],TConfig *config){if(argc<3)return TRunConfigBrowser(config);NSString *action=[[NSString stringWithUTF8String:argv[2]] lowercaseString];if([action isEqual:@"path"]){fprintf(stdout,"%s\n",TConfigProfileDirectory().fileSystemRepresentation);return 0;}if([action isEqual:@"list"]){fprintf(stdout,"active\t%s\n",TActiveConfigName(config).UTF8String);for(NSString *name in TConfigProfileNames())fprintf(stdout,"%s\t%s\n",[name isEqual:TActiveConfigName(config)]?"active":"saved",name.UTF8String);return 0;}NSString *result=nil;if([action isEqual:@"save"]&&argc==4)result=TSaveConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"use"]&&argc==4)result=TUseConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"rename"]&&argc==5)result=TRenameConfig([NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[4]],config);else if([action isEqual:@"delete"]&&argc==4)result=TDeleteConfig([NSString stringWithUTF8String:argv[3]],config);else{fputs("usage: termatica configs [list|path|save NAME|use NAME|rename OLD NEW|delete NAME]\n",stderr);return 2;}fprintf(stdout,"%s\n",result.UTF8String);return [result hasPrefix:@"[ FAILED"]||[result hasPrefix:@"[ INVALID"]||[result hasPrefix:@"[ NOT"]||[result hasPrefix:@"[ EXISTS"]?1:0;}

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
static NSArray<NSDictionary *> *TUnifiedConfigSections(TConfig *config) {
    NSMutableArray *pluginRows=[NSMutableArray array];for(NSString *identifier in [config.pluginStates.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)])[pluginRows addObject:TSetting(identifier.uppercaseString,[@"plugins." stringByAppendingString:identifier],@"bool",nil,nil,nil,nil)];
    NSMutableArray *bindingRows=[NSMutableArray array];for(NSString *identifier in [config.keybindings.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)])[bindingRows addObject:TSetting(identifier,[@"keybindings." stringByAppendingString:identifier],@"string",nil,nil,nil,nil)];
    NSArray *themes=config.installedThemeNames.count?config.installedThemeNames:@[@"terminal-default"];
    return @[
      @{@"title":@"THEMES",@"detail":@"active palette and surface",@"rows":@[TSetting(@"Active theme",@"theme",@"option",themes,nil,nil,nil)]},
      @{@"title":@"TEXT & COLOUR",@"detail":@"font, cursor and ANSI behaviour",@"rows":@[
        TSetting(@"Font name",@"fontName",@"string",nil,nil,nil,nil),TSetting(@"Font size",@"fontSize",@"number",nil,@8,@48,@1),
        TSetting(@"Text colour mode",@"textColorMode",@"option",@[@"ansi",@"spectrum"],nil,nil,nil),TSetting(@"Padding",@"padding",@"number",nil,@0,@40,@1),
        TSetting(@"Scrollback",@"scrollback",@"number",nil,@100,@100000,@500),TSetting(@"Foreground",@"colors.foreground",@"string",nil,nil,nil,nil),
        TSetting(@"Cursor colour",@"colors.cursor",@"string",nil,nil,nil,nil),TSetting(@"ANSI palette",@"colors.palette",@"json",nil,nil,nil,nil)
      ]},
      @{@"title":@"APPEARANCE",@"detail":@"opacity, blur and terminal effects",@"rows":@[
        TSetting(@"Background opacity",@"appearance.backgroundOpacity",@"number-theme",nil,@0.08,@1,@0.05),TSetting(@"Window opacity",@"appearance.windowOpacity",@"number-theme",nil,@0.20,@1,@0.05),
        TSetting(@"Blur",@"appearance.blur",@"bool-theme",nil,nil,nil,nil),TSetting(@"Blur material",@"appearance.blurMaterial",@"option-theme",@[@"hud",@"popover",@"sidebar",@"menu",@"under-window"],nil,nil,nil),
        TSetting(@"Glow",@"appearance.glow",@"number-theme",nil,@0,@1,@0.05),TSetting(@"Scanlines",@"appearance.scanlines",@"number-theme",nil,@0,@1,@0.05),
        TSetting(@"Vignette",@"appearance.vignette",@"number-theme",nil,@0,@1,@0.05),TSetting(@"Cursor style",@"appearance.cursorStyle",@"option-theme",@[@"block",@"bar",@"underline"],nil,nil,nil)
      ]},
      @{@"title":@"TABS & MOTION",@"detail":@"rail, tiling, gaps and speed",@"rows":@[
        TSetting(@"Rail width",@"tabs.railWidth",@"number",nil,@28,@64,@1),TSetting(@"Animations",@"tabs.animations",@"bool",nil,nil,nil,nil),
        TSetting(@"Animation speed",@"tabs.animationSpeed",@"number",nil,@0.25,@4,@0.10),TSetting(@"Auto hide rail",@"tabs.autoHide",@"bool",nil,nil,nil,nil),
        TSetting(@"Hide delay",@"tabs.hideDelay",@"number",nil,@1,@30,@1),TSetting(@"Tile gap",@"tabs.tileGap",@"number",nil,@0,@24,@1),
        TSetting(@"Screen inset",@"tabs.screenInset",@"number",nil,@8,@80,@1),TSetting(@"Hyprland blur",@"tabs.hyprlandBlur",@"bool",nil,nil,nil,nil)
      ]},
      @{@"title":@"PLUGINS",@"detail":@"all installed and built-in capabilities",@"rows":pluginRows},
      @{@"title":@"SYSTEM & UPDATES",@"detail":@"shell, memory mode and GitHub releases",@"rows":@[
        TSetting(@"Shell",@"shell",@"string",nil,nil,nil,nil),TSetting(@"Shell arguments",@"shellArguments",@"json",nil,nil,nil,nil),
        TSetting(@"Skeleterm",@"skeleterm",@"bool",nil,nil,nil,nil),TSetting(@"Check on launch",@"updates.checkOnLaunch",@"bool",nil,nil,nil,nil),
        TSetting(@"Update repository",@"updates.repository",@"string",nil,nil,nil,nil)
      ]},
      @{@"title":@"KEYBINDINGS",@"detail":@"every application shortcut",@"rows":bindingRows}
    ];
}
static NSString *TConfigDisplayValue(id value) {
    if(!value||value==NSNull.null)return @"unset";if([value isKindOfClass:NSNumber.class]){if(CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return [value boolValue]?@"ON":@"OFF";double number=[value doubleValue];return fabs(number-round(number))<0.0001?[NSString stringWithFormat:@"%.0f",number]:[NSString stringWithFormat:@"%.2f",number];}
    if([value isKindOfClass:NSString.class])return value;NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];NSString *json=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:[value description];return json.length>42?[[json substringToIndex:39] stringByAppendingString:@"..."]:json;
}
static BOOL TCommitUnifiedConfig(TConfig *config,NSMutableDictionary *dictionary,NSString **message) {
    NSError *error=nil;if(!TWriteJSONDictionary(dictionary,config.path,&error)){if(message)*message=[NSString stringWithFormat:@"FAILED: %@",error.localizedDescription?:@"could not write config"];return NO;}[config ensureEditableFile];[config reload];TPostCLICommand(@"reload");if(message)*message=@"SAVED + RELOADED";return YES;
}
static id TParseConfigInput(NSString *input,NSString *type) {
    if(!input.length)return nil;if([type isEqual:@"number"]||[type isEqual:@"number-theme"]){if([input.lowercaseString isEqual:@"theme"]&&[type hasSuffix:@"theme"])return @"theme";NSScanner *scanner=[NSScanner scannerWithString:input];double value=0;if([scanner scanDouble:&value]&&scanner.isAtEnd)return @(value);return nil;}
    if([type isEqual:@"bool"]||[type isEqual:@"bool-theme"]){NSString *lower=input.lowercaseString;if([lower isEqual:@"theme"]&&[type hasSuffix:@"theme"])return @"theme";if([@[@"on",@"true",@"yes",@"1"] containsObject:lower])return @YES;if([@[@"off",@"false",@"no",@"0"] containsObject:lower])return @NO;return nil;}
    if([type isEqual:@"json"]){NSData *data=[input dataUsingEncoding:NSUTF8StringEncoding];return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];}
    return input;
}
static BOOL TChangeConfigSetting(TConfig *config,NSDictionary *setting,NSInteger direction,NSString *promptValue,NSString **message) {
    NSMutableDictionary *dictionary=TReadActiveConfig(config);NSString *path=setting[@"path"],*type=setting[@"type"];id current=TConfigValueAtPath(dictionary,path);id next=nil;
    if(promptValue)next=TParseConfigInput(promptValue,type);
    else if([type hasPrefix:@"bool"]){if([type hasSuffix:@"theme"]&&[current isKindOfClass:NSString.class])next=@YES;else if([type hasSuffix:@"theme"]&&direction<0&&![current isKindOfClass:NSString.class])next=@"theme";else next=@(![current boolValue]);}
    else if([type hasPrefix:@"option"]){NSMutableArray *options=[NSMutableArray array];if([type hasSuffix:@"theme"])[options addObject:@"theme"];[options addObjectsFromArray:setting[@"options"]?:@[]];NSInteger index=[options indexOfObject:current];if(index==NSNotFound)index=0;next=options[(index+direction+(NSInteger)options.count)%(NSInteger)options.count];}
    else if([type hasPrefix:@"number"]){if([type hasSuffix:@"theme"]&&[current isKindOfClass:NSString.class])next=setting[@"min"];else if([type hasSuffix:@"theme"]&&direction<0&&[current doubleValue]<=[setting[@"min"] doubleValue])next=@"theme";else{double value=[current doubleValue]+direction*[setting[@"step"] doubleValue];next=@(MAX([setting[@"min"] doubleValue],MIN([setting[@"max"] doubleValue],value)));}}
    if(!next){if(message)*message=@"INVALID VALUE";return NO;}TConfigSetValueAtPath(dictionary,path,next);return TCommitUnifiedConfig(config,dictionary,message);
}
static void TDrawUnifiedRoot(NSArray<NSDictionary *> *sections,NSUInteger selected,TConfig *config,NSString *message) {
    fputs("\033[2J\033[H\033[38;2;122;162;247m  TERMATICA CONFIG\n\033[0m",stdout);fprintf(stdout,"\033[38;2;107;114;128m  active  %-24s  file  %s\033[0m\n\n",TActiveConfigName(config).UTF8String,config.path.fileSystemRepresentation);
    NSArray *titles=[@[@"CONFIG FILES"] arrayByAddingObjectsFromArray:[sections valueForKey:@"title"]];NSArray *details=[@[[NSString stringWithFormat:@"%lu saved configurations",(unsigned long)TConfigProfileNames().count]] arrayByAddingObjectsFromArray:[sections valueForKey:@"detail"]];
    for(NSUInteger i=0;i<titles.count;i++){BOOL active=i==selected;fputs(active?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-20.20s  %-48.48s\033[0m\n",active?'>':' ',[titles[i] UTF8String],[details[i] UTF8String]);}
    fputs("\n\033[38;2;107;114;128m  UP/DOWN move   ENTER open   Q quit\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m  %s\033[0m",message.UTF8String);fflush(stdout);
}
static BOOL TReadMenuKey(unsigned char *key,NSInteger *direction) {
    *direction=0;if(read(STDIN_FILENO,key,1)!=1)return NO;if(*key==27){unsigned char sequence[2]={0};if(read(STDIN_FILENO,&sequence[0],1)==1&&read(STDIN_FILENO,&sequence[1],1)==1&&sequence[0]=='['){if(sequence[1]=='A')*key='k';else if(sequence[1]=='B')*key='j';else if(sequence[1]=='C'){*key='l';*direction=1;}else if(sequence[1]=='D'){*key='h';*direction=-1;}}}return YES;
}
static NSString *TRunConfigFilesPanel(TConfig *config,struct termios original,struct termios raw) {
    NSUInteger selected=0;NSString *message=nil;while(YES){NSArray *names=TConfigProfileNames();if(names.count)selected=MIN(selected,names.count-1);else selected=0;TDrawConfigBrowser(names,selected,config,message);fputs("\n\033[38;2;107;114;128m[ N ] NEW  [ R ] RENAME  [ D ] DELETE  [ Q ] BACK\033[0m",stdout);fflush(stdout);unsigned char key=0;NSInteger direction=0;if(!TReadMenuKey(&key,&direction))continue;if(key=='q'||key=='Q')return message;if((key=='j'||key=='J')&&names.count)selected=(selected+1)%names.count;else if((key=='k'||key=='K')&&names.count)selected=(selected+names.count-1)%names.count;else if((key=='\r'||key=='\n')&&names.count)message=TUseConfigNamed(names[selected],config);else if(key=='n'||key=='N'){NSString *name=TConfigPrompt(original,raw,@"new config name: ");message=name.length?TSaveConfigNamed(name,config):@"CANCELLED";}else if((key=='r'||key=='R')&&names.count){NSString *name=TConfigPrompt(original,raw,[NSString stringWithFormat:@"rename %@ to: ",names[selected]]);message=name.length?TRenameConfig(names[selected],name,config):@"CANCELLED";}else if((key=='d'||key=='D')&&names.count){NSString *answer=TConfigPrompt(original,raw,[NSString stringWithFormat:@"delete %@? [y/N]: ",names[selected]]);message=[answer.lowercaseString isEqual:@"y"]?TDeleteConfig(names[selected],config):@"CANCELLED";}}
}
static NSString *TRunSettingsPanel(TConfig *config,NSDictionary *section,struct termios original,struct termios raw) {
    NSUInteger selected=0;NSString *message=nil;while(YES){NSArray *rows=section[@"rows"];selected=MIN(selected,rows.count?rows.count-1:0);NSMutableDictionary *dictionary=TReadActiveConfig(config);fputs("\033[2J\033[H",stdout);fprintf(stdout,"\033[38;2;122;162;247m  TERMATICA CONFIG / %s\033[0m\n\n",[section[@"title"] UTF8String]);
        for(NSUInteger i=0;i<rows.count;i++){NSDictionary *row=rows[i];BOOL active=i==selected;NSString *value=TConfigDisplayValue(TConfigValueAtPath(dictionary,row[@"path"]));fputs(active?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-24.24s  %-43.43s\033[0m\n",active?'>':' ',[row[@"label"] UTF8String],value.UTF8String);}
        fputs("\n\033[38;2;107;114;128m  UP/DOWN move   LEFT/RIGHT change   ENTER edit/toggle   Q back\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m  %s\033[0m",message.UTF8String);fflush(stdout);unsigned char key=0;NSInteger direction=0;if(!TReadMenuKey(&key,&direction))continue;if(key=='q'||key=='Q')return message;if(!rows.count)continue;if(key=='j'||key=='J')selected=(selected+1)%rows.count;else if(key=='k'||key=='K')selected=(selected+rows.count-1)%rows.count;else if(key=='h'||key=='H'||key=='l'||key=='L')TChangeConfigSetting(config,rows[selected],direction?:((key=='l'||key=='L')?1:-1),nil,&message);else if(key=='\r'||key=='\n'){NSDictionary *setting=rows[selected];NSString *type=setting[@"type"];if([type hasPrefix:@"bool"]||[type hasPrefix:@"option"])TChangeConfigSetting(config,setting,1,nil,&message);else{NSString *current=TConfigDisplayValue(TConfigValueAtPath(dictionary,setting[@"path"]));NSString *input=TConfigPrompt(original,raw,[NSString stringWithFormat:@"%@ [%@]: ",setting[@"label"],current]);if(input.length)TChangeConfigSetting(config,setting,1,input,&message);else message=@"UNCHANGED";}}}
}
static int TRunUnifiedConfigCLI(int argc,const char *argv[],TConfig *config) {
    if(argc>=3){NSString *action=[[NSString stringWithUTF8String:argv[2]] lowercaseString];if([action isEqual:@"list"]){fprintf(stdout,"active\t%s\n",TActiveConfigName(config).UTF8String);for(NSString *name in TConfigProfileNames())fprintf(stdout,"%s\t%s\n",[name isEqual:TActiveConfigName(config)]?"active":"saved",name.UTF8String);return 0;}if([action isEqual:@"get"]&&argc==4){id value=TConfigValueAtPath(TReadActiveConfig(config),[NSString stringWithUTF8String:argv[3]]);if(!value)return 1;fprintf(stdout,"%s\n",TConfigDisplayValue(value).UTF8String);return 0;}if([action isEqual:@"set"]&&argc>=5){NSString *path=[NSString stringWithUTF8String:argv[3]];NSMutableArray *parts=[NSMutableArray array];for(int i=4;i<argc;i++)[parts addObject:[NSString stringWithUTF8String:argv[i]]];NSString *input=[parts componentsJoinedByString:@" "];NSData *data=[input dataUsingEncoding:NSUTF8StringEncoding];id value=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil]?:input;NSMutableDictionary *dictionary=TReadActiveConfig(config);TConfigSetValueAtPath(dictionary,path,value);NSString *message=nil;if(!TCommitUnifiedConfig(config,dictionary,&message))return 1;fprintf(stdout,"%s\t%s\n",path.UTF8String,TConfigDisplayValue(value).UTF8String);return 0;}NSString *result=nil;if([action isEqual:@"create"]&&argc==4)result=TSaveConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"use"]&&argc==4)result=TUseConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"rename"]&&argc==5)result=TRenameConfig([NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[4]],config);else if([action isEqual:@"delete"]&&argc==4)result=TDeleteConfig([NSString stringWithUTF8String:argv[3]],config);else{fputs("usage: termatica config [list|get PATH|set PATH VALUE|create NAME|use NAME|rename OLD NEW|delete NAME]\n",stderr);return 2;}fprintf(stdout,"%s\n",result.UTF8String);return [result containsString:@"FAILED"]||[result containsString:@"INVALID"]||[result containsString:@"NOT FOUND"]||[result containsString:@"EXISTS"]?1:0;}
    struct termios original;if(!isatty(STDIN_FILENO)||!isatty(STDOUT_FILENO)||tcgetattr(STDIN_FILENO,&original)!=0){fputs("termatica config requires a terminal; use 'termatica config-file' for JSON or config subcommands for scripts.\n",stderr);return 2;}struct termios raw=original;raw.c_lflag&=~(ICANON|ECHO);raw.c_iflag&=~(IXON|ICRNL);raw.c_cc[VMIN]=1;raw.c_cc[VTIME]=0;tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);void(*previous)(int)=signal(SIGINT,TMenuSignal);TMenuInterrupted=0;NSUInteger selected=0;NSString *message=nil;fputs("\033[?25l",stdout);
    while(!TMenuInterrupted){NSArray *sections=TUnifiedConfigSections(config);NSUInteger count=sections.count+1;selected=MIN(selected,count-1);TDrawUnifiedRoot(sections,selected,config,message);unsigned char key=0;NSInteger direction=0;if(!TReadMenuKey(&key,&direction))continue;if(key=='q'||key=='Q')break;if(key=='j'||key=='J')selected=(selected+1)%count;else if(key=='k'||key=='K')selected=(selected+count-1)%count;else if(key=='\r'||key=='\n')message=selected==0?TRunConfigFilesPanel(config,original,raw):TRunSettingsPanel(config,sections[selected-1],original,raw);}
    tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);signal(SIGINT,previous);fputs("\033[?25h\033[0m\n",stdout);return TMenuInterrupted?130:0;
}

#if 0
// Removed from the built application in 0.4.2. Display settings are config-only.
static BOOL TCodeWrite(TConfig *config,NSMutableDictionary *dictionary,NSString **message){NSError *error=nil;if(!TWriteJSONDictionary(dictionary,config.path,&error)){if(message)*message=[NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not write config"];return NO;}[config reload];TPostCLICommand(@"reload");if(message)*message=@"[ APPLIED ] running terminals reloaded";return YES;}
static NSMutableDictionary *TCodeAppearance(NSMutableDictionary *dictionary){NSDictionary *value=[dictionary[@"appearance"] isKindOfClass:NSDictionary.class]?dictionary[@"appearance"]:@{};NSMutableDictionary *appearance=[value mutableCopy];dictionary[@"appearance"]=appearance;return appearance;}
static BOOL TCodeBoolean(NSString *value,BOOL *result){NSString *v=value.lowercaseString;if([@[@"on",@"true",@"1",@"yes"] containsObject:v]){*result=YES;return YES;}if([@[@"off",@"false",@"0",@"no"] containsObject:v]){*result=NO;return YES;}return NO;}
enum { TCodeRowCount=14 };
static NSMutableDictionary *TCodeTabs(NSMutableDictionary *dictionary){NSDictionary *value=[dictionary[@"tabs"] isKindOfClass:NSDictionary.class]?dictionary[@"tabs"]:@{};NSMutableDictionary *tabs=[value mutableCopy];dictionary[@"tabs"]=tabs;return tabs;}
static NSMutableDictionary *TCodeColors(NSMutableDictionary *dictionary){NSDictionary *value=[dictionary[@"colors"] isKindOfClass:NSDictionary.class]?dictionary[@"colors"]:@{};NSMutableDictionary *colors=[value mutableCopy];dictionary[@"colors"]=colors;return colors;}
static void TCodeReset(NSMutableDictionary *d){d[@"theme"]=@"terminal-default";d[@"textColorMode"]=@"ansi";d[@"fontSize"]=@11;d[@"scrollback"]=@2000;d[@"skeleterm"]=@NO;[d removeObjectForKey:@"colors"];d[@"appearance"]=@{@"topBar":@YES};d[@"tabs"]=@{@"railWidth":@34,@"animations":@YES,@"animationSpeed":@1.35,@"autoHide":@YES,@"hideDelay":@5,@"tileGap":@10,@"screenInset":@18,@"hyprlandBlur":@NO};}
static NSString *TCodeCycleColor(NSMutableDictionary *d,NSString *key,NSInteger direction){
    NSArray *choices=@[@"theme",@"#F2FAF8",@"#7DD3FC",@"#7CE38B",@"#FFE083",@"#FF8787",@"#DDB2F4"];NSMutableDictionary *colors=TCodeColors(d);NSString *current=[colors[key] isKindOfClass:NSString.class]?colors[key]:@"theme";NSInteger index=[choices indexOfObject:current];if(index==NSNotFound)index=0;index=(index+direction+(NSInteger)choices.count)%(NSInteger)choices.count;NSString *next=choices[(NSUInteger)index];if([next isEqual:@"theme"])[colors removeObjectForKey:key];else colors[key]=next;return next;
}
static NSString *TCodeApply(TConfig *config,NSUInteger row,NSInteger direction){
    NSMutableDictionary *d=TReadActiveConfig(config);NSString *message=nil;
    if(row==0)d[@"textColorMode"]=config.colorizePlainText?@"ansi":@"spectrum";
    else if(row==1){NSArray *themes=config.installedThemeNames;if(!themes.count)return @"[ NO THEMES ]";NSInteger current=[themes indexOfObject:config.themeName];if(current==NSNotFound)current=0;NSInteger next=(current+direction+(NSInteger)themes.count)%(NSInteger)themes.count;[config useThemeNamed:themes[(NSUInteger)next]];TPostCLICommand(@"reload");return [NSString stringWithFormat:@"[ THEME ] %@",themes[(NSUInteger)next]];}
    else if(row==2)d[@"fontSize"]=@(MAX(8,MIN(48,config.fontSize+direction)));
    else if(row==3)TCodeAppearance(d)[@"backgroundOpacity"]=@(MAX(0.08,MIN(1,config.backgroundOpacity+direction*0.05)));
    else if(row==4)TCodeAppearance(d)[@"blur"]=@(!config.blur);
    else if(row==5)TCodeAppearance(d)[@"topBar"]=@(!config.topBar);
    else if(row==6)TCodeCycleColor(d,@"cursor",direction);
    else if(row==7){NSArray *styles=@[@"block",@"bar",@"underline"];NSInteger index=[styles indexOfObject:config.cursorStyle];if(index==NSNotFound)index=0;TCodeAppearance(d)[@"cursorStyle"]=styles[(index+direction+(NSInteger)styles.count)%(NSInteger)styles.count];}
    else if(row==8)TCodeCycleColor(d,@"foreground",direction);
    else if(row==9){NSMutableDictionary *colors=TCodeColors(d);if([colors[@"palette"] isKindOfClass:NSArray.class])[colors removeObjectForKey:@"palette"];else colors[@"palette"]=TStandardPaletteHex();}
    else if(row==10)TCodeTabs(d)[@"tileGap"]=@(MAX(0,MIN(24,(NSInteger)llround(config.tileGap)+direction)));
    else if(row==11)TCodeTabs(d)[@"animationSpeed"]=@(MAX(0.25,MIN(4,config.animationSpeed+direction*0.10)));
    else if(row==12)d[@"scrollback"]=@(MAX(100,MIN(100000,(NSInteger)config.scrollback+direction*500)));
    else if(row==13)TCodeReset(d);
    TCodeWrite(config,d,&message);return row==13?@"[ RESET ] display settings restored":message;
}
static void TDrawCodeBrowser(NSUInteger selected,TConfig *config,NSString *message){
    NSDictionary *raw=TReadActiveConfig(config),*colors=[raw[@"colors"] isKindOfClass:NSDictionary.class]?raw[@"colors"]:@{};
    NSArray *labels=@[@"TEXT COLOURS",@"THEME",@"FONT SIZE",@"TRANSPARENCY",@"BLUR",@"TOP BAR",@"CURSOR COLOUR",@"CURSOR STYLE",@"FOREGROUND",@"ANSI PALETTE",@"TILE GAP",@"ANIMATION SPEED",@"SCROLLBACK",@"RESET DEFAULTS"];
    NSArray *values=@[config.colorizePlainText?@"SPECTRUM":@"STANDARD ANSI",config.themeName?:@"custom",[NSString stringWithFormat:@"%.0f px",config.fontSize],[NSString stringWithFormat:@"%.0f%%",config.backgroundOpacity*100],config.blur?@"ON":@"OFF",config.topBar?@"ON":@"OFF",colors[@"cursor"]?:@"THEME",config.cursorStyle.uppercaseString,colors[@"foreground"]?:@"THEME",[colors[@"palette"] isKindOfClass:NSArray.class]?@"STANDARD":@"THEME",[NSString stringWithFormat:@"%.0f px",config.tileGap],[NSString stringWithFormat:@"%.2fx",config.animationSpeed],[NSString stringWithFormat:@"%lu lines",(unsigned long)config.scrollback],@"DISPLAY"];
    NSArray *details=@[@"normal ANSI or explicit spectrum",@"active portable theme",@"terminal cell text size",@"terminal background opacity",@"native background material",@"titlebar and traffic lights",@"theme token or chosen colour",@"block, bar or underline",@"ordinary terminal text colour",@"theme or standard 16 colours",@"transparent Hyprland gutter",@"native transition speed",@"retained output per terminal",@"restore display defaults"];
    fputs("\033[2J\033[H\033[38;2;122;162;247m+--------------------------------------------------------------------------------------+\n|  >_ TERMATICA // CODE                                                               |\n|  Live terminal settings, written to your readable config.json                        |\n+--------------------------------------------------------------------------------------+\033[0m\n\n",stdout);
    for(NSUInteger i=0;i<labels.count;i++){BOOL active=i==selected;fputs(active?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-17.17s  %-18.18s  %-35.35s\033[0m\n",active?'>':' ',[labels[i] UTF8String],[values[i] UTF8String],[details[i] UTF8String]);}
    fputs("\n\033[38;2;107;114;128m[ UP/DOWN ] MOVE  [ LEFT/RIGHT or ENTER ] CHANGE  [ Q ] QUIT\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m%s\033[0m",message.UTF8String);fflush(stdout);
}
static void TCodeShow(TConfig *config){NSDictionary *raw=TReadActiveConfig(config),*colors=[raw[@"colors"] isKindOfClass:NSDictionary.class]?raw[@"colors"]:@{};fprintf(stdout,"text-colours\t%s\ntheme\t%s\nfont-size\t%.0f\ntransparency\t%.0f\nblur\t%s\ntop-bar\t%s\ncursor-color\t%s\ncursor-style\t%s\nforeground\t%s\nansi-palette\t%s\ntile-gap\t%.0f\nanimation-speed\t%.2f\nscrollback\t%lu\n",config.colorizePlainText?"spectrum":"ansi",config.themeName.UTF8String,config.fontSize,config.backgroundOpacity*100,config.blur?"on":"off",config.topBar?"on":"off",THexString(config.cursor).UTF8String,config.cursorStyle.UTF8String,THexString(config.foreground).UTF8String,[colors[@"palette"] isKindOfClass:NSArray.class]?"custom":"theme",config.tileGap,config.animationSpeed,(unsigned long)config.scrollback);}
static int TLegacyCodeCLI(int argc,const char *argv[],TConfig *config){
    if(argc>=3){NSString *key=[[NSString stringWithUTF8String:argv[2]] lowercaseString];if([key isEqual:@"show"]){TCodeShow(config);return 0;}NSMutableDictionary *d=TReadActiveConfig(config);NSString *message=nil;if([key isEqual:@"reset"]){TCodeReset(d);if(!TCodeWrite(config,d,&message)){fprintf(stderr,"%s\n",message.UTF8String);return 1;}fputs("reset\tdefaults\n",stdout);return 0;}if([key isEqual:@"ansi-color"]&&argc==5){NSInteger index=atoi(argv[3]);NSString *hex=[NSString stringWithUTF8String:argv[4]];if(index<0||index>15||!TValidHexColor(hex)){fputs("usage: termatica code ansi-color 0..15 '#RRGGBB'\n",stderr);return 2;}NSMutableArray *palette=[NSMutableArray arrayWithCapacity:16];for(NSColor *color in config.palette)[palette addObject:THexString(color)];palette[(NSUInteger)index]=hex.uppercaseString;TCodeColors(d)[@"palette"]=palette;if(!TCodeWrite(config,d,&message))return 1;fprintf(stdout,"ansi-color-%ld\t%s\n",(long)index,hex.UTF8String);return 0;}if(argc<4){fputs("usage: termatica code [show|reset|colors MODE|theme NAME|font-size N|transparency N|blur BOOL|top-bar BOOL|cursor-color HEX|cursor-style STYLE|foreground HEX|palette MODE|ansi-color INDEX HEX|tile-gap N|animation-speed N|scrollback N]\n",stderr);return 2;}NSString *value=[[NSString stringWithUTF8String:argv[3]] lowercaseString];BOOL valid=YES;
        if([key isEqual:@"colors"]||[key isEqual:@"colours"]){if([value isEqual:@"standard"])value=@"ansi";valid=[@[@"ansi",@"spectrum"] containsObject:value];if(valid)d[@"textColorMode"]=value;}
        else if([key isEqual:@"theme"]){valid=[config.installedThemeNames containsObject:value];if(valid){[config useThemeNamed:value];TPostCLICommand(@"reload");fprintf(stdout,"theme\t%s\n",value.UTF8String);return 0;}}
        else if([key isEqual:@"font-size"]){NSInteger number=value.integerValue;valid=number>=8&&number<=48;if(valid)d[@"fontSize"]=@(number);}
        else if([key isEqual:@"transparency"]){double number=value.doubleValue;valid=number>=8&&number<=100;if(valid)TCodeAppearance(d)[@"backgroundOpacity"]=@(number/100);}
        else if([key isEqual:@"blur"]||[key isEqual:@"top-bar"]){BOOL enabled=NO;valid=TCodeBoolean(value,&enabled);if(valid)TCodeAppearance(d)[[key isEqual:@"top-bar"]?@"topBar":key]=@(enabled);}
        else if([key isEqual:@"cursor-color"]||[key isEqual:@"foreground"]){valid=[value isEqual:@"theme"]||TValidHexColor(value);if(valid){NSMutableDictionary *target=TCodeColors(d);if([value isEqual:@"theme"])[target removeObjectForKey:[key isEqual:@"cursor-color"]?@"cursor":@"foreground"];else target[[key isEqual:@"cursor-color"]?@"cursor":@"foreground"]=value.uppercaseString;}}
        else if([key isEqual:@"cursor-style"]){valid=[@[@"block",@"bar",@"underline"] containsObject:value];if(valid)TCodeAppearance(d)[@"cursorStyle"]=value;}
        else if([key isEqual:@"palette"]){valid=[@[@"theme",@"standard"] containsObject:value];if(valid){NSMutableDictionary *target=TCodeColors(d);if([value isEqual:@"theme"])[target removeObjectForKey:@"palette"];else target[@"palette"]=TStandardPaletteHex();}}
        else if([key isEqual:@"tile-gap"]){NSInteger number=value.integerValue;valid=number>=0&&number<=24;if(valid)TCodeTabs(d)[@"tileGap"]=@(number);}
        else if([key isEqual:@"animation-speed"]){double number=value.doubleValue;valid=number>=0.25&&number<=4;if(valid)TCodeTabs(d)[@"animationSpeed"]=@(number);}
        else if([key isEqual:@"scrollback"]){NSInteger number=value.integerValue;valid=number>=100&&number<=100000;if(valid)d[@"scrollback"]=@(number);}
        else valid=NO;
        if(!valid){fputs("termatica code: invalid setting or value\n",stderr);return 2;}if(!TCodeWrite(config,d,&message)){fprintf(stderr,"%s\n",message.UTF8String);return 1;}fprintf(stdout,"%s\t%s\n",key.UTF8String,value.UTF8String);return 0;
    }
    struct termios original;if(!isatty(STDIN_FILENO)||!isatty(STDOUT_FILENO)||tcgetattr(STDIN_FILENO,&original)!=0){TCodeShow(config);return 0;}struct termios raw=original;raw.c_lflag&=~(ICANON|ECHO);raw.c_iflag&=~(IXON|ICRNL);raw.c_cc[VMIN]=1;raw.c_cc[VTIME]=0;tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);void(*previous)(int)=signal(SIGINT,TMenuSignal);TMenuInterrupted=0;NSUInteger selected=0;NSString *message=nil;fputs("\033[?25l",stdout);
    while(!TMenuInterrupted){TDrawCodeBrowser(selected,config,message);unsigned char key=0;if(read(STDIN_FILENO,&key,1)!=1)continue;if(key=='q'||key=='Q')break;if(key=='j'||key=='J'){selected=(selected+1)%TCodeRowCount;continue;}if(key=='k'||key=='K'){selected=(selected+TCodeRowCount-1)%TCodeRowCount;continue;}if(key=='\r'||key=='\n'){message=TCodeApply(config,selected,1);continue;}if(key==27){unsigned char sequence[2]={0};if(read(STDIN_FILENO,&sequence[0],1)==1&&read(STDIN_FILENO,&sequence[1],1)==1&&sequence[0]=='['){if(sequence[1]=='A')selected=(selected+TCodeRowCount-1)%TCodeRowCount;else if(sequence[1]=='B')selected=(selected+1)%TCodeRowCount;else if(sequence[1]=='C')message=TCodeApply(config,selected,1);else if(sequence[1]=='D')message=TCodeApply(config,selected,-1);}}}
    tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);signal(SIGINT,previous);fputs("\033[?25h\033[0m\n",stdout);return TMenuInterrupted?130:0;
}
#endif
static int __attribute__((unused)) TRunCodeCLI(int argc,const char *argv[],TConfig *config) {
    [config ensureEditableFile];
    if(argc>=3&&(!strcmp(argv[2],"show")||!strcmp(argv[2],"path"))){
        if(!strcmp(argv[2],"path"))fprintf(stdout,"%s\n",config.path.fileSystemRepresentation);
        else {NSData *data=[NSData dataWithContentsOfFile:config.path];if(data.length)fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);}
        return 0;
    }
    if(argc>=3){fputs("termatica code no longer changes settings. Edit config.json, then run 'termatica reload'.\n",stderr);return 2;}
    TOpenPath(config.path);fprintf(stdout,"opened config-only settings: %s\n",config.path.fileSystemRepresentation);return 0;
}

static void TDrawModuleBrowser(NSArray<NSDictionary *> *items,NSUInteger selected,TConfig *config,NSString *message) {
    fputs("\033[2J\033[H\033[38;2;122;162;247m+--------------------------------------------------------------------------+\n|  >_ TERMATICA // MODULES                                                 |\n|  GET not installed   ON active   OFF installed but inactive              |\n+--------------------------------------------------------------------------+\033[0m\n",stdout);
    for(NSUInteger i=0;i<items.count;i++){NSDictionary *item=items[i];BOOL highlighted=i==selected;if(highlighted)fputs("\033[48;2;43;52;69m\033[38;2;238;241;245m",stdout);else fputs("\033[38;2;216;222;233m",stdout);fprintf(stdout," %c %2lu  ",highlighted?'>':' ',(unsigned long)i+1);NSString *state=TModuleState(item,config);if([state isEqual:@"ON"])fputs("\033[38;2;152;195;121m",stdout);else if([state isEqual:@"OFF"])fputs("\033[38;2;255;180;84m",stdout);else if([state isEqual:@"GET"])fputs("\033[38;2;89;194;255m",stdout);else fputs("\033[38;2;149;230;203m",stdout);fprintf(stdout,"%-5s",state.UTF8String);fputs(highlighted?"\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %-4s %-20.20s  %-35.35s\033[0m\n",[item[@"icon"] UTF8String],[[item[@"title"] uppercaseString] UTF8String],[item[@"detail"]?:@"user catalog module" UTF8String]);}
    fputs("\n\033[38;2;107;114;128m[ UP/DOWN or J/K ] MOVE   [ ENTER ] INSTALL / TOGGLE   [ Q ] QUIT\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m%s\033[0m",message.UTF8String);fflush(stdout);
}

static NSString *TPerformModuleAction(NSDictionary *item,TConfig *config) {NSError *error=nil;NSString *result=nil;BOOL needsInstall=[TModuleState(item,config) isEqual:@"GET"];if(needsInstall)for(int i=0;i<=20;i++){fputs("\r\033[38;2;122;162;247mWRITE [",stdout);for(int j=0;j<20;j++)fputc(j<i?'#':(j==i?'>':'.'),stdout);fprintf(stdout,"] %3d%%\033[0m",i*5);fflush(stdout);usleep(5000);}if(needsInstall)fputc('\n',stdout);BOOL ok=TActivateModule(item,config,&result,&error);if(ok){TPostCLICommand(@"reload");return [NSString stringWithFormat:@"[ %@ ] %@",result?:@"UPDATED",item[@"title"]?:item[@"id"]];}return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"module action failed"];}

static NSDictionary *TModuleChoice(NSString *answer,NSArray<NSDictionary *> *items) {NSInteger choice=answer.integerValue;if(choice>=1&&choice<=(NSInteger)items.count)return items[(NSUInteger)choice-1];for(NSDictionary *candidate in items)if([candidate[@"id"] isEqual:answer])return candidate;return nil;}

static int __attribute__((unused)) TRunModuleBrowser(NSString *category,TConfig *config) {
    NSArray *items=[TModuleItems() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return [item[@"kind"] isEqual:category];}]];if(!items.count)return 0;struct termios original;BOOL interactive=isatty(STDIN_FILENO)&&isatty(STDOUT_FILENO)&&tcgetattr(STDIN_FILENO,&original)==0;NSString *message=nil;
    if(interactive){struct termios raw=original;raw.c_lflag&=~(ICANON|ECHO);raw.c_iflag&=~(IXON|ICRNL);raw.c_cc[VMIN]=1;raw.c_cc[VTIME]=0;tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);void (*previous)(int)=signal(SIGINT,TMenuSignal);TMenuInterrupted=0;NSUInteger selected=0;fputs("\033[?25l",stdout);while(!TMenuInterrupted){TDrawModuleBrowser(items,selected,config,message);unsigned char key=0;if(read(STDIN_FILENO,&key,1)!=1)continue;if(key=='q'||key=='Q')break;if(key=='\r'||key=='\n'){message=TPerformModuleAction(items[selected],config);continue;}if(key=='j'||key=='J'){selected=(selected+1)%items.count;continue;}if(key=='k'||key=='K'){selected=(selected+items.count-1)%items.count;continue;}if(key==27){unsigned char sequence[2]={0};if(read(STDIN_FILENO,&sequence[0],1)==1&&read(STDIN_FILENO,&sequence[1],1)==1&&sequence[0]=='['){if(sequence[1]=='A')selected=(selected+items.count-1)%items.count;else if(sequence[1]=='B')selected=(selected+1)%items.count;}}}tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);signal(SIGINT,previous);fputs("\033[?25h\033[0m\n",stdout);return TMenuInterrupted?130:0;}
    char input[128]={0};while(YES){TDrawModuleBrowser(items,NSNotFound,config,message);fputs("\nType module ids repeatedly; q closes the menu.\nmodule> ",stdout);fflush(stdout);if(!fgets(input,sizeof(input),stdin))return 0;NSString *answer=[[[NSString stringWithUTF8String:input] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];if([answer isEqual:@"q"]||[answer isEqual:@"quit"]||!answer.length)return 0;NSDictionary *item=TModuleChoice(answer,items);if(!item){message=[NSString stringWithFormat:@"[ NOT FOUND ] %@",answer];continue;}message=TPerformModuleAction(item,config);}
}

static NSDictionary *TModuleItemNamed(NSString *identifier) {for(NSDictionary *item in TModuleItems())if([item[@"id"] isEqual:identifier])return item;return nil;}
static void TInstallConfiguredPlugins(TConfig *config) {
    for(NSString *identifier in config.pluginStates){
        if(![config.pluginStates[identifier] boolValue]||[config isPluginInstalled:identifier])continue;
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

#if 0
static NSString *TCompletionScript(NSString *shell) {
    NSString *commands=@"code plugins themes configs install run editor reload config config-path config-dir plugins-dir themes-dir skeleterm completions help version";
    NSString *plugins=@"hello pi-bridge editor-deck vim-control neovim-control emacs-control nano-control micro-control helix-control hidden-path hyprland-layout unicode-rendering osc-integration borderless-window";
    NSString *themes=@"terminal-default amber-crt ghost-glass green-screen",*editors=@"vim nvim emacs nano micro hx";
    NSString *code=@"show path";
    if([shell isEqual:@"zsh"])return [NSString stringWithFormat:@"#compdef termatica\nlocal -a commands\ncommands=(%@)\nif (( CURRENT == 2 )); then compadd -- $commands; return; fi\ncase $words[2] in\n  code)\n    if (( CURRENT == 3 )); then _values 'setting' %@; return; fi\n    case $words[3] in\n      colors|colours) _values 'mode' ansi spectrum ;;\n      theme) _values 'theme' %@ ;;\n      blur|top-bar) _values 'state' on off ;;\n      cursor-color|foreground) _values 'colour' theme '#F2FAF8' '#7DD3FC' '#7CE38B' '#FFE083' '#FF8787' '#DDB2F4' ;;\n      cursor-style) _values 'style' block bar underline ;;\n      palette) _values 'palette' theme standard ;;\n      ansi-color) (( CURRENT == 4 )) && _values 'ANSI index' {0..15} ;;\n    esac ;;\n  plugins|install) _values 'plugin' %@ ;;\n  themes) _values 'theme' %@ ;;\n  configs) (( CURRENT == 3 )) && _values 'action' list path save use rename delete ;;\n  editor) (( CURRENT == 3 )) && _values 'editor' %@ || _files ;;\n  completions) _values 'shell' zsh bash fish install path ;;\nesac\n",commands,code,themes,plugins,themes,editors];
    if([shell isEqual:@"bash"])return [NSString stringWithFormat:@"_termatica_complete() {\n  local cur=\"${COMP_WORDS[COMP_CWORD]}\" command=\"${COMP_WORDS[1]}\" setting=\"${COMP_WORDS[2]}\" words=\"%@\"\n  if (( COMP_CWORD == 1 )); then COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") ); return; fi\n  case \"$command\" in\n    code)\n      words=\"%@\"\n      if (( COMP_CWORD > 2 )); then case \"$setting\" in colors|colours) words=\"ansi spectrum\";; theme) words=\"%@\";; blur|top-bar) words=\"on off\";; cursor-color|foreground) words=\"theme '#F2FAF8' '#7DD3FC' '#7CE38B' '#FFE083' '#FF8787' '#DDB2F4'\";; cursor-style) words=\"block bar underline\";; palette) words=\"theme standard\";; ansi-color) words=\"0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15\";; esac; fi ;;\n    plugins|install) words=\"%@\" ;;\n    themes) words=\"%@\" ;;\n    editor) words=\"%@\" ;;\n    completions) words=\"zsh bash fish install path\" ;;\n    configs) words=\"list path save use rename delete\" ;;\n  esac\n  COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") )\n}\ncomplete -F _termatica_complete termatica\n",commands,code,themes,plugins,themes,editors];
    if([shell isEqual:@"fish"]){NSMutableString *script=[NSMutableString stringWithFormat:@"complete -c termatica -f -n 'not __fish_seen_subcommand_from %@' -a '%@'\n",commands,commands];for(NSString *command in [code componentsSeparatedByString:@" "])[script appendFormat:@"complete -c termatica -f -n '__fish_seen_subcommand_from code' -a '%@'\n",command];for(NSString *plugin in [plugins componentsSeparatedByString:@" "])[script appendFormat:@"complete -c termatica -f -n '__fish_seen_subcommand_from plugins install' -a '%@'\n",plugin];for(NSString *theme in [themes componentsSeparatedByString:@" "])[script appendFormat:@"complete -c termatica -f -n '__fish_seen_subcommand_from themes' -a '%@'\n",theme];for(NSString *editor in [editors componentsSeparatedByString:@" "])[script appendFormat:@"complete -c termatica -f -n '__fish_seen_subcommand_from editor' -a '%@'\n",editor];return script;}
    return nil;
}
#endif
static NSString *TCompletionScript(NSString *shell) {
    NSString *commands=@"config config-file update reload editor run completions help version",*configActions=@"list get set create use rename delete",*editors=@"vim nvim emacs nano micro hx";
    if([shell isEqual:@"zsh"])return [NSString stringWithFormat:@"#compdef termatica\nlocal -a commands\ncommands=(%@)\nif (( CURRENT == 2 )); then compadd -- $commands; return; fi\ncase $words[2] in\n  config) (( CURRENT == 3 )) && _values 'action' %@ ;;\n  config-file) (( CURRENT == 3 )) && _values 'action' path ;;\n  update) (( CURRENT == 3 )) && _values 'action' check ;;\n  editor) (( CURRENT == 3 )) && _values 'editor' %@ || _files ;;\n  completions) _values 'shell' zsh bash fish install path ;;\nesac\n",commands,configActions,editors];
    if([shell isEqual:@"bash"])return [NSString stringWithFormat:@"_termatica_complete() {\n  local cur=\"${COMP_WORDS[COMP_CWORD]}\" command=\"${COMP_WORDS[1]}\" words=\"%@\"\n  if (( COMP_CWORD == 1 )); then COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") ); return; fi\n  case \"$command\" in\n    config) words=\"%@\" ;;\n    config-file) words=\"path\" ;;\n    update) words=\"check\" ;;\n    editor) words=\"%@\" ;;\n    completions) words=\"zsh bash fish install path\" ;;\n  esac\n  COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") )\n}\ncomplete -F _termatica_complete termatica\n",commands,configActions,editors];
    if([shell isEqual:@"fish"])return [NSString stringWithFormat:@"complete -c termatica -f -n 'not __fish_seen_subcommand_from %@' -a '%@'\ncomplete -c termatica -f -n '__fish_seen_subcommand_from config' -a '%@'\ncomplete -c termatica -f -n '__fish_seen_subcommand_from config-file' -a 'path'\ncomplete -c termatica -f -n '__fish_seen_subcommand_from update' -a 'check'\ncomplete -c termatica -f -n '__fish_seen_subcommand_from editor' -a '%@'\ncomplete -c termatica -f -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish install path'\n",commands,commands,configActions,editors];
    return nil;
}
static NSString *TZshCompletionBootstrap(void) {
    return @"typeset -g _termatica_completion_dir=\"${${(%):-%N}:A:h}\"\n"
           @"fpath=(\"$_termatica_completion_dir\" $fpath)\n"
           @"autoload -Uz compinit\n"
           @"if (( ! $+functions[compdef] )); then compinit -i; fi\n"
           @"autoload -Uz _termatica\n"
           @"compdef _termatica termatica\n"
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
static int TRunUpdateCLI(int argc,const char *argv[],TConfig *config) {
    BOOL checkOnly=argc>=3&&(!strcmp(argv[2],"check")||!strcmp(argv[2],"--check"));NSError *error=nil;fprintf(stdout,"Checking GitHub for Termatica updates...\n");NSDictionary *release=TLatestRelease(config.updateRepository,&error);if(!release){fprintf(stderr,"termatica update: %s\n",(error.localizedDescription?:@"update check failed").UTF8String);return 1;}
    NSString *tag=release[@"tag_name"],*current=TCurrentVersion();if(TCompareVersions(tag,current)!=NSOrderedDescending){fprintf(stdout,"Termatica %s is current. Latest GitHub release: %s.\n",current.UTF8String,tag.UTF8String);return 0;}fprintf(stdout,"Update available: %s -> %s\n",current.UTF8String,tag.UTF8String);if(checkOnly)return 10;
    NSDictionary *asset=TReleaseAsset(release,@"Termatica-macOS-universal.zip");NSString *download=[asset[@"browser_download_url"] isKindOfClass:NSString.class]?asset[@"browser_download_url"]:nil,*digest=[asset[@"digest"] isKindOfClass:NSString.class]?asset[@"digest"]:nil;if(!download.length||![digest hasPrefix:@"sha256:"]){fputs("termatica update: release is missing the signed ZIP metadata or SHA-256 digest\n",stderr);return 1;}
    NSString *temporary=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"termatica-update-%@",NSUUID.UUID.UUIDString]];if(![NSFileManager.defaultManager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]){fprintf(stderr,"termatica update: %s\n",error.localizedDescription.UTF8String);return 1;}NSString *zip=[temporary stringByAppendingPathComponent:@"Termatica.zip"],*unpacked=[temporary stringByAppendingPathComponent:@"unpacked"];fprintf(stdout,"Downloading %s...\n",tag.UTF8String);
    BOOL ok=TRunTask(@"/usr/bin/curl",@[@"-fL",@"--connect-timeout",@"5",@"--max-time",@"120",@"-A",@"Termatica-Updater",@"-o",zip,download],nil,&error);NSString *actual=ok?TSHA256(zip,&error):nil,*expected=[[digest substringFromIndex:7] lowercaseString];if(!ok||![actual isEqual:expected]){fprintf(stderr,"termatica update: %s\n",(error.localizedDescription?:@"download checksum did not match GitHub").UTF8String);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}
    [NSFileManager.defaultManager createDirectoryAtPath:unpacked withIntermediateDirectories:YES attributes:nil error:nil];if(!TRunTask(@"/usr/bin/ditto",@[@"-x",@"-k",zip,unpacked],nil,&error)){fprintf(stderr,"termatica update: %s\n",error.localizedDescription.UTF8String);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}NSString *source=[unpacked stringByAppendingPathComponent:@"Termatica.app"];NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[source stringByAppendingPathComponent:@"Contents/Info.plist"]];NSString *bundleID=info[@"CFBundleIdentifier"],*version=info[@"CFBundleShortVersionString"];if(![bundleID isEqual:@"com.termatica.Termatica"]||TCompareVersions(version,current)!=NSOrderedDescending||TCompareVersions(version,tag)!=NSOrderedSame){fputs("termatica update: downloaded app identity or version is invalid\n",stderr);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}if(!TRunTask(@"/usr/bin/codesign",@[@"--verify",@"--deep",@"--strict",source],nil,&error)){fprintf(stderr,"termatica update: signature verification failed: %s\n",error.localizedDescription.UTF8String);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}
    const char *targetOverride=getenv("TERMATICA_UPDATE_DESTINATION");NSString *target=targetOverride&&*targetOverride?[NSString stringWithUTF8String:targetOverride]:([NSBundle.mainBundle.bundlePath.pathExtension.lowercaseString isEqual:@"app"]&&[NSBundle.mainBundle.bundlePath hasPrefix:@"/Applications/"]?NSBundle.mainBundle.bundlePath:@"/Applications/Termatica.app");NSString *parent=target.stringByDeletingLastPathComponent,*token=NSUUID.UUID.UUIDString,*stage=[parent stringByAppendingPathComponent:[NSString stringWithFormat:@".Termatica-update-%@.app",token]],*backup=[parent stringByAppendingPathComponent:[NSString stringWithFormat:@".Termatica-backup-%@.app",token]];
    if(!TRunTask(@"/usr/bin/ditto",@[source,stage],nil,&error)){fprintf(stderr,"termatica update: cannot stage app in %s: %s\n",parent.fileSystemRepresentation,error.localizedDescription.UTF8String);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];return 1;}NSFileManager *fm=NSFileManager.defaultManager;BOOL hadTarget=[fm fileExistsAtPath:target];if(hadTarget&&![fm moveItemAtPath:target toPath:backup error:&error])ok=NO;else if(![fm moveItemAtPath:stage toPath:target error:&error]){ok=NO;if(hadTarget)[fm moveItemAtPath:backup toPath:target error:nil];}else{ok=YES;if(hadTarget)[fm removeItemAtPath:backup error:nil];}
    [fm removeItemAtPath:temporary error:nil];if(!ok){fprintf(stderr,"termatica update: install failed: %s\n",(error.localizedDescription?:@"could not replace the application").UTF8String);return 1;}fprintf(stdout,"Updated Termatica to %s at %s. Restart the app to use it.\n",tag.UTF8String,target.fileSystemRepresentation);return 0;
}

static int TRunCLI(int argc, const char *argv[]) {
    NSString *arg=argc>1?[NSString stringWithUTF8String:argv[1]]:@"--help";
    if([arg isEqual:@"--help"]||[arg isEqual:@"-h"]||[arg isEqual:@"help"]){
        fprintf(stdout,"Termatica %s\n\nUSAGE\n  termatica <command> [arguments]\n\nCONFIGURATION\n  config             Open the complete categorized terminal config UI\n  config-file        Open the authoritative config.json\n  config-file path   Print the authoritative config path\n\nUPDATES\n  update             Download, verify, and install the latest GitHub release\n  update check       Check GitHub without installing\n\nTOOLS\n  reload             Reload saved configuration in the running app\n  editor <name> ...  Run Vim, Neovim, Emacs, Nano, Micro, or Helix\n  run <name> [text]  Run an enabled extension command\n  completions        Generate or install shell completions\n\nFLAGS\n  --help             Show this guide\n  --version          Print the version\n",TCurrentVersion().UTF8String);return 0;
    }
    if([arg isEqual:@"--version"]||[arg isEqual:@"version"]){fprintf(stdout,"Termatica %s\n",TCurrentVersion().UTF8String);return 0;}
    if([arg isEqual:@"editor"]||[arg isEqual:@"--editor"]||[arg isEqual:@"edit"]||[arg isEqual:@"--edit"])return TRunEditorCLI(argc,argv);
    if([arg isEqual:@"completions"]||[arg isEqual:@"--completions"])return TRunCompletionsCLI(argc,argv);
    if([arg isEqual:@"run"]||[arg isEqual:@"--run"]){if(argc<3){fputs("termatica: run requires an extension command name\n",stderr);return 2;}NSMutableArray *parts=[NSMutableArray array];for(int i=3;i<argc;i++)[parts addObject:[NSString stringWithUTF8String:argv[i]]];BOOL sent=TPostCLIRequest(@{@"command":@"run",@"name":[NSString stringWithUTF8String:argv[2]],@"query":[parts componentsJoinedByString:@" "]});if(!sent){fputs("termatica: the Termatica app is not running\n",stderr);return 1;}return 0;}
    TConfig *config=[TConfig new];
    if([arg isEqual:@"config"])return TRunUnifiedConfigCLI(argc,argv,config);
    if([arg isEqual:@"config-file"]){[config ensureEditableFile];if(argc>=3&&!strcmp(argv[2],"path"))fprintf(stdout,"%s\n",config.path.fileSystemRepresentation);else{TOpenPath(config.path);fprintf(stdout,"opened %s\n",config.path.fileSystemRepresentation);}return 0;}
    if([arg isEqual:@"update"])return TRunUpdateCLI(argc,argv,config);
    if([arg isEqual:@"--reload"]||[arg isEqual:@"reload"]){TPostCLICommand(@"reload");fputs("reload requested\n",stdout);return 0;}
    fprintf(stderr,"termatica: unknown command: %s\nRun 'termatica --help'.\n",arg.UTF8String);return 2;
}

typedef struct {
    uint32_t ch:24;
    uint32_t flags:8;
    uint32_t fg;
    uint32_t bg;
} TCell;
_Static_assert(sizeof(TCell)==12,"terminal cells must remain compact");

enum { TBold = 1, TItalic = 2, TUnderline = 4, TInverse = 8, TWide = 16, TContinuation = 32, TCluster = 64 };
enum { TStyleMask = TBold|TItalic|TUnderline|TInverse };
enum { TClusterBase = 0x110000 };
enum { TParseText, TParseEscape, TParseCSI, TParseOSC, TParseOSCEscape };

@interface TTerminalView : NSView
@property TConfig *config;
@property CGFloat leadingOverlayInset;
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
- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config;
- (BOOL)startShell;
- (void)stopShellTerminating:(BOOL)terminate;
- (void)drainPendingData;
- (void)sendString:(NSString *)string;
- (void)reloadAppearance;
- (void)clearTerminal;
- (void)clearScrollbackPreservingPrompt;
- (void)releaseAnimationLayer;
- (NSString *)visibleText;
- (void)setHiddenPathEnabled:(BOOL)enabled;
- (NSString *)workingDirectory;
@end

static NSMutableArray<TTerminalView *> *TTerminalDrainQueue;
static BOOL TTerminalDrainScheduled;
static void TArmTerminalDrain(void);
static void TScheduleTerminalDrain(TTerminalView *terminal) {
    if(!terminal)return;if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TScheduleTerminalDrain(terminal);});return;}
    if(!TTerminalDrainQueue)TTerminalDrainQueue=[NSMutableArray array];if(![TTerminalDrainQueue containsObject:terminal])[TTerminalDrainQueue addObject:terminal];TArmTerminalDrain();
}
static void TArmTerminalDrain(void) {
    if(TTerminalDrainScheduled||!TTerminalDrainQueue.count)return;TTerminalDrainScheduled=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1*NSEC_PER_MSEC),dispatch_get_main_queue(),^{TTerminalDrainScheduled=NO;if(!TTerminalDrainQueue.count)return;TTerminalView *next=TTerminalDrainQueue.firstObject;[TTerminalDrainQueue removeObjectAtIndex:0];[next drainPendingData];TArmTerminalDrain();});
}
static void TCancelTerminalDrain(TTerminalView *terminal) {
    if(!terminal)return;
    void (^cancel)(void)=^{while([TTerminalDrainQueue containsObject:terminal])[TTerminalDrainQueue removeObjectIdenticalTo:terminal];};
    if(NSThread.isMainThread)cancel();else dispatch_async(dispatch_get_main_queue(),cancel);
}

@implementation TTerminalView {
    int _master;
    pid_t _pid;
    dispatch_source_t _readSource;
    dispatch_queue_t _writeQueue;
    TCell *_cells;
    NSUInteger _rowOffset;
    NSUInteger _cols, _rows, _cursorX, _cursorY, _savedX, _savedY;
    NSUInteger _scrollTop, _scrollBottom;
    NSMutableArray<NSData *> *_history;
    NSUInteger _historyStart;
    NSMutableData *_scratchLine;
    NSMutableData *_glyphScratch;
    NSMutableData *_colorScratch;
    NSMutableData *_pendingData;
    NSUInteger _pendingOffset;
    BOOL _drainScheduled;
    BOOL _displayScheduled;
    BOOL _readPaused;
    BOOL _backpressureReported;
    NSInteger _historyOffset;
    NSFont *_font, *_boldFont, *_italicFont;
    CGFloat _cellWidth, _cellHeight;
    uint32_t _currentFG, _currentBG;
    uint8_t _currentFlags;
    int _parseState, _params[20], _paramIndex;
    BOOL _privateCSI, _bracketedPaste, _cursorVisible;
    NSMutableString *_osc;
    NSMutableDictionary<NSNumber *,NSDictionary *> *_attributeCache;
    NSMutableArray<NSString *> *_graphemes;
    NSMutableDictionary<NSString *,NSNumber *> *_graphemeIDs;
    NSMutableDictionary<NSNumber *,NSString *> *_linksByCell;
    NSString *_currentLink;
    NSMutableArray<NSDictionary *> *_commandMarks;
    NSUInteger _kittyKeyboardFlags;
    NSUInteger _modifyOtherKeys;
    uint8_t _csiPrefix;
    BOOL _accessibilityUpdatePending;
    uint32_t _utf8Code;
    int _utf8Needed;
    NSPoint _selectionStart, _selectionEnd;
    BOOL _selecting, _hasSelection, _tileDragging;
    BOOL _hiddenPathDesired;
    NSInteger _hiddenPathApplied;
    NSUInteger _hiddenPathGeneration;
}

- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config {
    if ((self = [super initWithFrame:frame])) {
        _config = config; _master = -1; _pid = -1; _hiddenPathApplied=-1; _history = [NSMutableArray array];_scratchLine=[NSMutableData data];_glyphScratch=[NSMutableData data];_colorScratch=[NSMutableData data];_pendingData=[NSMutableData data];_writeQueue=dispatch_queue_create("com.termatica.pty-write",DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
        _osc = [NSMutableString string];_attributeCache=[NSMutableDictionary dictionary];_graphemes=[NSMutableArray array];_graphemeIDs=[NSMutableDictionary dictionary];_linksByCell=[NSMutableDictionary dictionary];_commandMarks=[NSMutableArray array];_parseState = TParseText; _cursorVisible = YES;
        _currentFG = _currentBG = TDefaultColor;
        [self reloadAppearance];
        [self resizeGrid];
        self.accessibilityLabel = @"Terminal";
    }
    return self;
}
- (void)dealloc {
    [self stopShellTerminating:YES];
    free(_cells);
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event {return YES;}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return self.config.backgroundOpacity >= 0.999 && !self.config.blur; }
- (void)setNeedsDisplay:(BOOL)flag {[super setNeedsDisplay:flag];}
- (void)reloadAppearance {
    if(_historyStart||_history.count>self.config.scrollback){NSUInteger keep=MIN(_history.count,self.config.scrollback),first=_history.count-keep;NSMutableArray *ordered=[NSMutableArray arrayWithCapacity:keep];for(NSUInteger i=first;i<_history.count;i++)[ordered addObject:_history[(_historyStart+i)%_history.count]];_history=ordered;_historyStart=0;}
    [_attributeCache removeAllObjects];
    _font = [NSFont fontWithName:self.config.fontName size:self.config.fontSize] ?: [NSFont monospacedSystemFontOfSize:self.config.fontSize weight:NSFontWeightRegular];
    NSFontManager *fm = NSFontManager.sharedFontManager;
    _boldFont = [fm convertFont:_font toHaveTrait:NSBoldFontMask] ?: _font;
    _italicFont = [fm convertFont:_font toHaveTrait:NSItalicFontMask] ?: _font;
    NSDictionary *a = @{NSFontAttributeName:_font};
    NSSize size = [@"M" sizeWithAttributes:a];
    _cellWidth = ceil(size.width);
    _cellHeight = ceil(_font.ascender - _font.descender + _font.leading + 2);
    [self resizeGrid];
    [self refreshTextView];
    [self setNeedsDisplay:YES];
}
- (void)releaseAnimationLayer {if(self.layer.animationKeys.count){__weak TTerminalView *weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[weakSelf releaseAnimationLayer];});return;}self.wantsLayer=NO;}
- (TCell)blankCell { return (TCell){ .ch=' ', .fg=TDefaultColor, .bg=TDefaultColor, .flags=0 }; }
- (TCell *)cellsForRow:(NSUInteger)row {return _cells+((_rowOffset+row)%_rows)*_cols;}
- (void)normalizeRows {if(!_rowOffset||!_cells)return;TCell *ordered=malloc(_rows*_cols*sizeof(TCell));for(NSUInteger y=0;y<_rows;y++)memcpy(ordered+y*_cols,[self cellsForRow:y],_cols*sizeof(TCell));free(_cells);_cells=ordered;_rowOffset=0;}
- (void)addHistoryLine:(NSData *)line {NSUInteger limit=self.config.scrollback;if(!limit)return;if(_history.count<limit){[_history addObject:line];return;}_history[_historyStart]=line;_historyStart=(_historyStart+1)%_history.count;}
- (NSData *)historyLineAtIndex:(NSUInteger)index {return _history[(_historyStart+index)%_history.count];}
- (void)clearHistory {[_history removeAllObjects];_historyStart=0;}
- (void)resizeGrid {
    CGFloat topInset=self.safeAreaInsets.top,bottomInset=self.safeAreaInsets.bottom;
    NSUInteger cols = MAX(2, (NSUInteger)floor((self.bounds.size.width - self.config.padding * 2 - self.leadingOverlayInset) / MAX(1, _cellWidth)));
    NSUInteger rows = MAX(2, (NSUInteger)floor((self.bounds.size.height - self.config.padding * 2 - topInset - bottomInset) / MAX(1, _cellHeight)));
    if (cols == _cols && rows == _rows) return;
    TCell *next = calloc(cols * rows, sizeof(TCell));
    TCell blank = [self blankCell];
    for (NSUInteger i = 0; i < cols * rows; i++) next[i] = blank;
    if (_cells) {
        NSUInteger copyRows = MIN(rows, _rows), copyCols = MIN(cols, _cols);
        for (NSUInteger y = 0; y < copyRows; y++)
            memcpy(next + y * cols, [self cellsForRow:y], copyCols * sizeof(TCell));
        free(_cells);
    }
    _cells = next; _cols = cols; _rows = rows; _rowOffset=0;[_linksByCell removeAllObjects];
    _cursorX = MIN(_cursorX, cols - 1); _cursorY = MIN(_cursorY, rows - 1);
    _scrollTop = 0; _scrollBottom = rows - 1;
    if (_master >= 0) {
        struct winsize ws = { .ws_row=(unsigned short)rows, .ws_col=(unsigned short)cols,
                              .ws_xpixel=(unsigned short)self.bounds.size.width, .ws_ypixel=(unsigned short)self.bounds.size.height };
        ioctl(_master, TIOCSWINSZ, &ws);
    }
}
- (void)setFrameSize:(NSSize)newSize { [super setFrameSize:newSize]; if(newSize.width>100&&newSize.height>80)[self resizeGrid]; }
- (BOOL)startShell {
    if (_pid > 0) return YES;
    NSString *launchDirectory=self.launchDirectory;
    NSString *completionRoot=[TConfigDirectoryPath() stringByAppendingPathComponent:@"completions"];
    struct winsize ws = { .ws_row=(unsigned short)_rows, .ws_col=(unsigned short)_cols };
    _pid = forkpty(&_master, NULL, NULL, &ws);
    if (_pid < 0) { TLog(@"forkpty failed: %s", strerror(errno)); return NO; }
    if (_pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("CLICOLOR", "1", 0);
        setenv("LSCOLORS", "Gxfxcxdxbxegedabagacad", 0);
        setenv("TERM_PROGRAM", "Termatica", 1);
        setenv("TERM_PROGRAM_VERSION", "0.4.1", 1);
        setenv("TERMATICA_COMPLETIONS",completionRoot.fileSystemRepresentation,1);
        NSString *hiddenPathScript=[[[TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"] stringByAppendingPathComponent:@"hidden-path"] stringByAppendingPathComponent:@"prompt.sh"];
        setenv("TERM_HP",hiddenPathScript.fileSystemRepresentation,1);
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
    TLog(@"started %@ as pid %d on pty %d (%lux%lu)", self.config.shell, _pid, _master, _cols, _rows);
    __weak typeof(self) weakSelf = self;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _master, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    _readSource=source;
    dispatch_source_set_event_handler(source, ^{
        @autoreleasepool {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            int master=-1;@synchronized(self){if(self->_readSource!=source)return;master=self->_master;}
            uint8_t buffer[32768];
            ssize_t n = read(master, buffer, sizeof(buffer));
            if (n > 0) {
                BOOL schedule=NO;@synchronized(self){if(self->_readSource!=source)return;[self->_pendingData appendBytes:buffer length:(NSUInteger)n];NSUInteger queued=self->_pendingData.length-self->_pendingOffset;if(queued>=524288&&!self->_readPaused){self->_readPaused=YES;dispatch_suspend(source);if(!self->_backpressureReported){self->_backpressureReported=YES;TLog(@"PTY backpressure active at %lu queued bytes",(unsigned long)queued);}}if(!self->_drainScheduled){self->_drainScheduled=YES;schedule=YES;}}
                if(schedule)TScheduleTerminalDrain(self);
            } else if (n == 0) {TLog(@"shell pty reached EOF");[self stopShellTerminating:NO];}
            else if (errno != EAGAIN) {TLog(@"pty read failed: %s", strerror(errno));[self stopShellTerminating:YES];}
        }
    });
    dispatch_source_set_cancel_handler(source, ^{});
    dispatch_resume(source);
    [self setHiddenPathEnabled:[self.config isPluginEnabled:@"hidden-path"]];
    return YES;
}
- (void)stopShellTerminating:(BOOL)terminate {dispatch_source_t source=nil;@synchronized(self){source=_readSource;_readSource=nil;if(source&&_readPaused){_readPaused=NO;dispatch_resume(source);}if(terminate){[_pendingData setLength:0];_pendingOffset=0;_drainScheduled=NO;_backpressureReported=NO;}}if(terminate)TCancelTerminalDrain(self);if(source)dispatch_source_cancel(source);int master=_master;_master=-1;if(master>=0)close(master);pid_t child=_pid;_pid=-1;if(child>0){if(terminate)kill(child,SIGHUP);dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{int status=0;while(waitpid(child,&status,0)<0&&errno==EINTR){}});}}
- (void)drainPendingData {
    NSData *chunk=nil;BOOL more=NO;dispatch_source_t resumeSource=nil;
    @synchronized(self){
        NSUInteger available=_pendingData.length-_pendingOffset,take=MIN((NSUInteger)4096,available);
        if(take)chunk=[NSData dataWithBytes:(const uint8_t *)_pendingData.bytes+_pendingOffset length:take];
        _pendingOffset+=take;
        if(_pendingOffset>=262144&&_pendingOffset*2>=_pendingData.length){[_pendingData replaceBytesInRange:NSMakeRange(0,_pendingOffset) withBytes:NULL length:0];_pendingOffset=0;}
        available=_pendingData.length-_pendingOffset;more=available>0;
        if(_readPaused&&available<=131072&&_readSource){_readPaused=NO;resumeSource=_readSource;}
        if(!more){[_pendingData setLength:0];_pendingOffset=0;_drainScheduled=NO;}
    }
    if(resumeSource)dispatch_resume(resumeSource);
    if(chunk.length)[self consumeData:chunk];
    if(more)TScheduleTerminalDrain(self);
}
- (void)sendBytes:(const void *)bytes length:(NSUInteger)length {
    if(!length)return;NSData *payload=[NSData dataWithBytes:bytes length:length];__weak typeof(self) weakSelf=self;
    dispatch_async(_writeQueue,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;const uint8_t *cursor=payload.bytes;NSUInteger remaining=payload.length;while(remaining){int master=-1;@synchronized(self){master=self->_master;}if(master<0)return;ssize_t written=write(master,cursor,remaining);if(written>0){cursor+=written;remaining-=(NSUInteger)written;continue;}if(written<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){struct pollfd descriptor={.fd=master,.events=POLLOUT};if(poll(&descriptor,1,20)>=0)continue;}if(written<0&&errno==EINTR)continue;return;}});
}
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
    static BOOL reportedFirstShellOutput = NO;
    if (!reportedFirstShellOutput) {
        reportedFirstShellOutput = YES;
        TLog(@"first shell output after %.2f ms", (CFAbsoluteTimeGetCurrent() - TProcessStartedAt) * 1000.0);
    }
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [self consumeByte:bytes[i]];
    _historyOffset = 0;
    [self refreshTextView];
    if(NSWorkspace.sharedWorkspace.isVoiceOverEnabled&&!_accessibilityUpdatePending){_accessibilityUpdatePending=YES;__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;self.accessibilityValue=[self visibleText];self->_accessibilityUpdatePending=NO;});}
}
- (void)consumeByte:(uint8_t)b {
    if (_parseState == TParseOSC) {
        if (b == 7) { [self finishOSC]; _parseState = TParseText; }
        else if (b == 27) _parseState = TParseOSCEscape;
        else if (b >= 32 && _osc.length < 4096) [_osc appendFormat:@"%c", b];
        return;
    }
    if (_parseState == TParseOSCEscape) {
        if (b == '\\') { [self finishOSC]; _parseState = TParseText; }
        else _parseState = TParseOSC;
        return;
    }
    if (_parseState == TParseEscape) {
        _parseState = TParseText;
        if (b == '[') { _parseState = TParseCSI; memset(_params, 0, sizeof(_params)); _paramIndex = 0; _privateCSI = NO; _csiPrefix=0; }
        else if (b == ']') { [_osc setString:@""]; _parseState = TParseOSC; }
        else if (b == '7') { _savedX = _cursorX; _savedY = _cursorY; }
        else if (b == '8') { _cursorX = MIN(_savedX, _cols-1); _cursorY = MIN(_savedY, _rows-1); }
        else if (b == 'D') [self lineFeed];
        else if (b == 'E') { _cursorX = 0; [self lineFeed]; }
        else if (b == 'M') [self reverseIndex];
        else if (b == 'c') [self resetTerminal];
        return;
    }
    if (_parseState == TParseCSI) {
        if (b == '?' || b == '>' || b == '<' || b == '=') { _privateCSI = YES; _csiPrefix=b; return; }
        if (b >= '0' && b <= '9') { _params[_paramIndex] = _params[_paramIndex] * 10 + b - '0'; return; }
        if (b == ';' || b == ':') { if (_paramIndex < 19) _paramIndex++; return; }
        if (b >= 0x40 && b <= 0x7E) { [self executeCSI:b]; _parseState = TParseText; }
        return;
    }
    if (b == 27) { _parseState = TParseEscape; return; }
    if (b == 7) { NSBeep(); return; }
    if (b == 8) { if (_cursorX) _cursorX--; return; }
    if (b == 9) { _cursorX = MIN(((_cursorX / 8) + 1) * 8, _cols - 1); return; }
    if (b == 10 || b == 11 || b == 12) { [self lineFeed]; return; }
    if (b == 13) { _cursorX = 0; return; }
    if (b < 32 || b == 127) return;
    if (_utf8Needed) {
        if ((b & 0xC0) != 0x80) { _utf8Needed = 0; [self putCodepoint:0xFFFD]; [self consumeByte:b]; return; }
        _utf8Code = (_utf8Code << 6) | (b & 0x3F);
        if (--_utf8Needed == 0) [self putCodepoint:_utf8Code];
    } else if (b < 0x80) [self putCodepoint:b];
    else if ((b & 0xE0) == 0xC0) { _utf8Code = b & 0x1F; _utf8Needed = 1; }
    else if ((b & 0xF0) == 0xE0) { _utf8Code = b & 0x0F; _utf8Needed = 2; }
    else if ((b & 0xF8) == 0xF0) { _utf8Code = b & 0x07; _utf8Needed = 3; }
    else [self putCodepoint:0xFFFD];
}
- (int)param:(int)i defaultValue:(int)value { return i <= _paramIndex && _params[i] ? _params[i] : value; }
- (void)executeCSI:(uint8_t)command {
    int n = [self param:0 defaultValue:1];
    if((_csiPrefix=='>'||_csiPrefix=='=')&&command=='u'){_kittyKeyboardFlags=(NSUInteger)MAX(0,_params[0]);return;}
    if(_csiPrefix=='<'&&command=='u'){_kittyKeyboardFlags=0;return;}
    if(_csiPrefix=='?'&&command=='u'){[self sendString:[NSString stringWithFormat:@"\033[?%luu",(unsigned long)_kittyKeyboardFlags]];return;}
    if(_csiPrefix=='>'&&command=='m'&&_params[0]==4){_modifyOtherKeys=(NSUInteger)MAX(0,_params[1]);return;}
    switch (command) {
        case 'A': _cursorY = n > (int)_cursorY ? 0 : _cursorY - n; break;
        case 'B': _cursorY = MIN(_rows - 1, _cursorY + n); break;
        case 'C': _cursorX = MIN(_cols - 1, _cursorX + n); break;
        case 'D': _cursorX = n > (int)_cursorX ? 0 : _cursorX - n; break;
        case 'E': _cursorY = MIN(_rows - 1, _cursorY + n); _cursorX = 0; break;
        case 'F': _cursorY = n > (int)_cursorY ? 0 : _cursorY - n; _cursorX = 0; break;
        case 'G': _cursorX = MIN(_cols - 1, (NSUInteger)(n - 1)); break;
        case 'H': case 'f': _cursorY = MIN(_rows - 1, (NSUInteger)([self param:0 defaultValue:1] - 1)); _cursorX = MIN(_cols - 1, (NSUInteger)([self param:1 defaultValue:1] - 1)); break;
        case 'd': _cursorY = MIN(_rows - 1, (NSUInteger)(n - 1)); break;
        case 'J': [self eraseDisplay:_params[0]]; break;
        case 'K': [self eraseLine:_params[0]]; break;
        case 'm': [self applySGR]; break;
        case 's': _savedX = _cursorX; _savedY = _cursorY; break;
        case 'u': _cursorX = MIN(_savedX, _cols-1); _cursorY = MIN(_savedY, _rows-1); break;
        case 'r': {
            NSUInteger top = (NSUInteger)([self param:0 defaultValue:1] - 1);
            NSUInteger bottom = (NSUInteger)([self param:1 defaultValue:(int)_rows] - 1);
            if (top < bottom && bottom < _rows) { _scrollTop = top; _scrollBottom = bottom; _cursorX = _cursorY = 0; }
            break;
        }
        case 'h': case 'l': if (_privateCSI) [self setPrivateMode:_params[0] enabled:command == 'h']; break;
        case 'P': [self deleteCharacters:n]; break;
        case '@': [self insertCharacters:n]; break;
        case 'X': [self eraseCharacters:n]; break;
        case 'L': [self insertLines:n]; break;
        case 'M': [self deleteLines:n]; break;
        case 'n': if (_params[0] == 6) [self sendString:[NSString stringWithFormat:@"\033[%lu;%luR", _cursorY+1, _cursorX+1]]; else if (_params[0] == 5) [self sendString:@"\033[0n"]; break;
        case 'c': [self sendString:@"\033[?1;2c"]; break;
        default: break;
    }
}
- (void)applySGR {
    if (_paramIndex == 0 && _params[0] == 0) { _currentFG = _currentBG = TDefaultColor; _currentFlags = 0; return; }
    for (int i = 0; i <= _paramIndex; i++) {
        int p = _params[i];
        if (p == 0) { _currentFG = _currentBG = TDefaultColor; _currentFlags = 0; }
        else if (p == 1) _currentFlags |= TBold;
        else if (p == 3) _currentFlags |= TItalic;
        else if (p == 4) _currentFlags |= TUnderline;
        else if (p == 7) _currentFlags |= TInverse;
        else if (p == 22) _currentFlags &= ~TBold;
        else if (p == 23) _currentFlags &= ~TItalic;
        else if (p == 24) _currentFlags &= ~TUnderline;
        else if (p == 27) _currentFlags &= ~TInverse;
        else if (p >= 30 && p <= 37) _currentFG = TRGB(self.config.palette[p - 30]);
        else if (p >= 40 && p <= 47) _currentBG = TRGB(self.config.palette[p - 40]);
        else if (p >= 90 && p <= 97) _currentFG = TRGB(self.config.palette[p - 90 + 8]);
        else if (p >= 100 && p <= 107) _currentBG = TRGB(self.config.palette[p - 100 + 8]);
        else if (p == 39) _currentFG = TDefaultColor;
        else if (p == 49) _currentBG = TDefaultColor;
        else if ((p == 38 || p == 48) && i + 1 <= _paramIndex) {
            uint32_t color = TDefaultColor;
            if (_params[i+1] == 5 && i + 2 <= _paramIndex) { color = [self colorFor256:_params[i+2]]; i += 2; }
            else if (_params[i+1] == 2 && i + 4 <= _paramIndex) { color = ((_params[i+2]&255)<<16)|((_params[i+3]&255)<<8)|(_params[i+4]&255); i += 4; }
            if (p == 38) _currentFG = color; else _currentBG = color;
        }
    }
}
- (uint32_t)colorFor256:(int)i {
    if (i < 16) return TRGB(self.config.palette[MAX(0, i)]);
    if (i < 232) { int q=i-16, r=q/36, g=(q/6)%6, b=q%6; int levels[]={0,95,135,175,215,255}; return (levels[r]<<16)|(levels[g]<<8)|levels[b]; }
    int v = 8 + (i - 232) * 10; return (v<<16)|(v<<8)|v;
}
- (void)setPrivateMode:(int)mode enabled:(BOOL)enabled {
    if (mode == 25) _cursorVisible = enabled;
    else if (mode == 2004) _bracketedPaste = enabled;
    else if (mode == 1049 || mode == 47 || mode == 1047) { [self clearTerminal]; _historyOffset = 0; }
}
- (uint32_t)internGrapheme:(NSString *)value {
    NSNumber *existing=_graphemeIDs[value];if(existing)return existing.unsignedIntValue;
    if(_graphemes.count>=0xEEFFFF)return 0xFFFD;uint32_t token=(uint32_t)(TClusterBase+_graphemes.count);[_graphemes addObject:value];_graphemeIDs[value]=@(token);return token;
}
- (NSNumber *)linkKeyForX:(NSUInteger)x y:(NSUInteger)y {return @((((_rowOffset+y)%_rows)*_cols)+x);}
- (void)clearWideCellAtX:(NSUInteger)x row:(TCell *)row {
    if(x>=_cols)return;if(row[x].flags&TWide){if(x+1<_cols)row[x+1]=[self blankCell];}
    else if((row[x].flags&TContinuation)&&x){row[x-1].flags&=~TWide;}
}
- (void)putCodepoint:(uint32_t)cp {
    if(self.config.unicodeRendering&&_cursorX){
        TCell *row=[self cellsForRow:_cursorY];NSUInteger baseX=_cursorX-1;if((row[baseX].flags&TContinuation)&&baseX)baseX--;TCell *base=&row[baseX];NSString *existing=[self stringForCodepoint:base->ch];BOOL joins=TUnicodeCombining(cp)||[existing hasSuffix:@"\u200D"]||(TUnicodeRegional(cp)&&TUnicodeRegional(base->ch));
        if(joins&&base->ch!=' '&&!(base->flags&TContinuation)){NSString *scalar=[self stringForCodepoint:cp],*cluster=[existing stringByAppendingString:scalar];base->ch=[self internGrapheme:cluster];base->flags|=TCluster;if((TUnicodeWide(cp)||cp==0xFE0F||cp==0x200D)&&!(base->flags&TWide)&&baseX+1<_cols){base->flags|=TWide;row[baseX+1]=(TCell){.ch=0,.fg=base->fg,.bg=base->bg,.flags=TContinuation};if(_cursorX==baseX+1)_cursorX++;}return;}
    }
    NSUInteger width=self.config.unicodeRendering&&TUnicodeWide(cp)?2:1;
    if (_cursorX >= _cols||(_cursorX+width>_cols)) { _cursorX = 0; [self lineFeed]; }
    TCell *row=[self cellsForRow:_cursorY];[self clearWideCellAtX:_cursorX row:row];TCell *c=row+_cursorX;
    c->ch = cp; c->fg = _currentFG; c->bg = _currentBG; c->flags = _currentFlags|(width==2?TWide:0);
    NSNumber *linkKey=[self linkKeyForX:_cursorX y:_cursorY];if(self.config.oscIntegration&&_currentLink.length)_linksByCell[linkKey]=_currentLink;else[_linksByCell removeObjectForKey:linkKey];
    if(width==2){row[_cursorX+1]=(TCell){.ch=0,.fg=_currentFG,.bg=_currentBG,.flags=TContinuation};NSNumber *continuation=[self linkKeyForX:_cursorX+1 y:_cursorY];if(self.config.oscIntegration&&_currentLink.length)_linksByCell[continuation]=_currentLink;else[_linksByCell removeObjectForKey:continuation];}
    _cursorX+=width;
}
- (void)lineFeed {
    if (_cursorY == _scrollBottom) [self scrollUp];
    else _cursorY = MIN(_rows - 1, _cursorY + 1);
}
- (void)scrollUp {
    if (_scrollTop == 0 && _scrollBottom == _rows - 1) {
        TCell *top=[self cellsForRow:0];NSUInteger used=_cols;TCell blank=[self blankCell];while(used){TCell cell=top[used-1];if(cell.ch!=blank.ch||cell.flags!=blank.flags||cell.fg!=blank.fg||cell.bg!=blank.bg)break;used--;}
        [self addHistoryLine:[NSData dataWithBytes:top length:used*sizeof(TCell)]];
        _rowOffset=(_rowOffset+1)%_rows;TCell *bottom=[self cellsForRow:_rows-1];NSUInteger physical=(_rowOffset+_rows-1)%_rows;for(NSUInteger x=0;x<_cols;x++){bottom[x]=blank;[_linksByCell removeObjectForKey:@(physical*_cols+x)];}return;
    }
    [self normalizeRows];
    memmove(_cells + _scrollTop * _cols, _cells + (_scrollTop + 1) * _cols, (_scrollBottom - _scrollTop) * _cols * sizeof(TCell));
    TCell blank = [self blankCell];
    for (NSUInteger x=0; x<_cols; x++) _cells[_scrollBottom*_cols+x]=blank;
}
- (void)reverseIndex {
    if (_cursorY > _scrollTop) { _cursorY--; return; }
    if(_scrollTop==0&&_scrollBottom==_rows-1){_rowOffset=(_rowOffset+_rows-1)%_rows;TCell blank=[self blankCell],*top=[self cellsForRow:0];NSUInteger physical=_rowOffset;for(NSUInteger x=0;x<_cols;x++){top[x]=blank;[_linksByCell removeObjectForKey:@(physical*_cols+x)];}return;}
    [self normalizeRows];
    memmove(_cells + (_scrollTop + 1) * _cols, _cells + _scrollTop * _cols, (_scrollBottom - _scrollTop) * _cols * sizeof(TCell));
    TCell blank=[self blankCell]; for(NSUInteger x=0;x<_cols;x++) _cells[_scrollTop*_cols+x]=blank;
}
- (void)eraseDisplay:(int)mode {
    TCell blank=[self blankCell];
    if (mode==2 || mode==3) { for(NSUInteger i=0;i<_cols*_rows;i++) _cells[i]=blank;_rowOffset=0;if(mode==3)[self clearHistory]; }
    else if(mode==0){for(NSUInteger y=_cursorY;y<_rows;y++){TCell *row=[self cellsForRow:y];NSUInteger start=y==_cursorY?_cursorX:0;for(NSUInteger x=start;x<_cols;x++)row[x]=blank;}}
    else if(mode==1){for(NSUInteger y=0;y<=_cursorY&&y<_rows;y++){TCell *row=[self cellsForRow:y];NSUInteger end=y==_cursorY?MIN(_cols,_cursorX+1):_cols;for(NSUInteger x=0;x<end;x++)row[x]=blank;}}
}
- (void)eraseLine:(int)mode {
    TCell blank=[self blankCell]; NSUInteger a=0,b=_cols;
    if(mode==0)a=_cursorX; else if(mode==1)b=MIN(_cols,_cursorX+1);
    TCell *row=[self cellsForRow:_cursorY];for(NSUInteger x=a;x<b;x++)row[x]=blank;
}
- (void)eraseCharacters:(int)n { TCell b=[self blankCell],*row=[self cellsForRow:_cursorY];for(NSUInteger x=_cursorX;x<MIN(_cols,_cursorX+(NSUInteger)n);x++)row[x]=b; }
- (void)deleteCharacters:(int)n { NSUInteger count=MIN((NSUInteger)n,_cols-_cursorX);TCell b=[self blankCell],*row=[self cellsForRow:_cursorY];memmove(row+_cursorX,row+_cursorX+count,(_cols-_cursorX-count)*sizeof(TCell));for(NSUInteger x=_cols-count;x<_cols;x++)row[x]=b; }
- (void)insertCharacters:(int)n { NSUInteger count=MIN((NSUInteger)n,_cols-_cursorX);TCell b=[self blankCell],*row=[self cellsForRow:_cursorY];memmove(row+_cursorX+count,row+_cursorX,(_cols-_cursorX-count)*sizeof(TCell));for(NSUInteger x=_cursorX;x<_cursorX+count;x++)row[x]=b; }
- (void)insertLines:(int)n { if(_cursorY<_scrollTop||_cursorY>_scrollBottom)return;[self normalizeRows];NSUInteger count=MIN((NSUInteger)n,_scrollBottom-_cursorY+1);memmove(_cells+(_cursorY+count)*_cols,_cells+_cursorY*_cols,(_scrollBottom-_cursorY+1-count)*_cols*sizeof(TCell));TCell b=[self blankCell];for(NSUInteger i=_cursorY*_cols;i<(_cursorY+count)*_cols;i++)_cells[i]=b; }
- (void)deleteLines:(int)n { if(_cursorY<_scrollTop||_cursorY>_scrollBottom)return;[self normalizeRows];NSUInteger count=MIN((NSUInteger)n,_scrollBottom-_cursorY+1);memmove(_cells+_cursorY*_cols,_cells+(_cursorY+count)*_cols,(_scrollBottom-_cursorY+1-count)*_cols*sizeof(TCell));TCell b=[self blankCell];for(NSUInteger i=(_scrollBottom-count+1)*_cols;i<=_scrollBottom*_cols+_cols-1;i++)_cells[i]=b; }
- (void)finishOSC {
    NSArray *parts=[_osc componentsSeparatedByString:@";"];
    if(parts.count>1 && ([parts[0] isEqualToString:@"0"]||[parts[0] isEqualToString:@"2"])) {
        NSString *title=[[parts subarrayWithRange:NSMakeRange(1,parts.count-1)] componentsJoinedByString:@";"];
        if(self.titleChanged)self.titleChanged(title);
    } else if (self.config.oscIntegration&&[_osc hasPrefix:@"7;file://"]) {
        NSString *urlString=[_osc substringFromIndex:2]; NSURL *url=[NSURL URLWithString:urlString];
        if(url.path.length && self.cwdChanged)self.cwdChanged(url.path);
    } else if(self.config.oscIntegration&&[_osc hasPrefix:@"8;"]){
        NSRange first=[_osc rangeOfString:@";"],second=first.location==NSNotFound?NSMakeRange(NSNotFound,0):[_osc rangeOfString:@";" options:0 range:NSMakeRange(NSMaxRange(first),_osc.length-NSMaxRange(first))];NSString *url=second.location==NSNotFound?@"":[_osc substringFromIndex:NSMaxRange(second)];_currentLink=url.length?url:nil;
    } else if(self.config.oscIntegration&&[_osc hasPrefix:@"133;"]){
        NSString *mark=parts.count>1?parts[1]:@"";NSMutableDictionary *entry=[@{@"mark":mark,@"row":@(_history.count+_cursorY)} mutableCopy];if([mark isEqual:@"D"]&&parts.count>2)entry[@"status"]=parts[2];[_commandMarks addObject:entry];if(_commandMarks.count>2048)[_commandMarks removeObjectsInRange:NSMakeRange(0,_commandMarks.count-2048)];
    }
    [_osc setString:@""];
}
- (void)resetTerminal { _currentFG=_currentBG=TDefaultColor; _currentFlags=0; _cursorX=_cursorY=0; _scrollTop=0; _scrollBottom=_rows-1;_kittyKeyboardFlags=0;_modifyOtherKeys=0;_currentLink=nil;[_commandMarks removeAllObjects];[_linksByCell removeAllObjects]; [self eraseDisplay:2]; }
- (void)clearTerminal { [self eraseDisplay:2]; _cursorX=_cursorY=0; [self clearHistory]; [self refreshTextView];[self setNeedsDisplay:YES]; }
- (void)clearScrollbackPreservingPrompt {
    [self clearHistory];_historyOffset=0;_hasSelection=NO;
    uint8_t formFeed=0x0C;[self sendBytes:&formFeed length:1];
    [self refreshTextView];[self setNeedsDisplay:YES];
}

- (const TCell *)lineAtVisibleIndex:(NSInteger)index temporary:(NSData **)temporary {
    NSInteger totalHistory=(NSInteger)_history.count;
    NSInteger first=totalHistory-(NSInteger)_historyOffset;
    NSInteger logical=first+index;
    if(logical<totalHistory && logical>=0){NSData *d=[self historyLineAtIndex:(NSUInteger)logical];NSUInteger full=_cols*sizeof(TCell);if(d.length>=full){*temporary=d;return d.bytes;}[_scratchLine setLength:full];TCell blank=[self blankCell],*cells=_scratchLine.mutableBytes;for(NSUInteger i=0;i<_cols;i++)cells[i]=blank;if(d.length)memcpy(cells,d.bytes,d.length);*temporary=_scratchLine;return cells;}
    NSInteger row=logical-totalHistory;
    if(row>=0 && row<(NSInteger)_rows)return [self cellsForRow:(NSUInteger)row];
    return NULL;
}
- (BOOL)cellSelectedX:(NSUInteger)x y:(NSUInteger)y {
    if(!_hasSelection)return NO;
    NSInteger a=(NSInteger)_selectionStart.y*(NSInteger)_cols+(NSInteger)_selectionStart.x;
    NSInteger b=(NSInteger)_selectionEnd.y*(NSInteger)_cols+(NSInteger)_selectionEnd.x;
    if(a>b){NSInteger t=a;a=b;b=t;} NSInteger p=(NSInteger)y*(NSInteger)_cols+(NSInteger)x;
    return p>=a&&p<=b;
}
- (NSString *)stringForCodepoint:(uint32_t)cp {if(cp>=TClusterBase){NSUInteger index=cp-TClusterBase;return index<_graphemes.count?_graphemes[index]:@"\uFFFD";}if(cp<=0xFFFF)return [NSString stringWithCharacters:(unichar[]){(unichar)(cp?:' ')} length:1];if(cp>0x10FFFF)return @"\uFFFD";uint32_t v=cp-0x10000;unichar pair[2]={(unichar)(0xD800+(v>>10)),(unichar)(0xDC00+(v&0x3FF))};return [NSString stringWithCharacters:pair length:2];}
- (void)refreshTextView {
    if(_displayScheduled||self.hidden)return;_displayScheduled=YES;__weak typeof(self) weakSelf=self;uint64_t delay=self.activeTerminal?16:33;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;self->_displayScheduled=NO;[self setNeedsDisplay:YES];});
}
- (NSDictionary *)textAttributesForForeground:(uint32_t)foreground flags:(uint8_t)flags shadow:(NSShadow *)shadow {NSNumber *key=@((foreground<<8)|flags);NSDictionary *cached=_attributeCache[key];if(cached)return cached;NSFont *font=(flags&TBold)?_boldFont:((flags&TItalic)?_italicFont:_font);CGFloat glyphAdvance=[@"M" sizeWithAttributes:@{NSFontAttributeName:font}].width,cellKern=_cellWidth-glyphAdvance;NSMutableDictionary *attrs=[@{NSFontAttributeName:font,NSForegroundColorAttributeName:TColor(foreground),NSKernAttributeName:@(cellKern)} mutableCopy];if(shadow)attrs[NSShadowAttributeName]=shadow;if(flags&TUnderline)attrs[NSUnderlineStyleAttributeName]=@(NSUnderlineStyleSingle);if(_attributeCache.count>=128)[_attributeCache removeAllObjects];_attributeCache[key]=attrs;return attrs;}
- (void)drawRect:(NSRect)dirtyRect {
    [self.config.background setFill];NSRectFill(dirtyRect);CGFloat pad=self.config.padding+self.leadingOverlayInset,top=self.config.padding+self.safeAreaInsets.top;NSShadow *phosphor=nil;if(self.config.glow>0){phosphor=[NSShadow new];phosphor.shadowColor=[self.config.accent colorWithAlphaComponent:self.config.glow];phosphor.shadowBlurRadius=1+self.config.glow*3;phosphor.shadowOffset=NSZeroSize;}
    NSInteger firstRow=MAX(0,(NSInteger)floor((NSMinY(dirtyRect)-top)/MAX(1,_cellHeight))),lastRow=MIN((NSInteger)_rows,(NSInteger)ceil((NSMaxY(dirtyRect)-top)/MAX(1,_cellHeight)));NSInteger firstColumn=MAX(0,(NSInteger)floor((NSMinX(dirtyRect)-pad)/MAX(1,_cellWidth))),lastColumn=MIN((NSInteger)_cols,(NSInteger)ceil((NSMaxX(dirtyRect)-pad)/MAX(1,_cellWidth)));if(lastRow<firstRow)lastRow=firstRow;if(lastColumn<firstColumn)lastColumn=firstColumn;
    uint32_t defaultForeground=TRGB(self.config.foreground),defaultBackground=TRGB(self.config.background),plainRGB[8]={0};NSUInteger plainCount=self.config.colorizePlainText?MIN((NSUInteger)8,self.config.plainTextPalette.count):0;for(NSUInteger i=0;i<plainCount;i++)plainRGB[i]=TRGB(self.config.plainTextPalette[i]);[_glyphScratch setLength:MAX((NSUInteger)1,_cols*2)*sizeof(unichar)];[_colorScratch setLength:MAX((NSUInteger)1,_cols)*sizeof(uint32_t)];unichar *glyphs=_glyphScratch.mutableBytes;uint32_t *plainForegrounds=_colorScratch.mutableBytes;
    for(NSInteger y=firstRow;y<lastRow;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:y temporary:&hold];if(!line)continue;
        BOOL inPlainToken=NO;NSUInteger plainToken=0;for(NSUInteger column=0;column<_cols;column++){uint32_t codepoint=line[column].ch;BOOL whitespace=!codepoint||codepoint==' '||codepoint=='\t';if(whitespace)inPlainToken=NO;else if(!inPlainToken){inPlainToken=YES;plainToken++;}plainForegrounds[column]=plainCount&&!whitespace?plainRGB[(plainToken-1)%plainCount]:defaultForeground;}
        NSInteger x=firstColumn;while(x<lastColumn){TCell c=line[x];BOOL selected=[self cellSelectedX:(NSUInteger)x y:(NSUInteger)y],inverse=(c.flags&TInverse)!=0;uint32_t background=c.bg==TDefaultColor?defaultBackground:c.bg,foreground=c.fg==TDefaultColor?defaultForeground:c.fg;if(inverse){uint32_t swap=foreground;foreground=background;background=swap;}NSInteger kind=selected?1:((c.bg!=TDefaultColor||inverse)?2:0),start=x;x++;while(x<lastColumn){TCell next=line[x];BOOL nextSelected=[self cellSelectedX:(NSUInteger)x y:(NSUInteger)y],nextInverse=(next.flags&TInverse)!=0;uint32_t nextBackground=next.bg==TDefaultColor?defaultBackground:next.bg,nextForeground=next.fg==TDefaultColor?defaultForeground:next.fg;if(nextInverse){uint32_t swap=nextForeground;nextForeground=nextBackground;nextBackground=swap;}NSInteger nextKind=nextSelected?1:((next.bg!=TDefaultColor||nextInverse)?2:0);if(nextKind!=kind||(kind==2&&nextBackground!=background))break;x++;}if(kind){[(kind==1?self.config.selection:TColor(background)) setFill];NSRectFill(NSMakeRect(pad+start*_cellWidth,top+y*_cellHeight,(x-start)*_cellWidth,_cellHeight));}}
        x=firstColumn;while(x<lastColumn){TCell c=line[x];if(c.flags&TContinuation){x++;continue;}uint32_t foreground=c.fg==TDefaultColor&&!(c.flags&TInverse)?plainForegrounds[x]:(c.fg==TDefaultColor?defaultForeground:c.fg),background=c.bg==TDefaultColor?defaultBackground:c.bg;if(c.flags&TInverse){uint32_t swap=foreground;foreground=background;background=swap;}BOOL linked=_historyOffset==0&&_linksByCell[[self linkKeyForX:(NSUInteger)x y:(NSUInteger)y]]!=nil;uint8_t flags=(c.flags&TStyleMask)|(linked?TUnderline:0);if(c.flags&(TWide|TCluster)){NSString *text=[self stringForCodepoint:c.ch];NSMutableDictionary *attrs=[[self textAttributesForForeground:foreground flags:flags shadow:phosphor] mutableCopy];[attrs removeObjectForKey:NSKernAttributeName];[text drawAtPoint:NSMakePoint(pad+x*_cellWidth,top+y*_cellHeight) withAttributes:attrs];x+=(c.flags&TWide)?2:1;continue;}NSInteger start=x;NSUInteger length=0;BOOL hasGlyph=NO;while(x<lastColumn){TCell next=line[x];if(next.flags&(TWide|TCluster|TContinuation))break;uint32_t nextForeground=next.fg==TDefaultColor&&!(next.flags&TInverse)?plainForegrounds[x]:(next.fg==TDefaultColor?defaultForeground:next.fg),nextBackground=next.bg==TDefaultColor?defaultBackground:next.bg;if(next.flags&TInverse){uint32_t swap=nextForeground;nextForeground=nextBackground;nextBackground=swap;}BOOL nextLinked=_historyOffset==0&&_linksByCell[[self linkKeyForX:(NSUInteger)x y:(NSUInteger)y]]!=nil;uint8_t nextFlags=(next.flags&TStyleMask)|(nextLinked?TUnderline:0);if(nextForeground!=foreground||nextFlags!=flags)break;uint32_t codepoint=next.ch?:' ';if(codepoint!=' ')hasGlyph=YES;length=TAppendUTF16(glyphs,length,codepoint);x++;}if(hasGlyph&&length){NSString *text=[[NSString alloc]initWithCharacters:glyphs length:length];[text drawAtPoint:NSMakePoint(pad+start*_cellWidth,top+y*_cellHeight) withAttributes:[self textAttributesForForeground:foreground flags:flags shadow:phosphor]];}}
    }
    if(_cursorVisible&&_historyOffset==0&&(self.window.firstResponder==self||self.activeTerminal)){BOOL block=![self.config.cursorStyle isEqual:@"bar"]&&![self.config.cursorStyle isEqual:@"underline"];[[self.config.cursor colorWithAlphaComponent:block?0.42:0.96]setFill];NSRect r=NSMakeRect(pad+_cursorX*_cellWidth,top+_cursorY*_cellHeight,_cellWidth,_cellHeight);if([self.config.cursorStyle isEqual:@"bar"])r.size.width=2;else if([self.config.cursorStyle isEqual:@"underline"]){r.origin.y+=_cellHeight-2;r.size.height=2;}NSRectFillUsingOperation(r,NSCompositingOperationSourceOver);}
    if(self.config.scanlines>0){[[NSColor colorWithWhite:0 alpha:self.config.scanlines*0.10]setFill];CGFloat start=MAX(2,floor(NSMinY(dirtyRect)/4)*4);for(CGFloat y=start;y<NSMaxY(dirtyRect);y+=4)NSRectFillUsingOperation(NSMakeRect(NSMinX(dirtyRect),y,NSWidth(dirtyRect),1),NSCompositingOperationSourceOver);}
    if(self.config.vignette>0&&!self.tiledRendering){for(NSUInteger i=0;i<6;i++){[[NSColor colorWithWhite:0 alpha:self.config.vignette*(6-i)/30.0]setStroke];NSBezierPath *p=[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds,i+0.5,i+0.5)];[p stroke];}}
}
- (NSPoint)cellForPoint:(NSPoint)p { NSInteger x=floor((p.x-self.config.padding-self.leadingOverlayInset)/_cellWidth),y=floor((p.y-self.config.padding-self.safeAreaInsets.top)/_cellHeight); return NSMakePoint(MAX(0,MIN((NSInteger)_cols-1,x)),MAX(0,MIN((NSInteger)_rows-1,y))); }
- (void)mouseDown:(NSEvent *)event {
    if(self.focused)self.focused();
    if(!self.tiledRendering)[self.window makeFirstResponder:self];
    NSPoint local=[self convertPoint:event.locationInWindow fromView:nil];
    NSPoint cell=[self cellForPoint:local];if(self.config.oscIntegration&&_historyOffset==0&&(event.modifierFlags&NSEventModifierFlagCommand)){NSString *link=_linksByCell[[self linkKeyForX:(NSUInteger)cell.x y:(NSUInteger)cell.y]];NSURL *url=link.length?[NSURL URLWithString:link]:nil;if(url){[NSWorkspace.sharedWorkspace openURL:url];return;}}
    BOOL commandDrag=(event.modifierFlags&NSEventModifierFlagCommand)!=0;
    BOOL paddingDrag=local.y<=MAX(10,self.config.padding);
    if(self.tiledRendering&&(commandDrag||paddingDrag)&&self.tileDragBegan){_tileDragging=YES;_selecting=NO;_hasSelection=NO;self.tileDragBegan(self,event);return;}
    _selectionStart=_selectionEnd=[self cellForPoint:local];_selecting=YES;_hasSelection=NO;[self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)event {if(_tileDragging){if(self.tileDragMoved)self.tileDragMoved(self,event);return;}if(!_selecting)return;_selectionEnd=[self cellForPoint:[self convertPoint:event.locationInWindow fromView:nil]];_hasSelection=YES;[self setNeedsDisplay:YES];}
- (void)mouseUp:(NSEvent *)event {if(_tileDragging){_tileDragging=NO;if(self.tileDragEnded)self.tileDragEnded(self,event);return;}_selecting=NO;}
- (void)scrollWheel:(NSEvent *)event { NSInteger delta=(NSInteger)llround(event.scrollingDeltaY/3.0); _historyOffset=MAX(0,MIN((NSInteger)_history.count,_historyOffset+delta));[self refreshTextView];[self setNeedsDisplay:YES]; }
- (NSString *)selectedText {
    if(!_hasSelection)return @"";NSInteger a=(NSInteger)_selectionStart.y*(NSInteger)_cols+(NSInteger)_selectionStart.x,b=(NSInteger)_selectionEnd.y*(NSInteger)_cols+(NSInteger)_selectionEnd.x;if(a>b){NSInteger t=a;a=b;b=t;}NSMutableString *s=[NSMutableString string];NSInteger firstRow=a/(NSInteger)_cols,lastRow=b/(NSInteger)_cols;for(NSInteger y=firstRow;y<=lastRow;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:y temporary:&hold];NSInteger x0=y==firstRow?a%(NSInteger)_cols:0,x1=y==lastRow?b%(NSInteger)_cols:(NSInteger)_cols-1;NSMutableString *row=[NSMutableString string];for(NSInteger x=x0;x<=x1;x++)if(!line||!(line[x].flags&TContinuation))[row appendString:[self stringForCodepoint:line?line[x].ch:' ']];while([row hasSuffix:@" "])[row deleteCharactersInRange:NSMakeRange(row.length-1,1)];[s appendString:row];if(y<lastRow)[s appendString:@"\n"];}return s;
}
- (NSString *)visibleText {NSMutableArray *lines=[NSMutableArray array];for(NSUInteger y=0;y<_rows;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:(NSInteger)y temporary:&hold];NSMutableString *row=[NSMutableString string];for(NSUInteger x=0;x<_cols;x++)if(!line||!(line[x].flags&TContinuation))[row appendString:[self stringForCodepoint:line?line[x].ch:' ']];while([row hasSuffix:@" "])[row deleteCharactersInRange:NSMakeRange(row.length-1,1)];[lines addObject:row];}while(lines.count&&[lines.lastObject length]==0)[lines removeLastObject];return [lines componentsJoinedByString:@"\n"];}
- (void)copy:(id)sender {NSString *s=[self selectedText];if(s.length){[NSPasteboard.generalPasteboard clearContents];[NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];}}
- (void)paste:(id)sender { NSString *s=[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];if(!s.length)return;if(_bracketedPaste)[self sendString:[NSString stringWithFormat:@"\033[200~%@\033[201~",s]];else[self sendString:s]; }
- (void)selectAll:(id)sender {_selectionStart=NSMakePoint(0,0);_selectionEnd=NSMakePoint(_cols-1,_rows-1);_hasSelection=YES;[self setNeedsDisplay:YES];}
- (uint32_t)firstScalar:(NSString *)value {if(!value.length)return 0;NSData *data=[value dataUsingEncoding:NSUTF32LittleEndianStringEncoding];uint32_t scalar=0;if(data.length>=4)memcpy(&scalar,data.bytes,4);return scalar;}
- (uint32_t)kittyCodeForKey:(unsigned short)key {
    switch(key){case 53:return 27;case 36:case 76:return 13;case 48:return 9;case 51:return 127;case 114:return 57348;case 117:return 57349;case 123:return 57350;case 124:return 57351;case 126:return 57352;case 125:return 57353;case 116:return 57354;case 121:return 57355;case 115:return 57356;case 119:return 57357;case 122:return 57364;case 120:return 57365;case 99:return 57366;case 118:return 57367;case 96:return 57368;case 97:return 57369;case 98:return 57370;case 100:return 57371;case 101:return 57372;case 109:return 57373;case 103:return 57374;case 111:return 57375;default:return 0;}
}
- (void)keyDown:(NSEvent *)e {
    if(e.modifierFlags&NSEventModifierFlagCommand){[super keyDown:e];return;}
    NSString *s=nil; unsigned short k=e.keyCode;NSEventModifierFlags mods=e.modifierFlags&NSEventModifierFlagDeviceIndependentFlagsMask;NSInteger modifier=1+((mods&NSEventModifierFlagShift)?1:0)+((mods&NSEventModifierFlagOption)?2:0)+((mods&NSEventModifierFlagControl)?4:0);
    if(_kittyKeyboardFlags){uint32_t code=[self kittyCodeForKey:k];if(!code)code=[self firstScalar:e.characters];if(code){[self sendString:[NSString stringWithFormat:@"\033[%u;%ldu",code,(long)modifier]];_hasSelection=NO;[self setNeedsDisplay:YES];return;}}
    if(_modifyOtherKeys>=2&&modifier>1){uint32_t code=[self firstScalar:e.charactersIgnoringModifiers];if(code&&code>=32){[self sendString:[NSString stringWithFormat:@"\033[27;%ld;%u~",(long)modifier,code]];_hasSelection=NO;[self setNeedsDisplay:YES];return;}}
    if(k==36||k==76)s=@"\r";else if(k==51)s=@"\x7f";else if(k==53)s=@"\x1b";else if(k==48)s=(mods&NSEventModifierFlagShift)?@"\x1b[Z":@"\t";
    else if(k==123)s=modifier>1?[NSString stringWithFormat:@"\x1b[1;%ldD",(long)modifier]:@"\x1b[D";else if(k==124)s=modifier>1?[NSString stringWithFormat:@"\x1b[1;%ldC",(long)modifier]:@"\x1b[C";else if(k==125)s=modifier>1?[NSString stringWithFormat:@"\x1b[1;%ldB",(long)modifier]:@"\x1b[B";else if(k==126)s=modifier>1?[NSString stringWithFormat:@"\x1b[1;%ldA",(long)modifier]:@"\x1b[A";
    else if(k==115)s=modifier>1?[NSString stringWithFormat:@"\x1b[1;%ldH",(long)modifier]:@"\x1b[H";else if(k==119)s=modifier>1?[NSString stringWithFormat:@"\x1b[1;%ldF",(long)modifier]:@"\x1b[F";else if(k==116)s=@"\x1b[5~";else if(k==121)s=@"\x1b[6~";else if(k==117)s=@"\x1b[3~";
    else if(k==122)s=@"\x1bOP";else if(k==120)s=@"\x1bOQ";else if(k==99)s=@"\x1bOR";else if(k==118)s=@"\x1bOS";else if(k==96)s=@"\x1b[15~";else if(k==97)s=@"\x1b[17~";else if(k==98)s=@"\x1b[18~";else if(k==100)s=@"\x1b[19~";else if(k==101)s=@"\x1b[20~";else if(k==109)s=@"\x1b[21~";else if(k==103)s=@"\x1b[23~";else if(k==111)s=@"\x1b[24~";
    else if(mods&NSEventModifierFlagControl){NSString *c=e.charactersIgnoringModifiers.lowercaseString;if(c.length){unichar ch=[c characterAtIndex:0];uint8_t b=0;if(ch>='a'&&ch<='z')b=(uint8_t)(ch-'a'+1);else if(ch==' '||ch=='@')b=0;else if(ch=='[')b=27;else if(ch=='\\')b=28;else if(ch==']')b=29;else if(ch=='^')b=30;else if(ch=='_')b=31;else if(ch=='?')b=127;else b=255;if(b!=255){[self sendBytes:&b length:1];return;}}}
    else {s=(mods&NSEventModifierFlagOption)?e.charactersIgnoringModifiers:e.characters;if((mods&NSEventModifierFlagOption)&&s.length)s=[@"\x1b" stringByAppendingString:s];}
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
        if(![self.config isPluginEnabled:name]){TLog(@"plugin %@ disabled",name);continue;}
        NSString *root = [self.directory stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"extension.json"]];
        if (!data) continue;
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *entry = manifest[@"entry"];
        NSString *identifier = manifest[@"id"] ?: name;
        if (!entry.length) continue;
        NSArray *builtIn=TBuiltInCommands(name);if(builtIn.count||[@[@"hyprland-layout",@"hidden-path",@"unicode-rendering",@"osc-integration",@"borderless-window"] containsObject:name]){for(NSDictionary *definition in builtIn){NSMutableDictionary *command=[definition mutableCopy];command[@"extension"]=identifier;[_commands addObject:command];}TLog(@"plugin %@ loaded declaratively without a helper process",name);continue;}
        NSString *path = [root stringByAppendingPathComponent:entry];
        if (![fm isExecutableFileAtPath:path]) continue;

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
                while (YES) {
                    const uint8_t *bytes = pending.bytes;
                    NSUInteger newline = NSNotFound;
                    for (NSUInteger i = 0; i < pending.length; i++) if (bytes[i] == '\n') { newline = i; break; }
                    if (newline == NSNotFound) break;
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
- (instancetype)initWithFrame:(NSRect)frameRect {if((self=[super initWithFrame:frameRect])){self.bordered=NO;self.wantsLayer=YES;self.layer.cornerRadius=8;self.layer.masksToBounds=YES;self.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];self.alignment=NSTextAlignmentCenter;self.focusRingType=NSFocusRingTypeNone;}return self;}
- (void)updateTrackingAreas {[super updateTrackingAreas];if(self.hoverTrackingArea)[self removeTrackingArea:self.hoverTrackingArea];self.hoverTrackingArea=[[NSTrackingArea alloc]initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];[self addTrackingArea:self.hoverTrackingArea];}
- (void)mouseEntered:(NSEvent *)event {self.hovered=YES;[self applyStyleAnimated:YES];}
- (void)mouseExited:(NSEvent *)event {self.hovered=NO;[self applyStyleAnimated:YES];}
- (void)applyStyleAnimated:(BOOL)animated {NSColor *fill=self.selectedTab?[self.config.accent colorWithAlphaComponent:0.22]:(self.hovered?[self.config.selection colorWithAlphaComponent:0.68]:NSColor.clearColor);self.layer.backgroundColor=fill.CGColor;self.contentTintColor=(self.selectedTab||self.hovered)?self.config.foreground:self.config.muted;CGFloat opacity=self.selectedTab?1:(self.hovered?0.94:0.72);if(!animated){self.alphaValue=opacity;return;}[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=0.13/MAX(0.25,self.config.animationSpeed);context.timingFunction=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];self.animator.alphaValue=opacity;} completionHandler:nil];}
@end

@interface TTabRailView : NSView
@property TConfig *config;
@property NSUInteger tabCount;
@end

@implementation TTabRailView
- (BOOL)isFlipped{return YES;}
- (BOOL)isOpaque{return NO;}
- (void)drawRect:(NSRect)dirtyRect {NSRect box=NSInsetRect(self.bounds,0.5,0.5);NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:box xRadius:11 yRadius:11];CGFloat fillAlpha=self.config.blur?0.26:0.96;[[self.config.panel colorWithAlphaComponent:fillAlpha]setFill];[shape fill];if(self.config.hyprlandLayout)return;if(!self.config.blur){[[self.config.muted colorWithAlphaComponent:0.32]setStroke];shape.lineWidth=1;[shape stroke];}if(self.tabCount>1){CGFloat item=(self.bounds.size.height-8)/self.tabCount;[[self.config.muted colorWithAlphaComponent:self.config.blur?0.10:0.17]setStroke];for(NSUInteger i=1;i<self.tabCount;i++){NSBezierPath *line=[NSBezierPath bezierPath];[line moveToPoint:NSMakePoint(9,4+i*item)];[line lineToPoint:NSMakePoint(self.bounds.size.width-9,4+i*item)];line.lineWidth=1;[line stroke];}}}
@end

@interface TTabEdgeView : NSView
@property TConfig *config;
@end

@implementation TTabEdgeView
- (BOOL)isOpaque{return NO;}
- (void)drawRect:(NSRect)dirtyRect {NSBezierPath *arrow=[NSBezierPath bezierPath];CGFloat mid=NSMidY(self.bounds);[arrow moveToPoint:NSMakePoint(2.5,mid-4)];[arrow lineToPoint:NSMakePoint(6.5,mid)];[arrow lineToPoint:NSMakePoint(2.5,mid+4)];arrow.lineWidth=1.5;arrow.lineCapStyle=NSLineCapStyleRound;arrow.lineJoinStyle=NSLineJoinStyleRound;[[self.config.foreground colorWithAlphaComponent:0.58]setStroke];[arrow stroke];}
@end

static void TAnimateCenterReveal(NSView *view,CFTimeInterval duration,CGFloat radius,NSString *key,dispatch_block_t completion) {
    if(!view||NSIsEmptyRect(view.bounds)){if(completion)completion();return;}
    view.wantsLayer=YES;
    CAShapeLayer *mask=[CAShapeLayer layer];mask.frame=view.bounds;mask.fillColor=NSColor.blackColor.CGColor;
    NSRect endRect=view.bounds,startRect=NSMakeRect(NSMidX(endRect)-3,NSMidY(endRect)-3,6,6);
    CGPathRef start=CGPathCreateWithRoundedRect(NSRectToCGRect(startRect),3,3,NULL);
    CGPathRef end=CGPathCreateWithRoundedRect(NSRectToCGRect(endRect),radius,radius,NULL);
    mask.path=end;view.layer.mask=mask;
    CABasicAnimation *reveal=[CABasicAnimation animationWithKeyPath:@"path"];reveal.fromValue=(__bridge id)start;reveal.toValue=(__bridge id)end;reveal.duration=duration;reveal.timingFunction=[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f];[mask addAnimation:reveal forKey:key];
    CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];fade.fromValue=@0.28;fade.toValue=@1;fade.duration=duration*0.72;fade.timingFunction=reveal.timingFunction;[view.layer addAnimation:fade forKey:[key stringByAppendingString:@".fade"]];
    CABasicAnimation *scale=[CABasicAnimation animationWithKeyPath:@"transform.scale"];scale.fromValue=@0.965;scale.toValue=@1;scale.duration=duration;scale.timingFunction=reveal.timingFunction;[view.layer addAnimation:scale forKey:[key stringByAppendingString:@".settle"]];
    CGPathRelease(start);CGPathRelease(end);
    __weak NSView *weakView=view;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((duration+0.02)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{NSView *strongView=weakView;if(strongView.layer.mask==mask)strongView.layer.mask=nil;if(completion)completion();});
}

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
- (void)animateLaunchReveal;
- (BOOL)executeExtensionNamed:(NSString *)name query:(NSString *)query;
@end

@implementation TWindowController { NSString *_cwd; NSView *_root; NSVisualEffectView *_effect; TTabRailView *_tabRail; TTabEdgeView *_tabEdge; NSMutableArray<TTabButton *> *_tabButtons; BOOL _animateTabLayout; BOOL _hyprlandApplied; NSRect _preHyprlandFrame; TTerminalView *_draggingTerminal; NSPoint _dragOffset; TTerminalView *_enteringTerminal; NSTimer *_tabHideTimer; NSTrackingArea *_tabHoverArea; NSRect _tabRailTargetFrame; BOOL _tabRailVisible; BOOL _mouseInTabArea; BOOL _revealRailAfterLayout; }
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions {
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,920,600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){_config=config;_extensions=extensions;_terminals=[NSMutableArray array];_tabButtons=[NSMutableArray array];window.delegate=(id)self;window.title=@"Termatica";window.titleVisibility=NSWindowTitleHidden;window.titlebarAppearsTransparent=YES;window.styleMask|=NSWindowStyleMaskFullSizeContentView;window.minSize=NSMakeSize(480,280);window.tabbingMode=NSWindowTabbingModeDisallowed;window.movableByWindowBackground=NO;[window center];
        _root=[[NSView alloc]initWithFrame:window.contentView.bounds];_root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;window.contentView=_root;
        _tabRail=[[TTabRailView alloc]initWithFrame:NSZeroRect];_tabRail.config=config;_tabRail.wantsLayer=YES;[_root addSubview:_tabRail];
        _tabEdge=[[TTabEdgeView alloc]initWithFrame:NSZeroRect];_tabEdge.config=config;_tabEdge.wantsLayer=YES;_tabEdge.hidden=YES;_tabEdge.alphaValue=0;[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];
        [self applyAppearance];[self addTab];
    }return self;
}
- (BOOL)hasVerticalSplit {for(TTerminalView *terminal in _terminals)if(terminal.verticalSplit)return YES;return NO;}
- (BOOL)usesTiledLayout {return _terminals.count>1&&(self.config.hyprlandLayout||[self hasVerticalSplit]);}
- (CFTimeInterval)animationDuration:(CFTimeInterval)duration {return duration/MAX(0.25,self.config.animationSpeed);}
- (void)updateTerminalTabInsets {for(TTerminalView *terminal in _terminals)if(terminal.leadingOverlayInset!=0){terminal.leadingOverlayInset=0;[terminal resizeGrid];[terminal setNeedsDisplay:YES];}}
- (void)updateTabHoverArea {
    if(_tabHoverArea){[_root removeTrackingArea:_tabHoverArea];_tabHoverArea=nil;}if(_terminals.count<2)return;
    NSRect edge=NSMakeRect(0,NSMaxY(_tabRailTargetFrame)-26,10,26);_tabEdge.frame=edge;NSRect hover=NSUnionRect(_tabRailTargetFrame,edge);hover=NSInsetRect(hover,-6,-6);_tabHoverArea=[[NSTrackingArea alloc]initWithRect:hover options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow owner:self userInfo:nil];[_root addTrackingArea:_tabHoverArea];
}
- (void)scheduleTabRailHide {
    [_tabHideTimer invalidate];_tabHideTimer=nil;if(!self.config.tabAutoHide||!_tabRailVisible||_terminals.count<2)return;__weak typeof(self) weakSelf=self;_tabHideTimer=[NSTimer timerWithTimeInterval:self.config.tabHideDelay repeats:NO block:^(NSTimer *timer){__strong typeof(weakSelf) self=weakSelf;if(self)[self hideTabRail];}];[NSRunLoop.mainRunLoop addTimer:_tabHideTimer forMode:NSRunLoopCommonModes];
}
- (void)revealTabRail {
    if(_terminals.count<2||NSIsEmptyRect(_tabRailTargetFrame))return;[_tabHideTimer invalidate];_tabHideTimer=nil;BOOL wasVisible=_tabRailVisible;_tabRailVisible=YES;[self updateTerminalTabInsets];[_tabRail.layer removeAnimationForKey:@"termatica.rail.fold"];[_tabEdge.layer removeAnimationForKey:@"termatica.edge.reveal"];NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+7;_tabRail.hidden=NO;if(!wasVisible){_tabRail.frame=collapsed;_tabRail.alphaValue=0;if(self.config.tabAnimations){CAKeyframeAnimation *unfold=[CAKeyframeAnimation animationWithKeyPath:@"transform"];unfold.values=@[[NSValue valueWithCATransform3D:CATransform3DConcat(CATransform3DMakeTranslation(-10,0,0),CATransform3DMakeScale(0.78,0.90,1))],[NSValue valueWithCATransform3D:CATransform3DMakeScale(0.97,0.99,1)],[NSValue valueWithCATransform3D:CATransform3DIdentity]];unfold.keyTimes=@[@0,@0.62,@1];unfold.duration=[self animationDuration:0.18];unfold.timingFunctions=@[[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f],[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f]];[_tabRail.layer addAnimation:unfold forKey:@"termatica.rail.unfold"];}}_tabEdge.hidden=NO;CAMediaTimingFunction *settle=[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f];[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=self.config.tabAnimations?[self animationDuration:0.20]:0;context.timingFunction=settle;_tabRail.animator.frame=_tabRailTargetFrame;_tabRail.animator.alphaValue=1;_tabEdge.animator.alphaValue=0;} completionHandler:^{if(self->_tabRailVisible)self->_tabEdge.hidden=YES;}];[self scheduleTabRailHide];
}
- (void)hideTabRail {
    if(!_tabRailVisible||_terminals.count<2)return;if(_mouseInTabArea){[self scheduleTabRailHide];return;}[_tabHideTimer invalidate];_tabHideTimer=nil;_tabRailVisible=NO;NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+7;_tabEdge.hidden=NO;_tabEdge.alphaValue=0;if(self.config.tabAnimations){[_tabRail.layer removeAnimationForKey:@"termatica.rail.unfold"];CAKeyframeAnimation *fold=[CAKeyframeAnimation animationWithKeyPath:@"transform"];fold.values=@[[NSValue valueWithCATransform3D:CATransform3DIdentity],[NSValue valueWithCATransform3D:CATransform3DConcat(CATransform3DMakeTranslation(-3,0,0),CATransform3DMakeScale(0.94,0.98,1))],[NSValue valueWithCATransform3D:CATransform3DConcat(CATransform3DMakeTranslation(-12,0,0),CATransform3DMakeScale(0.72,0.86,1))]];fold.keyTimes=@[@0,@0.34,@1];fold.duration=[self animationDuration:0.20];fold.timingFunctions=@[[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f],[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f]];[_tabRail.layer addAnimation:fold forKey:@"termatica.rail.fold"];CABasicAnimation *edgeReveal=[CABasicAnimation animationWithKeyPath:@"transform.scale"];edgeReveal.fromValue=@0.58;edgeReveal.toValue=@1;edgeReveal.duration=[self animationDuration:0.16];edgeReveal.timingFunction=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];[_tabEdge.layer addAnimation:edgeReveal forKey:@"termatica.edge.reveal"];}CAMediaTimingFunction *settle=[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f];[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=self.config.tabAnimations?[self animationDuration:0.20]:0;context.timingFunction=settle;_tabRail.animator.frame=collapsed;_tabRail.animator.alphaValue=0;_tabEdge.animator.alphaValue=0.68;} completionHandler:^{if(!self->_tabRailVisible){self->_tabRail.hidden=YES;[self updateTerminalTabInsets];}}];
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
- (void)updateEffectMask {
    if(!_effect)return;
    if(![self usesTiledLayout]){_effect.layer.mask=nil;return;}
    CAShapeLayer *mask=[_effect.layer.mask isKindOfClass:CAShapeLayer.class]?(CAShapeLayer *)_effect.layer.mask:[CAShapeLayer layer];
    CGMutablePathRef path=CGPathCreateMutable();
    for(TTerminalView *terminal in _terminals)CGPathAddRoundedRect(path,NULL,NSRectToCGRect(terminal.frame),14,14);
    mask.frame=_effect.bounds;mask.path=path;mask.fillColor=NSColor.blackColor.CGColor;_effect.layer.mask=mask;CGPathRelease(path);
}
- (void)beginDraggingTerminal:(TTerminalView *)terminal event:(NSEvent *)event {
    if(![self usesTiledLayout]||![_terminals containsObject:terminal])return;
    [self focusTerminal:terminal];_draggingTerminal=terminal;
    NSPoint point=[_root convertPoint:event.locationInWindow fromView:nil];_dragOffset=NSMakePoint(point.x-NSMinX(terminal.frame),point.y-NSMinY(terminal.frame));
    terminal.autoresizingMask=NSViewNotSizable;terminal.wantsLayer=NO;[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];
}
- (void)dragTerminal:(TTerminalView *)terminal event:(NSEvent *)event {
    if(terminal!=_draggingTerminal)return;
    NSPoint point=[_root convertPoint:event.locationInWindow fromView:nil];NSRect frame=terminal.frame;
    frame.origin.x=MAX(0,MIN(_root.bounds.size.width-frame.size.width,point.x-_dragOffset.x));frame.origin.y=MAX(0,MIN(_root.bounds.size.height-frame.size.height,point.y-_dragOffset.y));terminal.frame=frame;
    NSArray<NSValue *> *slots=[self hyprlandFrames];NSUInteger nearest=0;CGFloat best=CGFLOAT_MAX;
    for(NSUInteger i=0;i<slots.count;i++){NSRect slot=slots[i].rectValue;CGFloat dx=point.x-NSMidX(slot),dy=point.y-NSMidY(slot),distance=dx*dx+dy*dy;if(distance<best){best=distance;nearest=i;}}
    NSUInteger current=[_terminals indexOfObject:terminal];if(nearest!=current){[_terminals removeObjectAtIndex:current];[_terminals insertObject:terminal atIndex:nearest];[self rebuildTabs];_animateTabLayout=YES;[self layoutTabs];}
    [self updateEffectMask];
}
- (void)endDraggingTerminal:(TTerminalView *)terminal event:(NSEvent *)event {
    if(terminal!=_draggingTerminal)return;terminal.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;_draggingTerminal=nil;_animateTabLayout=YES;[self layoutTabs];[self rebuildTabs];[self focusTerminal:terminal];
}
- (TTerminalView *)newTerminal {
    TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSZeroRect config:self.config];terminal.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;__weak typeof(self) weakSelf=self;__weak TTerminalView *weakTerminal=terminal;terminal.titleChanged=^(NSString *title){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self.window.title=title.length?title:@"Termatica";};terminal.cwdChanged=^(NSString *cwd){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self->_cwd=cwd;};terminal.focused=^{__strong typeof(weakSelf) self=weakSelf;if(self&&weakTerminal)[self focusTerminal:weakTerminal];};terminal.tileDragBegan=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self beginDraggingTerminal:tile event:event];};terminal.tileDragMoved=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self dragTerminal:tile event:event];};terminal.tileDragEnded=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self endDraggingTerminal:tile event:event];};terminal.accessibilityHelp=@"Command-drag, or drag from the top padding, to rearrange this Hyprland terminal.";return terminal;
}
- (void)updateTabSelectionAnimated:(BOOL)animated {NSUInteger active=[_terminals indexOfObject:self.terminal];for(NSUInteger i=0;i<_tabButtons.count;i++){TTabButton *button=_tabButtons[i];BOOL selected=i==active;if(button.selectedTab!=selected){button.selectedTab=selected;[button applyStyleAnimated:animated];}}if(_terminals.count>1)[self revealTabRail];}
- (void)focusTerminal:(TTerminalView *)terminal {if(!terminal||![_terminals containsObject:terminal])return;if(self.terminal!=terminal){self.terminal=terminal;_cwd=[terminal workingDirectory];if([self usesTiledLayout])[self updateTabSelectionAnimated:YES];else{[self rebuildTabs];[self layoutTabs];}}for(TTerminalView *item in _terminals)item.activeTerminal=item==terminal;self.extensions.activeTerminal=terminal;[terminal setNeedsDisplay:YES];[self.window makeFirstResponder:terminal];}
- (void)animateLaunchReveal {
    if(!self.config.tabAnimations)return;
    TAnimateCenterReveal(_root,[self animationDuration:0.30],self.config.topBar?0:14,@"termatica.launch.center",nil);
}
- (void)animateNewTerminal:(TTerminalView *)terminal {
    if(!self.config.tabAnimations)return;CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];
    BOOL tiled=[self usesTiledLayout];__weak TTerminalView *weakTerminal=terminal;TAnimateCenterReveal(terminal,[self animationDuration:tiled?0.22:0.18],tiled?14:0,@"termatica.terminal.center",^{if(!tiled)[weakTerminal releaseAnimationLayer];});
    if(_tabButtons.count>1){TTabButton *button=_tabButtons.lastObject,*previous=_tabButtons[_tabButtons.count-2];CABasicAnimation *move=[CABasicAnimation animationWithKeyPath:@"position"];move.fromValue=[NSValue valueWithPoint:previous.layer.position];move.toValue=[NSValue valueWithPoint:button.layer.position];move.duration=[self animationDuration:0.12];move.timingFunction=ease;[button.layer addAnimation:move forKey:@"termatica.bubble.move"];CABasicAnimation *bubble=[CABasicAnimation animationWithKeyPath:@"transform.scale"];bubble.fromValue=@0.78;bubble.toValue=@1;bubble.duration=[self animationDuration:0.11];bubble.timingFunction=ease;[button.layer addAnimation:bubble forKey:@"termatica.bubble.pop"];}
}
- (void)cancelTileAnimation {_enteringTerminal=nil;}
- (void)addTabWithVerticalSplit:(BOOL)verticalSplit {[self cancelTileAnimation];BOOL animate=_terminals.count>0&&_terminals.count<6,wasTiled=[self usesTiledLayout];TTerminalView *anchor=self.terminal,*terminal=[self newTerminal];terminal.verticalSplit=verticalSplit;terminal.splitAnchor=verticalSplit?anchor:nil;if(verticalSplit&&anchor){NSUInteger index=[_terminals indexOfObject:anchor];[_terminals insertObject:terminal atIndex:index==NSNotFound?_terminals.count:index+1];}else [_terminals addObject:terminal];if(animate&&self.config.tabAnimations&&[self usesTiledLayout])_enteringTerminal=terminal;[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];self.terminal=terminal;self.extensions.activeTerminal=terminal;_animateTabLayout=animate;BOOL changedTiling=wasTiled!=[self usesTiledLayout];if(changedTiling)[self applyAppearance];else{[self rebuildTabs];[self layoutTabs];}[terminal startShell];if(animate)[self animateNewTerminal:terminal];[self focusTerminal:terminal];}
- (void)addTab {[self addTabWithVerticalSplit:NO];}
- (void)addVerticalTab {[self addTabWithVerticalSplit:YES];}
- (void)closeTab {[self cancelTileAnimation];TTerminalView *closing=self.terminal;if(!closing)return;if(_terminals.count<=1){[_terminals removeAllObjects];self.terminal=nil;self.extensions.activeTerminal=nil;[closing stopShellTerminating:YES];[closing removeFromSuperview];TInvalidateSessionSnapshot();[self.window close];return;}BOOL wasTiled=[self usesTiledLayout],animate=_terminals.count<=6;NSUInteger index=[_terminals indexOfObject:closing];for(TTerminalView *item in _terminals)if(item.splitAnchor==closing)item.splitAnchor=closing.splitAnchor;[_terminals removeObjectAtIndex:index];[closing stopShellTerminating:YES];[closing removeFromSuperview];TInvalidateSessionSnapshot();self.terminal=_terminals[MIN(index,_terminals.count-1)];self.extensions.activeTerminal=self.terminal;_animateTabLayout=animate;if(wasTiled!=[self usesTiledLayout])[self applyAppearance];else{[self rebuildTabs];[self layoutTabs];}[self focusTerminal:self.terminal];}
- (void)selectTabButton:(NSButton *)sender {[self selectTabNumber:sender.tag+1];}
- (void)selectTabNumber:(NSInteger)number {
    NSInteger index=number-1;if(index<0||index>=(NSInteger)_terminals.count)return;NSUInteger oldIndex=[_terminals indexOfObject:self.terminal];if((NSUInteger)index==oldIndex){[self focusTerminal:self.terminal];return;}
    TTerminalView *old=self.terminal,*next=_terminals[(NSUInteger)index];self.terminal=next;_cwd=[next workingDirectory];self.extensions.activeTerminal=next;if([self usesTiledLayout]){[self updateTabSelectionAnimated:YES];[self focusTerminal:next];[next setNeedsDisplay:YES];return;}[self rebuildTabs];[self layoutTabs];
    if(self.config.tabAnimations&&![self usesTiledLayout]){old.wantsLayer=next.wantsLayer=YES;CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];old.hidden=NO;next.hidden=NO;CGFloat direction=(NSUInteger)index>oldIndex?1:-1;CABasicAnimation *incoming=[CABasicAnimation animationWithKeyPath:@"transform.translation.x"];incoming.fromValue=@(direction*20);incoming.toValue=@0;incoming.duration=[self animationDuration:0.12];incoming.timingFunction=ease;[next.layer addAnimation:incoming forKey:@"termatica.tab.slide.in"];CABasicAnimation *outgoing=[CABasicAnimation animationWithKeyPath:@"transform.translation.x"];outgoing.fromValue=@0;outgoing.toValue=@(-direction*14);outgoing.duration=[self animationDuration:0.10];outgoing.timingFunction=ease;[old.layer addAnimation:outgoing forKey:@"termatica.tab.slide.out"];CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];fade.fromValue=@1;fade.toValue=@0;fade.duration=[self animationDuration:0.10];fade.timingFunction=ease;[old.layer addAnimation:fade forKey:@"termatica.tab.fade.out"];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self animationDuration:0.13]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{old.hidden=YES;[old releaseAnimationLayer];[next releaseAnimationLayer];});}
    [self focusTerminal:next];[next setNeedsDisplay:YES];
}
- (void)rebuildTabs {
    for(TTabButton *button in _tabButtons)[button removeFromSuperview];[_tabButtons removeAllObjects];_tabRail.tabCount=_terminals.count;
    if(_terminals.count<2){[_tabHideTimer invalidate];_tabHideTimer=nil;_tabRailVisible=NO;_tabRail.hidden=YES;_tabEdge.hidden=YES;TLog(@"tab count %lu, rail unavailable",(unsigned long)_terminals.count);return;}
    _revealRailAfterLayout=YES;NSUInteger active=[_terminals indexOfObject:self.terminal];for(NSUInteger i=0;i<_terminals.count;i++){TTabButton *button=[[TTabButton alloc]initWithFrame:NSZeroRect];button.config=self.config;button.title=[NSString stringWithFormat:@"%lu",(unsigned long)i+1];button.target=self;button.action=@selector(selectTabButton:);button.tag=(NSInteger)i;button.selectedTab=i==active;button.accessibilityLabel=[NSString stringWithFormat:@"Terminal tab %lu",(unsigned long)i+1];[button applyStyleAnimated:NO];[_tabRail addSubview:button];[_tabButtons addObject:button];}[_root addSubview:_tabRail positioned:NSWindowAbove relativeTo:nil];[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];[_tabRail setNeedsDisplay:YES];TLog(@"tab count %lu, rail ready",(unsigned long)_terminals.count);
}
- (void)layoutTabs {
    CGFloat w=_root.bounds.size.width,h=_root.bounds.size.height;BOOL tile=[self usesTiledLayout],animate=_animateTabLayout&&self.config.tabAnimations;NSArray<NSValue *> *slots=tile?[self hyprlandFrames]:@[];CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];
    NSMutableArray<NSValue *> *fromFrames=[NSMutableArray arrayWithCapacity:_terminals.count],*toFrames=[NSMutableArray arrayWithCapacity:_terminals.count];
    for(NSUInteger i=0;i<_terminals.count;i++){
        TTerminalView *terminal=_terminals[i];NSRect target=tile?slots[i].rectValue:NSMakeRect(0,0,w,h),prior=terminal.frame;
        NSRect animationStart=prior;if(tile&&prior.size.width<1){animationStart=NSInsetRect(target,NSWidth(target)*0.06,NSHeight(target)*0.10);if(terminal.splitAnchor){NSUInteger anchorIndex=[_terminals indexOfObject:terminal.splitAnchor];if(anchorIndex!=NSNotFound&&anchorIndex<fromFrames.count){NSRect anchor=fromFrames[anchorIndex].rectValue;animationStart.origin.y=MAX(NSMinY(target),MIN(NSMaxY(target)-NSHeight(animationStart),NSMinY(anchor)-NSHeight(animationStart)*0.24));}}}
        [fromFrames addObject:[NSValue valueWithRect:animationStart]];[toFrames addObject:[NSValue valueWithRect:target]];
        terminal.hidden=tile?NO:terminal!=self.terminal;terminal.leadingOverlayInset=0;terminal.activeTerminal=terminal==self.terminal;terminal.tiledRendering=tile;
        if(terminal!=_draggingTerminal){terminal.frame=target;[terminal resizeGrid];}
        terminal.wantsLayer=tile||animate;terminal.layer.cornerRadius=tile?14:0;terminal.layer.masksToBounds=tile;
        if(tile)TLog(@"tile %lu frame %.0f,%.0f %.0fx%.0f anchor %@",(unsigned long)i+1,target.origin.x,target.origin.y,target.size.width,target.size.height,terminal.splitAnchor?[NSString stringWithFormat:@"%lu",(unsigned long)[_terminals indexOfObject:terminal.splitAnchor]+1]:@"root");
        if(terminal==_draggingTerminal)continue;
        if(animate&&animationStart.size.width>0&&!NSEqualRects(animationStart,target)){CGFloat sx=animationStart.size.width/target.size.width,sy=animationStart.size.height/target.size.height,dx=NSMidX(animationStart)-NSMidX(target),dy=NSMidY(animationStart)-NSMidY(target);CATransform3D from=CATransform3DConcat(CATransform3DMakeTranslation(dx,dy,0),CATransform3DMakeScale(sx,sy,1));CABasicAnimation *snap=[CABasicAnimation animationWithKeyPath:@"transform"];snap.fromValue=[NSValue valueWithCATransform3D:from];snap.toValue=[NSValue valueWithCATransform3D:CATransform3DIdentity];snap.duration=[self animationDuration:0.12];snap.timingFunction=ease;[terminal.layer addAnimation:snap forKey:@"termatica.hypr.snap"];if(terminal==_enteringTerminal){CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];fade.fromValue=@0;fade.toValue=@1;fade.duration=[self animationDuration:0.09];fade.timingFunction=ease;[terminal.layer addAnimation:fade forKey:@"termatica.hypr.fade"];}if(!tile){__weak TTerminalView *weakTerminal=terminal;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self animationDuration:0.14]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[weakTerminal releaseAnimationLayer];});}}
    }
    [self cancelTileAnimation];
    [self updateEffectMask];
    if(_terminals.count<2){_animateTabLayout=NO;[self updateTerminalTabInsets];return;}
    CGFloat topInset=MAX(42,_root.safeAreaInsets.top+8),available=MAX(44,h-topInset-8),itemHeight=MIN(28,floor((available-8)/_terminals.count));itemHeight=MAX(20,itemHeight);CGFloat railWidth=self.config.tabRailWidth,railHeight=8+itemHeight*_terminals.count;_tabRailTargetFrame=NSMakeRect(8,MAX(8,h-topInset-railHeight-6),railWidth,railHeight);for(NSUInteger i=0;i<_tabButtons.count;i++)_tabButtons[i].frame=NSMakeRect(4,4+i*itemHeight,railWidth-8,itemHeight);[self updateTabHoverArea];TLog(@"tab rail frame %.0f,%.0f %.0fx%.0f",_tabRailTargetFrame.origin.x,_tabRailTargetFrame.origin.y,_tabRailTargetFrame.size.width,_tabRailTargetFrame.size.height);BOOL reveal=_revealRailAfterLayout;_revealRailAfterLayout=NO;_animateTabLayout=NO;if(reveal)[self revealTabRail];else if(_tabRailVisible)_tabRail.frame=_tabRailTargetFrame;else{NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+7;_tabRail.frame=collapsed;}[_root addSubview:_tabRail positioned:NSWindowAbove relativeTo:nil];[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];[_tabRail setNeedsDisplay:YES];
}
- (void)windowDidResize:(NSNotification *)notification {[self layoutTabs];}
- (void)windowDidBecomeKey:(NSNotification *)notification {if(self.terminal)[self focusTerminal:self.terminal];}
- (void)routeKeyEvent:(NSEvent *)event {if(self.terminal)[self.terminal keyDown:event];}
- (void)applyAppearance {
    BOOL tiled=[self usesTiledLayout];
    BOOL wantsBlur=self.config.blur&&!self.config.skeleterm&&(!tiled||self.config.hyprlandBlur)&&getenv("TERMATICA_NO_BLUR")==NULL;
    BOOL opaque=self.config.backgroundOpacity>=0.999&&self.config.windowOpacity>=0.999&&!wantsBlur,borderless=!self.config.topBar,transparentFrame=borderless||tiled;
    if(self.config.hyprlandLayout){if(!_hyprlandApplied)_preHyprlandFrame=self.window.frame;NSRect target=NSInsetRect(NSScreen.mainScreen.visibleFrame,self.config.screenInset,self.config.screenInset);if(!NSEqualRects(self.window.frame,target))[self.window setFrame:target display:YES animate:self.config.tabAnimations];_hyprlandApplied=YES;}else if(_hyprlandApplied){if(_preHyprlandFrame.size.width>0)[self.window setFrame:_preHyprlandFrame display:YES animate:self.config.tabAnimations];_hyprlandApplied=NO;}
    NSWindowStyleMask fullscreen=self.window.styleMask&NSWindowStyleMaskFullScreen;self.window.styleMask=fullscreen|NSWindowStyleMaskResizable|(self.config.topBar?(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskFullSizeContentView):NSWindowStyleMaskBorderless);self.window.titleVisibility=NSWindowTitleHidden;self.window.titlebarAppearsTransparent=YES;self.window.titlebarSeparatorStyle=NSTitlebarSeparatorStyleNone;self.window.movableByWindowBackground=NO;self.window.hasShadow=NO;
    _root.wantsLayer=borderless;_root.layer.backgroundColor=NSColor.clearColor.CGColor;_root.layer.cornerRadius=borderless?14:0;_root.layer.masksToBounds=borderless;_root.layer.borderWidth=0;_root.layer.borderColor=nil;
    for(NSUInteger type=NSWindowCloseButton;type<=NSWindowZoomButton;type++)[[self.window standardWindowButton:(NSWindowButton)type] setHidden:borderless];self.window.alphaValue=self.config.windowOpacity;self.window.opaque=transparentFrame?NO:opaque;self.window.backgroundColor=(transparentFrame||!opaque)?NSColor.clearColor:self.config.background;_tabRail.config=self.config;
    if(wantsBlur&&!_effect){_effect=[[NSVisualEffectView alloc]initWithFrame:_root.bounds];_effect.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;_effect.blendingMode=NSVisualEffectBlendingModeBehindWindow;_effect.wantsLayer=YES;[_root addSubview:_effect positioned:NSWindowBelow relativeTo:nil];}else if(!wantsBlur&&_effect){[_effect removeFromSuperview];_effect=nil;}
    _effect.state=wantsBlur?NSVisualEffectStateActive:NSVisualEffectStateInactive;
    if([self.config.blurMaterial isEqual:@"sidebar"])_effect.material=NSVisualEffectMaterialSidebar;else if([self.config.blurMaterial isEqual:@"menu"])_effect.material=NSVisualEffectMaterialMenu;else if([self.config.blurMaterial isEqual:@"popover"])_effect.material=NSVisualEffectMaterialPopover;else if([self.config.blurMaterial isEqual:@"under-window"])_effect.material=NSVisualEffectMaterialUnderWindowBackground;else _effect.material=NSVisualEffectMaterialHUDWindow;
    for(TTerminalView *terminal in _terminals)[terminal setNeedsDisplay:YES];[self rebuildTabs];[self layoutTabs];if(self.terminal)[self focusTerminal:self.terminal];
}
- (void)reloadConfig {[self.config reload];BOOL hiddenPath=[self.config isPluginEnabled:@"hidden-path"];for(TTerminalView *terminal in _terminals){[terminal reloadAppearance];[terminal setHiddenPathEnabled:hiddenPath];}[self applyAppearance];}
- (BOOL)executeExtensionNamed:(NSString *)name query:(NSString *)query {NSString *needle=[name hasPrefix:@"/"]?name:[@"/" stringByAppendingString:name];for(NSDictionary *command in self.extensions.commands){if([command[@"slash"] isEqual:needle]||[command[@"id"] isEqual:name]){NSDictionary *ctx=@{@"query":query?:@"",@"cwd":_cwd?:[self.terminal workingDirectory],@"selection":[self.terminal selectedText]?:@"",@"screen":[self.terminal visibleText]?:@""};[self.extensions executeCommand:command context:ctx terminal:self.terminal];return YES;}}return NO;}
@end
static void TApplyMenuShortcut(NSMenuItem *item,NSString *spec) {if(!spec.length){item.keyEquivalent=@"";item.keyEquivalentModifierMask=0;return;}NSArray<NSString *> *parts=[spec.lowercaseString componentsSeparatedByString:@"+"];NSEventModifierFlags mask=0;NSString *key=parts.lastObject;for(NSString *part in parts){if([part isEqual:@"cmd"]||[part isEqual:@"command"])mask|=NSEventModifierFlagCommand;else if([part isEqual:@"shift"])mask|=NSEventModifierFlagShift;else if([part isEqual:@"option"]||[part isEqual:@"alt"])mask|=NSEventModifierFlagOption;else if([part isEqual:@"control"]||[part isEqual:@"ctrl"])mask|=NSEventModifierFlagControl;}if([key isEqual:@"plus"])key=@"+";else if([key isEqual:@"space"])key=@" ";item.keyEquivalent=key?:@"";item.keyEquivalentModifierMask=mask;}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@interface TAppDelegate : NSObject <NSApplicationDelegate,NSUserNotificationCenterDelegate>
@property TConfig *config;
@property TExtensionHost *extensions;
@property NSMutableArray<TWindowController *> *windows;
- (TWindowController *)active;
@end

@interface TApplication : NSApplication
@end

@implementation TApplication
- (void)sendEvent:(NSEvent *)event {if(event.type==NSEventTypeKeyDown){NSEventModifierFlags mods=event.modifierFlags&NSEventModifierFlagDeviceIndependentFlagsMask,command=NSEventModifierFlagCommand,commandShift=NSEventModifierFlagCommand|NSEventModifierFlagShift,relevant=mods&(NSEventModifierFlagCommand|NSEventModifierFlagShift|NSEventModifierFlagOption|NSEventModifierFlagControl);NSString *key=event.charactersIgnoringModifiers.lowercaseString;if(event.isARepeat&&[key isEqual:@"t"]&&(relevant==command||relevant==commandShift))return;if(relevant==commandShift&&[key isEqual:@"t"]&&[self sendAction:@selector(newVerticalTab:) to:self.delegate from:self])return;if(relevant==command){if([key isEqual:@"t"]&&[self sendAction:@selector(newTab:) to:self.delegate from:self])return;if([key isEqual:@"w"]&&[self sendAction:@selector(closeTab:) to:self.delegate from:self])return;if([key isEqual:@"k"]&&[self sendAction:@selector(clearTerminal:) to:self.delegate from:self])return;if(key.length==1&&[key characterAtIndex:0]>='1'&&[key characterAtIndex:0]<='9'){NSMenuItem *sender=[NSMenuItem new];sender.tag=[key integerValue];if([self sendAction:@selector(selectTab:) to:self.delegate from:sender])return;}}if(!(mods&NSEventModifierFlagCommand)){TWindowController *controller=[(TAppDelegate *)self.delegate active];if(controller&&event.window==controller.window){[controller routeKeyEvent:event];return;}}}[super sendEvent:event];}
@end

@implementation TAppDelegate {int _cliSocket;dispatch_source_t _cliSource;}
- (void)startCLIListener {_cliSocket=socket(AF_UNIX,SOCK_DGRAM,0);if(_cliSocket<0){TLog(@"CLI socket creation failed");return;}NSString *path=TCLISocketPath();unlink(path.fileSystemRepresentation);struct sockaddr_un address={0};address.sun_family=AF_UNIX;strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path));address.sun_len=(uint8_t)(offsetof(struct sockaddr_un,sun_path)+strlen(address.sun_path)+1);if(bind(_cliSocket,(struct sockaddr *)&address,address.sun_len)<0){TLog(@"CLI socket bind failed: %s",strerror(errno));close(_cliSocket);_cliSocket=-1;return;}fcntl(_cliSocket,F_SETFL,O_NONBLOCK);fcntl(_cliSocket,F_SETFD,FD_CLOEXEC);int socketFD=_cliSocket;_cliSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,(uintptr_t)socketFD,0,dispatch_get_main_queue());__weak typeof(self) weakSelf=self;dispatch_source_set_event_handler(_cliSource,^{uint8_t buffer[8192];ssize_t size=0;while((size=recv(socketFD,buffer,sizeof(buffer),0))>0){NSDictionary *request=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buffer length:(NSUInteger)size] options:0 error:nil];if([request isKindOfClass:NSDictionary.class])[weakSelf handleCLIRequest:request];}});dispatch_source_set_cancel_handler(_cliSource,^{close(socketFD);unlink(path.fileSystemRepresentation);});dispatch_resume(_cliSource);TLog(@"CLI socket listening at %@",path);}
- (void)checkForUpdatesOnLaunch {
    if(!self.config.updateCheckOnLaunch||!self.config.updateRepository.length)return;NSString *repository=[self.config.updateRepository copy];dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *error=nil;NSDictionary *release=TLatestRelease(repository,&error);NSString *tag=release[@"tag_name"];if(!tag||TCompareVersions(tag,TCurrentVersion())!=NSOrderedDescending){if(error)TLog(@"launch update check failed: %@",error.localizedDescription);return;}TLog(@"launch update check found %@",tag);dispatch_async(dispatch_get_main_queue(),^{NSUserNotification *notice=[NSUserNotification new];notice.title=[NSString stringWithFormat:@"Termatica %@ is available",tag];notice.informativeText=@"Run “termatica update” to download, verify, and install it.";notice.soundName=NSUserNotificationDefaultSoundName;NSUserNotificationCenter.defaultUserNotificationCenter.delegate=self;[NSUserNotificationCenter.defaultUserNotificationCenter deliverNotification:notice];NSApp.dockTile.badgeLabel=@"UP";TWindowController *controller=[self active];controller.window.title=[NSString stringWithFormat:@"Termatica · %@ available",tag];});});
}
- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification{return YES;}
#pragma clang diagnostic pop
- (void)applicationDidFinishLaunching:(NSNotification *)notification {_cliSocket=-1;TInvalidateSessionSnapshot();_config=[TConfig new];TInstallConfiguredPlugins(_config);[_config reload];_extensions=[TExtensionHost new];_extensions.config=_config;_windows=[NSMutableArray array];[self buildMenu];[self startCLIListener];if(!self.config.skeleterm)[_extensions loadExtensions];TWindowController *controller=[[TWindowController alloc]initWithConfig:self.config extensions:self.extensions];[self.windows addObject:controller];[controller showWindow:nil];controller.window.initialFirstResponder=controller.terminal;[controller.window makeFirstResponder:controller.terminal];dispatch_async(dispatch_get_main_queue(),^{[controller animateLaunchReveal];});[self checkForUpdatesOnLaunch];}
- (void)applicationWillTerminate:(NSNotification *)notification {TInvalidateSessionSnapshot();if(_cliSource){dispatch_source_cancel(_cliSource);_cliSource=nil;}else if(_cliSocket>=0){close(_cliSocket);unlink(TCLISocketPath().fileSystemRepresentation);_cliSocket=-1;}}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
- (void)newWindow:(id)sender {TWindowController *controller=[[TWindowController alloc]initWithConfig:self.config extensions:self.extensions];[self.windows addObject:controller];[controller showWindow:nil];controller.window.initialFirstResponder=controller.terminal;[controller.window makeFirstResponder:controller.terminal];dispatch_async(dispatch_get_main_queue(),^{[controller animateLaunchReveal];});}
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
- (void)openConfig:(id)sender{[[self active].terminal sendString:@"termatica config\n"];}
- (void)reloadAll {NSDictionary *priorBindings=self.config.keybindings;[self.config ensureEditableFile];[self.config reload];TInstallConfiguredPlugins(self.config);[self.config reload];if(![priorBindings isEqualToDictionary:self.config.keybindings])[self buildMenu];if(self.config.skeleterm)[self.extensions unloadExtensions];else[self.extensions loadExtensions];for(TWindowController *window in self.windows)[window reloadConfig];}
- (void)handleCLIRequest:(NSDictionary *)request {NSString *command=request[@"command"];if([command isEqual:@"reload"])[self reloadAll];else if([command isEqual:@"run"]&&![[self active] executeExtensionNamed:request[@"name"] query:request[@"query"]])TLog(@"extension command not found: %@",request[@"name"]);}
- (void)buildMenu {
    NSDictionary *keys=self.config.keybindings;NSMenu *main=[NSMenu new];NSApp.mainMenu=main;
    NSMenuItem *appItem=[NSMenuItem new];[main addItem:appItem];NSMenu *app=[NSMenu new];appItem.submenu=app;[app addItemWithTitle:@"About Termatica" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];[app addItem:NSMenuItem.separatorItem];NSMenuItem *config=[app addItemWithTitle:@"Open Configuration…" action:@selector(openConfig:) keyEquivalent:@""];TApplyMenuShortcut(config,keys[@"openConfig"]);[app addItem:NSMenuItem.separatorItem];[app addItemWithTitle:@"Hide Termatica" action:@selector(hide:) keyEquivalent:@"h"];[app addItemWithTitle:@"Quit Termatica" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *shellItem=[NSMenuItem new];[main addItem:shellItem];NSMenu *shell=[[NSMenu alloc]initWithTitle:@"Shell"];shellItem.submenu=shell;NSMenuItem *newWindow=[shell addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@""];TApplyMenuShortcut(newWindow,keys[@"newWindow"]);NSMenuItem *newTab=[shell addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@""];TApplyMenuShortcut(newTab,keys[@"newTab"]);NSMenuItem *newVerticalTab=[shell addItemWithTitle:@"New Vertical Terminal" action:@selector(newVerticalTab:) keyEquivalent:@""];TApplyMenuShortcut(newVerticalTab,keys[@"newVerticalTab"]);NSMenuItem *closeTab=[shell addItemWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@""];TApplyMenuShortcut(closeTab,keys[@"closeTab"]);[shell addItem:NSMenuItem.separatorItem];NSMenuItem *clear=[shell addItemWithTitle:@"Clear Terminal" action:@selector(clearTerminal:) keyEquivalent:@""];TApplyMenuShortcut(clear,keys[@"clearTerminal"]);NSMenuItem *reload=[shell addItemWithTitle:@"Reload Configuration" action:@selector(reloadConfig:) keyEquivalent:@""];TApplyMenuShortcut(reload,keys[@"reload"]);[shell addItem:NSMenuItem.separatorItem];for(NSInteger i=1;i<=9;i++){NSMenuItem *tab=[shell addItemWithTitle:[NSString stringWithFormat:@"Select Tab %ld",(long)i] action:@selector(selectTab:) keyEquivalent:@""];tab.tag=i;tab.target=self;NSString *name=[NSString stringWithFormat:@"tab%ld",(long)i],*fallback=[NSString stringWithFormat:@"cmd+%ld",(long)i];TApplyMenuShortcut(tab,keys[name]?:fallback);}
    NSMenuItem *editItem=[NSMenuItem new];[main addItem:editItem];NSMenu *edit=[[NSMenu alloc]initWithTitle:@"Edit"];editItem.submenu=edit;NSMenuItem *copy=[edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];TApplyMenuShortcut(copy,keys[@"copy"]);NSMenuItem *paste=[edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];TApplyMenuShortcut(paste,keys[@"paste"]);NSMenuItem *selectAll=[edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@""];TApplyMenuShortcut(selectAll,keys[@"selectAll"]);
    NSMenuItem *viewItem=[NSMenuItem new];[main addItem:viewItem];NSMenu *view=[[NSMenu alloc]initWithTitle:@"View"];viewItem.submenu=view;NSMenuItem *zoomIn=[view addItemWithTitle:@"Increase Text Size" action:@selector(zoomIn:) keyEquivalent:@""];TApplyMenuShortcut(zoomIn,keys[@"zoomIn"]);NSMenuItem *zoomOut=[view addItemWithTitle:@"Decrease Text Size" action:@selector(zoomOut:) keyEquivalent:@""];TApplyMenuShortcut(zoomOut,keys[@"zoomOut"]);NSMenuItem *zoomReset=[view addItemWithTitle:@"Reset Text Size" action:@selector(zoomReset:) keyEquivalent:@""];TApplyMenuShortcut(zoomReset,keys[@"zoomReset"]);
    for(NSMenuItem *item in main.itemArray)for(NSMenuItem *child in item.submenu.itemArray)if(child.action&&child.target==nil&&child.action!=@selector(copy:)&&child.action!=@selector(paste:)&&child.action!=@selector(selectAll:))child.target=self;
}
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TProcessStartedAt = CFAbsoluteTimeGetCurrent();
        NSString *invoked=[NSString stringWithUTF8String:argv[0]].lastPathComponent;
        if(argc==1&&[invoked isEqual:@"termatica"])return TRunCLI(argc,argv);
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
