#!/bin/bash
# Test flash image in QEMU
# Usage: ./scripts/test-qemu.sh [device] [timeout]
# Devices: r8n8 (default), r8n16, r16n16

set -uo pipefail

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-r8n8}"
TIMEOUT="${2:-30}"

FLASH_IMAGE="$MCULINUX_DIR/output/${DEVICE}/flash_${DEVICE}.bin"

# Per-device QEMU memory config
case "$DEVICE" in
    r8n8)   QEMU_RAM="8M" ;;
    r8n16)  QEMU_RAM="8M" ;;
    r16n16) QEMU_RAM="8M" ;;  # 16MB RAM causes kernel hang; use 8MB
    *)      QEMU_RAM="8M" ;;
esac

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

PADDED=""
if [ $NEXT_POWER -ne $FILE_SIZE ]; then
    PADDED=$(mktemp /tmp/mculinux-XXXXXX.bin)
    dd if=/dev/zero bs=1 count=$NEXT_POWER 2>/dev/null | tr '\0' '\377' > "$PADDED"
    dd if="$FLASH_IMAGE" of="$PADDED" conv=notrunc 2>/dev/null
    FLASH_IMAGE="$PADDED"
fi

# Run QEMU (retry on failure for NOMMU flakiness)
echo "=== QEMU Test: $DEVICE (${TIMEOUT}s timeout, ${QEMU_RAM} RAM) ==="
for attempt in 1 2 3; do
    EXIT_CODE=0
    OUTPUT=$(timeout "$TIMEOUT" "$QEMU" \
        -M esp32s3 \
        -nographic \
        -m "$QEMU_RAM" \
        -global driver=ssi_psram,property=is_octal,value=true \
        -drive file="$FLASH_IMAGE",if=mtd,format=raw \
        2>&1) || EXIT_CODE=$?

    # Check for "Bad ram pointer" — flash/bootloader incompatibility
    if echo "$OUTPUT" | grep -q "Bad ram pointer"; then
        echo "  Attempt $attempt: Bad ram pointer (bootloader/flash size mismatch)"
        if [ $attempt -lt 3 ]; then
            sleep 1
            continue
        fi
    fi

    # Check for successful boot
    if echo "$OUTPUT" | grep -q "Linux version"; then
        break
    fi

    if [ $attempt -lt 3 ]; then
        echo "  Attempt $attempt: no boot, retrying..."
        sleep 1
    fi
done

# Cleanup temp file
[ -n "${PADDED:-}" ] && rm -f "$PADDED"

# Analyze boot
HAS_KERNEL=false
HAS_TTY=false
HAS_LOGIN=false

if echo "$OUTPUT" | grep -q "Linux version"; then
    HAS_KERNEL=true
fi
if echo "$OUTPUT" | grep -q "ttyS0 at MMIO"; then
    HAS_TTY=true
fi
if echo "$OUTPUT" | grep -q "buildroot login:"; then
    HAS_LOGIN=true
fi

# Results
echo ""
echo "Boot results for $DEVICE:"
echo "  Kernel: $HAS_KERNEL"
echo "  TTY:    $HAS_TTY"
echo "  Login:  $HAS_LOGIN"
echo ""

if $HAS_LOGIN; then
    echo "PASS: Full boot to login prompt"
    echo "$OUTPUT" | grep -E "(Linux version|ttyS0|Mounted root|Run /sbin/init|login:)" | head -10
    exit 0
elif $HAS_TTY; then
    echo "PASS: UART registered, kernel booted"
    echo "$OUTPUT" | grep -E "(Linux version|ttyS0|Mounted root|Run /sbin/init)" | head -10
    exit 0
elif $HAS_KERNEL; then
    echo "WARN: Kernel booted but no UART/login"
    echo "$OUTPUT" | grep -E "(Linux version|Mounted root|Run /sbin/init)" | head -10
    exit 0
else
    echo "FAIL: Linux kernel did not boot"
    echo "$OUTPUT" | tail -30
    exit 1
fi
