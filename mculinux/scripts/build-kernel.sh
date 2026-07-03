#!/bin/bash
# Build kernel + rootfs via Buildroot
# Runs inside mculinux-builder Docker or natively
# Usage: ./scripts/build-kernel.sh

set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$MCULINUX_DIR/build"
OUTPUT_DIR="$MCULINUX_DIR/output"

echo "=== Building Kernel + Rootfs ==="

# Check if toolchain exists
TOOLCHAIN="$BUILD_DIR/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-gcc"
if [ ! -x "$TOOLCHAIN" ]; then
    echo "ERROR: musl toolchain not found"
    echo "Run: cd build && ./build-all.sh (full build)"
    exit 1
fi

echo "Toolchain: $($TOOLCHAIN --version | head -1)"

# Check Buildroot
if [ ! -d "$BUILD_DIR/buildroot" ]; then
    echo "ERROR: Buildroot not found"
    echo "Run: cd build && git clone https://github.com/jcmvbkbc/buildroot -b xtensa-2025.08-fdpic"
    exit 1
fi

# Build
echo "Building kernel + rootfs..."
nice make -C "$BUILD_DIR/buildroot" \
    O="$BUILD_DIR/build-buildroot-esp32s3_devkit_c1_8m" \
    -j$(nproc)

# Verify
BUILDROOT_OUT="$BUILD_DIR/build-buildroot-esp32s3_devkit_c1_8m"
echo ""
echo "=== Build Output ==="
for f in xipImage rootfs.cramfs etc.jffs2; do
    if [ -f "$BUILDROOT_OUT/images/$f" ]; then
        echo "  $f: $(ls -lh "$BUILDROOT_OUT/images/$f" | awk '{print $5}')"
    else
        echo "  $f: MISSING"
    fi
done
