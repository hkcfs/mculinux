#!/bin/bash
# Build MCUlinux firmware

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

echo "Building MCUlinux for $DEVICE"

# Build using Docker
docker build -t mculinux-builder -f docker/Dockerfile.builder .
docker run --rm \
    -v "$(pwd)/mculinux-packages":/packages \
    -v "$(pwd)/output":/output \
    mculinux-builder \
    /scripts/build-packages.sh

docker build -t mculinux-idf -f docker/Dockerfile.idf .
docker run --rm \
    -v "$(pwd)/images":/images \
    -v "$(pwd)/output":/output \
    mculinux-idf \
    /scripts/build-image.sh "$DEVICE"

echo "Build complete!"
echo "Output: $OUTPUT_DIR/$DEVICE/"
ls -la "$OUTPUT_DIR/$DEVICE/"
