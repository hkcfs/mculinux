#!/bin/bash
# Create MCUlinux release package

set -e

VERSION="${1:-0.1.0}"
WORKSPACE="${WORKSPACE:-/workspace}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "Creating MCUlinux release $VERSION"

# Create release directory
mkdir -p "$OUTPUT_DIR/release"

# Build all packages
echo "Building packages..."
cd "$WORKSPACE"
make build-packages

# Build all images
echo "Building images..."
for device in r8n8 r8n16 r16n16; do
    echo "Building $device..."
    make build-images DEVICE=$device
done

# Create release archives
echo "Creating release archives..."
for device in r8n8 r8n16 r16n16; do
    echo "Packaging $device..."
    cd "$OUTPUT_DIR/$device"
    zip -r "$OUTPUT_DIR/release/mculinux-$VERSION-$device.zip" .
    cd "$WORKSPACE"
done

# Create checksums
echo "Creating checksums..."
cd "$OUTPUT_DIR/release"
sha256sum *.zip > checksums.sha256

# Create release manifest
cat > manifest.json << EOF
{
    "version": "$VERSION",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "devices": [
        {
            "name": "r8n8",
            "psram": "8MB",
            "flash": "8MB",
            "file": "mculinux-$VERSION-r8n8.zip"
        },
        {
            "name": "r8n16",
            "psram": "8MB",
            "flash": "16MB",
            "file": "mculinux-$VERSION-r8n16.zip"
        },
        {
            "name": "r16n16",
            "psram": "16MB",
            "flash": "16MB",
            "file": "mculinux-$VERSION-r16n16.zip"
        }
    ],
    "checksums": "checksums.sha256"
}
EOF

echo "Release $VERSION created successfully!"
echo "Output: $OUTPUT_DIR/release/"
ls -la "$OUTPUT_DIR/release/"
