#!/bin/bash
# Test MCUlinux firmware with QEMU

set -e

DEVICE="${1:-r8n8}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

# Valid devices
VALID_DEVICES=("r8n8" "r8n16" "r16n16")

# Validate device
if [[ ! " ${VALID_DEVICES[@]} " =~ " ${DEVICE} " ]]; then
    echo "Error: Invalid device '$DEVICE'"
    echo "Valid devices: ${VALID_DEVICES[*]}"
    exit 1
fi

echo "Testing MCUlinux $DEVICE with QEMU"

# Build QEMU test image
docker build -t mculinux-qemu -f docker/Dockerfile.qemu .

# Run tests
docker run --rm \
    -v "$(pwd)/output":/output \
    mculinux-qemu \
    /scripts/run-tests.sh "$DEVICE"

echo "Tests completed!"
echo "Test report: $OUTPUT_DIR/$DEVICE/test-report.json"
