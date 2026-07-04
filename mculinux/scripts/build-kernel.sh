#!/bin/bash
# Build kernel + rootfs via Buildroot
# Tries Docker first, falls back to direct build
# Usage: ./scripts/build-kernel.sh [--no-docker]

set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$MCULINUX_DIR/build"
USE_DOCKER=1

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --no-docker) USE_DOCKER=0; shift ;;
        *) shift ;;
    esac
done

echo "=== Building Kernel + Rootfs ==="

# Check toolchain exists
TOOLCHAIN="$BUILD_DIR/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-gcc"
if [ ! -x "$TOOLCHAIN" ]; then
    echo "ERROR: musl toolchain not found. Run: make setup"
    exit 1
fi

# Check Buildroot
if [ ! -d "$BUILD_DIR/buildroot" ]; then
    echo "ERROR: Buildroot not found. Run: make setup"
    exit 1
fi

# Try Docker if available
if [ "$USE_DOCKER" -eq 1 ] && command -v docker &>/dev/null && docker image inspect mculinux-builder &>/dev/null; then
    echo "Using Docker..."
    sudo docker run --rm \
      -v "$MCULINUX_DIR:/app" \
      -w /app/build \
      -e XTENSA_GNU_CONFIG=/app/build/xtensa-dynconfig/esp32s3.so \
      mculinux-builder:latest \
      bash -c '
set -e
export PATH="$(pwd)/autoconf-2.71/root/bin:$PATH"
export XTENSA_GNU_CONFIG=/app/build/xtensa-dynconfig/esp32s3.so
echo "Toolchain: $(crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-gcc --version 2>/dev/null | head -1)"
echo "Building kernel + rootfs..."
nice make -C buildroot O="$(pwd)/build-buildroot-esp32s3_devkit_c1_8m" -j$(nproc)
'
else
    echo "Building directly (no Docker)..."
    export XTENSA_GNU_CONFIG="$BUILD_DIR/xtensa-dynconfig/esp32s3.so"
    export PATH="$(dirname "$TOOLCHAIN"):$PATH"

    cd "$BUILD_DIR"
    nice make -C buildroot O="$(pwd)/build-buildroot-esp32s3_devkit_c1_8m" -j$(nproc)
fi

echo ""
echo "=== Build Output ==="
for f in xipImage rootfs.erofs etc.jffs2; do
    if [ -f "$BUILD_DIR/build-buildroot-esp32s3_devkit_c1_8m/images/$f" ]; then
        echo "  $f: $(ls -lh "$BUILD_DIR/build-buildroot-esp32s3_devkit_c1_8m/images/$f" | awk '{print $5}')"
    else
        echo "  $f: MISSING"
    fi
done
