CONFIGURATION?=release
BUILD_DIR=build
APP=$(BUILD_DIR)/Adium.app
BIN_PATH=$(shell swift build -c $(CONFIGURATION) --show-bin-path)
RESOURCE_BUNDLE=AdiumSwift_AdiumSwift.bundle

.PHONY: all build app run install clean

all: app

build:
	swift build -c $(CONFIGURATION)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/PlugIns
	cp Packaging/Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	cp $(BIN_PATH)/AdiumSwift $(APP)/Contents/MacOS/AdiumSwift
	cp -R $(BIN_PATH)/$(RESOURCE_BUNDLE) $(APP)/Contents/Resources/
	cp Sources/AdiumSwift/Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
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
