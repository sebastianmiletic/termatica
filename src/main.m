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
#import <string.h>
#import <termios.h>

static const uint32_t TDefaultColor = 0xFFFFFFFFu;
static CFAbsoluteTime TProcessStartedAt;

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

static NSDictionary *TLoadSession(void) {
    NSData *data=[NSData dataWithContentsOfFile:TSessionPath()];
    id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    return [value isKindOfClass:NSDictionary.class]?value:nil;
}

static void TWriteSession(NSDictionary *session) {
    if(![session isKindOfClass:NSDictionary.class])return;
    TEnsureDirectory(nil);
    NSData *data=[NSJSONSerialization dataWithJSONObject:session options:NSJSONWritingPrettyPrinted error:nil];
    if([data writeToFile:TSessionPath() options:NSDataWritingAtomic error:nil])
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:TSessionPath() error:nil];
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
@property NSSet<NSString *> *disabledPlugins;
@property CGFloat tabRailWidth;
@property BOOL tabAnimations;
@property CGFloat animationSpeed;
@property CGFloat tileGap;
@property CGFloat screenInset;
@property BOOL hyprlandBlur;
@property BOOL tabAutoHide;
@property CGFloat tabHideDelay;
@property BOOL restoreSession;
@property NSUInteger sessionMaxLines;
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
        [self reload];
    }
    return self;
}
- (NSDictionary *)defaults {
    return @{
        @"shell": NSProcessInfo.processInfo.environment[@"SHELL"] ?: @"/bin/zsh",
        @"shellArguments": @[@"-l"], @"fontName": @"Monaco", @"fontSize": @11,
        @"padding": @12, @"scrollback": @2000,
        @"theme": @"terminal-default", @"skeleterm": @NO, @"disabledPlugins": @[],
        @"appearance": @{@"topBar":@YES},
        @"tabs": @{@"railWidth":@34,@"animations":@YES,@"animationSpeed":@1.35,@"autoHide":@YES,@"hideDelay":@5,@"tileGap":@10,@"screenInset":@18,@"hyprlandBlur":@NO},
        @"session": @{@"restore":@YES,@"maxLines":@2000},
        @"keybindings": @{@"openConfig":@"cmd+,",@"newWindow":@"cmd+n",@"newTab":@"cmd+t",@"newVerticalTab":@"cmd+shift+t",@"closeTab":@"cmd+w",@"clearTerminal":@"cmd+k",@"reload":@"cmd+r",@"copy":@"cmd+c",@"paste":@"cmd+v",@"selectAll":@"cmd+a",@"zoomIn":@"cmd+plus",@"zoomOut":@"cmd+-",@"zoomReset":@"cmd+0"}
    };
}
- (NSDictionary *)fallbackTheme {
    return @{@"background":@"#101216",@"foreground":@"#D8DEE9",@"cursor":@"#EEF1F5",@"accent":@"#7AA2F7",@"panel":@"#151820",@"muted":@"#6B7280",@"selection":@"#2B3445",@"appearance":@{@"backgroundOpacity":@1,@"windowOpacity":@1,@"blur":@NO,@"glow":@0,@"scanlines":@0,@"vignette":@0,@"cursorStyle":@"block"},@"palette":@[@"#1B1D23",@"#E06C75",@"#98C379",@"#E5C07B",@"#61AFEF",@"#C678DD",@"#56B6C2",@"#D7DAE0",@"#5C6370",@"#F07178",@"#AAD94C",@"#FFB454",@"#59C2FF",@"#D2A6FF",@"#95E6CB",@"#EEF1F5"]};
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
    self.disabledPlugins=[NSSet setWithArray:[d[@"disabledPlugins"] isKindOfClass:NSArray.class]?d[@"disabledPlugins"]:@[]];
    self.hyprlandLayout=[self isPluginEnabled:@"hyprland-layout"];
    NSDictionary *tabs=[d[@"tabs"] isKindOfClass:NSDictionary.class]?d[@"tabs"]:@{};self.tabRailWidth=MAX(28,MIN(64,[tabs[@"railWidth"] doubleValue]?:34));self.tabAnimations=tabs[@"animations"]?[tabs[@"animations"] boolValue]:YES;self.animationSpeed=MAX(0.25,MIN(4,[tabs[@"animationSpeed"] doubleValue]?:1.35));self.tabAutoHide=tabs[@"autoHide"]?[tabs[@"autoHide"] boolValue]:YES;self.tabHideDelay=MAX(1,MIN(30,[tabs[@"hideDelay"] doubleValue]?:5));self.tileGap=MAX(0,MIN(24,[tabs[@"tileGap"] doubleValue]?:10));self.screenInset=MAX(8,MIN(80,[tabs[@"screenInset"] doubleValue]?:18));self.hyprlandBlur=tabs[@"hyprlandBlur"]?[tabs[@"hyprlandBlur"] boolValue]:NO;
    NSDictionary *session=[d[@"session"] isKindOfClass:NSDictionary.class]?d[@"session"]:@{};self.restoreSession=session[@"restore"]?[session[@"restore"] boolValue]:YES;self.sessionMaxLines=MAX(100,MIN(10000,[session[@"maxLines"] unsignedIntegerValue]?:2000));
    id rawTheme=d[@"theme"];self.themeName=[rawTheme isKindOfClass:NSString.class]?rawTheme:@"custom";
    NSDictionary *theme=[rawTheme isKindOfClass:NSDictionary.class]?rawTheme:[self themeNamed:self.themeName];if(!theme)theme=[self fallbackTheme];
    NSDictionary *themeAppearance=[theme[@"appearance"] isKindOfClass:NSDictionary.class]?theme[@"appearance"]:@{};
    NSMutableDictionary *appearance=[themeAppearance mutableCopy];
    if([d[@"appearance"] isKindOfClass:NSDictionary.class])[appearance addEntriesFromDictionary:d[@"appearance"]];
    NSDictionary *userTabs=[user[@"tabs"] isKindOfClass:NSDictionary.class]?user[@"tabs"]:@{};if(!userTabs[@"hyprlandBlur"]&&appearance[@"hyprlandBlur"])self.hyprlandBlur=[appearance[@"hyprlandBlur"] boolValue];
    self.backgroundOpacity=MAX(0.08,MIN(1.0,appearance[@"backgroundOpacity"]?[appearance[@"backgroundOpacity"] doubleValue]:0.90));
    self.windowOpacity=MAX(0.20,MIN(1.0,appearance[@"windowOpacity"]?[appearance[@"windowOpacity"] doubleValue]:1.0));
    self.blur=appearance[@"blur"]?[appearance[@"blur"] boolValue]:YES;
    self.topBar=appearance[@"topBar"]?[appearance[@"topBar"] boolValue]:YES;
    self.blurMaterial=[appearance[@"blurMaterial"] isKindOfClass:NSString.class]?appearance[@"blurMaterial"]:@"hud";
    self.glow=MAX(0,MIN(1,[appearance[@"glow"] doubleValue]));self.scanlines=MAX(0,MIN(1,[appearance[@"scanlines"] doubleValue]));self.vignette=MAX(0,MIN(1,[appearance[@"vignette"] doubleValue]));
    self.cursorStyle=[appearance[@"cursorStyle"] isKindOfClass:NSString.class]?appearance[@"cursorStyle"]:@"block";
    NSMutableDictionary *bindings=[[[self defaults] objectForKey:@"keybindings"] mutableCopy];if([d[@"keybindings"] isKindOfClass:NSDictionary.class])[bindings addEntriesFromDictionary:d[@"keybindings"]];self.keybindings=bindings;
    self.background = [THexColor(theme[@"background"], THexColor(@"#101216", NSColor.blackColor)) colorWithAlphaComponent:self.backgroundOpacity];
    self.foreground = THexColor(theme[@"foreground"], THexColor(@"#D8DEE9", NSColor.textColor));
    self.cursor = THexColor(theme[@"cursor"], THexColor(@"#EEF1F5", NSColor.textColor));
    self.accent = THexColor(theme[@"accent"], self.cursor);
    self.panel=THexColor(theme[@"panel"],THexColor(@"#151820",NSColor.windowBackgroundColor));self.muted=THexColor(theme[@"muted"],THexColor(@"#6B7280",NSColor.secondaryLabelColor));self.selection=THexColor(theme[@"selection"],THexColor(@"#2B3445",self.accent));
    NSArray *raw = [theme[@"palette"] isKindOfClass:NSArray.class] ? theme[@"palette"] : [self fallbackTheme][@"palette"];
    NSMutableArray *colors = [NSMutableArray arrayWithCapacity:16];
    for (NSUInteger i = 0; i < 16; i++) {
        NSString *hex = i < raw.count ? raw[i] : @"#E8E4DD";
        [colors addObject:THexColor(hex, self.foreground)];
    }
    self.palette = colors;
}
- (NSArray<NSString *> *)installedThemeNames {NSMutableOrderedSet *names=[NSMutableOrderedSet orderedSet];for(NSString *root in @[[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Themes"],[TConfigDirectoryPath() stringByAppendingPathComponent:@"themes"]])for(NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]?:@[])if([file.pathExtension.lowercaseString isEqual:@"json"])[names addObject:file.stringByDeletingPathExtension];return names.array;}
- (void)useThemeNamed:(NSString *)name {if(![self themeNamed:name])return;[self ensureEditableFile];NSData *data=[NSData dataWithContentsOfFile:self.path];NSMutableDictionary *d=[NSMutableDictionary dictionary];id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;if([parsed isKindOfClass:NSDictionary.class])[d addEntriesFromDictionary:parsed];d[@"theme"]=name;d[@"skeleterm"]=@NO;[d removeObjectForKey:@"profile"];[[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil] writeToFile:self.path atomically:YES];[self reload];}
- (void)ensureEditableFile {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = self.path.stringByDeletingLastPathComponent;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:self.path]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:[self defaults] options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:self.path atomically:YES];
    }
}
- (NSMutableDictionary *)editableDictionary {
    [self ensureEditableFile];NSData *data=[NSData dataWithContentsOfFile:self.path];id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;return [parsed isKindOfClass:NSDictionary.class]?[parsed mutableCopy]:[[self defaults] mutableCopy];
}
- (void)writeEditableDictionary:(NSDictionary *)dictionary {
    NSData *data=[NSJSONSerialization dataWithJSONObject:dictionary options:NSJSONWritingPrettyPrinted error:nil];[data writeToFile:self.path atomically:YES];[self reload];
}
- (void)applySkeleterm {
    NSMutableDictionary *d=[self editableDictionary];[d removeObjectForKey:@"profile"];d[@"skeleterm"]=@YES;d[@"theme"]=@"terminal-default";d[@"scrollback"]=@300;d[@"appearance"]=@{@"backgroundOpacity":@1,@"windowOpacity":@1,@"blur":@NO,@"glow":@0,@"scanlines":@0,@"vignette":@0,@"cursorStyle":@"block"};[self writeEditableDictionary:d];
}
- (BOOL)isPluginInstalled:(NSString *)identifier {return identifier.length&&[NSFileManager.defaultManager fileExistsAtPath:[[TConfigDirectoryPath() stringByAppendingPathComponent:@"extensions"] stringByAppendingPathComponent:identifier]];}
- (BOOL)isPluginEnabled:(NSString *)identifier {return [self isPluginInstalled:identifier]&&![self.disabledPlugins containsObject:identifier];}
- (void)setPlugin:(NSString *)identifier enabled:(BOOL)enabled {if(!TSafeIdentifier(identifier))return;NSMutableDictionary *d=[self editableDictionary];NSMutableOrderedSet *disabled=[NSMutableOrderedSet orderedSetWithArray:[d[@"disabledPlugins"] isKindOfClass:NSArray.class]?d[@"disabledPlugins"]:@[]];if(enabled)[disabled removeObject:identifier];else[disabled addObject:identifier];d[@"disabledPlugins"]=disabled.array;[self writeEditableDictionary:d];}
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
      @{@"id":@"helix-control",@"kind":@"plugins",@"icon":@"[HX]",@"title":@"HELIX CONTROL",@"detail":@"/hx opens files in Helix inside the active terminal"}
      ,@{@"id":@"hyprland-layout",@"kind":@"plugins",@"icon":@"[HY]",@"title":@"HYPRLAND LAYOUT",@"detail":@"tiles terminal sessions with native snapping and motion"}
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

static BOOL TWritePlugin(NSString *identifier,NSDictionary *manifest,NSData *script,NSError **error) {NSString *entry=[manifest[@"entry"] isKindOfClass:NSString.class]?manifest[@"entry"]:@"extension";if(!TSafeIdentifier(identifier)||[entry containsString:@"/"]||[entry containsString:@".."]||!script.length){if(error)*error=[NSError errorWithDomain:@"TermaticaModules" code:1 userInfo:@{NSLocalizedDescriptionKey:@"invalid plugin package"}];return NO;}NSString *root=[TEnsureDirectory(@"extensions") stringByAppendingPathComponent:identifier];NSFileManager *fm=NSFileManager.defaultManager;if(![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error])return NO;NSData *json=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];if(![json writeToFile:[root stringByAppendingPathComponent:@"extension.json"] options:NSDataWritingAtomic error:error])return NO;NSString *path=[root stringByAppendingPathComponent:entry];if(![script writeToFile:path options:NSDataWritingAtomic error:error])return NO;return [fm setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:path error:error];}

