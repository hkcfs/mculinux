# mculinux-packages

Alpine Linux package manifests for ESP32-S3 microcontrollers.

## Directory Structure

```
mculinux-packages/
├── arch/
│   └── esp32s3/
│       ├── APKBUILD          # Cross-compilation config
│       └── community.repos   # Repository configuration
├── packages/
│   ├── base/
│   │   ├── APKBUILD
│   │   └── source.hash
│   ├── htop/
│   ├── btop/
│   ├── nano/
│   └── ...
├── scripts/
│   └── build-packages.sh
└── README.md
```

## Package List

### Base System
- busybox - Lightweight utilities
- musl libc - Standard C library
- bash - Shell

### Utilities
- htop - Process viewer
- btop - Resource monitor
- nano - Text editor
- coreutils - Basic utilities

## Adding a Package

1. Create a directory under `packages/`
2. Add APKBUILD file
3. Add source.hash for integrity
4. Update package list in README

## Building

```bash
# Build all packages
docker run --rm -v $(pwd):/packages mculinux-builder /scripts/build-packages.sh

# Build specific package
docker run --rm -v $(pwd):/packages mculinux-builder /scripts/build-packages.sh htop
```

## Cross-Compilation

Packages are cross-compiled for Xtensa architecture using:
- Alpine Linux base
- musl libc
- ESP-IDF toolchain
