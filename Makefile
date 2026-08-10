APP_NAME = Speed Reader
SCHEME = SpeedReader
ARCH = $(shell uname -m)
DESTINATION = platform=macOS,arch=$(ARCH)
BUILD_DIR = SpeedReader/.build
VERSION = $(shell grep MARKETING_VERSION SpeedReader/Config.xcconfig | cut -d'=' -f2 | tr -d ' ')
RELEASE_DIR = $(BUILD_DIR)/Build/Products/Release
DEBUG_DIR = $(BUILD_DIR)/Build/Products/Debug
PROJECT = SpeedReader/SpeedReader.xcodeproj

.PHONY: generate build release run dev dmg dmg-release install uninstall clean help

all: help

generate:
	@xcodegen generate --spec SpeedReader/project.yml --project SpeedReader

build: generate
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build -quiet -derivedDataPath $(BUILD_DIR) -destination '$(DESTINATION)'

release: generate
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release build -quiet -derivedDataPath $(BUILD_DIR) -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO

run: release
	@open "$(RELEASE_DIR)/$(APP_NAME).app"

dev: build
	@open "$(DEBUG_DIR)/$(APP_NAME).app"

dmg: release
	@./scripts/create-dmg.sh --no-sign

dmg-release: release
	@./scripts/create-dmg.sh --notarize

install: uninstall release
	@cp -rf "$(RELEASE_DIR)/$(APP_NAME).app" /Applications/

uninstall:
	@rm -rf "/Applications/$(APP_NAME).app"

clean:
	@rm -rf $(BUILD_DIR) dist

help:
	@echo "Speed Reader Build System"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  generate      - Regenerate Xcode project from project.yml"
	@echo "  build         - Build debug version"
	@echo "  release       - Build release version (universal binary)"
	@echo "  run           - Build release and open app"
	@echo "  dev           - Build debug and open app"
	@echo "  dmg           - Create .dmg installer (unsigned)"
	@echo "  dmg-release   - Create signed and notarized .dmg installer"
	@echo "  install       - Install to /Applications"
	@echo "  uninstall     - Remove from /Applications"
	@echo "  clean         - Remove build artifacts"
