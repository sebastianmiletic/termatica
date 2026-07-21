#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <util.h>
#import <sys/ioctl.h>
#import <sys/wait.h>
#import <signal.h>
#import <stdarg.h>
#import <libproc.h>
#import <string.h>
#import <termios.h>

static const uint32_t TDefaultColor = 0xFFFFFFFFu;
static CFAbsoluteTime TProcessStartedAt;
static NSString *const TCLICommandNotification = @"com.termatica.cli-command";

static NSString *TConfigDirectoryPath(void) {
    const char *override = getenv("TERMATICA_CONFIG_DIR");
    if (override && *override) return [[NSString stringWithUTF8String:override] stringByExpandingTildeInPath];
    return [@"~/.config/termatica" stringByExpandingTildeInPath];
}

static NSString *TEnsureDirectory(NSString *name) {
    NSString *path = name.length ? [TConfigDirectoryPath() stringByAppendingPathComponent:name] : TConfigDirectoryPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
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
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
                               green:((rgb >> 8) & 255) / 255.0
                                blue:(rgb & 255) / 255.0 alpha:1];
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
@property CGFloat tabRailWidth;
@property CGFloat backgroundOpacity;
@property CGFloat windowOpacity;
@property CGFloat glow;
@property CGFloat scanlines;
@property CGFloat vignette;
@property BOOL blur;
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
- (void)mergeEditableValues:(NSDictionary *)values;
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
        @"padding": @12, @"scrollback": @5000,
        @"theme": @"terminal-default",
        @"appearance": @{},
        @"tabs": @{@"railWidth":@34},
        @"keybindings": @{@"openConfig":@"cmd+,",@"newWindow":@"cmd+n",@"newTab":@"cmd+t",@"closeTab":@"cmd+w",@"clearTerminal":@"cmd+k",@"modules":@"cmd+m",@"reload":@"cmd+r",@"copy":@"cmd+c",@"paste":@"cmd+v",@"selectAll":@"cmd+a",@"zoomIn":@"cmd+plus",@"zoomOut":@"cmd+-",@"zoomReset":@"cmd+0"}
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
    NSData *data = [NSData dataWithContentsOfFile:self.path];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:NSDictionary.class]) {
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
    self.scrollback = MAX(100, MIN(100000, [d[@"scrollback"] unsignedIntegerValue] ?: 5000));
    self.skeleterm = [d[@"profile"] isEqual:@"skeleterm"];
    NSDictionary *tabs=[d[@"tabs"] isKindOfClass:NSDictionary.class]?d[@"tabs"]:@{};self.tabRailWidth=MAX(28,MIN(64,[tabs[@"railWidth"] doubleValue]?:34));
    id rawTheme=d[@"theme"];self.themeName=[rawTheme isKindOfClass:NSString.class]?rawTheme:@"custom";
    NSDictionary *theme=[rawTheme isKindOfClass:NSDictionary.class]?rawTheme:[self themeNamed:self.themeName];if(!theme)theme=[self fallbackTheme];
    NSDictionary *themeAppearance=[theme[@"appearance"] isKindOfClass:NSDictionary.class]?theme[@"appearance"]:@{};
    NSMutableDictionary *appearance=[themeAppearance mutableCopy];
    if([d[@"appearance"] isKindOfClass:NSDictionary.class])[appearance addEntriesFromDictionary:d[@"appearance"]];
    self.backgroundOpacity=MAX(0.08,MIN(1.0,appearance[@"backgroundOpacity"]?[appearance[@"backgroundOpacity"] doubleValue]:0.90));
    self.windowOpacity=MAX(0.20,MIN(1.0,appearance[@"windowOpacity"]?[appearance[@"windowOpacity"] doubleValue]:1.0));
    self.blur=appearance[@"blur"]?[appearance[@"blur"] boolValue]:YES;
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
- (void)useThemeNamed:(NSString *)name {if(![self themeNamed:name])return;[self ensureEditableFile];NSData *data=[NSData dataWithContentsOfFile:self.path];NSMutableDictionary *d=[NSMutableDictionary dictionary];id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;if([parsed isKindOfClass:NSDictionary.class])[d addEntriesFromDictionary:parsed];d[@"theme"]=name;[[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil] writeToFile:self.path atomically:YES];[self reload];}
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
    NSMutableDictionary *d=[self editableDictionary];d[@"profile"]=@"skeleterm";d[@"theme"]=@"terminal-default";d[@"scrollback"]=@300;d[@"appearance"]=@{@"backgroundOpacity":@1,@"windowOpacity":@1,@"blur":@NO,@"glow":@0,@"scanlines":@0,@"vignette":@0,@"cursorStyle":@"block"};[self writeEditableDictionary:d];
}
- (void)mergeEditableValues:(NSDictionary *)values {if(![values isKindOfClass:NSDictionary.class])return;NSMutableDictionary *d=[self editableDictionary];[d addEntriesFromDictionary:values];[self writeEditableDictionary:d];}
@end

