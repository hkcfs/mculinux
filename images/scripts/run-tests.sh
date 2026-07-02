#!/bin/bash
# Run QEMU tests for MCUlinux firmware
# Uses idf.py qemu from official ESP-IDF QEMU support

set -e

DEVICE="${1:-r8n8}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
FIRMWARE_DIR="${FIRMWARE_DIR:-/firmware}"

VALID_DEVICES=("r8n8" "r8n16" "r16n16")

if [[ ! " ${VALID_DEVICES[@]} " =~ " ${DEVICE} " ]]; then
    echo "Error: Invalid device '$DEVICE'. Valid: ${VALID_DEVICES[*]}"
    exit 1
fi

echo "=========================================="
echo "Testing MCUlinux $DEVICE with QEMU"
echo "=========================================="

# Source ESP-IDF environment
. "$IDF_PATH/export.sh"

# Verify QEMU is available
if ! command -v qemu-system-xtensa &> /dev/null; then
    echo "QEMU not found, installing..."
    python "$IDF_PATH/tools/idf_tools.py" install qemu-xtensa
    export PATH="$HOME/.espressif/tools/qemu-xtensa/esp-qemu/bin:$PATH"
fi

echo "QEMU found: $(which qemu-system-xtensa)"
echo ""

# Check if we have a pre-built flash image
if [ -f "$OUTPUT_DIR/$DEVICE/flash_image.bin" ]; then
    echo "Using pre-built flash image: $OUTPUT_DIR/$DEVICE/flash_image.bin"
    FLASH_FILE="$OUTPUT_DIR/$DEVICE/flash_image.bin"
else
    echo "No pre-built image found. Building first..."
    cd "$FIRMWARE_DIR"
    . "$IDF_PATH/export.sh"
    idf.py set-target esp32s3
    idf.py build

    # Create flash image
    python -m esptool --chip esp32s3 merge_bin \
        --output /tmp/flash_image.bin \
        --flash_mode dio \
        --flash_size 16MB \
        --flash_freq 80m \
        0x0 build/bootloader/bootloader.bin \
        0x8000 build/partition_table/partition-table.bin \
        0x10000 build/mculinux.bin
    FLASH_FILE="/tmp/flash_image.bin"
fi

# Run QEMU with timeout
echo ""
echo "Starting QEMU (10 second boot test)..."
echo "================================================"

QEMU_PID=""

timeout 15 qemu-system-xtensa \
    -M esp32s3 \
    -nographic \
    -drive file="$FLASH_FILE",if=mtd,format=raw \
    -serial mon:stdio \
    -no-reboot \
    2>&1 | tee /tmp/qemu_output.txt &
QEMU_PID=$!

# Wait for QEMU to finish or timeout
wait $QEMU_PID 2>/dev/null || true
QEMU_EXIT=$?

echo ""
echo "================================================"
echo "QEMU output:"
cat /tmp/qemu_output.txt
echo "================================================"

# Check results
PASS=true

if grep -q "MCUlinux" /tmp/qemu_output.txt; then
    echo "[PASS] MCUlinux banner displayed"
else
    echo "[FAIL] MCUlinux banner not found"
    PASS=false
fi

if grep -q "CPU cores" /tmp/qemu_output.txt; then
    echo "[PASS] Chip info displayed"
else
    echo "[FAIL] Chip info not found"
    PASS=false
fi

if grep -q "Free heap" /tmp/qemu_output.txt; then
    echo "[PASS] Heap info displayed"
else
    echo "[FAIL] Heap info not found"
    PASS=false
fi

if grep -q "IDF version" /tmp/qemu_output.txt; then
    echo "[PASS] IDF version displayed"
else
    echo "[FAIL] IDF version not found"
    PASS=false
fi

echo ""
# Create test report
mkdir -p "$OUTPUT_DIR/$DEVICE"
cat > "$OUTPUT_DIR/$DEVICE/test-report.json" << EOF
{
    "device": "$DEVICE",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "qemu": "$(which qemu-system-xtensa)",
    "tests": [
        {"name": "boot_banner", "status": "$(grep -q 'MCUlinux' /tmp/qemu_output.txt && echo passed || echo failed)"},
        {"name": "chip_info", "status": "$(grep -q 'CPU cores' /tmp/qemu_output.txt && echo passed || echo failed)"},
        {"name": "heap_info", "status": "$(grep -q 'Free heap' /tmp/qemu_output.txt && echo passed || echo failed)"},
        {"name": "idf_version", "status": "$(grep -q 'IDF version' /tmp/qemu_output.txt && echo passed || echo failed)"}
    ],
    "overall": "$([ "$PASS" = true ] && echo passed || echo failed)"
}
EOF

if [ "$PASS" = true ]; then
    echo "ALL TESTS PASSED for $DEVICE"
    exit 0
else
    echo "SOME TESTS FAILED for $DEVICE"
    exit 1
fi
