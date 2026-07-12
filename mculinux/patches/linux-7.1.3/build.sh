#!/bin/bash
# Build Linux 7.1.3 xipImage for ESP32-S3
# Prerequisites: xtensa-esp32s3-linux-muslfdpic toolchain in PATH
set -e

KERNEL_SRC="${1:-/tmp/linux-7.1.3}"
CROSS_COMPILE="${CROSS_COMPILE:-/home/debian/mculinux/mculinux/build/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-}"
XTPROJECT="${XTPROJECT:-/home/debian/mculinux/mculinux/tools/project/xtensa/esp32s3}"
XTDYNAMIC_CONFIG="${XTDYNAMIC_CONFIG:-/home/debian/mculinux/mculinux/build/xtensa-dynconfig/esp32s3.so}"

cd "$KERNEL_SRC"

echo "=== Building Linux 7.1.3 for ESP32-S3 ==="
echo "  Source: $KERNEL_SRC"
echo "  Toolchain: $CROSS_COMPILE"

# Apply patches
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/apply.sh" ]; then
    echo "Applying patches..."
    bash "$SCRIPT_DIR/apply.sh"
fi

# Configure
if [ ! -f .config ]; then
    echo "Configuring..."
    if [ -f "$SCRIPT_DIR/defconfig" ]; then
        cp "$SCRIPT_DIR/defconfig" .config
    fi
    make ARCH=xtensa CROSS_COMPILE="$CROSS_COMPILE" XTPROJECT="$XTPROJECT" XTDYNAMIC_CONFIG="$XTDYNAMIC_CONFIG" olddefconfig
fi

# Clean and build
make ARCH=xtensa CROSS_COMPILE="$CROSS_COMPILE" XTPROJECT="$XTPROJECT" XTDYNAMIC_CONFIG="$XTDYNAMIC_CONFIG" clean
make ARCH=xtensa CROSS_COMPILE="$CROSS_COMPILE" XTPROJECT="$XTPROJECT" XTDYNAMIC_CONFIG="$XTDYNAMIC_CONFIG" -j$(nproc)
make ARCH=xtensa CROSS_COMPILE="$CROSS_COMPILE" XTPROJECT="$XTPROJECT" XTDYNAMIC_CONFIG="$XTDYNAMIC_CONFIG" xipImage -j$(nproc)

echo ""
echo "=== Build Complete ==="
echo "  xipImage: $(ls -lh arch/xtensa/boot/xipImage | awk '{print $5}')"
echo ""
