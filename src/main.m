#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "TerminalCore.h"
#import <QuartzCore/QuartzCore.h>
#import <Carbon/Carbon.h>
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
static NSDictionary *TReadSessionSnapshot(void) {
    NSString *path=TSessionPath();struct stat info={0};if(stat(path.fileSystemRepresentation,&info)<0||!S_ISREG(info.st_mode)||info.st_uid!=getuid()||info.st_size<=0||info.st_size>262144)return nil;
    NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;return [value isKindOfClass:NSDictionary.class]?value:nil;
}
static void TWriteSessionSnapshot(NSArray<NSDictionary *> *windows) {
    NSString *directory=TEnsureDirectory(nil),*path=TSessionPath();NSDictionary *snapshot=@{@"version":@1,@"windows":windows?:@[]};NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];if(!data.length||data.length>262144)return;
    NSString *temporary=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@".session.%u.tmp",arc4random()]];if([data writeToFile:temporary options:NSDataWritingAtomic error:nil]){[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:temporary error:nil];if(rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation)<0)[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];}
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
static NSString *TOSCColor(NSColor *color) {NSColor *c=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace]?:NSColor.whiteColor;return [NSString stringWithFormat:@"rgb:%04x/%04x/%04x",(unsigned)lrint(c.redComponent*65535),(unsigned)lrint(c.greenComponent*65535),(unsigned)lrint(c.blueComponent*65535)];}

static NSArray<NSString *> *TStandardPaletteHex(void) {return @[@"#1B1D23",@"#E06C75",@"#98C379",@"#E5C07B",@"#61AFEF",@"#C678DD",@"#56B6C2",@"#D7DAE0",@"#5C6370",@"#F07178",@"#AAD94C",@"#FFB454",@"#59C2FF",@"#D2A6FF",@"#95E6CB",@"#EEF1F5"];}

@interface TConfig : NSObject
@property NSString *path;
@property NSString *shell;
@property NSArray<NSString *> *shellArguments;
@property NSString *fontName;
@property NSArray<NSString *> *fontFeatures;
@property CGFloat fontSize;
@property CGFloat padding;
@property NSUInteger scrollback;
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
@property BOOL restoreSession;
@property BOOL pasteProtection;
@property NSString *clipboardRead;
@property NSString *clipboardWrite;
@property NSString *bellStyle;
@property BOOL secureKeyboard;
@property BOOL shellIntegration;
- (void)reload;
- (void)ensureEditableFile;
- (NSArray<NSString *> *)installedThemeNames;
- (void)useThemeNamed:(NSString *)name;
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
        @"textColorMode": @"ansi",
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
        @"system": @{@"restoreSession":@YES,@"pasteProtection":@NO,@"secureKeyboard":@YES,@"shellIntegration":@YES,@"clipboardRead":@"ask",@"clipboardWrite":@"allow"},
        @"updates": @{@"checkOnLaunch":@YES,@"repository":@"sebastianmiletic/termatica"},
        @"keybindings": @{@"openConfig":@"cmd+,",@"newWindow":@"cmd+n",@"newTab":@"cmd+t",@"newVerticalTab":@"cmd+shift+t",@"closeTab":@"cmd+w",@"clearTerminal":@"cmd+k",@"searchScrollback":@"cmd+shift+f",@"splitHorizontal":@"cmd+d",@"splitVertical":@"cmd+shift+d",@"nextSplit":@"cmd+]",@"previousSplit":@"cmd+[",@"previousPrompt":@"cmd+shift+p",@"nextPrompt":@"cmd+option+p",@"reload":@"cmd+r",@"copy":@"cmd+c",@"paste":@"cmd+v",@"selectAll":@"cmd+a",@"zoomIn":@"cmd+plus",@"zoomOut":@"cmd+-",@"zoomReset":@"cmd+0"}
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
    self.fontFeatures = [d[@"fontFeatures"] isKindOfClass:NSArray.class] ? d[@"fontFeatures"] : @[];
    self.fontSize = MAX(8, MIN(48, [d[@"fontSize"] doubleValue] ?: 11));
    self.padding = MAX(0, MIN(40, [d[@"padding"] doubleValue]));
    self.scrollback = MAX(100, MIN(100000, [d[@"scrollback"] unsignedIntegerValue] ?: 2000));
    
    NSDictionary *system=[d[@"system"] isKindOfClass:NSDictionary.class]?d[@"system"]:@{};self.restoreSession=system[@"restoreSession"]?[system[@"restoreSession"] boolValue]:YES;self.pasteProtection=system[@"pasteProtection"]?[system[@"pasteProtection"] boolValue]:NO;self.secureKeyboard=system[@"secureKeyboard"]?[system[@"secureKeyboard"] boolValue]:YES;self.shellIntegration=system[@"shellIntegration"]?[system[@"shellIntegration"] boolValue]:YES;self.clipboardRead=[@[@"ask",@"allow",@"deny"] containsObject:system[@"clipboardRead"]]?system[@"clipboardRead"]:@"ask";self.clipboardWrite=[@[@"ask",@"allow",@"deny"] containsObject:system[@"clipboardWrite"]]?system[@"clipboardWrite"]:@"allow";self.bellStyle=[@[@"sound",@"visual",@"both",@"none"] containsObject:system[@"bellStyle"]]?system[@"bellStyle"]:@"sound";
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
- (void)useThemeNamed:(NSString *)name {if(![self themeNamed:name])return;[self ensureEditableFile];NSData *data=[NSData dataWithContentsOfFile:self.path];NSMutableDictionary *d=[NSMutableDictionary dictionary];id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;if([parsed isKindOfClass:NSDictionary.class])[d addEntriesFromDictionary:parsed];d[@"theme"]=name;[d removeObjectForKey:@"profile"];[[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil] writeToFile:self.path atomically:YES];[self reload];}
- (void)ensureEditableFile {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = self.path.stringByDeletingLastPathComponent;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *existingData=[NSData dataWithContentsOfFile:self.path];
    id parsed=existingData?[NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil]:nil;
    NSDictionary *existing=[parsed isKindOfClass:NSDictionary.class]?parsed:@{};
    NSMutableDictionary *normalized=[[self defaults] mutableCopy];
    [normalized addEntriesFromDictionary:existing];
    for(NSString *key in @[@"appearance",@"colors",@"tabs",@"system",@"updates",@"keybindings"]){
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
static NSArray<NSString *> *TOtherConfigProfileNames(TConfig *config){NSString *current=TActiveConfigName(config);return [TConfigProfileNames() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name,NSDictionary *bindings){return ![name isEqual:current];}]];}
static BOOL TValidConfigName(NSString *name){return TSafeIdentifier(name)&&![name isEqual:@"config"]&&![name isEqual:@"session"];}
static NSString *TSaveConfigNamed(NSString *name,TConfig *config){if(!TValidConfigName(name))return @"[ INVALID ] use letters, numbers, dot, dash or underscore";NSMutableDictionary *active=TReadActiveConfig(config);active[@"configName"]=name;NSError *error=nil;if(!TWriteJSONDictionary(active,TConfigProfilePath(name),&error)||!TWriteJSONDictionary(active,config.path,&error))return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not save config"];[config reload];TPostCLICommand(@"reload");return [NSString stringWithFormat:@"[ SAVED + CURRENT ] %@",name];}
static NSString *TUseConfigNamed(NSString *name,TConfig *config){if(!TValidConfigName(name))return @"[ INVALID ] config name";NSData *data=[NSData dataWithContentsOfFile:TConfigProfilePath(name)];id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;if(![value isKindOfClass:NSDictionary.class])return [NSString stringWithFormat:@"[ NOT FOUND ] %@",name];NSMutableDictionary *active=[value mutableCopy];active[@"configName"]=name;NSError *error=nil;if(!TWriteJSONDictionary(active,config.path,&error))return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"could not select config"];[config reload];TPostCLICommand(@"reload");return [NSString stringWithFormat:@"[ CURRENT ] %@",name];}
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
        TSetting(@"Restore workspace",@"system.restoreSession",@"bool",nil,nil,nil,nil),
        TSetting(@"Unsafe paste protection",@"system.pasteProtection",@"bool",nil,nil,nil,nil),TSetting(@"Secure password input",@"system.secureKeyboard",@"bool",nil,nil,nil,nil),TSetting(@"Shell integration",@"system.shellIntegration",@"bool",nil,nil,nil,nil),TSetting(@"Clipboard reads",@"system.clipboardRead",@"option",@[@"ask",@"allow",@"deny"],nil,nil,nil),
        TSetting(@"Clipboard writes",@"system.clipboardWrite",@"option",@[@"ask",@"allow",@"deny"],nil,nil,nil),TSetting(@"Check on launch",@"updates.checkOnLaunch",@"bool",nil,nil,nil,nil),
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
    fputs("\033[2J\033[H\033[38;2;122;162;247m  TERMATICA CONFIG / SETTINGS\n\033[0m",stdout);fprintf(stdout,"\033[38;2;107;114;128m  current  %-24s  file  %s\033[0m\n\n",TActiveConfigName(config).UTF8String,config.path.fileSystemRepresentation);
    NSArray *titles=[sections valueForKey:@"title"],*details=[sections valueForKey:@"detail"];
    for(NSUInteger i=0;i<titles.count;i++){BOOL active=i==selected;fputs(active?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-20.20s  %-48.48s\033[0m\n",active?'>':' ',[titles[i] UTF8String],[details[i] UTF8String]);}
    fputs("\n\033[38;2;107;114;128m  UP/DOWN move   ENTER open   Q config files\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m  %s\033[0m",message.UTF8String);fflush(stdout);
}
static BOOL TReadMenuKey(unsigned char *key,NSInteger *direction) {
    *direction=0;if(read(STDIN_FILENO,key,1)!=1)return NO;if(*key==27){unsigned char sequence[2]={0};if(read(STDIN_FILENO,&sequence[0],1)==1&&read(STDIN_FILENO,&sequence[1],1)==1&&sequence[0]=='['){if(sequence[1]=='A')*key='k';else if(sequence[1]=='B')*key='j';else if(sequence[1]=='C'){*key='l';*direction=1;}else if(sequence[1]=='D'){*key='h';*direction=-1;}}}return YES;
}
static void TDrawConfigFilesHome(NSArray<NSString *> *names,NSUInteger selected,TConfig *config,NSString *message) {
    fputs("\033[2J\033[H\033[38;2;122;162;247m  TERMATICA CONFIG / CONFIG FILES\033[0m\n",stdout);fprintf(stdout,"\033[38;2;107;114;128m  folder  %s\033[0m\n\n",TConfigProfileDirectory().fileSystemRepresentation);
    BOOL current=selected==0;fputs(current?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-8s  %-24.24s  %s\033[0m\n",current?'>':' ',"CURRENT",TActiveConfigName(config).UTF8String,"open config settings");
    for(NSUInteger i=0;i<names.count;i++){BOOL highlighted=selected==i+1;fputs(highlighted?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-8s  %-24.24s  %s\033[0m\n",highlighted?'>':' ',"SAVED",names[i].UTF8String,"make current, then open settings");}
    if(!names.count)fputs("\n\033[38;2;107;114;128m  No saved config files. Press N to create one.\033[0m",stdout);
    fputs("\n\033[38;2;107;114;128m  ENTER settings   N new   R rename   D delete   Q quit\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m  %s\033[0m",message.UTF8String);fflush(stdout);
}
static BOOL TRunConfigFilesPanel(TConfig *config,struct termios original,struct termios raw,NSString **lastMessage) {
    NSUInteger selected=0;NSString *message=*lastMessage;while(!TMenuInterrupted){NSArray *names=TOtherConfigProfileNames(config);NSUInteger count=names.count+1;selected=MIN(selected,count-1);TDrawConfigFilesHome(names,selected,config,message);unsigned char key=0;NSInteger direction=0;if(!TReadMenuKey(&key,&direction))continue;if(key=='q'||key=='Q'){*lastMessage=message;return NO;}if(key=='j'||key=='J')selected=(selected+1)%count;else if(key=='k'||key=='K')selected=(selected+count-1)%count;else if(key=='\r'||key=='\n'){if(selected>0)message=TUseConfigNamed(names[selected-1],config);*lastMessage=message;return YES;}else if(key=='n'||key=='N'){NSString *name=TConfigPrompt(original,raw,@"new config name: ");message=name.length?TSaveConfigNamed(name,config):@"CANCELLED";if([message hasPrefix:@"[ SAVED"]){*lastMessage=message;return YES;}}else if(key=='r'||key=='R'){NSString *oldName=selected?names[selected-1]:TActiveConfigName(config);if(![NSFileManager.defaultManager fileExistsAtPath:TConfigProfilePath(oldName)]){message=@"CURRENT is not a saved config file";continue;}NSString *name=TConfigPrompt(original,raw,[NSString stringWithFormat:@"rename %@ to: ",oldName]);message=name.length?TRenameConfig(oldName,name,config):@"CANCELLED";}else if(key=='d'||key=='D'){NSString *name=selected?names[selected-1]:TActiveConfigName(config);if(![NSFileManager.defaultManager fileExistsAtPath:TConfigProfilePath(name)]){message=@"CURRENT is not a saved config file";continue;}NSString *answer=TConfigPrompt(original,raw,[NSString stringWithFormat:@"delete %@? [y/N]: ",name]);message=[answer.lowercaseString isEqual:@"y"]?TDeleteConfig(name,config):@"CANCELLED";}}
    *lastMessage=message;return NO;
}
static NSString *TRunSettingsPanel(TConfig *config,NSDictionary *section,struct termios original,struct termios raw) {
    NSUInteger selected=0;NSString *message=nil;while(YES){NSArray *rows=section[@"rows"];selected=MIN(selected,rows.count?rows.count-1:0);NSMutableDictionary *dictionary=TReadActiveConfig(config);fputs("\033[2J\033[H",stdout);fprintf(stdout,"\033[38;2;122;162;247m  TERMATICA CONFIG / %s\033[0m\n\n",[section[@"title"] UTF8String]);
        for(NSUInteger i=0;i<rows.count;i++){NSDictionary *row=rows[i];BOOL active=i==selected;NSString *value=TConfigDisplayValue(TConfigValueAtPath(dictionary,row[@"path"]));fputs(active?"\033[48;2;43;52;69m\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %c  %-24.24s  %-43.43s\033[0m\n",active?'>':' ',[row[@"label"] UTF8String],value.UTF8String);}
        fputs("\n\033[38;2;107;114;128m  UP/DOWN move   LEFT/RIGHT change   ENTER edit/toggle   Q back\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m  %s\033[0m",message.UTF8String);fflush(stdout);unsigned char key=0;NSInteger direction=0;if(!TReadMenuKey(&key,&direction))continue;if(key=='q'||key=='Q')return message;if(!rows.count)continue;if(key=='j'||key=='J')selected=(selected+1)%rows.count;else if(key=='k'||key=='K')selected=(selected+rows.count-1)%rows.count;else if(key=='h'||key=='H'||key=='l'||key=='L')TChangeConfigSetting(config,rows[selected],direction?:((key=='l'||key=='L')?1:-1),nil,&message);else if(key=='\r'||key=='\n'){NSDictionary *setting=rows[selected];NSString *type=setting[@"type"];if([type hasPrefix:@"bool"]||[type hasPrefix:@"option"])TChangeConfigSetting(config,setting,1,nil,&message);else{NSString *current=TConfigDisplayValue(TConfigValueAtPath(dictionary,setting[@"path"]));NSString *input=TConfigPrompt(original,raw,[NSString stringWithFormat:@"%@ [%@]: ",setting[@"label"],current]);if(input.length)TChangeConfigSetting(config,setting,1,input,&message);else message=@"UNCHANGED";}}}
}
static int TRunUnifiedConfigCLI(int argc,const char *argv[],TConfig *config) {
    if(argc>=3){NSString *action=[[NSString stringWithUTF8String:argv[2]] lowercaseString];if([action isEqual:@"list"]){fprintf(stdout,"current\t%s\n",TActiveConfigName(config).UTF8String);for(NSString *name in TOtherConfigProfileNames(config))fprintf(stdout,"saved\t%s\n",name.UTF8String);return 0;}if([action isEqual:@"get"]&&argc==4){id value=TConfigValueAtPath(TReadActiveConfig(config),[NSString stringWithUTF8String:argv[3]]);if(!value)return 1;fprintf(stdout,"%s\n",TConfigDisplayValue(value).UTF8String);return 0;}if([action isEqual:@"set"]&&argc>=5){NSString *path=[NSString stringWithUTF8String:argv[3]];NSMutableArray *parts=[NSMutableArray array];for(int i=4;i<argc;i++)[parts addObject:[NSString stringWithUTF8String:argv[i]]];NSString *input=[parts componentsJoinedByString:@" "];NSData *data=[input dataUsingEncoding:NSUTF8StringEncoding];id value=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil]?:input;NSMutableDictionary *dictionary=TReadActiveConfig(config);TConfigSetValueAtPath(dictionary,path,value);NSString *message=nil;if(!TCommitUnifiedConfig(config,dictionary,&message))return 1;fprintf(stdout,"%s\t%s\n",path.UTF8String,TConfigDisplayValue(value).UTF8String);return 0;}NSString *result=nil;if([action isEqual:@"create"]&&argc==4)result=TSaveConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"use"]&&argc==4)result=TUseConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"rename"]&&argc==5)result=TRenameConfig([NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[4]],config);else if([action isEqual:@"delete"]&&argc==4)result=TDeleteConfig([NSString stringWithUTF8String:argv[3]],config);else{fputs("usage: termatica config [list|get PATH|set PATH VALUE|create NAME|use NAME|rename OLD NEW|delete NAME]\n",stderr);return 2;}fprintf(stdout,"%s\n",result.UTF8String);return [result containsString:@"FAILED"]||[result containsString:@"INVALID"]||[result containsString:@"NOT FOUND"]||[result containsString:@"EXISTS"]?1:0;}
    struct termios original;if(!isatty(STDIN_FILENO)||!isatty(STDOUT_FILENO)||tcgetattr(STDIN_FILENO,&original)!=0){fputs("termatica config requires a terminal; use 'termatica config-file' for JSON or config subcommands for scripts.\n",stderr);return 2;}struct termios raw=original;raw.c_lflag&=~(ICANON|ECHO);raw.c_iflag&=~(IXON|ICRNL);raw.c_cc[VMIN]=1;raw.c_cc[VTIME]=0;tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);void(*previous)(int)=signal(SIGINT,TMenuSignal);TMenuInterrupted=0;NSString *message=nil;fputs("\033[?25l",stdout);
    while(!TMenuInterrupted&&TRunConfigFilesPanel(config,original,raw,&message)){NSArray *sections=TUnifiedConfigSections(config);NSUInteger selected=0;BOOL backToFiles=NO;while(!TMenuInterrupted&&!backToFiles){NSUInteger count=sections.count;selected=MIN(selected,count-1);TDrawUnifiedRoot(sections,selected,config,message);unsigned char key=0;NSInteger direction=0;if(!TReadMenuKey(&key,&direction))continue;if(key=='q'||key=='Q')backToFiles=YES;else if(key=='j'||key=='J')selected=(selected+1)%count;else if(key=='k'||key=='K')selected=(selected+count-1)%count;else if(key=='\r'||key=='\n')message=TRunSettingsPanel(config,sections[selected],original,raw);}}
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
    NSString *commands=@"code plugins themes configs install run editor reload config config-path config-dir plugins-dir themes-dir completions help version";
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
    NSString *commands=@"config config-file update reload editor run completions help version c cf u r e x h v",*configActions=@"list get set create use rename delete",*editors=@"vim nvim emacs nano micro hx";
    if([shell isEqual:@"zsh"])return [NSString stringWithFormat:@"#compdef termatica t\nlocal -a commands\ncommands=(%@)\nif (( CURRENT == 2 )); then compadd -- $commands; return; fi\ncase $words[2] in\n  config|c) (( CURRENT == 3 )) && _values 'action' %@ ;;\n  config-file|cf) (( CURRENT == 3 )) && _values 'action' path ;;\n  update|u) (( CURRENT == 3 )) && _values 'action' check ;;\n  editor|e) (( CURRENT == 3 )) && _values 'editor' %@ || _files ;;\n  completions) _values 'shell' zsh bash fish install path ;;\nesac\n",commands,configActions,editors];
    if([shell isEqual:@"bash"])return [NSString stringWithFormat:@"_termatica_complete() {\n  local cur=\"${COMP_WORDS[COMP_CWORD]}\" command=\"${COMP_WORDS[1]}\" words=\"%@\"\n  if (( COMP_CWORD == 1 )); then COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") ); return; fi\n  case \"$command\" in\n    config|c) words=\"%@\" ;;\n    config-file|cf) words=\"path\" ;;\n    update|u) words=\"check\" ;;\n    editor|e) words=\"%@\" ;;\n    completions) words=\"zsh bash fish install path\" ;;\n  esac\n  COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") )\n}\ncomplete -F _termatica_complete termatica t\n",commands,configActions,editors];
    if([shell isEqual:@"fish"])return [NSString stringWithFormat:@"for __termaticacmd in termatica t\ncomplete -c $__termaticacmd -f -n 'not __fish_seen_subcommand_from %@' -a '%@'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from config c' -a '%@'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from config-file cf' -a 'path'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from update u' -a 'check'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from editor e' -a '%@'\ncomplete -c $__termaticacmd -f -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish install path'\nend\n",commands,commands,configActions,editors];
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