static BOOL TInstallModule(NSDictionary *item,TConfig *config,NSError **error) {
    NSString *identifier=item[@"id"],*kind=item[@"kind"];
    if(!TSafeIdentifier(identifier))return NO;
    if([kind isEqual:@"themes"]){NSData *data=[NSData dataWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[NSString stringWithFormat:@"Themes/%@.json",identifier]] options:0 error:error];NSDictionary *theme=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:error]:nil;if(![theme isKindOfClass:NSDictionary.class])return NO;NSString *path=[[TEnsureDirectory(@"themes") stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"json"];BOOL ok=[data writeToFile:path options:NSDataWritingAtomic error:error];if(ok)[config useThemeNamed:identifier];return ok;}
    if(![kind isEqual:@"plugins"])return NO;
    NSDictionary *manifest=@{@"id":[NSString stringWithFormat:@"com.termatica.%@",identifier],@"name":identifier,@"version":@"1.0.0",@"entry":@"extension.py"};NSString *script=nil;
    if([identifier isEqual:@"editor-deck"]||[identifier hasSuffix:@"-control"]){script=TEditorControlsScript(identifier);}
    else if([identifier isEqual:@"hyprland-layout"]){script=@"#!/usr/bin/env python3\nimport sys\nfor line in sys.stdin: pass\n";}
    else {NSString *command=[identifier isEqual:@"pi-bridge"]?@"pi":@"printf '\\033[38;2;122;162;247mTermatica\\033[0m %s\\n'";NSString *slash=[identifier isEqual:@"pi-bridge"]?@"/pi":@"/hello";NSString *title=[identifier isEqual:@"pi-bridge"]?@"Pi: send prompt":@"Hello: write into shell";script=[NSString stringWithFormat:@"#!/usr/bin/env python3\nimport json,sys,shlex\nfor line in sys.stdin:\n try:\n  m=json.loads(line)\n  if m.get('method')=='initialize': print(json.dumps({'jsonrpc':'2.0','method':'command.register','params':{'id':'%@.run','title':'%@','slash':'%@'}}),flush=True)\n  elif m.get('method')=='command.execute':\n   q=m.get('params',{}).get('query',''); print(json.dumps({'jsonrpc':'2.0','method':'terminal.sendText','params':{'text':\"%@ \"+shlex.quote(q)+\"\\n\"}}),flush=True)\n except Exception: pass\n",identifier,title,slash,command];}
    BOOL ok=TWritePlugin(identifier,manifest,[script dataUsingEncoding:NSUTF8StringEncoding],error);if(ok)[config setPlugin:identifier enabled:YES];return ok;
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
static void TDrawConfigBrowser(NSArray<NSString *> *names,NSUInteger selected,TConfig *config,NSString *message){fputs("\033[2J\033[H\033[38;2;122;162;247m+--------------------------------------------------------------------------+\n|  >_ TERMATICA // CONFIGS                                                 |\n|  Portable JSON configurations, readable by you and coding agents         |\n+--------------------------------------------------------------------------+\033[0m\n",stdout);fprintf(stdout,"\033[38;2;107;114;128m folder  %s\n active  %s\033[0m\n\n",TConfigProfileDirectory().fileSystemRepresentation,TActiveConfigName(config).UTF8String);if(!names.count)fputs("\033[38;2;216;222;233m   No saved configurations. Press S to save the current config.\033[0m\n",stdout);for(NSUInteger i=0;i<names.count;i++){BOOL highlighted=i==selected,active=[names[i] isEqual:TActiveConfigName(config)];if(highlighted)fputs("\033[48;2;43;52;69m\033[38;2;238;241;245m",stdout);else fputs("\033[38;2;216;222;233m",stdout);fprintf(stdout," %c %2lu  %-7s  %-52s\033[0m\n",highlighted?'>':' ',(unsigned long)i+1,active?"ACTIVE":"SAVED",names[i].UTF8String);}fputs("\n\033[38;2;107;114;128m[ UP/DOWN ] MOVE  [ ENTER ] USE  [ S ] SAVE  [ R ] RENAME  [ D ] DELETE  [ Q ] QUIT\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m%s\033[0m",message.UTF8String);fflush(stdout);}
static NSString *TConfigPrompt(struct termios original,struct termios raw,NSString *prompt){tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);fputs("\033[?25h\n",stdout);fprintf(stdout,"%s",prompt.UTF8String);fflush(stdout);char input[128]={0};NSString *answer=@"";if(fgets(input,sizeof(input),stdin))answer=[[NSString stringWithUTF8String:input] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);fputs("\033[?25l",stdout);return answer;}
static int TRunConfigBrowser(TConfig *config){
    struct termios original;BOOL interactive=isatty(STDIN_FILENO)&&isatty(STDOUT_FILENO)&&tcgetattr(STDIN_FILENO,&original)==0;NSString *message=nil;
    if(interactive){struct termios raw=original;raw.c_lflag&=~(ICANON|ECHO);raw.c_iflag&=~(IXON|ICRNL);raw.c_cc[VMIN]=1;raw.c_cc[VTIME]=0;tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);void(*previous)(int)=signal(SIGINT,TMenuSignal);TMenuInterrupted=0;NSUInteger selected=0;fputs("\033[?25l",stdout);while(!TMenuInterrupted){NSArray *names=TConfigProfileNames();if(names.count)selected=MIN(selected,names.count-1);else selected=0;TDrawConfigBrowser(names,selected,config,message);unsigned char key=0;if(read(STDIN_FILENO,&key,1)!=1)continue;if(key=='q'||key=='Q')break;if((key=='\r'||key=='\n')&&names.count){message=TUseConfigNamed(names[selected],config);continue;}if((key=='j'||key=='J')&&names.count){selected=(selected+1)%names.count;continue;}if((key=='k'||key=='K')&&names.count){selected=(selected+names.count-1)%names.count;continue;}if(key=='s'||key=='S'){NSString *name=TConfigPrompt(original,raw,@"save current config as: ");message=name.length?TSaveConfigNamed(name,config):@"[ CANCELLED ]";continue;}if((key=='r'||key=='R')&&names.count){NSString *name=TConfigPrompt(original,raw,[NSString stringWithFormat:@"rename %@ to: ",names[selected]]);message=name.length?TRenameConfig(names[selected],name,config):@"[ CANCELLED ]";continue;}if((key=='d'||key=='D')&&names.count){NSString *answer=TConfigPrompt(original,raw,[NSString stringWithFormat:@"delete %@? [y/N]: ",names[selected]]);message=[answer.lowercaseString isEqual:@"y"]?TDeleteConfig(names[selected],config):@"[ CANCELLED ]";continue;}if(key==27){unsigned char sequence[2]={0};if(read(STDIN_FILENO,&sequence[0],1)==1&&read(STDIN_FILENO,&sequence[1],1)==1&&sequence[0]=='['&&names.count){if(sequence[1]=='A')selected=(selected+names.count-1)%names.count;else if(sequence[1]=='B')selected=(selected+1)%names.count;}}}tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);signal(SIGINT,previous);fputs("\033[?25h\033[0m\n",stdout);return TMenuInterrupted?130:0;}
    char input[256]={0};while(YES){NSArray *names=TConfigProfileNames();TDrawConfigBrowser(names,NSNotFound,config,message);fputs("\ncommands: save NAME | use NAME | rename OLD NEW | delete NAME | list | q\nconfigs> ",stdout);fflush(stdout);if(!fgets(input,sizeof(input),stdin))return 0;NSString *line=[[NSString stringWithUTF8String:input] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSArray *parts=[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];NSMutableArray *args=[NSMutableArray array];for(NSString *part in parts)if(part.length)[args addObject:part];if(!args.count||[args[0] isEqual:@"q"]||[args[0] isEqual:@"quit"])return 0;if([args[0] isEqual:@"save"]&&args.count==2)message=TSaveConfigNamed(args[1],config);else if([args[0] isEqual:@"use"]&&args.count==2)message=TUseConfigNamed(args[1],config);else if([args[0] isEqual:@"rename"]&&args.count==3)message=TRenameConfig(args[1],args[2],config);else if([args[0] isEqual:@"delete"]&&args.count==2)message=TDeleteConfig(args[1],config);else if([args[0] isEqual:@"list"])message=[NSString stringWithFormat:@"[ %lu SAVED ]",(unsigned long)names.count];else message=@"[ INVALID ] expected save, use, rename, delete, list or q";}
}
static int TRunConfigsCLI(int argc,const char *argv[],TConfig *config){if(argc<3)return TRunConfigBrowser(config);NSString *action=[[NSString stringWithUTF8String:argv[2]] lowercaseString];if([action isEqual:@"path"]){fprintf(stdout,"%s\n",TConfigProfileDirectory().fileSystemRepresentation);return 0;}if([action isEqual:@"list"]){fprintf(stdout,"active\t%s\n",TActiveConfigName(config).UTF8String);for(NSString *name in TConfigProfileNames())fprintf(stdout,"%s\t%s\n",[name isEqual:TActiveConfigName(config)]?"active":"saved",name.UTF8String);return 0;}NSString *result=nil;if([action isEqual:@"save"]&&argc==4)result=TSaveConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"use"]&&argc==4)result=TUseConfigNamed([NSString stringWithUTF8String:argv[3]],config);else if([action isEqual:@"rename"]&&argc==5)result=TRenameConfig([NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[4]],config);else if([action isEqual:@"delete"]&&argc==4)result=TDeleteConfig([NSString stringWithUTF8String:argv[3]],config);else{fputs("usage: termatica configs [list|path|save NAME|use NAME|rename OLD NEW|delete NAME]\n",stderr);return 2;}fprintf(stdout,"%s\n",result.UTF8String);return [result hasPrefix:@"[ FAILED"]||[result hasPrefix:@"[ INVALID"]||[result hasPrefix:@"[ NOT"]||[result hasPrefix:@"[ EXISTS"]?1:0;}

