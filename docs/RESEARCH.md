# MCUlinux Research Log

Everything we tried, what worked, what failed, and why.

## Table of Contents
- [Current Status](#current-status)
- [Squashfs Investigation](#squashfs-investigation)
- [Squashfs: Not Actually Compiled](#squashfs-not-actually-compiled)
- [DWARFS Investigation](#dwarfs-investigation)
- [Kernel Rebuild Failure](#kernel-rebuild-failure)
- [Flash Layout Discovery](#flash-layout-discovery)
- [Stripped Cramfs Solution](#stripped-cramfs-solution)
- [XIP for Rootfs?](#xip-for-rootfs)
- [What Works Now](#what-works-now)
- [What Failed](#what-failed)
- [Remaining Limitations](#remaining-limitations)

---

## Current Status

**Date:** 2026-07-04

All 3 device images boot in QEMU:

| Device | Flash | Rootfs | Size | Boot |
|--------|-------|--------|------|------|
| r8n8 | 8MB | erofs+lzma | 2.5MB | PASS (85% reliable) |
| r8n16 | 16MB | erofs+lzma | 2.5MB | PASS |
| r16n16 | 16MB | erofs+lzma | 2.5MB | PASS |

Buildroot config: `xtensa-2025.08-fdpic` (kernel 6.16)
Toolchain: `xtensa-esp32s3-linux-muslfdpic-gcc 14.0.1` (musl, FDPIC)

**Major Changes:**
- Migrated from cramfs to EROFS+LZMA as default (2.5MB vs 4.3MB cramfs)
- All packages now fit without stripping (wpa_supplicant, dropbear, iw, htop, nano)
- Kernel config: EROFS with LZMA decompressor only (no squashfs, no zstd)
- DTB changed from `root=mtd:rootfs` to `root=/dev/mtdblock5`

---

## Squashfs Investigation

### Goal
Fit a useful rootfs into 8MB flash. The full cramfs is 4.3MB but the kernel partition is only 3.5MB. Squashfs compresses better (2.7MB vs 4.3MB), so we investigated enabling it.

### What We Did
1. Generated squashfs rootfs: `mksquashfs target/ rootfs.squashfs -comp gzip` → **2.7MB** (vs 4.3MB cramfs)
2. Switched Buildroot config from cramfs to squashfs:
   ```
   BR2_TARGET_ROOTFS_SQUASHFS=y
   BR2_TARGET_ROOTFS_SQUASHFS_GZIP=y
   # BR2_TARGET_ROOTFS_CRAMFS is not set
   ```
3. Added kernel config fragment to enable squashfs:
   ```
   CONFIG_SQUASHFS=y
   CONFIG_SQUASHFS_GZIP=y
   ```
4. Attempted kernel rebuild via `linux-dirclean` + `make linux`

### Result: FAILED
Kernel rebuild fails with assembler error:
```
./arch/xtensa/include/asm/initialize_mmu.h:57:
Error: invalid register 'atomctl' for 'wsr' instruction
```

### Why It Failed
- The `linux-dirclean` command destroys the kernel build directory entirely
- When Buildroot tries to rebuild from scratch, the cross-assembler (binutils 2.42.50 from crosstool-NG) doesn't recognize the `atomctl` register
- The original kernel build worked because it went through Buildroot's full environment setup (staging dir, cross-compilation env vars, etc.)
- After dirclean, the kernel re-extraction and build somehow loses this environment
- The `atomctl` register is a newer Xtensa feature (introduced in ESP32-S3) that requires a specific assembler configuration
- Our binutils is built from `xtensa-2.42-fdpic-musl` branch but the kernel source `xtensa-6.16-esp32` may expect a newer assembler

### Key Insight
The kernel can only be built ONCE through Buildroot's full build system. Running `linux-dirclean` and rebuilding breaks the environment. This is likely because:
- Buildroot patches the kernel source during extraction
- The cross-compiler environment setup is complex and happens during the first build
- Subsequent rebuilds don't fully recreate this environment

---

## Squashfs: Not Actually Compiled

### Discovery
After adding `CONFIG_SQUASHFS=y` to the kernel config, we assumed squashfs was supported. **It wasn't.**

### Evidence
```
# Squashfs objects exist (compiled at 07:48)
fs/squashfs/super.o   Modify: 2026-07-03 07:48:30

# But xipImage was built BEFORE (at 06:59)
images/xipImage       Modify: 2026-07-03 06:59:59

# Squashfs objects NOT linked into final kernel
nm vmlinux | grep squash  →  (empty)
nm fs/built-in.a | grep squash  →  (empty)
```

### What Happened
1. Original kernel built at 06:59 WITHOUT squashfs (cramfs only)
2. At 07:33 we added `CONFIG_SQUASHFS=y` to .config
3. A partial rebuild compiled squashfs objects (07:48)
4. But the final link step (xipImage) was NOT re-run
5. **xipImage has no squashfs support**

### Why QEMU Failed with Squashfs
When we put rootfs.squashfs at 0x480000:
- Kernel tries to mount it
- Finds no squashfs magic bytes (kernel lacks squashfs code)
- Falls through to cramfs check
- cramfs check finds squashfs data → fails
- "Bad ram pointer" error

### Fix Required
Need to rebuild kernel with squashfs. But `linux-dirclean` + rebuild fails with atomctl error.

---

## DWARFS Investigation

### What is DWARFS?
[DWARFS](https://github.com/mhx/dwarfs) is a high-performance compressed read-only filesystem by Marcus Hernanz. It uses modern compression algorithms (zstd, lzma, etc.) and has very good compression ratios.

### Compression Comparison
| Filesystem | Compression | Ratio | Speed | Kernel Support |
|------------|-------------|-------|-------|----------------|
| cramfs | zlib | 1.37x | Fast | Built-in |
| squashfs | zlib | 1.6x | Medium | Config option |
| squashfs | zstd | 2.0x | Medium | Config option |
| DWARFS | zstd | 2.5-3.0x | Slow mount | **Not in kernel** |

### Would DWARFS Help?
**Yes, dramatically.** With 2.5-3.0x compression:
- 5.9MB target → ~2.0-2.4MB DWARFS image
- Fits easily in 3.5MB partition
- Could include ALL packages (htop, nano, wifi, ssh)

### Why We Can't Use DWARFS

**Problem 1: Not in Linux kernel**
DWARFS is a FUSE-based filesystem. It requires:
- FUSE kernel module (`CONFIG_FUSE=y`)
- DWARFS FUSE daemon running in userspace
- This means DWARFS runs in userspace, not kernel space

**Problem 2: FUSE not enabled in ESP32-S3 kernel**
```
# CONFIG_FUSE_FS is not set
```
FUSE is not compiled into our kernel. Even if it were, FUSE adds overhead.

**Problem 3: Userspace daemon required**
DWARFS needs a daemon process to serve filesystem requests. On a microcontroller with 8MB PSRAM, this wastes RAM and CPU.

**Problem 4: Kernel rebuild required**
To enable FUSE and DWARFS, we need to rebuild the kernel. The kernel rebuild is broken (atomctl error).

### DWARFS vs Squashfs vs cramfs for ESP32-S3

For embedded systems like ESP32-S3:
- **cramfs**: Simple, fast, built-in, but poor compression
- **squashfs**: Better compression, kernel-native, but needs rebuild
- **DWARFS**: Best compression, but FUSE overhead makes it unsuitable

**Best choice for MCUlinux: squashfs** (if we can rebuild kernel)

---

## Kernel Rebuild Failure (Detailed)

### Error
```
kernel/async.o
...
kernel/built-in.a
make[2]: *** [Makefile:2003: .] Error 2
make[1]: *** [Makefile:248: __sub-make] Error 2
```

### Root Cause
The error happens during compilation of `head.S` which uses the `atomctl` register. The assembler doesn't know about this register.

### What We Tried
1. **Rebuild via Buildroot**: `make -C buildroot O=... linux` → fails
2. **Rebuild from scratch**: Remove `build/linux-xtensa-6.16-esp32-tag/` and rebuild → fails
3. **Config fragment approach**: Add squashfs via `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` → config applies but build still fails
4. **Direct gcc invocation**: Try compiling `head.S` manually → same atomctl error

### What Didn't Work
- The `linux-dirclean` + rebuild path is fundamentally broken
- The kernel source tree cannot be rebuilt after being cleaned
- The issue is NOT with the config (squashfs config is correct) but with the build environment

### Possible Fix (Not Attempted)
- Build a fresh kernel from source outside Buildroot with proper env vars
- Use a newer binutils that supports atomctl
- Patch the kernel DTS to avoid the atomctl register usage

---

## Flash Layout Discovery

### The Problem
The kernel's Device Tree Blob (DTB) hardcodes the partition layout. This is NOT the same as the partition table CSV that the bootloader uses.

### What We Found

**Bootloader partition table** (from CSV):
```
# 8MB layout:
nvs       0x0000a000  0x5000
phy_init  0x0000f000  0x1000
factory   0x00010000  0xa0000
etc       0x000b0000  0x70000
linux     0x00120000  0x360000
rootfs    0x00480000  0x380000  (3.5MB)

# 16MB layout:
rootfs    0x00600000  0x9f0000  (9.9MB)
```

**Kernel DTB partition table** (hardcoded in xipImage):
```
0x000000480000-0x000000800000 : "rootfs"  (3.5MB, ALWAYS)
```

### Key Finding
The kernel ignores the bootloader's 16MB partition table. It always sees the 8MB layout with rootfs at 0x480000, 3.5MB max. The 16MB CSV partition table is only used by the bootloader for flash validation, not by the kernel.

### Implications
- **r8n8**: 8MB flash, rootfs at 0x480000, max 3.5MB → cramfs must be < 3.5MB
- **r8n16/r16n16**: 16MB flash, rootfs still at 0x480000, max 3.5MB → extra 8MB is wasted
- To use 16MB properly, the kernel DTS must be modified to define larger partitions

### DTS Location
```
build/build-buildroot-esp32s3_devkit_c1_8m/build/linux-xtensa-6.16-esp32-tag/arch/xtensa/boot/dts/esp32s3-devkit-c1.dts
```

The DTS does NOT contain partition definitions. Partitions come from the bootloader's partition table which is read by the ESP-IDF bootloader and passed to the kernel via MTD.

### The Real Issue
The kernel's MTD partition parser reads the partition table from flash at offset 0x8000. But the `root=mtd:rootfs` kernel command line argument tells the kernel to mount the partition named "rootfs". The kernel finds this partition at 0x480000-0x800000 (3.5MB).

When we put cramfs at 0x600000 (16MB layout), the kernel can't find it because the "rootfs" partition is defined at 0x480000.

---

## Stripped Cramfs Solution

### What We Did
Since the kernel partition is only 3.5MB, we stripped heavy packages from the rootfs:

**Removed:**
- `wpa_supplicant` (1000KB) - WiFi
- `dropbear` (440KB) - SSH
- `iw` (324KB) - wireless tools
- `libncurses` (312KB) - terminal UI
- `libnl` (148KB) - netlink
- `htop` (depends on ncurses)
- `nano` (depends on ncurses)

**Result:**
- Original target: 5.9MB → Stripped target: 2.5MB
- Original cramfs: 4.3MB → Stripped cramfs: **1.4MB**
- Fits easily in 3.5MB partition

### Commands Used
```bash
# Strip packages
TARGET=build-buildroot-esp32s3_devkit_c1_8m/target
STRIPPED=/tmp/mculinux-stripped-rootfs
cp -a "$TARGET" "$STRIPPED"
rm -f "$STRIPPED/usr/sbin/wpa_supplicant"
rm -f "$STRIPPED/usr/sbin/dropbear"*
rm -f "$STRIPPED/usr/sbin/iw"
rm -f "$STRIPPED/usr/lib/libncurses"* "$STRIPPED/usr/lib/libform"*
rm -f "$STRIPPED/usr/lib/libmenu"* "$STRIPPED/usr/lib/libpanel"*
rm -f "$STRIPPED/usr/lib/libnl"*
rm -rf "$STRIPPED/usr/lib/terminfo" "$STRIPPED/usr/share/ncurses"
rm -f "$STRIPPED/usr/bin/htop" "$STRIPPED/usr/bin/nano"

# Rebuild cramfs
MKCRAMFS=build-buildroot-esp32s3_devkit_c1_8m/host/bin/mkcramfs
"$MKCRAMFS" -q "$STRIPPED" rootfs_stripped.cramfs
```

### What's Included in Stripped Rootfs
- `busybox` (ash shell, coreutils, init)
- `bash`
- `coreutils`
- Basic system files

---

## XIP for Rootfs?

### Question
Are we using XIP (Execute In Place) for the rootfs as well as the kernel?

### Answer: No
XIP is only used for the kernel (`xipImage`). The rootfs is a standard cramfs image loaded from flash into RAM.

### Evidence
```
# Kernel: XIP enabled
CONFIG_XIP_KERNEL=y
CONFIG_MTD_XIP=y

# Rootfs: standard cramfs (loaded from flash, not executed)
root=mtd:rootfs   (kernel command line)
cramfs: checking physical address 0x42480000 for linear cramfs image
VFS: Mounted root (cramfs filesystem) readonly on device 31:5.
```

### How It Works
1. **Kernel (XIP)**: xipImage is mapped directly to flash address 0x42120000
   - Code executes directly from flash (no RAM copy)
   - Saves RAM but flash must be memory-mapped
   - `CONFIG_XIP_DATA_ADDR=0x3d800000` (data in PSRAM)

2. **Rootfs (cramfs)**: Read from flash into RAM on boot
   - cramfs image at flash offset 0x480000
   - Kernel reads it into RAM during mount
   - Then accesses it from RAM (not flash)

### Why Not XIP for Rootfs?
- Rootfs contains data files, not executable code
- XIP only makes sense for code you execute
- cramfs/squashfs are designed for compressed storage, not execution
- Rootfs needs to be writable (even if currently read-only)

### Could We Use XIP for Rootfs?
Technically yes, but:
- Would need a custom filesystem format
- No compression (XIP requires flat mapping)
- Would waste flash space
- Not worth it for data files

---

## What Works Now

### Boot Sequence (All Devices)
```
ESP-ROM bootloader → loads xipImage → Linux 6.16.0 boots
→ mounts EROFS rootfs at 0x480000 → runs /sbin/init
→ buildroot login: prompt
```

### Known Issue: NOMMU init reliability (~85%)
On NOMMU, `init` (busybox) requires a contiguous order-8 (1024KB) allocation to load. With only ~1416KB free and fragmented by kernel slabs, this succeeds ~85% of the time. The remaining 15% shows:
```
nommu: Allocation of length 856064 from process 1 (init) failed
Starting init: /sbin/init exists but couldn't execute it (error -12)
Run /bin/sh as init process
```
The system falls back to `/bin/sh` directly but won't have a proper login prompt.

### QEMU Test Command
```bash
timeout 25 qemu-system-xtensa \
  -M esp32s3 -nographic -m 8M \
  -global driver=ssi_psram,property=is_octal,value=true \
  -drive file=output/r8n8/flash_r8n8.bin,if=mtd,format=raw
```

### Build Commands
```bash
# Full build (toolchain + Buildroot + flash image)
sudo docker run --rm -v $(pwd):/app -w /app/build \
  mculinux-builder bash build-qemu.sh

# Create flash image only
./build-all.sh r8n8
```

---

## What Failed

### 1. Kernel Rebuild After linux-dirclean
**Error:** `invalid register 'atomctl' for 'wsr' instruction`
**Cause:** Build environment lost after dirclean
**Impact:** Cannot add squashfs or other kernel features after initial build

### 2. Full Cramfs on 16MB Flash
**Error:** `cramfs: unable to get direct memory access to mtd:rootfs`
**Cause:** Kernel partition is 3.5MB, cramfs is 4.3MB
**Impact:** 16MB flash devices can't use full rootfs with all packages

### 3. 16MB Partition Table Ignored by Kernel
**Error:** Kernel always uses 8MB layout regardless of flash size
**Cause:** DTB/MTD parser hardcodes partition offsets
**Impact:** Extra flash space is wasted on 16MB devices

### 4. Squashfs Rootfs (2.7MB) Not Usable
**Error:** Kernel lacks CONFIG_SQUASHFS=y
**Cause:** Cannot rebuild kernel to add it
**Impact:** Cannot use better compression to fit more in partition
**Status: RESOLVED** — Rebuilt kernel through Buildroot (no linux-dirclean needed), enabled SQUASHFS, XZ, and EROFS support

### 5. NOMMU Memory Fragmentation
**Error:** `nommu: Allocation of length 856064 from process 1 (init) failed`
**Cause:** On NOMMU, loading ELF binaries requires contiguous RAM. With only 8MB total and heavy kernel slab usage (printk buffer ~540KB, TCP hash tables ~256KB), the order-8 (1024KB) allocation for init fails ~15% of the time.
**Impact:** Boot succeeds ~85% of the time; remaining 15% falls back to `/bin/sh` without login
**Mitigation:** System still runs (kernel auto-falls back to /bin/sh), but no proper init/login

---

## Remaining Limitations

### 1. ~~No WiFi/SSH in Stripped Build~~ RESOLVED
The 8MB flash can only fit a minimal rootfs. WiFi (wpa_supplicant) and SSH (dropbear) are removed.
**Status: RESOLVED** — Squashfs+zstd compresses to 2.7MB (vs 4.3MB cramfs), fitting all packages with 800KB headroom.

### 2. 16MB Flash Wasted
The kernel's partition layout is fixed at 8MB. The extra 8MB on r8n16/r16n16 is unused.

### 3. ~~Kernel Cannot Be Modified After Build~~ RESOLVED
The `linux-dirclean` + rebuild path is broken. Any kernel config change requires a complete rebuild from scratch, which fails.
**Status: RESOLVED** — Kernel can be reconfigured by modifying the kernel config fragment and running `make kernel` (which runs Buildroot, not linux-dirclean). Added SQUASHFS, XZ, EROFS support this way.

### 4. FDPIC Binary Crashes (Known)
Busybox init and syslogd crash with FDPIC-related errors. The system still boots because busybox retries. This is a known issue with the musl-xtensa FDPIC fork.

---

## Experiments Log

### Test 1: Original 8MB Flash (Before Stripping)
```
Flash: 8MB, cramfs at 0x480000 (4.3MB)
Result: cramfs exceeds partition, "Can't lookup blockdev"
Status: FAILED
```

### Test 2: 16MB Flash with Full Cramfs at 0x600000
```
Flash: 16MB, cramfs at 0x600000 (4.3MB)
Result: Kernel looks for rootfs at 0x480000, can't find it
Status: FAILED
```

### Test 3: 16MB Flash with Full Cramfs at 0x480000
```
Flash: 16MB, cramfs at 0x480000 (4.3MB)
Result: cramfs 4.3MB > partition 3.5MB, "unable to get direct memory access"
Status: FAILED
```

### Test 4: Stripped Cramfs on 8MB Flash
```
Flash: 8MB, stripped cramfs at 0x480000 (1.4MB)
Result: cramfs mounts, login prompt appears
Status: PASS
```

### Test 5: Stripped Cramfs on 16MB Flash
```
Flash: 16MB, stripped cramfs at 0x480000 (1.4MB)
Result: cramfs mounts, login prompt appears
Status: PASS
```

### Test 6: Squashfs (2.7MB) - Build Attempt
```
Generated rootfs.squashfs = 2.7MB (fits in 3.5MB)
Switched Buildroot to BR2_TARGET_ROOTFS_SQUASHFS=y
Kernel rebuild: "invalid register 'atomctl'"
Status: FAILED (kernel rebuild broken)
```

### Test 7: Kernel Config Fragment for Squashfs
```
Created squashfs_fragment.cfg with CONFIG_SQUASHFS=y
Applied via BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES
Kernel rebuild: same atomctl error
Status: FAILED
```

---

## Test Evidence (Captured 2026-07-03)

### QEMU Boot Output - All 3 Devices PASS

**r8n8 (8MB flash):**
```
Linux version 6.16.0 (debian@004af392356c) (xtensa-esp32s3-linux-muslfdpic-gcc 14.0.1) #1 PREEMPT
cramfs: linear cramfs image on mtd:rootfs appears to be 1372 KB in size
VFS: Mounted root (cramfs filesystem) readonly on device 31:5.
devtmpfs: mounted
buildroot login:
```

**r8n16 (16MB flash):**
```
Linux version 6.16.0 (debian@004af392356c) (xtensa-esp32s3-linux-muslfdpic-gcc 14.0.1) #1 PREEMPT
cramfs: linear cramfs image on mtd:rootfs appears to be 1372 KB in size
VFS: Mounted root (cramfs filesystem) readonly on device 31:5.
devtmpfs: mounted
buildroot login:
```

**r16n16 (16MB flash):**
```
Linux version 6.16.0 (debian@004af392356c) (xtensa-esp32s3-linux-muslfdpic-gcc 14.0.1) #1 PREEMPT
cramfs: linear cramfs image on mtd:rootfs appears to be 1372 KB in size
VFS: Mounted root (cramfs filesystem) readonly on device 31:5.
devtmpfs: mounted
buildroot login:
```

### Image Sizes
```
output/r8n8/flash_r8n8.bin    8.0M   (8MB flash)
output/r8n16/flash_r8n16.bin  16M    (16MB flash)
output/r16n16/flash_r16n16.bin 16M   (16MB flash)
```

### Rootfs Comparison
```
rootfs.cramfs    4.3M   (full, doesn't fit in 3.5MB partition)
rootfs.squashfs  2.7M   (generated, but kernel lacks squashfs support)
rootfs_r8n8.cramfs 1.4M (stripped, fits in 3.5MB partition)
```

---

## Key Commands Reference

### Build Toolchain
```bash
cd build/crosstool-NG
./ct-ng xtensa-esp32s3-linux-muslfdpic
CT_PREFIX="$(pwd)/builds" nice ./ct-ng build
```

### Build Buildroot
```bash
make -C buildroot O=build/build-buildroot-esp32s3_devkit_c1_8m \
  -j$(nproc)
```

### Build Bootloader
```bash
cd build/esp-hosted/esp_hosted_ng/esp/esp_driver
cmake . && cd network_adapter
idf.py set-target esp32s3
idf.py build
```

### Create Flash Image
```bash
# 8MB
dd if=/dev/zero bs=1M count=8 | tr '\0' '\377' > flash.bin
dd if=bootloader.bin of=flash.bin bs=1 seek=0 conv=notrunc
dd if=partition-table.bin of=flash.bin bs=1 seek=0x8000 conv=notrunc
dd if=network_adapter.bin of=flash.bin bs=1 seek=0x10000 conv=notrunc
dd if=etc.jffs2 of=flash.bin bs=1 seek=0xB0000 conv=notrunc
dd if=xipImage of=flash.bin bs=1 seek=0x120000 conv=notrunc
dd if=rootfs.cramfs of=flash.bin bs=1 seek=0x480000 conv=notrunc
```

### Test in QEMU
```bash
timeout 25 qemu-system-xtensa \
  -M esp32s3 -nographic -m 8M \
  -global driver=ssi_psram,property=is_octal,value=true \
   -drive file=flash.bin,if=mtd,format=raw
```

### Test 8: Squashfs+ZSTD (kernel rebuild via Buildroot)
```
Changed kernel config fragment: SQUASHFS=y, SQUASHFS_ZSTD=y
Changed Buildroot defconfig: CRAMFS → SQUASHFS+ZSTD
Rebuilt via: make kernel (Buildroot, no linux-dirclean)
Result: xipImage rebuilt with squashfs, rootfs.squashfs 2.7MB
QEMU boot: PASS (Mounted root (squashfs filesystem))
Init reliability: ~85% (NOMMU fragmentation)
Status: PASS
```

### Test 9: Squashfs+XZ (2.5MB)
```
Generated rootfs_squashfs_xz.bin with mksquashfs -comp xz
Added CONFIG_SQUASHFS_XZ=y to kernel config
QEMU boot: PASS, 2.5MB (best compression)
Status: PASS
```

### Test 10: EROFS+LZMA (winner)
```
mkfs.erofs -zlzma,level=109 -C 16384 \
  -E fragments,dedupe,ztailpacking,force-inode-compact \
  -x -1 -T 0 rootfs.erofs ./target/
Result: 2.43MB (smallest of all tests)
Kernel: CONFIG_EROFS_FS=y, CONFIG_EROFS_FS_ZIP=y, CONFIG_EROFS_FS_ZIP_LZMA=y
QEMU boot: PASS (Mounted root (erofs filesystem))
Status: PASS — DEFAULT
```

## RootFS Compression Comparison (Final)

| Filesystem | Compression | Flags | Size |
|------------|-------------|-------|------|
| cramfs | zlib | Buildroot default | 4.3 MB |
| SquashFS | gzip | `-comp gzip -b 16384` | 2.8 MB |
| SquashFS | zstd | `-comp zstd -Xcompression-level 22 -b 16K` | 2.7 MB |
| SquashFS | xz | `-comp xz -b 16384` | 2.5 MB |
| EROFS (default) | zstd,level=3 | defaults | 3.6 MB |
| EROFS (optimized) | zstd,level=22 | `-z zstd,level=22,dictsize=64k -C 65536 -E fragments,dedupe` | 2.6 MB |
| **EROFS (winner)** | **lzma,level=109** | **`-zlzma,level=109 -C 16384 -E fragments,dedupe,ztailpacking,force-inode-compact -x -1 -T 0`** | **2.43 MB** |

**Default choice: EROFS+LZMA** — smallest image (2.43MB), best compression ratio (2.43x), fits easily in 3.5MB partition with 1MB headroom.
```
