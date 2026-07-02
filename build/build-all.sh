#!/bin/bash
# MCUlinux Build Script
# Builds ESP32-S3 Linux images for all supported devices
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPTS="/app/build-scripts"
OUTPUT_DIR="/app/output"

# Supported devices
DEVICES=("r8n8" "r8n16" "r16n16")

# Parse arguments
DEVICE="${1:-all}"
KEEP="${KEEP:-}"

echo "=========================================="
echo "MCUlinux Builder"
echo "=========================================="
echo "Device: $DEVICE"
echo "Keep flags: ${KEEP:-none}"
echo ""

# Set keep flags from environment
[ -n "$KEEP" ] && export keep_toolchain=y
[ -n "$KEEP" ] && export keep_buildroot=y
[ -n "$KEEP" ] && export keep_rootfs=y
[ -n "$KEEP" ] && export keep_bootloader=y

build_device() {
    local device="$1"
    local conf="$SCRIPT_DIR/${device}.conf"

    if [ ! -f "$conf" ]; then
        echo "Error: Config not found: $conf"
        return 1
    fi

    echo "=========================================="
    echo "Building: $device"
    echo "Config: $conf"
    echo "=========================================="

    # Source device config
    . "$conf"

    # Run the build script
    cd "$BUILD_SCRIPTS"
    if [ -f "$SCRIPT_DIR/keep" ]; then
        . "$SCRIPT_DIR/keep"
    fi

    bash -x ./rebuild-esp32s3-linux-wifi.sh -c "$conf"

    # Copy output
    mkdir -p "$OUTPUT_DIR/$device"
    if [ -d "build/build-buildroot-${BUILDROOT_CONFIG}/images" ]; then
        cp build/build-buildroot-${BUILDROOT_CONFIG}/images/* "$OUTPUT_DIR/$device/" 2>/dev/null || true
    fi

    echo "Build complete for $device"
}

# Build
if [ "$DEVICE" = "all" ]; then
    for dev in "${DEVICES[@]}"; do
        build_device "$dev"
    done
else
    build_device "$DEVICE"
fi

echo ""
echo "=========================================="
echo "Build complete!"
echo "Output: $OUTPUT_DIR/"
ls -la "$OUTPUT_DIR/"
echo "=========================================="