static void TDrawModuleBrowser(NSArray<NSDictionary *> *items,NSUInteger selected,TConfig *config,NSString *message) {
    fputs("\033[2J\033[H\033[38;2;122;162;247m+--------------------------------------------------------------------------+\n|  >_ TERMATICA // MODULES                                                 |\n|  GET not installed   ON active   OFF installed but inactive              |\n+--------------------------------------------------------------------------+\033[0m\n",stdout);
    for(NSUInteger i=0;i<items.count;i++){NSDictionary *item=items[i];BOOL highlighted=i==selected;if(highlighted)fputs("\033[48;2;43;52;69m\033[38;2;238;241;245m",stdout);else fputs("\033[38;2;216;222;233m",stdout);fprintf(stdout," %c %2lu  ",highlighted?'>':' ',(unsigned long)i+1);NSString *state=TModuleState(item,config);if([state isEqual:@"ON"])fputs("\033[38;2;152;195;121m",stdout);else if([state isEqual:@"OFF"])fputs("\033[38;2;255;180;84m",stdout);else if([state isEqual:@"GET"])fputs("\033[38;2;89;194;255m",stdout);else fputs("\033[38;2;149;230;203m",stdout);fprintf(stdout,"%-5s",state.UTF8String);fputs(highlighted?"\033[38;2;238;241;245m":"\033[38;2;216;222;233m",stdout);fprintf(stdout," %-4s %-20.20s  %-35.35s\033[0m\n",[item[@"icon"] UTF8String],[[item[@"title"] uppercaseString] UTF8String],[item[@"detail"]?:@"user catalog module" UTF8String]);}
    fputs("\n\033[38;2;107;114;128m[ UP/DOWN or J/K ] MOVE   [ ENTER ] INSTALL / TOGGLE   [ Q ] QUIT\033[0m",stdout);if(message.length)fprintf(stdout,"\n\033[38;2;152;195;121m%s\033[0m",message.UTF8String);fflush(stdout);
}

static NSString *TPerformModuleAction(NSDictionary *item,TConfig *config) {NSError *error=nil;NSString *result=nil;BOOL needsInstall=[TModuleState(item,config) isEqual:@"GET"];if(needsInstall)for(int i=0;i<=20;i++){fputs("\r\033[38;2;122;162;247mWRITE [",stdout);for(int j=0;j<20;j++)fputc(j<i?'#':(j==i?'>':'.'),stdout);fprintf(stdout,"] %3d%%\033[0m",i*5);fflush(stdout);usleep(5000);}if(needsInstall)fputc('\n',stdout);BOOL ok=TActivateModule(item,config,&result,&error);if(ok){TPostCLICommand(@"reload");return [NSString stringWithFormat:@"[ %@ ] %@",result?:@"UPDATED",item[@"title"]?:item[@"id"]];}return [NSString stringWithFormat:@"[ FAILED ] %@",error.localizedDescription?:@"module action failed"];}

static NSDictionary *TModuleChoice(NSString *answer,NSArray<NSDictionary *> *items) {NSInteger choice=answer.integerValue;if(choice>=1&&choice<=(NSInteger)items.count)return items[(NSUInteger)choice-1];for(NSDictionary *candidate in items)if([candidate[@"id"] isEqual:answer])return candidate;return nil;}

static int TRunModuleBrowser(NSString *category,TConfig *config) {
    NSArray *items=[TModuleItems() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return [item[@"kind"] isEqual:category];}]];if(!items.count)return 0;struct termios original;BOOL interactive=isatty(STDIN_FILENO)&&isatty(STDOUT_FILENO)&&tcgetattr(STDIN_FILENO,&original)==0;NSString *message=nil;
    if(interactive){struct termios raw=original;raw.c_lflag&=~(ICANON|ECHO);raw.c_iflag&=~(IXON|ICRNL);raw.c_cc[VMIN]=1;raw.c_cc[VTIME]=0;tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);void (*previous)(int)=signal(SIGINT,TMenuSignal);TMenuInterrupted=0;NSUInteger selected=0;fputs("\033[?25l",stdout);while(!TMenuInterrupted){TDrawModuleBrowser(items,selected,config,message);unsigned char key=0;if(read(STDIN_FILENO,&key,1)!=1)continue;if(key=='q'||key=='Q')break;if(key=='\r'||key=='\n'){message=TPerformModuleAction(items[selected],config);continue;}if(key=='j'||key=='J'){selected=(selected+1)%items.count;continue;}if(key=='k'||key=='K'){selected=(selected+items.count-1)%items.count;continue;}if(key==27){unsigned char sequence[2]={0};if(read(STDIN_FILENO,&sequence[0],1)==1&&read(STDIN_FILENO,&sequence[1],1)==1&&sequence[0]=='['){if(sequence[1]=='A')selected=(selected+items.count-1)%items.count;else if(sequence[1]=='B')selected=(selected+1)%items.count;}}}tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);signal(SIGINT,previous);fputs("\033[?25h\033[0m\n",stdout);return TMenuInterrupted?130:0;}
    char input[128]={0};while(YES){TDrawModuleBrowser(items,NSNotFound,config,message);fputs("\nType module ids repeatedly; q closes the menu.\nmodule> ",stdout);fflush(stdout);if(!fgets(input,sizeof(input),stdin))return 0;NSString *answer=[[[NSString stringWithUTF8String:input] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];if([answer isEqual:@"q"]||[answer isEqual:@"quit"]||!answer.length)return 0;NSDictionary *item=TModuleChoice(answer,items);if(!item){message=[NSString stringWithFormat:@"[ NOT FOUND ] %@",answer];continue;}message=TPerformModuleAction(item,config);}
}

static NSDictionary *TModuleItemNamed(NSString *identifier) {for(NSDictionary *item in TModuleItems())if([item[@"id"] isEqual:identifier])return item;return nil;}

static int TRunEditorCLI(int argc,const char *argv[]) {
    NSDictionary *editors=@{@"vim":@[@"vim"],@"vi":@[@"vim"],@"nvim":@[@"nvim"],@"emacs":@[@"emacs",@"-nw"],@"nano":@[@"nano"],@"micro":@[@"micro"],@"hx":@[@"hx"],@"helix":@[@"hx"]};
    if(argc<3||!strcmp(argv[2],"list")){fputs("Terminal editors: vim, nvim, emacs, nano, micro, hx\nUsage: termatica editor <name> [file ...]\n",stdout);return argc<3?2:0;}
    NSString *name=[[NSString stringWithUTF8String:argv[2]] lowercaseString];NSArray<NSString *> *prefix=editors[name];if(!prefix){fprintf(stderr,"termatica: unsupported editor: %s\n",argv[2]);return 2;}
    NSUInteger extra=(NSUInteger)MAX(0,argc-3),count=prefix.count+extra;char **editorArgv=calloc(count+1,sizeof(char *));for(NSUInteger i=0;i<prefix.count;i++)editorArgv[i]=(char *)prefix[i].UTF8String;for(NSUInteger i=0;i<extra;i++)editorArgv[prefix.count+i]=(char *)argv[3+i];editorArgv[count]=NULL;execvp(editorArgv[0],editorArgv);fprintf(stderr,"termatica: %s is not installed or not in PATH\n",editorArgv[0]);free(editorArgv);return 127;
}

static int TRunCLI(int argc, const char *argv[]) {
    NSString *arg=argc>1?[NSString stringWithUTF8String:argv[1]]:@"--help";
    if([arg isEqual:@"--help"]||[arg isEqual:@"-h"]||[arg isEqual:@"help"]){
        fputs("Termatica 0.3.2\n\nUSAGE\n  termatica <command> [arguments]\n\nTERMINAL COMMANDS\n  plugins            Browse plugins with arrow keys\n  themes             Browse themes with arrow keys\n  configs            Manage portable saved configurations\n  install <id>       Install a built-in module\n  run <name> [text]  Run an installed extension command\n  editor <name> ...  Run Vim, Neovim, Emacs, Nano, Micro or Helix\n  reload             Reload config and installed extensions\n\nFILES AND MODES\n  config             Open editable config.json\n  config-path        Print the active config path for users and agents\n  config-dir         Open the Termatica data folder\n  plugins-dir        Open installed extensions\n  themes-dir         Open installed themes\n  skeleterm          Apply minimum-memory mode\n\nFLAGS\n  --help             Show this guide\n  --version          Print the version\n\nLong commands also accept their legacy --command spelling.\n",stdout);return 0;
    }
    if([arg isEqual:@"--version"]||[arg isEqual:@"version"]){fputs("Termatica 0.3.2\n",stdout);return 0;}
    if([arg isEqual:@"editor"]||[arg isEqual:@"--editor"]||[arg isEqual:@"edit"]||[arg isEqual:@"--edit"])return TRunEditorCLI(argc,argv);
    if([arg isEqual:@"run"]||[arg isEqual:@"--run"]){if(argc<3){fputs("termatica: run requires an extension command name\n",stderr);return 2;}NSMutableArray *parts=[NSMutableArray array];for(int i=3;i<argc;i++)[parts addObject:[NSString stringWithUTF8String:argv[i]]];BOOL sent=TPostCLIRequest(@{@"command":@"run",@"name":[NSString stringWithUTF8String:argv[2]],@"query":[parts componentsJoinedByString:@" "]});if(!sent){fputs("termatica: the Termatica app is not running\n",stderr);return 1;}return 0;}
    TConfig *config=[TConfig new];
    if([arg isEqual:@"--configs"]||[arg isEqual:@"configs"])return TRunConfigsCLI(argc,argv,config);
    if([arg isEqual:@"--config-path"]||[arg isEqual:@"config-path"]){fprintf(stdout,"%s\n",config.path.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--config"]||[arg isEqual:@"--settings"]||[arg isEqual:@"config"]||[arg isEqual:@"settings"]){[config ensureEditableFile];TOpenPath(config.path);fprintf(stdout,"opened %s\n",config.path.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--config-dir"]||[arg isEqual:@"config-dir"]){NSString *p=TEnsureDirectory(nil);TOpenPath(p);fprintf(stdout,"opened %s\n",p.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--plugins-dir"]||[arg isEqual:@"plugins-dir"]){NSString *p=TEnsureDirectory(@"extensions");TOpenPath(p);fprintf(stdout,"opened %s\n",p.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--themes-dir"]||[arg isEqual:@"themes-dir"]){NSString *p=TEnsureDirectory(@"themes");TOpenPath(p);fprintf(stdout,"opened %s\n",p.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--skeleterm"]||[arg isEqual:@"skeleterm"]){[config applySkeleterm];TPostCLICommand(@"reload");fputs("skeleterm applied: 300-line history, effects and extension processes disabled\n",stdout);return 0;}
    if([arg isEqual:@"--reload"]||[arg isEqual:@"reload"]){TPostCLICommand(@"reload");fputs("reload requested\n",stdout);return 0;}
    if([arg isEqual:@"--plugins"]||[arg isEqual:@"plugins"])return TRunModuleBrowser(@"plugins",config);
    if([arg isEqual:@"--themes"]||[arg isEqual:@"themes"])return TRunModuleBrowser(@"themes",config);
    if([arg isEqual:@"--install"]||[arg isEqual:@"install"]){if(argc<3){fputs("termatica: install requires a module id\n",stderr);return 2;}NSString *identifier=[[NSString stringWithUTF8String:argv[2]] lowercaseString];NSDictionary *item=TModuleItemNamed(identifier);if(!item){fprintf(stderr,"termatica: module not found: %s\n",identifier.UTF8String);return 2;}NSError *error=nil;if(!TInstallModule(item,config,&error)){fprintf(stderr,"termatica: install failed: %s\n",(error.localizedDescription?:@"unknown error").UTF8String);return 1;}TPostCLICommand(@"reload");fprintf(stdout,"installed %s\n",identifier.UTF8String);return 0;}
    fprintf(stderr,"termatica: unknown command: %s\nRun 'termatica --help'.\n",arg.UTF8String);return 2;
}

typedef struct {
    uint32_t ch:24;
    uint32_t flags:8;
    uint32_t fg;
    uint32_t bg;
} TCell;
_Static_assert(sizeof(TCell)==12,"terminal cells must remain compact");

enum { TBold = 1, TItalic = 2, TUnderline = 4, TInverse = 8 };
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
@property (copy) void (^redrawRequested)(void);
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
- (NSString *)sessionTextWithMaximumLines:(NSUInteger)maximumLines;
- (void)restoreSessionText:(NSString *)text;
- (NSString *)workingDirectory;
@end

static NSMutableArray<TTerminalView *> *TTerminalDrainQueue;
static BOOL TTerminalDrainScheduled;
static void TScheduleTerminalDrain(TTerminalView *terminal) {
    if(!terminal)return;if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TScheduleTerminalDrain(terminal);});return;}
    if(!TTerminalDrainQueue)TTerminalDrainQueue=[NSMutableArray array];if(![TTerminalDrainQueue containsObject:terminal])[TTerminalDrainQueue addObject:terminal];if(TTerminalDrainScheduled)return;TTerminalDrainScheduled=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_MSEC),dispatch_get_main_queue(),^{TTerminalDrainScheduled=NO;if(!TTerminalDrainQueue.count)return;TTerminalView *next=TTerminalDrainQueue.firstObject;[TTerminalDrainQueue removeObjectAtIndex:0];[next drainPendingData];});
}

