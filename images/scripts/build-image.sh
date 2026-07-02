#!/bin/bash
# Build MCUlinux firmware image for ESP32-S3
# Uses official espressif/idf Docker image with idf.py

set -e

DEVICE="${1:-r8n8}"
IMAGES_DIR="${IMAGES_DIR:-/images}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
FIRMWARE_DIR="${FIRMWARE_DIR:-/firmware}"

# Valid devices
VALID_DEVICES=("r8n8" "r8n16" "r16n16")

# Validate device
if [[ ! " ${VALID_DEVICES[@]} " =~ " ${DEVICE} " ]]; then
    echo "Error: Invalid device '$DEVICE'"
    echo "Valid devices: ${VALID_DEVICES[*]}"
    exit 1
fi

echo "=========================================="
echo "Building MCUlinux image for $DEVICE"
echo "=========================================="

# Source ESP-IDF environment
. "$IDF_PATH/export.sh"

# Set target
idf.py set-target esp32s3

# Copy device-specific config
if [ -f "$IMAGES_DIR/$DEVICE/config/sdkconfig.defaults" ]; then
    cp "$IMAGES_DIR/$DEVICE/config/sdkconfig.defaults" sdkconfig.defaults
fi

if [ -f "$IMAGES_DIR/$DEVICE/partitions/partitions.csv" ]; then
    cp "$IMAGES_DIR/$DEVICE/partitions/partitions.csv" partitions.csv
fi

# Build
idf.py build

# Create output directory
mkdir -p "$OUTPUT_DIR/$DEVICE"

# Copy build artifacts
cp build/mculinux.bin "$OUTPUT_DIR/$DEVICE/firmware.bin"
cp build/partition_table/partition-table.bin "$OUTPUT_DIR/$DEVICE/partitions.bin"
cp build/bootloader/bootloader.bin "$OUTPUT_DIR/$DEVICE/bootloader.bin"
cp build/flasher_args.json "$OUTPUT_DIR/$DEVICE/flasher_args.json"
cp build/flash_args "$OUTPUT_DIR/$DEVICE/flash_args"

# Create combined flash image for QEMU
python -m esptool --chip esp32s3 merge_bin \
    --output "$OUTPUT_DIR/$DEVICE/flash_image.bin" \
    --flash_mode dio \
    --flash_size 16MB \
    --flash_freq 80m \
    0x0 build/bootloader/bootloader.bin \
    0x8000 build/partition_table/partition-table.bin \
    0x10000 build/mculinux.bin

# Create flash script
cat > "$OUTPUT_DIR/$DEVICE/flash.sh" << 'FLASHEOF'
#!/bin/bash
PORT="${1:-/dev/ttyUSB0}"
BAUD="${2:-115200}"

if ! command -v esptool.py &> /dev/null; then
    echo "Error: esptool.py not found. Install: pip install esptool"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Flashing MCUlinux to $PORT..."

esptool.py --chip esp32s3 --port "$PORT" --baud "$BAUD" \
    write_flash 0x0 \
    "$SCRIPT_DIR/bootloader.bin" \
    "$SCRIPT_DIR/partitions.bin" \
    "$SCRIPT_DIR/firmware.bin"

echo "Flash complete! Open serial: screen $PORT 115200"
FLASHEOF
chmod +x "$OUTPUT_DIR/$DEVICE/flash.sh"

# Create device info
cat > "$OUTPUT_DIR/$DEVICE/device.json" << EOF
{
    "device": "$DEVICE",
    "target": "esp32s3",
    "memory": {
        "psram": "$(case $DEVICE in r8n8|r8n16) echo "8MB";; r16n16) echo "16MB";; esac)",
        "flash": "$(case $DEVICE in r8n8) echo "8MB";; r8n16|r16n16) echo "16MB";; esac)"
    },
    "files": ["firmware.bin", "partitions.bin", "bootloader.bin", "flash_image.bin"],
    "build_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo ""
echo "Build complete for $DEVICE"
echo "Output: $OUTPUT_DIR/$DEVICE/"
ls -lh "$OUTPUT_DIR/$DEVICE/"
