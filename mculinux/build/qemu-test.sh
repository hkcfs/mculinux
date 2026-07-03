#!/bin/bash
# MCUlinux QEMU Boot Test
# Verifies ESP32-S3 Linux image boots correctly in QEMU
# Usage: ./qemu-test.sh <flash_image> [timeout_seconds]
#        ./qemu-test.sh --device r8n8 [timeout_seconds]
#
# Exit codes:
#   0 = PASS (booted successfully)
#   1 = FAIL (image missing, QEMU error, or boot failure)
#   2 = SKIP (QEMU not available)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU="${QEMU:-$(dirname "$SCRIPT_DIR")/tools/qemu/qemu/bin/qemu-system-xtensa}"

# Parse arguments
FLASH_IMAGE=""
DEVICE=""
TIMEOUT=30

if [ "${1:-}" = "--device" ]; then
    DEVICE="${2:-r8n8}"
    TIMEOUT="${3:-30}"
    OUTPUT_DIR="${OUTPUT_DIR:-/app/output}"
    FLASH_IMAGE="$OUTPUT_DIR/${DEVICE}/flash_${DEVICE}.bin"
else
    FLASH_IMAGE="${1:-}"
    TIMEOUT="${2:-30}"
fi

if [ -z "$FLASH_IMAGE" ]; then
    echo "Usage: $0 <flash_image> [timeout_seconds]"
    echo "       $0 --device r8n8 [timeout_seconds]"
    exit 1
fi

echo "=========================================="
echo "MCUlinux QEMU Boot Test"
echo "=========================================="
echo "Image: $FLASH_IMAGE"
echo "Timeout: ${TIMEOUT}s"
echo ""

# Check flash image exists
if [ ! -f "$FLASH_IMAGE" ]; then
    echo "FAIL: Flash image not found: $FLASH_IMAGE"
    exit 1
fi

# Check QEMU exists
if [ ! -x "$QEMU" ] && ! command -v "$QEMU" &>/dev/null; then
    echo "SKIP: QEMU not found at: $QEMU"
    echo "Install ESP-IDF QEMU or set QEMU env var."
    exit 2
fi

IMG_SIZE=$(stat -c%s "$FLASH_IMAGE" 2>/dev/null || stat -f%z "$FLASH_IMAGE" 2>/dev/null)
IMG_SIZE_MB=$((IMG_SIZE / 1024 / 1024))
echo "Image size: ${IMG_SIZE_MB}MB"

# Pad image if not power of 2 (QEMU requires 2, 4, 8, or 16MB)
PADDED=false
case $IMG_SIZE_MB in
    2|4|8|16) ;;
    *)
        echo "Note: Image is ${IMG_SIZE_MB}MB, QEMU needs 2/4/8/16MB. Padding..."
        PADDED=true
        ;;
esac

# Create temp padded image if needed
if [ "$PADDED" = true ]; then
    # Find next power of 2
    for sz in 2 4 8 16; do
        if [ $sz -ge $IMG_SIZE_MB ]; then
            PADDED_SIZE_MB=$sz
            break
        fi
    done
    PADDED_IMAGE=$(mktemp /tmp/mculinux-qemu-XXXXXX.bin)
    PADDED_SIZE=$((PADDED_SIZE_MB * 1024 * 1024))
    dd if=/dev/zero bs=1 count=$PADDED_SIZE 2>/dev/null | tr '\0' '\377' > "$PADDED_IMAGE"
    dd if="$FLASH_IMAGE" of="$PADDED_IMAGE" conv=notrunc 2>/dev/null
    FLASH_IMAGE="$PADDED_IMAGE"
    echo "Padded to ${PADDED_SIZE_MB}MB for QEMU"
fi

# Determine memory size (use flash size as PSRAM indicator)
MEMORY_MB=${IMG_SIZE_MB}
# r8n8=8MB PSRAM, r8n16=8MB PSRAM, r16n16=16MB PSRAM
if [ -n "$DEVICE" ]; then
    case "$DEVICE" in
        r8n8|r8n16) MEMORY_MB=8 ;;
        r16n16) MEMORY_MB=16 ;;
    esac
fi

# Run QEMU, capture output
LOG_FILE=$(mktemp /tmp/mculinux-boot-XXXXXX.log)
echo "Running QEMU (memory: ${MEMORY_MB}MB)..."
echo "------------------------------------------"

timeout "$TIMEOUT" "$QEMU" \
    -M esp32s3 \
    -nographic \
    -m ${MEMORY_MB}M \
    -global driver=ssi_psram,property=is_octal,value=true \
    -drive file="$FLASH_IMAGE",if=mtd,format=raw \
    > "$LOG_FILE" 2>&1

EXIT_CODE=$?

echo ""
echo "------------------------------------------"
echo "QEMU output (last 30 lines):"
echo "------------------------------------------"
tail -30 "$LOG_FILE"
echo "------------------------------------------"

# Analyze boot output
BOOT_OK=false
HAS_PANIC=false
HAS_SHELL=false

if grep -qi "Linux version" "$LOG_FILE" 2>/dev/null; then
    BOOT_OK=true
    echo "[check] Kernel booted: YES"
else
    echo "[check] Kernel booted: NO"
fi

if grep -qi "panic\|kernel panic\|oops\|BUG:" "$LOG_FILE" 2>/dev/null; then
    HAS_PANIC=true
    echo "[check] Kernel panic: YES (FAIL)"
else
    echo "[check] Kernel panic: NO"
fi

if grep -qi "/ #\|/ \$\|localhost\|login:" "$LOG_FILE" 2>/dev/null; then
    HAS_SHELL=true
    echo "[check] Shell prompt: YES"
else
    echo "[check] Shell prompt: NO"
fi

# Cleanup
rm -f "$LOG_FILE"
[ "$PADDED" = true ] && rm -f "$PADDED_IMAGE"

echo ""
echo "------------------------------------------"

# Final verdict
if [ "$EXIT_CODE" -eq 124 ]; then
    if [ "$BOOT_OK" = true ] && [ "$HAS_PANIC" = false ]; then
        echo "PASS: Image booted successfully in ${TIMEOUT}s"
        echo "  - Kernel loaded"
        [ "$HAS_SHELL" = true ] && echo "  - Shell prompt reached"
        exit 0
    else
        echo "FAIL: QEMU timed out but boot issues detected"
        exit 1
    fi
elif [ "$EXIT_CODE" -eq 0 ]; then
    if [ "$BOOT_OK" = true ] && [ "$HAS_PANIC" = false ]; then
        echo "PASS: Image booted and exited cleanly"
        exit 0
    else
        echo "FAIL: QEMU exited cleanly but boot issues detected"
        exit 1
    fi
else
    echo "FAIL: QEMU exited with error code $EXIT_CODE"
    exit 1
fi
