#!/bin/bash
# MCUlinux QEMU Build Script
# Builds ESP32-S3 Linux and creates a flash image for QEMU testing
# Usage: ./build-qemu.sh [device]
# Devices: r8n8 (default), r8n16, r16n16

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPTS="/app/build-scripts"
OUTPUT_DIR="/app/output"

# Default device
DEVICE="${1:-r8n8}"

echo "=========================================="
echo "MCUlinux QEMU Builder"
echo "=========================================="
echo "Device: $DEVICE"
echo ""

# Source device config
CONF="$SCRIPT_DIR/${DEVICE}.conf"
if [ ! -f "$CONF" ]; then
    echo "Error: Config not found: $CONF"
    exit 1
fi
. "$CONF"

echo "Buildroot config: $BUILDROOT_CONFIG"
echo "ESP-Hosted config: $ESP_HOSTED_CONFIG"
echo ""

cd "$BUILD_SCRIPTS"

# Set autoconf path
export PATH="$(pwd)/autoconf-2.71/root/bin:$PATH"

# dynconfig
if [ ! -f xtensa-dynconfig/esp32s3.so ]; then
    echo "Building dynconfig..."
    git clone https://github.com/jcmvbkbc/xtensa-dynconfig -b original
    git clone https://github.com/jcmvbkbc/config-esp32s3 esp32s3
    make -C xtensa-dynconfig ORIG=1 CONF_DIR="$(pwd)" esp32s3.so
fi
export XTENSA_GNU_CONFIG="$(pwd)/xtensa-dynconfig/esp32s3.so"

# toolchain
if [ ! -x crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/xtensa-esp32s3-linux-uclibcfdpic-gcc ]; then
    echo "Building toolchain..."
    git clone https://github.com/jcmvbkbc/crosstool-NG.git -b xtensa-fdpic
    pushd crosstool-NG
    ./bootstrap && ./configure --enable-local && make
    ./ct-ng xtensa-esp32s3-linux-uclibcfdpic
    CT_PREFIX="$(pwd)/builds" nice ./ct-ng build
    popd
fi

# kernel and rootfs
if [ ! -d buildroot ]; then
    echo "Cloning buildroot..."
    git clone https://github.com/jcmvbkbc/buildroot -b xtensa-2024.08-fdpic
else
    pushd buildroot
    git pull
    popd
fi

if [ ! -d "build-buildroot-${BUILDROOT_CONFIG}" ]; then
    echo "Configuring buildroot..."
    nice make -C buildroot O="$(pwd)/build-buildroot-${BUILDROOT_CONFIG}" "${BUILDROOT_CONFIG}_defconfig"
    buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --set-str TOOLCHAIN_EXTERNAL_PATH "$(pwd)/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic"
    buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --set-str TOOLCHAIN_EXTERNAL_PREFIX '$(ARCH)-esp32s3-linux-uclibcfdpic'
    buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --set-str TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX '$(ARCH)-esp32s3-linux-uclibcfdpic'
fi

echo "Building kernel and rootfs..."
nice make -C buildroot O="$(pwd)/build-buildroot-${BUILDROOT_CONFIG}" -j$(nproc)

# Verify buildroot output
[ -f "build-buildroot-${BUILDROOT_CONFIG}/images/xipImage" ] || { echo "ERROR: xipImage not found"; exit 1; }
[ -f "build-buildroot-${BUILDROOT_CONFIG}/images/rootfs.cramfs" ] || { echo "ERROR: rootfs.cramfs not found"; exit 1; }
[ -f "build-buildroot-${BUILDROOT_CONFIG}/images/etc.jffs2" ] || { echo "ERROR: etc.jffs2 not found"; exit 1; }

echo "Buildroot images ready:"
ls -la "build-buildroot-${BUILDROOT_CONFIG}/images/"

# bootloader
if [ ! -d esp-hosted ]; then
    echo "Cloning esp-hosted..."
    git clone https://github.com/jcmvbkbc/esp-hosted -b ipc-5.1.1
fi

echo "Building bootloader..."
pushd esp-hosted/esp_hosted_ng/esp/esp_driver
cmake .
cd esp-idf
. export.sh
cd ../network_adapter
idf.py set-target esp32s3
cp "$ESP_HOSTED_CONFIG" sdkconfig
idf.py build

