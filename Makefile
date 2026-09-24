# LocalBoard — local-only Kanban and project management for macOS.
#
# Config/AppInfo.xcconfig is the single source of truth for naming, so this
# file reads it rather than repeating the values.

SHELL := /bin/bash
CONFIGURATION ?= release

APP_NAME  := $(shell sed -n 's/^APP_DISPLAY_NAME[[:space:]]*=[[:space:]]*//p' Config/AppInfo.xcconfig)
CLI_NAME  := $(shell sed -n 's/^APP_CLI_NAME[[:space:]]*=[[:space:]]*//p' Config/AppInfo.xcconfig)
BUNDLE_ID := $(shell sed -n 's/^APP_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' Config/AppInfo.xcconfig)

APP_BUNDLE      := dist/$(APP_NAME).app
APP_INSTALL_DIR ?= $(HOME)/Applications
BIN_INSTALL_DIR ?= $(HOME)/.local/bin
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: help build test bundle install uninstall run where verify clean

help:
	@echo "$(APP_NAME) — make targets"
	@echo
	@echo "  build      Compile every target (debug)"
	@echo "  test       Run the test suites"
	@echo "  bundle     Assemble $(APP_NAME).app into dist/"
	@echo "  install    Bundle, then install the app and the $(CLI_NAME) CLI"
	@echo "  uninstall  Remove both. Your boards are left untouched."
	@echo "  run        Launch the app from dist/ without installing"
	@echo "  where      Print the data folders"
	@echo "  verify     Check that nothing reaches the network"
	@echo "  clean      Remove build products"

build:
	swift build

test:
	swift test

bundle:
	@Scripts/bundle-spm.sh $(CONFIGURATION)

install: bundle
	@mkdir -p "$(APP_INSTALL_DIR)"
	@rm -rf "$(APP_INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "$(APP_INSTALL_DIR)/"
	@$(LSREGISTER) -f "$(APP_INSTALL_DIR)/$(APP_NAME).app"
	@echo "installed $(APP_INSTALL_DIR)/$(APP_NAME).app"
	@mkdir -p "$(BIN_INSTALL_DIR)"
	@swift build -c $(CONFIGURATION) --product $(CLI_NAME)
	@cp "$$(swift build -c $(CONFIGURATION) --show-bin-path)/$(CLI_NAME)" "$(BIN_INSTALL_DIR)/$(CLI_NAME)"
	@echo "installed $(BIN_INSTALL_DIR)/$(CLI_NAME)"
	@if ! echo "$$PATH" | tr ':' '\n' | grep -qx "$(BIN_INSTALL_DIR)"; then \
	    echo; \
	    echo "note: $(BIN_INSTALL_DIR) is not on your PATH. Add it with:"; \
	    echo "  echo 'export PATH=\"$(BIN_INSTALL_DIR):\$$PATH\"' >> ~/.zshrc"; \
	fi

uninstall:
	@-$(LSREGISTER) -u "$(APP_INSTALL_DIR)/$(APP_NAME).app" 2>/dev/null
	@rm -rf "$(APP_INSTALL_DIR)/$(APP_NAME).app"
	@rm -f "$(BIN_INSTALL_DIR)/$(CLI_NAME)"
	@echo "removed the app and the CLI"
	@echo "your boards are still in ~/Library/Containers/$(BUNDLE_ID)"

run: bundle
	open "$(APP_BUNDLE)"

where:
	@swift run -c $(CONFIGURATION) $(CLI_NAME) where

verify:
	@Scripts/verify-no-network.sh

clean:
	rm -rf .build dist