static BOOL TPostCLIRequest(NSDictionary *request) {
    if([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.termatica.Termatica"].count==0)return NO;
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:TCLICommandNotification object:@"TermaticaCLI" userInfo:request deliverImmediately:YES];return YES;
}
static void TPostCLICommand(NSString *command) {TPostCLIRequest(@{@"command":command?:@""});}

static NSArray<NSDictionary *> *TMarketplaceItems(void) {
    NSMutableArray *items=[@[
      @{@"id":@"terminal-default",@"kind":@"themes",@"icon":@"[T]",@"title":@"TERMINAL DEFAULT",@"detail":@"neutral dark surface with a complete standard ANSI palette"},
      @{@"id":@"amber-crt",@"kind":@"themes",@"icon":@"[T:]",@"title":@"AMBER CRT",@"detail":@"optional phosphor palette, glow and blur"},
      @{@"id":@"ghost-glass",@"kind":@"themes",@"icon":@"[T~]",@"title":@"GHOST GLASS",@"detail":@"transparent cool glass and bar cursor"},
      @{@"id":@"green-screen",@"kind":@"themes",@"icon":@"[T#]",@"title":@"GREEN SCREEN",@"detail":@"opaque green phosphor and underline cursor"},
      @{@"id":@"skeleterm",@"kind":@"profiles",@"icon":@"[SK]",@"title":@"SKELETERM",@"detail":@"minimum-memory mode, 300-line history, effects and plugins off"},
      @{@"id":@"plain-terminal",@"kind":@"profiles",@"icon":@"[PL]",@"title":@"PLAIN TERMINAL",@"detail":@"opaque terminal, normal ANSI colors, full extension support",@"config":@{@"profile":@"standard",@"theme":@"terminal-default",@"appearance":@{@"backgroundOpacity":@1,@"windowOpacity":@1,@"blur":@NO,@"glow":@0,@"scanlines":@0,@"vignette":@0,@"cursorStyle":@"block"}}},
      @{@"id":@"amber-focus",@"kind":@"profiles",@"icon":@"[AF]",@"title":@"AMBER FOCUS",@"detail":@"opaque amber with a restrained cursor glow",@"config":@{@"profile":@"standard",@"theme":@"amber-crt",@"appearance":@{@"backgroundOpacity":@1,@"windowOpacity":@1,@"blur":@NO,@"glow":@0.08,@"scanlines":@0,@"vignette":@0.04,@"cursorStyle":@"block"}}},
      @{@"id":@"ghost-lite",@"kind":@"profiles",@"icon":@"[GL]",@"title":@"GHOST LITE",@"detail":@"translucent surface without the memory cost of blur",@"config":@{@"profile":@"standard",@"theme":@"ghost-glass",@"appearance":@{@"backgroundOpacity":@0.88,@"windowOpacity":@1,@"blur":@NO,@"glow":@0.04,@"scanlines":@0,@"vignette":@0,@"cursorStyle":@"bar"}}},
      @{@"id":@"hello",@"kind":@"plugins",@"icon":@"[>_]",@"title":@"HELLO PROTOCOL",@"detail":@"source-readable extension example, Python 3"},
      @{@"id":@"pi-bridge",@"kind":@"plugins",@"icon":@"[PI]",@"title":@"PI COMMAND BRIDGE",@"detail":@"adds /pi for an installed Pi CLI, Python 3"},
      @{@"id":@"editor-deck",@"kind":@"plugins",@"icon":@"[ED]",@"title":@"EDITOR DECK",@"detail":@"terminal controls for Vim, Neovim, Emacs, Nano, Micro and Helix"},
      @{@"id":@"vim-control",@"kind":@"plugins",@"icon":@"[VI]",@"title":@"VIM CONTROL",@"detail":@"/vim opens files in Vim inside the active terminal"},
      @{@"id":@"neovim-control",@"kind":@"plugins",@"icon":@"[NV]",@"title":@"NEOVIM CONTROL",@"detail":@"/nvim opens files in Neovim inside the active terminal"},
      @{@"id":@"emacs-control",@"kind":@"plugins",@"icon":@"[EM]",@"title":@"EMACS CONTROL",@"detail":@"/emacs opens terminal-mode Emacs with no GUI"},
      @{@"id":@"nano-control",@"kind":@"plugins",@"icon":@"[NA]",@"title":@"NANO CONTROL",@"detail":@"/nano opens files in Nano inside the active terminal"},
      @{@"id":@"micro-control",@"kind":@"plugins",@"icon":@"[MI]",@"title":@"MICRO CONTROL",@"detail":@"/micro opens files in Micro inside the active terminal"},
      @{@"id":@"helix-control",@"kind":@"plugins",@"icon":@"[HX]",@"title":@"HELIX CONTROL",@"detail":@"/hx opens files in Helix inside the active terminal"}
    ] mutableCopy];
    NSData *data=[NSData dataWithContentsOfFile:[TConfigDirectoryPath() stringByAppendingPathComponent:@"marketplace.json"]];NSDictionary *catalog=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;for(NSDictionary *item in [catalog[@"items"] isKindOfClass:NSArray.class]?catalog[@"items"]:@[])if([item isKindOfClass:NSDictionary.class]&&TSafeIdentifier(item[@"id"])&&[@[@"themes",@"plugins",@"profiles"] containsObject:item[@"kind"]])[items addObject:item];return items;
}

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

static NSData *TDownloadModule(NSString *urlString,NSError **error) {NSURL *url=[NSURL URLWithString:urlString];if(![url.scheme.lowercaseString isEqual:@"https"]){if(error)*error=[NSError errorWithDomain:@"TermaticaMarketplace" code:1 userInfo:@{NSLocalizedDescriptionKey:@"only HTTPS downloads are allowed"}];return nil;}NSData *data=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];if(data.length>2*1024*1024){if(error)*error=[NSError errorWithDomain:@"TermaticaMarketplace" code:2 userInfo:@{NSLocalizedDescriptionKey:@"module exceeds the 2 MB limit"}];return nil;}return data;}

static BOOL TWritePlugin(NSString *identifier,NSDictionary *manifest,NSData *script,NSError **error) {NSString *entry=[manifest[@"entry"] isKindOfClass:NSString.class]?manifest[@"entry"]:@"extension";if(!TSafeIdentifier(identifier)||[entry containsString:@"/"]||[entry containsString:@".."]||!script.length){if(error)*error=[NSError errorWithDomain:@"TermaticaMarketplace" code:3 userInfo:@{NSLocalizedDescriptionKey:@"invalid plugin package"}];return NO;}NSString *root=[TEnsureDirectory(@"extensions") stringByAppendingPathComponent:identifier];NSFileManager *fm=NSFileManager.defaultManager;if(![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error])return NO;NSData *json=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];if(![json writeToFile:[root stringByAppendingPathComponent:@"extension.json"] options:NSDataWritingAtomic error:error])return NO;NSString *path=[root stringByAppendingPathComponent:entry];if(![script writeToFile:path options:NSDataWritingAtomic error:error])return NO;return [fm setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:path error:error];}

static BOOL TInstallModule(NSDictionary *item,TConfig *config,NSError **error) {
    NSString *identifier=item[@"id"],*kind=item[@"kind"];
    if(!TSafeIdentifier(identifier))return NO;
    if([kind isEqual:@"themes"]){NSData *data=nil;if([item[@"theme"] isKindOfClass:NSDictionary.class])data=[NSJSONSerialization dataWithJSONObject:item[@"theme"] options:NSJSONWritingPrettyPrinted error:error];else if([item[@"downloadURL"] isKindOfClass:NSString.class])data=TDownloadModule(item[@"downloadURL"],error);else data=[NSData dataWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[NSString stringWithFormat:@"Themes/%@.json",identifier]] options:0 error:error];NSDictionary *theme=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:error]:nil;if(![theme isKindOfClass:NSDictionary.class])return NO;NSString *path=[[TEnsureDirectory(@"themes") stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"json"];BOOL ok=[data writeToFile:path options:NSDataWritingAtomic error:error];if(ok)[config useThemeNamed:identifier];return ok;}
    if([kind isEqual:@"profiles"]){if([identifier isEqual:@"skeleterm"])[config applySkeleterm];else [config mergeEditableValues:[item[@"config"] isKindOfClass:NSDictionary.class]?item[@"config"]:@{}];return YES;}
    if(![kind isEqual:@"plugins"])return NO;
    if([item[@"manifest"] isKindOfClass:NSDictionary.class]){NSData *script=[item[@"script"] isKindOfClass:NSString.class]?[item[@"script"] dataUsingEncoding:NSUTF8StringEncoding]:TDownloadModule(item[@"downloadURL"],error);return TWritePlugin(identifier,item[@"manifest"],script,error);}
    NSDictionary *manifest=@{@"id":[NSString stringWithFormat:@"com.termatica.%@",identifier],@"name":identifier,@"version":@"1.0.0",@"entry":@"extension.py"};NSString *script=nil;
    if([identifier isEqual:@"editor-deck"]||[identifier hasSuffix:@"-control"]){script=TEditorControlsScript(identifier);}
    else {NSString *command=[identifier isEqual:@"pi-bridge"]?@"pi":@"printf '\\033[38;2;122;162;247mTermatica\\033[0m %s\\n'";NSString *slash=[identifier isEqual:@"pi-bridge"]?@"/pi":@"/hello";NSString *title=[identifier isEqual:@"pi-bridge"]?@"Pi: send prompt":@"Hello: write into shell";script=[NSString stringWithFormat:@"#!/usr/bin/env python3\nimport json,sys,shlex\nfor line in sys.stdin:\n try:\n  m=json.loads(line)\n  if m.get('method')=='initialize': print(json.dumps({'jsonrpc':'2.0','method':'command.register','params':{'id':'%@.run','title':'%@','slash':'%@'}}),flush=True)\n  elif m.get('method')=='command.execute':\n   q=m.get('params',{}).get('query',''); print(json.dumps({'jsonrpc':'2.0','method':'terminal.sendText','params':{'text':\"%@ \"+shlex.quote(q)+\"\\n\"}}),flush=True)\n except Exception: pass\n",identifier,title,slash,command];}
    return TWritePlugin(identifier,manifest,[script dataUsingEncoding:NSUTF8StringEncoding],error);
}

