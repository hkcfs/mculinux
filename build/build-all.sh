#!/bin/bash
# MCUlinux Build Script
# Builds ESP32-S3 Linux images for all supported devices
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPTS="/app/build-scripts"
OUTPUT_DIR="/app/output"

# Supported devices
DEVICES=("r8n8" "r8n16" "r16n16")

# Parse arguments
DEVICE="${1:-all}"
KEEP="${KEEP:-}"

echo "=========================================="
echo "MCUlinux Builder"
echo "=========================================="
echo "Device: $DEVICE"
echo "Keep flags: ${KEEP:-none}"
echo ""

# Set keep flags from environment
[ -n "$KEEP" ] && export keep_toolchain=y
[ -n "$KEEP" ] && export keep_buildroot=y
[ -n "$KEEP" ] && export keep_rootfs=y
[ -n "$KEEP" ] && export keep_bootloader=y

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

    # Run the build script
    cd "$BUILD_SCRIPTS"
    if [ -f "$SCRIPT_DIR/keep" ]; then
        . "$SCRIPT_DIR/keep"
    fi

    bash -x ./rebuild-esp32s3-linux-wifi.sh -c "$conf"

    # Copy output
    mkdir -p "$OUTPUT_DIR/$device"
    if [ -d "build/build-buildroot-${BUILDROOT_CONFIG}/images" ]; then
        cp build/build-buildroot-${BUILDROOT_CONFIG}/images/* "$OUTPUT_DIR/$device/" 2>/dev/null || true
    fi

    # Copy bootloader binaries
    ESP_HOSTED_BUILD="esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build"
    if [ -d "$ESP_HOSTED_BUILD" ]; then
        cp "$ESP_HOSTED_BUILD/bootloader/bootloader.bin" "$OUTPUT_DIR/$device/" 2>/dev/null || true
        cp "$ESP_HOSTED_BUILD/partition_table/partition-table.bin" "$OUTPUT_DIR/$device/" 2>/dev/null || true
        cp "$ESP_HOSTED_BUILD/network_adapter.bin" "$OUTPUT_DIR/$device/" 2>/dev/null || true
    fi

    # Create flash image for QEMU testing
    FLASH_SIZE_MB=8
    case "$device" in
        r8n8)   FLASH_SIZE_MB=8 ;;
        r8n16)  FLASH_SIZE_MB=16 ;;
        r16n16) FLASH_SIZE_MB=16 ;;
    esac
    FLASH_SIZE=$((FLASH_SIZE_MB * 1024 * 1024))
    FLASH_IMAGE="$OUTPUT_DIR/$device/flash_${device}.bin"

    if [ -f "$OUTPUT_DIR/$device/bootloader.bin" ] && \
       [ -f "$OUTPUT_DIR/$device/partition-table.bin" ] && \
       [ -f "$OUTPUT_DIR/$device/network_adapter.bin" ] && \
       [ -f "$OUTPUT_DIR/$device/xipImage" ] && \
       [ -f "$OUTPUT_DIR/$device/rootfs.cramfs" ]; then

        echo "Creating flash image for $device (${FLASH_SIZE_MB}MB)..."

        # Create empty flash image filled with 0xFF
        dd if=/dev/zero bs=1 count=$FLASH_SIZE 2>/dev/null | tr '\0' '\377' > "$FLASH_IMAGE"

        # Write components at correct offsets
        dd if="$OUTPUT_DIR/$device/bootloader.bin" of="$FLASH_IMAGE" bs=1 seek=0 conv=notrunc 2>/dev/null
        dd if="$OUTPUT_DIR/$device/partition-table.bin" of="$FLASH_IMAGE" bs=1 seek=$((0x8000)) conv=notrunc 2>/dev/null
        dd if="$OUTPUT_DIR/$device/network_adapter.bin" of="$FLASH_IMAGE" bs=1 seek=$((0x10000)) conv=notrunc 2>/dev/null
        [ -f "$OUTPUT_DIR/$device/etc.jffs2" ] && \
            dd if="$OUTPUT_DIR/$device/etc.jffs2" of="$FLASH_IMAGE" bs=1 seek=$((0xB0000)) conv=notrunc 2>/dev/null
        dd if="$OUTPUT_DIR/$device/xipImage" of="$FLASH_IMAGE" bs=1 seek=$((0x120000)) conv=notrunc 2>/dev/null
        dd if="$OUTPUT_DIR/$device/rootfs.cramfs" of="$FLASH_IMAGE" bs=1 seek=$((0x480000)) conv=notrunc 2>/dev/null

        echo "Flash image: $FLASH_IMAGE"
    fi

    echo "Build complete for $device"
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
