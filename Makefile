CONFIGURATION?=release
BUILD_DIR=build
APP=$(BUILD_DIR)/Fluorite.app
BIN_PATH=$(shell swift build -c $(CONFIGURATION) --show-bin-path)
RESOURCE_BUNDLE=Fluorite_Fluorite.bundle
FRAMEWORKS_DIR=$(APP)/Contents/Frameworks
PLUGINS_DIR=$(APP)/Contents/PlugIns
ENTITLEMENTS=Packaging/Fluorite.entitlements

# libpurple's built-in plugins to bundle for a self-contained release, plus
# the generic core utilities. Deliberately excludes protocols outside
# AGENTS.md's scope (Gadu-Gadu, Zephyr, GroupWise, IRC) and anything that
# would pull in GnuTLS or the Tcl/Tk runtime (ssl-gnutls.so, libgg.so,
# tcl.so, perl.so). ssl.so alone covers TLS for XMPP via Secure Transport.
HOMEBREW_PURPLE_PLUGINS_DIR=$(shell brew --prefix pidgin 2>/dev/null)/lib/purple-2
BUNDLED_PLUGINS=libxmpp.so ssl.so libsimple.so autoaccept.so buddynote.so \
	idle.so joinpart.so log_reader.so newline.so offlinemsg.so psychic.so \
	statenotify.so

# Set on the command line for `sign`/`notarize`/`release`, e.g.:
#   make release DEVELOPER_ID_APP="Developer ID Application: NAME (TEAMID)"
DEVELOPER_ID_APP?=
NOTARY_PROFILE?=fluorite-notary

# Release version for the file names of the distributables. It is also
# stamped into the bundle's CFBundleShortVersionString and CFBundleVersion.
# The newest v* tag at HEAD wins; a build without one falls back to
# Packaging/Info.plist. Override it on the command line:
#   make release VERSION=0.2.0 ...
VERSION := $(shell git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed -e 's/^v//')
ifeq ($(strip $(VERSION)),)
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Packaging/Info.plist)
endif

DMG_STAGING=$(BUILD_DIR)/dmg-root
DMG=$(BUILD_DIR)/Fluorite-$(VERSION).dmg

.PHONY: all build app bundle-dylibs stamp-version sign notarize zip dmg release run install clean

all: app

