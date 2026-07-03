.PHONY: all bootloader kernel image test compress build clean help

DEVICE ?= r8n8
TIMEOUT ?= 30
SCRIPTS := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))scripts

all: build

help: ## Show available targets
	@echo "MCUlinux Makefile"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Devices: r8n8, r8n16, r16n16"
	@echo "Example: make image DEVICE=r8n8"

build: bootloader kernel image test ## Full build (bootloader + kernel + image + test)

bootloader: ## Build WiFi firmware (network_adapter.bin)
	$(SCRIPTS)/build-bootloader.sh --trimmed

kernel: ## Build kernel + rootfs via Buildroot
	$(SCRIPTS)/build-kernel.sh

image: ## Assemble flash image
	$(SCRIPTS)/build-image.sh $(DEVICE)

test: ## Boot flash image in QEMU
	$(SCRIPTS)/test-qemu.sh $(DEVICE) $(TIMEOUT)

compress: ## Compare filesystem compression variants
	$(SCRIPTS)/compress-test.sh

clean: ## Clean output
	rm -rf output/

r8n8: ## Build r8n8 (8MB flash)
	$(SCRIPTS)/build.sh r8n8

r8n16: ## Build r8n16 (16MB flash)
	$(SCRIPTS)/build.sh r8n16

r16n16: ## Build r16n16 (16MB flash)
	$(SCRIPTS)/build.sh r16n16
