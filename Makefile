APP_NAME := MySkills
BUNDLE_ID := dev.legibet.myskills
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
APP_CONTENTS := $(APP_BUNDLE)/Contents
APP_MACOS := $(APP_CONTENTS)/MacOS
APP_BINARY := $(APP_MACOS)/$(APP_NAME)
INFO_PLIST := $(APP_CONTENTS)/Info.plist
SOURCE_INFO_PLIST := Resources/Info.plist

.PHONY: build bundle sign run verify debug logs telemetry clean

build:
	swift build

bundle: build
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_MACOS)"
	cp "$$(swift build --show-bin-path)/$(APP_NAME)" "$(APP_BINARY)"
	chmod +x "$(APP_BINARY)"
	cp "$(SOURCE_INFO_PLIST)" "$(INFO_PLIST)"

sign: bundle
	codesign --force --sign - "$(APP_BUNDLE)" >/dev/null

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
