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
KERNEL_VERSION="${KERNEL_VERSION:-latest}"

# Parse args
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS_OVERRIDE="$2"; shift 2 ;;
        --kernel) KERNEL_VER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Resolve kernel version: explicit --kernel, KERNEL_VERSION env, or the
# version stamp left by build-kernel.sh. Never guess silently.
if [ "$KERNEL_VERSION" = "latest" ]; then
    if [ -f "$BUILD_DIR/.kernel-version" ]; then
        KERNEL_VERSION="$(cat "$BUILD_DIR/.kernel-version")"
    else
        echo "ERROR: KERNEL_VERSION=latest but no build/build/.kernel-version stamp."
        echo "  Run: make kernel  (or pass --kernel 7.2)"
        exit 1
    fi
fi

# Normalize full versions (7.2.4) to the prebuilt naming scheme (xipImage-7.2).
KERNEL_VER="$(echo "$KERNEL_VERSION" | cut -d. -f1,2)"

echo "=== Assembling Flash Image: $DEVICE ==="

# Flash size + matching partition table (data partition fills the tail:
# 768K on 8MB, 8.75MB on 16MB)
case "$DEVICE" in
    r8n8)   FLASH_SIZE_MB=8; TABLE_SUFFIX=8m ;;
    *)      FLASH_SIZE_MB=16; TABLE_SUFFIX=16m ;;
esac

FLASH_SIZE_BYTES=$((FLASH_SIZE_MB * 1024 * 1024))
FLASH_IMAGE="$OUTPUT_DIR/${DEVICE}/flash_${DEVICE}.bin"

# Component paths (all committed prebuilts, refreshed by make kernel/busybox/etc or CI)
PREBUILT_BINARIES="$MCULINUX_DIR/tools/prebuilt/binaries"
ESP_HOSTED_DIR="$BUILD_DIR/esp-hosted/esp_hosted_ng/esp/esp_driver"

# Find bootloader binaries: prebuilt binaries > esp-hosted build tree
if [ -f "$PREBUILT_BINARIES/network_adapter.bin" ]; then
    BOOTLOADER_BIN="$PREBUILT_BINARIES/bootloader.bin"
    PARTITION_BIN="$PREBUILT_BINARIES/partition-table-$TABLE_SUFFIX.bin"
    NETWORK_BIN="$PREBUILT_BINARIES/network_adapter.bin"
    echo "Using prebuilt binaries from tools/prebuilt/ (partition table: $TABLE_SUFFIX)"
elif [ -f "$ESP_HOSTED_DIR/network_adapter/build/network_adapter.bin" ]; then
    BOOTLOADER_BIN="$ESP_HOSTED_DIR/network_adapter/build/bootloader/bootloader.bin"
    PARTITION_BIN="$ESP_HOSTED_DIR/network_adapter/build/partition_table/partition-table.bin"
    NETWORK_BIN="$ESP_HOSTED_DIR/network_adapter/build/network_adapter.bin"
    echo "Using esp-hosted bootloader binaries"
else
    echo "ERROR: No bootloader binaries found"
    echo "  Run: make bootloader"
    exit 1
fi
[ -f "$PARTITION_BIN" ] || {
    echo "ERROR: partition table missing: $PARTITION_BIN"
    echo "  Run: ./scripts/build-partition-tables.sh"
    exit 1
}

# Find xipImage: versioned prebuilt only (built by make kernel / CI full).
XIP_IMAGE=""
if [ -f "$PREBUILT_BINARIES/xipImage-$KERNEL_VER" ]; then
    XIP_IMAGE="$PREBUILT_BINARIES/xipImage-$KERNEL_VER"
else
    echo "ERROR: xipImage-$KERNEL_VER not found in $PREBUILT_BINARIES"
    echo "  Run: make kernel KERNEL_VERSION=$KERNEL_VER"
    exit 1
fi

echo "Using kernel $KERNEL_VER: $XIP_IMAGE ($(du -h "$XIP_IMAGE" | cut -f1))"

# Check rootfs: override > committed prebuilt (rebuilt by make busybox / CI full)
ROOTFS=""
if [ -n "$ROOTFS_OVERRIDE" ] && [ -f "$ROOTFS_OVERRIDE" ]; then
    ROOTFS="$ROOTFS_OVERRIDE"
elif [ -f "$PREBUILT_BINARIES/rootfs.erofs" ]; then
    ROOTFS="$PREBUILT_BINARIES/rootfs.erofs"
else
    echo "ERROR: rootfs.erofs not found. Run: make busybox"
    exit 1
fi

# etc.jffs2: committed prebuilt (rebuilt by make etc / CI full)
if [ -f "$PREBUILT_BINARIES/etc.jffs2" ]; then
    JFFS2="$PREBUILT_BINARIES/etc.jffs2"
else
    echo "ERROR: etc.jffs2 not found. Run: make etc"
    exit 1
fi

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

# Stage the bootloader into the output dir first; 16MB+ devices need the
# image header patched to declare the real flash size or the ESP-ROM
# rejects the partition table (partitions past 8MB). The committed
# prebuilt keeps its 8MB header (correct for r8n8).
cp "$BOOTLOADER_BIN" "$OUTPUT_DIR/${DEVICE}/bootloader.bin"
if [ "$FLASH_SIZE_MB" -ne 8 ]; then
    python3 "$MCULINUX_DIR/scripts/patch-bootloader-flashsize.py" \
        "$OUTPUT_DIR/${DEVICE}/bootloader.bin" \
        "$OUTPUT_DIR/${DEVICE}/bootloader.bin" "$FLASH_SIZE_MB" \
        || { echo "ERROR: bootloader flash-size patch failed"; exit 1; }
fi
BOOTLOADER_BIN="$OUTPUT_DIR/${DEVICE}/bootloader.bin"

dd if=/dev/zero bs=1M count=$FLASH_SIZE_MB 2>/dev/null | tr '\0' '\377' > "$FLASH_IMAGE"

# Write at kernel DTB partition offsets
dd if="$BOOTLOADER_BIN" of="$FLASH_IMAGE" bs=1 seek=0 conv=notrunc 2>/dev/null
dd if="$PARTITION_BIN" of="$FLASH_IMAGE" bs=1 seek=$((0x8000)) conv=notrunc 2>/dev/null
dd if="$NETWORK_BIN" of="$FLASH_IMAGE" bs=1 seek=$((0x10000)) conv=notrunc 2>/dev/null
dd if="$JFFS2" of="$FLASH_IMAGE" bs=1 seek=$((0xB0000)) conv=notrunc 2>/dev/null
dd if="$XIP_IMAGE" of="$FLASH_IMAGE" bs=1 seek=$((0x120000)) conv=notrunc 2>/dev/null
dd if="$ROOTFS" of="$FLASH_IMAGE" bs=1 seek=$((0x500000)) conv=notrunc 2>/dev/null

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
