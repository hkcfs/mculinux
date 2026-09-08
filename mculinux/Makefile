.PHONY: all all-devices image test test-loop run clean help \
	r8n8 r8n16 r16n16 toolchain kernel busybox init bootloader rootfs qemu assemble

# Focus device: r8n16 (16MB flash, 8MB PSRAM)
DEVICE ?= r8n16
TIMEOUT ?= 60
# Kernel tracks latest stable (resolve: make latest). Pin to test an older one.
KERNEL_VERSION ?= latest
MAX_ATTEMPTS ?= 3
SCRIPTS := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))scripts

all: ## Build focus device (r8n16)
	$(SCRIPTS)/build.sh $(DEVICE)

all-devices: ## Build all devices (r8n8, r8n16, r16n16)
	$(SCRIPTS)/build.sh r8n8
	$(SCRIPTS)/build.sh r8n16
	$(SCRIPTS)/build.sh r16n16

help: ## Show available targets
	@echo "MCUlinux Makefile (modular, focus: r8n16)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Focus device: r8n16 (16MB flash, 8MB PSRAM)"
	@echo "Kernel: Linux $(KERNEL_VERSION) (override: make KERNEL_VERSION=7.2.3 ...)"
	@echo "Example: make test DEVICE=r8n16 TIMEOUT=60"

# --- Modular component targets (each rebuildable independently) ---
toolchain: ## Build xtensa-esp32s3-linux-muslfdpic toolchain
	$(SCRIPTS)/setup.sh toolchain

kernel: ## Build Linux xipImage (tinyconfig + fragment, latest stable)
	KERNEL_VERSION=$(KERNEL_VERSION) $(SCRIPTS)/build-kernel.sh

busybox: ## Build busybox NOMMU (latest stable) + assemble rootfs
	$(SCRIPTS)/build-busybox-nommu.sh

init: ## Rebuild static init + reassemble rootfs
	$(SCRIPTS)/build-rootfs.sh

rootfs: ## Assemble EROFS rootfs from skeleton (needs make busybox first)
	$(SCRIPTS)/build-rootfs.sh

etc: ## Build etc.jffs2 from rootfs/etc (needs mkfs.jffs2)
	$(SCRIPTS)/build-etc-jffs2.sh

partitions: ## Generate partition-table binaries from partitions/*.csv
	$(SCRIPTS)/build-partition-tables.sh

bootloader: ## Build ESP32-S3 bootloader binaries (idf:latest)
	$(SCRIPTS)/build-bootloader.sh

qemu: ## Install Espressif QEMU with esp32s3 machine
	$(SCRIPTS)/install-qemu-esp32.sh

assemble: ## Assemble flash image from components
	KERNEL_VERSION=$(KERNEL_VERSION) $(SCRIPTS)/build-image.sh $(DEVICE)

image: assemble ## Assemble flash image from prebuilt binaries (alias)

test: assemble ## Build image then boot in QEMU with timeout (fail-fast)
	KERNEL_VERSION=$(KERNEL_VERSION) $(SCRIPTS)/test-qemu.sh $(DEVICE) $(TIMEOUT)

test-loop: assemble ## Build image then retry QEMU boot until pass (MAX_ATTEMPTS)
	@attempt=1; \
	while [ $$attempt -le $(MAX_ATTEMPTS) ]; do \
		echo "=== make test-loop: attempt $$attempt/$(MAX_ATTEMPTS) (DEVICE=$(DEVICE)) ==="; \
		if KERNEL_VERSION=$(KERNEL_VERSION) $(SCRIPTS)/test-qemu.sh $(DEVICE) $(TIMEOUT); then \
			echo "PASS on attempt $$attempt"; exit 0; \
		fi; \
		attempt=$$((attempt+1)); sleep 2; \
	done; \
	echo "FAIL after $(MAX_ATTEMPTS) attempts"; exit 1

run: ## Boot flash image in QEMU (interactive, retry loop)
	$(SCRIPTS)/run-qemu.sh $(DEVICE)

compress: ## Compare filesystem compression variants
	$(SCRIPTS)/compress-test.sh

latest: ## Print latest stable kernel (overall + per branch)
	@echo -n "stable: "; $(SCRIPTS)/latest-stable.sh
	@echo -n "7.1:    "; $(SCRIPTS)/latest-stable.sh 7.1
	@echo -n "7.2:    "; $(SCRIPTS)/latest-stable.sh 7.2

clean: ## Clean output
	rm -rf output/
	@echo "Cleaned output"

r8n8: ## Build r8n8 (8MB flash, 8MB PSRAM)
	$(SCRIPTS)/build.sh r8n8

r8n16: ## Build r8n16 (16MB flash, 8MB PSRAM) [focus device]
	$(SCRIPTS)/build.sh r8n16

r16n16: ## Build r16n16 (16MB flash, 16MB PSRAM)
	$(SCRIPTS)/build.sh r16n16
