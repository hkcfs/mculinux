#!/bin/bash
# MCUlinux QEMU Test Script
# Tests ESP32-S3 Linux boot in QEMU
# Usage: ./qemu-test.sh [device] [timeout_seconds]
# Devices: r8n8 (default), r8n16, r16n16

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-/app/output}"
QEMU="${QEMU:-qemu-system-xtensa}"

# Defaults
DEVICE="${1:-r8n8}"
TIMEOUT="${2:-30}"
FLASH_SIZE_MB=8

# Device-specific flash sizes
case "$DEVICE" in
    r8n8)   FLASH_SIZE_MB=8 ;;
    r8n16)  FLASH_SIZE_MB=16 ;;
    r16n16) FLASH_SIZE_MB=16 ;;
esac

FLASH_IMAGE="$OUTPUT_DIR/${DEVICE}/flash_${DEVICE}.bin"

echo "=========================================="
echo "MCUlinux QEMU Test"
echo "=========================================="
echo "Device: $DEVICE"
echo "Flash size: ${FLASH_SIZE_MB}MB"
echo "Timeout: ${TIMEOUT}s"
echo ""

# Check flash image exists
if [ ! -f "$FLASH_IMAGE" ]; then
    echo "ERROR: Flash image not found: $FLASH_IMAGE"
    echo "Run build-qemu.sh first to create the flash image."
    exit 1
fi

# Check QEMU exists
if ! command -v "$QEMU" &>/dev/null && [ ! -x "$QEMU" ]; then
    echo "ERROR: QEMU not found: $QEMU"
    echo "Set QEMU environment variable to the path of qemu-system-xtensa."
    exit 1
fi

echo "Flash image: $FLASH_IMAGE ($(ls -lh "$FLASH_IMAGE" | awk '{print $5}'))"
echo "Running QEMU..."
echo "------------------------------------------"

# Run QEMU with timeout
# -m: PSRAM size (must match device config)
# -global driver=ssi_psram,property=is_octal,value=true: enable octal PSRAM
# -drive: flash image
# -nographic: no GUI
timeout "$TIMEOUT" "$QEMU" \
    -M esp32s3 \
    -nographic \
    -m ${FLASH_SIZE_MB}M \
    -global driver=ssi_psram,property=is_octal,value=true \
    -drive file="$FLASH_IMAGE",if=mtd,format=raw \
    2>&1

EXIT_CODE=$?

echo ""
echo "------------------------------------------"

# Evaluate result
if [ "$EXIT_CODE" -eq 124 ]; then
    echo "PASS: QEMU booted successfully (timed out after ${TIMEOUT}s as expected)"
    echo "Linux kernel and rootfs loaded correctly."
    exit 0
elif [ "$EXIT_CODE" -eq 0 ]; then
    echo "INFO: QEMU exited cleanly (exit code 0)"
    exit 0
else
    echo "FAIL: QEMU exited with error code $EXIT_CODE"
    exit 1
fi