@implementation TTerminalView {
    int _master;
    pid_t _pid;
    dispatch_source_t _readSource;
    TCell *_cells;
    NSUInteger _rowOffset;
    NSUInteger _cols, _rows, _cursorX, _cursorY, _savedX, _savedY;
    NSUInteger _scrollTop, _scrollBottom;
    NSMutableArray<NSData *> *_history;
    NSUInteger _historyStart;
    NSMutableData *_scratchLine;
    NSMutableData *_pendingData;
    NSUInteger _pendingOffset;
    BOOL _drainScheduled;
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
    BOOL _accessibilityUpdatePending;
    uint32_t _utf8Code;
    int _utf8Needed;
    NSPoint _selectionStart, _selectionEnd;
    BOOL _selecting, _hasSelection, _tileDragging;
}

- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config {
    if ((self = [super initWithFrame:frame])) {
        _config = config; _master = -1; _pid = -1; _history = [NSMutableArray array];_scratchLine=[NSMutableData data];_pendingData=[NSMutableData data];
        _osc = [NSMutableString string];_attributeCache=[NSMutableDictionary dictionary];_parseState = TParseText; _cursorVisible = YES;
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
- (void)setNeedsDisplay:(BOOL)flag {if(flag&&self.tiledRendering){if(self.redrawRequested)self.redrawRequested();return;}[super setNeedsDisplay:flag];if(flag&&self.redrawRequested)self.redrawRequested();}
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
    _cells = next; _cols = cols; _rows = rows; _rowOffset=0;
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
    struct winsize ws = { .ws_row=(unsigned short)_rows, .ws_col=(unsigned short)_cols };
    _pid = forkpty(&_master, NULL, NULL, &ws);
    if (_pid < 0) { TLog(@"forkpty failed: %s", strerror(errno)); return NO; }
    if (_pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("CLICOLOR", "1", 0);
        setenv("LSCOLORS", "Gxfxcxdxbxegedabagacad", 0);
        setenv("TERM_PROGRAM", "Termatica", 1);
        setenv("TERM_PROGRAM_VERSION", "0.3.2", 1);
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
            uint8_t buffer[32768];
            ssize_t n = read(self->_master, buffer, sizeof(buffer));
            if (n > 0) {
                BOOL schedule=NO;@synchronized(self){[self->_pendingData appendBytes:buffer length:(NSUInteger)n];NSUInteger queued=self->_pendingData.length-self->_pendingOffset;if(queued>=524288&&!self->_readPaused&&self->_readSource==source){self->_readPaused=YES;dispatch_suspend(source);if(!self->_backpressureReported){self->_backpressureReported=YES;TLog(@"PTY backpressure active at %lu queued bytes",(unsigned long)queued);}}if(!self->_drainScheduled){self->_drainScheduled=YES;schedule=YES;}}
                if(schedule)TScheduleTerminalDrain(self);
            } else if (n == 0) {TLog(@"shell pty reached EOF");[self stopShellTerminating:NO];}
            else if (errno != EAGAIN) {TLog(@"pty read failed: %s", strerror(errno));[self stopShellTerminating:YES];}
        }
    });
    dispatch_source_set_cancel_handler(source, ^{});
    dispatch_resume(source);
    return YES;
}
- (void)stopShellTerminating:(BOOL)terminate {dispatch_source_t source=nil;@synchronized(self){source=_readSource;_readSource=nil;if(source&&_readPaused){_readPaused=NO;dispatch_resume(source);}}if(source)dispatch_source_cancel(source);int master=_master;_master=-1;if(master>=0)close(master);pid_t child=_pid;_pid=-1;if(child>0){if(terminate)kill(child,SIGHUP);dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{int status=0;while(waitpid(child,&status,0)<0&&errno==EINTR){}});}}
- (void)drainPendingData {
    NSData *chunk=nil;BOOL more=NO;dispatch_source_t resumeSource=nil;
    @synchronized(self){
        NSUInteger available=_pendingData.length-_pendingOffset,take=MIN((NSUInteger)8192,available);
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
    if (_master < 0 || !length) return;
    const uint8_t *p = bytes;
    while (length) {
        ssize_t n = write(_master, p, length);
        if (n <= 0) break;
        p += n; length -= (NSUInteger)n;
    }
}
- (void)sendString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    [self sendBytes:data.bytes length:data.length];
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
        if (b == '[') { _parseState = TParseCSI; memset(_params, 0, sizeof(_params)); _paramIndex = 0; _privateCSI = NO; }
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
        if (b == '?' || b == '>') { _privateCSI = YES; return; }
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
- (void)putCodepoint:(uint32_t)cp {
    if (_cursorX >= _cols) { _cursorX = 0; [self lineFeed]; }
    TCell *c = [self cellsForRow:_cursorY]+_cursorX;
    c->ch = cp; c->fg = _currentFG; c->bg = _currentBG; c->flags = _currentFlags;
    _cursorX++;
}
- (void)lineFeed {
    if (_cursorY == _scrollBottom) [self scrollUp];
    else _cursorY = MIN(_rows - 1, _cursorY + 1);
}
- (void)scrollUp {
    if (_scrollTop == 0 && _scrollBottom == _rows - 1) {
        TCell *top=[self cellsForRow:0];NSUInteger used=_cols;TCell blank=[self blankCell];while(used){TCell cell=top[used-1];if(cell.ch!=blank.ch||cell.flags!=blank.flags||cell.fg!=blank.fg||cell.bg!=blank.bg)break;used--;}
        [self addHistoryLine:[NSData dataWithBytes:top length:used*sizeof(TCell)]];
        _rowOffset=(_rowOffset+1)%_rows;TCell *bottom=[self cellsForRow:_rows-1];for(NSUInteger x=0;x<_cols;x++)bottom[x]=blank;return;
    }
    [self normalizeRows];
    memmove(_cells + _scrollTop * _cols, _cells + (_scrollTop + 1) * _cols, (_scrollBottom - _scrollTop) * _cols * sizeof(TCell));
    TCell blank = [self blankCell];
    for (NSUInteger x=0; x<_cols; x++) _cells[_scrollBottom*_cols+x]=blank;
}
- (void)reverseIndex {
    if (_cursorY > _scrollTop) { _cursorY--; return; }
    if(_scrollTop==0&&_scrollBottom==_rows-1){_rowOffset=(_rowOffset+_rows-1)%_rows;TCell blank=[self blankCell],*top=[self cellsForRow:0];for(NSUInteger x=0;x<_cols;x++)top[x]=blank;return;}
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
    } else if ([_osc hasPrefix:@"7;file://"]) {
        NSString *urlString=[_osc substringFromIndex:2]; NSURL *url=[NSURL URLWithString:urlString];
        if(url.path.length && self.cwdChanged)self.cwdChanged(url.path);
    }
    [_osc setString:@""];
}
- (void)resetTerminal { _currentFG=_currentBG=TDefaultColor; _currentFlags=0; _cursorX=_cursorY=0; _scrollTop=0; _scrollBottom=_rows-1; [self eraseDisplay:2]; }
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
- (NSString *)stringForCodepoint:(uint32_t)cp {if(cp<=0xFFFF)return [NSString stringWithCharacters:(unichar[]){(unichar)(cp?:' ')} length:1];uint32_t v=cp-0x10000;unichar pair[2]={(unichar)(0xD800+(v>>10)),(unichar)(0xDC00+(v&0x3FF))};return [NSString stringWithCharacters:pair length:2];}
- (void)refreshTextView {
    [self setNeedsDisplay:YES];
}
- (NSDictionary *)textAttributesForForeground:(uint32_t)foreground flags:(uint8_t)flags shadow:(NSShadow *)shadow {NSNumber *key=@((foreground<<8)|flags);NSDictionary *cached=_attributeCache[key];if(cached)return cached;NSFont *font=(flags&TBold)?_boldFont:((flags&TItalic)?_italicFont:_font);NSMutableDictionary *attrs=[@{NSFontAttributeName:font,NSForegroundColorAttributeName:TColor(foreground)} mutableCopy];if(shadow)attrs[NSShadowAttributeName]=shadow;if(flags&TUnderline)attrs[NSUnderlineStyleAttributeName]=@(NSUnderlineStyleSingle);if(_attributeCache.count>=128)[_attributeCache removeAllObjects];_attributeCache[key]=attrs;return attrs;}
- (void)drawRect:(NSRect)dirtyRect {
    [self.config.background setFill];NSRectFill(dirtyRect);CGFloat pad=self.config.padding+self.leadingOverlayInset,top=self.config.padding+self.safeAreaInsets.top;NSShadow *phosphor=nil;if(self.config.glow>0){phosphor=[NSShadow new];phosphor.shadowColor=[self.config.accent colorWithAlphaComponent:self.config.glow];phosphor.shadowBlurRadius=1+self.config.glow*3;phosphor.shadowOffset=NSZeroSize;}
    for(NSUInteger y=0;y<_rows;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:(NSInteger)y temporary:&hold];if(!line)continue;for(NSUInteger x=0;x<_cols;x++){TCell c=line[x];if(c.ch==' '&&!([self cellSelectedX:x y:y])&&c.bg==TDefaultColor)continue;uint32_t fg=c.fg==TDefaultColor?TRGB(self.config.foreground):c.fg,bg=c.bg==TDefaultColor?TRGB(self.config.background):c.bg;if(c.flags&TInverse){uint32_t t=fg;fg=bg;bg=t;}NSRect cell=NSMakeRect(pad+x*_cellWidth,top+y*_cellHeight,_cellWidth,_cellHeight);if([self cellSelectedX:x y:y]){[self.config.selection setFill];NSRectFill(cell);}else if(c.bg!=TDefaultColor){[TColor(bg) setFill];NSRectFill(cell);}if(c.ch!=' '&&c.ch){NSDictionary *attrs=[self textAttributesForForeground:fg flags:(uint8_t)c.flags shadow:phosphor];[[self stringForCodepoint:c.ch] drawInRect:NSMakeRect(cell.origin.x,cell.origin.y,_cellWidth+2,_cellHeight) withAttributes:attrs];}}}
    if(_cursorVisible&&_historyOffset==0&&(self.window.firstResponder==self||self.activeTerminal)){BOOL block=![self.config.cursorStyle isEqual:@"bar"]&&![self.config.cursorStyle isEqual:@"underline"];[[self.config.cursor colorWithAlphaComponent:block?0.42:0.96]setFill];NSRect r=NSMakeRect(pad+_cursorX*_cellWidth,top+_cursorY*_cellHeight,_cellWidth,_cellHeight);if([self.config.cursorStyle isEqual:@"bar"])r.size.width=2;else if([self.config.cursorStyle isEqual:@"underline"]){r.origin.y+=_cellHeight-2;r.size.height=2;}NSRectFillUsingOperation(r,NSCompositingOperationSourceOver);}
    if(self.config.scanlines>0){[[NSColor colorWithWhite:0 alpha:self.config.scanlines*0.10]setFill];for(CGFloat y=2;y<self.bounds.size.height;y+=4)NSRectFillUsingOperation(NSMakeRect(0,y,self.bounds.size.width,1),NSCompositingOperationSourceOver);}
    if(self.config.vignette>0&&!self.tiledRendering){for(NSUInteger i=0;i<6;i++){[[NSColor colorWithWhite:0 alpha:self.config.vignette*(6-i)/30.0]setStroke];NSBezierPath *p=[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds,i+0.5,i+0.5)];[p stroke];}}
}
- (NSPoint)cellForPoint:(NSPoint)p { NSInteger x=floor((p.x-self.config.padding-self.leadingOverlayInset)/_cellWidth),y=floor((p.y-self.config.padding-self.safeAreaInsets.top)/_cellHeight); return NSMakePoint(MAX(0,MIN((NSInteger)_cols-1,x)),MAX(0,MIN((NSInteger)_rows-1,y))); }
- (void)mouseDown:(NSEvent *)event {
    if(self.focused)self.focused();
    [self.window makeFirstResponder:self];
    NSPoint local=[self convertPoint:event.locationInWindow fromView:nil];
    BOOL commandDrag=(event.modifierFlags&NSEventModifierFlagCommand)!=0;
    BOOL paddingDrag=local.y<=MAX(10,self.config.padding);
    if(self.tiledRendering&&(commandDrag||paddingDrag)&&self.tileDragBegan){_tileDragging=YES;_selecting=NO;_hasSelection=NO;self.tileDragBegan(self,event);return;}
    _selectionStart=_selectionEnd=[self cellForPoint:local];_selecting=YES;_hasSelection=NO;[self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)event {if(_tileDragging){if(self.tileDragMoved)self.tileDragMoved(self,event);return;}if(!_selecting)return;_selectionEnd=[self cellForPoint:[self convertPoint:event.locationInWindow fromView:nil]];_hasSelection=YES;[self setNeedsDisplay:YES];}
- (void)mouseUp:(NSEvent *)event {if(_tileDragging){_tileDragging=NO;if(self.tileDragEnded)self.tileDragEnded(self,event);return;}_selecting=NO;}
- (void)scrollWheel:(NSEvent *)event { NSInteger delta=(NSInteger)llround(event.scrollingDeltaY/3.0); _historyOffset=MAX(0,MIN((NSInteger)_history.count,_historyOffset+delta));[self refreshTextView];[self setNeedsDisplay:YES]; }
- (NSString *)selectedText {
    if(!_hasSelection)return @"";NSInteger a=(NSInteger)_selectionStart.y*(NSInteger)_cols+(NSInteger)_selectionStart.x,b=(NSInteger)_selectionEnd.y*(NSInteger)_cols+(NSInteger)_selectionEnd.x;if(a>b){NSInteger t=a;a=b;b=t;}NSMutableString *s=[NSMutableString string];NSInteger firstRow=a/(NSInteger)_cols,lastRow=b/(NSInteger)_cols;for(NSInteger y=firstRow;y<=lastRow;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:y temporary:&hold];NSInteger x0=y==firstRow?a%(NSInteger)_cols:0,x1=y==lastRow?b%(NSInteger)_cols:(NSInteger)_cols-1;NSMutableString *row=[NSMutableString string];for(NSInteger x=x0;x<=x1;x++)[row appendString:[self stringForCodepoint:line?line[x].ch:' ']];while([row hasSuffix:@" "])[row deleteCharactersInRange:NSMakeRange(row.length-1,1)];[s appendString:row];if(y<lastRow)[s appendString:@"\n"];}return s;
}
- (NSString *)visibleText {NSMutableArray *lines=[NSMutableArray array];for(NSUInteger y=0;y<_rows;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:(NSInteger)y temporary:&hold];NSMutableString *row=[NSMutableString string];for(NSUInteger x=0;x<_cols;x++)[row appendString:[self stringForCodepoint:line?line[x].ch:' ']];while([row hasSuffix:@" "])[row deleteCharactersInRange:NSMakeRange(row.length-1,1)];[lines addObject:row];}while(lines.count&&[lines.lastObject length]==0)[lines removeLastObject];return [lines componentsJoinedByString:@"\n"];}
- (NSString *)sessionTextWithMaximumLines:(NSUInteger)maximumLines {
    NSUInteger total=_history.count+_rows,first=total>maximumLines?total-maximumLines:0;NSMutableArray<NSString *> *lines=[NSMutableArray arrayWithCapacity:MIN(total,maximumLines)];
    for(NSUInteger logical=first;logical<total;logical++){const TCell *cells=NULL;NSUInteger count=_cols;NSData *hold=nil;if(logical<_history.count){hold=[self historyLineAtIndex:logical];cells=hold.bytes;count=MIN(_cols,hold.length/sizeof(TCell));}else cells=[self cellsForRow:logical-_history.count];NSMutableString *line=[NSMutableString string];for(NSUInteger x=0;x<count;x++)[line appendString:[self stringForCodepoint:cells?cells[x].ch:' ']];while([line hasSuffix:@" "])[line deleteCharactersInRange:NSMakeRange(line.length-1,1)];[lines addObject:line];}
    while(lines.count&&[lines.lastObject length]==0)[lines removeLastObject];return [lines componentsJoinedByString:@"\n"];
}
- (void)restoreSessionText:(NSString *)text {
    if(![text isKindOfClass:NSString.class]||!text.length)return;[self clearHistory];[self eraseDisplay:2];_cursorX=_cursorY=0;_currentFG=_currentBG=TDefaultColor;_currentFlags=0;
    for(NSString *line in [text componentsSeparatedByString:@"\n"]){NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];const uint8_t *bytes=data.bytes;for(NSUInteger i=0;i<data.length;i++)[self consumeByte:bytes[i]];[self consumeByte:'\r'];[self consumeByte:'\n'];}
    _historyOffset=0;[self refreshTextView];[self setNeedsDisplay:YES];
}
- (void)copy:(id)sender {NSString *s=[self selectedText];if(s.length){[NSPasteboard.generalPasteboard clearContents];[NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];}}
- (void)paste:(id)sender { NSString *s=[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];if(!s.length)return;if(_bracketedPaste)[self sendString:[NSString stringWithFormat:@"\033[200~%@\033[201~",s]];else[self sendString:s]; }
- (void)selectAll:(id)sender {_selectionStart=NSMakePoint(0,0);_selectionEnd=NSMakePoint(_cols-1,_rows-1);_hasSelection=YES;[self setNeedsDisplay:YES];}
- (void)keyDown:(NSEvent *)e {
    if(e.modifierFlags&NSEventModifierFlagCommand){[super keyDown:e];return;}
    NSString *s=nil; unsigned short k=e.keyCode;NSEventModifierFlags mods=e.modifierFlags&NSEventModifierFlagDeviceIndependentFlagsMask;NSInteger modifier=1+((mods&NSEventModifierFlagShift)?1:0)+((mods&NSEventModifierFlagOption)?2:0)+((mods&NSEventModifierFlagControl)?4:0);
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

@interface THyprlandCanvasView : NSView
@property NSArray<TTerminalView *> *terminals;
@property(weak) TTerminalView *activeTerminal;
@property(weak) TConfig *config;
@property NSDictionary<NSValue *,NSValue *> *frameOverrides;
@property NSDictionary<NSValue *,NSNumber *> *opacityOverrides;
@property TTerminalView *exitingTerminal;
@property NSRect exitingFrame;
@property CGFloat exitingAlpha;
- (void)requestRedrawForTerminal:(TTerminalView *)terminal;
@end

@implementation THyprlandCanvasView {__weak TTerminalView *_mouseTerminal;NSHashTable<TTerminalView *> *_dirtyTerminals;BOOL _redrawScheduled;}
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)acceptsFirstMouse:(NSEvent *)event{return YES;}
- (BOOL)isFlipped{return YES;}
- (BOOL)isOpaque{return NO;}
- (NSRect)canvasFrameForTerminal:(TTerminalView *)terminal {NSValue *override=self.frameOverrides[[NSValue valueWithNonretainedObject:terminal]];NSRect frame=override?override.rectValue:terminal.frame;frame.origin.y=NSHeight(self.bounds)-NSMaxY(frame);return frame;}
- (void)requestRedrawForTerminal:(TTerminalView *)terminal {if(!terminal)return;if(!_dirtyTerminals)_dirtyTerminals=[NSHashTable weakObjectsHashTable];[_dirtyTerminals addObject:terminal];if(_redrawScheduled)return;_redrawScheduled=YES;__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,33*NSEC_PER_MSEC),dispatch_get_main_queue(),^{__strong typeof(weakSelf) self=weakSelf;if(!self)return;NSArray *dirty=self->_dirtyTerminals.allObjects;[self->_dirtyTerminals removeAllObjects];self->_redrawScheduled=NO;for(TTerminalView *item in dirty)[self setNeedsDisplayInRect:NSInsetRect([self canvasFrameForTerminal:item],-1,-1)];});}
- (TTerminalView *)terminalAtEvent:(NSEvent *)event {NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];for(TTerminalView *terminal in self.terminals.reverseObjectEnumerator)if(NSPointInRect(point,[self canvasFrameForTerminal:terminal]))return terminal;return nil;}
- (void)drawTerminal:(TTerminalView *)terminal frame:(NSRect)frame alpha:(CGFloat)alpha {if(!terminal||alpha<=0||![self needsToDrawRect:frame])return;[NSGraphicsContext saveGraphicsState];CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext,alpha);[[NSBezierPath bezierPathWithRoundedRect:frame xRadius:12 yRadius:12]addClip];NSAffineTransform *transform=[NSAffineTransform transform];[transform translateXBy:NSMinX(frame) yBy:NSMinY(frame)];CGFloat sx=NSWidth(frame)/MAX(1,NSWidth(terminal.bounds)),sy=NSHeight(frame)/MAX(1,NSHeight(terminal.bounds));[transform scaleXBy:sx yBy:sy];[transform concat];[terminal drawRect:terminal.bounds];[NSGraphicsContext restoreGraphicsState];}
- (void)drawRect:(NSRect)dirtyRect {[[NSColor clearColor]setFill];NSRectFillUsingOperation(dirtyRect,NSCompositingOperationCopy);for(TTerminalView *terminal in self.terminals){NSValue *key=[NSValue valueWithNonretainedObject:terminal];[self drawTerminal:terminal frame:[self canvasFrameForTerminal:terminal] alpha:self.opacityOverrides[key]?self.opacityOverrides[key].doubleValue:1];}if(self.exitingTerminal){NSRect frame=self.exitingFrame;frame.origin.y=NSHeight(self.bounds)-NSMaxY(frame);[self drawTerminal:self.exitingTerminal frame:frame alpha:self.exitingAlpha];}}
- (void)mouseDown:(NSEvent *)event {_mouseTerminal=[self terminalAtEvent:event];[_mouseTerminal mouseDown:event];}
- (void)mouseDragged:(NSEvent *)event {[_mouseTerminal mouseDragged:event];[self setNeedsDisplay:YES];}
- (void)mouseUp:(NSEvent *)event {[_mouseTerminal mouseUp:event];_mouseTerminal=nil;[self setNeedsDisplay:YES];}
- (void)scrollWheel:(NSEvent *)event {TTerminalView *terminal=[self terminalAtEvent:event]?:self.activeTerminal;[terminal scrollWheel:event];}
- (void)keyDown:(NSEvent *)event {[self.activeTerminal keyDown:event];}
- (void)copy:(id)sender {[self.activeTerminal copy:sender];}
- (void)paste:(id)sender {[self.activeTerminal paste:sender];}
- (void)selectAll:(id)sender {[self.activeTerminal selectAll:sender];}
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
        if([self.config.disabledPlugins containsObject:name]){TLog(@"plugin %@ disabled",name);continue;}
        NSString *root = [self.directory stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"extension.json"]];
        if (!data) continue;
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *entry = manifest[@"entry"];
        NSString *identifier = manifest[@"id"] ?: name;
        if (!entry.length) continue;
        NSArray *builtIn=TBuiltInCommands(name);if(builtIn.count||[name isEqual:@"hyprland-layout"]){for(NSDictionary *definition in builtIn){NSMutableDictionary *command=[definition mutableCopy];command[@"extension"]=identifier;[_commands addObject:command];}TLog(@"plugin %@ loaded declaratively without a helper process",name);continue;}
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
                         @"params":@{@"protocolVersion":@1, @"appVersion":@"0.3.2"}} to:identifier];
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
- (NSDictionary *)sessionDictionary;
- (BOOL)restoreSessionDictionary:(NSDictionary *)session;
- (BOOL)executeExtensionNamed:(NSString *)name query:(NSString *)query;
@end