static int TRunCLI(int argc, const char *argv[]) {
    NSString *arg=argc>1?[NSString stringWithUTF8String:argv[1]]:@"--help";
    NSDictionary *quick=@{@"c":@"config",@"cf":@"config-file",@"u":@"update",@"r":@"reload",@"e":@"editor",@"x":@"run",@"h":@"help",@"v":@"version"};
    arg=quick[arg]?:arg;
    if([arg isEqual:@"--help"]||[arg isEqual:@"-h"]||[arg isEqual:@"help"]){
        fprintf(stdout,"Termatica %s\n\nUSAGE\n  t <command> [arguments]\n  termatica <command> [arguments]\n\nQUICK\n  t c                Open config files and settings\n  t cf               Open config.json\n  t u [check]        Update or check for an update\n  t r                Reload saved configuration\n  t e <name> ...     Run a terminal editor\n  t x <name> [text]  Run an enabled extension command\n  t h / t v          Help / version\n\nCONFIGURATION\n  config             Open the complete categorized terminal config UI\n  config-file        Open the authoritative config.json\n  config-file path   Print the authoritative config path\n\nUPDATES\n  update             Download, verify, and install the latest GitHub release\n  update check       Check GitHub without installing\n\nTOOLS\n  reload             Reload saved configuration in the running app\n  editor <name> ...  Run Vim, Neovim, Emacs, Nano, Micro, or Helix\n  run <name> [text]  Run an enabled extension command\n  completions        Generate or install shell completions\n\nFLAGS\n  --help             Show this guide\n  --version          Print the version\n",TCurrentVersion().UTF8String);return 0;
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

enum { TBold = 1, TItalic = 2, TUnderline = 4, TInverse = 8, TWide = 16, TContinuation = 32, TCluster = 64 };
enum { TStyleMask = TBold|TItalic|TUnderline|TInverse };
enum { TClusterBase = 0x110000 };

@interface TTerminalView : NSView
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
- (BOOL)startShell;
- (void)stopShellTerminating:(BOOL)terminate;
- (void)drainPendingData;
- (void)consumeData:(NSData *)data;
- (void)putASCIIBytes:(const uint8_t *)bytes length:(NSUInteger)length __attribute__((objc_direct));
- (void)putCodepoint:(uint32_t)codepoint __attribute__((objc_direct));
- (void)handleControl:(uint8_t)control;
- (void)handleEscape:(uint8_t)finalByte;
- (void)executeCSI:(uint8_t)command prefix:(uint8_t)prefix parameters:(const int *)parameters count:(NSUInteger)count;
- (void)finishOSC:(NSString *)osc __attribute__((objc_direct));
- (void)sendString:(NSString *)string;
- (void)scrollByLines:(NSInteger)lines;
- (void)jumpToPromptDirection:(NSInteger)direction;
- (void)routeWheelLines:(NSInteger)lines event:(NSEvent *)event modifierFlags:(NSEventModifierFlags)modifiers;
- (NSString *)functionalKeySequenceForKeyCode:(unsigned short)key modifier:(NSInteger)modifier;
- (BOOL)shouldForwardApplicationMouseWithModifiers:(NSEventModifierFlags)modifiers;
- (void)startDiagnosticInputCapture;
- (NSData *)finishDiagnosticInputCapture;
- (void)reloadAppearance;
- (void)clearTerminal;
- (void)clearScrollbackPreservingPrompt;
- (void)releaseAnimationLayer;
- (NSString *)visibleText;
- (void)setHiddenPathEnabled:(BOOL)enabled;
- (NSString *)workingDirectory;
- (NSDictionary *)diagnosticState;
- (void)renderImage:(CGImageRef)image atRow:(NSUInteger)row col:(NSUInteger)col width:(NSUInteger)w height:(NSUInteger)h scale:(BOOL)scale;
- (void)deleteImageWithID:(NSString *)imageID;
- (void)queryImageWithID:(NSString *)imageID;
- (void)parseSixel:(NSString *)data;
- (void)parseKittyGraphic:(NSString *)data;
- (void)parseIterm2Image:(NSString *)osc;
- (void)searchScrollback;
- (void)closeSearch;
- (void)executeSearch:(id)sender;
- (void)navigateSearch:(NSInteger)direction;
- (void)toggleSearchCase:(id)sender;
- (BOOL)cellInSearchResult:(NSUInteger)x y:(NSUInteger)y;
@end

@implementation TTerminalView {
    int _master;
    pid_t _pid;
    dispatch_source_t _readSource;
    dispatch_queue_t _parseQueue;
    dispatch_queue_t _writeQueue;
    TCell *_cells;
    NSUInteger _rowOffset;
    NSUInteger _cols, _rows, _cursorX, _cursorY, _savedX, _savedY;
    NSUInteger _scrollTop, _scrollBottom;
    NSMutableArray<NSData *> *_history;
    NSUInteger _historyStart;
    TCell *_historyCells;
    TCell *_historyBlankRow;
    NSUInteger _historyCapacity;
    NSUInteger _historyCount;
    NSUInteger _historyCols;
    NSMutableData *_scratchLine;
    NSMutableData *_glyphScratch;
    NSMutableData *_colorScratch;
    NSMutableData *_pendingData;
    NSMutableData *_diagnosticInput;
    NSUInteger _pendingOffset;
    BOOL _drainScheduled;
    BOOL _displayScheduled;
    BOOL _readPaused;
    BOOL _backpressureReported;
    NSInteger _historyOffset;
    NSUInteger _historyGeneration;
    CGFloat _scrollAccumulator;
    NSFont *_font, *_boldFont, *_italicFont;
    CGFloat _cellWidth, _cellHeight;
    uint32_t _currentFG, _currentBG;
    uint8_t _currentFlags;
    TTerminalDecoder *_decoder;
    BOOL _bracketedPaste, _cursorVisible;
    NSMutableDictionary<NSNumber *,NSDictionary *> *_attributeCache;
    NSMutableArray<NSString *> *_graphemes;
    NSMutableDictionary<NSString *,NSNumber *> *_graphemeIDs;
    NSMutableDictionary<NSNumber *,NSString *> *_linksByCell;
    NSString *_currentLink;
    NSMutableArray<NSDictionary *> *_commandMarks;
    NSUInteger _kittyKeyboardFlags;
    NSUInteger _modifyOtherKeys;
    BOOL _alternateScreen;
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
    NSData *_primaryScreen;
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
    BOOL _palette256Valid;
    BOOL _cachedUnicodeRendering;
    BOOL _cachedOscIntegration;
    NSMutableDictionary *_inlineImages;
    NSMutableDictionary *_kittyImageIDs;
    NSMutableString *_kittyGraphicAccumulator;
    NSMutableDictionary *_animatedImages;
    dispatch_source_t _animationTimer;
    BOOL _cursorBlink;
    BOOL _cursorBlinkVisible;
    dispatch_source_t _blinkTimer;
    BOOL _systemReduceMotion;
    NSString *_terminalTitle;
    uint8_t _currentUnderlineStyle;
    uint8_t *_underlineStyles;
    NSString *_lastEmittedChar;
    NSString *_searchString;
    NSMutableArray *_searchResults;
    NSUInteger _searchIndex;
    NSTextField *_searchField;
    BOOL _searchActive;
    BOOL _searchCaseSensitive;
    NSTextField *_searchCounter;
}

- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config {
    if ((self = [super initWithFrame:frame])) {
        _config = config; _master = -1; _pid = -1; _hiddenPathApplied=-1; _history = [NSMutableArray array];_scratchLine=[NSMutableData data];_glyphScratch=[NSMutableData data];_colorScratch=[NSMutableData data];_pendingData=[NSMutableData data];_parseQueue=dispatch_queue_create("com.termatica.core",DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);_writeQueue=dispatch_queue_create("com.termatica.pty-write",DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);_inlineImages=[NSMutableDictionary dictionary];_kittyImageIDs=[NSMutableDictionary dictionary];_kittyGraphicAccumulator=[NSMutableString string];_animatedImages=[NSMutableDictionary dictionary];_searchResults=[NSMutableArray array];
        _decoder=[TTerminalDecoder new];_attributeCache=[NSMutableDictionary dictionary];_graphemes=[NSMutableArray array];_graphemeIDs=[NSMutableDictionary dictionary];_linksByCell=[NSMutableDictionary dictionary];_commandMarks=[NSMutableArray array];_cursorVisible = YES;_autoWrap=YES;
        _currentFG = _currentBG = TDefaultColor;
        self.wantsLayer=YES;
        self.layerContentsRedrawPolicy=NSViewLayerContentsRedrawOnSetNeedsDisplay;
        [self reloadAppearance];
        [self resizeGrid];
        self.accessibilityLabel = @"Terminal";
    }
    return self;
}
- (void)dealloc {
    [self stopShellTerminating:YES];
    free(_cells);
    free(_historyCells);
    free(_historyBlankRow);
    free(_underlineStyles);
    if(_animationTimer){dispatch_source_cancel(_animationTimer);_animationTimer=nil;}
    if(_blinkTimer){dispatch_source_cancel(_blinkTimer);_blinkTimer=nil;}
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)disableSecureKeyboardInput {if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf disableSecureKeyboardInput];});return;}if(_secureInputEnabled){DisableSecureEventInput();_secureInputEnabled=NO;TLog(@"secure keyboard input disabled");}}
- (void)updateSecureKeyboardInput {if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf updateSecureKeyboardInput];});return;}int master=-1;@synchronized(self){master=_master;}struct termios attributes={0};BOOL shouldEnable=self.config.secureKeyboard&&self.window.firstResponder==self&&master>=0&&tcgetattr(master,&attributes)==0&&!(attributes.c_lflag&ECHO);if(shouldEnable&&!_secureInputEnabled){if(EnableSecureEventInput()==noErr){_secureInputEnabled=YES;TLog(@"secure keyboard input enabled while PTY echo is disabled");}}else if(!shouldEnable)[self disableSecureKeyboardInput];}
- (BOOL)becomeFirstResponder {BOOL accepted=[super becomeFirstResponder];if(accepted&&_focusReporting)[self sendString:@"\033[I"];if(accepted)[self updateSecureKeyboardInput];return accepted;}
- (BOOL)resignFirstResponder {if(_focusReporting)[self sendString:@"\033[O"];[self disableSecureKeyboardInput];return [super resignFirstResponder];}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {return YES;}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return self.config.backgroundOpacity >= 0.999 && !self.config.blur; }
- (void)setNeedsDisplay:(BOOL)flag {[super setNeedsDisplay:flag];}
- (void)markDamageX:(NSUInteger)x y:(NSUInteger)y width:(NSUInteger)width height:(NSUInteger)height __attribute__((objc_direct)) {
    if(!width||!height||!_cols||!_rows)return;NSUInteger maxX=MIN(_cols,x+width),maxY=MIN(_rows,y+height);if(x>=maxX||y>=maxY)return;
    if(!_damageValid){_damageValid=YES;_damageMinX=x;_damageMinY=y;_damageMaxX=maxX;_damageMaxY=maxY;}
    else{_damageMinX=MIN(_damageMinX,x);_damageMinY=MIN(_damageMinY,y);_damageMaxX=MAX(_damageMaxX,maxX);_damageMaxY=MAX(_damageMaxY,maxY);}
}
- (void)markAllDamage __attribute__((objc_direct)) {_damageValid=YES;_damageFull=YES;_damageMinX=_damageMinY=0;_damageMaxX=_cols;_damageMaxY=_rows;}
- (NSRect)takeDamageRect __attribute__((objc_direct)) {
    @synchronized(self){if(!_damageValid)return NSZeroRect;NSRect rect;if(_damageFull)rect=self.bounds;else{CGFloat pad=self.config.padding+self.leadingOverlayInset,top=self.config.padding+self.safeAreaInsets.top+self.topContentInset;rect=NSMakeRect(pad+_damageMinX*_cellWidth,top+_damageMinY*_cellHeight,MAX(1,(_damageMaxX-_damageMinX)*_cellWidth),MAX(1,(_damageMaxY-_damageMinY)*_cellHeight));rect=NSIntersectionRect(NSInsetRect(rect,-1,-1),self.bounds);}_damageValid=_damageFull=NO;return rect;}
}
- (void)reloadAppearance {
    @synchronized(self) {
    if(_historyCount>self.config.scrollback){
        NSUInteger drop=_historyCount-self.config.scrollback;
        _historyStart=(_historyStart+drop)%_historyCapacity;_historyCount=self.config.scrollback;
    }
    [_attributeCache removeAllObjects];
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
    CTFontDescriptorRef mainDesc=CTFontCopyFontDescriptor((__bridge CTFontRef)_font);
    if(mainDesc){NSMutableArray *cascade=[NSMutableArray array];
        for(NSString *name in @[@"Apple Color Emoji",@"Apple Symbols",@"Noto Sans CJK SC",@"PingFang SC",@"Hiragino Sans"]){
            CTFontDescriptorRef d=CTFontDescriptorCreateWithNameAndSize((__bridge CFStringRef)name,self.config.fontSize);
            if(d){[cascade addObject:CFBridgingRelease(d)];}
        }
        NSDictionary *cattrs=@{(__bridge NSString *)kCTFontCascadeListAttribute:cascade};
        CTFontDescriptorRef richDesc=CTFontDescriptorCreateCopyWithAttributes(mainDesc,(__bridge CFDictionaryRef)cattrs);
        if(richDesc){CTFontRef richFont=CTFontCreateWithFontDescriptor(richDesc,self.config.fontSize,NULL);
            if(richFont){_font=CFBridgingRelease(richFont);}CFRelease(richDesc);}
        CFRelease(mainDesc);
    }
    _boldFont = [fm convertFont:_font toHaveTrait:NSBoldFontMask] ?: _font;
    NSDictionary *a = @{NSFontAttributeName:_font};
    NSSize size = [@"M" sizeWithAttributes:a];
    _cellWidth = ceil(size.width);
    _cellHeight = ceil(_font.ascender - _font.descender + _font.leading + 2);
    for (NSUInteger i = 0; i < 16; i++) _palette256[i] = i < self.config.palette.count ? TRGB(self.config.palette[i]) : 0;
    const int levels[6] = {0,95,135,175,215,255};
    for (NSUInteger i = 16; i < 232; i++) { NSUInteger q=i-16,r=q/36,g=(q/6)%6,b=q%6; _palette256[i]=((uint32_t)levels[r]<<16)|((uint32_t)levels[g]<<8)|(uint32_t)levels[b]; }
    for (NSUInteger i = 232; i < 256; i++) { int v=8+(i-232)*10; _palette256[i]=((uint32_t)v<<16)|((uint32_t)v<<8)|(uint32_t)v; }
    _palette256Valid = YES;
    [self markAllDamage];
    [self resizeGrid];
    [self refreshTextView];
    [self setNeedsDisplay:YES];
    }
}
- (void)releaseAnimationLayer {if(self.layer.animationKeys.count){__weak TTerminalView *weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[weakSelf releaseAnimationLayer];});return;}[self.layer removeAllAnimations];self.wantsLayer=YES;}
- (TCell)blankCell { return (TCell){ .ch=' ', .fg=TDefaultColor, .bg=TDefaultColor, .flags=0 }; }
- (TCell *)cellsForRow:(NSUInteger)row {return _cells+((_rowOffset+row)%_rows)*_cols;}
- (void)normalizeRows {if(!_rowOffset||!_cells)return;TCell *ordered=malloc(_rows*_cols*sizeof(TCell));for(NSUInteger y=0;y<_rows;y++)memcpy(ordered+y*_cols,[self cellsForRow:y],_cols*sizeof(TCell));free(_cells);_cells=ordered;_rowOffset=0;}
- (void)ensureBlankRow {
    if(_cols==0)return;
    if(_historyBlankRow){TCell blank=[self blankCell];BOOL match=YES;for(NSUInteger i=0;i<_cols;i++){if(_historyBlankRow[i].ch!=blank.ch||_historyBlankRow[i].fg!=blank.fg||_historyBlankRow[i].bg!=blank.bg||_historyBlankRow[i].flags!=blank.flags){match=NO;break;}}if(match)return;}
    free(_historyBlankRow);_historyBlankRow=malloc(_cols*sizeof(TCell));
    if(_historyBlankRow){TCell blank=[self blankCell];for(NSUInteger i=0;i<_cols;i++)_historyBlankRow[i]=blank;}
}
- (void)addHistoryCells:(const TCell *)cells count:(NSUInteger)count __attribute__((objc_direct)) {
    NSUInteger limit=self.config.scrollback;if(!limit){[self ensureBlankRow];return;}
    NSUInteger cols=_cols,len=MIN(count,cols);
    [self ensureBlankRow];
    if(len==0)return;
    _historyGeneration++;
    if(_historyCells==NULL||_historyCapacity<limit||_historyCols!=cols){
        if(_historyCells)free(_historyCells);
        NSUInteger newCap=limit;_historyCapacity=newCap;_historyCols=cols;
        _historyCells=malloc(newCap*cols*sizeof(TCell));_historyBlankRow=malloc(cols*sizeof(TCell));
        if(!_historyCells||!_historyBlankRow){free(_historyCells);free(_historyBlankRow);_historyCells=NULL;_historyBlankRow=NULL;_historyCapacity=0;return;}
        TCell blank=[self blankCell];TCell *b=_historyBlankRow;for(NSUInteger i=0;i<cols;i++)b[i]=blank;
        TCell *c=_historyCells;for(NSUInteger i=0;i<newCap*cols;i++)c[i]=blank;
        _historyCount=0;_historyStart=0;
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
    CGFloat topInset=self.safeAreaInsets.top+self.topContentInset,bottomInset=self.safeAreaInsets.bottom;
    NSUInteger cols = MAX(2, (NSUInteger)floor((self.bounds.size.width - self.config.padding * 2 - self.leadingOverlayInset) / MAX(1, _cellWidth)));
    NSUInteger rows = MAX(2, (NSUInteger)floor((self.bounds.size.height - self.config.padding * 2 - topInset - bottomInset) / MAX(1, _cellHeight)));
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
    _cells = next; _cols = cols; _rows = rows; _rowOffset=0;[_linksByCell removeAllObjects];free(_underlineStyles);_underlineStyles=calloc(cols*rows,sizeof(uint8_t));
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
- (void)setFrameSize:(NSSize)newSize { [super setFrameSize:newSize]; if(newSize.width>100&&newSize.height>80)[self resizeGrid]; }
- (BOOL)startShell {
    if (_pid > 0) return YES;
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
                if(schedule)dispatch_async(self->_parseQueue,^{[self drainPendingData];});
            } else if (n == 0) {TLog(@"shell pty reached EOF");[self stopShellTerminating:NO];}
            else if (errno != EAGAIN) {TLog(@"pty read failed: %s", strerror(errno));[self stopShellTerminating:YES];}
        }
    });
    dispatch_source_set_cancel_handler(source, ^{});
    dispatch_resume(source);
    _hiddenPathDesired=[self.config isPluginEnabled:@"hidden-path"];_hiddenPathApplied=_hiddenPathDesired?1:0;
    return YES;
}
- (void)stopShellTerminating:(BOOL)terminate {[self disableSecureKeyboardInput];dispatch_source_t source=nil;@synchronized(self){source=_readSource;_readSource=nil;if(source&&_readPaused){_readPaused=NO;dispatch_resume(source);}if(terminate){[_pendingData setLength:0];_pendingOffset=0;_drainScheduled=NO;_backpressureReported=NO;}}if(source)dispatch_source_cancel(source);int master=_master;_master=-1;if(master>=0)close(master);pid_t child=_pid;_pid=-1;if(child>0){if(terminate)kill(child,SIGHUP);dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{int status=0;while(waitpid(child,&status,0)<0&&errno==EINTR){}});}}
- (void)drainPendingData {
    NSData *chunk=nil;BOOL more=NO;dispatch_source_t resumeSource=nil;
    @synchronized(self){
        NSUInteger available=_pendingData.length-_pendingOffset,take=MIN((NSUInteger)32768,available);
        if(take)chunk=[NSData dataWithBytes:(const uint8_t *)_pendingData.bytes+_pendingOffset length:take];
        _pendingOffset+=take;
        if(_pendingOffset>=262144&&_pendingOffset*2>=_pendingData.length){[_pendingData replaceBytesInRange:NSMakeRange(0,_pendingOffset) withBytes:NULL length:0];_pendingOffset=0;}
        available=_pendingData.length-_pendingOffset;more=available>0;
        if(_readPaused&&available<=131072&&_readSource){_readPaused=NO;resumeSource=_readSource;}
        if(!more){[_pendingData setLength:0];_pendingOffset=0;_drainScheduled=NO;}
    }
    if(resumeSource)dispatch_resume(resumeSource);
    if(chunk.length)[self consumeData:chunk];
    if(more)dispatch_async(_parseQueue,^{[self drainPendingData];});
}
- (void)sendBytes:(const void *)bytes length:(NSUInteger)length {
    if(!length)return;if(_diagnosticInput){[_diagnosticInput appendBytes:bytes length:length];return;}NSData *payload=[NSData dataWithBytes:bytes length:length];__weak typeof(self) weakSelf=self;
    dispatch_async(_writeQueue,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;const uint8_t *cursor=payload.bytes;NSUInteger remaining=payload.length;while(remaining){int master=-1;@synchronized(self){master=self->_master;}if(master<0){TLog(@"input dropped because PTY is closed");return;}ssize_t written=write(master,cursor,remaining);if(written>0){cursor+=written;remaining-=(NSUInteger)written;continue;}if(written<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){struct pollfd descriptor={.fd=master,.events=POLLOUT};if(poll(&descriptor,1,20)>=0)continue;}if(written<0&&errno==EINTR)continue;TLog(@"PTY input write failed: %s",strerror(errno));return;}});
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
    @synchronized(self) {
    static BOOL reportedFirstShellOutput = NO;
    if (!reportedFirstShellOutput) {
        reportedFirstShellOutput = YES;
        TLog(@"first shell output after %.2f ms", (CFAbsoluteTimeGetCurrent() - TProcessStartedAt) * 1000.0);
    }
    BOOL followOutput=_historyOffset==0;NSUInteger historyGeneration=_historyGeneration,oldCursorX=_cursorX,oldCursorY=_cursorY;
    __unsafe_unretained TTerminalView *terminal=self;
    [_decoder consumeData:data ascii:^(const uint8_t *bytes,NSUInteger length){[terminal putASCIIBytes:bytes length:length];} codepoint:^(uint32_t codepoint){[terminal putCodepoint:codepoint];} control:^(uint8_t control){[terminal handleControl:control];} escape:^(uint8_t finalByte){[terminal handleEscape:finalByte];} csi:^(uint8_t finalByte,uint8_t prefix,const int *parameters,NSUInteger count){[terminal executeCSI:finalByte prefix:prefix parameters:parameters count:count];} osc:^(NSString *value){[terminal finishOSC:value];}];
    if(followOutput)_historyOffset=0;
    else _historyOffset=MIN((NSInteger)_historyCount,_historyOffset+(NSInteger)(_historyGeneration-historyGeneration));
    [self markDamageX:oldCursorX y:oldCursorY width:1 height:1];[self markDamageX:_cursorX y:_cursorY width:1 height:1];
    [self refreshTextView];
    }
}
- (void)putASCIIBytes:(const uint8_t *)bytes length:(NSUInteger)length __attribute__((objc_direct)) {
    BOOL tracksLinks=_cachedOscIntegration;NSUInteger startX=_cursorX,startY=_cursorY;
    for(NSUInteger i=0;i<length;i++){
        if(_cursorX>=_cols){if(_autoWrap){_cursorX=0;[self lineFeed];}else _cursorX=_cols-1;}
        TCell *row=[self cellsForRow:_cursorY];
        [self clearWideCellAtX:_cursorX row:row];
        TCell *cell=row+_cursorX;cell->ch=bytes[i];cell->fg=_currentFG;cell->bg=_currentBG;cell->flags=_currentFlags;if(_currentUnderlineStyle&&_underlineStyles)_underlineStyles[_cursorY*_cols+_cursorX]=_currentUnderlineStyle;
        if(tracksLinks){NSNumber *key=[self linkKeyForX:_cursorX y:_cursorY];if(_currentLink.length)_linksByCell[key]=_currentLink;else[_linksByCell removeObjectForKey:key];}
        _cursorX++;
    }
    if(length){
        NSUInteger endY=_cursorY,endX=_cursorX;
        if(endY==startY){[self markDamageX:startX y:startY width:MAX(1,endX-startX) height:1];}
        else{[self markDamageX:startX y:startY width:_cols-startX height:1];if(endY>startY+1)[self markDamageX:0 y:startY+1 width:_cols height:(endY-(startY+1))];[self markDamageX:0 y:endY width:endX height:1];}
    }
}
- (void)handleControl:(uint8_t)control {
    if(control==7){dispatch_async(dispatch_get_main_queue(),^{NSString *bell=self.config.bellStyle?:@"sound";if([bell containsString:@"sound"])NSBeep();if([bell containsString:@"visual"]){CABasicAnimation *flash=[CABasicAnimation animationWithKeyPath:@"opacity"];flash.fromValue=@0.3;flash.toValue=@1;flash.duration=0.15;[self.layer addAnimation:flash forKey:@"termatica.bell"];}});return;}
    if(control==8){if(_cursorX)_cursorX--;return;}
    if(control==9){_cursorX=MIN(((_cursorX/8)+1)*8,_cols-1);return;}
    if(control==10||control==11||control==12){[self lineFeed];return;}
    if(control==13)_cursorX=0;
}
- (void)handleEscape:(uint8_t)finalByte {
    if(finalByte=='7'){_savedX=_cursorX;_savedY=_cursorY;}
    else if(finalByte=='8'){_cursorX=MIN(_savedX,_cols-1);_cursorY=MIN(_savedY,_rows-1);}
    else if(finalByte=='D')[self lineFeed];
    else if(finalByte=='E'){_cursorX=0;[self lineFeed];}
    else if(finalByte=='M')[self reverseIndex];
    else if(finalByte=='c')[self resetTerminal];
}
static int TCSIParameter(const int *parameters,NSUInteger count,NSUInteger index,int defaultValue){return index<count&&parameters[index]?parameters[index]:defaultValue;}
- (void)executeCSI:(uint8_t)command prefix:(uint8_t)prefix parameters:(const int *)parameters count:(NSUInteger)count {
    int n=TCSIParameter(parameters,count,0,1);
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
            if (top < bottom && bottom < _rows) { _scrollTop = top; _scrollBottom = bottom; _cursorX = _cursorY = 0; }
            break;
        }
        case 'h': case 'l': if(prefix)for(NSUInteger i=0;i<count;i++)[self setPrivateMode:parameters[i] enabled:command=='h'];break;
        case 'P': [self deleteCharacters:n]; break;
        case '@': [self insertCharacters:n]; break;
        case 'X': [self eraseCharacters:n]; break;
        case 'L': [self insertLines:n]; break;
        case 'M': [self deleteLines:n]; break;
        case 'n': if(parameters[0]==6)[self sendString:[NSString stringWithFormat:@"\033[%lu;%luR",_cursorY+1,_cursorX+1]];else if(parameters[0]==5)[self sendString:@"\033[0n"];break;
        case 'b': { NSString *last=_lastEmittedChar;for(int r=0;r<n&&last;r++) [self sendString:last]; break; }
        case 'c': [self sendString:@"\033[?1;2c"]; break;
        default: break;
    }
}
- (void)applySGRParameters:(const int *)parameters count:(NSUInteger)count {
    if(count==1&&parameters[0]==0){_currentFG=_currentBG=TDefaultColor;_currentFlags=0;return;}
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
            else if(parameters[i+1]==2&&i+4<count){color=((parameters[i+2]&255)<<16)|((parameters[i+3]&255)<<8)|(parameters[i+4]&255);i+=4;}
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
    if(_alternateScreen)return;[self normalizeRows];_primaryScreen=[NSData dataWithBytes:_cells length:_cols*_rows*sizeof(TCell)];_primaryCols=_cols;_primaryRows=_rows;_primaryCursorX=_cursorX;_primaryCursorY=_cursorY;_alternateScreen=YES;_historyOffset=0;[self eraseDisplay:2];_cursorX=_cursorY=0;[self markAllDamage];
}
- (void)leaveAlternateScreen {
    if(!_alternateScreen)return;TCell blank=[self blankCell];for(NSUInteger i=0;i<_cols*_rows;i++)_cells[i]=blank;NSUInteger copyRows=MIN(_rows,_primaryRows),copyCols=MIN(_cols,_primaryCols);const TCell *saved=_primaryScreen.bytes;for(NSUInteger y=0;y<copyRows;y++)memcpy(_cells+y*_cols,saved+y*_primaryCols,copyCols*sizeof(TCell));_cursorX=MIN(_primaryCursorX,_cols-1);_cursorY=MIN(_primaryCursorY,_rows-1);_primaryScreen=nil;_alternateScreen=NO;_historyOffset=0;[self markAllDamage];
}
- (void)setPrivateMode:(int)mode enabled:(BOOL)enabled {
    if (mode == 25) _cursorVisible = enabled;
    else if (mode == 2004) _bracketedPaste = enabled;
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
    else if(mode==2026){_synchronizedUpdates=enabled;if(!enabled)[self refreshTextView];}
    else if(mode==12){_cursorBlink=enabled;[self startCursorBlink];}
}
- (uint32_t)internGrapheme:(NSString *)value {
    NSNumber *existing=_graphemeIDs[value];if(existing)return existing.unsignedIntValue;
    if(_graphemes.count>=0xEEFFFF)return 0xFFFD;uint32_t token=(uint32_t)(TClusterBase+_graphemes.count);[_graphemes addObject:value];_graphemeIDs[value]=@(token);return token;
}
- (NSNumber *)linkKeyForX:(NSUInteger)x y:(NSUInteger)y {return @((((_rowOffset+y)%_rows)*_cols)+x);}
- (void)clearWideCellAtX:(NSUInteger)x row:(TCell *)row __attribute__((objc_direct)) {
    if(x>=_cols)return;if(row[x].flags&TWide){if(x+1<_cols)row[x+1]=[self blankCell];}
    else if((row[x].flags&TContinuation)&&x){row[x-1].flags&=~TWide;}
}
- (void)putCodepoint:(uint32_t)cp __attribute__((objc_direct)) {
    if(_cachedUnicodeRendering&&_cursorX){
        TCell *row=[self cellsForRow:_cursorY];NSUInteger baseX=_cursorX-1;if((row[baseX].flags&TContinuation)&&baseX)baseX--;TCell *base=&row[baseX];NSString *existing=[self stringForCodepoint:base->ch],*scalar=[self stringForCodepoint:cp],*candidate=[existing stringByAppendingString:scalar];BOOL joins=TUnicodeCombining(cp)||[existing hasSuffix:@"\u200D"]||(TUnicodeRegional(cp)&&TUnicodeRegional(base->ch));if(!joins&&candidate.length){NSRange cluster=[candidate rangeOfComposedCharacterSequenceAtIndex:candidate.length-1];joins=cluster.location==0&&NSMaxRange(cluster)==candidate.length;}
        if(joins&&base->ch!=' '&&!(base->flags&TContinuation)){base->ch=[self internGrapheme:candidate];base->flags|=TCluster;if((TUnicodeWide(cp)||cp==0xFE0F||cp==0x200D)&&!(base->flags&TWide)&&baseX+1<_cols){base->flags|=TWide;row[baseX+1]=(TCell){.ch=0,.fg=base->fg,.bg=base->bg,.flags=TContinuation};if(_cursorX==baseX+1)_cursorX++;}[self markDamageX:baseX y:_cursorY width:(base->flags&TWide)?2:1 height:1];return;}
    }
    NSUInteger width=_cachedUnicodeRendering&&TUnicodeWide(cp)?2:1;
    if (_cursorX >= _cols||(_cursorX+width>_cols)) {if(_autoWrap){_cursorX = 0; [self lineFeed];}else _cursorX=_cols-width;}
    TCell *row=[self cellsForRow:_cursorY];[self clearWideCellAtX:_cursorX row:row];TCell *c=row+_cursorX;
    c->ch = cp; c->fg = _currentFG; c->bg = _currentBG; c->flags = _currentFlags|(width==2?TWide:0);
    [self markDamageX:_cursorX y:_cursorY width:width height:1];
    if(_cachedOscIntegration){NSNumber *linkKey=[self linkKeyForX:_cursorX y:_cursorY];if(_currentLink.length)_linksByCell[linkKey]=_currentLink;else[_linksByCell removeObjectForKey:linkKey];}
    if(width==2){row[_cursorX+1]=(TCell){.ch=0,.fg=_currentFG,.bg=_currentBG,.flags=TContinuation};if(_cachedOscIntegration){NSNumber *continuation=[self linkKeyForX:_cursorX+1 y:_cursorY];if(_currentLink.length)_linksByCell[continuation]=_currentLink;else[_linksByCell removeObjectForKey:continuation];}}
    _cursorX+=width;
}
- (void)lineFeed __attribute__((objc_direct)) {
    if (_cursorY == _scrollBottom) [self scrollUp];
    else _cursorY = MIN(_rows - 1, _cursorY + 1);
}
- (void)scrollUp __attribute__((objc_direct)) {
    [self markDamageX:0 y:_scrollTop width:_cols height:_scrollBottom-_scrollTop+1];
    if (_scrollTop == 0 && _scrollBottom == _rows - 1) {
        TCell *top=[self cellsForRow:0];NSUInteger used=_cols;TCell blank=[self blankCell];while(used){TCell cell=top[used-1];if(cell.ch!=blank.ch||cell.flags!=blank.flags||cell.fg!=blank.fg||cell.bg!=blank.bg)break;used--;}
        [self addHistoryCells:top count:used];
        _rowOffset=(_rowOffset+1)%_rows;TCell *bottom=[self cellsForRow:_rows-1];NSUInteger physical=(_rowOffset+_rows-1)%_rows;for(NSUInteger x=0;x<_cols;x++){bottom[x]=blank;if(_cachedOscIntegration)[_linksByCell removeObjectForKey:@(physical*_cols+x)];}return;
    }
    [self normalizeRows];
    memmove(_cells + _scrollTop * _cols, _cells + (_scrollTop + 1) * _cols, (_scrollBottom - _scrollTop) * _cols * sizeof(TCell));
    TCell blank = [self blankCell];
    for (NSUInteger x=0; x<_cols; x++) _cells[_scrollBottom*_cols+x]=blank;
}
- (void)reverseIndex {
    [self markDamageX:0 y:_scrollTop width:_cols height:_scrollBottom-_scrollTop+1];
    if (_cursorY > _scrollTop) { _cursorY--; return; }
    if(_scrollTop==0&&_scrollBottom==_rows-1){_rowOffset=(_rowOffset+_rows-1)%_rows;TCell blank=[self blankCell],*top=[self cellsForRow:0];NSUInteger physical=_rowOffset;for(NSUInteger x=0;x<_cols;x++){top[x]=blank;if(_cachedOscIntegration)[_linksByCell removeObjectForKey:@(physical*_cols+x)];}return;}
    [self normalizeRows];
    memmove(_cells + (_scrollTop + 1) * _cols, _cells + _scrollTop * _cols, (_scrollBottom - _scrollTop) * _cols * sizeof(TCell));
    TCell blank=[self blankCell]; for(NSUInteger x=0;x<_cols;x++) _cells[_scrollTop*_cols+x]=blank;
}
- (void)eraseDisplay:(int)mode {
    TCell blank=[self blankCell];
    if (mode==2 || mode==3) { for(NSUInteger i=0;i<_cols*_rows;i++) _cells[i]=blank;_rowOffset=0;if(mode==3)[self clearHistory];[self markAllDamage]; }
    else if(mode==0){for(NSUInteger y=_cursorY;y<_rows;y++){TCell *row=[self cellsForRow:y];NSUInteger start=y==_cursorY?_cursorX:0;for(NSUInteger x=start;x<_cols;x++)row[x]=blank;}[self markDamageX:0 y:_cursorY width:_cols height:_rows-_cursorY];}
    else if(mode==1){for(NSUInteger y=0;y<=_cursorY&&y<_rows;y++){TCell *row=[self cellsForRow:y];NSUInteger end=y==_cursorY?MIN(_cols,_cursorX+1):_cols;for(NSUInteger x=0;x<end;x++)row[x]=blank;}[self markDamageX:0 y:0 width:_cols height:MIN(_rows,_cursorY+1)];}
}
- (void)eraseLine:(int)mode {
    TCell blank=[self blankCell]; NSUInteger a=0,b=_cols;
    if(mode==0)a=_cursorX; else if(mode==1)b=MIN(_cols,_cursorX+1);
    TCell *row=[self cellsForRow:_cursorY];for(NSUInteger x=a;x<b;x++)row[x]=blank;[self markDamageX:a y:_cursorY width:b-a height:1];
}
- (void)eraseCharacters:(int)n { TCell b=[self blankCell],*row=[self cellsForRow:_cursorY];NSUInteger end=MIN(_cols,_cursorX+(NSUInteger)n);for(NSUInteger x=_cursorX;x<end;x++)row[x]=b;[self markDamageX:_cursorX y:_cursorY width:end-_cursorX height:1]; }
- (void)deleteCharacters:(int)n { NSUInteger count=MIN((NSUInteger)n,_cols-_cursorX);TCell b=[self blankCell],*row=[self cellsForRow:_cursorY];memmove(row+_cursorX,row+_cursorX+count,(_cols-_cursorX-count)*sizeof(TCell));for(NSUInteger x=_cols-count;x<_cols;x++)row[x]=b;[self markDamageX:_cursorX y:_cursorY width:_cols-_cursorX height:1]; }
- (void)insertCharacters:(int)n { NSUInteger count=MIN((NSUInteger)n,_cols-_cursorX);TCell b=[self blankCell],*row=[self cellsForRow:_cursorY];memmove(row+_cursorX+count,row+_cursorX,(_cols-_cursorX-count)*sizeof(TCell));for(NSUInteger x=_cursorX;x<_cursorX+count;x++)row[x]=b;[self markDamageX:_cursorX y:_cursorY width:_cols-_cursorX height:1]; }
- (void)insertLines:(int)n { if(_cursorY<_scrollTop||_cursorY>_scrollBottom)return;[self normalizeRows];NSUInteger count=MIN((NSUInteger)n,_scrollBottom-_cursorY+1);memmove(_cells+(_cursorY+count)*_cols,_cells+_cursorY*_cols,(_scrollBottom-_cursorY+1-count)*_cols*sizeof(TCell));TCell b=[self blankCell];for(NSUInteger i=_cursorY*_cols;i<(_cursorY+count)*_cols;i++)_cells[i]=b;[self markDamageX:0 y:_cursorY width:_cols height:_scrollBottom-_cursorY+1]; }
- (void)deleteLines:(int)n { if(_cursorY<_scrollTop||_cursorY>_scrollBottom)return;[self normalizeRows];NSUInteger count=MIN((NSUInteger)n,_scrollBottom-_cursorY+1);memmove(_cells+_cursorY*_cols,_cells+(_cursorY+count)*_cols,(_scrollBottom-_cursorY+1-count)*_cols*sizeof(TCell));TCell b=[self blankCell];for(NSUInteger i=(_scrollBottom-count+1)*_cols;i<=_scrollBottom*_cols+_cols-1;i++)_cells[i]=b;[self markDamageX:0 y:_cursorY width:_cols height:_scrollBottom-_cursorY+1]; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)finishOSC:(NSString *)osc __attribute__((objc_direct)) {
    if([osc hasPrefix:@"bsu"]||[osc hasPrefix:@"esu"]){_synchronizedUpdates=[osc hasPrefix:@"esu"];[self refreshTextView];[self setNeedsDisplay:YES];return;}
    if([osc hasPrefix:@"1337;File="]){[self parseIterm2Image:osc];return;}
    if(osc.length>0&&[osc characterAtIndex:0]=='G'){[self parseKittyGraphic:osc];return;}
    NSArray *parts=[osc componentsSeparatedByString:@";"];
    if(parts.count>1 && ([parts[0] isEqualToString:@"0"]||[parts[0] isEqualToString:@"2"])) {
        NSString *title=[[parts subarrayWithRange:NSMakeRange(1,parts.count-1)] componentsJoinedByString:@";"];
        if(self.titleChanged){void(^changed)(NSString *)=[self.titleChanged copy];dispatch_async(dispatch_get_main_queue(),^{changed(title);});}
    } else if (self.config.oscIntegration&&[osc hasPrefix:@"7;file://"]) {
        NSString *urlString=[osc substringFromIndex:2]; NSURL *url=[NSURL URLWithString:urlString];
        if(url.path.length&&self.cwdChanged){void(^changed)(NSString *)=[self.cwdChanged copy];NSString *path=url.path;dispatch_async(dispatch_get_main_queue(),^{changed(path);});}
    } else if(self.config.oscIntegration&&[osc hasPrefix:@"8;"]){
        NSRange first=[osc rangeOfString:@";"],second=first.location==NSNotFound?NSMakeRange(NSNotFound,0):[osc rangeOfString:@";" options:0 range:NSMakeRange(NSMaxRange(first),osc.length-NSMaxRange(first))];NSString *url=second.location==NSNotFound?@"":[osc substringFromIndex:NSMaxRange(second)];_currentLink=url.length?url:nil;
    } else if(self.config.oscIntegration&&[osc hasPrefix:@"133;"]){
        NSString *mark=parts.count>1?parts[1]:@"";NSMutableDictionary *entry=[@{@"mark":mark,@"row":@(_historyCount+_cursorY)} mutableCopy];if([mark isEqual:@"D"]&&parts.count>2)entry[@"status"]=parts[2];[_commandMarks addObject:entry];if(_commandMarks.count>2048)[_commandMarks removeObjectsInRange:NSMakeRange(0,_commandMarks.count-2048)];
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
- (void)resetTerminal { [_decoder reset];_currentFG=_currentBG=TDefaultColor; _currentFlags=0; _cursorX=_cursorY=0;_scrollTop=0;_scrollBottom=_rows-1;_kittyKeyboardFlags=0;_modifyOtherKeys=0;_applicationCursorKeys=NO;_autoWrap=YES;_alternateScroll=NO;_focusReporting=NO;_mouseTrackingMode=0;_utf8Mouse=NO;_sgrMouse=NO;_urxvtMouse=NO;_pixelMouse=NO;_synchronizedUpdates=NO;_currentLink=nil;[_commandMarks removeAllObjects];[_linksByCell removeAllObjects];if(_alternateScreen)[self leaveAlternateScreen];[self eraseDisplay:2]; }
- (void)clearTerminal { [self eraseDisplay:2]; _cursorX=_cursorY=0; [self clearHistory]; [self refreshTextView];[self setNeedsDisplay:YES]; }
- (void)clearScrollbackPreservingPrompt {
    [self clearHistory];_historyOffset=0;_hasSelection=NO;
    uint8_t formFeed=0x0C;[self sendBytes:&formFeed length:1];
    [self refreshTextView];[self setNeedsDisplay:YES];
}

- (const TCell *)lineAtVisibleIndex:(NSInteger)index temporary:(NSData **)temporary {
    NSInteger totalHistory=(NSInteger)_historyCount;
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
    if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf refreshTextView];});return;}
    if(_synchronizedUpdates||_displayScheduled||self.hidden)return;_displayScheduled=YES;__weak typeof(self) weakSelf=self;uint64_t delay=self.activeTerminal?8:16;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;self->_displayScheduled=NO;NSRect damage=[self takeDamageRect];if(!NSIsEmptyRect(damage))[self setNeedsDisplayInRect:damage];[self updateSecureKeyboardInput];if(NSWorkspace.sharedWorkspace.isVoiceOverEnabled&&!self->_accessibilityUpdatePending){self->_accessibilityUpdatePending=YES;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;self.accessibilityValue=[self visibleText];self->_accessibilityUpdatePending=NO;});}});
}
- (NSDictionary *)textAttributesForForeground:(uint32_t)foreground flags:(uint8_t)flags shadow:(NSShadow *)shadow underlineStyle:(uint8_t)underlineStyle {NSNumber *key=@((foreground<<16)|(flags<<8)|underlineStyle);NSDictionary *cached=_attributeCache[key];if(cached)return cached;NSFont *font=(flags&TBold)?_boldFont:((flags&TItalic)?_italicFont:_font);CGFloat glyphAdvance=[@"M" sizeWithAttributes:@{NSFontAttributeName:font}].width,cellKern=_cellWidth-glyphAdvance;NSMutableDictionary *attrs=[@{NSFontAttributeName:font,NSForegroundColorAttributeName:TColor(foreground),NSKernAttributeName:@(cellKern),NSLigatureAttributeName:@1} mutableCopy];if(shadow)attrs[NSShadowAttributeName]=shadow;if(flags&TUnderline){NSInteger style=NSUnderlineStyleSingle;if(underlineStyle==2)style=NSUnderlineStyleThick;else if(underlineStyle==3)style=NSUnderlineStyleSingle|NSUnderlinePatternDash;else if(underlineStyle==4)style=NSUnderlineStyleSingle|NSUnderlinePatternDot;else if(underlineStyle==5)style=NSUnderlineStyleSingle|NSUnderlinePatternDashDot;attrs[NSUnderlineStyleAttributeName]=@(style);}if(_attributeCache.count>=1024){NSEnumerator *e=[_attributeCache keyEnumerator];NSNumber *evict=[e nextObject];if(evict)[_attributeCache removeObjectForKey:evict];}_attributeCache[key]=attrs;return attrs;}
- (NSDictionary *)textAttributesForForeground:(uint32_t)foreground flags:(uint8_t)flags shadow:(NSShadow *)shadow {return [self textAttributesForForeground:foreground flags:flags shadow:shadow underlineStyle:0];}
- (void)drawRect:(NSRect)dirtyRect {
    @synchronized(self) {
    [self.config.background setFill];NSRectFill(dirtyRect);CGFloat pad=self.config.padding+self.leadingOverlayInset,top=self.config.padding+self.safeAreaInsets.top+self.topContentInset;NSShadow *phosphor=nil;if(self.config.glow>0){phosphor=[NSShadow new];phosphor.shadowColor=[self.config.accent colorWithAlphaComponent:self.config.glow];phosphor.shadowBlurRadius=1+self.config.glow*3;phosphor.shadowOffset=NSZeroSize;}
    NSInteger firstRow=MAX(0,(NSInteger)floor((NSMinY(dirtyRect)-top)/MAX(1,_cellHeight))),lastRow=MIN((NSInteger)_rows,(NSInteger)ceil((NSMaxY(dirtyRect)-top)/MAX(1,_cellHeight)));NSInteger firstColumn=MAX(0,(NSInteger)floor((NSMinX(dirtyRect)-pad)/MAX(1,_cellWidth))),lastColumn=MIN((NSInteger)_cols,(NSInteger)ceil((NSMaxX(dirtyRect)-pad)/MAX(1,_cellWidth)));if(lastRow<firstRow)lastRow=firstRow;if(lastColumn<firstColumn)lastColumn=firstColumn;
    uint32_t defaultForeground=TRGB(self.config.foreground),defaultBackground=TRGB(self.config.background),plainRGB[8]={0};NSUInteger plainCount=self.config.colorizePlainText?MIN((NSUInteger)8,self.config.plainTextPalette.count):0;for(NSUInteger i=0;i<plainCount;i++)plainRGB[i]=TRGB(self.config.plainTextPalette[i]);[_glyphScratch setLength:MAX((NSUInteger)1,_cols*2)*sizeof(unichar)];[_colorScratch setLength:MAX((NSUInteger)1,_cols)*sizeof(uint32_t)];unichar *glyphs=_glyphScratch.mutableBytes;uint32_t *plainForegrounds=_colorScratch.mutableBytes;
    for(NSInteger y=firstRow;y<lastRow;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:y temporary:&hold];if(!line)continue;
        BOOL inPlainToken=NO;NSUInteger plainToken=0;for(NSUInteger column=0;column<_cols;column++){uint32_t codepoint=line[column].ch;BOOL whitespace=!codepoint||codepoint==' '||codepoint=='\t';if(whitespace)inPlainToken=NO;else if(!inPlainToken){inPlainToken=YES;plainToken++;}plainForegrounds[column]=plainCount&&!whitespace?plainRGB[(plainToken-1)%plainCount]:defaultForeground;}
        NSInteger x=firstColumn;while(x<lastColumn){TCell c=line[x];BOOL selected=[self cellSelectedX:(NSUInteger)x y:(NSUInteger)y],inSearch=[self cellInSearchResult:(NSUInteger)x y:(NSUInteger)y],inverse=(c.flags&TInverse)!=0;uint32_t background=c.bg==TDefaultColor?defaultBackground:c.bg,foreground=c.fg==TDefaultColor?defaultForeground:c.fg;if(inverse){uint32_t swap=foreground;foreground=background;background=swap;}if(inSearch){background=TRGB(self.config.accent);foreground=TRGB(self.config.background);}NSInteger kind=selected?1:(inSearch?3:((c.bg!=TDefaultColor||inverse)?2:0)),start=x;x++;while(x<lastColumn){TCell next=line[x];BOOL nextSelected=[self cellSelectedX:(NSUInteger)x y:(NSUInteger)y],nextInSearch=[self cellInSearchResult:(NSUInteger)x y:(NSUInteger)y],nextInverse=(next.flags&TInverse)!=0;uint32_t nextBackground=next.bg==TDefaultColor?defaultBackground:next.bg,nextForeground=next.fg==TDefaultColor?defaultForeground:next.fg;if(nextInverse){uint32_t swap=nextForeground;nextForeground=nextBackground;nextBackground=swap;}if(nextInSearch){nextBackground=TRGB(self.config.accent);nextForeground=TRGB(self.config.background);}NSInteger nextKind=nextSelected?1:(nextInSearch?3:((next.bg!=TDefaultColor||nextInverse)?2:0));if(nextKind!=kind||(kind==2&&nextBackground!=background))break;x++;}if(kind){[(kind==1?self.config.selection:(kind==3?self.config.accent:TColor(background))) setFill];NSRectFill(NSMakeRect(pad+start*_cellWidth,top+y*_cellHeight,(x-start)*_cellWidth,_cellHeight));}}
        x=firstColumn;while(x<lastColumn){TCell c=line[x];if(c.flags&TContinuation){x++;continue;}uint32_t foreground=c.fg==TDefaultColor&&!(c.flags&TInverse)?plainForegrounds[x]:(c.fg==TDefaultColor?defaultForeground:c.fg),background=c.bg==TDefaultColor?defaultBackground:c.bg;if(c.flags&TInverse){uint32_t swap=foreground;foreground=background;background=swap;}BOOL linked=_historyOffset==0&&_linksByCell[[self linkKeyForX:(NSUInteger)x y:(NSUInteger)y]]!=nil;uint8_t flags=(c.flags&TStyleMask)|(linked?TUnderline:0);uint8_t ulStyle=(_underlineStyles&&y<(NSInteger)_rows&&x<(NSInteger)_cols)?_underlineStyles[y*_cols+x]:0;if(c.flags&(TWide|TCluster)){NSString *text=[self stringForCodepoint:c.ch];NSMutableDictionary *attrs=[[self textAttributesForForeground:foreground flags:flags shadow:phosphor underlineStyle:ulStyle] mutableCopy];[attrs removeObjectForKey:NSKernAttributeName];[text drawAtPoint:NSMakePoint(pad+x*_cellWidth,top+y*_cellHeight) withAttributes:attrs];x+=(c.flags&TWide)?2:1;continue;}NSInteger start=x;NSUInteger length=0;BOOL hasGlyph=NO;while(x<lastColumn){TCell next=line[x];if(next.flags&(TWide|TCluster|TContinuation))break;uint32_t nextForeground=next.fg==TDefaultColor&&!(next.flags&TInverse)?plainForegrounds[x]:(next.fg==TDefaultColor?defaultForeground:next.fg),nextBackground=next.bg==TDefaultColor?defaultBackground:next.bg;if(next.flags&TInverse){uint32_t swap=nextForeground;nextForeground=nextBackground;nextBackground=swap;}BOOL nextLinked=_historyOffset==0&&_linksByCell[[self linkKeyForX:(NSUInteger)x y:(NSUInteger)y]]!=nil;uint8_t nextFlags=(next.flags&TStyleMask)|(nextLinked?TUnderline:0);if(nextForeground!=foreground||nextFlags!=flags)break;uint32_t codepoint=next.ch?:' ';if(codepoint!=' ')hasGlyph=YES;length=TAppendUTF16(glyphs,length,codepoint);x++;}if(hasGlyph&&length){NSString *text=[[NSString alloc]initWithCharacters:glyphs length:length];[text drawAtPoint:NSMakePoint(pad+start*_cellWidth,top+y*_cellHeight) withAttributes:[self textAttributesForForeground:foreground flags:flags shadow:phosphor underlineStyle:ulStyle]];}}
    }
    if(_cursorVisible&&_historyOffset==0&&(_cursorBlink?_cursorBlinkVisible:YES)&&(self.window.firstResponder==self||self.activeTerminal)){BOOL block=![self.config.cursorStyle isEqual:@"bar"]&&![self.config.cursorStyle isEqual:@"underline"];BOOL focused=self.window.firstResponder==self||self.activeTerminal;[[self.config.cursor colorWithAlphaComponent:focused?(block?0.42:0.96):(block?0.2:0.5)]setFill];NSRect r=NSMakeRect(pad+_cursorX*_cellWidth,top+_cursorY*_cellHeight,_cellWidth,_cellHeight);if([self.config.cursorStyle isEqual:@"bar"])r.size.width=2;else if([self.config.cursorStyle isEqual:@"underline"]){r.origin.y+=_cellHeight-2;r.size.height=2;}NSRectFillUsingOperation(r,NSCompositingOperationSourceOver);}
    if(_inlineImages.count){for(NSNumber *key in _inlineImages){NSUInteger v=key.unsignedIntegerValue;NSUInteger row=v>>16,col=v&0xFFFF;CGImageRef img=(__bridge CGImageRef)_inlineImages[key];if(img){NSRect imgRect=NSMakeRect(pad+col*_cellWidth,top+row*_cellHeight,CGImageGetWidth(img),CGImageGetHeight(img));if(NSIntersectsRect(imgRect,dirtyRect)){NSGraphicsContext *gc=NSGraphicsContext.currentContext;CGContextRef ctx=[gc CGContext];CGContextSaveGState(ctx);CGContextDrawImage(ctx,NSRectToCGRect(imgRect),img);CGContextRestoreGState(ctx);}}}}
    if(self.config.scanlines>0){[[NSColor colorWithWhite:0 alpha:self.config.scanlines*0.10]setFill];CGFloat start=MAX(2,floor(NSMinY(dirtyRect)/4)*4);for(CGFloat y=start;y<NSMaxY(dirtyRect);y+=4)NSRectFillUsingOperation(NSMakeRect(NSMinX(dirtyRect),y,NSWidth(dirtyRect),1),NSCompositingOperationSourceOver);}
    if(self.config.vignette>0&&!self.tiledRendering){for(NSUInteger i=0;i<6;i++){[[NSColor colorWithWhite:0 alpha:self.config.vignette*(6-i)/30.0]setStroke];NSBezierPath *p=[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds,i+0.5,i+0.5)];[p stroke];}}
    if(_historyCount&&_historyOffset>0){CGFloat trackHeight=MAX(1,NSHeight(self.bounds)-12),total=(CGFloat)(_historyCount+_rows),visible=(CGFloat)_rows,thumbHeight=MAX(24,trackHeight*visible/MAX(visible,total)),progress=(CGFloat)_historyOffset/MAX(1,(CGFloat)_historyCount),y=6+(trackHeight-thumbHeight)*(1-progress);[[self.config.foreground colorWithAlphaComponent:0.42]setFill];NSBezierPath *thumb=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMaxX(self.bounds)-5,y,2.5,thumbHeight) xRadius:1.25 yRadius:1.25];[thumb fill];}
    }
}
- (NSPoint)cellForPoint:(NSPoint)p { NSInteger x=floor((p.x-self.config.padding-self.leadingOverlayInset)/_cellWidth),y=floor((p.y-self.config.padding-self.safeAreaInsets.top-self.topContentInset)/_cellHeight); return NSMakePoint(MAX(0,MIN((NSInteger)_cols-1,x)),MAX(0,MIN((NSInteger)_rows-1,y))); }
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
    if([sender.draggingPasteboard.types containsObject:NSFilenamesPboardType])return NSDragOperationCopy;
    return NSDragOperationNone;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray *files=[sender.draggingPasteboard propertyListForType:NSFilenamesPboardType];
    if(!files.count)return NO;
    for(NSString *path in files){NSString *escaped=[path stringByReplacingOccurrencesOfString:@" " withString:@"\\ "];[self sendString:escaped];if(files.count>1)[self sendString:@" "];}
    return YES;
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
    if(_mouseTrackingMode&&!shift){NSUInteger button=lines>0?64:65;for(NSInteger i=0;i<MIN((NSInteger)8,labs(lines));i++)[self sendMouseButton:button event:event release:NO motion:NO];return;}
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
    NSString *functional=[self functionalKeySequenceForKeyCode:k modifier:modifier];if(functional){[self sendString:functional];_hasSelection=NO;[self setNeedsDisplay:YES];return;}
    if(_kittyKeyboardFlags&8){uint32_t code=[self kittyCodeForKey:k];if(!code)code=[self firstScalar:e.charactersIgnoringModifiers];if(code){[self sendString:[NSString stringWithFormat:@"\033[%u;%ldu",code,(long)modifier]];_hasSelection=NO;[self setNeedsDisplay:YES];return;}}
    if((_kittyKeyboardFlags&1)&&(k==53||(mods&(NSEventModifierFlagOption|NSEventModifierFlagControl)))){uint32_t code=[self kittyCodeForKey:k];if(!code)code=[self firstScalar:e.charactersIgnoringModifiers];if(code){[self sendString:[NSString stringWithFormat:@"\033[%u;%ldu",code,(long)modifier]];_hasSelection=NO;[self setNeedsDisplay:YES];return;}}
    if(_modifyOtherKeys>=2&&modifier>1){uint32_t code=[self firstScalar:e.charactersIgnoringModifiers];if(code&&code>=32){[self sendString:[NSString stringWithFormat:@"\033[27;%ld;%u~",(long)modifier,code]];_hasSelection=NO;[self setNeedsDisplay:YES];return;}}
    if(k==36||k==76)s=@"\r";else if(k==51)s=@"\x7f";else if(k==53)s=@"\x1b";else if(k==48)s=(mods&NSEventModifierFlagShift)?@"\x1b[Z":@"\t";
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
- (NSDictionary *)diagnosticState {@synchronized(self){return @{@"history":@(_historyCount),@"offset":@(_historyOffset),@"alternate":@(_alternateScreen),@"rows":@(_rows),@"columns":@(_cols),@"mouseMode":@(_mouseTrackingMode),@"mouseEncoding":_pixelMouse?@"pixel-sgr":(_sgrMouse?@"sgr":(_urxvtMouse?@"urxvt":(_utf8Mouse?@"utf8":@"legacy")))};}}
- (void)renderImage:(CGImageRef)image atRow:(NSUInteger)row col:(NSUInteger)col width:(NSUInteger)w height:(NSUInteger)h scale:(BOOL)doScale {
    if(!image)return;
    NSUInteger srcW=CGImageGetWidth(image),srcH=CGImageGetHeight(image);
    if(doScale){NSUInteger maxW=_cols*_cellWidth,maxH=_rows*_cellHeight;if(srcW>maxW||srcH>maxH){CGFloat sc=MIN((CGFloat)maxW/srcW,(CGFloat)maxH/srcH);srcW=MAX(1,(NSUInteger)(srcW*sc));srcH=MAX(1,(NSUInteger)(srcH*sc));CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef ctx=CGBitmapContextCreate(NULL,srcW,srcH,8,srcW*4,cs,kCGImageAlphaPremultipliedLast);if(cs&&ctx){CGContextSetRGBFillColor(ctx,0,0,0,0);CGContextFillRect(ctx,CGRectMake(0,0,srcW,srcH));CGContextDrawImage(ctx,CGRectMake(0,0,srcW,srcH),image);CGImageRef scaled=CGBitmapContextCreateImage(ctx);if(scaled){CGImageRelease(image);image=scaled;}CGContextRelease(ctx);}if(cs)CGColorSpaceRelease(cs);}}
    NSNumber *key=@((row<<16)|col);_inlineImages[key]=CFBridgingRelease(image);
    NSUInteger cellsW=MAX(1,(srcW+_cellWidth-1)/_cellWidth),cellsH=MAX(1,(srcH+_cellHeight-1)/_cellHeight);
    [self markDamageX:col y:row width:cellsW height:cellsH];[self refreshTextView];
}
- (void)deleteImageWithID:(NSString *)imageID {if(imageID){NSNumber *posKey=_kittyImageIDs[imageID];if(posKey){[_inlineImages removeObjectForKey:posKey];[_kittyImageIDs removeObjectForKey:imageID];[_animatedImages removeObjectForKey:imageID];[self setNeedsDisplay:YES];}}else{[_inlineImages removeAllObjects];[_kittyImageIDs removeAllObjects];[_animatedImages removeAllObjects];[self setNeedsDisplay:YES];}}
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
    if(sixelWidth&&sixelHeight){NSUInteger imgW=MIN(sixelWidth,maxWidth),imgH=MIN(sixelHeight,maxHeight);CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef ctx=CGBitmapContextCreate(pixels,maxWidth,maxHeight,8,maxWidth*4,cs,kCGImageAlphaPremultipliedLast);CGImageRef image=ctx?CGBitmapContextCreateImage(ctx):NULL;if(ctx)CGContextRelease(ctx);if(cs)CGColorSpaceRelease(cs);if(image){CGImageRef subImage=CGImageCreateWithImageInRect(image,CGRectMake(0,0,imgW,imgH));if(subImage){CGImageRelease(image);image=subImage;}[self renderImage:image atRow:cursorRow col:cursorCol width:0 height:0 scale:YES];CGImageRelease(image);}_cursorY=MIN(_rows-1,cursorRow+(imgH+_cellHeight-1)/_cellHeight);_cursorX=0;}
    free(pixels);
}
- (void)parseKittyGraphic:(NSString *)data {
    NSString *body=[data substringFromIndex:1];NSRange colonRange=[body rangeOfString:@":"];if(colonRange.location==NSNotFound)return;
    NSString *kvPart=[body substringToIndex:colonRange.location];NSString *base64=[body substringFromIndex:NSMaxRange(colonRange)];
    NSUInteger cellRow=0,cellCol=0,destWidth=0,destHeight=0;BOOL more=NO;NSString *action=@"T",*imageID=nil;BOOL virtualPlacement=NO;
    for(NSString *pair in [kvPart componentsSeparatedByString:@","]){NSArray *kv=[pair componentsSeparatedByString:@"="];if(kv.count!=2)continue;NSString *key=kv[0],*value=kv[1];
        if([key isEqual:@"a"])action=value;else if([key isEqual:@"i"])imageID=value;else if([key isEqual:@"m"])more=[value boolValue];else if([key isEqual:@"c"])cellCol=[value integerValue];else if([key isEqual:@"r"])cellRow=[value integerValue];else if([key isEqual:@"w"])destWidth=[value integerValue];else if([key isEqual:@"h"])destHeight=[value integerValue];else if([key isEqual:@"U"])virtualPlacement=[value boolValue];}
    if([action isEqual:@"q"]){[self queryImageWithID:imageID];return;}
    if([action isEqual:@"d"]){[self deleteImageWithID:imageID];return;}
    if(more){[_kittyGraphicAccumulator appendString:base64];return;}
    [_kittyGraphicAccumulator appendString:base64];NSData *rawData=[[NSData alloc]initWithBase64EncodedString:_kittyGraphicAccumulator options:0];[_kittyGraphicAccumulator setString:@""];
    if(!rawData.length)return;CGImageSourceRef src=CGImageSourceCreateWithData((__bridge CFDataRef)rawData,NULL);if(!src)return;
    NSUInteger frameCount=CGImageSourceGetCount(src);
    if(frameCount>1&&imageID){NSMutableDictionary *frames=[NSMutableDictionary dictionary];NSMutableArray *delays=[NSMutableArray array];for(NSUInteger i=0;i<frameCount;i++){CGImageRef f=CGImageSourceCreateImageAtIndex(src,i,NULL);if(f)frames[@(i)]=CFBridgingRelease(f);NSDictionary *props=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src,i,NULL));NSDictionary *gifProps=props[(__bridge NSString *)kCGImagePropertyGIFDictionary];NSUInteger delayMs=[gifProps[(__bridge NSString *)kCGImagePropertyGIFDelayTime] doubleValue]*1000;[delays addObject:@(MAX(40,delayMs))];}
        _animatedImages[imageID]=@{@"frames":frames,@"count":@(frameCount),@"current":@(0),@"delays":delays};
        CGImageRef first=(__bridge CGImageRef)frames[@(0)];if(first){NSUInteger targetRow=cellRow?:_cursorY,targetCol=cellCol?:_cursorX;NSNumber *posKey=@((targetRow<<16)|targetCol);_inlineImages[posKey]=CFBridgingRelease(CGImageCreateCopy(first));if(imageID)_kittyImageIDs[imageID]=posKey;NSUInteger cellsW=MAX(1,(CGImageGetWidth(first)+_cellWidth-1)/_cellWidth),cellsH=MAX(1,(CGImageGetHeight(first)+_cellHeight-1)/_cellHeight);[self markDamageX:targetCol y:targetRow width:cellsW height:cellsH];[self refreshTextView];[self startAnimationTimer];}
        CFRelease(src);return;
    }
    CGImageRef image=CGImageSourceCreateImageAtIndex(src,0,NULL);CFRelease(src);if(!image)return;
    NSUInteger targetRow=cellRow?:_cursorY,targetCol=cellCol?:_cursorX;if(virtualPlacement){targetRow=0;targetCol=0;}
    if(destWidth&&destHeight){CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef ctx=CGBitmapContextCreate(NULL,destWidth,destHeight,8,destWidth*4,cs,kCGImageAlphaPremultipliedLast);if(cs&&ctx){CGContextSetRGBFillColor(ctx,0,0,0,0);CGContextFillRect(ctx,CGRectMake(0,0,destWidth,destHeight));CGContextDrawImage(ctx,CGRectMake(0,0,destWidth,destHeight),image);CGImageRef scaled=CGBitmapContextCreateImage(ctx);if(scaled){CGImageRelease(image);image=scaled;}CGContextRelease(ctx);}if(cs)CGColorSpaceRelease(cs);}
    NSNumber *posKey=@((targetRow<<16)|targetCol);if(imageID)_kittyImageIDs[imageID]=posKey;_inlineImages[posKey]=CFBridgingRelease(image);
    NSUInteger imgW=CGImageGetWidth(image),imgH=CGImageGetHeight(image);NSUInteger cellsW=MAX(1,(imgW+_cellWidth-1)/_cellWidth),cellsH=MAX(1,(imgH+_cellHeight-1)/_cellHeight);
    [self markDamageX:targetCol y:targetRow width:cellsW height:cellsH];[self refreshTextView];
    if(!cellRow&&!cellCol&&!virtualPlacement){_cursorY=MIN(_rows-1,targetRow+cellsH);_cursorX=0;}
}
- (void)startAnimationTimer {if(_animationTimer)return;uint64_t delay=100;for(NSString *imageID in _animatedImages){NSDictionary *anim=_animatedImages[imageID];NSArray *delays=anim[@"delays"];if(delays.count){NSUInteger cur=[anim[@"current"] unsignedIntegerValue];if(cur<delays.count){uint64_t d=[delays[cur] unsignedIntegerValue];delay=MIN(delay,d);}}}dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,delay*NSEC_PER_MSEC),delay*NSEC_PER_MSEC,10*NSEC_PER_MSEC);__weak typeof(self) weakSelf=self;dispatch_source_set_event_handler(timer,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;[self advanceAnimation];if(self->_animationTimer==timer){dispatch_source_cancel(timer);self->_animationTimer=nil;[self startAnimationTimer];}});dispatch_resume(timer);_animationTimer=timer;}
- (void)advanceAnimation {if(!_animatedImages.count){if(_animationTimer){dispatch_source_cancel(_animationTimer);_animationTimer=nil;}return;}for(NSString *imageID in _animatedImages.allKeys){NSMutableDictionary *anim=[_animatedImages[imageID] mutableCopy];NSUInteger count=[anim[@"count"] unsignedIntegerValue],current=[anim[@"current"] unsignedIntegerValue];current=(current+1)%count;anim[@"current"]=@(current);_animatedImages[imageID]=anim;NSNumber *posKey=_kittyImageIDs[imageID];if(!posKey)continue;NSDictionary *frames=anim[@"frames"];CGImageRef frame=(__bridge CGImageRef)frames[@(current)];if(!frame)continue;_inlineImages[posKey]=CFBridgingRelease(CGImageCreateCopy(frame));NSUInteger v=posKey.unsignedIntegerValue,row=v>>16,col=v&0xFFFF;NSUInteger cellsW=MAX(1,(CGImageGetWidth(frame)+_cellWidth-1)/_cellWidth),cellsH=MAX(1,(CGImageGetHeight(frame)+_cellHeight-1)/_cellHeight);[self markDamageX:col y:row width:cellsW height:cellsH];}[self refreshTextView];}
- (void)parseIterm2Image:(NSString *)osc {
    NSUInteger cursorRow=_cursorY,cursorCol=_cursorX;NSString *body=[osc substringFromIndex:@"1337;File=".length];NSUInteger colonLoc=[body rangeOfString:@":"].location;
    NSString *params=colonLoc==NSNotFound?body:[body substringToIndex:colonLoc];NSString *base64=colonLoc==NSNotFound?@"":[body substringFromIndex:colonLoc+1];
    NSUInteger destWidth=0,destHeight=0;BOOL preserveAspect=YES,inlineMode=YES;
    for(NSString *pair in [params componentsSeparatedByString:@";"]){NSRange eq=[pair rangeOfString:@"="];if(eq.location==NSNotFound)continue;NSString *key=[pair substringToIndex:eq.location],*value=[pair substringFromIndex:eq.location+1];if([key isEqual:@"width"])destWidth=[value integerValue];else if([key isEqual:@"height"])destHeight=[value integerValue];else if([key isEqual:@"preserveAspectRatio"])preserveAspect=[value boolValue];else if([key isEqual:@"inline"])inlineMode=[value boolValue];}
    if(!base64.length)return;NSData *rawData=[[NSData alloc]initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];if(!rawData.length)return;
    CGImageSourceRef src=CGImageSourceCreateWithData((__bridge CFDataRef)rawData,NULL);if(!src)return;CGImageRef image=CGImageSourceCreateImageAtIndex(src,0,NULL);CFRelease(src);if(!image)return;
    NSUInteger imgW=CGImageGetWidth(image),imgH=CGImageGetHeight(image);
    if(destWidth>0||destHeight>0){if(destWidth==0)destWidth=imgW;if(destHeight==0)destHeight=imgH;if(preserveAspect){CGFloat sc=MIN((CGFloat)destWidth/imgW,(CGFloat)destHeight/imgH);destWidth=MAX(1,(NSUInteger)(imgW*sc));destHeight=MAX(1,(NSUInteger)(imgH*sc));}CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef ctx=CGBitmapContextCreate(NULL,destWidth,destHeight,8,destWidth*4,cs,kCGImageAlphaPremultipliedLast);if(cs&&ctx){CGContextSetRGBFillColor(ctx,0,0,0,0);CGContextFillRect(ctx,CGRectMake(0,0,destWidth,destHeight));CGContextDrawImage(ctx,CGRectMake(0,0,destWidth,destHeight),image);CGImageRef scaled=CGBitmapContextCreateImage(ctx);if(scaled){CGImageRelease(image);image=scaled;}CGContextRelease(ctx);}if(cs)CGColorSpaceRelease(cs);}
    [self renderImage:image atRow:cursorRow col:cursorCol width:0 height:0 scale:YES];CGImageRelease(image);
    if(inlineMode){NSUInteger cellsH=(CGImageGetHeight(image)+_cellHeight-1)/_cellHeight;_cursorY=MIN(_rows-1,cursorRow+cellsH);_cursorX=0;}
}
- (void)searchScrollback {
    dispatch_async(dispatch_get_main_queue(),^{
        if(self->_searchActive){[self closeSearch];return;}
        self->_searchActive=YES;
        CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
        CGFloat barH=28,barW=340;
        CGFloat barX=w-barW-self.config.padding-self.leadingOverlayInset-4;
        CGFloat barY=h-barH-self.config.padding-self.safeAreaInsets.bottom-4;
        NSView *overlay=[[NSView alloc]initWithFrame:NSMakeRect(barX,barY,barW,barH)];
        overlay.wantsLayer=YES;overlay.layer.cornerRadius=6;overlay.layer.masksToBounds=YES;
        overlay.layer.backgroundColor=[self.config.panel colorWithAlphaComponent:0.96].CGColor;
        overlay.layer.borderColor=[self.config.accent colorWithAlphaComponent:0.5].CGColor;
        overlay.layer.borderWidth=1;
        self->_searchField=[[NSTextField alloc]initWithFrame:NSMakeRect(8,4,190,20)];
        self->_searchField.placeholderString=@"Search scrollback";
        self->_searchField.target=self;self->_searchField.action=@selector(executeSearch:);
        self->_searchField.bezelStyle=NSTextFieldRoundedBezel;
        self->_searchField.textColor=self.config.foreground;
        self->_searchField.backgroundColor=self.config.panel;
        NSButton *caseBtn=[NSButton checkboxWithTitle:@"Aa" target:self action:@selector(toggleSearchCase:)];
        caseBtn.frame=NSMakeRect(202,4,30,20);caseBtn.contentTintColor=self.config.accent;
        self->_searchCounter=[[NSTextField alloc]initWithFrame:NSMakeRect(232,4,100,18)];
        self->_searchCounter.editable=NO;self->_searchCounter.bezeled=NO;self->_searchCounter.stringValue=@"";
        self->_searchCounter.alignment=NSTextAlignmentRight;
        self->_searchCounter.textColor=self.config.muted?:self.config.foreground;
        self->_searchCounter.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        [overlay addSubview:self->_searchField];[overlay addSubview:caseBtn];[overlay addSubview:self->_searchCounter];
        [overlay setValue:@(0x5345) forKey:@"tag"];
        [self addSubview:overlay];
        CABasicAnimation *slide=[CABasicAnimation animationWithKeyPath:@"opacity"];slide.fromValue=@0;slide.toValue=@1;slide.duration=0.12;[overlay.layer addAnimation:slide forKey:@"fade"];
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
    if(y+(NSInteger)_historyOffset!=resultRow-(NSInteger)_historyCount)return NO;
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
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions session:(NSDictionary *)session;
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
- (NSDictionary *)sessionState;
- (TTerminalView *)newTerminal;
@end

@implementation TWindowController { NSString *_cwd; NSView *_root; NSVisualEffectView *_effect; TTabRailView *_tabRail; TTabEdgeView *_tabEdge; NSMutableArray<TTabButton *> *_tabButtons; BOOL _animateTabLayout; BOOL _hyprlandApplied; NSRect _preHyprlandFrame; TTerminalView *_draggingTerminal; NSPoint _dragOffset; TTerminalView *_enteringTerminal; NSTimer *_tabHideTimer; NSTrackingArea *_tabHoverArea; NSRect _tabRailTargetFrame; BOOL _tabRailVisible; BOOL _mouseInTabArea; BOOL _revealRailAfterLayout; }
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions {
    return [self initWithConfig:config extensions:extensions session:nil];
}
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions session:(NSDictionary *)session {
    NSWindow *window=[[TTerminalWindow alloc]initWithContentRect:NSMakeRect(0,0,920,600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){_config=config;_extensions=extensions;_terminals=[NSMutableArray array];_tabButtons=[NSMutableArray array];window.delegate=(id)self;window.title=@"Termatica";window.titleVisibility=NSWindowTitleHidden;window.titlebarAppearsTransparent=YES;window.styleMask|=NSWindowStyleMaskFullSizeContentView;window.minSize=NSMakeSize(480,280);window.tabbingMode=NSWindowTabbingModeDisallowed;window.movableByWindowBackground=NO;[window center];
        _root=[[NSView alloc]initWithFrame:window.contentView.bounds];_root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;window.contentView=_root;
        _tabRail=[[TTabRailView alloc]initWithFrame:NSZeroRect];_tabRail.config=config;_tabRail.wantsLayer=YES;[_root addSubview:_tabRail];
        _tabEdge=[[TTabEdgeView alloc]initWithFrame:NSZeroRect];_tabEdge.config=config;_tabEdge.wantsLayer=YES;_tabEdge.hidden=YES;_tabEdge.alphaValue=0;[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];
        [self applyAppearance];
        NSArray *saved=[session[@"terminals"] isKindOfClass:NSArray.class]?session[@"terminals"]:@[];if(saved.count&&saved.count<=32){NSString *frameString=[session[@"frame"] isKindOfClass:NSString.class]?session[@"frame"]:nil;NSRect restored=frameString.length?NSRectFromString(frameString):NSZeroRect;if(restored.size.width>=480&&restored.size.height>=280){NSRect visible=NSScreen.mainScreen.visibleFrame;restored.size.width=MIN(restored.size.width,visible.size.width);restored.size.height=MIN(restored.size.height,visible.size.height);restored.origin.x=MAX(NSMinX(visible),MIN(NSMaxX(visible)-restored.size.width,restored.origin.x));restored.origin.y=MAX(NSMinY(visible),MIN(NSMaxY(visible)-restored.size.height,restored.origin.y));[window setFrame:restored display:NO];}
            for(NSDictionary *item in saved){if(![item isKindOfClass:NSDictionary.class])continue;TTerminalView *terminal=[self newTerminal];NSString *cwd=[item[@"cwd"] isKindOfClass:NSString.class]?item[@"cwd"]:nil;BOOL directory=NO;if(cwd.length&&cwd.length<=PATH_MAX&&[NSFileManager.defaultManager fileExistsAtPath:cwd isDirectory:&directory]&&directory)terminal.launchDirectory=cwd;terminal.verticalSplit=[item[@"vertical"] boolValue];NSInteger anchor=[item[@"anchor"] integerValue];if(anchor>=0&&anchor<(NSInteger)_terminals.count)terminal.splitAnchor=_terminals[(NSUInteger)anchor];[_terminals addObject:terminal];[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];[terminal startShell];}
            NSUInteger active=MIN([session[@"active"] unsignedIntegerValue],_terminals.count?_terminals.count-1:0);self.terminal=_terminals.count?_terminals[active]:nil;self.extensions.activeTerminal=self.terminal;[self rebuildTabs];[self layoutTabs];if(self.terminal)[self focusTerminal:self.terminal];
        }
        if(!_terminals.count)[self addTab];
    }return self;
}
- (NSDictionary *)sessionState {
    if(!_terminals.count)return nil;NSMutableArray *items=[NSMutableArray arrayWithCapacity:_terminals.count];for(TTerminalView *terminal in _terminals){NSUInteger anchor=terminal.splitAnchor?[_terminals indexOfObject:terminal.splitAnchor]:NSNotFound;[items addObject:@{@"cwd":[terminal workingDirectory]?:NSHomeDirectory(),@"vertical":@(terminal.verticalSplit),@"anchor":anchor==NSNotFound?@(-1):@(anchor)}];}NSUInteger active=[_terminals indexOfObject:self.terminal];return @{@"frame":NSStringFromRect(self.window.frame),@"active":@(active==NSNotFound?0:active),@"terminals":items};
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
    NSRect edge=NSMakeRect(0,NSMaxY(_tabRailTargetFrame)-26,10,26);_tabEdge.frame=edge;NSRect hover=NSUnionRect(_tabRailTargetFrame,edge);hover=NSInsetRect(hover,-6,-6);_tabHoverArea=[[NSTrackingArea alloc]initWithRect:hover options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow owner:self userInfo:nil];[_root addTrackingArea:_tabHoverArea];
}
- (void)scheduleTabRailHide {
    [_tabHideTimer invalidate];_tabHideTimer=nil;if(!self.config.tabAutoHide||!_tabRailVisible||![self tabRailAvailable])return;__weak typeof(self) weakSelf=self;_tabHideTimer=[NSTimer timerWithTimeInterval:self.config.tabHideDelay repeats:NO block:^(NSTimer *timer){__strong typeof(weakSelf) self=weakSelf;if(self)[self hideTabRail];}];[NSRunLoop.mainRunLoop addTimer:_tabHideTimer forMode:NSRunLoopCommonModes];
}
- (void)revealTabRail {
    if(![self tabRailAvailable]||NSIsEmptyRect(_tabRailTargetFrame)){[self suppressTabRail];return;}[_tabHideTimer invalidate];_tabHideTimer=nil;BOOL wasVisible=_tabRailVisible;_tabRailVisible=YES;[self updateTerminalTabInsets];[_tabRail.layer removeAnimationForKey:@"termatica.rail.fold"];[_tabEdge.layer removeAnimationForKey:@"termatica.edge.reveal"];NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+7;_tabRail.hidden=NO;if(!wasVisible){_tabRail.frame=collapsed;_tabRail.alphaValue=0;if(self.config.tabAnimations){CAKeyframeAnimation *unfold=[CAKeyframeAnimation animationWithKeyPath:@"transform"];unfold.values=@[[NSValue valueWithCATransform3D:CATransform3DConcat(CATransform3DMakeTranslation(-10,0,0),CATransform3DMakeScale(0.78,0.90,1))],[NSValue valueWithCATransform3D:CATransform3DMakeScale(0.97,0.99,1)],[NSValue valueWithCATransform3D:CATransform3DIdentity]];unfold.keyTimes=@[@0,@0.62,@1];unfold.duration=[self animationDuration:0.18];unfold.timingFunctions=@[[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f],[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f]];[_tabRail.layer addAnimation:unfold forKey:@"termatica.rail.unfold"];}}_tabEdge.hidden=NO;CAMediaTimingFunction *settle=[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f];[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=self.config.tabAnimations?[self animationDuration:0.20]:0;context.timingFunction=settle;_tabRail.animator.frame=_tabRailTargetFrame;_tabRail.animator.alphaValue=1;_tabEdge.animator.alphaValue=0;} completionHandler:^{if(self->_tabRailVisible)self->_tabEdge.hidden=YES;}];[self scheduleTabRailHide];
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
    terminal.autoresizingMask=NSViewNotSizable;terminal.wantsLayer=YES;[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];
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
    TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSZeroRect config:self.config];terminal.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;__weak typeof(self) weakSelf=self;__weak TTerminalView *weakTerminal=terminal;terminal.titleChanged=^(NSString *title){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self.window.title=title.length?title:@"Termatica";};terminal.cwdChanged=^(NSString *cwd){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self->_cwd=cwd;};terminal.focused=^{__strong typeof(weakSelf) self=weakSelf;if(self&&weakTerminal)[self focusTerminal:weakTerminal];};terminal.tileDragBegan=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self beginDraggingTerminal:tile event:event];};terminal.tileDragMoved=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self dragTerminal:tile event:event];};terminal.tileDragEnded=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self endDraggingTerminal:tile event:event];};terminal.accessibilityHelp=@"Command-drag, or drag from the top padding, to rearrange this Hyprland terminal.";terminal.splitShortcut=^{__strong typeof(weakSelf) self=weakSelf;if(self)[self addTabWithVerticalSplit:NO];};terminal.nextSplitShortcut=^{__strong typeof(weakSelf) self=weakSelf;if(self){NSUInteger idx=[self.terminals indexOfObject:self.terminal];if(idx!=NSNotFound&&idx+1<self.terminals.count){[self focusTerminal:self.terminals[idx+1]];}}};terminal.prevSplitShortcut=^{__strong typeof(weakSelf) self=weakSelf;if(self){NSUInteger idx=[self.terminals indexOfObject:self.terminal];if(idx!=NSNotFound&&idx>0){[self focusTerminal:self.terminals[idx-1]];}}};return terminal;
}
- (void)updateTabSelectionAnimated:(BOOL)animated {NSUInteger active=[_terminals indexOfObject:self.terminal];for(NSUInteger i=0;i<_tabButtons.count;i++){TTabButton *button=_tabButtons[i];BOOL selected=i==active;if(button.selectedTab!=selected){button.selectedTab=selected;[button applyStyleAnimated:animated];}}if([self tabRailAvailable])[self revealTabRail];}
- (void)focusTerminal:(TTerminalView *)terminal {if(!terminal||![_terminals containsObject:terminal])return;if(self.terminal!=terminal){self.terminal=terminal;_cwd=[terminal workingDirectory];if([self usesTiledLayout])[self updateTabSelectionAnimated:YES];else{[self rebuildTabs];[self layoutTabs];}}for(TTerminalView *item in _terminals)item.activeTerminal=item==terminal;self.extensions.activeTerminal=terminal;[terminal setNeedsDisplay:YES];[self.window makeFirstResponder:terminal];}
- (void)animateLaunchReveal {
    if(!self.config.tabAnimations)return;
    [self layoutTabs];
    [_root layoutSubtreeIfNeeded];
    [self.window displayIfNeeded];
    TAnimateCenterReveal(_root,[self animationDuration:0.30],self.config.topBar?0:14,@"termatica.launch.center",nil);
}
- (void)animateNewTerminal:(TTerminalView *)terminal {
    if(!self.config.tabAnimations)return;CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];
    BOOL tiled=[self usesTiledLayout];__weak TTerminalView *weakTerminal=terminal;TAnimateCenterReveal(terminal,[self animationDuration:tiled?0.22:0.18],tiled?14:0,@"termatica.terminal.center",^{if(!tiled)[weakTerminal releaseAnimationLayer];});
    if(_tabButtons.count>1){TTabButton *button=_tabButtons.lastObject,*previous=_tabButtons[_tabButtons.count-2];CABasicAnimation *move=[CABasicAnimation animationWithKeyPath:@"position"];move.fromValue=[NSValue valueWithPoint:previous.layer.position];move.toValue=[NSValue valueWithPoint:button.layer.position];move.duration=[self animationDuration:0.12];move.timingFunction=ease;[button.layer addAnimation:move forKey:@"termatica.bubble.move"];CABasicAnimation *bubble=[CABasicAnimation animationWithKeyPath:@"transform.scale"];bubble.fromValue=@0.78;bubble.toValue=@1;bubble.duration=[self animationDuration:0.11];bubble.timingFunction=ease;[button.layer addAnimation:bubble forKey:@"termatica.bubble.pop"];}
}
- (void)cancelTileAnimation {_enteringTerminal=nil;}
- (void)addTabWithVerticalSplit:(BOOL)verticalSplit {[self cancelTileAnimation];BOOL animate=_terminals.count>0&&_terminals.count<6,wasTiled=[self usesTiledLayout];TTerminalView *anchor=self.terminal,*terminal=[self newTerminal];terminal.launchDirectory=anchor?[anchor workingDirectory]:_cwd;terminal.verticalSplit=verticalSplit;terminal.splitAnchor=verticalSplit?anchor:nil;if(verticalSplit&&anchor){NSUInteger index=[_terminals indexOfObject:anchor];[_terminals insertObject:terminal atIndex:index==NSNotFound?_terminals.count:index+1];}else [_terminals addObject:terminal];if(animate&&self.config.tabAnimations&&[self usesTiledLayout])_enteringTerminal=terminal;[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];self.terminal=terminal;self.extensions.activeTerminal=terminal;_animateTabLayout=animate;BOOL changedTiling=wasTiled!=[self usesTiledLayout];if(changedTiling)[self applyAppearance];else{[self rebuildTabs];[self layoutTabs];}[terminal startShell];if(animate)[self animateNewTerminal:terminal];[self focusTerminal:terminal];}
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
        terminal.wantsLayer=YES;terminal.layer.cornerRadius=tile?14:0;terminal.layer.masksToBounds=tile;

        if(tile)TLog(@"tile %lu frame %.0f,%.0f %.0fx%.0f anchor %@",(unsigned long)i+1,target.origin.x,target.origin.y,target.size.width,target.size.height,terminal.splitAnchor?[NSString stringWithFormat:@"%lu",(unsigned long)[_terminals indexOfObject:terminal.splitAnchor]+1]:@"root");
        if(terminal==_draggingTerminal)continue;
        BOOL animateTerminal=animate&&(!tile||!_enteringTerminal||terminal==_enteringTerminal);
        if(animateTerminal&&animationStart.size.width>0&&!NSEqualRects(animationStart,target)){CGFloat sx=animationStart.size.width/target.size.width,sy=animationStart.size.height/target.size.height,dx=NSMidX(animationStart)-NSMidX(target),dy=NSMidY(animationStart)-NSMidY(target);CATransform3D from=CATransform3DConcat(CATransform3DMakeTranslation(dx,dy,0),CATransform3DMakeScale(sx,sy,1));CABasicAnimation *snap=[CABasicAnimation animationWithKeyPath:@"transform"];snap.fromValue=[NSValue valueWithCATransform3D:from];snap.toValue=[NSValue valueWithCATransform3D:CATransform3DIdentity];snap.duration=[self animationDuration:0.12];snap.timingFunction=ease;[terminal.layer addAnimation:snap forKey:@"termatica.hypr.snap"];if(terminal==_enteringTerminal){CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];fade.fromValue=@0;fade.toValue=@1;fade.duration=[self animationDuration:0.09];fade.timingFunction=ease;[terminal.layer addAnimation:fade forKey:@"termatica.hypr.fade"];}if(!tile){__weak TTerminalView *weakTerminal=terminal;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self animationDuration:0.14]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[weakTerminal releaseAnimationLayer];});}}
    }
    [self cancelTileAnimation];
    [self updateEffectMask];
    if(![self tabRailAvailable]){_animateTabLayout=NO;[self suppressTabRail];[self updateTerminalTabInsets];return;}
    CGFloat topInset=MAX(42,_root.safeAreaInsets.top+8),available=MAX(44,h-topInset-8),itemHeight=MIN(28,floor((available-8)/_terminals.count));itemHeight=MAX(20,itemHeight);CGFloat railWidth=self.config.tabRailWidth,railHeight=8+itemHeight*_terminals.count;_tabRailTargetFrame=NSMakeRect(8,MAX(8,h-topInset-railHeight-6),railWidth,railHeight);for(NSUInteger i=0;i<_tabButtons.count;i++)_tabButtons[i].frame=NSMakeRect(4,4+i*itemHeight,railWidth-8,itemHeight);[self updateTabHoverArea];TLog(@"tab rail frame %.0f,%.0f %.0fx%.0f",_tabRailTargetFrame.origin.x,_tabRailTargetFrame.origin.y,_tabRailTargetFrame.size.width,_tabRailTargetFrame.size.height);BOOL reveal=_revealRailAfterLayout;_revealRailAfterLayout=NO;_animateTabLayout=NO;if(reveal)[self revealTabRail];else if(_tabRailVisible)_tabRail.frame=_tabRailTargetFrame;else{NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+7;_tabRail.frame=collapsed;}[_root addSubview:_tabRail positioned:NSWindowAbove relativeTo:nil];[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];[_tabRail setNeedsDisplay:YES];
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
    if(self.config.hyprlandLayout){if(!_hyprlandApplied)_preHyprlandFrame=self.window.frame;NSRect target=NSInsetRect(NSScreen.mainScreen.visibleFrame,self.config.screenInset,self.config.screenInset);if(!NSEqualRects(self.window.frame,target))[self.window setFrame:target display:YES animate:animateWindow];_hyprlandApplied=YES;}else if(_hyprlandApplied){if(_preHyprlandFrame.size.width>0)[self.window setFrame:_preHyprlandFrame display:YES animate:animateWindow];_hyprlandApplied=NO;}
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
- (void)applicationDidFinishLaunching:(NSNotification *)notification {_cliSocket=-1;_config=[TConfig new];TInstallConfiguredPlugins(_config);[_config reload];_extensions=[TExtensionHost new];_extensions.config=_config;_windows=[NSMutableArray array];[self buildMenu];[self startCLIListener];[_extensions loadExtensions];[self startConfigWatcher];NSDictionary *snapshot=self.config.restoreSession?TReadSessionSnapshot():nil;NSArray *saved=[snapshot[@"windows"] isKindOfClass:NSArray.class]?snapshot[@"windows"]:@[];if(!saved.count)saved=@[[NSNull null]];for(id state in saved){NSDictionary *session=[state isKindOfClass:NSDictionary.class]?state:nil;TWindowController *controller=[[TWindowController alloc]initWithConfig:self.config extensions:self.extensions session:session];[self.windows addObject:controller];controller.window.initialFirstResponder=controller.terminal;[controller.window makeFirstResponder:controller.terminal];[controller animateLaunchReveal];[controller showWindow:nil];}[self checkForUpdatesOnLaunch];}
- (void)startConfigWatcher {NSString *path=_config.path;int fd=open(path.fileSystemRepresentation,O_EVTONLY);if(fd<0)return;dispatch_source_t src=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,fd,DISPATCH_VNODE_DELETE|DISPATCH_VNODE_WRITE|DISPATCH_VNODE_REVOKE,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));__weak typeof(self) weakSelf=self;__block dispatch_source_t prev=nil;dispatch_source_set_event_handler(src,^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self reloadAll];});if(prev)dispatch_cancel(prev);prev=src;});dispatch_source_set_cancel_handler(src,^{close(fd);});dispatch_resume(src);}
- (void)applicationWillTerminate:(NSNotification *)notification {if(self.config.restoreSession){NSMutableArray *states=[NSMutableArray array];for(TWindowController *controller in self.windows){NSDictionary *state=[controller sessionState];if(state)[states addObject:state];}TWriteSessionSnapshot(states);}else TInvalidateSessionSnapshot();if(_cliSource){dispatch_source_cancel(_cliSource);_cliSource=nil;}else if(_cliSocket>=0){close(_cliSocket);TRemoveOwnedSocket(TCLISocketPath());_cliSocket=-1;}}
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
- (void)handleCLIRequest:(NSDictionary *)request {NSString *command=request[@"command"];if([command isEqual:@"reload"])[self reloadAll];else if([command isEqual:@"run"]&&![[self active] executeExtensionNamed:request[@"name"] query:request[@"query"]])TLog(@"extension command not found: %@",request[@"name"]);}
- (void)buildMenu {
    NSDictionary *keys=self.config.keybindings;NSMenu *main=[NSMenu new];NSApp.mainMenu=main;
    NSMenuItem *appItem=[NSMenuItem new];[main addItem:appItem];NSMenu *app=[NSMenu new];appItem.submenu=app;[app addItemWithTitle:@"About Termatica" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];[app addItem:NSMenuItem.separatorItem];NSMenuItem *config=[app addItemWithTitle:@"Open Configuration…" action:@selector(openConfig:) keyEquivalent:@""];TApplyMenuShortcut(config,keys[@"openConfig"]);[app addItem:NSMenuItem.separatorItem];[app addItemWithTitle:@"Hide Termatica" action:@selector(hide:) keyEquivalent:@"h"];[app addItemWithTitle:@"Quit Termatica" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *shellItem=[NSMenuItem new];[main addItem:shellItem];NSMenu *shell=[[NSMenu alloc]initWithTitle:@"Shell"];shellItem.submenu=shell;NSMenuItem *newWindow=[shell addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@""];TApplyMenuShortcut(newWindow,keys[@"newWindow"]);NSMenuItem *newTab=[shell addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@""];TApplyMenuShortcut(newTab,keys[@"newTab"]);NSMenuItem *newVerticalTab=[shell addItemWithTitle:@"New Vertical Terminal" action:@selector(newVerticalTab:) keyEquivalent:@""];TApplyMenuShortcut(newVerticalTab,keys[@"newVerticalTab"]);NSMenuItem *closeTab=[shell addItemWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@""];TApplyMenuShortcut(closeTab,keys[@"closeTab"]);[shell addItem:NSMenuItem.separatorItem];NSMenuItem *clear=[shell addItemWithTitle:@"Clear Terminal" action:@selector(clearTerminal:) keyEquivalent:@""];TApplyMenuShortcut(clear,keys[@"clearTerminal"]);NSMenuItem *reload=[shell addItemWithTitle:@"Reload Configuration" action:@selector(reloadConfig:) keyEquivalent:@""];TApplyMenuShortcut(reload,keys[@"reload"]);[shell addItem:NSMenuItem.separatorItem];for(NSInteger i=1;i<=9;i++){NSMenuItem *tab=[shell addItemWithTitle:[NSString stringWithFormat:@"Select Tab %ld",(long)i] action:@selector(selectTab:) keyEquivalent:@""];tab.tag=i;tab.target=self;NSString *name=[NSString stringWithFormat:@"tab%ld",(long)i],*fallback=[NSString stringWithFormat:@"cmd+%ld",(long)i];TApplyMenuShortcut(tab,keys[name]?:fallback);}
    NSMenuItem *editItem=[NSMenuItem new];[main addItem:editItem];NSMenu *edit=[[NSMenu alloc]initWithTitle:@"Edit"];editItem.submenu=edit;NSMenuItem *copy=[edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];TApplyMenuShortcut(copy,keys[@"copy"]);NSMenuItem *paste=[edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];TApplyMenuShortcut(paste,keys[@"paste"]);NSMenuItem *selectAll=[edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@""];TApplyMenuShortcut(selectAll,keys[@"selectAll"]);
    NSMenuItem *viewItem=[NSMenuItem new];[main addItem:viewItem];NSMenu *view=[[NSMenu alloc]initWithTitle:@"View"];viewItem.submenu=view;NSMenuItem *zoomIn=[view addItemWithTitle:@"Increase Text Size" action:@selector(zoomIn:) keyEquivalent:@""];TApplyMenuShortcut(zoomIn,keys[@"zoomIn"]);NSMenuItem *zoomOut=[view addItemWithTitle:@"Decrease Text Size" action:@selector(zoomOut:) keyEquivalent:@""];TApplyMenuShortcut(zoomOut,keys[@"zoomOut"]);NSMenuItem *zoomReset=[view addItemWithTitle:@"Reset Text Size" action:@selector(zoomReset:) keyEquivalent:@""];TApplyMenuShortcut(zoomReset,keys[@"zoomReset"]);[view addItem:NSMenuItem.separatorItem];NSMenuItem *previousPrompt=[view addItemWithTitle:@"Previous Prompt" action:@selector(previousPrompt:) keyEquivalent:@""];TApplyMenuShortcut(previousPrompt,keys[@"previousPrompt"]);NSMenuItem *nextPrompt=[view addItemWithTitle:@"Next Prompt" action:@selector(nextPrompt:) keyEquivalent:@""];TApplyMenuShortcut(nextPrompt,keys[@"nextPrompt"]);NSMenuItem *search=[view addItemWithTitle:@"Search Scrollback" action:@selector(searchScrollback:) keyEquivalent:@""];TApplyMenuShortcut(search,keys[@"searchScrollback"]);NSMenuItem *splitH=[view addItemWithTitle:@"Split Horizontal" action:@selector(splitHorizontal:) keyEquivalent:@""];TApplyMenuShortcut(splitH,keys[@"splitHorizontal"]);NSMenuItem *splitV=[view addItemWithTitle:@"Split Vertical" action:@selector(splitVertical:) keyEquivalent:@""];TApplyMenuShortcut(splitV,keys[@"splitVertical"]);[view addItem:NSMenuItem.separatorItem];NSMenuItem *nextSplit=[view addItemWithTitle:@"Next Split" action:@selector(nextSplit:) keyEquivalent:@""];TApplyMenuShortcut(nextSplit,keys[@"nextSplit"]);NSMenuItem *prevSplit=[view addItemWithTitle:@"Previous Split" action:@selector(previousSplit:) keyEquivalent:@""];TApplyMenuShortcut(prevSplit,keys[@"previousSplit"]);
    for(NSMenuItem *item in main.itemArray)for(NSMenuItem *child in item.submenu.itemArray)if(child.action&&child.target==nil&&child.action!=@selector(copy:)&&child.action!=@selector(paste:)&&child.action!=@selector(selectAll:))child.target=self;
}
@end
static int TRunTerminalSelfTest(void) {
    [TApplication sharedApplication];
    TConfig *config=[TConfig new];config.scrollback=1000;config.unicodeRendering=YES;config.clipboardRead=@"deny";config.clipboardWrite=@"deny";
    TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,800,500) config:config];
    NSMutableString *lines=[NSMutableString string];for(NSUInteger i=0;i<240;i++)[lines appendFormat:@"scroll-line-%03lu\r\n",(unsigned long)i];
    [terminal consumeData:[lines dataUsingEncoding:NSUTF8StringEncoding]];
    NSDictionary *initial=terminal.diagnosticState;if([initial[@"history"] unsignedIntegerValue]<100)return 1;
    [terminal scrollByLines:12];NSInteger offset=[terminal.diagnosticState[@"offset"] integerValue];if(offset!=12)return 2;
    [terminal consumeData:[@"anchored-a\r\nanchored-b\r\n" dataUsingEncoding:NSUTF8StringEncoding]];if([terminal.diagnosticState[@"offset"] integerValue]<=offset)return 3;
    [terminal scrollByLines:-100000];if([terminal.diagnosticState[@"offset"] integerValue]!=0)return 4;
    CGEventRef wheelEvent=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitLine,1,3);NSEvent *wheel=[NSEvent eventWithCGEvent:wheelEvent];CFRelease(wheelEvent);[terminal scrollWheel:wheel];
    if([terminal.diagnosticState[@"offset"] integerValue]<=0)return 5;[terminal scrollByLines:-100000];
    [terminal consumeData:[@"PRIMARY-MARKER\033[?1049hALTERNATE-MARKER\033[?1049l" dataUsingEncoding:NSUTF8StringEncoding]];
    if(![[terminal visibleText] containsString:@"PRIMARY-MARKER"]||[terminal.diagnosticState[@"alternate"] boolValue])return 6;
    [terminal consumeData:[@"\033[>1u" dataUsingEncoding:NSUTF8StringEncoding]];
    if(![[terminal functionalKeySequenceForKeyCode:126 modifier:1] isEqual:@"\033[1;1A"])return 7;
    if(![[terminal functionalKeySequenceForKeyCode:125 modifier:2] isEqual:@"\033[1;2B"])return 8;
    NSEvent *up=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:126];
    [terminal startDiagnosticInputCapture];[terminal keyDown:up];
    if(![[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding] isEqual:@"\033[1;1A"])return 9;
    [terminal consumeData:[@"\033[<u\033[?1h" dataUsingEncoding:NSUTF8StringEncoding]];
    if(![[terminal functionalKeySequenceForKeyCode:123 modifier:1] isEqual:@"\033OD"])return 10;
    [terminal consumeData:[@"\033[?1049h" dataUsingEncoding:NSUTF8StringEncoding]];
    [terminal startDiagnosticInputCapture];[terminal scrollWheel:wheel];
    NSString *alternateScrollReport=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];
    if(![alternateScrollReport containsString:@"\033OA"])return 22;
    [terminal consumeData:[@"\033[?1049l" dataUsingEncoding:NSUTF8StringEncoding]];
    [terminal consumeData:[@"\033[?1000;1006h" dataUsingEncoding:NSUTF8StringEncoding]];
    if([terminal shouldForwardApplicationMouseWithModifiers:0])return 11;
    if(![terminal shouldForwardApplicationMouseWithModifiers:NSEventModifierFlagOption])return 12;
    if(![terminal.diagnosticState[@"mouseEncoding"] isEqual:@"sgr"])return 13;
    [terminal startDiagnosticInputCapture];[terminal scrollWheel:wheel];
    NSString *wheelReport=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];
    if(![wheelReport containsString:@"\033[<64;"])return 14;
    [terminal scrollByLines:-100000];[terminal startDiagnosticInputCapture];[terminal routeWheelLines:3 event:wheel modifierFlags:NSEventModifierFlagShift];
    if([terminal finishDiagnosticInputCapture].length||[terminal.diagnosticState[@"offset"] integerValue]<=0)return 15;
    [terminal scrollByLines:-100000];
    [terminal startDiagnosticInputCapture];[terminal consumeData:[@"\033]10;?\a" dataUsingEncoding:NSUTF8StringEncoding]];NSString *colorReply=[[NSString alloc]initWithData:[terminal finishDiagnosticInputCapture] encoding:NSUTF8StringEncoding];if(![colorReply containsString:@"\033]10;rgb:"])return 16;
    NSEvent *down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(400,250) modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
    NSEvent *mouseUp=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSMakePoint(400,250) modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:0];
    [terminal startDiagnosticInputCapture];[terminal mouseDown:down];[terminal mouseUp:mouseUp];
    if([terminal finishDiagnosticInputCapture].length)return 17;
    TConfig *tiledConfig=[TConfig new];tiledConfig.hyprlandLayout=YES;tiledConfig.tabAnimations=NO;tiledConfig.shell=@"/usr/bin/true";tiledConfig.shellArguments=@[];
    TWindowController *tiles=[[TWindowController alloc]initWithConfig:tiledConfig extensions:nil];[tiles addTab];
    if(tiles.terminals.count!=2)return 18;
    for(TTerminalView *tile in tiles.terminals)if([tiles terminalAtRootPoint:NSMakePoint(NSMidX(tile.frame),NSMidY(tile.frame))]!=tile)return 19;
    for(TTerminalView *tile in tiles.terminals)[tile stopShellTerminating:YES];[tiles.window close];
    TWriteSessionSnapshot(@[@{@"frame":NSStringFromRect(NSMakeRect(20,20,800,500)),@"active":@0,@"terminals":@[@{@"cwd":@"/tmp",@"vertical":@NO,@"anchor":@(-1)}]}]);NSDictionary *session=TReadSessionSnapshot();if(![session[@"windows"] isKindOfClass:NSArray.class]||[session[@"windows"] count]!=1)return 20;struct stat sessionInfo={0};if(stat(TSessionPath().fileSystemRepresentation,&sessionInfo)<0||(sessionInfo.st_mode&0777)!=0600)return 21;TInvalidateSessionSnapshot();
    fprintf(stdout,"terminal-self-test ok history=%lu rows=%lu columns=%lu keyboard=kitty+legacy mouse=native-click+tui-wheel wheel=normal+hyprland\n",(unsigned long)[initial[@"history"] unsignedIntegerValue],(unsigned long)[initial[@"rows"] unsignedIntegerValue],(unsigned long)[initial[@"columns"] unsignedIntegerValue]);
    return 0;
}

