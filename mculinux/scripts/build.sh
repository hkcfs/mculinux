#!/bin/bash
# Full build: bootloader + kernel + flash image + QEMU test
# Usage: ./scripts/build.sh [device]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${1:-r8n8}"

echo "=========================================="
echo "MCUlinux Full Build: $DEVICE"
echo "=========================================="
echo ""

# Step 1: Bootloader
echo "--- Step 1/3: Bootloader ---"
"$SCRIPT_DIR/build-bootloader.sh" --trimmed
echo ""

# Step 2: Kernel + rootfs
echo "--- Step 2/3: Kernel + Rootfs ---"
"$SCRIPT_DIR/build-kernel.sh"
echo ""

# Step 3: Flash image
echo "--- Step 3/3: Flash Image ---"
"$SCRIPT_DIR/build-image.sh" "$DEVICE"
echo ""

# Step 4: QEMU test
echo "--- Step 4/4: QEMU Test ---"
"$SCRIPT_DIR/test-qemu.sh" "$DEVICE" 30