@implementation TWindowController { NSString *_cwd; NSView *_root; NSVisualEffectView *_effect; THyprlandCanvasView *_canvas; TTabRailView *_tabRail; TTabEdgeView *_tabEdge; NSMutableArray<TTabButton *> *_tabButtons; BOOL _animateTabLayout; BOOL _hyprlandApplied; NSRect _preHyprlandFrame; TTerminalView *_draggingTerminal; NSPoint _dragOffset; NSTimer *_tileAnimationTimer; CFTimeInterval _tileAnimationStarted; NSArray<NSValue *> *_tileAnimationFrom; NSArray<NSValue *> *_tileAnimationTo; TTerminalView *_enteringTerminal; TTerminalView *_closingTerminal; NSRect _closingTileFrom; NSRect _closingTileTo; NSTimer *_tabHideTimer; NSTrackingArea *_tabHoverArea; NSRect _tabRailTargetFrame; BOOL _tabRailVisible; BOOL _mouseInTabArea; BOOL _revealRailAfterLayout; }
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions {
    return [self initWithConfig:config extensions:extensions session:nil];
}
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions session:(NSDictionary *)session {
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,920,600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){_config=config;_extensions=extensions;_terminals=[NSMutableArray array];_tabButtons=[NSMutableArray array];window.delegate=(id)self;window.title=@"Termatica";window.titleVisibility=NSWindowTitleHidden;window.titlebarAppearsTransparent=YES;window.styleMask|=NSWindowStyleMaskFullSizeContentView;window.minSize=NSMakeSize(480,280);window.tabbingMode=NSWindowTabbingModeDisallowed;window.movableByWindowBackground=NO;[window center];
        _root=[[NSView alloc]initWithFrame:window.contentView.bounds];_root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;window.contentView=_root;
        _canvas=[[THyprlandCanvasView alloc]initWithFrame:_root.bounds];_canvas.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;_canvas.config=config;_canvas.hidden=YES;[_root addSubview:_canvas];
        _tabRail=[[TTabRailView alloc]initWithFrame:NSZeroRect];_tabRail.config=config;[_root addSubview:_tabRail];
        _tabEdge=[[TTabEdgeView alloc]initWithFrame:NSZeroRect];_tabEdge.config=config;_tabEdge.hidden=YES;_tabEdge.alphaValue=0;[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];
        if(![self restoreSessionDictionary:session]){[self applyAppearance];[self addTab];}
    }return self;
}
- (BOOL)hasVerticalSplit {for(TTerminalView *terminal in _terminals)if(terminal.verticalSplit)return YES;return NO;}
- (BOOL)usesTiledLayout {return _terminals.count>1&&(self.config.hyprlandLayout||[self hasVerticalSplit]);}
- (CFTimeInterval)animationDuration:(CFTimeInterval)duration {return duration/MAX(0.25,self.config.animationSpeed);}
- (void)updateTerminalTabInsets {BOOL tiled=[self usesTiledLayout]||_closingTerminal!=nil;for(TTerminalView *terminal in _terminals){CGFloat inset=0;if(tiled&&_tabRailVisible&&NSIntersectsRect(terminal.frame,_tabRailTargetFrame))inset=self.config.tabRailWidth+12;else if(!tiled&&_terminals.count>1)inset=_tabRailVisible?self.config.tabRailWidth+12:10;if(terminal.leadingOverlayInset!=inset){terminal.leadingOverlayInset=inset;[terminal resizeGrid];[terminal setNeedsDisplay:YES];}}}
- (void)updateTabHoverArea {
    if(_tabHoverArea){[_root removeTrackingArea:_tabHoverArea];_tabHoverArea=nil;}if(_terminals.count<2)return;
    NSRect edge=NSMakeRect(0,NSMaxY(_tabRailTargetFrame)-26,10,26);_tabEdge.frame=edge;NSRect hover=NSUnionRect(_tabRailTargetFrame,edge);hover=NSInsetRect(hover,-6,-6);_tabHoverArea=[[NSTrackingArea alloc]initWithRect:hover options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow owner:self userInfo:nil];[_root addTrackingArea:_tabHoverArea];
}
- (void)scheduleTabRailHide {
    [_tabHideTimer invalidate];_tabHideTimer=nil;if(!self.config.tabAutoHide||!_tabRailVisible||_terminals.count<2)return;__weak typeof(self) weakSelf=self;_tabHideTimer=[NSTimer timerWithTimeInterval:self.config.tabHideDelay repeats:NO block:^(NSTimer *timer){__strong typeof(weakSelf) self=weakSelf;if(self)[self hideTabRail];}];[NSRunLoop.mainRunLoop addTimer:_tabHideTimer forMode:NSRunLoopCommonModes];
}
- (void)revealTabRail {
    if(_terminals.count<2||NSIsEmptyRect(_tabRailTargetFrame))return;[_tabHideTimer invalidate];_tabHideTimer=nil;BOOL wasVisible=_tabRailVisible;_tabRailVisible=YES;[self updateTerminalTabInsets];NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+7;_tabRail.hidden=NO;if(!wasVisible){_tabRail.frame=collapsed;_tabRail.alphaValue=0;}_tabEdge.hidden=NO;CAMediaTimingFunction *settle=[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f];[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=self.config.tabAnimations?[self animationDuration:0.24]:0;context.timingFunction=settle;_tabRail.animator.frame=_tabRailTargetFrame;_tabRail.animator.alphaValue=1;_tabEdge.animator.alphaValue=0;} completionHandler:^{if(self->_tabRailVisible)self->_tabEdge.hidden=YES;}];[self scheduleTabRailHide];
}
- (void)hideTabRail {
    if(!_tabRailVisible||_terminals.count<2)return;if(_mouseInTabArea){[self scheduleTabRailHide];return;}[_tabHideTimer invalidate];_tabHideTimer=nil;_tabRailVisible=NO;NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+7;_tabEdge.hidden=NO;_tabEdge.alphaValue=0;CAMediaTimingFunction *settle=[CAMediaTimingFunction functionWithControlPoints:0.16f :1.0f :0.3f :1.0f];[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=self.config.tabAnimations?[self animationDuration:0.24]:0;context.timingFunction=settle;_tabRail.animator.frame=collapsed;_tabRail.animator.alphaValue=0;_tabEdge.animator.alphaValue=0.68;} completionHandler:^{if(!self->_tabRailVisible){self->_tabRail.hidden=YES;[self updateTerminalTabInsets];}}];
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
    for(TTerminalView *terminal in _terminals)CGPathAddRect(path,NULL,NSRectToCGRect(terminal.frame));
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
    TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:NSZeroRect config:self.config];terminal.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;__weak typeof(self) weakSelf=self;__weak TTerminalView *weakTerminal=terminal;terminal.titleChanged=^(NSString *title){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self.window.title=title.length?title:@"Termatica";};terminal.cwdChanged=^(NSString *cwd){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self->_cwd=cwd;};terminal.focused=^{__strong typeof(weakSelf) self=weakSelf;if(self&&weakTerminal)[self focusTerminal:weakTerminal];};terminal.tileDragBegan=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self beginDraggingTerminal:tile event:event];};terminal.tileDragMoved=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self dragTerminal:tile event:event];};terminal.tileDragEnded=^(TTerminalView *tile,NSEvent *event){__strong typeof(weakSelf) self=weakSelf;if(self)[self endDraggingTerminal:tile event:event];};terminal.redrawRequested=^{__strong typeof(weakSelf) self=weakSelf;if(self&&weakTerminal&&!self->_canvas.hidden)[self->_canvas requestRedrawForTerminal:weakTerminal];};terminal.accessibilityHelp=@"Command-drag, or drag from the top padding, to rearrange this Hyprland terminal.";return terminal;
}
- (BOOL)restoreSessionDictionary:(NSDictionary *)session {
    if(![session isKindOfClass:NSDictionary.class]||[session[@"version"] integerValue]!=1)return NO;NSArray *states=[session[@"terminals"] isKindOfClass:NSArray.class]?session[@"terminals"]:nil;if(!states.count||states.count>32)return NO;
    NSString *frameString=[session[@"windowFrame"] isKindOfClass:NSString.class]?session[@"windowFrame"]:nil;if(frameString.length){NSRect frame=NSRectFromString(frameString);if(frame.size.width>=480&&frame.size.height>=280)[self.window setFrame:frame display:NO];}
    for(NSDictionary *state in states){if(![state isKindOfClass:NSDictionary.class])continue;TTerminalView *terminal=[self newTerminal];terminal.verticalSplit=[state[@"verticalSplit"] boolValue];NSString *cwd=[state[@"cwd"] isKindOfClass:NSString.class]?state[@"cwd"]:nil;BOOL directory=NO;if(cwd.length&&[NSFileManager.defaultManager fileExistsAtPath:cwd isDirectory:&directory]&&directory)terminal.launchDirectory=cwd;[_terminals addObject:terminal];[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];}
    if(!_terminals.count)return NO;
    for(NSUInteger i=0;i<MIN(states.count,_terminals.count);i++){NSInteger anchor=[states[i][@"anchor"] integerValue];if(anchor>=0&&anchor<(NSInteger)_terminals.count&&anchor!=(NSInteger)i)_terminals[i].splitAnchor=_terminals[(NSUInteger)anchor];}
    NSUInteger active=MIN([session[@"active"] unsignedIntegerValue],_terminals.count-1);self.terminal=_terminals[active];self.extensions.activeTerminal=self.terminal;[self applyAppearance];
    for(NSUInteger i=0;i<MIN(states.count,_terminals.count);i++){NSString *text=[states[i][@"text"] isKindOfClass:NSString.class]?states[i][@"text"]:nil;if(text.length>1048576)text=[text substringFromIndex:text.length-1048576];[_terminals[i] restoreSessionText:text];[_terminals[i] startShell];}
    _cwd=[self.terminal workingDirectory];[self focusTerminal:self.terminal];TLog(@"restored %lu terminal sessions",(unsigned long)_terminals.count);return YES;
}
- (NSDictionary *)sessionDictionary {
    NSMutableArray *states=[NSMutableArray arrayWithCapacity:_terminals.count];for(TTerminalView *terminal in _terminals){NSUInteger anchor=terminal.splitAnchor?[_terminals indexOfObject:terminal.splitAnchor]:NSNotFound;[states addObject:@{@"cwd":[terminal workingDirectory]?:@"",@"text":[terminal sessionTextWithMaximumLines:self.config.sessionMaxLines]?:@"",@"verticalSplit":@(terminal.verticalSplit),@"anchor":anchor==NSNotFound?@(-1):@(anchor)}];}
    NSUInteger active=[_terminals indexOfObject:self.terminal];return @{@"version":@1,@"windowFrame":NSStringFromRect(self.window.frame),@"active":active==NSNotFound?@0:@(active),@"terminals":states};
}
- (void)focusTerminal:(TTerminalView *)terminal {if(!terminal||![_terminals containsObject:terminal])return;if(self.terminal!=terminal){self.terminal=terminal;_cwd=[terminal workingDirectory];[self rebuildTabs];[self layoutTabs];}for(TTerminalView *item in _terminals)item.activeTerminal=item==terminal;self.extensions.activeTerminal=terminal;_canvas.activeTerminal=terminal;[_canvas setNeedsDisplay:YES];[self.window makeFirstResponder:[self usesTiledLayout]?_canvas:terminal];}
- (void)animateNewTerminal:(TTerminalView *)terminal {
    if(!self.config.tabAnimations)return;CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];
    if(![self usesTiledLayout]){terminal.wantsLayer=YES;CABasicAnimation *scale=[CABasicAnimation animationWithKeyPath:@"transform.scale"];scale.fromValue=@0.975;scale.toValue=@1;scale.duration=[self animationDuration:0.13];scale.timingFunction=ease;[terminal.layer addAnimation:scale forKey:@"termatica.tab.pop"];CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];fade.fromValue=@0;fade.toValue=@1;fade.duration=[self animationDuration:0.08];fade.timingFunction=ease;[terminal.layer addAnimation:fade forKey:@"termatica.tab.fade"];__weak TTerminalView *weakTerminal=terminal;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self animationDuration:0.15]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[weakTerminal releaseAnimationLayer];});}
    if(_tabButtons.count>1){TTabButton *button=_tabButtons.lastObject,*previous=_tabButtons[_tabButtons.count-2];CABasicAnimation *move=[CABasicAnimation animationWithKeyPath:@"position"];move.fromValue=[NSValue valueWithPoint:previous.layer.position];move.toValue=[NSValue valueWithPoint:button.layer.position];move.duration=[self animationDuration:0.12];move.timingFunction=ease;[button.layer addAnimation:move forKey:@"termatica.bubble.move"];CABasicAnimation *bubble=[CABasicAnimation animationWithKeyPath:@"transform.scale"];bubble.fromValue=@0.78;bubble.toValue=@1;bubble.duration=[self animationDuration:0.11];bubble.timingFunction=ease;[button.layer addAnimation:bubble forKey:@"termatica.bubble.pop"];}
}
- (void)startTileAnimationFrom:(NSArray<NSValue *> *)fromFrames to:(NSArray<NSValue *> *)toFrames {
    [_tileAnimationTimer invalidate];_tileAnimationFrom=fromFrames;_tileAnimationTo=toFrames;_tileAnimationStarted=CACurrentMediaTime();NSMutableDictionary *initial=[NSMutableDictionary dictionaryWithCapacity:_terminals.count],*initialOpacity=[NSMutableDictionary dictionary];NSUInteger initialCount=MIN(_terminals.count,fromFrames.count);for(NSUInteger i=0;i<initialCount;i++)initial[[NSValue valueWithNonretainedObject:_terminals[i]]]=fromFrames[i];if(_enteringTerminal)initialOpacity[[NSValue valueWithNonretainedObject:_enteringTerminal]]=@0;_canvas.frameOverrides=initial;_canvas.opacityOverrides=initialOpacity;_canvas.exitingTerminal=_closingTerminal;_canvas.exitingFrame=_closingTileFrom;_canvas.exitingAlpha=_closingTerminal?1:0;[_canvas setNeedsDisplay:YES];CFTimeInterval duration=[self animationDuration:0.24];__weak typeof(self) weakSelf=self;
    _tileAnimationTimer=[NSTimer timerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer *timer){__strong typeof(weakSelf) self=weakSelf;if(!self){[timer invalidate];return;}CGFloat t=MIN(1,(CACurrentMediaTime()-self->_tileAnimationStarted)/duration),p=1-pow(1-t,5);NSMutableDictionary *overrides=[NSMutableDictionary dictionaryWithCapacity:self->_terminals.count],*opacities=[NSMutableDictionary dictionary];NSUInteger count=MIN(self->_terminals.count,MIN(self->_tileAnimationFrom.count,self->_tileAnimationTo.count));for(NSUInteger i=0;i<count;i++){NSRect a=self->_tileAnimationFrom[i].rectValue,b=self->_tileAnimationTo[i].rectValue,r=NSMakeRect(a.origin.x+(b.origin.x-a.origin.x)*p,a.origin.y+(b.origin.y-a.origin.y)*p,a.size.width+(b.size.width-a.size.width)*p,a.size.height+(b.size.height-a.size.height)*p);overrides[[NSValue valueWithNonretainedObject:self->_terminals[i]]]=[NSValue valueWithRect:r];}if(self->_enteringTerminal)opacities[[NSValue valueWithNonretainedObject:self->_enteringTerminal]]=@(MIN(1,t*1.7));if(self->_closingTerminal){NSRect a=self->_closingTileFrom,b=self->_closingTileTo;self->_canvas.exitingFrame=NSMakeRect(a.origin.x+(b.origin.x-a.origin.x)*p,a.origin.y+(b.origin.y-a.origin.y)*p,a.size.width+(b.size.width-a.size.width)*p,a.size.height+(b.size.height-a.size.height)*p);self->_canvas.exitingAlpha=pow(1-t,1.35);}self->_canvas.frameOverrides=overrides;self->_canvas.opacityOverrides=opacities;[self->_canvas setNeedsDisplay:YES];if(t>=1){[timer invalidate];self->_tileAnimationTimer=nil;TTerminalView *closed=self->_closingTerminal;self->_closingTerminal=nil;self->_enteringTerminal=nil;self->_canvas.frameOverrides=nil;self->_canvas.opacityOverrides=nil;self->_canvas.exitingTerminal=nil;self->_canvas.exitingAlpha=0;if(closed)[closed stopShellTerminating:YES];[self layoutTabs];[self->_canvas setNeedsDisplay:YES];}}];[NSRunLoop.mainRunLoop addTimer:_tileAnimationTimer forMode:NSRunLoopCommonModes];
}
- (void)addTabWithVerticalSplit:(BOOL)verticalSplit {BOOL animate=_terminals.count>0,wasTiled=[self usesTiledLayout];TTerminalView *anchor=self.terminal,*terminal=[self newTerminal];terminal.verticalSplit=verticalSplit;terminal.splitAnchor=verticalSplit?anchor:nil;if(verticalSplit&&anchor){NSUInteger index=[_terminals indexOfObject:anchor];[_terminals insertObject:terminal atIndex:index==NSNotFound?_terminals.count:index+1];}else [_terminals addObject:terminal];if(animate&&self.config.tabAnimations&&[self usesTiledLayout])_enteringTerminal=terminal;[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];self.terminal=terminal;self.extensions.activeTerminal=terminal;[self rebuildTabs];_animateTabLayout=animate;BOOL changedTiling=wasTiled!=[self usesTiledLayout];if(changedTiling)[self applyAppearance];else [self layoutTabs];[terminal startShell];if(animate)[self animateNewTerminal:terminal];[self focusTerminal:terminal];}
- (void)addTab {[self addTabWithVerticalSplit:NO];}
- (void)addVerticalTab {[self addTabWithVerticalSplit:YES];}
- (void)closeTab {if(_terminals.count<=1){[self.window close];return;}BOOL wasTiled=[self usesTiledLayout];NSUInteger index=[_terminals indexOfObject:self.terminal];TTerminalView *closing=self.terminal;if(wasTiled&&self.config.tabAnimations){NSValue *override=_canvas.frameOverrides[[NSValue valueWithNonretainedObject:closing]];_closingTerminal=closing;_closingTileFrom=override?override.rectValue:closing.frame;_closingTileTo=NSInsetRect(_closingTileFrom,NSWidth(_closingTileFrom)*0.035,NSHeight(_closingTileFrom)*0.06);_canvas.exitingTerminal=closing;}for(TTerminalView *item in _terminals)if(item.splitAnchor==closing)item.splitAnchor=closing.splitAnchor;[_terminals removeObjectAtIndex:index];[closing removeFromSuperview];self.terminal=_terminals[MIN(index,_terminals.count-1)];self.extensions.activeTerminal=self.terminal;[self rebuildTabs];_animateTabLayout=YES;if(wasTiled!=[self usesTiledLayout])[self applyAppearance];else [self layoutTabs];[self focusTerminal:self.terminal];}
- (void)selectTabButton:(NSButton *)sender {[self selectTabNumber:sender.tag+1];}
- (void)selectTabNumber:(NSInteger)number {
    NSInteger index=number-1;if(index<0||index>=(NSInteger)_terminals.count)return;NSUInteger oldIndex=[_terminals indexOfObject:self.terminal];if((NSUInteger)index==oldIndex){[self focusTerminal:self.terminal];return;}
    TTerminalView *old=self.terminal,*next=_terminals[(NSUInteger)index];self.terminal=next;_cwd=[next workingDirectory];self.extensions.activeTerminal=next;[self rebuildTabs];[self layoutTabs];
    if(self.config.tabAnimations&&![self usesTiledLayout]){old.wantsLayer=next.wantsLayer=YES;CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];old.hidden=NO;next.hidden=NO;CGFloat direction=(NSUInteger)index>oldIndex?1:-1;CABasicAnimation *incoming=[CABasicAnimation animationWithKeyPath:@"transform.translation.x"];incoming.fromValue=@(direction*20);incoming.toValue=@0;incoming.duration=[self animationDuration:0.12];incoming.timingFunction=ease;[next.layer addAnimation:incoming forKey:@"termatica.tab.slide.in"];CABasicAnimation *outgoing=[CABasicAnimation animationWithKeyPath:@"transform.translation.x"];outgoing.fromValue=@0;outgoing.toValue=@(-direction*14);outgoing.duration=[self animationDuration:0.10];outgoing.timingFunction=ease;[old.layer addAnimation:outgoing forKey:@"termatica.tab.slide.out"];CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];fade.fromValue=@1;fade.toValue=@0;fade.duration=[self animationDuration:0.10];fade.timingFunction=ease;[old.layer addAnimation:fade forKey:@"termatica.tab.fade.out"];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self animationDuration:0.13]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{old.hidden=YES;[old releaseAnimationLayer];[next releaseAnimationLayer];});}
    [self focusTerminal:next];[next setNeedsDisplay:YES];
}
- (void)rebuildTabs {
    for(TTabButton *button in _tabButtons)[button removeFromSuperview];[_tabButtons removeAllObjects];_tabRail.tabCount=_terminals.count;
    if(_terminals.count<2){[_tabHideTimer invalidate];_tabHideTimer=nil;_tabRailVisible=NO;_tabRail.hidden=YES;_tabEdge.hidden=YES;TLog(@"tab count %lu, rail unavailable",(unsigned long)_terminals.count);return;}
    _revealRailAfterLayout=YES;NSUInteger active=[_terminals indexOfObject:self.terminal];for(NSUInteger i=0;i<_terminals.count;i++){TTabButton *button=[[TTabButton alloc]initWithFrame:NSZeroRect];button.config=self.config;button.title=[NSString stringWithFormat:@"%lu",(unsigned long)i+1];button.target=self;button.action=@selector(selectTabButton:);button.tag=(NSInteger)i;button.selectedTab=i==active;button.accessibilityLabel=[NSString stringWithFormat:@"Terminal tab %lu",(unsigned long)i+1];[button applyStyleAnimated:NO];[_tabRail addSubview:button];[_tabButtons addObject:button];}[_root addSubview:_tabRail positioned:NSWindowAbove relativeTo:nil];[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];[_tabRail setNeedsDisplay:YES];TLog(@"tab count %lu, rail ready",(unsigned long)_terminals.count);
}
- (void)layoutTabs {
    CGFloat w=_root.bounds.size.width,h=_root.bounds.size.height;BOOL tile=[self usesTiledLayout]||_closingTerminal!=nil,animate=_animateTabLayout&&self.config.tabAnimations,railWillShow=_terminals.count>1&&(_tabRailVisible||_revealRailAfterLayout);NSArray<NSValue *> *slots=tile?[self hyprlandFrames]:@[];CAMediaTimingFunction *ease=[CAMediaTimingFunction functionWithControlPoints:0.11f :1.0f :0.2f :1.0f];_canvas.hidden=!tile;_canvas.terminals=_terminals.copy;_canvas.activeTerminal=self.terminal;
    NSMutableArray<NSValue *> *fromFrames=[NSMutableArray arrayWithCapacity:_terminals.count],*toFrames=[NSMutableArray arrayWithCapacity:_terminals.count];
    for(NSUInteger i=0;i<_terminals.count;i++){
        TTerminalView *terminal=_terminals[i];NSValue *override=_canvas.frameOverrides[[NSValue valueWithNonretainedObject:terminal]];NSRect target=tile?slots[i].rectValue:NSMakeRect(0,0,w,h),prior=override?override.rectValue:terminal.frame;
        NSRect animationStart=prior;if(tile&&prior.size.width<1){animationStart=NSInsetRect(target,NSWidth(target)*0.06,NSHeight(target)*0.10);if(terminal.splitAnchor){NSUInteger anchorIndex=[_terminals indexOfObject:terminal.splitAnchor];if(anchorIndex!=NSNotFound&&anchorIndex<fromFrames.count){NSRect anchor=fromFrames[anchorIndex].rectValue;animationStart.origin.y=MAX(NSMinY(target),MIN(NSMaxY(target)-NSHeight(animationStart),NSMinY(anchor)-NSHeight(animationStart)*0.24));}}}
        [fromFrames addObject:[NSValue valueWithRect:animationStart]];[toFrames addObject:[NSValue valueWithRect:target]];
        CGFloat overlayInset=tile?(railWillShow&&NSPointInRect(NSMakePoint(12,h-60),target)?self.config.tabRailWidth+12:0):(_terminals.count>1?(railWillShow?self.config.tabRailWidth+12:10):0);terminal.hidden=tile?YES:terminal!=self.terminal;terminal.leadingOverlayInset=overlayInset;terminal.activeTerminal=terminal==self.terminal;terminal.tiledRendering=tile;
        if(terminal!=_draggingTerminal){terminal.frame=target;[terminal resizeGrid];}
        if(tile)TLog(@"tile %lu frame %.0f,%.0f %.0fx%.0f anchor %@",(unsigned long)i+1,target.origin.x,target.origin.y,target.size.width,target.size.height,terminal.splitAnchor?[NSString stringWithFormat:@"%lu",(unsigned long)[_terminals indexOfObject:terminal.splitAnchor]+1]:@"root");
        if(terminal==_draggingTerminal)continue;
        if(animate&&!tile&&prior.size.width>0&&!NSEqualRects(prior,target)){terminal.wantsLayer=YES;CGFloat sx=prior.size.width/target.size.width,sy=prior.size.height/target.size.height,dx=NSMidX(prior)-NSMidX(target),dy=NSMidY(prior)-NSMidY(target);CATransform3D from=CATransform3DConcat(CATransform3DMakeTranslation(dx,dy,0),CATransform3DMakeScale(sx,sy,1));CABasicAnimation *snap=[CABasicAnimation animationWithKeyPath:@"transform"];snap.fromValue=[NSValue valueWithCATransform3D:from];snap.toValue=[NSValue valueWithCATransform3D:CATransform3DIdentity];snap.duration=[self animationDuration:0.12];snap.timingFunction=ease;[terminal.layer addAnimation:snap forKey:@"termatica.hypr.snap"];__weak TTerminalView *weakTerminal=terminal;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self animationDuration:0.14]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[weakTerminal releaseAnimationLayer];});}else terminal.wantsLayer=NO;
    }
    if(tile&&animate)[self startTileAnimationFrom:fromFrames to:toFrames];else{[_tileAnimationTimer invalidate];_tileAnimationTimer=nil;_canvas.frameOverrides=nil;if(tile)[_canvas setNeedsDisplay:YES];}
    [self updateEffectMask];
    if(_terminals.count<2){_animateTabLayout=NO;[self updateTerminalTabInsets];return;}
    CGFloat topInset=MAX(42,_root.safeAreaInsets.top+8),available=MAX(44,h-topInset-8),itemHeight=MIN(28,floor((available-8)/_terminals.count));itemHeight=MAX(20,itemHeight);CGFloat railWidth=self.config.tabRailWidth,railHeight=8+itemHeight*_terminals.count;_tabRailTargetFrame=NSMakeRect(8,MAX(8,h-topInset-railHeight-6),railWidth,railHeight);for(NSUInteger i=0;i<_tabButtons.count;i++)_tabButtons[i].frame=NSMakeRect(4,4+i*itemHeight,railWidth-8,itemHeight);[self updateTabHoverArea];TLog(@"tab rail frame %.0f,%.0f %.0fx%.0f",_tabRailTargetFrame.origin.x,_tabRailTargetFrame.origin.y,_tabRailTargetFrame.size.width,_tabRailTargetFrame.size.height);BOOL reveal=_revealRailAfterLayout;_revealRailAfterLayout=NO;_animateTabLayout=NO;if(reveal)[self revealTabRail];else if(_tabRailVisible)_tabRail.frame=_tabRailTargetFrame;else{NSRect collapsed=_tabRailTargetFrame;collapsed.origin.x=-NSWidth(collapsed)+7;_tabRail.frame=collapsed;}[_root addSubview:_tabRail positioned:NSWindowAbove relativeTo:nil];[_root addSubview:_tabEdge positioned:NSWindowAbove relativeTo:nil];[_tabRail setNeedsDisplay:YES];
}
- (void)windowDidResize:(NSNotification *)notification {[self layoutTabs];}
- (void)windowDidBecomeKey:(NSNotification *)notification {if(self.terminal)[self focusTerminal:self.terminal];}
- (void)routeKeyEvent:(NSEvent *)event {if(!self.terminal)return;[self focusTerminal:self.terminal];[self.terminal keyDown:event];}
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
- (void)reloadConfig {[self.config reload];for(TTerminalView *terminal in _terminals)[terminal reloadAppearance];[self applyAppearance];}
- (BOOL)executeExtensionNamed:(NSString *)name query:(NSString *)query {NSString *needle=[name hasPrefix:@"/"]?name:[@"/" stringByAppendingString:name];for(NSDictionary *command in self.extensions.commands){if([command[@"slash"] isEqual:needle]||[command[@"id"] isEqual:name]){NSDictionary *ctx=@{@"query":query?:@"",@"cwd":_cwd?:[self.terminal workingDirectory],@"selection":[self.terminal selectedText]?:@"",@"screen":[self.terminal visibleText]?:@""};[self.extensions executeCommand:command context:ctx terminal:self.terminal];return YES;}}return NO;}
@end
static void TApplyMenuShortcut(NSMenuItem *item,NSString *spec) {if(!spec.length){item.keyEquivalent=@"";item.keyEquivalentModifierMask=0;return;}NSArray<NSString *> *parts=[spec.lowercaseString componentsSeparatedByString:@"+"];NSEventModifierFlags mask=0;NSString *key=parts.lastObject;for(NSString *part in parts){if([part isEqual:@"cmd"]||[part isEqual:@"command"])mask|=NSEventModifierFlagCommand;else if([part isEqual:@"shift"])mask|=NSEventModifierFlagShift;else if([part isEqual:@"option"]||[part isEqual:@"alt"])mask|=NSEventModifierFlagOption;else if([part isEqual:@"control"]||[part isEqual:@"ctrl"])mask|=NSEventModifierFlagControl;}if([key isEqual:@"plus"])key=@"+";else if([key isEqual:@"space"])key=@" ";item.keyEquivalent=key?:@"";item.keyEquivalentModifierMask=mask;}
@interface TAppDelegate : NSObject <NSApplicationDelegate>
@property TConfig *config;
@property TExtensionHost *extensions;
@property NSMutableArray<TWindowController *> *windows;
- (TWindowController *)active;
@end

