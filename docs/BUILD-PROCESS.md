# MCUlinux Build Process

## Requirements

Host system needs only:
- `git` - clone the repo
- `make` - orchestrate builds
- `docker` - (optional) match CI exactly; native builds work too

Native builds additionally need: cross-toolchain (via `scripts/setup.sh`),
`mkfs.erofs` (erofs-utils), `mkfs.jffs2` (mtd-utils, only for `make etc`),
`fakeroot` (deterministic image ownership, optional).

No Buildroot. The kernel builds from upstream tinyconfig + our fragment,
the rootfs assembles from `mculinux/rootfs/` + busybox.

---

## Build Targets

```
./scripts/setup.sh  # One-time setup (toolchain tarball, dynconfig, esp-hosted)
make kernel         # Linux xipImage, latest stable, tinyconfig + fragment
make busybox        # busybox NOMMU, latest stable + assemble rootfs.erofs
make etc            # etc.jffs2 from rootfs/etc (needs mkfs.jffs2)
make bootloader     # ESP32-S3 bootloader binaries (idf:latest, manual)
make image          # Assemble flash image from prebuilts
make test           # QEMU boot test (kernel + tty + login + mounts)
make compress       # Filesystem compression comparison
make all-devices    # image+test for r8n8, r8n16, r16n16
make latest         # Print latest stable kernel (overall + per branch)
```

---

## Step 1: setup

**Script:** `scripts/setup.sh`
**Container:** Host (runs directly)
**Time:** ~minutes (toolchain is a release tarball, not a 45-min build)

One-time setup. Downloads the prebuilt musl cross-toolchain, builds
dynconfig, clones esp-hosted.

### What it does:

**1a. dynconfig**
Clones `jcmvbkbc/xtensa-dynconfig` and `config-esp32s3`. Builds `esp32s3.so`.

**1b. musl cross-toolchain**
Downloads `xtensa-esp32s3-linux-muslfdpic` from the public `toolchain`
release asset and places it at `build/crosstool-NG/builds/...` (same layout
as a from-source build). `TOOLCHAIN_SRC=1` restores the ~45-min
crosstool-NG source build (gcc `xtensa-14-9655-fdpic-musl`, binutils
`xtensa-2.42-fdpic-musl`, musl `xtensa-1.2.5-fdpic`, headers 6.16).

**1c. esp-hosted**
Clones `jcmvbkbc/esp-hosted` (`master`, tracks latest IDF;
`ESP_HOSTED_BRANCH=ipc-5.1.1` pairs with a pinned IDF). Only needed for
manual `make bootloader` rebuilds.

---

## Step 2: bootloader

**Script:** `scripts/build-bootloader.sh [--trimmed]`
**Container:** `espressif/idf:latest` (Docker, tracks IDF master)
**Time:** ~5 min

Builds the WiFi firmware (`network_adapter.bin`) using ESP-IDF.
`IDF_IMAGE_TAG=vX.Y` pins a release. Binaries are committed prebuilts;
CI never rebuilds them.

### What it does:

1. Runs `espressif/idf:latest` Docker container with esp-hosted volume mounted
2. Sets target to `esp32s3` via `idf.py set-target`
3. Applies trimmed sdkconfig - removes Ethernet, USB-OTG, SPIFFS, FATFS, MQTT, WiFi Provisioning; reduces mbedTLS cert bundle from 200 to 3 certs
4. Builds with `idf.py build`

### Output files:
```
output/bootloader/
  bootloader.bin          ~18KB   ESP-IDF bootloader
  network_adapter.bin     ~571KB  WiFi firmware (trimmed)
  partition-table.bin     ~3KB    Partition table
```

---

## Step 3: kernel

**Script:** `scripts/build-kernel.sh`
**Container:** Host or `mculinux-builder` (CI)
**Time:** ~2 min

