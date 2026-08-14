APP := build/Termatica.app
BIN := $(APP)/Contents/MacOS/Termatica
BENCH := build/TermaticaBenchmark
CLI := $(APP)/Contents/MacOS/termatica
SHORTCLI := $(APP)/Contents/MacOS/t
ZIP := dist/Termatica-macOS-universal.zip
DMG := dist/Termatica-macOS-universal.dmg
PLIST := $(APP)/Contents/Info.plist
ICON := $(APP)/Contents/Resources/AppIcon.icns
THEMES := $(patsubst Resources/Themes/%,$(APP)/Contents/Resources/Themes/%,$(wildcard Resources/Themes/*.json))
SHELL_INTEGRATION := $(shell find Resources/ShellIntegration -type f)
SHELL_INTEGRATION_RESOURCES := $(patsubst Resources/ShellIntegration/%,$(APP)/Contents/Resources/ShellIntegration/%,$(SHELL_INTEGRATION))
BENCHMARK_RESOURCES := $(APP)/Contents/Resources/Benchmarks/benchmark-live-matrix.sh
SOURCES := $(wildcard src/*.m)
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
ARCH_DIR := build/.arch
COMMON := -fobjc-arc -fmodules -flto -DNDEBUG -mmacosx-version-min=13.0 -isysroot "$(SDK)" -Wall -Wextra -Wno-unused-parameter -Wl,-dead_strip -framework AppKit -framework Foundation -framework QuartzCore -framework Carbon -framework Metal -framework CoreText -framework CoreVideo

.PHONY: all release run clean size install check package benchmark-harness benchmark-decoder benchmark-core benchmark-experience benchmark-metal benchmark

all: release

release: $(BIN) $(SHORTCLI) $(PLIST) $(ICON) $(THEMES) $(SHELL_INTEGRATION_RESOURCES) $(BENCHMARK_RESOURCES)
	codesign --force --sign - $(APP)
	@bytes=$$(find $(APP) -type f -exec stat -f '%z' {} + | awk '{s+=$$1} END {print s}'); \
	  test "$$bytes" -le 1572864 || { echo "Size limit exceeded: $$bytes bytes"; exit 1; }

$(BIN): $(SOURCES)
	@mkdir -p $(dir $@)
	@mkdir -p $(ARCH_DIR)
	xcrun clang $(COMMON) -O3 -arch arm64 -o $(ARCH_DIR)/Termatica-arm64 $(SOURCES)
	xcrun clang $(COMMON) -O3 -arch x86_64 -o $(ARCH_DIR)/Termatica-x86_64 $(SOURCES)
	strip -x $(ARCH_DIR)/Termatica-arm64 $(ARCH_DIR)/Termatica-x86_64
	rm -f $@
	lipo -create -segalign x86_64 0x1000 -segalign arm64 0x4000 $(ARCH_DIR)/Termatica-arm64 $(ARCH_DIR)/Termatica-x86_64 -output $@
	strip -x $@

$(BENCH): $(SOURCES)
	@mkdir -p $(dir $@)
	xcrun clang $(COMMON) -O3 -DTERMATICA_BENCHMARKS=1 -arch $$(uname -m) -o $@ $(SOURCES)
	strip -x $@

benchmark-harness: $(BENCH)

$(SHORTCLI): $(BIN)
	ln -sf Termatica $@

$(PLIST): Resources/Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

$(ICON): Resources/AppIcon.icns
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/Themes/%.json: Resources/Themes/%.json
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/ShellIntegration/%: Resources/ShellIntegration/%
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/Benchmarks/benchmark-live-matrix.sh: scripts/benchmark-live-matrix.sh
	@mkdir -p $(dir $@)
	cp $< $@
	chmod 755 $@

run: release
	open $(APP)

size: release
	@find $(APP) -type f -exec stat -f '%z' {} + | awk '{s+=$$1} END {printf "%d bytes bundle (%.1f KiB)\n",s,s/1024}'
	@stat -f '%z bytes executable' $(BIN)

benchmark-decoder: $(BENCH)
	TERMATICA_CONFIG_DIR=/tmp/termatica-decoder-benchmark $(BENCH) --benchmark-decoder 33554432

benchmark-core: $(BENCH)
	TERMATICA_CONFIG_DIR=/tmp/termatica-core-benchmark $(BENCH) --benchmark-core 33554432

benchmark-experience: $(BENCH)
	TERMATICA_CONFIG_DIR=/tmp/termatica-experience-benchmark $(BENCH) --benchmark-experience 240 10

benchmark-metal: $(BENCH)
	TERMATICA_CONFIG_DIR=/tmp/termatica-metal-benchmark $(BENCH) --benchmark-metal 240

benchmark: release $(BENCH)
	scripts/benchmark-terminals.sh

install: release
	ditto $(APP) /Applications/Termatica.app

check: release $(BENCH)
	@set -eux; tmp=$$(mktemp -d /tmp/termatica-check.XXXXXX); \
	  trap 'rm -rf "$$tmp"' EXIT; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) --version | grep -q '^Termatica 1.12.1$$'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'config-file'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'update check'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'benchmark \[all\].*Benchmark Termatica only'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) help | grep -q '^QUICK$$'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) help | grep -q 't b.*Benchmark'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) help | grep -q 't b a.*Benchmark all'; \
	  test "$$(readlink $(SHORTCLI))" = Termatica; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) v)" = 'Termatica 1.12.1'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'renderer-report'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'renderer-retry'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'renderer-qualification'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'renderer-campaign'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions zsh | grep -q 'renderer-retry'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions zsh | grep -q 'renderer-qualification'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions zsh | grep -q 'renderer-campaign'; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) cf path)" = "$$tmp/config.json"; \
	  ! TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config </dev/null >/dev/null 2>&1; \
	  command -v expect >/dev/null; \
	  TERMATICA_CONFIG_DIR="$$tmp/ui" expect -c 'set timeout 5; spawn $(CLI) config; expect "TERMATICA CONFIG / CONFIG FILES"; expect "CURRENT"; send "\r"; expect "TERMATICA CONFIG / SETTINGS"; send "q"; expect "TERMATICA CONFIG / CONFIG FILES"; send "q"; expect eof' >/dev/null; \
	  TERMATICA_CONFIG_DIR="$$tmp/ui-toggle" expect -c 'set timeout 5; spawn $(CLI) config; expect "CURRENT"; send "\r"; expect "TERMATICA CONFIG / SETTINGS"; send "\033\[B\033\[B\033\[B\033\[B\033\[B\033\[B\033\[B\r"; expect "TERMATICA CONFIG / PLUGINS"; expect -re "BORDERLESS-WINDOW +OFF"; send "\r"; expect -re "BORDERLESS-WINDOW +ON"; send "q"; expect "TERMATICA CONFIG / SETTINGS"; send "q"; expect "TERMATICA CONFIG / CONFIG FILES"; send "q"; expect eof' >/dev/null; \
	  TERMATICA_CONFIG_DIR="$$tmp/ui-arrows" expect -c 'set timeout 8; spawn $(CLI) config; expect "CURRENT"; send "\r"; expect "TERMATICA CONFIG / SETTINGS"; send "\033\[B\r"; expect "TERMATICA CONFIG / TEXT & COLOUR"; expect -re "Font name +Monaco"; send "\033\[C"; expect "SAVED + RELOADED"; send "\033\[B\033\[B\033\[C"; expect "SAVED + RELOADED"; send "q"; expect "TERMATICA CONFIG / SETTINGS"; send "\033\[B\033\[B\033\[B\033\[B\033\[B\033\[B\033\[B\r"; expect "TERMATICA CONFIG / SYSTEM & UPDATES"; send "\033\[C"; expect "SAVED + RELOADED"; send "\033\[B\033\[C"; expect "SAVED + RELOADED"; send "q"; expect "TERMATICA CONFIG / SETTINGS"; send "\033\[B\r"; expect "TERMATICA CONFIG / KEYBINDINGS"; send "\033\[C"; expect "SAVED + RELOADED"; send "q"; expect "TERMATICA CONFIG / SETTINGS"; send "q"; expect "TERMATICA CONFIG / CONFIG FILES"; send "q"; expect eof' >/dev/null; \
	  TERMATICA_CONFIG_DIR="$$tmp/ui-surfaces" expect -c 'set timeout 8; spawn $(CLI) config; expect "CURRENT"; send "\r"; expect "TERMATICA CONFIG / SETTINGS"; send "\033\[B\033\[B\033\[B\r"; expect "TERMATICA CONFIG / WINDOW & SURFACES"; send "\033\[B\033\[B\033\[B\033\[B\033\[C"; expect "SAVED + RELOADED"; send "\033"; expect "TERMATICA CONFIG / SETTINGS"; send "\033"; expect "TERMATICA CONFIG / CONFIG FILES"; send "\033"; expect eof' >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp/ui-surfaces" $(CLI) config get window.cornerRadius)" = 15; \
	  mkdir -p "$$tmp/migrate"; \
	  mkdir -p "$$tmp/migrate/screens"; \
	  printf '%s\n' '{"plugins":{"hidden-path":true},"skeleterm":0,"system":{"restoreSession":true,"pasteProtection":false}}' >"$$tmp/migrate/config.json"; \
	  printf '%s\n' '{"legacy":"terminal state"}' >"$$tmp/migrate/session.json"; \
	  printf '%s\n' 'legacy screen text' >"$$tmp/migrate/screens/pane.txt"; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp/migrate" $(CLI) config get plugins.hidden-path)" = ON; \
	  grep -Eq '"hidden-path"[[:space:]]*:[[:space:]]*"on"' "$$tmp/migrate/config.json"; \
	  grep -Eq '"pasteProtection"[[:space:]]*:[[:space:]]*"off"' "$$tmp/migrate/config.json"; \
	  ! grep -q '"restoreSession"' "$$tmp/migrate/config.json"; \
	  ! grep -q '"skeleterm"' "$$tmp/migrate/config.json"; \
	  test ! -e "$$tmp/migrate/session.json"; \
	  test ! -e "$$tmp/migrate/screens"; \
	  config_path=$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config-file path); \
	  test "$$config_path" = "$$tmp/config.json"; \
	  grep -Eq '"textColorMode"[[:space:]]*:[[:space:]]*"ansi"' "$$tmp/config.json"; \
	  grep -Eq '"backgroundOpacity"[[:space:]]*:[[:space:]]*"theme"' "$$tmp/config.json"; \
	  grep -Eq '"borderless-window"[[:space:]]*:[[:space:]]*"off"' "$$tmp/config.json"; \
	  grep -Eq '"checkOnLaunch"[[:space:]]*:[[:space:]]*"on"' "$$tmp/config.json"; \
	  grep -Eq '"pasteProtection"[[:space:]]*:[[:space:]]*"off"' "$$tmp/config.json"; \
	  ! grep -q '"restoreSession"' "$$tmp/config.json"; \
	  grep -Eq '"clipboardRead"[[:space:]]*:[[:space:]]*"ask"' "$$tmp/config.json"; \
	  test "$$(plutil -extract updates.repository raw "$$tmp/config.json")" = sebastianmiletic/termatica; \
	  grep -q '"themeOptions"' "$$tmp/config.json"; \
	  ! grep -q '"disabledPlugins"' "$$tmp/config.json"; \
	  ! grep -q '"session"' "$$tmp/config.json"; \
	  ! grep -q '"topBar"' "$$tmp/config.json"; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set fontSize 13 | grep -q '^fontSize'; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) c get fontSize)" = 13; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get fontSize)" = 13; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set appearance.backgroundOpacity 0.42 >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get appearance.backgroundOpacity)" = 0.42; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set appearance.renderer metal >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get appearance.renderer)" = metal; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set appearance.renderer appkit >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get appearance.renderer)" = appkit; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set plugins.hidden-path on >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get plugins.hidden-path)" = ON; \
	  grep -Eq '"hidden-path"[[:space:]]*:[[:space:]]*"on"' "$$tmp/config.json"; \
	  ! grep -Eq ':[[:space:]]*(true|false)([,}])' "$$tmp/config.json"; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config create dev | grep -q 'SAVED + CURRENT'; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get fontSize)" = 11; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get appearance.renderer)" = appkit; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get theme)" = terminal-default; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get plugins.hidden-path)" = OFF; \
	  test "$$(plutil -extract fontSize raw "$$tmp/configs/dev.json")" = 11; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config list | grep -c 'dev')" = 1; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config list | grep -q '^current[[:space:]]dev$$'; \
	  TERMATICA_CONFIG_DIR="$$tmp" expect -c 'set timeout 5; spawn $(CLI) config; expect "CURRENT"; expect "dev"; send "q"; expect eof' >"$$tmp/current-ui.out"; \
	  grep -q 'CURRENT.*dev' "$$tmp/current-ui.out"; \
	  ! grep -q 'ACTIVE.*dev' "$$tmp/current-ui.out"; \
	  test "$$(stat -f '%Lp' "$$tmp/configs/dev.json")" = 600; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config rename dev work | grep -q 'RENAMED'; \
	  test ! -e "$$tmp/configs/dev.json"; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config use work | grep -q 'CURRENT'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config delete work | grep -q 'DELETED'; \
	  test ! -e "$$tmp/configs/work.json"; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config create alpha >/dev/null; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set fontSize 20 >/dev/null; \
	  test "$$(plutil -extract fontSize raw "$$tmp/configs/alpha.json")" = 20; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config create beta >/dev/null; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set fontSize 30 >/dev/null; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config use alpha >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get fontSize)" = 20; \
	  plutil -replace fontSize -integer 21 "$$tmp/config.json"; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get fontSize)" = 21; \
	  test "$$(plutil -extract fontSize raw "$$tmp/configs/alpha.json")" = 21; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config use beta >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get fontSize)" = 30; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config use alpha >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get fontSize)" = 21; \
	  printf '%s\n' '{"fontSize":17,"tabs":{"tileGap":3}}' >"$$tmp/configs/partial.json"; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config use partial >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get fontSize)" = 17; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get tabs.tileGap)" = 3; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get tabs.railWidth)" = 34; \
	  test "$$(plutil -extract configName raw "$$tmp/configs/partial.json")" = partial; \
	  test "$$(plutil -extract schemaVersion raw "$$tmp/configs/partial.json")" = 1; \
	  test "$$(stat -f '%Lp' "$$tmp/config.json")" = 600; \
	  test "$$(stat -f '%Lp' "$$tmp/configs/partial.json")" = 600; \
	  mkdir -p "$$tmp/orphan"; \
	  printf '%s\n' '{"configName":"portable","fontSize":19}' >"$$tmp/orphan/config.json"; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp/orphan" $(CLI) config get fontSize)" = 19; \
	  test "$$(plutil -extract configName raw "$$tmp/orphan/configs/portable.json")" = portable; \
	  for removed in code configs plugins themes install skeleterm marketplace profiles catalog config-dir plugins-dir themes-dir; do \
	    ! TERMATICA_CONFIG_DIR="$$tmp" $(CLI) "$$removed" >/dev/null 2>&1; \
	  done; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions zsh | grep -q 'config-file'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions zsh | grep -q 'benchmark'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions zsh | grep -q '#compdef termatica t'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions bash | grep -q 'update'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions bash | grep -q 'termatica t'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions fish | grep -q 'rename'; \
	  ! TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions zsh | grep -q 'plugins'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions install >/dev/null; \
	  test -f "$$tmp/completions/_termatica"; \
	  test -f "$$tmp/completions/termatica.zsh"; \
	  test -f "$$tmp/completions/termatica.bash"; \
	  test -f "$$tmp/completions/termatica.fish"; \
	  zsh -n "$$tmp/completions/_termatica"; \
	  zsh -n "$$tmp/completions/termatica.zsh"; \
	  bash -n "$$tmp/completions/termatica.bash"; \
	  TERM_COMPLETION_DIR="$$tmp/completions" FPATH="$$tmp/completions:/usr/local/share/zsh/site-functions:/usr/share/zsh/site-functions:/usr/share/zsh/5.9/functions" zsh -flic 'source "$$TERM_COMPLETION_DIR/termatica.zsh"; test "$${_comps[termatica]}" = _termatica; test "$${_comps[t]}" = _termatica'; \
	  grep -Fq 'canBecomeKeyWindow {return YES;}' src/main.m; \
	  grep -Fq 'terminal.topContentInset=self.config.topBar?0:6' src/main.m; \
	  grep -Fq 'BOOL animateTerminal=animate&&(!tile||!_enteringTerminal||terminal==_enteringTerminal)' src/main.m; \
	  grep -Fq 'BOOL animateWindow=self.window.isVisible&&self.config.tabAnimations' src/main.m; \
	  grep -Fq 'tabRailAvailable {return _terminals.count>1&&!self.config.hyprlandLayout;}' src/main.m; \
	  grep -Fq 'if(![self tabRailAvailable]){_animateTabLayout=NO;[self suppressTabRail]' src/main.m; \
	  grep -Fq '[controller showWindow:nil];dispatch_async(dispatch_get_main_queue(),^{[controller animateLaunchReveal];})' src/main.m; \
	  ! grep -Fq 'scale.fromValue=@0.965' src/main.m; \
	  ! grep -Fq '[view.layer addAnimation:fade' src/main.m; \
	  grep -Fq 'CGPathAddRoundedRect(path,NULL,NSRectToCGRect(terminal.frame),self.config->tileCornerRadius,self.config->tileCornerRadius)' src/main.m; \
	  grep -Fq 'terminal.layer.cornerRadius=tile?self.config->tileCornerRadius:0' src/main.m; \
	  grep -Fq 'poll(&descriptor,1,60)' src/main.m; \
	  grep -Fq '@"window.tileCornerRadius"' src/main.m; \
	  grep -Fq '@"terminalUI.cursorThickness"' src/main.m; \
	  ! grep -Fq '@"terminalUI->' src/main.m; \
	  grep -Fq 'terminal.leadingOverlayInset=0' src/main.m; \
	  ! grep -Fq 'terminal.leadingOverlayInset=overlayInset' src/main.m; \
	  grep -Fq '_kittyKeyboardFlags' src/main.m; \
	  grep -Fq '_modifyOtherKeys' src/main.m; \
	  grep -Fq 'TUnicodeWide' src/main.m; \
	  grep -Fq 'OSC 7' src/main.m; \
	  grep -Fq 'OSC 8' src/main.m; \
	  grep -Fq 'OSC 133' src/main.m; \
	  grep -Fq 'if(!s&&(k==36||k==76))s=@"\r"' src/main.m; \
	  grep -Fq '[closing stopShellTerminating:YES];[closing removeFromSuperview];[self.window close];' src/main.m; \
	  grep -Fq 'TDECSpecialGraphics' src/main.m; \
	  ! grep -Fqi 'tmux' src/main.m; \
	  ! grep -Fq 'TWriteSessionSnapshot' src/main.m; \
	  ! grep -Fq 'TReadSessionSnapshot' src/main.m; \
	  ! grep -Fq 'checkpointSession' src/main.m; \
	  grep -Fq 'TAnimateCenterReveal' src/main.m; \
	  grep -Fq '_parseQueue=dispatch_queue_create("com.termatica.core"' src/main.m; \
	  grep -Fq 'dispatch_async(self->_parseQueue,^{[self drainPendingData];})' src/main.m; \
	  grep -Fq 'dataWithBytesNoCopy:buffer' src/main.m; \
	  grep -Fq 'TDecoderConsume(&_decoder' src/main.m; \
	  grep -Fq 't b a' src/main.m; \
	  grep -Fq 'FRESH TERMATICA BENCHMARK' scripts/benchmark-live-matrix.sh; \
	  grep -Fq 'FRESH ALL-TERMINAL BENCHMARK' scripts/benchmark-live-matrix.sh; \
	  grep -Fq 'result_path=' scripts/benchmark-live-matrix.sh; \
	  grep -Fq 'task.currentDirectoryURL=[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]' src/main.m; \
	  grep -Fq 'cd "$$work" || exit 1' scripts/benchmark-live-matrix.sh; \
	  grep -Fq 'TBenchmarkResultsController' src/main.m; \
	  grep -Fq 'NSTextView *comparisonTextView' src/main.m; \
	  grep -Fq 'adaptive-text all-data no-wrap winner=bold' src/main.m; \
	  ! grep -Fq 'Parser ASCII          309.1' src/main.m; \
	  test -x $(APP)/Contents/Resources/Benchmarks/benchmark-live-matrix.sh; \
	  zsh -n scripts/benchmark-live-matrix.sh; \
	  grep -Fq 'routeWheelLines:lines event:event' src/main.m; \
	  test -f $(APP)/Contents/Resources/ShellIntegration/zsh/.zshenv; \
	  test -f $(APP)/Contents/Resources/ShellIntegration/share/fish/vendor_conf.d/termatica.fish; \
	  zsh -n Resources/ShellIntegration/zsh/.zshenv Resources/ShellIntegration/termatica.zsh; \
	  bash -n Resources/ShellIntegration/termatica.bash; \
	  grep -Fq 'terminal.wantsLayer=tile||animateTerminal||[terminal usesMetalRenderer]' src/main.m; \
	  grep -Fq '_scrollAccumulator' src/main.m; \
	  grep -Fq '_alternateScroll' src/main.m; \
	  grep -Fq 'poll(&descriptor,1,20)' src/main.m; \
	  grep -Fq 'NSKernAttributeName:@(cellKern)' src/main.m; \
	  grep -Fq 'termatica.rail.fold' src/main.m; \
	  grep -Fq '"backgroundOpacity": 0.28' Resources/Themes/ghost-glass.json; \
	  grep -Fq '"#FF6B6B"' Resources/Themes/ghost-glass.json; \
	  grep -Fq '"#7CE38B"' Resources/Themes/ghost-glass.json; \
	  grep -Fq '"#67B7F7"' Resources/Themes/ghost-glass.json; \
	  grep -Fq '"cursor": "#F2FAF8"' Resources/Themes/ghost-glass.json; \
	  ! grep -Fq '"colorizePlainText": true' Resources/Themes/ghost-glass.json; \
	  grep -Fq '"plainTextPalette"' Resources/Themes/ghost-glass.json; \
	  grep -Fq '_colorScratch' src/main.m; \
	  ! grep -Fq 'THyprlandCanvasView' src/main.m; \
	  ! grep -Fq '#if 0' src/main.m; \
	  zsh -n scripts/benchmark-terminals.sh; \
	  python3 -B -c 'compile(open("scripts/benchmark_probe.py").read(), "scripts/benchmark_probe.py", "exec")'; \
	  python3 -B -c 'compile(open("scripts/tui_mouse_probe.py").read(), "scripts/tui_mouse_probe.py", "exec")'; \
	  TERMATICA_CONFIG_DIR="$$tmp/self-test" $(BENCH) --terminal-self-test | grep -q '^terminal-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/renderer-test" $(BENCH) --renderer-self-test | grep -q '^renderer-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/renderer-switch-test" $(BENCH) --renderer-switch-self-test | grep -q '^renderer-switch-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/renderer-parity-test" $(BENCH) --renderer-parity-self-test | grep -q '^renderer-parity-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/renderer-cache-test" $(BENCH) --renderer-cache-self-test | grep -q '^renderer-cache-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/renderer-scheduler-test" $(BENCH) --renderer-scheduler-self-test | grep -q '^renderer-scheduler-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/renderer-reliability-test" $(BENCH) --renderer-reliability-self-test | grep -q '^renderer-reliability-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/phase6-field-test" $(BENCH) --phase6-field-self-test | grep -q '^phase6-field-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/phase7-production-test" $(BENCH) --phase7-production-self-test | grep -q '^phase7-production-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/phase8-recovery-test" $(BENCH) --phase8-recovery-self-test | grep -q '^phase8-recovery-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/phase9-field-test" $(BENCH) --phase9-field-self-test | grep -q '^phase9-field-self-test ok'; \
	  TERMATICA_CONFIG_DIR="$$tmp/phase10-campaign-test" $(BENCH) --phase10-campaign-self-test | grep -q '^phase10-campaign-self-test ok'; \
	  if [ -z "$${CI:-}" ]; then TERMATICA_CONFIG_DIR="$$tmp/tui-compat-test" $(BENCH) --tui-compat-self-test | grep -q '^tui-compat-self-test ok'; fi; \
	  TERMATICA_CONFIG_DIR="$$tmp/renderer-comparison" $(BENCH) --benchmark-experience 30 0.5 >"$$tmp/renderer-comparison.json"; \
	  test "$$(stat -f '%z' "$$tmp/renderer-comparison.json")" -gt 4096; \
	  python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); assert data["schema_version"]==5; assert set(data["renderer_comparison"])=={"methodology","appkit","metal"}' "$$tmp/renderer-comparison.json"; \
	  $(BENCH) --benchmark-results-self-test | grep -q '^benchmark-results-self-test ok'; \
	  $(BENCH) --decoder-self-test | grep -q '^decoder-self-test ok'; \
	  $(CLI) editor list | grep -q 'vim, nvim, emacs, nano, micro, hx'; \
	  fixture="$$tmp/release-fixture"; \
	  mkdir -p "$$fixture" "$$tmp/install-target"; \
	  ditto $(APP) "$$fixture/Termatica.app"; \
	  plutil -replace CFBundleShortVersionString -string 9.9.9 "$$fixture/Termatica.app/Contents/Info.plist"; \
	  plutil -replace CFBundleVersion -string 999 "$$fixture/Termatica.app/Contents/Info.plist"; \
	  codesign --force --sign - "$$fixture/Termatica.app"; \
	  ditto -c -k --keepParent "$$fixture/Termatica.app" "$$fixture/Termatica-macOS-universal.zip"; \
	  digest=$$(shasum -a 256 "$$fixture/Termatica-macOS-universal.zip" | awk '{print $$1}'); \
	  fixture_url="file://$$fixture/Termatica-macOS-universal.zip"; \
	  printf '{"tag_name":"v9.9.9","assets":[{"name":"Termatica-macOS-universal.zip","browser_download_url":"%s","digest":"sha256:%s"}]}\n' "$$fixture_url" "$$digest" > "$$fixture/release.json"; \
	  set +e; \
	  TERMATICA_CONFIG_DIR="$$tmp" TERMATICA_UPDATE_API="file://$$fixture/release.json" $(CLI) update check >"$$tmp/update-check.out"; \
	  update_status=$$?; \
	  set -e; \
	  test "$$update_status" = 10; \
	  grep -q 'Update available: 1.12.1 -> v9.9.9' "$$tmp/update-check.out"; \
	  TERMATICA_CONFIG_DIR="$$tmp" TERMATICA_UPDATE_API="file://$$fixture/release.json" TERMATICA_UPDATE_DESTINATION="$$tmp/install-target/Termatica.app" $(CLI) update >"$$tmp/update.out"; \
	  test "$$(defaults read "$$tmp/install-target/Termatica.app/Contents/Info" CFBundleShortVersionString)" = 9.9.9; \
	  codesign --verify --deep --strict "$$tmp/install-target/Termatica.app"; \
	  printf '{"tag_name":"v9.9.9","assets":[{"name":"Termatica-macOS-universal.zip","browser_download_url":"%s","digest":"sha256:%064d"}]}\n' "$$fixture_url" 0 > "$$fixture/bad-release.json"; \
	  ! TERMATICA_CONFIG_DIR="$$tmp" TERMATICA_UPDATE_API="file://$$fixture/bad-release.json" TERMATICA_UPDATE_DESTINATION="$$tmp/install-target/Termatica.app" $(CLI) update >/dev/null 2>&1; \
	  test "$$(defaults read "$$tmp/install-target/Termatica.app/Contents/Info" CFBundleShortVersionString)" = 9.9.9; \
	  echo "Termatica checks passed"

package: check
	@mkdir -p dist build/dmg
	@rm -f $(ZIP) $(DMG) dist/SHA256SUMS
	@rm -rf build/dmg/Termatica.app build/dmg/Applications
	ditto $(APP) build/dmg/Termatica.app
	ln -s /Applications build/dmg/Applications
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(ZIP)
	hdiutil create -ov -volname Termatica -srcfolder build/dmg -format UDZO $(DMG)
	cd dist && shasum -a 256 $(notdir $(DMG)) $(notdir $(ZIP)) > SHA256SUMS
	@echo "Release artifacts written to dist/"

clean:
	rm -rf build
