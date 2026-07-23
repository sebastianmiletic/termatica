APP := build/Termatica.app
BIN := $(APP)/Contents/MacOS/Termatica
CLI := $(APP)/Contents/MacOS/termatica
ZIP := dist/Termatica-macOS-universal.zip
DMG := dist/Termatica-macOS-universal.dmg
PLIST := $(APP)/Contents/Info.plist
ICON := $(APP)/Contents/Resources/AppIcon.icns
THEMES := $(patsubst Resources/Themes/%,$(APP)/Contents/Resources/Themes/%,$(wildcard Resources/Themes/*.json))
SOURCES := $(wildcard src/*.m)
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
ARCH_DIR := build/.arch
COMMON := -fobjc-arc -fmodules -Oz -flto -DNDEBUG -mmacosx-version-min=13.0 -isysroot "$(SDK)" -Wall -Wextra -Wno-unused-parameter -Wl,-dead_strip -framework AppKit -framework Foundation -framework QuartzCore

.PHONY: all release run clean size install check package

all: release

release: $(BIN) $(CLI) $(PLIST) $(ICON) $(THEMES)
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

$(PLIST): Resources/Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

$(ICON): Resources/AppIcon.icns
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/Themes/%.json: Resources/Themes/%.json
	@mkdir -p $(dir $@)
	cp $< $@

run: release
	open $(APP)

size: release
	@find $(APP) -type f -exec stat -f '%z' {} + | awk '{s+=$$1} END {printf "%d bytes bundle (%.1f KiB)\n",s,s/1024}'
	@stat -f '%z bytes executable' $(BIN)

install: release
	ditto $(APP) /Applications/Termatica.app

check: release
	@set -eux; tmp=$$(mktemp -d /tmp/termatica-check.XXXXXX); \
	  trap 'rm -rf "$$tmp"' EXIT; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) --version | grep -q '^Termatica 0.3.3$$'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'plugins'; \
	  grep -Fq 'if(k==36||k==76)s=@"\r"' src/main.m; \
	  $(CLI) editor list | grep -q 'vim, nvim, emacs, nano, micro, hx'; \
	  printf 'q\n' | TERMATICA_CONFIG_DIR="$$tmp" $(CLI) plugins >/dev/null; \
	  for id in hello pi-bridge editor-deck vim-control neovim-control emacs-control nano-control micro-control helix-control hidden-path hyprland-layout; do \
	    TERMATICA_CONFIG_DIR="$$tmp" $(CLI) install "$$id" >/dev/null; \
	    test -x "$$tmp/extensions/$$id/extension.py"; \
	    if test "$$id" != hyprland-layout && test "$$id" != hidden-path; then \
	      printf '%s\n' '{"method":"initialize"}' | "$$tmp/extensions/$$id/extension.py" >"$$tmp/$$id.out"; \
	      grep -q 'command.register' "$$tmp/$$id.out"; \
	    fi; \
	  done; \
	  test -f "$$tmp/extensions/hidden-path/prompt.sh"; \
	  mkdir -p "$$tmp/home/Coding/OpenCloud"; \
	  HOME="$$tmp/home" zsh -f -c 'cd "$$HOME"; PROMPT="original "; . "$$1" on; _termatica_hidden_path_precmd; test "$$PROMPT" = "; "; . "$$1" off; test "$$PROMPT" = "original "' zsh "$$tmp/extensions/hidden-path/prompt.sh"; \
	  HOME="$$tmp/home" zsh -f -c 'cd "$$HOME/Coding/OpenCloud"; . "$$1" on; _termatica_hidden_path_precmd; test "$$PROMPT" = "Coding/OpenCloud ; "' zsh "$$tmp/extensions/hidden-path/prompt.sh"; \
	  printf 'hidden-path\n' | TERMATICA_CONFIG_DIR="$$tmp" $(CLI) plugins >/dev/null; \
	  grep -q '"hidden-path"' "$$tmp/config.json"; \
	  printf 'hidden-path\n' | TERMATICA_CONFIG_DIR="$$tmp" $(CLI) plugins >/dev/null; \
	  ! grep -q '"hidden-path"' "$$tmp/config.json"; \
	  printf '%s\n' '{"method":"initialize"}' '{"method":"command.execute","params":{"id":"editor.vim","query":"README.md"}}' | "$$tmp/extensions/editor-deck/extension.py" >"$$tmp/editor.out"; \
	  grep -q 'termatica editor vim README.md' "$$tmp/editor.out"; \
	  printf 'hello\n' | TERMATICA_CONFIG_DIR="$$tmp" $(CLI) plugins >/dev/null; \
	  grep -q '"hello"' "$$tmp/config.json"; \
	  printf 'hello\n' | TERMATICA_CONFIG_DIR="$$tmp" $(CLI) plugins >/dev/null; \
	  ! grep -q '"hello"' "$$tmp/config.json"; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) skeleterm >/dev/null; \
	  grep -Eq '"skeleterm"[[:space:]]*:[[:space:]]*true' "$$tmp/config.json"; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) configs save dev | grep -q 'SAVED + ACTIVE'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) configs list | grep -q '^active[[:space:]]dev$$'; \
	  test "$$(stat -f '%Lp' "$$tmp/configs/dev.json")" = 600; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) configs rename dev work | grep -q 'RENAMED'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) configs use work | grep -q 'ACTIVE'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) configs delete work | grep -q 'DELETED'; \
	  test ! -e "$$tmp/configs/work.json"; \
	  test "$$(TERMATICA_CONFIG_DIR="$$tmp" $(CLI) configs path)" = "$$tmp/configs"; \
	  ! TERMATICA_CONFIG_DIR="$$tmp" $(CLI) marketplace >/dev/null 2>&1; \
	  ! TERMATICA_CONFIG_DIR="$$tmp" $(CLI) profiles >/dev/null 2>&1; \
	  ! TERMATICA_CONFIG_DIR="$$tmp" $(CLI) catalog >/dev/null 2>&1; \
	  printf 'amber-crt\nterminal-default\nq\n' | TERMATICA_CONFIG_DIR="$$tmp" $(CLI) themes >/dev/null; \
	  grep -q '"terminal-default"' "$$tmp/config.json"; \
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