static volatile sig_atomic_t TMenuInterrupted=0;
static void TMenuSignal(int signalNumber){TMenuInterrupted=1;}

static void TDrawMarketplace(NSArray<NSDictionary *> *items,NSUInteger selected) {
    fputs("\033[2J\033[H\033[38;2;122;162;247m+------------------------------------------------------------------+\n|  >_ TERMATICA // MODULES                                        |\n|  arrows move  enter installs  q exits                            |\n+------------------------------------------------------------------+\033[0m\n",stdout);
    for(NSUInteger i=0;i<items.count;i++){NSDictionary *item=items[i];if(i==selected)fputs("\033[48;2;43;52;69m\033[38;2;238;241;245m",stdout);else fputs("\033[38;2;216;222;233m",stdout);fprintf(stdout," %c %2lu  %-4s %-22s  %-38s\033[0m\n",i==selected?'>':' ',(unsigned long)i+1,[item[@"icon"] UTF8String],[[item[@"title"] uppercaseString] UTF8String],[item[@"detail"]?:@"user catalog module" UTF8String]);}
    fputs("\n\033[38;2;107;114;128m[ UP/DOWN or J/K ] MOVE   [ ENTER ] INSTALL   [ Q ] QUIT\033[0m",stdout);fflush(stdout);
}

static int TRunMarketplace(NSString *category,TConfig *config) {
    NSArray *all=TMarketplaceItems();NSArray *items=nil;if([category isEqual:@"all"])items=all;else if([category isEqual:@"plugins"])items=[all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return [@[@"plugins",@"profiles"] containsObject:item[@"kind"]];}]];else items=[all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return [item[@"kind"] isEqual:category];}]];
    NSDictionary *item=nil;
    struct termios original;BOOL interactive=isatty(STDIN_FILENO)&&isatty(STDOUT_FILENO)&&tcgetattr(STDIN_FILENO,&original)==0;
    if(interactive){
        struct termios raw=original;raw.c_lflag&=~(ICANON|ECHO);raw.c_iflag&=~(IXON|ICRNL);raw.c_cc[VMIN]=1;raw.c_cc[VTIME]=0;tcsetattr(STDIN_FILENO,TCSAFLUSH,&raw);void (*previous)(int)=signal(SIGINT,TMenuSignal);TMenuInterrupted=0;NSUInteger selected=0;fputs("\033[?25l",stdout);while(!TMenuInterrupted){TDrawMarketplace(items,selected);unsigned char key=0;if(read(STDIN_FILENO,&key,1)!=1)continue;if(key=='q'||key=='Q')break;if(key=='\r'||key=='\n'){item=items[selected];break;}if(key=='j'||key=='J'){selected=(selected+1)%items.count;continue;}if(key=='k'||key=='K'){selected=(selected+items.count-1)%items.count;continue;}if(key==27){unsigned char sequence[2]={0};if(read(STDIN_FILENO,&sequence[0],1)==1&&read(STDIN_FILENO,&sequence[1],1)==1&&sequence[0]=='['){if(sequence[1]=='A')selected=(selected+items.count-1)%items.count;else if(sequence[1]=='B')selected=(selected+1)%items.count;}}}tcsetattr(STDIN_FILENO,TCSAFLUSH,&original);signal(SIGINT,previous);fputs("\033[?25h\033[0m\n",stdout);if(!item)return TMenuInterrupted?130:0;
    } else {
        TDrawMarketplace(items,NSNotFound);fputs("\nType a number or module id to install. Type q to return.\nmodule> ",stdout);fflush(stdout);char input[128]={0};if(!fgets(input,sizeof(input),stdin))return 0;NSString *answer=[[[NSString stringWithUTF8String:input] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];if([answer isEqual:@"q"]||[answer isEqual:@"quit"]||!answer.length)return 0;NSInteger choice=answer.integerValue;if(choice>=1&&choice<=(NSInteger)items.count)item=items[(NSUInteger)choice-1];else for(NSDictionary *candidate in items)if([candidate[@"id"] isEqual:answer]){item=candidate;break;}if(!item){fprintf(stderr,"termatica: module not found: %s\n",answer.UTF8String);return 2;}
    }
    for(int i=0;i<=20;i++){fputs("\r\033[38;2;122;162;247mWRITE [",stdout);for(int j=0;j<20;j++)fputc(j<i?'#':(j==i?'>':'.'),stdout);fprintf(stdout,"] %3d%%\033[0m",i*5);fflush(stdout);usleep(12000);}fputc('\n',stdout);NSError *error=nil;BOOL ok=TInstallModule(item,config,&error);if(ok){TPostCLICommand(@"reload");fprintf(stdout,"\033[38;2;152;195;121m[ INSTALLED ]\033[0m %s\n",[item[@"title"] UTF8String]);return 0;}fprintf(stderr,"[ FAILED ] %s\n",(error.localizedDescription?:@"installation failed").UTF8String);return 1;
}

static NSDictionary *TMarketplaceItemNamed(NSString *identifier) {for(NSDictionary *item in TMarketplaceItems())if([item[@"id"] isEqual:identifier])return item;return nil;}

static int TRunEditorCLI(int argc,const char *argv[]) {
    NSDictionary *editors=@{@"vim":@[@"vim"],@"vi":@[@"vim"],@"nvim":@[@"nvim"],@"emacs":@[@"emacs",@"-nw"],@"nano":@[@"nano"],@"micro":@[@"micro"],@"hx":@[@"hx"],@"helix":@[@"hx"]};
    if(argc<3||!strcmp(argv[2],"list")){fputs("Terminal editors: vim, nvim, emacs, nano, micro, hx\nUsage: termatica editor <name> [file ...]\n",stdout);return argc<3?2:0;}
    NSString *name=[[NSString stringWithUTF8String:argv[2]] lowercaseString];NSArray<NSString *> *prefix=editors[name];if(!prefix){fprintf(stderr,"termatica: unsupported editor: %s\n",argv[2]);return 2;}
    NSUInteger extra=(NSUInteger)MAX(0,argc-3),count=prefix.count+extra;char **editorArgv=calloc(count+1,sizeof(char *));for(NSUInteger i=0;i<prefix.count;i++)editorArgv[i]=(char *)prefix[i].UTF8String;for(NSUInteger i=0;i<extra;i++)editorArgv[prefix.count+i]=(char *)argv[3+i];editorArgv[count]=NULL;execvp(editorArgv[0],editorArgv);fprintf(stderr,"termatica: %s is not installed or not in PATH\n",editorArgv[0]);free(editorArgv);return 127;
}

