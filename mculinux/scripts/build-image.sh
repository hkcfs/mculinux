#!/bin/bash
# Assemble flash image from components
# Usage: ./scripts/build-image.sh [device] [--rootfs path]
# Devices: r8n8 (default), r8n16, r16n16

set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$MCULINUX_DIR/build"
OUTPUT_DIR="$MCULINUX_DIR/output"
DEVICE="${1:-r8n8}"
ROOTFS_OVERRIDE=""

# Parse args
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS_OVERRIDE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo "=== Assembling Flash Image: $DEVICE ==="

# Flash size
case "$DEVICE" in
    r8n8)   FLASH_SIZE_MB=8 ;;
    *)      FLASH_SIZE_MB=16 ;;
esac

FLASH_SIZE_BYTES=$((FLASH_SIZE_MB * 1024 * 1024))
FLASH_IMAGE="$OUTPUT_DIR/${DEVICE}/flash_${DEVICE}.bin"

# Component paths
BUILDROOT_OUT="$BUILD_DIR/build-buildroot-esp32s3_devkit_c1_8m"
PREBUILT_DIR="$MCULINUX_DIR/prebuilt/bootloader"
ESP_HOSTED_DIR="$BUILD_DIR/esp-hosted/esp_hosted_ng/esp/esp_driver"
KERNEL_PKG="$MCULINUX_DIR/mculinux-packages/packages/linux-esp32s3"

# Find bootloader binaries: prefer prebuilt, fallback to esp-hosted
if [ -f "$PREBUILT_DIR/network_adapter.bin" ]; then
    BOOTLOADER_BIN="$PREBUILT_DIR/bootloader.bin"
    PARTITION_BIN="$PREBUILT_DIR/partition-table.bin"
    NETWORK_BIN="$PREBUILT_DIR/network_adapter.bin"
    echo "Using prebuilt bootloader binaries"
elif [ -f "$ESP_HOSTED_DIR/network_adapter/build/network_adapter.bin" ]; then
    BOOTLOADER_BIN="$ESP_HOSTED_DIR/network_adapter/build/bootloader/bootloader.bin"
    PARTITION_BIN="$ESP_HOSTED_DIR/network_adapter/build/partition_table/partition-table.bin"
    NETWORK_BIN="$ESP_HOSTED_DIR/network_adapter/build/network_adapter.bin"
    echo "Using esp-hosted bootloader binaries"
else
    echo "ERROR: No bootloader binaries found"
    echo "  Run: make bootloader"
    echo "  Or ensure prebuilt/ exists"
    exit 1
fi

# Find xipImage: prefer kernel package, fallback to Buildroot
if [ -f "$KERNEL_PKG/output/xtensa-6.16-esp32/xipImage" ]; then
    XIP_IMAGE="$KERNEL_PKG/output/xtensa-6.16-esp32/xipImage"
elif [ -f "$KERNEL_PKG/work/linux-xtensa/arch/xtensa/boot/xipImage" ]; then
    XIP_IMAGE="$KERNEL_PKG/work/linux-xtensa/arch/xtensa/boot/xipImage"
elif [ -f "$BUILDROOT_OUT/images/xipImage" ]; then
    XIP_IMAGE="$BUILDROOT_OUT/images/xipImage"
else
    echo "ERROR: xipImage not found"
    exit 1
fi

# Check rootfs (prefer erofs for better compression)
ROOTFS=""
if [ -n "$ROOTFS_OVERRIDE" ] && [ -f "$ROOTFS_OVERRIDE" ]; then
    ROOTFS="$ROOTFS_OVERRIDE"
elif [ -f "$BUILDROOT_OUT/images/rootfs.erofs" ]; then
    ROOTFS="$BUILDROOT_OUT/images/rootfs.erofs"
fi

# Find etc.jffs2
JFFS2="$BUILDROOT_OUT/images/etc.jffs2"

# Verify all components exist
MISSING=0
for f in "$BOOTLOADER_BIN" "$PARTITION_BIN" "$NETWORK_BIN" "$XIP_IMAGE" "$JFFS2"; do
    if [ ! -f "$f" ]; then
        echo "MISSING: $f"
        MISSING=1
    fi
done

if [ -z "$ROOTFS" ]; then
    echo "MISSING: rootfs.erofs"
    MISSING=1
fi

if [ "$MISSING" -eq 1 ]; then
    echo "ERROR: Missing components. Run make kernel-package first."
    exit 1
fi

# Create flash image
mkdir -p "$OUTPUT_DIR/${DEVICE}"
echo "Creating ${FLASH_SIZE_MB}MB flash image..."

dd if=/dev/zero bs=1 count=$FLASH_SIZE_BYTES 2>/dev/null | tr '\0' '\377' > "$FLASH_IMAGE"

# Write at kernel DTB partition offsets
dd if="$BOOTLOADER_BIN" of="$FLASH_IMAGE" bs=1 seek=0 conv=notrunc 2>/dev/null
dd if="$PARTITION_BIN" of="$FLASH_IMAGE" bs=1 seek=$((0x8000)) conv=notrunc 2>/dev/null
dd if="$NETWORK_BIN" of="$FLASH_IMAGE" bs=1 seek=$((0x10000)) conv=notrunc 2>/dev/null
dd if="$JFFS2" of="$FLASH_IMAGE" bs=1 seek=$((0xB0000)) conv=notrunc 2>/dev/null
dd if="$XIP_IMAGE" of="$FLASH_IMAGE" bs=1 seek=$((0x120000)) conv=notrunc 2>/dev/null
dd if="$ROOTFS" of="$FLASH_IMAGE" bs=1 seek=$((0x480000)) conv=notrunc 2>/dev/null

# Copy components to output
cp "$ROOTFS" "$OUTPUT_DIR/${DEVICE}/rootfs.erofs" 2>/dev/null || true
cp "$XIP_IMAGE" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true
cp "$JFFS2" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true
cp "$BOOTLOADER_BIN" "$OUTPUT_DIR/${DEVICE}/bootloader.bin" 2>/dev/null || true
cp "$PARTITION_BIN" "$OUTPUT_DIR/${DEVICE}/partition-table.bin" 2>/dev/null || true
cp "$NETWORK_BIN" "$OUTPUT_DIR/${DEVICE}/network_adapter.bin" 2>/dev/null || true

echo ""
echo "=== Flash Image Ready ==="
echo "  Image: $FLASH_IMAGE ($(ls -lh "$FLASH_IMAGE" | awk '{print $5}'))"
echo "  Rootfs: $(ls -lh "$ROOTFS" | awk '{print $5}')"
echo ""
echo "Components:"
ls -lh "$OUTPUT_DIR/${DEVICE}/"
