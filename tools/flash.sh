#!/bin/bash
# Flash MCUlinux to ESP32-S3

set -e

DEVICE="${1:-r8n8}"
PORT="${2:-/dev/ttyUSB0}"
BAUD="${3:-115200}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

# Valid devices
VALID_DEVICES=("r8n8" "r8n16" "r16n16")

# Validate device
if [[ ! " ${VALID_DEVICES[@]} " =~ " ${DEVICE} " ]]; then
    echo "Error: Invalid device '$DEVICE'"
    echo "Valid devices: ${VALID_DEVICES[*]}"
    exit 1
fi

# Check if esptool is installed
if ! command -v esptool.py &> /dev/null; then
    echo "Error: esptool.py not found"
    echo "Install with: pip install esptool"
    exit 1
fi

# Check if firmware exists
if [ ! -f "$OUTPUT_DIR/$DEVICE/firmware.bin" ]; then
    echo "Error: Firmware not found at $OUTPUT_DIR/$DEVICE/firmware.bin"
    echo "Please build the firmware first: make build-images DEVICE=$DEVICE"
    exit 1
fi

echo "Flashing MCUlinux $DEVICE to $PORT..."

# Flash firmware
esptool.py --chip esp32s3 --port "$PORT" --baud "$BAUD" \
    write_flash 0x0 \
    "$OUTPUT_DIR/$DEVICE/bootloader.bin" \
    "$OUTPUT_DIR/$DEVICE/partitions.bin" \
    "$OUTPUT_DIR/$DEVICE/firmware.bin"

echo "Flash complete!"
echo ""
echo "Open serial console with:"
echo "  screen $PORT 115200"
echo ""
echo "Or use minicom:"
echo "  minicom -D $PORT -b 115200"
