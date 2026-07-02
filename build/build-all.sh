#!/bin/bash
# MCUlinux Build Script
# Builds ESP32-S3 Linux images for all supported devices
# This script is self-contained (does not call upstream rebuild scripts)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/app/build"
OUTPUT_DIR="/app/output"
BUILDROOT_VER="xtensa-2025.08-fdpic"

# Supported devices
DEVICES=("r8n8" "r8n16" "r16n16")

# Parse arguments
DEVICE="${1:-all}"

echo "=========================================="
echo "MCUlinux Builder"
echo "=========================================="
echo "Device: $DEVICE"
echo "Buildroot: $BUILDROOT_VER (kernel 6.16)"
echo ""

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

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
if [ ! -x crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-gcc ]; then
    echo "Building toolchain (musl)..."
    git clone https://github.com/jcmvbkbc/crosstool-NG.git -b xtensa-fdpic
    pushd crosstool-NG
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
CT_BINUTILS_DEVEL_BRANCH="xtensa-2.42-fdpic"
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

# kernel and rootfs
if [ ! -d buildroot ]; then
    echo "Cloning buildroot ($BUILDROOT_VER, kernel 6.16)..."
    git clone https://github.com/jcmvbkbc/buildroot -b "$BUILDROOT_VER"
else
    pushd buildroot
    git pull
    popd
fi

# bootloader (ESP-Hosted)
if [ ! -d esp-hosted ]; then
    echo "Cloning esp-hosted..."
    git clone https://github.com/jcmvbkbc/esp-hosted -b ipc-5.1.1
fi

build_device() {
    local device="$1"
    local conf="$SCRIPT_DIR/${device}.conf"

    if [ ! -f "$conf" ]; then
        echo "Error: Config not found: $conf"
        return 1
    fi

    echo "=========================================="
    echo "Building: $device"
    echo "Config: $conf"
    echo "=========================================="

    # Source device config
    . "$conf"

    # Configure buildroot if not done
    if [ ! -d "build-buildroot-${BUILDROOT_CONFIG}" ]; then
        echo "Configuring buildroot..."
        nice make -C buildroot O="$(pwd)/build-buildroot-${BUILDROOT_CONFIG}" "${BUILDROOT_CONFIG}_defconfig"
        buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --set-str TOOLCHAIN_EXTERNAL_PATH "$(pwd)/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic"
        buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --set-str TOOLCHAIN_EXTERNAL_PREFIX '$(ARCH)-esp32s3-linux-muslfdpic'
        buildroot/utils/config --file "build-buildroot-${BUILDROOT_CONFIG}/.config" --set-str TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX '$(ARCH)-esp32s3-linux-muslfdpic'

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
    [ -f "build-buildroot-${BUILDROOT_CONFIG}/images/xipImage" ] || { echo "ERROR: xipImage not found"; return 1; }
    [ -f "build-buildroot-${BUILDROOT_CONFIG}/images/rootfs.cramfs" ] || { echo "ERROR: rootfs.cramfs not found"; return 1; }
    [ -f "build-buildroot-${BUILDROOT_CONFIG}/images/etc.jffs2" ] || { echo "ERROR: etc.jffs2 not found"; return 1; }

    # Build bootloader if needed
    if [ ! -f esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/network_adapter.bin ]; then
        echo "Building bootloader..."
        pushd esp-hosted/esp_hosted_ng/esp/esp_driver
        cmake .
        cd esp-idf
        . export.sh
        cd ../network_adapter
        idf.py set-target esp32s3
        cp "$ESP_HOSTED_CONFIG" sdkconfig
        idf.py build
        popd
    fi

    # Create flash image
    echo ""
    echo "=========================================="
    echo "Creating flash image for $device"
    echo "=========================================="

    FLASH_SIZE_MB=8
    case "$device" in
        r8n8)   FLASH_SIZE_MB=8 ;;
        r8n16)  FLASH_SIZE_MB=16 ;;
        r16n16) FLASH_SIZE_MB=16 ;;
    esac
    FLASH_SIZE=$((FLASH_SIZE_MB * 1024 * 1024))
    FLASH_IMAGE="$OUTPUT_DIR/${device}/flash_${device}.bin"

    mkdir -p "$OUTPUT_DIR/${device}"

    # Create empty flash image filled with 0xFF
    dd if=/dev/zero bs=1 count=$FLASH_SIZE 2>/dev/null | tr '\0' '\377' > "$FLASH_IMAGE"

    # Write components at correct offsets
    dd if=esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/bootloader/bootloader.bin \
       of="$FLASH_IMAGE" bs=1 seek=0 conv=notrunc 2>/dev/null
    dd if=esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/partition_table/partition-table.bin \
       of="$FLASH_IMAGE" bs=1 seek=$((0x8000)) conv=notrunc 2>/dev/null
    dd if=esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/network_adapter.bin \
       of="$FLASH_IMAGE" bs=1 seek=$((0x10000)) conv=notrunc 2>/dev/null
    dd if="build-buildroot-${BUILDROOT_CONFIG}/images/etc.jffs2" \
       of="$FLASH_IMAGE" bs=1 seek=$((0xB0000)) conv=notrunc 2>/dev/null
    dd if="build-buildroot-${BUILDROOT_CONFIG}/images/xipImage" \
       of="$FLASH_IMAGE" bs=1 seek=$((0x120000)) conv=notrunc 2>/dev/null
    dd if="build-buildroot-${BUILDROOT_CONFIG}/images/rootfs.cramfs" \
       of="$FLASH_IMAGE" bs=1 seek=$((0x480000)) conv=notrunc 2>/dev/null

    # Copy individual images for reference
    cp "build-buildroot-${BUILDROOT_CONFIG}/images/xipImage" "$OUTPUT_DIR/${device}/" 2>/dev/null || true
    cp "build-buildroot-${BUILDROOT_CONFIG}/images/rootfs.cramfs" "$OUTPUT_DIR/${device}/" 2>/dev/null || true
    cp "build-buildroot-${BUILDROOT_CONFIG}/images/etc.jffs2" "$OUTPUT_DIR/${device}/" 2>/dev/null || true
    cp esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/bootloader/bootloader.bin "$OUTPUT_DIR/${device}/" 2>/dev/null || true
    cp esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/partition_table/partition-table.bin "$OUTPUT_DIR/${device}/" 2>/dev/null || true
    cp esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/network_adapter.bin "$OUTPUT_DIR/${device}/" 2>/dev/null || true

    echo "Build complete for $device"
    echo "Flash image: $FLASH_IMAGE"
    ls -lh "$FLASH_IMAGE"
}

# Build
if [ "$DEVICE" = "all" ]; then
    for dev in "${DEVICES[@]}"; do
        build_device "$dev"
    done
else
    build_device "$DEVICE"
fi

echo ""
echo "=========================================="
echo "Build complete!"
echo "Output: $OUTPUT_DIR/"
ls -la "$OUTPUT_DIR/"
echo "=========================================="