static int TRunCoreBenchmark(NSUInteger requestedBytes) {
    [TApplication sharedApplication];NSUInteger bytes=MAX((NSUInteger)1048576,MIN((NSUInteger)268435456,requestedBytes?:33554432));TConfig *config=[TConfig new];config.scrollback=2000;TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,1200,800) config:config];NSArray<NSDictionary *> *cases=@[@{@"name":@"ascii",@"pattern":@"benchmark plain terminal text 0123456789 abcdefghijklmnopqrstuvwxyz\r\n"},@{@"name":@"unicode",@"pattern":@"Unicode λ漢字🙂 composed e\u0301 terminal rendering\r\n"},@{@"name":@"csi",@"pattern":@"\033[38;2;89;194;255mcyan\033[0m \033[1mbold\033[0m \033[2Kbenchmark\r\n"}];NSMutableArray *results=[NSMutableArray array];
    for(NSDictionary *item in cases){NSData *pattern=[item[@"pattern"] dataUsingEncoding:NSUTF8StringEncoding];NSMutableData *chunk=[NSMutableData dataWithCapacity:32768];while(chunk.length+pattern.length<=32768)[chunk appendData:pattern];NSUInteger consumed=0;CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();while(consumed<bytes){NSUInteger take=MIN(chunk.length,bytes-consumed);[terminal consumeData:take==chunk.length?chunk:[chunk subdataWithRange:NSMakeRange(0,take)]];consumed+=take;}double seconds=CFAbsoluteTimeGetCurrent()-start,mbps=(double)consumed/1048576.0/MAX(0.000001,seconds);[results addObject:@{@"case":item[@"name"],@"bytes":@(consumed),@"seconds":@(seconds),@"mib_per_second":@(mbps)}];}
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"engine":@"Termatica Core/AppKit",@"bytes_per_case":@(bytes),@"results":results} options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return 0;
}