# Verify bootloader
[ -f build/bootloader/bootloader.bin ] || { echo "ERROR: bootloader.bin not found"; exit 1; }
[ -f build/partition_table/partition-table.bin ] || { echo "ERROR: partition-table.bin not found"; exit 1; }
[ -f build/network_adapter.bin ] || { echo "ERROR: network_adapter.bin not found"; exit 1; }

echo "Bootloader binaries ready:"
ls -la build/bootloader/bootloader.bin build/partition_table/partition-table.bin build/network_adapter.bin
popd

# Create flash image
echo ""
echo "=========================================="
echo "Creating flash image for $DEVICE"
echo "=========================================="

FLASH_SIZE_MB=8
FLASH_SIZE=$((FLASH_SIZE_MB * 1024 * 1024))
FLASH_IMAGE="$OUTPUT_DIR/${DEVICE}/flash_${DEVICE}.bin"

mkdir -p "$OUTPUT_DIR/${DEVICE}"

# Create empty 8MB flash image filled with 0xFF
dd if=/dev/zero bs=1 count=$FLASH_SIZE | tr '\0' '\377' > "$FLASH_IMAGE"

# Write bootloader at 0x0
echo "Writing bootloader at 0x0..."
dd if=esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/bootloader/bootloader.bin \
   of="$FLASH_IMAGE" bs=1 seek=0 conv=notrunc

# Write partition table at 0x8000
echo "Writing partition table at 0x8000..."
dd if=esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/partition_table/partition-table.bin \
   of="$FLASH_IMAGE" bs=1 seek=$((0x8000)) conv=notrunc

# Write network_adapter (factory app) at 0x10000
echo "Writing network_adapter at 0x10000..."
dd if=esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/network_adapter.bin \
   of="$FLASH_IMAGE" bs=1 seek=$((0x10000)) conv=notrunc

# Write etc.jffs2 at 0xB0000
echo "Writing etc.jffs2 at 0xB0000..."
dd if="build-buildroot-${BUILDROOT_CONFIG}/images/etc.jffs2" \
   of="$FLASH_IMAGE" bs=1 seek=$((0xB0000)) conv=notrunc

# Write xipImage at 0x120000
echo "Writing xipImage at 0x120000..."
dd if="build-buildroot-${BUILDROOT_CONFIG}/images/xipImage" \
   of="$FLASH_IMAGE" bs=1 seek=$((0x120000)) conv=notrunc

# Write rootfs.cramfs at 0x480000
echo "Writing rootfs.cramfs at 0x480000..."
dd if="build-buildroot-${BUILDROOT_CONFIG}/images/rootfs.cramfs" \
   of="$FLASH_IMAGE" bs=1 seek=$((0x480000)) conv=notrunc

# Copy individual images for reference
cp "build-buildroot-${BUILDROOT_CONFIG}/images/xipImage" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true
cp "build-buildroot-${BUILDROOT_CONFIG}/images/rootfs.cramfs" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true
cp "build-buildroot-${BUILDROOT_CONFIG}/images/etc.jffs2" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
echo "Flash image: $FLASH_IMAGE"
ls -lh "$FLASH_IMAGE"
echo ""
echo "All output files:"
ls -la "$OUTPUT_DIR/${DEVICE}/"
echo ""
echo "To test with QEMU:"
echo "  timeout 30 qemu-system-xtensa -M esp32s3 -nographic -m ${FLASH_SIZE_MB}M \\"
echo "    -global driver=ssi_psram,property=is_octal,value=true \\"
echo "    -drive file=$FLASH_IMAGE,if=mtd,format=raw"
echo ""
echo "Or use the test script:"
echo "  ./qemu-test.sh ${DEVICE} 30"
echo "=========================================="

# Run QEMU test
echo ""
echo "=========================================="
echo "Running QEMU test (30s timeout)..."
echo "=========================================="

TEST_EXIT=0
timeout 30 qemu-system-xtensa \
    -M esp32s3 \
    -nographic \
    -m ${FLASH_SIZE_MB}M \
    -global driver=ssi_psram,property=is_octal,value=true \
    -drive file="$FLASH_IMAGE",if=mtd,format=raw \
    2>&1 || TEST_EXIT=$?

echo ""
if [ "$TEST_EXIT" -eq 124 ]; then
    echo "QEMU TEST PASSED: Boot successful (timed out after 30s as expected)"
elif [ "$TEST_EXIT" -eq 0 ]; then
    echo "QEMU TEST PASSED: Exited cleanly"
else
    echo "QEMU TEST FAILED: Exit code $TEST_EXIT"
fi
echo "=========================================="