build:
	swift build -c $(CONFIGURATION)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/PlugIns
	cp Packaging/Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	cp $(BIN_PATH)/Fluorite $(APP)/Contents/MacOS/Fluorite
	cp -R $(BIN_PATH)/$(RESOURCE_BUNDLE) $(APP)/Contents/Resources/
	cp Sources/Fluorite/Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp -R Packaging/*.lproj $(APP)/Contents/Resources/
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

# Vendors the Homebrew libpurple/glib dylibs and a curated set of
# libpurple's built-in plugins into the bundle, and rewrites every load
# command to point inside the app instead of at Homebrew. Required before
# `sign`: a Developer ID build cannot depend on libraries that only exist
# at a fixed Homebrew path on the build machine. The plugins must link
# against these SAME vendored dylibs, not fresh copies of their own --
# otherwise glib/gobject loads twice in one process and libpurple's type
# system corrupts at startup (duplicate ObjC class registration).
bundle-dylibs: app
	@command -v dylibbundler >/dev/null 2>&1 || { \
		echo "dylibbundler not found. Install it with: brew install dylibbundler"; exit 1; }
	@test -d "$(HOMEBREW_PURPLE_PLUGINS_DIR)" || { \
		echo "libpurple plugin dir not found at $(HOMEBREW_PURPLE_PLUGINS_DIR). Is pidgin installed via Homebrew?"; exit 1; }
	dylibbundler -od -b -ns \
		-x $(APP)/Contents/MacOS/Fluorite \
		-d $(FRAMEWORKS_DIR) \
		-p @executable_path/../Frameworks/
	for plugin in $(BUNDLED_PLUGINS); do \
		cp "$(HOMEBREW_PURPLE_PLUGINS_DIR)/$$plugin" $(PLUGINS_DIR)/ || exit 1; \
		chmod +w $(PLUGINS_DIR)/$$plugin; \
		dylibbundler -of -cd -b -ns \
			-x $(PLUGINS_DIR)/$$plugin \
			-d $(FRAMEWORKS_DIR) \
			-p @executable_path/../Frameworks/ || exit 1; \
	done
	@# dylibbundler duplicates the app's existing LC_RPATH entries instead
	@# of replacing them; dyld refuses to launch a binary with duplicate
	@# LC_RPATH values, so collapse back down to exactly one.
	@while [ "$$(otool -l $(APP)/Contents/MacOS/Fluorite | grep -c 'cmd LC_RPATH')" -gt 1 ]; do \
		install_name_tool -delete_rpath "@executable_path/../Frameworks/" $(APP)/Contents/MacOS/Fluorite; \
	done
	@if [ "$$(otool -l $(APP)/Contents/MacOS/Fluorite | grep -c 'cmd LC_RPATH')" -eq 0 ]; then \
		install_name_tool -add_rpath "@executable_path/../Frameworks/" $(APP)/Contents/MacOS/Fluorite; \
	fi
	codesign --force --deep --sign - $(APP)
	@echo "Vendored dylibs and plugins into $(APP)"

# Stamps $(VERSION) into the bundle's Info.plist. Runs before any Developer
# ID signature: codesign seals Info.plist, so a later edit breaks the seal.
stamp-version: bundle-dylibs
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(APP)/Contents/Info.plist
	@echo "Stamped $(APP) at version $(VERSION)"

# Signs every embedded dylib and plugin, then the app itself, with
# hardened runtime -- innermost first. Notarization requires Developer ID,
# not the ad-hoc (-) signature `app` and `bundle-dylibs` use for local runs.
sign: stamp-version
	@test -n "$(DEVELOPER_ID_APP)" || { \
		echo 'Set DEVELOPER_ID_APP="Developer ID Application: NAME (TEAMID)"'; exit 1; }
	for dylib in $(FRAMEWORKS_DIR)/*.dylib; do \
		codesign --force --options runtime --timestamp \
			--sign "$(DEVELOPER_ID_APP)" "$$dylib" || exit 1; \
	done
	for plugin in $(PLUGINS_DIR)/*.so; do \
		codesign --force --options runtime --timestamp \
			--sign "$(DEVELOPER_ID_APP)" "$$plugin" || exit 1; \
	done
	codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(DEVELOPER_ID_APP)" $(APP)
	codesign --verify --deep --strict --verbose=2 $(APP)
	@echo "Signed $(APP) with $(DEVELOPER_ID_APP)"

# Submits the signed app for notarization and staples the ticket, so
# Gatekeeper can verify it offline. Requires credentials stored once with:
#   xcrun notarytool store-credentials $(NOTARY_PROFILE) \
#     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
notarize: sign
	ditto -c -k --keepParent $(APP) $(BUILD_DIR)/Fluorite-notarize.zip
	xcrun notarytool submit $(BUILD_DIR)/Fluorite-notarize.zip \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	rm -f $(BUILD_DIR)/Fluorite-notarize.zip
	xcrun stapler staple $(APP)
	spctl --assess --type execute --verbose $(APP)
	@echo "Notarized $(APP)"

# Builds both distributables for a GitHub release: the zip and the DMG.
release: notarize zip dmg

# Zips the stapled app for updaters and no-mount downloads.
zip: notarize
	ditto -c -k --keepParent $(APP) $(BUILD_DIR)/Fluorite-$(VERSION).zip
	@echo "Built $(BUILD_DIR)/Fluorite-$(VERSION).zip"

# Packs the stapled app into Fluorite-<version>.dmg with the drag-to-
# Applications layout from Packaging/dmg-background.tiff. The image then
# gets its own Developer ID signature, its own notarization ticket, and a
# staple: stapling only the app inside does not cover the volume.
# create-dmg places icons through AppleScript, so this needs a GUI session;
# GitHub macOS runners have one. Never pass --skip-jenkins: it skips that
# placement.
dmg: notarize
	@test -n "$(DEVELOPER_ID_APP)" || { \
		echo 'Set DEVELOPER_ID_APP="Developer ID Application: NAME (TEAMID)"'; exit 1; }
	command -v create-dmg >/dev/null || { \
		echo "create-dmg not found. Install it with: brew install create-dmg"; exit 1; }
	rm -f $(DMG)
	rm -rf $(DMG_STAGING)
	mkdir -p $(DMG_STAGING)
	cp -R $(APP) $(DMG_STAGING)/Fluorite.app
	create-dmg \
		--volname "Fluorite" \
		--icon-size 128 \
		--background Packaging/dmg-background.tiff \
		--window-size 660 400 \
		--icon "Fluorite.app" 170 190 \
		--app-drop-link 490 190 \
		$(DMG) $(DMG_STAGING)
	codesign --force --timestamp --sign "$(DEVELOPER_ID_APP)" $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	spctl -a -t open --context context:primary-signature -v $(DMG)
	@echo "Built $(DMG)"

install: app
	mkdir -p ~/Applications
	rm -rf ~/Applications/Fluorite.app
	cp -R $(APP) ~/Applications/

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
