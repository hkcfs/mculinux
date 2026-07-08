#!/bin/bash
# Full build: flash image + QEMU test
# Uses prebuilt binaries from tools/prebuilt/binaries/
# Usage: ./scripts/build.sh [device]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${1:-r8n8}"

echo "=========================================="
echo "MCUlinux Flash Image: $DEVICE"
echo "=========================================="
echo ""

# Step 1: Flash image (uses prebuilt binaries)
echo "--- Step 1/2: Flash Image ---"
"$SCRIPT_DIR/build-image.sh" "$DEVICE"
echo ""

# Step 2: QEMU test
echo "--- Step 2/2: QEMU Test ---"
"$SCRIPT_DIR/test-qemu.sh" "$DEVICE" 30