static int TRunCLI(int argc, const char *argv[]) {
    NSString *arg=argc>1?[NSString stringWithUTF8String:argv[1]]:@"--help";
    if([arg isEqual:@"--help"]||[arg isEqual:@"-h"]||[arg isEqual:@"help"]){
        fputs("Termatica 0.3.0\n\nUSAGE\n  termatica <command> [arguments]\n\nTERMINAL COMMANDS\n  plugins            Browse plugins and profiles with arrow keys\n  themes             Browse themes with arrow keys\n  profiles           Browse resource and appearance profiles\n  marketplace        Browse every module in the terminal\n  install <id>       Install a module without opening the browser\n  run <name> [text]  Run an installed extension command\n  editor <name> ...  Run Vim, Neovim, Emacs, Nano, Micro or Helix\n  reload             Reload config and installed extensions\n\nFILES AND PROFILES\n  config             Open editable config.json\n  config-path        Print the config path\n  config-dir         Open the Termatica data folder\n  plugins-dir        Open installed extensions\n  themes-dir         Open installed themes\n  catalog            Open the user marketplace catalog\n  skeleterm          Apply minimum-memory mode\n\nFLAGS\n  --help             Show this guide\n  --version          Print the version\n\nLong commands also accept their legacy --command spelling.\n",stdout);return 0;
    }
    if([arg isEqual:@"--version"]||[arg isEqual:@"version"]){fputs("Termatica 0.3.0\n",stdout);return 0;}
    if([arg isEqual:@"editor"]||[arg isEqual:@"--editor"]||[arg isEqual:@"edit"]||[arg isEqual:@"--edit"])return TRunEditorCLI(argc,argv);
    if([arg isEqual:@"run"]||[arg isEqual:@"--run"]){if(argc<3){fputs("termatica: run requires an extension command name\n",stderr);return 2;}NSMutableArray *parts=[NSMutableArray array];for(int i=3;i<argc;i++)[parts addObject:[NSString stringWithUTF8String:argv[i]]];BOOL sent=TPostCLIRequest(@{@"command":@"run",@"name":[NSString stringWithUTF8String:argv[2]],@"query":[parts componentsJoinedByString:@" "]});if(!sent){fputs("termatica: the Termatica app is not running\n",stderr);return 1;}return 0;}
    TConfig *config=[TConfig new];
    if([arg isEqual:@"--config-path"]||[arg isEqual:@"config-path"]){fprintf(stdout,"%s\n",config.path.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--config"]||[arg isEqual:@"--settings"]||[arg isEqual:@"config"]||[arg isEqual:@"settings"]){[config ensureEditableFile];TOpenPath(config.path);fprintf(stdout,"opened %s\n",config.path.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--config-dir"]||[arg isEqual:@"config-dir"]){NSString *p=TEnsureDirectory(nil);TOpenPath(p);fprintf(stdout,"opened %s\n",p.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--plugins-dir"]||[arg isEqual:@"plugins-dir"]){NSString *p=TEnsureDirectory(@"extensions");TOpenPath(p);fprintf(stdout,"opened %s\n",p.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--themes-dir"]||[arg isEqual:@"themes-dir"]){NSString *p=TEnsureDirectory(@"themes");TOpenPath(p);fprintf(stdout,"opened %s\n",p.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--catalog"]||[arg isEqual:@"catalog"]){NSString *p=[TConfigDirectoryPath() stringByAppendingPathComponent:@"marketplace.json"];if(![NSFileManager.defaultManager fileExistsAtPath:p]){NSData *data=[NSJSONSerialization dataWithJSONObject:@{ @"items":@[] } options:NSJSONWritingPrettyPrinted error:nil];[data writeToFile:p atomically:YES];}TOpenPath(p);fprintf(stdout,"opened %s\n",p.fileSystemRepresentation);return 0;}
    if([arg isEqual:@"--skeleterm"]||[arg isEqual:@"skeleterm"]){[config applySkeleterm];TPostCLICommand(@"reload");fputs("skeleterm applied: 300-line history, effects and extension processes disabled\n",stdout);return 0;}
    if([arg isEqual:@"--reload"]||[arg isEqual:@"reload"]){TPostCLICommand(@"reload");fputs("reload requested\n",stdout);return 0;}
    if([arg isEqual:@"--plugins"]||[arg isEqual:@"plugins"])return TRunMarketplace(@"plugins",config);
    if([arg isEqual:@"--themes"]||[arg isEqual:@"themes"])return TRunMarketplace(@"themes",config);
    if([arg isEqual:@"--profiles"]||[arg isEqual:@"profiles"])return TRunMarketplace(@"profiles",config);
    if([arg isEqual:@"--marketplace"]||[arg isEqual:@"marketplace"]||[arg isEqual:@"modules"])return TRunMarketplace(@"all",config);
    if([arg isEqual:@"--install"]||[arg isEqual:@"install"]){if(argc<3){fputs("termatica: install requires a module id\n",stderr);return 2;}NSString *identifier=[[NSString stringWithUTF8String:argv[2]] lowercaseString];NSDictionary *item=TMarketplaceItemNamed(identifier);if(!item){fprintf(stderr,"termatica: module not found: %s\n",identifier.UTF8String);return 2;}NSError *error=nil;if(!TInstallModule(item,config,&error)){fprintf(stderr,"termatica: install failed: %s\n",(error.localizedDescription?:@"unknown error").UTF8String);return 1;}TPostCLICommand(@"reload");fprintf(stdout,"installed %s\n",identifier.UTF8String);return 0;}
    fprintf(stderr,"termatica: unknown command: %s\nRun 'termatica --help'.\n",arg.UTF8String);return 2;
}

typedef struct {
    uint32_t ch;
    uint32_t fg;
    uint32_t bg;
    uint8_t flags;
} TCell;

enum { TBold = 1, TItalic = 2, TUnderline = 4, TInverse = 8 };
enum { TParseText, TParseEscape, TParseCSI, TParseOSC, TParseOSCEscape };

@interface TTerminalView : NSView
@property TConfig *config;
@property (copy) void (^titleChanged)(NSString *title);
@property (copy) void (^cwdChanged)(NSString *cwd);
- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config;
- (BOOL)startShell;
- (void)sendString:(NSString *)string;
- (void)reloadAppearance;
- (void)clearTerminal;
- (NSString *)visibleText;
- (NSString *)workingDirectory;
@end

@implementation TTerminalView {
    int _master;
    pid_t _pid;
    dispatch_source_t _readSource;
    TCell *_cells;
    NSUInteger _cols, _rows, _cursorX, _cursorY, _savedX, _savedY;
    NSUInteger _scrollTop, _scrollBottom;
    NSMutableArray<NSData *> *_history;
    NSInteger _historyOffset;
    NSFont *_font, *_boldFont, *_italicFont;
    CGFloat _cellWidth, _cellHeight;
    uint32_t _currentFG, _currentBG;
    uint8_t _currentFlags;
    int _parseState, _params[20], _paramIndex;
    BOOL _privateCSI, _bracketedPaste, _cursorVisible;
    NSMutableString *_osc;
    uint32_t _utf8Code;
    int _utf8Needed;
    NSPoint _selectionStart, _selectionEnd;
    BOOL _selecting, _hasSelection;
}

- (instancetype)initWithFrame:(NSRect)frame config:(TConfig *)config {
    if ((self = [super initWithFrame:frame])) {
        _config = config; _master = -1; _pid = -1; _history = [NSMutableArray array];
        _osc = [NSMutableString string]; _parseState = TParseText; _cursorVisible = YES;
        _currentFG = _currentBG = TDefaultColor;
        [self reloadAppearance];
        [self resizeGrid];
        self.accessibilityLabel = @"Terminal";
    }
    return self;
}
- (void)dealloc {
    if (_readSource) dispatch_source_cancel(_readSource);
    if (_master >= 0) close(_master);
    if (_pid > 0) kill(_pid, SIGHUP);
    free(_cells);
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return self.config.backgroundOpacity >= 0.999 && !self.config.blur; }
- (void)reloadAppearance {
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
- (TCell)blankCell { return (TCell){ .ch=' ', .fg=TDefaultColor, .bg=TDefaultColor, .flags=0 }; }
- (void)resizeGrid {
    CGFloat topInset=self.safeAreaInsets.top,bottomInset=self.safeAreaInsets.bottom;
    NSUInteger cols = MAX(2, (NSUInteger)floor((self.bounds.size.width - self.config.padding * 2) / MAX(1, _cellWidth)));
    NSUInteger rows = MAX(2, (NSUInteger)floor((self.bounds.size.height - self.config.padding * 2 - topInset - bottomInset) / MAX(1, _cellHeight)));
    if (cols == _cols && rows == _rows) return;
    TCell *next = calloc(cols * rows, sizeof(TCell));
    TCell blank = [self blankCell];
    for (NSUInteger i = 0; i < cols * rows; i++) next[i] = blank;
    if (_cells) {
        NSUInteger copyRows = MIN(rows, _rows), copyCols = MIN(cols, _cols);
        for (NSUInteger y = 0; y < copyRows; y++)
            memcpy(next + y * cols, _cells + y * _cols, copyCols * sizeof(TCell));
        free(_cells);
    }
    _cells = next; _cols = cols; _rows = rows;
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
    struct winsize ws = { .ws_row=(unsigned short)_rows, .ws_col=(unsigned short)_cols };
    _pid = forkpty(&_master, NULL, NULL, &ws);
    if (_pid < 0) { TLog(@"forkpty failed: %s", strerror(errno)); return NO; }
    if (_pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("TERM_PROGRAM", "Termatica", 1);
        setenv("TERM_PROGRAM_VERSION", "0.3.0", 1);
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
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _master, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_source_set_event_handler(_readSource, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        uint8_t buffer[32768];
        ssize_t n = read(self->_master, buffer, sizeof(buffer));
        if (n > 0) {
            NSData *chunk = [NSData dataWithBytes:buffer length:(NSUInteger)n];
            dispatch_async(dispatch_get_main_queue(), ^{ [self consumeData:chunk]; });
        } else if (n == 0) TLog(@"shell pty reached EOF");
        else if (errno != EAGAIN) TLog(@"pty read failed: %s", strerror(errno));
    });
    dispatch_source_set_cancel_handler(_readSource, ^{});
    dispatch_resume(_readSource);
    return YES;
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
    [self setNeedsDisplay:YES];
    self.accessibilityValue = [self visibleText];
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
    TCell *c = &_cells[_cursorY * _cols + _cursorX];
    c->ch = cp; c->fg = _currentFG; c->bg = _currentBG; c->flags = _currentFlags;
    _cursorX++;
}
- (void)lineFeed {
    if (_cursorY == _scrollBottom) [self scrollUp];
    else _cursorY = MIN(_rows - 1, _cursorY + 1);
}
- (void)scrollUp {
    if (_scrollTop == 0 && _scrollBottom == _rows - 1) {
        NSData *line = [NSData dataWithBytes:_cells length:_cols * sizeof(TCell)];
        [_history addObject:line];
        if (_history.count > self.config.scrollback) [_history removeObjectAtIndex:0];
    }
    memmove(_cells + _scrollTop * _cols, _cells + (_scrollTop + 1) * _cols, (_scrollBottom - _scrollTop) * _cols * sizeof(TCell));
    TCell blank = [self blankCell];
    for (NSUInteger x=0; x<_cols; x++) _cells[_scrollBottom*_cols+x]=blank;
}
- (void)reverseIndex {
    if (_cursorY > _scrollTop) { _cursorY--; return; }
    memmove(_cells + (_scrollTop + 1) * _cols, _cells + _scrollTop * _cols, (_scrollBottom - _scrollTop) * _cols * sizeof(TCell));
    TCell blank=[self blankCell]; for(NSUInteger x=0;x<_cols;x++) _cells[_scrollTop*_cols+x]=blank;
}
- (void)eraseDisplay:(int)mode {
    TCell blank=[self blankCell];
    if (mode==2 || mode==3) { for(NSUInteger i=0;i<_cols*_rows;i++) _cells[i]=blank; if(mode==3)[_history removeAllObjects]; }
    else if(mode==0) for(NSUInteger i=_cursorY*_cols+_cursorX;i<_cols*_rows;i++) _cells[i]=blank;
    else if(mode==1) for(NSUInteger i=0;i<=_cursorY*_cols+_cursorX && i<_cols*_rows;i++) _cells[i]=blank;
}
- (void)eraseLine:(int)mode {
    TCell blank=[self blankCell]; NSUInteger a=0,b=_cols;
    if(mode==0)a=_cursorX; else if(mode==1)b=MIN(_cols,_cursorX+1);
    for(NSUInteger x=a;x<b;x++) _cells[_cursorY*_cols+x]=blank;
}
- (void)eraseCharacters:(int)n { TCell b=[self blankCell]; for(NSUInteger x=_cursorX;x<MIN(_cols,_cursorX+(NSUInteger)n);x++)_cells[_cursorY*_cols+x]=b; }
- (void)deleteCharacters:(int)n { NSUInteger count=MIN((NSUInteger)n,_cols-_cursorX); TCell b=[self blankCell]; memmove(_cells+_cursorY*_cols+_cursorX,_cells+_cursorY*_cols+_cursorX+count,(_cols-_cursorX-count)*sizeof(TCell)); for(NSUInteger x=_cols-count;x<_cols;x++)_cells[_cursorY*_cols+x]=b; }
- (void)insertCharacters:(int)n { NSUInteger count=MIN((NSUInteger)n,_cols-_cursorX); TCell b=[self blankCell]; memmove(_cells+_cursorY*_cols+_cursorX+count,_cells+_cursorY*_cols+_cursorX,(_cols-_cursorX-count)*sizeof(TCell)); for(NSUInteger x=_cursorX;x<_cursorX+count;x++)_cells[_cursorY*_cols+x]=b; }
- (void)insertLines:(int)n { if(_cursorY<_scrollTop||_cursorY>_scrollBottom)return; NSUInteger count=MIN((NSUInteger)n,_scrollBottom-_cursorY+1); memmove(_cells+(_cursorY+count)*_cols,_cells+_cursorY*_cols,(_scrollBottom-_cursorY+1-count)*_cols*sizeof(TCell)); TCell b=[self blankCell]; for(NSUInteger i=_cursorY*_cols;i<(_cursorY+count)*_cols;i++)_cells[i]=b; }
- (void)deleteLines:(int)n { if(_cursorY<_scrollTop||_cursorY>_scrollBottom)return; NSUInteger count=MIN((NSUInteger)n,_scrollBottom-_cursorY+1); memmove(_cells+_cursorY*_cols,_cells+(_cursorY+count)*_cols,(_scrollBottom-_cursorY+1-count)*_cols*sizeof(TCell)); TCell b=[self blankCell]; for(NSUInteger i=(_scrollBottom-count+1)*_cols;i<=_scrollBottom*_cols+_cols-1;i++)_cells[i]=b; }
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
- (void)clearTerminal { [self eraseDisplay:2]; _cursorX=_cursorY=0; [_history removeAllObjects]; [self refreshTextView];[self setNeedsDisplay:YES]; }

- (const TCell *)lineAtVisibleIndex:(NSInteger)index temporary:(NSData **)temporary {
    NSInteger totalHistory=(NSInteger)_history.count;
    NSInteger first=totalHistory-(NSInteger)_historyOffset;
    NSInteger logical=first+index;
    if(logical<totalHistory && logical>=0){ NSData *d=_history[(NSUInteger)logical]; *temporary=d; return d.bytes; }
    NSInteger row=logical-totalHistory;
    if(row>=0 && row<(NSInteger)_rows)return _cells+row*_cols;
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
- (void)drawRect:(NSRect)dirtyRect {
    [self.config.background setFill];NSRectFill(dirtyRect);CGFloat pad=self.config.padding,top=pad+self.safeAreaInsets.top;NSShadow *phosphor=nil;if(self.config.glow>0){phosphor=[NSShadow new];phosphor.shadowColor=[self.config.accent colorWithAlphaComponent:self.config.glow];phosphor.shadowBlurRadius=1+self.config.glow*3;phosphor.shadowOffset=NSZeroSize;}
    for(NSUInteger y=0;y<_rows;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:(NSInteger)y temporary:&hold];if(!line)continue;for(NSUInteger x=0;x<_cols;x++){TCell c=line[x];if(c.ch==' '&&!([self cellSelectedX:x y:y])&&c.bg==TDefaultColor)continue;uint32_t fg=c.fg==TDefaultColor?TRGB(self.config.foreground):c.fg,bg=c.bg==TDefaultColor?TRGB(self.config.background):c.bg;if(c.flags&TInverse){uint32_t t=fg;fg=bg;bg=t;}NSRect cell=NSMakeRect(pad+x*_cellWidth,top+y*_cellHeight,_cellWidth,_cellHeight);if([self cellSelectedX:x y:y]){[self.config.selection setFill];NSRectFill(cell);}else if(c.bg!=TDefaultColor){[TColor(bg) setFill];NSRectFill(cell);}if(c.ch!=' '&&c.ch){NSFont *font=(c.flags&TBold)?_boldFont:((c.flags&TItalic)?_italicFont:_font);NSMutableDictionary *attrs=[@{NSFontAttributeName:font,NSForegroundColorAttributeName:TColor(fg)} mutableCopy];if(phosphor)attrs[NSShadowAttributeName]=phosphor;if(c.flags&TUnderline)attrs[NSUnderlineStyleAttributeName]=@(NSUnderlineStyleSingle);[[self stringForCodepoint:c.ch] drawInRect:NSMakeRect(cell.origin.x,cell.origin.y,_cellWidth+2,_cellHeight) withAttributes:attrs];}}}
    if(_cursorVisible&&_historyOffset==0&&self.window.firstResponder==self){BOOL block=![self.config.cursorStyle isEqual:@"bar"]&&![self.config.cursorStyle isEqual:@"underline"];[[self.config.cursor colorWithAlphaComponent:block?0.42:0.96]setFill];NSRect r=NSMakeRect(pad+_cursorX*_cellWidth,top+_cursorY*_cellHeight,_cellWidth,_cellHeight);if([self.config.cursorStyle isEqual:@"bar"])r.size.width=2;else if([self.config.cursorStyle isEqual:@"underline"]){r.origin.y+=_cellHeight-2;r.size.height=2;}NSRectFillUsingOperation(r,NSCompositingOperationSourceOver);}
    if(self.config.scanlines>0){[[NSColor colorWithWhite:0 alpha:self.config.scanlines*0.10]setFill];for(CGFloat y=2;y<self.bounds.size.height;y+=4)NSRectFillUsingOperation(NSMakeRect(0,y,self.bounds.size.width,1),NSCompositingOperationSourceOver);}
    if(self.config.vignette>0){for(NSUInteger i=0;i<6;i++){[[NSColor colorWithWhite:0 alpha:self.config.vignette*(6-i)/30.0]setStroke];NSBezierPath *p=[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds,i+0.5,i+0.5)];[p stroke];}}
}
- (NSPoint)cellForPoint:(NSPoint)p { NSInteger x=floor((p.x-self.config.padding)/_cellWidth),y=floor((p.y-self.config.padding-self.safeAreaInsets.top)/_cellHeight); return NSMakePoint(MAX(0,MIN((NSInteger)_cols-1,x)),MAX(0,MIN((NSInteger)_rows-1,y))); }
- (void)mouseDown:(NSEvent *)event {[self.window makeFirstResponder:self];_selectionStart=_selectionEnd=[self cellForPoint:[self convertPoint:event.locationInWindow fromView:nil]];_selecting=YES;_hasSelection=NO;[self setNeedsDisplay:YES];}
- (void)mouseDragged:(NSEvent *)event {if(!_selecting)return;_selectionEnd=[self cellForPoint:[self convertPoint:event.locationInWindow fromView:nil]];_hasSelection=YES;[self setNeedsDisplay:YES];}
- (void)mouseUp:(NSEvent *)event {_selecting=NO;}
- (void)scrollWheel:(NSEvent *)event { NSInteger delta=(NSInteger)llround(event.scrollingDeltaY/3.0); _historyOffset=MAX(0,MIN((NSInteger)_history.count,_historyOffset+delta));[self refreshTextView];[self setNeedsDisplay:YES]; }
- (NSString *)selectedText {
    if(!_hasSelection)return @"";NSInteger a=(NSInteger)_selectionStart.y*(NSInteger)_cols+(NSInteger)_selectionStart.x,b=(NSInteger)_selectionEnd.y*(NSInteger)_cols+(NSInteger)_selectionEnd.x;if(a>b){NSInteger t=a;a=b;b=t;}NSMutableString *s=[NSMutableString string];NSInteger firstRow=a/(NSInteger)_cols,lastRow=b/(NSInteger)_cols;for(NSInteger y=firstRow;y<=lastRow;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:y temporary:&hold];NSInteger x0=y==firstRow?a%(NSInteger)_cols:0,x1=y==lastRow?b%(NSInteger)_cols:(NSInteger)_cols-1;NSMutableString *row=[NSMutableString string];for(NSInteger x=x0;x<=x1;x++)[row appendString:[self stringForCodepoint:line?line[x].ch:' ']];while([row hasSuffix:@" "])[row deleteCharactersInRange:NSMakeRange(row.length-1,1)];[s appendString:row];if(y<lastRow)[s appendString:@"\n"];}return s;
}
- (NSString *)visibleText {NSMutableArray *lines=[NSMutableArray array];for(NSUInteger y=0;y<_rows;y++){NSData *hold=nil;const TCell *line=[self lineAtVisibleIndex:(NSInteger)y temporary:&hold];NSMutableString *row=[NSMutableString string];for(NSUInteger x=0;x<_cols;x++)[row appendString:[self stringForCodepoint:line?line[x].ch:' ']];while([row hasSuffix:@" "])[row deleteCharactersInRange:NSMakeRange(row.length-1,1)];[lines addObject:row];}while(lines.count&&[lines.lastObject length]==0)[lines removeLastObject];return [lines componentsJoinedByString:@"\n"];}
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
    return NSFileManager.defaultManager.currentDirectoryPath;
}
@end

