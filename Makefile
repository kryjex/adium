CONFIGURATION?=release
BUILD_DIR=build
APP=$(BUILD_DIR)/Adium.app
BIN_PATH=$(shell swift build -c $(CONFIGURATION) --show-bin-path)
RESOURCE_BUNDLE=AdiumSwift_AdiumSwift.bundle

.PHONY: all build plugins app run install clean

all: app

build:
	swift build -c $(CONFIGURATION)

# purple-gowhatsapp's reference Makefile targets Linux; on macOS the Go runtime
# additionally needs CoreFoundation/Security and libresolv at link time.
GOWHATSAPP_LDFLAGS = $(shell pkg-config --libs glib-2.0 purple opusfile gdk-pixbuf-2.0) -framework CoreFoundation -framework Security -lresolv

plugins:
	$(MAKE) -C Plugins/purple-gowhatsapp libwhatsmeow.so CGO_LDFLAGS="$(GOWHATSAPP_LDFLAGS)"
	for dir in Plugins/*/; do \
		[ "$$dir" = "Plugins/purple-gowhatsapp/" ] && continue; \
		if [ -f "$$dir/Makefile" ]; then $(MAKE) -C "$$dir" || exit 1; fi; \
	done

app: build plugins
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/PlugIns
	cp Packaging/Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	cp $(BIN_PATH)/AdiumSwift $(APP)/Contents/MacOS/AdiumSwift
	cp -R $(BIN_PATH)/$(RESOURCE_BUNDLE) $(APP)/Contents/Resources/
	cp Sources/AdiumSwift/Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	for plugin in Plugins/*/*.so; do \
		case "$$plugin" in Plugins/template/*) continue;; esac; \
		if [ -f "$$plugin" ]; then cp "$$plugin" $(APP)/Contents/PlugIns/; fi; \
	done
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

install: app
	mkdir -p ~/Applications
	rm -rf ~/Applications/Adium.app
	cp -R $(APP) ~/Applications/

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
