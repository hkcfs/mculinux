.PHONY: all bootloader kernel kernel-package image test compress build clean help rebuild

DEVICE ?= r8n8
TIMEOUT ?= 30
SCRIPTS := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))scripts
PKG := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))mculinux-packages/packages/linux-esp32s3

all: ## Build all devices (r8n8, r8n16, r16n16)
	$(SCRIPTS)/build.sh r8n8
	$(SCRIPTS)/build.sh r8n16
	$(SCRIPTS)/build.sh r16n16

setup: ## One-time setup (toolchain, Buildroot, esp-hosted)
	$(SCRIPTS)/setup.sh

help: ## Show available targets
	@echo "MCUlinux Makefile"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Devices: r8n8, r8n16, r16n16"
	@echo "Example: make image DEVICE=r8n8"

build: bootloader kernel image test ## Full build (bootloader + kernel + image + test)

rebuild: kernel-package image test ## Quick rebuild: kernel package + flash image + test

bootloader: ## Build WiFi firmware (network_adapter.bin)
	$(SCRIPTS)/build-bootloader.sh --trimmed

kernel: ## Build kernel + rootfs via Buildroot (Docker)
	$(SCRIPTS)/build-kernel.sh

kernel-package: ## Build kernel from fork (no Docker, uses XTENSA_GNU_CONFIG)
	cd $(PKG) && XTENSA_GNU_CONFIG=$(abspath $(PKG)/../../build/xtensa-dynconfig/esp32s3.so) \
		CROSS_COMPILE=$(abspath $(PKG)/../../build/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-) \
		bash build.sh

kernel-config: ## Edit kernel config (opens menuconfig)
	cd $(PKG)/work/linux-xtensa && \
		XTENSA_GNU_CONFIG=$(abspath $(PKG)/../../build/xtensa-dynconfig/esp32s3.so) \
		make ARCH=xtensa CROSS_COMPILE=$(abspath $(PKG)/../../build/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-) menuconfig

image: ## Assemble flash image
	$(SCRIPTS)/build-image.sh $(DEVICE)

test: ## Boot flash image in QEMU
	$(SCRIPTS)/test-qemu.sh $(DEVICE) $(TIMEOUT)

run: ## Boot flash image in QEMU (interactive, retry loop)
	$(SCRIPTS)/run-qemu.sh $(DEVICE)

compress: ## Compare filesystem compression variants
	$(SCRIPTS)/compress-test.sh

clean: ## Clean output and build caches
	rm -rf output/
	rm -f /tmp/rootfs_*.bin /tmp/flash_*.bin
	@echo "Cleaned output and temp files"

clean-all: clean ## Clean everything including kernel build
	rm -rf $(PKG)/work/linux-xtensa
	@echo "Cleaned kernel source"

r8n8: ## Build r8n8 (8MB flash)
	$(SCRIPTS)/build.sh r8n8

r8n16: ## Build r8n16 (16MB flash)
	$(SCRIPTS)/build.sh r8n16

r16n16: ## Build r16n16 (16MB flash)
	$(SCRIPTS)/build.sh r16n16
