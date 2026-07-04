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
BOOTLOADER_DIR="$BUILD_DIR/esp-hosted/esp_hosted_ng/esp/esp_driver"

# Verify components exist
MISSING=0
for f in "$BOOTLOADER_DIR/network_adapter/build/bootloader/bootloader.bin" \
         "$BOOTLOADER_DIR/network_adapter/build/partition_table/partition-table.bin" \
         "$BOOTLOADER_DIR/network_adapter/build/network_adapter.bin" \
         "$BUILDROOT_OUT/images/xipImage" \
         "$BUILDROOT_OUT/images/etc.jffs2"; do
    if [ ! -f "$f" ]; then
        echo "MISSING: $f"
        MISSING=1
    fi
done

# Check rootfs (prefer erofs for better compression)
ROOTFS=""
if [ -n "$ROOTFS_OVERRIDE" ] && [ -f "$ROOTFS_OVERRIDE" ]; then
    ROOTFS="$ROOTFS_OVERRIDE"
elif [ -f "$BUILDROOT_OUT/images/rootfs.erofs" ]; then
    ROOTFS="$BUILDROOT_OUT/images/rootfs.erofs"
fi

if [ -z "$ROOTFS" ]; then
    echo "MISSING: rootfs.erofs"
    MISSING=1
fi

if [ "$MISSING" -eq 1 ]; then
    echo "ERROR: Missing components. Run build-bootloader.sh and build-kernel.sh first."
    exit 1
fi

# Create flash image
mkdir -p "$OUTPUT_DIR/${DEVICE}"
echo "Creating ${FLASH_SIZE_MB}MB flash image..."

dd if=/dev/zero bs=1 count=$FLASH_SIZE_BYTES 2>/dev/null | tr '\0' '\377' > "$FLASH_IMAGE"

# Write at kernel DTB partition offsets
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
dd if="$ROOTFS" \
   of="$FLASH_IMAGE" bs=1 seek=$((0x480000)) conv=notrunc 2>/dev/null

# Copy components to output
cp "$ROOTFS" "$OUTPUT_DIR/${DEVICE}/rootfs.erofs" 2>/dev/null || true
cp "$BUILDROOT_OUT/images/xipImage" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true
cp "$BUILDROOT_OUT/images/etc.jffs2" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true
cp "$BOOTLOADER_DIR/network_adapter/build/bootloader/bootloader.bin" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true
cp "$BOOTLOADER_DIR/network_adapter/build/partition_table/partition-table.bin" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true
cp "$BOOTLOADER_DIR/network_adapter/build/network_adapter.bin" "$OUTPUT_DIR/${DEVICE}/" 2>/dev/null || true

echo ""
echo "=== Flash Image Ready ==="
echo "  Image: $FLASH_IMAGE ($(ls -lh "$FLASH_IMAGE" | awk '{print $5}'))"
echo "  Rootfs: $(ls -lh "$ROOTFS" | awk '{print $5}')"
echo ""
echo "Components:"
ls -lh "$OUTPUT_DIR/${DEVICE}/"
