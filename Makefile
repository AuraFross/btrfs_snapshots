PLUGIN   := btrfs-snapshots
VERSION  := $(shell grep 'ENTITY version' $(PLUGIN).plg 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/' || echo "dev")
BUILD_DIR := build
SRC_DIR  := src
TEST_DIR := /tmp/$(PLUGIN)-test

.PHONY: build clean version install-local

## build: Build the .txz plugin package
build:
	@chmod +x build.sh
	@./build.sh $(VERSION)

## clean: Remove build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR)
	@rm -f $(PLUGIN)-*.txz
	@rm -f $(PLUGIN)-*.md5
	@rm -f $(PLUGIN)-*.sha256
	@echo "Clean complete."

## version: Display the current plugin version
version:
	@echo "$(PLUGIN) v$(VERSION)"

## install-local: Copy plugin files to a local test path for development
install-local:
	@echo "Installing $(PLUGIN) v$(VERSION) to $(TEST_DIR)..."
	@mkdir -p $(TEST_DIR)/usr/local/emhttp/plugins/$(PLUGIN)
	@mkdir -p $(TEST_DIR)/boot/config/plugins/$(PLUGIN)
	@cp -r $(SRC_DIR)/usr/local/emhttp/plugins/$(PLUGIN)/* \
		$(TEST_DIR)/usr/local/emhttp/plugins/$(PLUGIN)/
	@if [ -f $(SRC_DIR)/usr/local/emhttp/plugins/$(PLUGIN)/default.cfg ]; then \
		cp $(SRC_DIR)/usr/local/emhttp/plugins/$(PLUGIN)/default.cfg \
			$(TEST_DIR)/boot/config/plugins/$(PLUGIN)/$(PLUGIN).cfg; \
	fi
	@chmod +x $(TEST_DIR)/usr/local/emhttp/plugins/$(PLUGIN)/scripts/* 2>/dev/null || true
	@chmod +x $(TEST_DIR)/usr/local/emhttp/plugins/$(PLUGIN)/event/* 2>/dev/null || true
	@echo "Installed to $(TEST_DIR)"
	@echo "  Plugin dir: $(TEST_DIR)/usr/local/emhttp/plugins/$(PLUGIN)/"
	@echo "  Config dir: $(TEST_DIR)/boot/config/plugins/$(PLUGIN)/"
