#!/bin/bash
# Build all MCUlinux firmware images

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICES=("r8n8" "r8n16" "r16n16")

echo "Building all MCUlinux images..."

for device in "${DEVICES[@]}"; do
    echo "=========================================="
    echo "Building $device"
    echo "=========================================="
    "$SCRIPT_DIR/build-image.sh" "$device"
    echo ""
done

echo "All images built successfully!"
echo "Output directories:"
for device in "${DEVICES[@]}"; do
    echo "  - $device/"
done
