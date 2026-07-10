.PHONY: all image test run clean help r8n8 r8n16 r16n16

DEVICE ?= r8n8
KERNEL ?= 6.16
TIMEOUT ?= 30
SCRIPTS := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))scripts

all: ## Build all devices (r8n8, r8n16, r16n16)
	$(SCRIPTS)/build.sh r8n8
	$(SCRIPTS)/build.sh r8n16
	$(SCRIPTS)/build.sh r16n16

help: ## Show available targets
	@echo "MCUlinux Makefile"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Devices: r8n8, r8n16, r16n16"
	@echo "Kernels: 6.16, 7.1 (default: 7.1)"
	@echo "Example: make image DEVICE=r8n8 KERNEL=7.1"

image: ## Assemble flash image from prebuilt binaries
	$(SCRIPTS)/build-image.sh $(DEVICE) --kernel $(KERNEL)

test: ## Boot flash image in QEMU
	$(SCRIPTS)/test-qemu.sh $(DEVICE) $(TIMEOUT)

run: ## Boot flash image in QEMU (interactive, retry loop)
	$(SCRIPTS)/run-qemu.sh $(DEVICE)

compress: ## Compare filesystem compression variants
	$(SCRIPTS)/compress-test.sh

clean: ## Clean output
	rm -rf output/
	@echo "Cleaned output"

r8n8: ## Build r8n8 (8MB flash)
	$(SCRIPTS)/build.sh r8n8

r8n16: ## Build r8n16 (16MB flash)
	$(SCRIPTS)/build.sh r8n16

r16n16: ## Build r16n16 (16MB flash)
	$(SCRIPTS)/build.sh r16n16
