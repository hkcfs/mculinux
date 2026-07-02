#!/bin/bash
# MCUlinux Build Script
# Builds ESP32-S3 Linux images for all supported devices
# Usage: ./build-all.sh [device|all]
#
# This script is self-contained:
#   1. Builds musl cross-toolchain via crosstool-NG
#   2. Builds kernel + rootfs via Buildroot
#   3. Assembles flash images
#   4. Tests images in QEMU

set -e
trap 'echo "ERROR at line $LINENO (exit $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/app/build"
OUTPUT_DIR="/app/output"
BUILDROOT_VER="xtensa-2025.08-fdpic"
LOG_DIR="$OUTPUT_DIR/logs"
QEMU="${QEMU:-/home/debian/mculinux/tools/qemu/qemu/bin/qemu-system-xtensa}"

# Supported devices
DEVICES=("r8n8" "r8n16" "r16n16")

# Parse arguments
DEVICE="${1:-all}"

timestamp() { date '+%H:%M:%S'; }
log() { echo "[$(timestamp)] $*"; }

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR" "$LOG_DIR"

echo "=========================================="
log "MCUlinux Builder"
echo "=========================================="
log "Device: $DEVICE"
log "Buildroot: $BUILDROOT_VER (kernel 6.16)"
log "Output: $OUTPUT_DIR"
echo ""

cd "$BUILD_DIR"

# Set autoconf path
export PATH="$(pwd)/autoconf-2.71/root/bin:$PATH"

# ──────────────────────────────────────────────
# Step 1: dynconfig
# ──────────────────────────────────────────────
if [ ! -f xtensa-dynconfig/esp32s3.so ]; then
    log "Building dynconfig..."
    git clone https://github.com/jcmvbkbc/xtensa-dynconfig -b original
    git clone https://github.com/jcmvbkbc/config-esp32s3 esp32s3
    make -C xtensa-dynconfig ORIG=1 CONF_DIR="$(pwd)" esp32s3.so
fi
export XTENSA_GNU_CONFIG="$(pwd)/xtensa-dynconfig/esp32s3.so"
log "dynconfig ready"

# ──────────────────────────────────────────────
# Step 2: musl cross-toolchain
# ──────────────────────────────────────────────
TOOLCHAIN_PREFIX="crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic"
TOOLCHAIN_GCC="$TOOLCHAIN_PREFIX/bin/xtensa-esp32s3-linux-muslfdpic-gcc"

if [ ! -x "$TOOLCHAIN_GCC" ]; then
    log "Building musl cross-toolchain (this takes 30-60 min)..."
    git clone https://github.com/jcmvbkbc/crosstool-NG.git -b xtensa-fdpic 2>/dev/null || true
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

# Verify toolchain
log "Verifying toolchain..."
for bin in gcc ar as ld; do
    if [ ! -x "$TOOLCHAIN_PREFIX/bin/xtensa-esp32s3-linux-muslfdpic-$bin" ]; then
        echo "FATAL: Toolchain binary missing: $bin"
        exit 1
    fi
done
log "Toolchain ready: $($TOOLCHAIN_GCC --version | head -1)"

# Export for Buildroot
export TOOLCHAIN_EXTERNAL_PATH="$(pwd)/$TOOLCHAIN_PREFIX"
export TOOLCHAIN_EXTERNAL_PREFIX="xtensa-esp32s3-linux-muslfdpic"
export BR2_TOOLCHAIN_EXTERNAL_PATH="$TOOLCHAIN_EXTERNAL_PATH"
export BR2_TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX="$TOOLCHAIN_EXTERNAL_PREFIX"

# ──────────────────────────────────────────────
# Step 3: Buildroot clone/update
# ──────────────────────────────────────────────
if [ ! -d buildroot ]; then
    log "Cloning Buildroot ($BUILDROOT_VER)..."
    git clone https://github.com/jcmvbkbc/buildroot -b "$BUILDROOT_VER"
