# MCUlinux

Linux for ESP32-S3 — XIP from SPI flash, EROFS rootfs, 8/16MB flash configs.

## Device Matrix

| Config | Flash | PSRAM | Target |
|--------|-------|-------|--------|
| `r8n8` | 8MB | 8MB | ESP32-S3 DevKit-C1 |
| `r8n16` | 16MB | 8MB | ESP32-S3 DevKit-C1 |
| `r16n16` | 16MB | 16MB | ESP32-S3 Box-3 |

## Quick Start

```bash
# Build flash image from prebuilt binaries
make image DEVICE=r8n8

# Boot in QEMU
make test DEVICE=r8n8

# Build all device configs
make all
```

## Prebuilt Binaries

| Component | Size | Description |
|-----------|------|-------------|
| `xipImage-7.1` | 3.6MB | Linux 7.1.3 XIP kernel (ESP32-S3, musl, call0 ABI) |
| `rootfs.erofs` | 2.5MB | EROFS rootfs with busybox (static, initramfs) |
| `bootloader.bin` | 18KB | ESP-IDF bootloader |
| `partition-table.bin` | 3KB | Partition table |
| `network_adapter.bin` | 571KB | WiFi network adapter firmware |

## Flash Layout (8MB example)

| Offset | Size | Partition |
|--------|------|-----------|
| `0x00000` | 4KB | Bootloader |
| `0x08000` | 4KB | Partition Table |
| `0x10000` | 576KB | Network Adapter |
| `0xB0000` | 448KB | etc (JFFS2) |
| `0x120000` | 3.5MB | Linux Kernel (XIP) |
| `0x500000` | 3MB | Root Filesystem (EROFS) |

## Building from Source

### Prerequisites

- xtensa-esp32s3-linux-muslfdpic cross-compiler (from crosstool-NG)
- QEMU with xtensa-esp32s3 support
- Buildroot (for rootfs)

### Full Build

```bash
# One-time setup (installs toolchain, clones repos)
scripts/setup.sh

# Build everything
scripts/build-all.sh
```

### Kernel Patches

ESP32-S3 kernel patches are in `patches/linux-7.1.3/`. Key modifications:

- `gpio-mmio.c`: ESP32 clock GPIO controller support
- `irq-esp32-intc.c`: ESP32 interrupt controller
- `esp32_uart.c`: ESP32 UART serial driver
- `esp32s3.dtsi`: Device tree for ESP32-S3
- `esp32s3-devkit-c1.dts`: Board-level device tree

### QEMU Testing

```bash
# Single device test
make test DEVICE=r8n8

# All devices
make all

# Interactive boot (retry loop)
make run DEVICE=r8n8
```

## Automated Builds

GitHub Actions runs monthly to:
1. Pull latest Linux kernel (7.1.3)
2. Apply ESP32-S3 patches
3. Build XIP kernel (3 configs: r8n8, r8n16, r16n16)
4. Boot-test each image in QEMU
5. Publish release with full boot logs and flash images

## License

GPL-2.0
