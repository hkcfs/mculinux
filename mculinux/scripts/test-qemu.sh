#!/bin/bash
# Test flash image in QEMU
# Usage: ./scripts/test-qemu.sh [device] [timeout]
# Devices: r8n8 (default), r8n16, r16n16

set -uo pipefail

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-r8n8}"
TIMEOUT="${2:-30}"

FLASH_IMAGE="$MCULINUX_DIR/output/${DEVICE}/flash_${DEVICE}.bin"

# Find QEMU: env > local build > system PATH
if [ -n "${QEMU:-}" ] && [ -x "$QEMU" ]; then
    : # use QEMU from environment
elif [ -x "$MCULINUX_DIR/tools/qemu/qemu/bin/qemu-system-xtensa" ]; then
    QEMU="$MCULINUX_DIR/tools/qemu/qemu/bin/qemu-system-xtensa"
elif command -v qemu-system-xtensa &>/dev/null; then
    QEMU=qemu-system-xtensa
else
    echo "SKIP: qemu-system-xtensa not found"
    echo "  Install: sudo apt-get install qemu-system-misc"
    exit 2
fi

if [ ! -f "$FLASH_IMAGE" ]; then
    echo "FAIL: Flash image not found: $FLASH_IMAGE"
    echo "Run: make image DEVICE=$DEVICE"
    exit 1
fi

# Pad to power of 2 if needed
FILE_SIZE=$(stat -c%s "$FLASH_IMAGE")
NEXT_POWER=1
while [ $NEXT_POWER -lt $FILE_SIZE ]; do
    NEXT_POWER=$((NEXT_POWER * 2))
done

if [ $NEXT_POWER -ne $FILE_SIZE ]; then
    PADDED=$(mktemp /tmp/mculinux-XXXXXX.bin)
    dd if=/dev/zero bs=1 count=$NEXT_POWER 2>/dev/null | tr '\0' '\377' > "$PADDED"
    dd if="$FLASH_IMAGE" of="$PADDED" conv=notrunc 2>/dev/null
    FLASH_IMAGE="$PADDED"
fi

# Run QEMU
echo "=== QEMU Test: $DEVICE (${TIMEOUT}s timeout) ==="
OUTPUT=$(timeout "$TIMEOUT" "$QEMU" \
    -M esp32s3 \
    -nographic \
    -m 8M \
    -global driver=ssi_psram,property=is_octal,value=true \
    -drive file="$FLASH_IMAGE",if=mtd,format=raw \
    2>&1) || EXIT_CODE=$?

# Cleanup temp file
[ -n "${PADDED:-}" ] && rm -f "$PADDED"

# Analyze - only PASS if kernel actually booted
if echo "$OUTPUT" | grep -q "Linux version"; then
    echo "PASS: Linux kernel booted"
    echo "$OUTPUT" | grep -E "(Linux version|erofs|Mounted root|Freeing unused|Run /sbin/init|login:)" | head -10
    exit 0
else
    echo "FAIL: Linux kernel did not boot"
    echo "$OUTPUT" | tail -30
    exit 1
fi