@class TWindowController;

@interface TExtensionHost : NSObject
@property NSMutableArray<NSDictionary *> *commands;
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
        NSString *root = [self.directory stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"extension.json"]];
        if (!data) continue;
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *entry = manifest[@"entry"];
        NSString *identifier = manifest[@"id"] ?: name;
        if (!entry.length) continue;
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
                         @"params":@{@"protocolVersion":@1, @"appVersion":@"0.3.0"}} to:identifier];
        } else TLog(@"extension %@ failed to launch: %@", identifier, error.localizedDescription);
    }
    if (self.commandsChanged) self.commandsChanged();
}
- (void)send:(NSDictionary *)message to:(NSString *)identifier {NSPipe *pipe=_inputs[identifier];if(!pipe)return;NSData *json=[NSJSONSerialization dataWithJSONObject:message options:0 error:nil];NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];@try{[pipe.fileHandleForWriting writeData:line];}@catch(NSException *e){} }
- (void)executeCommand:(NSDictionary *)command context:(NSDictionary *)context terminal:(TTerminalView *)terminal {NSString *ext=command[@"extension"];if(!ext)return;self.activeTerminal=terminal;NSMutableDictionary *params=[context mutableCopy];params[@"id"]=command[@"id"]?:@"";[self send:@{@"jsonrpc":@"2.0",@"method":@"command.execute",@"params":params} to:ext];}
@end

