#!/bin/bash
# Build kernel xipImage from upstream tinyconfig + ESP32 fragment. No Buildroot.
# Always builds the latest stable kernel unless KERNEL_VERSION pins one.
# Usage: [KERNEL_VERSION=latest|7.2.4] [KSRC=/path] ./scripts/build-kernel.sh
set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$MCULINUX_DIR/build"
PATCHES_DIR="$MCULINUX_DIR/patches/linux-esp32"

KVER_REQ="${KERNEL_VERSION:-latest}"
if [ "$KVER_REQ" = "latest" ]; then
    KVER_REQ="$("$MCULINUX_DIR/scripts/latest-stable.sh")"
fi
[ -n "$KVER_REQ" ] || { echo "FAIL: could not resolve kernel version"; exit 1; }
KV_SHORT="$(echo "$KVER_REQ" | cut -d. -f1,2)"

KSRC="${KSRC:-$BUILD_DIR/kernel-src/linux-$KVER_REQ}"
CROSS="${XTENSA_CROSS:-$BUILD_DIR/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-}"

echo "=== Building Linux $KVER_REQ (tinyconfig + ESP32 fragment) ==="

# Toolchain must be visible BEFORE any *config step: Kconfig probes the
# compiler, and the wrong/missing compiler flips CONFIG_KERNEL_ABI_* and
# breaks the build (WindowVectors link errors).
command -v "${CROSS}gcc" >/dev/null 2>&1 || {
    echo "FAIL: cross gcc not found: ${CROSS}gcc"
    echo "  Run: make setup  (or export XTENSA_CROSS=<prefix>)"
    exit 1
}
export PATH="$(dirname "${CROSS}gcc"):$PATH"
export ARCH=xtensa
export CROSS_COMPILE="$(basename "$CROSS")"
echo "Toolchain: $("${CROSS}gcc" --version | head -1)"

# Acquire pristine source: builder prefetch > download (cdn, edge fallback).
if [ ! -d "$KSRC" ]; then
    echo "Acquiring linux-$KVER_REQ source..."
    mkdir -p "$(dirname "$KSRC")"
    if [ -f "/opt/src/linux-$KVER_REQ.tar.xz" ]; then
        tar -xf "/opt/src/linux-$KVER_REQ.tar.xz" -C "$(dirname "$KSRC")"
    else
        (wget -q --tries=3 --timeout=120 \
            "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KVER_REQ.tar.xz" \
            -O "/tmp/linux-$KVER_REQ.tar.xz" || \
         wget -q --tries=5 --timeout=120 \
            "https://mirrors.edge.kernel.org/pub/linux/kernel/v7.x/linux-$KVER_REQ.tar.xz" \
            -O "/tmp/linux-$KVER_REQ.tar.xz") \
            || { echo "FAIL: kernel tarball download failed"; exit 1; }
        tar -xf "/tmp/linux-$KVER_REQ.tar.xz" -C "$(dirname "$KSRC")"
        rm -f "/tmp/linux-$KVER_REQ.tar.xz"
    fi
fi
[ -f "$KSRC/Makefile" ] || { echo "FAIL: no kernel source at $KSRC"; exit 1; }

cd "$KSRC"

# Apply ESP32 patches STRICT: any failure is fatal. Already-applied patches
# are skipped (idempotent re-runs); anything else that fails stops the build.
echo "Applying ESP32 patches..."
for patch in "$PATCHES_DIR"/0*.patch; do
    if patch -p1 -R --dry-run --batch < "$patch" >/dev/null 2>&1; then
        echo "  $(basename "$patch") (already applied, skipping)"
    else
        echo "  $(basename "$patch")"
        patch -p1 --batch < "$patch" || exit 1
    fi
done
echo "All ESP32 patches applied."

# Base = upstream tinyconfig (fresh every time, no stale baggage),
# then our fragment wins, then olddefconfig resolves dependencies.
echo "Configuring (tinyconfig + fragment)..."
make ARCH=xtensa tinyconfig
scripts/kconfig/merge_config.sh -m .config "$PATCHES_DIR/fragment.config"
make ARCH=xtensa olddefconfig

# Guard against silent misconfiguration (e.g. a malformed fragment line that
# merge_config.sh ignores): these symbols are load-bearing for boot.
echo "Verifying load-bearing symbols..."
for sym in CONFIG_PRINTK CONFIG_PARSE_BOOTPARAM CONFIG_BLOCK CONFIG_MTD_BLOCK \
           CONFIG_EROFS_FS CONFIG_JFFS2_FS CONFIG_SERIAL_ESP32 CONFIG_TTY \
           CONFIG_XTENSA_PLATFORM_ESP32; do
    grep -q "^$sym=y$" .config || { echo "FAIL: $sym is not =y after merge"; exit 1; }
done
grep -q '^# CONFIG_LD_DEAD_CODE_DATA_ELIMINATION is not set$' .config \
    || { echo "FAIL: DCE (sched_clock hang) is not disabled after merge"; exit 1; }
echo "Config verified."

echo "Building xipImage..."
make -j"$(nproc)" KCFLAGS="-Oz -fmerge-all-constants" xipImage
ls -lh arch/xtensa/boot/xipImage

echo "$KVER_REQ" > "$BUILD_DIR/.kernel-version"
cp arch/xtensa/boot/xipImage \
    "$MCULINUX_DIR/tools/prebuilt/binaries/xipImage-$KV_SHORT"
echo ""
echo "=== Done: Linux $KVER_REQ -> tools/prebuilt/binaries/xipImage-$KV_SHORT ==="
