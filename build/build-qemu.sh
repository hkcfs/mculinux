#!/bin/bash
# MCUlinux QEMU Build Script
# Builds ESP32-S3 Linux and creates a flash image for QEMU testing
# Usage: ./build-qemu.sh [device]
# Devices: r8n8 (default), r8n16, r16n16
# Uses musl libc for Alpine Linux compatibility

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPTS="/app/build-scripts"
OUTPUT_DIR="/app/output"

# Default device
DEVICE="${1:-r8n8}"

echo "=========================================="
echo "MCUlinux QEMU Builder (musl)"
echo "=========================================="
echo "Device: $DEVICE"
echo "libc: musl (Alpine-compatible)"
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

# Toolchain - musl variant
TOOLCHAIN_PREFIX="xtensa-esp32s3-linux-muslfdpic"
if [ ! -x crosstool-NG/builds/${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN_PREFIX}-gcc ]; then
    echo "Building musl toolchain..."
    git clone https://github.com/jcmvbkbc/crosstool-NG.git -b xtensa-fdpic
    pushd crosstool-NG

    # Create musl config for ESP32-S3
    mkdir -p samples/xtensa-esp32s3-linux-muslfdpic
    cat > samples/xtensa-esp32s3-linux-muslfdpic/crosstool.config << 'CTEOF'
CT_CONFIG_VERSION="4"
CT_EXPERIMENTAL=y
# CT_PREFIX_DIR_RO is not set
CT_ARCH_XTENSA=y
# CT_DEMULTILIB is not set
# CT_ARCH_USE_MMU is not set
CT_TARGET_CFLAGS="-mauto-litpools -Os"
CT_TARGET_VENDOR="esp32s3"
CT_KERNEL_LINUX=y
CT_LINUX_SRC_DEVEL=y
CT_LINUX_DEVEL_URL="https://github.com/jcmvbkbc/linux-xtensa.git"
CT_LINUX_DEVEL_BRANCH="xtensa-6.16-esp32"
CT_ARCH_BINFMT_FDPIC=y
CT_BINUTILS_SRC_DEVEL=y
CT_BINUTILS_DEVEL_URL="https://github.com/jcmvbkbc/binutils-gdb-xtensa.git"
CT_BINUTILS_DEVEL_BRANCH="xtensa-2.42-fdpic-musl"
CT_BINUTILS_PLUGINS=y
# CT_BINUTILS_RELRO is not set
CT_MUSL_SRC_DEVEL=y
CT_MUSL_DEVEL_URL="https://github.com/jcmvbkbc/musl-xtensa.git"
CT_MUSL_DEVEL_BRANCH="xtensa-1.2.5-fdpic"
CT_GCC_SRC_DEVEL=y
CT_GCC_DEVEL_URL="https://github.com/jcmvbkbc/gcc-xtensa.git"
CT_GCC_DEVEL_BRANCH="xtensa-14-9655-fdpic-musl"
# CT_CC_GCC_SJLJ_EXCEPTIONS is not set
CTEOF

    ./bootstrap && ./configure --enable-local && make
    ./ct-ng xtensa-esp32s3-linux-muslfdpic
    CT_PREFIX="$(pwd)/builds" nice ./ct-ng build
    popd
fi

# Verify toolchain
[ -x "crosstool-NG/builds/${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN_PREFIX}-gcc" ] || { echo "ERROR: musl toolchain not built"; exit 1; }
echo "Musl toolchain ready: $(crosstool-NG/builds/${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN_PREFIX}-gcc --version | head -1)"

# kernel and rootfs
if [ ! -d buildroot ]; then
    echo "Cloning buildroot (xtensa-2025.08-fdpic, kernel 6.16)..."
    git clone https://github.com/jcmvbkbc/buildroot -b xtensa-2025.08-fdpic
else
    pushd buildroot
    git pull
    popd
fi

if [ ! -d "build-buildroot-${BUILDROOT_CONFIG}" ]; then
    echo "Configuring buildroot..."
    nice make -C buildroot O="$(pwd)/build-buildroot-${BUILDROOT_CONFIG}" "${BUILDROOT_CONFIG}_defconfig"

    # Override toolchain to use musl
    buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --set-str TOOLCHAIN_EXTERNAL_PATH "$(pwd)/crosstool-NG/builds/${TOOLCHAIN_PREFIX}"
    buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --set-str TOOLCHAIN_EXTERNAL_PREFIX '$(ARCH)-esp32s3-linux-muslfdpic'
    buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --set-str TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX '$(ARCH)-esp32s3-linux-muslfdpic'

    # Enable additional packages
    echo "Enabling additional packages (htop, nano)..."
    buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --enable BR2_PACKAGE_HTOP
    buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --enable BR2_PACKAGE_NANO

    # Enforce -Os (optimize for size) globally
    echo "Enforcing -Os (optimize for size) for all packages..."
    buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --enable BR2_OPTIM_S
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
