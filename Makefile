APP := build/Termatica.app
BIN := $(APP)/Contents/MacOS/Termatica
CLI := $(APP)/Contents/MacOS/termatica
SHORTCLI := $(APP)/Contents/MacOS/t
ZIP := dist/Termatica-macOS-universal.zip
DMG := dist/Termatica-macOS-universal.dmg
PLIST := $(APP)/Contents/Info.plist
ICON := $(APP)/Contents/Resources/AppIcon.icns
THEMES := $(patsubst Resources/Themes/%,$(APP)/Contents/Resources/Themes/%,$(wildcard Resources/Themes/*.json))
SHELL_INTEGRATION := $(shell find Resources/ShellIntegration -type f)
SHELL_INTEGRATION_RESOURCES := $(patsubst Resources/ShellIntegration/%,$(APP)/Contents/Resources/ShellIntegration/%,$(SHELL_INTEGRATION))
SOURCES := $(wildcard src/*.m)
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
ARCH_DIR := build/.arch
COMMON := -fobjc-arc -fmodules -O3 -flto -DNDEBUG -mmacosx-version-min=13.0 -isysroot "$(SDK)" -Wall -Wextra -Wno-unused-parameter -Wl,-dead_strip -framework AppKit -framework Foundation -framework QuartzCore -framework Carbon

.PHONY: all release run clean size install check package benchmark-core benchmark-experience benchmark

all: release

release: $(BIN) $(CLI) $(SHORTCLI) $(PLIST) $(ICON) $(THEMES) $(SHELL_INTEGRATION_RESOURCES)
	codesign --force --sign - $(APP)
	@bytes=$$(find $(APP) -type f -exec stat -f '%z' {} + | awk '{s+=$$1} END {print s}'); \
	  test "$$bytes" -le 1048576 || { echo "Size limit exceeded: $$bytes bytes"; exit 1; }

$(BIN): $(SOURCES)
	@mkdir -p $(dir $@)
	@mkdir -p $(ARCH_DIR)
	xcrun clang $(COMMON) -arch arm64 -o $(ARCH_DIR)/Termatica-arm64 $(SOURCES)
	xcrun clang $(COMMON) -arch x86_64 -o $(ARCH_DIR)/Termatica-x86_64 $(SOURCES)
	lipo -create $(ARCH_DIR)/Termatica-arm64 $(ARCH_DIR)/Termatica-x86_64 -output $@
	strip -x $@

$(CLI): $(BIN)
	ln -sf Termatica $@

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

run: release
	open $(APP)

size: release
	@find $(APP) -type f -exec stat -f '%z' {} + | awk '{s+=$$1} END {printf "%d bytes bundle (%.1f KiB)\n",s,s/1024}'
	@stat -f '%z bytes executable' $(BIN)

benchmark-core: release
	TERMATICA_CONFIG_DIR=/tmp/termatica-core-benchmark $(BIN) --benchmark-core 33554432

benchmark-experience: release
	TERMATICA_CONFIG_DIR=/tmp/termatica-experience-benchmark $(BIN) --benchmark-experience 240 3

benchmark: release
	scripts/benchmark-terminals.sh

install: release
	ditto $(APP) /Applications/Termatica.app

check: release
	@set -eux; tmp=$$(mktemp -d /tmp/termatica-check.XXXXXX); \
	  trap 'rm -rf "$$tmp"' EXIT; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) --version | grep -q '^Termatica 0.9.1$$'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'config-file'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'update check'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) help | grep -q '^QUICK$$'; \
	  test "$$(readlink $(SHORTCLI))" = Termatica; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) v)" = 'Termatica 0.9.1'; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) cf path)" = "$$tmp/config.json"; \
	  ! TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config </dev/null >/dev/null 2>&1; \
	  command -v expect >/dev/null; \
	  TERMATICA_CONFIG_DIR="$$tmp/ui" expect -c 'set timeout 5; spawn $(CLI) config; expect "TERMATICA CONFIG / CONFIG FILES"; expect "CURRENT"; send "\r"; expect "TERMATICA CONFIG / SETTINGS"; send "q"; expect "TERMATICA CONFIG / CONFIG FILES"; send "q"; expect eof' >/dev/null; \
	  config_path=$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config-file path); \
	  test "$$config_path" = "$$tmp/config.json"; \
	  grep -Eq '"textColorMode"[[:space:]]*:[[:space:]]*"ansi"' "$$tmp/config.json"; \
	  grep -Eq '"backgroundOpacity"[[:space:]]*:[[:space:]]*"theme"' "$$tmp/config.json"; \
	  grep -Eq '"borderless-window"[[:space:]]*:[[:space:]]*false' "$$tmp/config.json"; \
	  grep -Eq '"pasteProtection"[[:space:]]*:[[:space:]]*false' "$$tmp/config.json"; \
	  grep -Eq '"restoreSession"[[:space:]]*:[[:space:]]*true' "$$tmp/config.json"; \
	  grep -Eq '"clipboardRead"[[:space:]]*:[[:space:]]*"ask"' "$$tmp/config.json"; \
	  test "$$(plutil -extract updates.repository raw "$$tmp/config.json")" = sebastianmiletic/termatica; \
	  grep -q '"themeOptions"' "$$tmp/config.json"; \
	  ! grep -q '"disabledPlugins"' "$$tmp/config.json"; \
	  ! grep -q '"session"' "$$tmp/config.json"; \
	  ! grep -q '"topBar"' "$$tmp/config.json"; \
	  ! grep -q '"skeleterm"' "$$tmp/config.json"; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set fontSize 13 | grep -q '^fontSize'; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(SHORTCLI) c get fontSize)" = 13; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get fontSize)" = 13; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set appearance.backgroundOpacity 0.42 >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get appearance.backgroundOpacity)" = 0.42; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config set plugins.hidden-path true >/dev/null; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config get plugins.hidden-path)" = ON; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config create dev | grep -q 'SAVED + CURRENT'; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config list | grep -c 'dev')" = 1; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config list | grep -q '^current[[:space:]]dev$$'; \
	  TERMATICA_CONFIG_DIR="$$tmp" expect -c 'set timeout 5; spawn $(CLI) config; expect "CURRENT"; expect "dev"; send "q"; expect eof' >"$$tmp/current-ui.out"; \
	  grep -q 'CURRENT.*dev' "$$tmp/current-ui.out"; \
	  ! grep -q 'ACTIVE.*dev' "$$tmp/current-ui.out"; \
	  test "$$(stat -f '%Lp' "$$tmp/configs/dev.json")" = 600; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config rename dev work | grep -q 'RENAMED'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config use work | grep -q 'CURRENT'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) config delete work | grep -q 'DELETED'; \
	  test ! -e "$$tmp/configs/work.json"; \
	  for removed in code configs plugins themes install marketplace profiles catalog config-dir plugins-dir themes-dir; do \
	    ! TERMATICA_CONFIG_DIR="$$tmp" $(CLI) "$$removed" >/dev/null 2>&1; \
	  done; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) completions zsh | grep -q 'config-file'; \
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
	  grep -Fq '[controller animateLaunchReveal];[controller showWindow:nil]' src/main.m; \
	  ! grep -Fq 'scale.fromValue=@0.965' src/main.m; \
	  ! grep -Fq '[view.layer addAnimation:fade' src/main.m; \
	  grep -Fq 'CGPathAddRoundedRect(path,NULL,NSRectToCGRect(terminal.frame),14,14)' src/main.m; \
	  grep -Fq 'terminal.layer.cornerRadius=tile?14:0' src/main.m; \
	  grep -Fq 'terminal.leadingOverlayInset=0' src/main.m; \
	  ! grep -Fq 'terminal.leadingOverlayInset=overlayInset' src/main.m; \
	  grep -Fq '_kittyKeyboardFlags' src/main.m; \
	  grep -Fq '_modifyOtherKeys' src/main.m; \
	  grep -Fq 'TUnicodeWide' src/main.m; \
	  grep -Fq 'OSC 7' src/main.m; \
	  grep -Fq 'OSC 8' src/main.m; \
	  grep -Fq 'OSC 133' src/main.m; \
	  grep -Fq 'if(k==36||k==76)s=@"\r"' src/main.m; \
	  grep -Fq '[closing stopShellTerminating:YES];[closing removeFromSuperview];TInvalidateSessionSnapshot();' src/main.m; \
	  grep -Fq 'TWriteSessionSnapshot' src/main.m; \
	  grep -Fq 'TReadSessionSnapshot' src/main.m; \
	  grep -Fq 'TAnimateCenterReveal' src/main.m; \
	  grep -Fq '_parseQueue=dispatch_queue_create("com.termatica.core"' src/main.m; \
	  grep -Fq 'dispatch_async(self->_parseQueue,^{[self drainPendingData];})' src/main.m; \
	  grep -Fq 'take=MIN((NSUInteger)65536,available)' src/main.m; \
	  grep -Fq 'routeWheelLines:lines event:event' src/main.m; \
	  test -f $(APP)/Contents/Resources/ShellIntegration/zsh/.zshenv; \
	  test -f $(APP)/Contents/Resources/ShellIntegration/share/fish/vendor_conf.d/termatica.fish; \
	  zsh -n Resources/ShellIntegration/zsh/.zshenv Resources/ShellIntegration/termatica.zsh; \
	  bash -n Resources/ShellIntegration/termatica.bash; \
	  grep -Fq 'terminal.wantsLayer=YES' src/main.m; \
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
	  zsh -n scripts/benchmark-terminals.sh; \
	  python3 -B -c 'compile(open("scripts/benchmark_probe.py").read(), "scripts/benchmark_probe.py", "exec")'; \
	  python3 -B -c 'compile(open("scripts/tui_mouse_probe.py").read(), "scripts/tui_mouse_probe.py", "exec")'; \
	  TERMATICA_CONFIG_DIR="$$tmp/self-test" $(BIN) --terminal-self-test | grep -q '^terminal-self-test ok'; \
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
	  grep -q 'Update available: 0.9.1 -> v9.9.9' "$$tmp/update-check.out"; \
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