else
    log "Buildroot already cloned"
fi

# ──────────────────────────────────────────────
# Step 4: esp-hosted (bootloader)
# ──────────────────────────────────────────────
if [ ! -d esp-hosted ]; then
    log "Cloning esp-hosted..."
    git clone https://github.com/jcmvbkbc/esp-hosted -b ipc-5.1.1
fi

# ──────────────────────────────────────────────
# Build per-device
# ──────────────────────────────────────────────
build_device() {
    local device="$1"
    local conf_file="$SCRIPT_DIR/${device}.conf"

    if [ ! -f "$conf_file" ]; then
        echo "ERROR: Config not found: $conf_file"
        return 1
    fi

    # Source device config
    source "$conf_file"

    echo ""
    echo "=========================================="
    log "Building: $device"
    log "  Buildroot config: $BUILDROOT_CONFIG"
    log "  Flash: ${FLASH_SIZE}, PSRAM: ${PSRAM_SIZE}"
    echo "=========================================="

    local BUILDROOT_OUT="build-buildroot-${BUILDROOT_CONFIG}"
    local BUILD_LOG="$LOG_DIR/${device}-build.log"

    # Configure Buildroot
    if [ ! -d "$BUILDROOT_OUT" ]; then
        log "Configuring Buildroot..."
        nice make -C buildroot O="$(pwd)/$BUILDROOT_OUT" "${BUILDROOT_CONFIG}_defconfig" 2>&1 | tee "$BUILD_LOG"

        # Apply external toolchain
        buildroot/utils/config --file "$BUILDROOT_OUT/.config" --set-str TOOLCHAIN_EXTERNAL_PATH "$(pwd)/$TOOLCHAIN_PREFIX"
        buildroot/utils/config --file "$BUILDROOT_OUT/.config" --set-str TOOLCHAIN_EXTERNAL_PREFIX '$(ARCH)-esp32s3-linux-muslfdpic'
        buildroot/utils/config --file "$BUILDROOT_OUT/.config" --set-str TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX '$(ARCH)-esp32s3-linux-muslfdpic'

        # Enable packages
        log "Enabling packages: htop, nano..."
        buildroot/utils/config --file "$BUILDROOT_OUT/.config" --enable BR2_PACKAGE_HTOP
        buildroot/utils/config --file "$BUILDROOT_OUT/.config" --enable BR2_PACKAGE_NANO

        # Enforce -Os globally
        log "Enforcing -Os (optimize for size)..."
        buildroot/utils/config --file "$BUILDROOT_OUT/.config" --enable BR2_OPTIM_S
    fi

    # Build
    log "Building kernel + rootfs (this takes 10-20 min)..."
    nice make -C buildroot O="$(pwd)/$BUILDROOT_OUT" -j$(nproc) 2>&1 | tee -a "$BUILD_LOG"

    # Verify outputs
    log "Verifying build outputs..."
    for f in xipImage rootfs.cramfs etc.jffs2; do
        if [ ! -f "$BUILDROOT_OUT/images/$f" ]; then
            echo "ERROR: Missing: $BUILDROOT_OUT/images/$f"
            return 1
        fi
        log "  $f: $(ls -lh "$BUILDROOT_OUT/images/$f" | awk '{print $5}')"
    done

    # Build bootloader
    local BOOTLOADER_DIR="esp-hosted/esp_hosted_ng/esp/esp_driver"
    if [ ! -f "$BOOTLOADER_DIR/network_adapter/build/network_adapter.bin" ]; then
        log "Building bootloader..."
        pushd "$BOOTLOADER_DIR"
        cmake .
        cd esp-idf
        . export.sh
        cd ../network_adapter
        idf.py set-target esp32s3
        cp "$ESP_HOSTED_CONFIG" sdkconfig
        idf.py build
        popd
    fi

    # ──────────────────────────────────────────────
    # Create flash image
    # ──────────────────────────────────────────────
    log "Creating flash image..."
    local FLASH_SIZE_MB
    case "$device" in
        r8n8)   FLASH_SIZE_MB=8 ;;
        r8n16)  FLASH_SIZE_MB=16 ;;
        r16n16) FLASH_SIZE_MB=16 ;;
    esac
    local FLASH_SIZE_BYTES=$((FLASH_SIZE_MB * 1024 * 1024))
    local FLASH_IMAGE="$OUTPUT_DIR/${device}/flash_${device}.bin"

    mkdir -p "$OUTPUT_DIR/${device}"

    # Create empty flash filled with 0xFF
    dd if=/dev/zero bs=1 count=$FLASH_SIZE_BYTES 2>/dev/null | tr '\0' '\377' > "$FLASH_IMAGE"

    # Write components at offsets
    dd if="$BOOTLOADER_DIR/network_adapter/build/bootloader/bootloader.bin" \
       of="$FLASH_IMAGE" bs=1 seek=0 conv=notrunc 2>/dev/null
    dd if="$BOOTLOADER_DIR/network_adapter/build/partition_table/partition-table.bin" \
       of="$FLASH_IMAGE" bs=1 seek=$((0x8000)) conv=notrunc 2>/dev/null
    dd if="$BOOTLOADER_DIR/network_adapter/build/network_adapter.bin" \
       of="$FLASH_IMAGE" bs=1 seek=$((0x10000)) conv=notrunc 2>/dev/null
    dd if="$BUILDROOT_OUT/images/etc.jffs2" \
       of="$FLASH_IMAGE" bs=1 seek=$((0xB0000)) conv=notrunc 2>/dev/null
    dd if="$BUILDROOT_OUT/images/xipImage" \
       of="$FLASH_IMAGE" bs=1 seek=$((0x120000)) conv=notrunc 2>/dev/null
    dd if="$BUILDROOT_OUT/images/rootfs.cramfs" \
       of="$FLASH_IMAGE" bs=1 seek=$((0x480000)) conv=notrunc 2>/dev/null

    log "Flash image: $FLASH_IMAGE ($(ls -lh "$FLASH_IMAGE" | awk '{print $5}'))"

    # Copy individual images
    for f in xipImage rootfs.cramfs etc.jffs2; do
        cp "$BUILDROOT_OUT/images/$f" "$OUTPUT_DIR/${device}/" 2>/dev/null || true
    done
    for f in bootloader.bin partition-table.bin network_adapter.bin; do
        find "$BOOTLOADER_DIR" -name "$f" -exec cp {} "$OUTPUT_DIR/${device}/" \; 2>/dev/null || true
    done

    log "Build complete for $device"
}

# ──────────────────────────────────────────────
# Execute builds
# ──────────────────────────────────────────────
if [ "$DEVICE" = "all" ]; then
    for dev in "${DEVICES[@]}"; do
        build_device "$dev"
    done
else
    build_device "$DEVICE"
fi

# ──────────────────────────────────────────────
# Step 5: QEMU boot test
# ──────────────────────────────────────────────
echo ""
echo "=========================================="
log "QEMU Boot Test"
echo "=========================================="

QEMU_SCRIPT="$SCRIPT_DIR/qemu-test.sh"
if [ -x "$QEMU_SCRIPT" ]; then
    if [ "$DEVICE" = "all" ]; then
        for dev in "${DEVICES[@]}"; do
            log "Testing $dev..."
            QEMU="$QEMU" "$QEMU_SCRIPT" --device "$dev" 30 || true
        done
    else
        QEMU="$QEMU" "$QEMU_SCRIPT" --device "$DEVICE" 30
    fi
else
    log "QEMU test script not found, skipping"
fi

echo ""
echo "=========================================="
log "All done!"
log "Output directory: $OUTPUT_DIR/"
ls -la "$OUTPUT_DIR/"
echo "=========================================="