@interface TApplication : NSApplication
@end

@implementation TApplication
- (void)sendEvent:(NSEvent *)event {if(event.type==NSEventTypeKeyDown){NSEventModifierFlags mods=event.modifierFlags&NSEventModifierFlagDeviceIndependentFlagsMask,command=NSEventModifierFlagCommand,commandShift=NSEventModifierFlagCommand|NSEventModifierFlagShift,relevant=mods&(NSEventModifierFlagCommand|NSEventModifierFlagShift|NSEventModifierFlagOption|NSEventModifierFlagControl);NSString *key=event.charactersIgnoringModifiers.lowercaseString;if(event.isARepeat&&[key isEqual:@"t"]&&(relevant==command||relevant==commandShift))return;if(relevant==commandShift&&[key isEqual:@"t"]&&[self sendAction:@selector(newVerticalTab:) to:self.delegate from:self])return;if(relevant==command){if([key isEqual:@"t"]&&[self sendAction:@selector(newTab:) to:self.delegate from:self])return;if([key isEqual:@"w"]&&[self sendAction:@selector(closeTab:) to:self.delegate from:self])return;if([key isEqual:@"k"]&&[self sendAction:@selector(clearTerminal:) to:self.delegate from:self])return;if(key.length==1&&[key characterAtIndex:0]>='1'&&[key characterAtIndex:0]<='9'){NSMenuItem *sender=[NSMenuItem new];sender.tag=[key integerValue];if([self sendAction:@selector(selectTab:) to:self.delegate from:sender])return;}}if(!(mods&NSEventModifierFlagCommand)){TWindowController *controller=[(TAppDelegate *)self.delegate active];if(controller&&event.window==controller.window&&controller.window.firstResponder!=controller.terminal){[controller routeKeyEvent:event];return;}}}[super sendEvent:event];}
@end