Builds the Linux kernel (XIP) from **upstream tinyconfig + our fragment**
(`patches/linux-esp32/fragment.config`, applied via `merge_config.sh`).
Always the latest stable unless `KERNEL_VERSION=7.2.4` pins one.

### What it does:

1. Resolves version (`latest-stable.sh`, kernel.org) unless pinned
2. Acquires pristine source (`/opt/src` prefetch, else cdn/edge.kernel.org)
3. Applies `patches/linux-esp32/0001-0009` STRICT (any failure = red build;
   already-applied patches are skipped for idempotent re-runs)
4. `make ARCH=xtensa tinyconfig`, merge fragment, `olddefconfig`
5. Verifies load-bearing symbols (`PRINTK`, `BLOCK`, `MTD_BLOCK`,
   `EROFS_FS`, `JFFS2_FS`, `SERIAL_ESP32`, `TTY`, DCE off) — fail loud
6. `make KCFLAGS="-Oz -fmerge-all-constants" xipImage`
7. Stamps `build/.kernel-version`, copies `xipImage-<major.minor>` to prebuilts

### Why tinyconfig + fragment (not a defconfig):

A full defconfig rots: symbols renamed/removed upstream linger silently and
`olddefconfig` fills gaps with defaults you never reviewed. tinyconfig is
always fresh upstream; the fragment (~150 lines) is the complete, reviewable
record of what the board needs. Equivalence with the last booting config is
checked by diffing (see fragment header + E-series docs).

### Known tinyconfig traps (documented so nobody re-learns them):

- `LD_DEAD_CODE_DATA_ELIMINATION` (DCE): tinyconfig enables it, and it hangs
  xtensa XIP right after `sched_clock` (experiment E2). Fragment disables it.
- `merge_config.sh` ignores `# CONFIG_X is not set` lines with trailing
  comments — keep them byte-exact. `build-kernel.sh` asserts the result.

### Output files:
```
tools/prebuilt/binaries/
  xipImage-7.2            ~1.8MB  Linux XIP kernel (7.2.x, ESP32-S3, musl, call0 ABI)
```

---

## Step 4: busybox + rootfs

**Scripts:** `scripts/build-busybox-nommu.sh`, `scripts/build-rootfs.sh`
**Container:** Host or `mculinux-builder` (CI)
**Time:** ~2 min

Builds busybox (always latest stable, resolved via git tags in
`latest-busybox.sh`, source via shallow clone) and assembles the EROFS
rootfs from `mculinux/rootfs/` — no Buildroot.

### What it does:

1. Resolves latest busybox (max tag over all git remotes, fallback 1.38.0)
2. Acquires source: builder pre-extract > prefetched tarball > git clone >
   tarball download. Fail loud if nothing works.
3. Applies our defconfig + `oldconfig`, applies the NOMMU `hush.c` patch
   (fail loud if upstream moved the anchor — red CI, not silent MMU hush)
