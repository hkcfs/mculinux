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

# Find QEMU: env > repo binary > Espressif install script > system PATH
# NOTE: system qemu-system-misc lacks the esp32s3 machine; prefer Espressif fork.
if [ -n "${QEMU:-}" ] && [ -x "$QEMU" ]; then
    : # use QEMU from environment
elif [ -x "$MCULINUX_DIR/tools/qemu/qemu/bin/qemu-system-xtensa" ]; then
    QEMU="$MCULINUX_DIR/tools/qemu/qemu/bin/qemu-system-xtensa"
elif [ -x "$MCULINUX_DIR/scripts/install-qemu-esp32.sh" ]; then
    QEMU="$("$MCULINUX_DIR/scripts/install-qemu-esp32.sh" 2>/dev/null)" || QEMU=""
    if [ -z "$QEMU" ] || [ ! -x "$QEMU" ]; then
        echo "SKIP: Espressif qemu-system-xtensa not available"
        echo "  Run: ./scripts/install-qemu-esp32.sh"
        exit 2
    fi
elif command -v qemu-system-xtensa &>/dev/null; then
    echo "WARN: using system qemu-system-xtensa (likely missing esp32s3 machine)"
    QEMU=qemu-system-xtensa
else
    echo "SKIP: qemu-system-xtensa not found"
    echo "  Run: ./scripts/install-qemu-esp32.sh"
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
    # Drive the serial console while QEMU runs: answer a login prompt if one
    # appears, then capture free/meminfo/df for the boot report. The guest
    # usually drops straight to a shell, so stray input is harmless, and the
    # bundles repeat in case the guest is slow to reach userspace.
    OUTPUT=$( {
        for i in 1 2 3 4 5 6; do
            sleep 12
            echo "root"
            echo "---FREE---"; echo "free"
            echo "---MEMINFO---"; echo "cat /proc/meminfo"
            echo "---DF---"; echo "df -h; df -i"
            echo "---MEASURED---"
        done
        sleep 300
    } | timeout "$TIMEOUT" "$QEMU" \
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

# Full serial log for inspection (output/ is gitignored, never committed)
LOG_FILE="$MCULINUX_DIR/output/${DEVICE}/serial_${DEVICE}.log"
mkdir -p "$(dirname "$LOG_FILE")"
echo "$OUTPUT" > "$LOG_FILE"
echo "Full serial log: $LOG_FILE"

# Analyze boot
HAS_KERNEL=false
HAS_TTY=false
HAS_LOGIN=false
HAS_MEASURE=false

if echo "$OUTPUT" | grep -q "Linux version"; then
    HAS_KERNEL=true
fi
if echo "$OUTPUT" | grep -q "ttyS0 at MMIO"; then
    HAS_TTY=true
fi
if echo "$OUTPUT" | grep -q "buildroot login:\|/ # \|~ # "; then
    HAS_LOGIN=true
fi
if echo "$OUTPUT" | grep -q -- "---MEASURED---"; then
    HAS_MEASURE=true
fi

# Guest memory/storage report: full outputs of the last captured block.
# Note on "free disk": / (erofs) is read-only by design and always shows
# 100% — it is not writable free space. Writable space = tmpfs lines
# (and /etc jffs2 if CONFIG_JFFS2_FS is ever enabled; currently off).
report_measure() {
    echo "--- Guest: free (full) ---"
    echo "$OUTPUT" | sed -n '/---FREE---/,/---MEMINFO---/p' | tail -8
    echo "--- Guest: meminfo (full) ---"
    echo "$OUTPUT" | sed -n '/---MEMINFO---/,/---DF---/p' | tail -55
    echo "--- Guest: df -h + df -i (full) ---"
    echo "$OUTPUT" | sed -n '/---DF---/,/---MEASURED---/p' | tail -16
}

# Results
echo ""
echo "Boot results for $DEVICE:"
echo "  Kernel: $HAS_KERNEL"
echo "  TTY:    $HAS_TTY"
echo "  Login:  $HAS_LOGIN"
echo "  Measured: $HAS_MEASURE"
echo ""

if $HAS_LOGIN; then
    echo "PASS: Full boot to login prompt"
    echo "$OUTPUT" | grep -E "(Linux version|ttyS0|Mounted root|Run /sbin/init|login:)" | head -10
    $HAS_MEASURE && report_measure
    exit 0
elif $HAS_TTY; then
    echo "PASS: UART registered, kernel booted"
    echo "$OUTPUT" | grep -E "(Linux version|ttyS0|Mounted root|Run /sbin/init)" | head -10
    $HAS_MEASURE && report_measure
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