@implementation TAppDelegate {int _cliSocket;dispatch_source_t _cliSource;}
- (void)startCLIListener {_cliSocket=socket(AF_UNIX,SOCK_DGRAM,0);if(_cliSocket<0){TLog(@"CLI socket creation failed");return;}NSString *path=TCLISocketPath();unlink(path.fileSystemRepresentation);struct sockaddr_un address={0};address.sun_family=AF_UNIX;strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path));address.sun_len=(uint8_t)(offsetof(struct sockaddr_un,sun_path)+strlen(address.sun_path)+1);if(bind(_cliSocket,(struct sockaddr *)&address,address.sun_len)<0){TLog(@"CLI socket bind failed: %s",strerror(errno));close(_cliSocket);_cliSocket=-1;return;}fcntl(_cliSocket,F_SETFL,O_NONBLOCK);fcntl(_cliSocket,F_SETFD,FD_CLOEXEC);int socketFD=_cliSocket;_cliSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,(uintptr_t)socketFD,0,dispatch_get_main_queue());__weak typeof(self) weakSelf=self;dispatch_source_set_event_handler(_cliSource,^{uint8_t buffer[8192];ssize_t size=0;while((size=recv(socketFD,buffer,sizeof(buffer),0))>0){NSDictionary *request=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buffer length:(NSUInteger)size] options:0 error:nil];if([request isKindOfClass:NSDictionary.class])[weakSelf handleCLIRequest:request];}});dispatch_source_set_cancel_handler(_cliSource,^{close(socketFD);unlink(path.fileSystemRepresentation);});dispatch_resume(_cliSource);TLog(@"CLI socket listening at %@",path);}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {_cliSocket=-1;_config=[TConfig new];_extensions=[TExtensionHost new];_extensions.config=_config;_windows=[NSMutableArray array];[self buildMenu];[self startCLIListener];if(!self.config.skeleterm)[_extensions loadExtensions];TWindowController *controller=[[TWindowController alloc]initWithConfig:self.config extensions:self.extensions session:self.config.restoreSession?TLoadSession():nil];[self.windows addObject:controller];[controller showWindow:nil];controller.window.initialFirstResponder=controller.terminal;[controller.window makeFirstResponder:controller.terminal];}
- (void)applicationWillTerminate:(NSNotification *)notification {if(self.config.restoreSession){TWindowController *controller=[self active];if(controller)TWriteSession([controller sessionDictionary]);}if(_cliSource){dispatch_source_cancel(_cliSource);_cliSource=nil;}else if(_cliSocket>=0){close(_cliSocket);unlink(TCLISocketPath().fileSystemRepresentation);_cliSocket=-1;}}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
- (void)newWindow:(id)sender {TWindowController *controller=[[TWindowController alloc]initWithConfig:self.config extensions:self.extensions];[self.windows addObject:controller];[controller showWindow:nil];controller.window.initialFirstResponder=controller.terminal;[controller.window makeFirstResponder:controller.terminal];}
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
- (void)openConfig:(id)sender{[self.config ensureEditableFile];[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.config.path]];}
- (void)reloadAll {NSDictionary *priorBindings=self.config.keybindings;[self.config reload];if(![priorBindings isEqualToDictionary:self.config.keybindings])[self buildMenu];if(self.config.skeleterm)[self.extensions unloadExtensions];else[self.extensions loadExtensions];for(TWindowController *window in self.windows)[window reloadConfig];}
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
