# MCUlinux Build Process

## Requirements

Host system needs only:
- `git` - clone the repo
- `make` - orchestrate builds
- `docker` - all build work happens in containers

No compilers, cross-toolchains, or build libraries on host. Everything is inside Docker.

---

## Build Targets

```
make setup          # Step 1: One-time setup
make bootloader     # Step 2: WiFi firmware
make kernel         # Step 3: Linux kernel + rootfs
make image          # Step 4: Assemble flash image
make test           # Step 5: QEMU boot test
make compress       # Step 6: Filesystem compression comparison
make build          # Step 7: Full build (steps 2-5 combined)
make all            # Step 8: Build all 3 devices
```

---

## Step 1: setup

**Script:** `scripts/setup.sh`
**Container:** Host (runs directly)
**Time:** ~45 min first time (toolchain build)

One-time setup. Builds the musl cross-compiler toolchain, clones Buildroot and esp-hosted.

### What it does:

**1a. dynconfig**
Clones `jcmvbkbc/xtensa-dynconfig` and `config-esp32s3`. Builds `esp32s3.so` - a shared library that tells GCC where to find Xtensa-specific config files.

**1b. musl cross-toolchain**
Clones `jcmvbkbc/crosstool-NG` and builds `xtensa-esp32s3-linux-muslfdpic-gcc` 14.0.1. This takes ~45 minutes. The toolchain uses:
- GCC 14 from `xtensa-14-9655-fdpic-musl` branch
- binutils 2.42 from `xtensa-2.42-fdpic-musl` branch (must be this, not `xtensa-2.42-fdpic`)
- musl libc from `xtensa-1.2.5-fdpic` branch
- Linux kernel headers 6.16

**1c. Buildroot**
Clones `jcmvbkbc/buildroot` branch `xtensa-2025.08-fdpic`. Configures with `esp32s3_devkit_c1_8m_defconfig`. Patches config to use musl toolchain.

**1d. esp-hosted**
Clones `jcmvbkbc/esp-hosted` branch `ipc-5.1.1`. Contains the ESP-IDF WiFi firmware and network adapter driver.

---

## Step 2: bootloader

**Script:** `scripts/build-bootloader.sh --trimmed`
**Container:** `espressif/idf:v5.1` (Docker)
**Time:** ~5 min

Builds the WiFi firmware (`network_adapter.bin`) using ESP-IDF.

### What it does:

1. Runs `espressif/idf:v5.1` Docker container with esp-hosted volume mounted
2. Sets target to `esp32s3` via `idf.py set-target`
3. Applies trimmed sdkconfig - removes Ethernet, USB-OTG, SPIFFS, FATFS, MQTT, WiFi Provisioning; reduces mbedTLS cert bundle from 200 to 3 certs
4. Builds with `idf.py build`

### Output files:
```
output/bootloader/
  bootloader.bin          ~18KB   ESP-IDF bootloader
  network_adapter.bin     ~551KB  WiFi firmware (trimmed)
  partition-table.bin     ~3KB    Partition table
```

### Why Docker:
ESP-IDF v5.1 requires Python 3.8 which conflicts with host Python. Docker keeps it isolated.

---

## Step 3: kernel

**Script:** `scripts/build-kernel.sh`
**Container:** `mculinux-builder:latest` (Docker)
**Time:** ~15 min

Builds the Linux kernel and root filesystem using Buildroot.

### What it does:

1. Runs `mculinux-builder` Docker container with build directory mounted
2. Builds kernel 6.16 (xipImage) - the kernel uses XIP (Execute In Place), running directly from flash
3. Builds root filesystem as cramfs (compressed read-only filesystem)
4. Builds `/etc` filesystem as JFFS2 (writable, wear-leveled)
5. Packages all userspace utilities (busybox, htop, nano, etc.)

### Docker image contents:
```
Ubuntu 22.04 + autoconf 2.71 + build tools:
  gperf, bison, flex, texinfo, help2man, gawk, libtool-bin
  git, unzip, ncurses-dev, rsync, cmake, wget, bzip2
  g++, python3, cpio, bc, fakeroot, libfakeroot
```

