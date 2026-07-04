# MCUlinux

Linux on a microcontroller. ESP32-S3 boots mainline Linux 6.16 in ~5 seconds.

**Website:** [hkcfs.github.io/mculinux](https://hkcfs.github.io/mculinux/)

## What is this?

MCUlinux runs a full Linux kernel on the ESP32-S3 — a $5 microcontroller with 8MB PSRAM. It uses a trimmed 2.8MB kernel, an EROFS+LZMA root filesystem (2.5MB), and boots from an 8MB SPI flash chip. No MMU, no SD card, no Linux board — just a soldering iron and a serial port.

## Supported Devices

| Device | PSRAM | Flash | Status |
|--------|-------|-------|--------|
| r8n8 | 8MB | 8MB | Working |
| r8n16 | 8MB | 16MB | Working |
| r16n16 | 16MB | 16MB | Working |

## Quick Start

### Flash to hardware

```bash
# Download latest release
wget https://github.com/hkcfs/mculinux/releases/latest/download/flash_r8n8.bin

# Flash (adjust port for your system)
esptool.py --chip esp32s3 --port /dev/ttyUSB0 write_flash 0x0 flash_r8n8.bin

# Connect (115200 baud)
screen /dev/ttyUSB0 115200
```

### Test in QEMU (no hardware needed)

```bash
# Install QEMU
sudo apt install qemu-system-misc

# Boot
qemu-system-xtensa -M esp32s3 -nographic -m 8M \
  -global driver=ssi_psram,property=is_octal,value=true \
  -drive file=flash_r8n8.bin,if=mtd,format=raw
```

## Building

```bash
# Clone
git clone https://github.com/hkcfs/mculinux.git
cd mculinux/mculinux

# One-time setup (downloads toolchain, Buildroot, ~30 min)
make setup

# Full build (kernel + flash image + QEMU test)
make rebuild

# Or step by step
make kernel-package    # Build kernel from fork
make image DEVICE=r8n8 # Assemble flash image
make test DEVICE=r8n8  # Boot in QEMU
```

### Build Targets

| Target | Description |
|--------|-------------|
| `make setup` | One-time setup (toolchain, Buildroot, esp-hosted) |
| `make rebuild` | Quick rebuild (kernel + image + test) |
| `make kernel-package` | Build kernel from fork (no Docker) |
| `make image DEVICE=r8n8` | Assemble flash image |
| `make test DEVICE=r8n8` | QEMU boot test |
| `make run` | Interactive QEMU with retry loop |
| `make bootloader` | Build WiFi bootloader (needs Docker) |
| `make compress` | Compare filesystem compression |
| `make clean` | Clean output and build caches |

## Docker Builder

A pre-built Docker image is available with all build dependencies:

```bash
# Pull the builder image
docker pull ghcr.io/hkcfs/mculinux/builder:latest

# Run a build
docker run --rm -v $(pwd):/app -w /app/mculinux \
  ghcr.io/hkcfs/mculinux/builder:latest make rebuild
```

The image is built automatically by CI when `mculinux/docker/Dockerfile` changes.

## Documentation

All documentation is in the [`docs/`](./docs/) folder:

| Document | Description |
|----------|-------------|
| [BUILD-PROCESS.md](./docs/BUILD-PROCESS.md) | Complete build process walkthrough |
| [RESEARCH.md](./docs/RESEARCH.md) | Full investigation log and technical decisions |
| [EROFS-COMPRESSION-RESEARCH.md](./docs/EROFS-COMPRESSION-RESEARCH.md) | Filesystem compression benchmarks |
| [rootfs-filesystem-comparison.md](./docs/rootfs-filesystem-comparison.md) | Comparing EROFS, SquashFS, CramFS |
| [GENERIC-KERNEL-TEST.md](./docs/GENERIC-KERNEL-TEST.md) | Testing mainline kernel (negative result) |
| [ALPINE-PORT-RESEARCH.md](./docs/ALPINE-PORT-RESEARCH.md) | Alpine Linux port investigation |

## Repository Structure

```
mculinux/
├── .github/workflows/     # CI/CD (build, deploy, release)
├── docs/                  # Documentation and research
├── mculinux/              # Build system
│   ├── Makefile           # Main entry point
│   ├── scripts/           # Build scripts
│   ├── build/             # Buildroot, toolchain (gitignored)
│   ├── prebuilt/          # Pre-built bootloader binaries
│   └── output/            # Build output (gitignored)
├── mculinux-packages/     # Package definitions
│   ├── arch/esp32s3/      # Architecture config
│   └── packages/          # APKBUILD manifests
└── website/               # GitHub Pages site
```

## Architecture

```
┌─────────────────────────────────────────────┐
│              Flash Layout (8MB)              │
├──────────┬──────────┬──────────┬────────────┤
│bootloader│partition │ network  │ etc.jffs2  │
│  0x00000 │  0x08000 │  0x10000 │  0x0B0000  │
├──────────┴──────────┴──────────┴────────────┤
│           xipImage (2.8MB)                  │
│              0x120000                       │
├─────────────────────────────────────────────┤
│         rootfs.erofs (2.5MB)                │
│              0x480000                       │
└─────────────────────────────────────────────┘

Kernel: Linux 6.16.0 (jcmvbkbc/linux-xtensa fork)
Rootfs: EROFS + LZMA level 109 (2.5MB)
Toolchain: crosstool-NG 1.25.0.183 (xtensa-esp32s3-linux-muslfdpic)
```

## Technical Details

- **Kernel**: Mainline Linux 6.16 with ESP32-S3 support from [jcmvbkbc/linux-xtensa](https://github.com/jcmvbkbc/linux-xtensa) fork
- **Rootfs**: Alpine-style packages built with EROFS+LZMA compression (smallest option at 2.5MB)
- **Toolchain**: musl-based cross-compiler with FDPIC binary format
- **Boot**: Network adapter firmware loads XIP kernel from SPI flash
- **QEMU**: Supports testing without hardware (`qemu-system-xtensa -M esp32s3`)

## Links

- **Website:** [hkcfs.github.io/mculinux](https://hkcfs.github.io/mculinux/)
- **Releases:** [github.com/hkcfs/mculinux/releases](https://github.com/hkcfs/mculinux/releases)
- **Kernel fork:** [jcmvbkbc/linux-xtensa](https://github.com/jcmvbkbc/linux-xtensa)
- **Buildroot fork:** [jcmvbkbc/buildroot](https://github.com/jcmvbkbc/buildroot)

## License

GPLv2 — see [LICENSE](./LICENSE).