4. Builds + strips `busybox` (~2MB)
5. `build-rootfs.sh` assembles staging: skeleton dirs, single-source
   `/etc` (`rootfs/etc/`), ~130 applet symlinks (explicit list — the cross
   binary can't run on the host for `--list` probing), static `init`
   (compiled from `patches/busybox-nommu/init_final.c`), `/dev/console+null`
   via fakeroot when available (devtmpfs covers boot regardless)
6. `mkfs.erofs -z lzma,level=9` → `tools/prebuilt/binaries/rootfs.erofs`
   (~1.1MB, ~159 inodes)

### Output files:
```
tools/prebuilt/binaries/
  rootfs.erofs            ~1.1MB  EROFS rootfs (busybox + static init)
```

---

## Step 5: etc (JFFS2)

**Script:** `scripts/build-etc-jffs2.sh`
**Container:** Host (needs `mkfs.jffs2`) or `mculinux-builder` (CI, has mtd-utils)
**Time:** ~seconds

Builds the writable `/etc` filesystem from the same `rootfs/etc/` source.

### What it does:

1. `mkfs.jffs2 --eraseblock=0x10000` — the eraseblock MUST match what the
   MTD layer advertises (`erase-size = <0x10000>` in `esp32s3.dtsi`); a
   mismatch produces an unmountable image
2. Fails loud if the image exceeds the etc partition (0xB0000, 448KB)
3. Guest-verified: `/dev/mtdblock3 on /etc type jffs2 (rw)`, touch test passes

### Output files:
```
tools/prebuilt/binaries/
  etc.jffs2               ~448KB  /etc filesystem (JFFS2, padded to partition)
```

---

## WiFi (lean Ethernet over IPC)

**Driver:** `patches/linux-esp32/0009-esp32-wifi-shmem.patch` (`drivers/net/ethernet/esp32-wifi-shmem.c`)
**Control:** `rootfs/utils/wificfg.c` → `/sbin/wificfg`

Split-core model: Core 0 (ESP-IDF `network_adapter`) owns WPA/auth and the
radio; Linux sees a plain Ethernet NIC (`eth0`) bound to the `wifi@1`
IPC-shmem child (client slot 1). Frames cross cores in esp-hosted payload
format; TX buffers are dcache-flushed, RX pointers are validated
(firmware-DRAM window only) and read via uncached ioremap.

- No supplicant/iwd/cfg80211 on Linux. `udhcpc` (in busybox) for IPv4,
  kernel SLAAC for IPv6.
- `wificfg [if] <ssid> [pass]` stages credentials via SIOCDEVPRIVATE
  (logged SSID in dmesg, passphrase never logged). Today the firmware
  uses its own config — staged creds take effect with a future firmware
  that implements an IPC connect command (Part B).
- QEMU proof: registration + MAC, `ifconfig up`, DHCP DISCOVERs on the
  wire (TX counters), ioctl round-trip. No radio in QEMU by design.

## Step 6: image

**Script:** `scripts/build-image.sh [device] [--kernel X.Y] [--rootfs path]`
**Container:** Host (runs directly)
**Time:** ~10 sec

Assembles all committed prebuilts into a single flash image. Fails loud on
any missing component (no silent fallbacks to stale blobs).

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
0x0B0000      0x70000      /etc filesystem (etc.jffs2, writable)
0x120000      0x3D0000     Linux kernel (xipImage)
0x500000      0x240000     Root filesystem (rootfs.erofs, read-only)
0x740000      rest         /data (JFFS2, writable: 768K on 8MB, 8.75MB on 16MB)
```

Per-device partition tables (`mculinux/partitions/partition-table-{8m,16m}.csv`,
built by `make partitions` with the vendored `gen_esp32part.py`): identical
entries 0-5 (same mtdblock0-5 on every device), `data` fills the flash tail.
16MB+ images also get the bootloader header patched to declare the real
flash size (`scripts/patch-bootloader-flashsize.py`) or the ESP-ROM rejects
the table and reboot-loops (the frozen prebuilt declares 8MB).

### Output:
```
output/r8n8/
  flash_r8n8.bin          ~8MB   Complete flash image
  bootloader.bin          ~18KB  (flash-size-patched copy on 16MB devices)
  partition-table.bin     ~3KB   (per-device: 8m/16m sources in partitions/)
  network_adapter.bin     ~571KB
  xipImage-7.2            ~1.8MB
  rootfs.erofs            ~1.1MB
  etc.jffs2               ~448KB
```

---

## Step 7: test

**Script:** `scripts/test-qemu.sh [device] [timeout]`
**Container:** Host (QEMU runs directly)
**Time:** ~60-90 sec

Boots the flash image in QEMU ESP32-S3 emulator and verifies a working system.

### What it does:

1. Pads flash image to next power of 2 (QEMU requirement: 2, 4, 8, or 16MB)
2. Runs QEMU with:
   - `-M esp32s3` - ESP32-S3 machine
   - `-nographic` - serial output to terminal
   - `-m 8M` - 8MB RAM (16MB RAM causes a kernel hang; all devices use 8M)
   - `-global driver=ssi_psram,property=is_octal,value=true` - octal PSRAM
   - `-drive file=flash.bin,if=mtd,format=raw` - flash image as MTD device
3. Drives the serial console (answers login, captures free/meminfo/df/mounts)
4. Saves the full serial log to `output/<device>/serial_<device>.log`
5. Reports: Kernel / TTY / Login / Measured / `/etc jffs2` / `/etc writable`

### QEMU location:
```
tools/qemu/qemu/bin/qemu-system-xtensa   (ESP-IDF QEMU esp-develop-9.2.2)
```
`$QEMU` env wins; both CI images pre-set it (`/opt/qemu/...`).

### Pass criteria:
- `Linux version` in output (kernel booted)
- `ttyS0 at MMIO` (UART registered)
- shell prompt (userspace up: `/sbin/init` → hush)
- `/dev/mtdblock3 on /etc type jffs2 (rw)` + touch test (writable config fs)

---

## Step 8: compress

**Script:** `scripts/compress-test.sh`
**Container:** Host (uses host compression tools)
**Time:** ~30 sec

Compares filesystem compression formats against the rootfs staging dir
(`make rootfs` first). Historical winner: EROFS+lzma (current production fs).

---

## Devices

```
Device    Flash    PSRAM    Target
------    -----    -----    ------
r8n8      8MB      8MB      ESP32-S3 DevKit-C1
r8n16     16MB     8MB      ESP32-S3 DevKit-C1 (focus device)
r16n16    16MB     16MB     ESP32-S3 Box-3
```

### Usage:
```bash
make image DEVICE=r8n8 && make test DEVICE=r8n8
make all-devices    # image+test for all 3 devices
```

---

## Partition Tables

**Source:** `mculinux/partitions/partition-table-{8m,16m}.csv`
**Build:** `make partitions` (vendored `tools/gen_esp32part.py`, no ESP-IDF needed)
**Binaries:** `tools/prebuilt/binaries/partition-table-{8m,16m}.bin`

```
## Label          type  ST      Offset        Length (8m / 16m)
nvs,              data, nvs,    0x00009000,   0x00001000
phy_init,         data, phy,    0x0000A000,   0x00001000
factory,          app,  factory,0x00010000,   0x000A0000
etc,              0x40, 0x1,    0x000B0000,   0x00070000 (448KB)
linux,            0x40, 0x0,    0x00120000,   0x003D0000
rootfs,           0x40, 0x1,    0x00500000,   0x00240000 (2.25MB)
data,             0x40, 0x2,    0x00740000,   0x000C0000 / 0x008C0000 (768KB / 8.75MB)
```

### Partition details:

| Partition | Offset | Size | Contents |
|-----------|--------|------|----------|
| **nvs** | 0x9000 | 4KB | Non-volatile storage (WiFi disabled, minimal) |
| **phy_init** | 0xF000 | 4KB | PHY initialization data |
| **factory** | 0x10000 | 640KB | WiFi firmware (`network_adapter.bin`) |
| **etc** | 0xB0000 | 448KB | `/etc` filesystem (`etc.jffs2`, writable) |
| **linux** | 0x120000 | 3904KB | Linux kernel (`xipImage`, XIP) |
| **rootfs** | 0x500000 | 2.25MB | Root filesystem (`rootfs.erofs`, read-only) |
| **data** | 0x740000 | rest | `/data` (`jffs2`, writable: 768KB / 8.75MB) |

### Total: 8MB (0x800000) on r8n8, 16MB on r8n16/r16n16 (`data` fills the tail)

### Why this layout:
- **nvs** at start: Required by ESP-IDF for WiFi calibration data
- **phy_init**: RF PHY configuration, must be at fixed offset
- **factory**: WiFi firmware runs on the WiFi CPU (ESP32-S3 has dual-core, one core runs WiFi)
- **etc**: JFFS2 allows writing config files, logs
- **linux**: XIP kernel runs directly from flash, no loading needed
- **rootfs**: erofs is read-only, compressed, ideal for root filesystem
- **data**: JFFS2 on the leftover flash — app storage, logs, user files

### Kernel DTB hardcodes this layout
The kernel device tree blob (DTB) is compiled with these partition offsets baked in. The kernel always sees this layout regardless of what the actual flash contains.

---

## Docker Images

### espressif/idf:latest
- Used for: bootloader build (manual only, never in CI)
- Contains: latest ESP-IDF, toolchains
- Tag tracks IDF master; `IDF_IMAGE_TAG=vX.Y` pins a release

### mculinux-builder:latest
- Used for: CI `full` job (kernel + busybox + rootfs + jffs2 from source)
- Contains: Ubuntu latest + autoconf 2.71 + build tools + erofs-utils +
  mtd-utils, prebuilt musl toolchain (`/opt/crosstool-ng/...`), latest
  kernel tarball + busybox git prefetch (`/opt/src`), Espressif QEMU
- Built from: `mculinux/docker/Dockerfile.builder`

### mculinux-tester:latest
- Used for: CI `fast` job (assemble committed prebuilts + boot)
- Contains: QEMU + runtime libs only

---

## CI/CD (GitHub Actions)

Two pre-baked images on GHCR, built by `.github/workflows/docker.yml`
on `mculinux/docker/**` changes + weekly Sunday refresh (re-resolves
latest Ubuntu/kernel/busybox) — both packages are **Public**:

`.github/workflows/build.yml` has two paths:

- **fast** (push/PR): tester image, device matrix r8n8/r8n16/r16n16 in
  parallel — `./scripts/build-image.sh <device>` + `./scripts/test-qemu.sh`.
  Uses committed prebuilts, so the `full` job's commit-back is what keeps
  them fresh.
- **full** (nightly cron 02:00 UTC + manual dispatch): builder image.
  Automation policy: ALWAYS build the latest stable kernel AND latest
  stable busybox, apply our patches, rebuild everything. Applies cleanly →
  green. Fails → loud red error, we make new patches. Never pin a "known
  good" version to avoid testing the new one.
  1. Resolve latest kernel + busybox versions
  2. Build kernel (`tinyconfig` + fragment, strict patches) → `xipImage-*`
  3. Build busybox (strict NOMMU patch) + assemble `rootfs.erofs`
  4. Build `etc.jffs2` (eraseblock-checked)
  5. Assemble + QEMU-test all devices (kernel/tty/login/mounts)
  6. Upload artifacts, **commit rebuilt binaries back to main** (red builds
     commit nothing; the next `fast` run tests the fresh blobs)

`make assemble`/`test`/`image` forward `KERNEL_VERSION` (`latest` by
default, resolved via `build/.kernel-version`) into `build-image.sh`.
`test-qemu.sh` self-provisions QEMU via `install-qemu-esp32.sh` and honors
`$QEMU` (pre-set to `/opt/qemu/...` in both images).

---

## File Sizes Summary (7.2.x era)

| Component | r8n8 | r8n16 | r16n16 |
|-----------|------|-------|--------|
| bootloader.bin | 18KB | 18KB | 18KB |
| network_adapter.bin | 571KB | 571KB | 571KB |
| partition-table.bin | 3KB | 3KB | 3KB |
| etc.jffs2 | 448KB | 448KB | 448KB |
| xipImage-7.2 | 1.8MB | 1.8MB | 1.8MB |
| rootfs.erofs | 1.1MB | 1.1MB | 1.1MB |
| /data free | ~572K | ~8.4M | ~8.4M |
| **Flash** | **8MB** | **16MB** | **16MB** |
