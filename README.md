# MCUlinux

Linux on a microcontroller. ESP32-S3 boots Linux 7.2.x in ~1 second.

**Website:** [hkcfs.github.io/mculinux](https://hkcfs.github.io/mculinux/)

## What is this?

MCUlinux runs a full Linux kernel on the ESP32-S3 — a $5 microcontroller with 8/16MB PSRAM. It uses a trimmed 1.8MB XIP kernel (upstream tinyconfig + our fragment), an EROFS+LZMA root filesystem (1.1MB), JFFS2 `/etc` + `/data`, and boots from SPI flash. No MMU, no SD card, no Linux board — just a soldering iron and a serial port.

## Supported Devices

| Device | PSRAM | Flash | /data | Status |
|--------|-------|-------|-------|--------|
| r8n8 | 8MB | 8MB | 768KB | Working |
| r8n16 | 8MB | 16MB | 8.75MB | Working |
| r16n16 | 16MB | 16MB | 8.75MB | Working |

## Quick Start

### Flash to hardware

```bash
# Download latest release (or build: make image DEVICE=r8n16)
wget https://github.com/hkcfs/mculinux/releases/latest/download/flash_r8n16.bin

# Flash (adjust port for your system)
esptool.py --chip esp32s3 --port /dev/ttyUSB0 write_flash 0x0 flash_r8n16.bin

# Connect (115200 baud)
screen /dev/ttyUSB0 115200
```

### Test in QEMU (no hardware needed)

```bash
cd mculinux
./scripts/install-qemu-esp32.sh   # Espressif QEMU fork (has the esp32s3 machine)
make image DEVICE=r8n16 && make test DEVICE=r8n16
```

## Building

```bash
cd mculinux

# One-time setup (toolchain tarball, dynconfig, esp-hosted)
./scripts/setup.sh

# Full build: latest stable kernel + busybox, from source
make kernel && make busybox && make etc
make image DEVICE=r8n16
make test DEVICE=r8n16
```

No Buildroot: the kernel builds from upstream `tinyconfig` + `patches/linux-esp32/fragment.config`,
the rootfs assembles from `rootfs/` + latest stable busybox.

### Build Targets

| Target | Description |
|--------|-------------|
| `make kernel` | Linux xipImage, latest stable (tinyconfig + fragment) |
| `make busybox` | busybox NOMMU, latest stable + assemble rootfs |
| `make etc` | etc.jffs2 from rootfs/etc |
| `make partitions` | partition-table binaries from partitions/*.csv |
| `make image DEVICE=r8n16` | Assemble flash image |
| `make test DEVICE=r8n16` | QEMU boot test (kernel/tty/login/mounts) |
| `make run` | Interactive QEMU with retry loop |
| `make bootloader` | WiFi bootloader (idf:latest Docker, manual) |
| `make compress` | Compare filesystem compression |
| `make latest` | Print latest stable kernel versions |
| `make clean` | Clean output |

## Docker Images

Pre-built images on GHCR (rebuilt weekly with latest Ubuntu/kernel/busybox):

```bash
# Full builds (kernel + userspace from source)
docker run --rm -v $(pwd):/work -w /work/mculinux \
  ghcr.io/hkcfs/mculinux/builder:latest make kernel

# Fast Boot tests (assemble prebuilts + QEMU)
docker run --rm -v $(pwd):/work -w /work/mculinux \
  ghcr.io/hkcfs/mculinux/tester:latest make test DEVICE=r8n16
```

Built automatically by CI from `mculinux/docker/Dockerfile.{builder,tester}`.

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
| [BRINGUP-7.2.3.md](./docs/BRINGUP-7.2.3.md) | 7.2 port bringup notes (historical) |
| [OPTIMIZATION-EXPERIMENTS.md](./docs/OPTIMIZATION-EXPERIMENTS.md) | Memory diet experiments E0-E9 |

## Repository Structure

```
mculinux/
├── .github/workflows/     # CI/CD (build, docker, release, deploy-website)
├── docs/                  # Documentation and research
├── mculinux/              # Build system
│   ├── Makefile           # Main entry point
│   ├── scripts/           # Build/test scripts (14, all live)
│   ├── patches/           # linux-esp32 (0001-0007 + fragment) + busybox-nommu
│   ├── rootfs/            # Skeleton /etc (feeds rootfs.erofs + etc.jffs2)
│   ├── partitions/        # Partition-table CSVs per flash size
│   ├── docker/            # Dockerfile.builder/.tester
│   ├── tools/             # gen_esp32part.py, prebuilt binaries, QEMU
│   ├── build/             # Toolchain, esp-hosted (gitignored)
│   └── output/            # Build output (gitignored)
└── website/               # GitHub Pages site + web flasher
```

## Architecture

```
┌─────────────────────────────────────────────┐
│              Flash Layout (8MB)              │
├──────────┬──────────┬──────────┬────────────┤
│bootloader│partition │ network  │ etc.jffs2  │
│  0x00000 │  0x08000 │  0x10000 │  0x0B0000  │
├──────────┴──────────┴──────────┴────────────┤
│           xipImage (1.8MB)                  │
│              0x120000                       │
├─────────────────────────────────────────────┤
│         rootfs.erofs (1.1MB)                │
│              0x500000                       │
├─────────────────────────────────────────────┤
│      data.jffs2 (768K / 8.75MB)             │
│              0x740000                       │
└─────────────────────────────────────────────┘

Kernel: Linux 7.2.x (vanilla + patches/linux-esp32, tinyconfig + fragment)
Rootfs: EROFS + LZMA (1.1MB) + JFFS2 /etc (448KB) + JFFS2 /data (tail)
Toolchain: xtensa-esp32s3-linux-muslfdpic-gcc 14.0.1 (musl FDPIC)
```

## Technical Details

- **Kernel**: Vanilla kernel.org stable (always latest in CI) + ESP32-S3 patches (UART, IRQ, MTD, IPC, GPIO-clk, platform, DTS)
- **Rootfs**: busybox (always latest stable, NOMMU) + static init, EROFS+LZMA
- **Writable storage**: JFFS2 `/etc` (448KB) and `/data` (flash tail: 768KB–8.75MB)
- **Toolchain**: musl-based cross-compiler with FDPIC binary format (prebuilt release tarball)
- **Boot**: Network adapter firmware loads XIP kernel from SPI flash
- **QEMU**: Espressif fork (`-M esp32s3`); r16n16 emulated with full 16MB PSRAM

## Links

- **Website:** [hkcfs.github.io/mculinux](https://hkcfs.github.io/mculinux/)
- **Releases:** [github.com/hkcfs/mculinux/releases](https://github.com/hkcfs/mculinux/releases)
- **Actions:** [github.com/hkcfs/mculinux/actions](https://github.com/hkcfs/mculinux/actions)

## License

GPLv2 — see [LICENSE](./LICENSE).
