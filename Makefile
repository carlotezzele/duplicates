# With only the Command Line Tools installed (no Xcode), Swift Testing's macro
# plugin lives in a subfolder the compiler doesn't search by default.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)

PREFIX ?= $(HOME)/.local

.PHONY: build release test install-cli app install-app run-app icon clean

build:
	swift build

release:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

install-cli: release
	install -d $(PREFIX)/bin
	install -m 755 .build/release/doppio $(PREFIX)/bin/doppio
	@echo "Installed $(PREFIX)/bin/doppio"

app:
	scripts/build-app.sh

install-app: app
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/Doppio.app
	ditto build/Doppio.app $(HOME)/Applications/Doppio.app
	@echo "Installed $(HOME)/Applications/Doppio.app"

run-app: app
	open build/Doppio.app

icon:
	scripts/make-icon.sh

clean:
	swift package clean
	rm -rf build