@interface TTabRailView : NSView
@property TConfig *config;
@end

@implementation TTabRailView
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirtyRect {[[self.config.background colorWithAlphaComponent:0.98]setFill];NSRectFill(dirtyRect);[[self.config.muted colorWithAlphaComponent:0.28]setFill];NSRectFill(NSMakeRect(self.bounds.size.width-1,0,1,self.bounds.size.height));}
@end

@interface TWindowController : NSWindowController <NSWindowDelegate>
@property TTerminalView *terminal;
@property NSMutableArray<TTerminalView *> *terminals;
@property TConfig *config;
@property TExtensionHost *extensions;
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions;
- (void)addTab;
- (void)closeTab;
- (void)selectTabNumber:(NSInteger)number;
- (void)reloadConfig;
- (BOOL)executeExtensionNamed:(NSString *)name query:(NSString *)query;
@end

@implementation TWindowController { NSString *_cwd; NSView *_root; NSVisualEffectView *_effect; TTabRailView *_tabRail; NSMutableArray<NSButton *> *_tabButtons; }
- (instancetype)initWithConfig:(TConfig *)config extensions:(TExtensionHost *)extensions {
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,920,600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){_config=config;_extensions=extensions;_terminals=[NSMutableArray array];_tabButtons=[NSMutableArray array];window.delegate=(id)self;window.title=@"Termatica";window.titleVisibility=NSWindowTitleHidden;window.titlebarAppearsTransparent=YES;window.styleMask|=NSWindowStyleMaskFullSizeContentView;window.minSize=NSMakeSize(480,280);window.tabbingMode=NSWindowTabbingModeDisallowed;window.movableByWindowBackground=NO;[window center];
        _root=[[NSView alloc]initWithFrame:window.contentView.bounds];_root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;window.contentView=_root;
        _tabRail=[[TTabRailView alloc]initWithFrame:NSZeroRect];_tabRail.config=config;_tabRail.autoresizingMask=NSViewHeightSizable;[_root addSubview:_tabRail];
        [self applyAppearance];[self addTab];
    }return self;
}
- (TTerminalView *)newTerminal {
    TTerminalView *terminal=[[TTerminalView alloc]initWithFrame:_root.bounds config:self.config];terminal.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;__weak typeof(self) weakSelf=self;__weak TTerminalView *weakTerminal=terminal;terminal.titleChanged=^(NSString *title){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self.window.title=title.length?title:@"Termatica";};terminal.cwdChanged=^(NSString *cwd){__strong typeof(weakSelf) self=weakSelf;if(self&&self.terminal==weakTerminal)self->_cwd=cwd;};return terminal;
}
- (void)addTab {TTerminalView *terminal=[self newTerminal];[_terminals addObject:terminal];[_root addSubview:terminal positioned:NSWindowBelow relativeTo:_tabRail];self.terminal=terminal;[self rebuildTabs];[self layoutTabs];[terminal startShell];[self.window makeFirstResponder:terminal];}
- (void)closeTab {if(_terminals.count<=1){[self.window close];return;}NSUInteger index=[_terminals indexOfObject:self.terminal];TTerminalView *closing=self.terminal;[_terminals removeObjectAtIndex:index];[closing removeFromSuperview];self.terminal=_terminals[MIN(index,_terminals.count-1)];[self rebuildTabs];[self layoutTabs];[self.window makeFirstResponder:self.terminal];}
- (void)selectTabButton:(NSButton *)sender {[self selectTabNumber:sender.tag+1];}
- (void)selectTabNumber:(NSInteger)number {NSInteger index=number-1;if(index<0||index>=(NSInteger)_terminals.count)return;self.terminal=_terminals[(NSUInteger)index];_cwd=[self.terminal workingDirectory];[self rebuildTabs];[self layoutTabs];[self.window makeFirstResponder:self.terminal];}
- (void)rebuildTabs {for(NSButton *button in _tabButtons)[button removeFromSuperview];[_tabButtons removeAllObjects];_tabRail.hidden=_terminals.count<2;if(_tabRail.hidden)return;NSUInteger active=[_terminals indexOfObject:self.terminal];for(NSUInteger i=0;i<_terminals.count;i++){NSButton *button=[NSButton buttonWithTitle:[NSString stringWithFormat:@"%lu",(unsigned long)i+1] target:self action:@selector(selectTabButton:)];button.tag=(NSInteger)i;button.bordered=NO;button.wantsLayer=YES;button.layer.cornerRadius=3;button.layer.backgroundColor=i==active?[self.config.selection colorWithAlphaComponent:0.72].CGColor:NSColor.clearColor.CGColor;button.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:i==active?NSFontWeightSemibold:NSFontWeightRegular];button.contentTintColor=i==active?self.config.foreground:self.config.muted;button.accessibilityLabel=[NSString stringWithFormat:@"Terminal tab %lu",(unsigned long)i+1];[_tabRail addSubview:button];[_tabButtons addObject:button];}}
- (void)layoutTabs {CGFloat rail=_terminals.count>1?self.config.tabRailWidth:0,w=_root.bounds.size.width,h=_root.bounds.size.height;_tabRail.frame=NSMakeRect(0,0,rail,h);CGFloat top=_tabRail.safeAreaInsets.top+6;for(NSUInteger i=0;i<_tabButtons.count;i++)_tabButtons[i].frame=NSMakeRect(3,top+i*30,rail-6,24);for(TTerminalView *terminal in _terminals){terminal.hidden=terminal!=self.terminal;terminal.frame=NSMakeRect(rail,0,MAX(1,w-rail),h);}[self.terminal resizeGrid];[_tabRail setNeedsDisplay:YES];}
- (void)windowDidResize:(NSNotification *)notification {[self layoutTabs];}
- (void)applyAppearance {
    self.window.alphaValue=self.config.windowOpacity;self.window.opaque=NO;self.window.backgroundColor=NSColor.clearColor;_tabRail.config=self.config;
    if(!self.config.skeleterm&&!_effect){_effect=[[NSVisualEffectView alloc]initWithFrame:_root.bounds];_effect.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;_effect.blendingMode=NSVisualEffectBlendingModeBehindWindow;[_root addSubview:_effect positioned:NSWindowBelow relativeTo:nil];}
    _effect.hidden=self.config.skeleterm||getenv("TERMATICA_NO_BLUR")!=NULL;_effect.state=self.config.blur?NSVisualEffectStateActive:NSVisualEffectStateInactive;
    if([self.config.blurMaterial isEqual:@"sidebar"])_effect.material=NSVisualEffectMaterialSidebar;else if([self.config.blurMaterial isEqual:@"menu"])_effect.material=NSVisualEffectMaterialMenu;else if([self.config.blurMaterial isEqual:@"popover"])_effect.material=NSVisualEffectMaterialPopover;else _effect.material=NSVisualEffectMaterialHUDWindow;
    for(TTerminalView *terminal in _terminals)[terminal setNeedsDisplay:YES];[self rebuildTabs];[self layoutTabs];
}
- (void)reloadConfig {[self.config reload];for(TTerminalView *terminal in _terminals)[terminal reloadAppearance];[self applyAppearance];}
- (BOOL)executeExtensionNamed:(NSString *)name query:(NSString *)query {NSString *needle=[name hasPrefix:@"/"]?name:[@"/" stringByAppendingString:name];for(NSDictionary *command in self.extensions.commands){if([command[@"slash"] isEqual:needle]||[command[@"id"] isEqual:name]){NSDictionary *ctx=@{@"query":query?:@"",@"cwd":_cwd?:[self.terminal workingDirectory],@"selection":[self.terminal selectedText]?:@"",@"screen":[self.terminal visibleText]?:@""};[self.extensions executeCommand:command context:ctx terminal:self.terminal];return YES;}}return NO;}
@end
static void TApplyMenuShortcut(NSMenuItem *item,NSString *spec) {if(!spec.length){item.keyEquivalent=@"";item.keyEquivalentModifierMask=0;return;}NSArray<NSString *> *parts=[spec.lowercaseString componentsSeparatedByString:@"+"];NSEventModifierFlags mask=0;NSString *key=parts.lastObject;for(NSString *part in parts){if([part isEqual:@"cmd"]||[part isEqual:@"command"])mask|=NSEventModifierFlagCommand;else if([part isEqual:@"shift"])mask|=NSEventModifierFlagShift;else if([part isEqual:@"option"]||[part isEqual:@"alt"])mask|=NSEventModifierFlagOption;else if([part isEqual:@"control"]||[part isEqual:@"ctrl"])mask|=NSEventModifierFlagControl;}if([key isEqual:@"plus"])key=@"+";else if([key isEqual:@"space"])key=@" ";item.keyEquivalent=key?:@"";item.keyEquivalentModifierMask=mask;}
@interface TAppDelegate : NSObject <NSApplicationDelegate>
@property TConfig *config;
@property TExtensionHost *extensions;
@property NSMutableArray<TWindowController *> *windows;
@end

