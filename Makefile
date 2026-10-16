# With only the Command Line Tools installed (no Xcode), Swift Testing's macro
# plugin lives in a subfolder the compiler doesn't search by default.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)

PREFIX ?= $(HOME)/.local

.PHONY: build release test install-cli clean

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

clean:
	swift package clean
