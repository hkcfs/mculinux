# Alpine Linux ESP32-S3 Port - Research

## Current State

Alpine Linux does NOT officially support Xtensa architecture. Supported architectures:
x86_64, aarch64, armv7, armhf, ppc64le, s390x, riscv64, armv6.

Alpine does have `gcc-cross-embedded` package with `gcc-xtensa-esp32s3-elf` but this is bare-metal (not Linux userspace).

## What's Needed to Port Alpine to ESP32-S3

### Approach A: Full Alpine Port (Official-style)
1. Add `xtensa32` to Alpine's supported architectures
2. Create `alpine-base` for xtensa32
3. Create `aports` fork with xtensa32 APKBUILDs
4. Set up build infrastructure (build server, package signing)
5. Bootstrap minimal rootfs: musl + busybox + apk

### Approach B: Pragmatic Port (Buildroot-compatible)
1. Use our existing `xtensa-esp32s3-linux-muslfdpic` cross-compiler
2. Build Alpine packages using modified APKBUILDs that reference our toolchain
3. Package results as `.apk` files
4. Assemble into rootfs using Alpine's `mkimage` or Buildroot

### Approach C: Hybrid (Recommended)
1. Build Alpine packages using cross-compilation in Docker
2. Use `abuild` tooling for package building
3. Create a minimal Alpine rootfs with our kernel
4. Boot test in QEMU

## Key Components

### Toolchain
- Alpine uses standard musl (not xtensa-musl fork)
- We use jcmvbkbc/musl-xtensa fork (has xtensa patches)
- Need to either:
  a. Upstream xtensa patches to mainline musl
  b. Cross-compile Alpine packages with our toolchain
  c. Build Alpine's musl from source for xtensa

### Package Build System (abuild)
- `abuild` builds packages in clean chroots
- `newapkbuild` generates APKBUILD templates
- `abuild checksum` generates checksums
- `abuild -r` builds the package
- Output: `.apk` files signed with RSA keys

### APKBUILD Format
```bash
pkgname=package-name
pkgver=1.0.0
pkgrel=0
pkgdesc="Description"
url="https://..."
arch="all"  # or specific arch
license="MIT"
depends=""
makedepends=""
source="https://..."
builddir="$srcdir/$pkgname-$pkgver"

prepare() { default_prepare; }
build() { ./configure --prefix=/usr; make; }
package() { make DESTDIR="$pkgdir" install; }
sha512sums="..."
```

## Implementation Plan

### Phase 1: Validate Toolchain Compatibility
- [ ] Verify our musl-xtensa fork can build Alpine packages
- [ ] Test cross-compilation of busybox, musl, apk-tools
- [ ] Check if Alpine's abuild works with our toolchain

### Phase 2: Build Alpine Packages
- [ ] Cross-compile core Alpine packages:
  - musl (from our fork)
  - busybox
  - apk-tools (package manager)
  - alpine-baselayout (filesystem structure)
  - alpine-init (init scripts)
  - musl-utils (ldd, etc.)
- [ ] Package as .apk files

### Phase 3: Assemble Rootfs
- [ ] Create minimal Alpine rootfs structure
- [ ] Install .apk packages
- [ ] Configure init (busybox init -> openrc or direct)
- [ ] Add our kernel (xipImage)
- [ ] Create flash image

### Phase 4: Test
- [ ] Boot in QEMU
- [ ] Verify apk works
- [ ] Test package installation

## Technical Challenges

1. **FDPIC support**: Our toolchain uses FDPIC binary format. Alpine packages may need to be built with FDPIC support.

2. **Kernel headers**: Alpine expects standard Linux headers. Our kernel uses custom xtensa headers.

3. **apk-tools**: Alpine's package manager needs to be cross-compiled for xtensa.

4. **Size**: Alpine is minimal but still larger than our current Buildroot image.

5. **No MMU**: ESP32-S3 has no MMU. Alpine typically assumes MMU. Need to check if Alpine supports noMMU.

## Comparison: Buildroot vs Alpine

| Feature | Buildroot (current) | Alpine (future) |
|---------|-------------------|-----------------|
| Package manager | None (static) | apk |
| Package updates | Rebuild entire image | Install individual packages |
| Community packages | Limited | Thousands |
| Size | ~3.5MB | ~5-8MB |
| Complexity | Low | Medium |
| Maintenance | Rebuild every 6 months | Rolling updates possible |

## Resources
- Alpine aports: https://gitlab.alpinelinux.org/alpine/aports
- abuild source: https://gitlab.alpinelinux.org/alpine/abuild
- APKBUILD reference: https://wiki.alpinelinux.org/wiki/APKBUILD_Reference
- Alpine porting guide: https://wiki.alpinelinux.org/wiki/Developer_Documentation
- jcmvbkbc esp32-linux-build: https://github.com/jcmvbkbc/esp32-linux-build
