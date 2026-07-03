#!/bin/bash
# Build kernel + rootfs via Buildroot
# Runs inside mculinux-builder Docker
# Usage: ./scripts/build-kernel.sh

set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$MCULINUX_DIR/build"

echo "=== Building Kernel + Rootfs (Docker) ==="

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

# Run inside Docker
sudo docker run --rm \
  -v "$MCULINUX_DIR:/workspace" \
  -w /workspace/build \
  mculinux-builder:latest \
  bash -c '
set -e
export PATH="$(pwd)/autoconf-2.71/root/bin:$PATH"

echo "Toolchain: $(crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-gcc --version 2>/dev/null | head -1)"

echo "Building kernel + rootfs..."
nice make -C buildroot O="$(pwd)/build-buildroot-esp32s3_devkit_c1_8m" -j$(nproc)

echo ""
echo "=== Build Output ==="
for f in xipImage rootfs.cramfs etc.jffs2; do
    if [ -f "build-buildroot-esp32s3_devkit_c1_8m/images/$f" ]; then
        echo "  $f: $(ls -lh "build-buildroot-esp32s3_devkit_c1_8m/images/$f" | awk '"'"'{print $5}'"'"')"
    else
        echo "  $f: MISSING"
    fi
done
'
