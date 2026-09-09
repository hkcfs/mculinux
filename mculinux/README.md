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
| `xipImage-7.2` | 1.8MB | Linux 7.2.x XIP kernel (ESP32-S3, musl, call0 ABI) |
| `rootfs.erofs` | 1.2MB | EROFS rootfs with busybox (static, initramfs) |
| `bootloader.bin` | 18KB | ESP-IDF bootloader |
| `partition-table.bin` | 3KB | Partition table |
| `network_adapter.bin` | 571KB | WiFi network adapter firmware |

## Flash Layout (8MB example)

| Offset | Size | Partition |
|--------|------|-----------|
| `0x00000` | 4KB | Bootloader |
| `0x08000` | 4KB | Partition Table |
| `0x10000` | 576KB | Network Adapter |
| `0xB0000` | 448KB | etc (JFFS2, writable) |
| `0x120000` | 3904KB | Linux Kernel (XIP) |
| `0x500000` | 2.25MB | Root Filesystem (EROFS, read-only) |
| `0x740000` | rest | data (JFFS2, writable: 768K / 8.75MB) |

## Building from Source

### Prerequisites

- xtensa-esp32s3-linux-muslfdpic cross-compiler (`make setup` fetches it)
- QEMU with xtensa-esp32s3 support (`make qemu`)
- `mkfs.erofs` (erofs-utils) for rootfs, `mkfs.jffs2` (mtd-utils) for `make etc`

No Buildroot — kernel builds from tinyconfig + fragment, rootfs assembles
from `rootfs/` + busybox.

### Full Build

```bash
# One-time setup (toolchain tarball, dynconfig, esp-hosted)
make setup 2>/dev/null || scripts/setup.sh

# Build everything (latest stable kernel + busybox)
make kernel && make busybox && make etc
make image DEVICE=r8n8 && make test DEVICE=r8n8
```

### Kernel Patches

ESP32-S3 kernel patches are in `patches/linux-esp32/` (`0001-0008`), plus
`fragment.config` — our deltas on upstream `tinyconfig`. Key modifications:

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

GitHub Actions (`build.yml`):
- **fast** (push/PR): assemble committed prebuilts + QEMU boot-test all devices
- **full** (nightly + dispatch): rebuild latest stable kernel + busybox +
  rootfs + jffs2 from source, test all devices, commit fresh binaries back
- **docker** (Dockerfile changes + weekly): rebuild builder/tester images
  (re-resolves latest Ubuntu/kernel/busybox)

## License

GPL-2.0