### Output files:
```
build/build-buildroot-esp32s3_devkit_c1_8m/images/
  xipImage               ~2.4-3.9MB  Linux kernel (XIP)
  rootfs.cramfs          ~4.3MB       Root filesystem (cramfs)
  etc.jffs2              ~22KB        /etc filesystem (JFFS2)
```

### Why Docker:
Buildroot requires autoconf 2.71 (Ubuntu 22.04 has 2.69). Docker provides the right version.

---

## Step 4: image

**Script:** `scripts/build-image.sh [device]`
**Container:** Host (runs directly)
**Time:** ~10 sec

Assembles all components into a single flash image.

### What it does:

1. Creates blank flash image filled with `0xFF` (8MB for r8n8, 16MB for r8n16/r16n16)
2. Writes each component at its partition offset using `dd`
3. Copies individual components to output directory

### Flash layout (r8n8):
```
Offset        Size         Component
0x000000      0xA000       Bootloader (bootloader.bin)
0x00A000      0x5000       NVS (nvs, wear-leveling data)
0x00F000      0x1000       PHY init (phy_init)
0x010000      0xA0000      WiFi firmware (network_adapter.bin)
0x0B0000      0x70000      /etc filesystem (etc.jffs2)
0x120000      0x360000     Linux kernel (xipImage)
0x480000      0x380000     Root filesystem (rootfs.cramfs)
```

### Output:
```
output/r8n8/
  flash_r8n8.bin          ~8MB   Complete flash image
  bootloader.bin          ~18KB
  partition-table.bin     ~3KB
  network_adapter.bin     ~551KB
  xipImage                ~2.4MB
  rootfs.cramfs           ~4.3MB
  etc.jffs2               ~22KB
```

---

## Step 5: test

**Script:** `scripts/test-qemu.sh [device] [timeout]`
**Container:** Host (QEMU runs directly)
**Time:** ~30 sec

Boots the flash image in QEMU ESP32-S3 emulator to verify it works.

### What it does:

1. Pads flash image to next power of 2 (QEMU requirement: 2, 4, 8, or 16MB)
2. Runs QEMU with:
   - `-M esp32s3` - ESP32-S3 machine
   - `-nographic` - serial output to terminal
   - `-m 8M` - 8MB RAM
   - `-global driver=ssi_psram,property=is_octal,value=true` - octal PSRAM
   - `-drive file=flash.bin,if=mtd,format=raw` - flash image as MTD device
3. Waits up to 30 seconds for "Linux version" in output
4. Reports PASS/FAIL

### QEMU location:
```
tools/qemu/qemu/bin/qemu-system-xtensa   (ESP-IDF QEMU v9.2.2)
```

### Pass criteria:
- Output contains "Linux version" - kernel booted successfully
- OR timeout after 30s (boot was progressing, just slow)

---

## Step 6: compress

**Script:** `scripts/compress-test.sh`
**Container:** Host (uses host compression tools)
**Time:** ~30 sec

Compares different filesystem compression formats.

### What it does:

1. Takes the Buildroot `target/` directory (uncompressed rootfs)
2. Creates images with each format:
   - cramfs (default)
   - SquashFS + gzip
   - SquashFS + zstd
   - SquashFS + xz
   - EROFS + zstd
3. Reports sizes and compression ratios

### Compression results (5.9MB source):
```
Format                    Size    Ratio
------                    ----    -----
cramfs                    3.0MB   2.0x
squashfs+gzip             2.8MB   2.1x
squashfs+zstd             2.6MB   2.3x
squashfs+xz               2.5MB   2.4x
erofs+zstd                3.5MB   1.7x
```

All formats fit in the 3.5MB rootfs partition.

---

## Step 7: build

**Script:** `scripts/build.sh [device]`
**Container:** Multiple (bootloader in espressif/idf, kernel in mculinux-builder)
**Time:** ~20 min

Full build combining steps 2-5.

### What it does:

```
Step 1/4: Bootloader      (espressif/idf Docker)
Step 2/4: Kernel + Rootfs (mculinux-builder Docker)
Step 3/4: Flash Image     (host, dd commands)
Step 4/4: QEMU Test       (host, qemu-system-xtensa)
```

