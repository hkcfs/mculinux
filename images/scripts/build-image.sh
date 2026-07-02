#!/bin/bash
# Build MCUlinux firmware image for ESP32-S3

set -e

DEVICE="${1:-r8n8}"
IMAGES_DIR="${IMAGES_DIR:-/images}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
IDF_PATH="${IDF_PATH:-/opt/esp-idf}"

# Valid devices
VALID_DEVICES=("r8n8" "r8n16" "r16n16")

# Validate device
if [[ ! " ${VALID_DEVICES[@]} " =~ " ${DEVICE} " ]]; then
    echo "Error: Invalid device '$DEVICE'"
    echo "Valid devices: ${VALID_DEVICES[*]}"
    exit 1
fi

echo "Building MCUlinux image for $DEVICE"

# Set up ESP-IDF environment
. "$IDF_PATH/export.sh"

# Set target
idf.py set-target esp32s3

# Copy device-specific configuration
cp "$IMAGES_DIR/$DEVICE/config/sdkconfig.defaults" sdkconfig.defaults
cp "$IMAGES_DIR/$DEVICE/partitions/partitions.csv" partitions.csv

# Build
idf.py build

# Create output directory
mkdir -p "$OUTPUT_DIR/$DEVICE"

# Copy build artifacts
cp build/mculinux.bin "$OUTPUT_DIR/$DEVICE/firmware.bin"
cp build/partition_table/partition-table.bin "$OUTPUT_DIR/$DEVICE/partitions.bin"
cp build/bootloader/bootloader.bin "$OUTPUT_DIR/$DEVICE/bootloader.bin"

# Create flash script
cat > "$OUTPUT_DIR/$DEVICE/flash.sh" << 'EOF'
#!/bin/bash
# Flash MCUlinux to ESP32-S3

PORT="${1:-/dev/ttyUSB0}"
BAUD="${2:-115200}"

if ! command -v esptool.py &> /dev/null; then
    echo "Error: esptool.py not found"
    echo "Install with: pip install esptool"
    exit 1
fi

echo "Flashing MCUlinux to $PORT..."

esptool.py --chip esp32s3 --port "$PORT" --baud "$BAUD" \
    write_flash 0x0 \
    bootloader.bin \
    partitions.bin \
    firmware.bin

echo "Flash complete!"
echo "Open serial console with: screen $PORT 115200"
EOF

chmod +x "$OUTPUT_DIR/$DEVICE/flash.sh"

# Create device info file
cat > "$OUTPUT_DIR/$DEVICE/device.json" << EOF
{
    "device": "$DEVICE",
    "target": "esp32s3",
    "memory": {
        "psram": "$(case $DEVICE in
            r8n8|r8n16) echo "8MB" ;;
            r16n16) echo "16MB" ;;
        esac)",
        "flash": "$(case $DEVICE in
            r8n8) echo "8MB" ;;
            r8n16|r16n16) echo "16MB" ;;
        esac)"
    },
    "build": {
        "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "idf_version": "$IDF_VERSION",
        "target": "esp32s3"
    }
}
EOF

echo "Build complete for $DEVICE"
echo "Output: $OUTPUT_DIR/$DEVICE/"
