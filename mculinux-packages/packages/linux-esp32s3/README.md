# Linux ESP32-S3 Kernel Package

Mainline Linux kernel with ESP32-S3 support patches from the jcmvbkbc/linux-xtensa fork.

## What This Does

1. Downloads the latest stable Linux kernel from kernel.org
2. Applies ESP32-S3 patches (Xtensa variant, drivers, DTS)
3. Builds the kernel for ESP32-S3
4. Outputs xipImage and DTB

## Quick Start

```bash
# Build latest stable kernel
./build.sh

# Build specific version
./build.sh 6.16

# Extract patches from fork (first time only)
./extract-patches.sh
```

## Directory Structure

```
linux-esp32s3/
├── APKBUILD              # Alpine package build file
├── build.sh              # Automated build script
├── extract-patches.sh    # Extract patches from jcmvbkbc fork
├── README.md
├── configs/
│   └── esp32s3_defconfig # Kernel config fragment
├── patches/              # ESP32-S3 patches (generated)
│   ├── 001-xtensa-esp32s3-variant.patch
│   ├── 002-esp32-platform.patch
│   └── ...
└── work/                 # Build artifacts (gitignored)
```

## Patches

The patches add the following ESP32-S3 support to mainline Linux:

| Patch | Component | Description |
|-------|-----------|-------------|
| 001 | Xtensa variant | ESP32-S3 core definition (ISA, registers) |
| 002 | Platform | ESP32 platform support (XIP, noMMU) |
| 003 | IRQ controller | ESP32 interrupt matrix |
| 004 | Clock controller | ESP32-S3 clock initialization |
| 005 | UART | Serial console driver |
| 006 | GPIO | 49-pin GPIO driver |
| 007 | SPI | SPI master controller |
| 008 | TRNG | Hardware random number generator |
| 009 | IPC | Inter-processor communication |
| 010 | MTD flash | Flash access via IPC |
| 011 | USB ACM | USB CDC ACM gadget |
| 012 | USB PHY | ESP32-S3 USB PHY |
| 013 | DTS | Device tree for ESP32-S3 |
| 014 | WiFi | Espressif WiFi driver |
| 015 | Kconfig | Configuration options |

## How It Works

### Automated Build (build.sh)

The build script:
1. Queries kernel.org for latest stable version
2. Downloads and extracts the kernel tarball
3. Applies all ESP32-S3 patches
4. Configures kernel with ESP32-S3 defconfig
5. Builds xipImage and DTBs
6. Outputs to `output/<version>/`

### Patch Extraction (extract-patches.sh)

The extraction script:
1. Clones the jcmvbkbc/linux-xtensa fork
2. Identifies all ESP32-S3 specific files
3. Generates individual patches for each component
4. Saves to `patches/` directory

## Kernel Config

The kernel uses these key config options:

```
CONFIG_XTENSA_VARIANT_CUSTOM=y
CONFIG_XTENSA_VARIANT_CUSTOM_NAME="esp32s3"
CONFIG_XTENSA_PLATFORM_ESP32=y
CONFIG_XIP_KERNEL=y
CONFIG_KERNEL_LOAD_ADDRESS=0x42120000
CONFIG_XIP_DATA_ADDR=0x3d800000
CONFIG_BUILTIN_DTB_NAME="esp32s3-devkit-c1"
CONFIG_MTD_ESP32=y
CONFIG_SERIAL_ESP32=y
CONFIG_GPIO_ESP32=y
CONFIG_SPI_ESP32=y
CONFIG_ESP32_WIFI=y
```

## Testing

After building, test with QEMU:

```bash
# Build flash image
make image DEVICE=r8n8

# Test in QEMU
make test DEVICE=r8n8
```

## Troubleshooting

### Patch fails to apply
- Check if the fork has been updated
- Re-run `./extract-patches.sh` to regenerate patches

### Build fails
- Check `output/<version>/build-*.log` for errors
- Ensure cross-compiler is installed: `xtensa-esp32s3-linux-muslfdpic-gcc`

### Kernel doesn't boot
- Verify DTB is correct for your board
- Check memory layout matches your hardware
