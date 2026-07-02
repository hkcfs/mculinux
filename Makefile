.PHONY: all build build-packages build-images test release clean help

DEVICE ?= r8n8
VERSION ?= 0.1.0
DOCKER_BUILDKIT ?= 1

all: build

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: build-packages build-images ## Build everything

build-packages: ## Build all packages for ESP32-S3
	@echo "Building packages for ESP32-S3..."
	docker build -t mculinux-builder -f docker/Dockerfile.builder .
	docker run --rm -v $(PWD)/mculinux-packages:/packages -v $(PWD)/output:/output mculinux-builder /scripts/build-packages.sh

build-images: ## Build firmware images
	@echo "Building images for $(DEVICE)..."
	docker build -t mculinux-idf -f docker/Dockerfile.idf .
	docker run --rm -v $(PWD)/images:/images -v $(PWD)/output:/output mculinux-idf /scripts/build-image.sh $(DEVICE)

test: ## Run QEMU tests
	@echo "Running QEMU tests..."
	docker build -t mculinux-qemu -f docker/Dockerfile.qemu .
	docker run --rm -v $(PWD)/output:/output mculinux-qemu /scripts/run-tests.sh

release: ## Create release package
	@echo "Creating release $(VERSION)..."
	docker run --rm -v $(PWD):/workspace mculinux-builder /scripts/create-release.sh $(VERSION)

clean: ## Clean build artifacts
	rm -rf output/
	docker rmi mculinux-builder mculinux-idf mculinux-qemu 2>/dev/null || true

docker: ## Build all Docker images
	docker build -t mculinux-builder -f docker/Dockerfile.builder .
	docker build -t mculinux-idf -f docker/Dockerfile.idf .
	docker build -t mculinux-qemu -f docker/Dockerfile.qemu .

flash: ## Flash device (requires esptool.py)
	esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 115200 write_flash 0x0 output/$(DEVICE)/firmware.bin
