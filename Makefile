APP_NAME := MySkills
BUNDLE_ID := dev.legibet.myskills
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
APP_CONTENTS := $(APP_BUNDLE)/Contents
APP_MACOS := $(APP_CONTENTS)/MacOS
APP_RESOURCES := $(APP_CONTENTS)/Resources
APP_BINARY := $(APP_MACOS)/$(APP_NAME)
INFO_PLIST := $(APP_CONTENTS)/Info.plist
SOURCE_INFO_PLIST := Resources/Info.plist
APP_ICON := Resources/AppIcon.icon
MIN_MACOS := 26.0
DMG_ROOT := $(DIST_DIR)/dmg
DMG_PATH := $(DIST_DIR)/$(APP_NAME).dmg
BUILD_OPTIONS :=

.PHONY: build bundle sign release-app dmg publish run verify debug logs telemetry clean

build:
	swift build $(BUILD_OPTIONS)

bundle: build
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_MACOS)" "$(APP_RESOURCES)"
	cp "$$(swift build $(BUILD_OPTIONS) --show-bin-path)/$(APP_NAME)" "$(APP_BINARY)"
	chmod +x "$(APP_BINARY)"
	cp "$(SOURCE_INFO_PLIST)" "$(INFO_PLIST)"
	@# actool resolves relative paths against its daemon's working directory, so pass absolute ones.
	xcrun actool "$(CURDIR)/$(APP_ICON)" --compile "$(CURDIR)/$(APP_RESOURCES)" \
		--output-partial-info-plist "$(CURDIR)/$(DIST_DIR)/AppIcon.partial.plist" \
		--app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target $(MIN_MACOS) \
		--output-format human-readable-text --errors --warnings

sign: bundle
	codesign --force --sign - "$(APP_BUNDLE)" >/dev/null
	codesign --verify --deep --strict "$(APP_BUNDLE)"

release-app:
	$(MAKE) sign BUILD_OPTIONS="-c release --arch arm64"

dmg: release-app
	rm -rf "$(DMG_ROOT)" "$(DMG_PATH)"
	mkdir -p "$(DMG_ROOT)"
	ditto "$(APP_BUNDLE)" "$(DMG_ROOT)/$(APP_NAME).app"
	ln -s /Applications "$(DMG_ROOT)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_ROOT)" -format UDZO -ov "$(DMG_PATH)"
	hdiutil verify "$(DMG_PATH)"
	rm -rf "$(DMG_ROOT)"

publish: dmg
	@test -z "$$(git status --porcelain)" || (echo "Commit your changes before publishing."; exit 1)
	git tag -f latest HEAD
	git push origin refs/tags/latest --force
	@commit="$$(git rev-parse --short HEAD)"; \
	if gh release view latest >/dev/null 2>&1; then \
		gh release upload latest "$(DMG_PATH)" --clobber; \
		gh release edit latest --title "Latest" --notes "Built from commit $$commit." --latest; \
	else \
		gh release create latest "$(DMG_PATH)" --title "Latest" --notes "Built from commit $$commit." --latest; \
	fi

run: sign
	pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true
	/usr/bin/open -n "$(APP_BUNDLE)"

verify: run
	sleep 1
	pgrep -x "$(APP_NAME)" >/dev/null

debug: sign
	lldb -- "$(APP_BINARY)"

logs: run
	/usr/bin/log stream --info --style compact --predicate 'process == "$(APP_NAME)"'

telemetry: run
	/usr/bin/log stream --info --style compact --predicate 'subsystem == "$(BUNDLE_ID)"'

clean:
	rm -rf .build "$(DIST_DIR)"