static int TCompareDouble(const void *left,const void *right){double a=*(const double *)left,b=*(const double *)right;return a<b?-1:(a>b?1:0);}
static double TPercentile(double *values,NSUInteger count,double percentile){if(!count)return 0;qsort(values,count,sizeof(double),TCompareDouble);NSUInteger index=(NSUInteger)MIN((double)(count-1),ceil(percentile*(double)count)-1);return values[index];}
static double TUsageSeconds(struct rusage usage){return usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1000000.0+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1000000.0;}
static int TRunExperienceBenchmark(NSUInteger requestedFrames,double requestedSeconds) {
    [TApplication sharedApplication];NSUInteger frames=MAX((NSUInteger)30,MIN((NSUInteger)1200,requestedFrames?:240));double sustainedSeconds=MAX(0.5,MIN(30.0,requestedSeconds>0?requestedSeconds:3.0));TConfig *config=[TConfig new];config.scrollback=10000;config.blur=NO;config.glow=config.scanlines=config.vignette=0;config.unicodeRendering=YES;TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSMakeRect(0,0,1000,700) config:config];
    NSMutableString *history=[NSMutableString string];for(NSUInteger i=0;i<5000;i++)[history appendFormat:@"frame-%05lu  λ漢字🙂  != -> terminal rendering and scrollback\r\n",(unsigned long)i];[terminal consumeData:[history dataUsingEncoding:NSUTF8StringEncoding]];[terminal scrollByLines:1000];
    NSBitmapImageRep *bitmap=[terminal bitmapImageRepForCachingDisplayInRect:terminal.bounds];if(!bitmap){fputs("could not allocate render benchmark surface\n",stderr);return 2;}double *paint=calloc(frames,sizeof(double)),*interaction=calloc(frames,sizeof(double));
    for(NSUInteger i=0;i<frames;i++){@autoreleasepool{NSInteger direction=(i%120)<60?1:-1;CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();[terminal scrollByLines:direction];[terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];paint[i]=(CFAbsoluteTimeGetCurrent()-start)*1000.0;NSString *update=[NSString stringWithFormat:@"\rinteraction-%06lu",(unsigned long)i];start=CFAbsoluteTimeGetCurrent();[terminal consumeData:[update dataUsingEncoding:NSUTF8StringEncoding]];[terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];interaction[i]=(CFAbsoluteTimeGetCurrent()-start)*1000.0;}}
    NSData *pattern=[@"sustained terminal output λ漢字🙂 \033[38;2;89;194;255mcolor\033[0m 0123456789\r\n" dataUsingEncoding:NSUTF8StringEncoding];NSMutableData *chunk=[NSMutableData dataWithCapacity:65536];while(chunk.length+pattern.length<=65536)[chunk appendData:pattern];struct rusage before={0},after={0};getrusage(RUSAGE_SELF,&before);CFAbsoluteTime sustainedStart=CFAbsoluteTimeGetCurrent(),deadline=sustainedStart+sustainedSeconds;NSUInteger bytes=0;NSMutableArray<NSNumber *> *windows=[NSMutableArray array];CFAbsoluteTime windowStart=sustainedStart;NSUInteger windowBytes=0;while(CFAbsoluteTimeGetCurrent()<deadline){[terminal consumeData:chunk];bytes+=chunk.length;windowBytes+=chunk.length;CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();if(now-windowStart>=0.25){[windows addObject:@((double)windowBytes/1048576.0/(now-windowStart))];windowStart=now;windowBytes=0;}}CFAbsoluteTime sustainedEnd=CFAbsoluteTimeGetCurrent();getrusage(RUSAGE_SELF,&after);double wall=sustainedEnd-sustainedStart,cpu=TUsageSeconds(after)-TUsageSeconds(before),mean=0,minimum=DBL_MAX;for(NSNumber *number in windows){mean+=number.doubleValue;minimum=MIN(minimum,number.doubleValue);}if(windows.count)mean/=windows.count;double variance=0;for(NSNumber *number in windows){double delta=number.doubleValue-mean;variance+=delta*delta;}double coefficient=windows.count&&mean>0?sqrt(variance/windows.count)/mean:0;
    double paintP50=TPercentile(paint,frames,0.50),paintP95=TPercentile(paint,frames,0.95),paintP99=TPercentile(paint,frames,0.99),interactionP50=TPercentile(interaction,frames,0.50),interactionP95=TPercentile(interaction,frames,0.95),interactionP99=TPercentile(interaction,frames,0.99);NSUInteger missed60=0,missed120=0;for(NSUInteger i=0;i<frames;i++){if(paint[i]>16.667)missed60++;if(paint[i]>8.333)missed120++;}free(paint);free(interaction);
    NSDictionary *result=@{@"engine":@"Termatica Core/AppKit",@"methodology":@{@"paint":@"offscreen AppKit cacheDisplay duration after one-line scroll; not key-to-photon",@"interaction":@"parse plus immediate offscreen paint; not hardware input latency",@"energy_proxy":@"process user plus system CPU seconds per wall second; not electrical power"},@"frames":@(frames),@"paint_ms":@{@"p50":@(paintP50),@"p95":@(paintP95),@"p99":@(paintP99),@"over_60hz_budget":@(missed60),@"over_120hz_budget":@(missed120)},@"parse_to_paint_ms":@{@"p50":@(interactionP50),@"p95":@(interactionP95),@"p99":@(interactionP99)},@"sustained":@{@"wall_seconds":@(wall),@"bytes":@(bytes),@"mib_per_second":@((double)bytes/1048576.0/wall),@"minimum_250ms_window_mib_per_second":@(minimum==DBL_MAX?0:minimum),@"window_coefficient_of_variation":@(coefficient),@"cpu_seconds":@(cpu),@"cpu_seconds_per_wall_second":@(cpu/wall)}};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TProcessStartedAt = CFAbsoluteTimeGetCurrent();
        NSString *invoked=[NSString stringWithUTF8String:argv[0]].lastPathComponent;
        if(argc>1&&!strcmp(argv[1],"--terminal-self-test"))return TRunTerminalSelfTest();
        if(argc>1&&!strcmp(argv[1],"--benchmark-core"))return TRunCoreBenchmark(argc>2?(NSUInteger)strtoull(argv[2],NULL,10):33554432);
        if(argc>1&&!strcmp(argv[1],"--benchmark-experience"))return TRunExperienceBenchmark(argc>2?(NSUInteger)strtoull(argv[2],NULL,10):240,argc>3?strtod(argv[3],NULL):3.0);
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