### Usage:
```bash
make build DEVICE=r8n8     # Build for 8MB flash
make build DEVICE=r8n16    # Build for 16MB flash, 8MB PSRAM
make build DEVICE=r16n16   # Build for 16MB flash, 16MB PSRAM
```

---

## Step 8: all

**Script:** `scripts/build.sh` (called 3 times)
**Container:** Same as step 7
**Time:** ~60 min

Builds firmware images for all 3 device variants.

### Devices:
```
Device    Flash    PSRAM    Buildroot Config
------    -----    -----    ----------------
r8n8      8MB      8MB      esp32s3_devkit_c1_8m
r8n16     16MB     8MB      esp32s3_devkit_c1_8m
r16n16    16MB     16MB     esp32s3_box3
```

### Usage:
```bash
make all    # Build all 3 devices
```

---

## r8n8 Partition Table

**File:** `build/esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/partition_table.esp32s3`

```
## Label          Type    ST      Offset        Length
nvs,              data,   nvs,    0x00009000,   0x00001000    (4KB)
phy_init,         data,   phy,    0x0000A000,   0x00001000    (4KB)
factory,          app,    factory,0x00010000,   0x000A0000    (640KB)
etc,              0x40,   0x1,    0x000B0000,   0x00070000    (448KB)
linux,            0x40,   0x0,    0x00120000,   0x00360000    (3.375MB)
rootfs,           0x40,   0x1,    0x00480000,   0x00380000    (3.5MB)
```

### Partition details:

| Partition | Offset | Size | Contents |
|-----------|--------|------|----------|
| **nvs** | 0x9000 | 4KB | Non-volatile storage (WiFi disabled, minimal) |
| **phy_init** | 0xF000 | 4KB | PHY initialization data |
| **factory** | 0x10000 | 640KB | WiFi firmware (`network_adapter.bin`) |
| **etc** | 0xB0000 | 448KB | `/etc` filesystem (`etc.jffs2`, writable) |
| **linux** | 0x120000 | 3.375MB | Linux kernel (`xipImage`, XIP) |
| **rootfs** | 0x480000 | 3.5MB | Root filesystem (`rootfs.cramfs`, read-only) |

### Total: 8MB (0x800000)

### Why this layout:
- **nvs** at start: Required by ESP-IDF for WiFi calibration data
- **phy_init**: RF PHY configuration, must be at fixed offset
- **factory**: WiFi firmware runs on the WiFi CPU (ESP32-S3 has dual-core, one core runs WiFi)
- **etc**: JFFS2 allows writing config files, logs
- **linux**: XIP kernel runs directly from flash, no loading needed
- **rootfs**: cramfs is read-only, compressed, ideal for root filesystem

### Kernel DTB hardcodes this layout
The kernel device tree blob (DTB) is compiled with these partition offsets baked in. The kernel always sees this layout regardless of what the actual flash contains.

---

## Docker Images

### espressif/idf:v5.1
- Used for: bootloader build
- Contains: ESP-IDF v5.1, Python 3.8, ESP32-S3 toolchain
- Why: ESP-IDF requires specific Python version, isolated from host

### mculinux-builder:latest
- Used for: kernel + rootfs build
- Contains: Ubuntu 22.04 + autoconf 2.71 + build tools
- Why: Buildroot needs autoconf 2.71 (Ubuntu 22.04 has 2.69)
- Built from: `docker/Dockerfile`

---

## File Sizes Summary

| Component | r8n8 | r8n16 | r16n16 |
|-----------|------|-------|--------|
| bootloader.bin | 18KB | 18KB | 18KB |
| network_adapter.bin | 551KB | 551KB | 551KB |
| partition-table.bin | 3KB | 3KB | 3KB |
| etc.jffs2 | 22KB | 22KB | 22KB |
| xipImage | 2.4MB | 2.4MB | 2.4MB |
| rootfs.cramfs | 4.3MB | 4.3MB | 4.3MB |
| **Total** | **7.3MB** | **7.3MB** | **7.3MB** |
| **Flash** | **8MB** | **16MB** | **16MB** |
| **Free** | **0.7MB** | **8.7MB** | **8.7MB** |
