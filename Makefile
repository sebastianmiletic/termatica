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
COMMON := -fobjc-arc -fmodules -Os -flto -DNDEBUG -mmacosx-version-min=13.0 -isysroot "$(SDK)" -Wall -Wextra -Wno-unused-parameter -framework AppKit -framework Foundation

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
	@tmp=$$(mktemp -d /tmp/termatica-check.XXXXXX); \
	  trap 'rm -rf "$$tmp"' EXIT; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) --version | grep -q '^Termatica 0.3.0$$'; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) help | grep -q 'plugins'; \
	  $(CLI) editor list | grep -q 'vim, nvim, emacs, nano, micro, hx'; \
	  printf 'q\n' | TERMATICA_CONFIG_DIR="$$tmp" $(CLI) plugins >/dev/null; \
	  TERMATICA_CONFIG_DIR="$$tmp" $(CLI) install editor-deck >/dev/null; \
	  test -x "$$tmp/extensions/editor-deck/extension.py"; \
	  printf '%s\n' '{"method":"initialize"}' '{"method":"command.execute","params":{"id":"editor.vim","query":"README.md"}}' | "$$tmp/extensions/editor-deck/extension.py" | grep -q 'termatica editor vim README.md'; \
	  echo "Termatica checks passed"

package: check
	@mkdir -p dist build/dmg
	@rm -f $(ZIP) $(DMG) dist/SHA256SUMS
	@rm -rf build/dmg/Termatica.app build/dmg/Applications
	ditto $(APP) build/dmg/Termatica.app
	ln -s /Applications build/dmg/Applications
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(ZIP)
	hdiutil create -ov -volname Termatica -srcfolder build/dmg -format UDZO $(DMG)
	shasum -a 256 $(DMG) $(ZIP) > dist/SHA256SUMS
	@echo "Release artifacts written to dist/"

clean:
	rm -rf build