@implementation TAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {_config=[TConfig new];_extensions=[TExtensionHost new];_windows=[NSMutableArray array];[self buildMenu];[NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(handleCLICommand:) name:TCLICommandNotification object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];if(!self.config.skeleterm)[_extensions loadExtensions];[self newWindow:nil];}
- (void)dealloc {[NSDistributedNotificationCenter.defaultCenter removeObserver:self];}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
- (void)newWindow:(id)sender {TWindowController *controller=[[TWindowController alloc]initWithConfig:self.config extensions:self.extensions];[self.windows addObject:controller];[controller showWindow:nil];controller.window.initialFirstResponder=controller.terminal;[controller.window makeFirstResponder:controller.terminal];}
- (TWindowController *)active {return (TWindowController *)NSApp.keyWindow.windowController?:self.windows.lastObject;}
- (void)newTab:(id)sender {[[self active] addTab];}
- (void)closeTab:(id)sender {[[self active] closeTab];}
- (void)selectTab:(NSMenuItem *)sender {[[self active] selectTabNumber:sender.tag];}
- (void)reloadConfig:(id)sender{[self reloadAll];}
- (void)clearTerminal:(id)sender{[[self active].terminal clearTerminal];}
- (void)zoomIn:(id)sender{self.config.fontSize=MIN(48,self.config.fontSize+1);for(TTerminalView *terminal in [self active].terminals)[terminal reloadAppearance];}
- (void)zoomOut:(id)sender{self.config.fontSize=MAX(8,self.config.fontSize-1);for(TTerminalView *terminal in [self active].terminals)[terminal reloadAppearance];}
- (void)zoomReset:(id)sender{self.config.fontSize=11;for(TTerminalView *terminal in [self active].terminals)[terminal reloadAppearance];}
- (void)openConfig:(id)sender{[self.config ensureEditableFile];[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.config.path]];}
- (void)openMarketplaceCategory:(NSString *)category {NSString *command=[category isEqual:@"plugins"]?@"plugins":([category isEqual:@"themes"]?@"themes":([category isEqual:@"profiles"]?@"profiles":@"marketplace"));[[self active].terminal sendString:[NSString stringWithFormat:@"termatica %@\r",command]];[[self active].window makeFirstResponder:[self active].terminal];}
- (void)openMarketplace:(id)sender {[self openMarketplaceCategory:@"all"];}
- (void)reloadAll {[self.config reload];[self buildMenu];if(self.config.skeleterm)[self.extensions unloadExtensions];else[self.extensions loadExtensions];for(TWindowController *window in self.windows)[window reloadConfig];}
- (void)handleCLICommand:(NSNotification *)note {NSDictionary *request=note.userInfo;dispatch_async(dispatch_get_main_queue(),^{NSString *command=request[@"command"];if([command isEqual:@"reload"])[self reloadAll];else if([command isEqual:@"run"]){if(![[self active] executeExtensionNamed:request[@"name"] query:request[@"query"]])TLog(@"extension command not found: %@",request[@"name"]);}else [self openMarketplaceCategory:command];});}
- (void)buildMenu {
    NSDictionary *keys=self.config.keybindings;NSMenu *main=[NSMenu new];NSApp.mainMenu=main;
    NSMenuItem *appItem=[NSMenuItem new];[main addItem:appItem];NSMenu *app=[NSMenu new];appItem.submenu=app;[app addItemWithTitle:@"About Termatica" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];[app addItem:NSMenuItem.separatorItem];NSMenuItem *config=[app addItemWithTitle:@"Open Configuration…" action:@selector(openConfig:) keyEquivalent:@""];TApplyMenuShortcut(config,keys[@"openConfig"]);[app addItem:NSMenuItem.separatorItem];[app addItemWithTitle:@"Hide Termatica" action:@selector(hide:) keyEquivalent:@"h"];[app addItemWithTitle:@"Quit Termatica" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *shellItem=[NSMenuItem new];[main addItem:shellItem];NSMenu *shell=[[NSMenu alloc]initWithTitle:@"Shell"];shellItem.submenu=shell;NSMenuItem *newWindow=[shell addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@""];TApplyMenuShortcut(newWindow,keys[@"newWindow"]);NSMenuItem *newTab=[shell addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@""];TApplyMenuShortcut(newTab,keys[@"newTab"]);NSMenuItem *closeTab=[shell addItemWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@""];TApplyMenuShortcut(closeTab,keys[@"closeTab"]);[shell addItem:NSMenuItem.separatorItem];NSMenuItem *clear=[shell addItemWithTitle:@"Clear Terminal" action:@selector(clearTerminal:) keyEquivalent:@""];TApplyMenuShortcut(clear,keys[@"clearTerminal"]);NSMenuItem *modules=[shell addItemWithTitle:@"Terminal Modules…" action:@selector(openMarketplace:) keyEquivalent:@""];TApplyMenuShortcut(modules,keys[@"modules"]);NSMenuItem *reload=[shell addItemWithTitle:@"Reload Configuration" action:@selector(reloadConfig:) keyEquivalent:@""];TApplyMenuShortcut(reload,keys[@"reload"]);[shell addItem:NSMenuItem.separatorItem];for(NSInteger i=1;i<=9;i++){NSMenuItem *tab=[shell addItemWithTitle:[NSString stringWithFormat:@"Select Tab %ld",(long)i] action:@selector(selectTab:) keyEquivalent:@""];tab.tag=i;tab.target=self;NSString *name=[NSString stringWithFormat:@"tab%ld",(long)i],*fallback=[NSString stringWithFormat:@"cmd+%ld",(long)i];TApplyMenuShortcut(tab,keys[name]?:fallback);}
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
        NSApplication *app=NSApplication.sharedApplication;
        TAppDelegate *delegate=[TAppDelegate new];
        app.delegate=delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
