.PHONY: all build build-device test qemu-test flash docker clean help

DEVICE ?= r8n8
VERSION ?= 0.1.0
KEEP ?=

all: build

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: docker ## Build all device images
	docker compose run --rm build-all

build-device: docker ## Build specific device image (DEVICE=r8n8)
	docker compose run --rm builder ./build-all.sh $(DEVICE)

test: ## Run QEMU tests (requires Docker)
	docker compose run --rm builder ./qemu-test.sh $(DEVICE) 30

qemu-test: ## Run QEMU test locally (no Docker, requires qemu-system-xtensa in PATH)
	./build/qemu-test.sh $(DEVICE) 30

flash: ## Flash device (requires esptool.py and device connected)
	esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 2000000 \
		write_flash 0x0 \
		output/$(DEVICE)/xipImage \
		output/$(DEVICE)/rootfs.cramfs \
		output/$(DEVICE)/etc.jffs2

docker: ## Build Docker image
	docker compose build

clean: ## Clean build artifacts
	rm -rf output/
	docker compose down --rmi local 2>/dev/null || true

# Individual device targets
r8n8: docker ## Build r8n8 (8MB PSRAM + 8MB Flash)
	docker compose run --rm builder ./build-all.sh r8n8

r8n16: docker ## Build r8n16 (8MB PSRAM + 16MB Flash)
	docker compose run --rm builder ./build-all.sh r8n16

r16n16: docker ## Build r16n16 (16MB PSRAM + 16MB Flash)
	docker compose run --rm builder ./build-all.sh r16n16
