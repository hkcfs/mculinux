#!/bin/bash
# Boot flash image in QEMU for manual testing
# Retries automatically if NOMMU init allocation fails (~15% of boots)
# Usage: ./scripts/run-qemu.sh [r8n8|r8n16|r16n16]
#   Log in as root (no password), then run: free
#   Exit with Ctrl+A X

set -euo pipefail

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-r8n8}"
FLASH_IMAGE="$MCULINUX_DIR/output/${DEVICE}/flash_${DEVICE}.bin"

# Per-device QEMU memory config
case "$DEVICE" in
    r8n8)   QEMU_RAM="8M" ;;
    r8n16)  QEMU_RAM="8M" ;;
    r16n16) QEMU_RAM="8M" ;;
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
    echo "Flash image not found. Run: make image DEVICE=$DEVICE"
    exit 1
fi

# Pad to power of 2
FILE_SIZE=$(stat -c%s "$FLASH_IMAGE")
NEXT_POWER=1
while [ $NEXT_POWER -lt $FILE_SIZE ]; do NEXT_POWER=$((NEXT_POWER * 2)); done

for attempt in 1 2 3; do
  PADDED=""
  FP="$FLASH_IMAGE"
  if [ $NEXT_POWER -ne $FILE_SIZE ]; then
    PADDED=$(mktemp /tmp/mculinux-XXXXXX.bin)
    dd if=/dev/zero bs=1 count=$NEXT_POWER 2>/dev/null | tr '\0' '\377' > "$PADDED"
    dd if="$FLASH_IMAGE" of="$PADDED" conv=notrunc 2>/dev/null
    FP="$PADDED"
  fi

  echo "Booting $DEVICE (attempt $attempt, ${QEMU_RAM} RAM)... Login as root (no password), then run: free"
  set +e
  "$QEMU" -M esp32s3 -nographic -m "$QEMU_RAM" \
      -global driver=ssi_psram,property=is_octal,value=true \
      -drive file="$FP",if=mtd,format=raw
  QEMU_EXIT=$?
  set -e

  rm -f "${PADDED:-}"

  # QEMU exit 0 means user exited normally (success)
  # QEMU exit 1 usually means init failed (crash)
  if [ $QEMU_EXIT -eq 0 ]; then
    exit 0
  fi
  echo "  init may have failed, restarting..."
  sleep 1
done

echo "Failed to boot after 3 attempts (NOMMU memory issue)"
exit 1
