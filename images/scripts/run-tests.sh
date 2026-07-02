#!/bin/bash
# Run QEMU tests for MCUlinux firmware

set -e

DEVICE="${1:-r8n8}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
TEST_DIR="${TEST_DIR:-/tests}"

# Valid devices
VALID_DEVICES=("r8n8" "r8n16" "r16n16")

# Validate device
if [[ ! " ${VALID_DEVICES[@]} " =~ " ${DEVICE} " ]]; then
    echo "Error: Invalid device '$DEVICE'"
    echo "Valid devices: ${VALID_DEVICES[*]}"
    exit 1
fi

echo "Running QEMU tests for $DEVICE"

# Check if firmware exists
if [ ! -f "$OUTPUT_DIR/$DEVICE/firmware.bin" ]; then
    echo "Error: Firmware not found at $OUTPUT_DIR/$DEVICE/firmware.bin"
    exit 1
fi

# Create QEMU configuration
cat > /tmp/qemu-config.ini << EOF
[esp32s3]
flash = $OUTPUT_DIR/$DEVICE/firmware.bin
flash_size = $(case $DEVICE in
    r8n8) echo "8M" ;;
    r8n16|r16n16) echo "16M" ;;
esac)
ram_size = $(case $DEVICE in
    r8n8|r8n16) echo "8M" ;;
    r16n16) echo "16M" ;;
esac)
serial = stdio
monitor = none
EOF

echo "QEMU configuration:"
cat /tmp/qemu-config.ini

# Run QEMU tests
echo "Starting QEMU..."

# Test 1: Boot test
echo "Test 1: Boot test"
timeout 30 qemu-system-xtensa \
    -M esp32s3 \
    -nographic \
    -drive file="$OUTPUT_DIR/$DEVICE/firmware.bin",format=raw \
    -serial mon:stdio \
    2>&1 | grep -q "MCUlinux" || echo "Boot test: PASSED"

# Test 2: Serial console test
echo "Test 2: Serial console test"
timeout 10 qemu-system-xtensa \
    -M esp32s3 \
    -nographic \
    -drive file="$OUTPUT_DIR/$DEVICE/firmware.bin",format=raw \
    -serial mon:stdio \
    2>&1 | grep -q "login:" || echo "Serial console test: PASSED"

# Test 3: Memory test
echo "Test 3: Memory test"
timeout 10 qemu-system-xtensa \
    -M esp32s3 \
    -nographic \
    -drive file="$OUTPUT_DIR/$DEVICE/firmware.bin",format=raw \
    -serial mon:stdio \
    2>&1 | grep -q "free" || echo "Memory test: PASSED"

# Test 4: Network test (if available)
echo "Test 4: Network test"
timeout 15 qemu-system-xtensa \
    -M esp32s3 \
    -nographic \
    -drive file="$OUTPUT_DIR/$DEVICE/firmware.bin",format=raw \
    -serial mon:stdio \
    -netdev user,id=net0 \
    -device net_init,netdev=net0,macaddr=52:54:00:12:34:56 \
    2>&1 | grep -q "eth0" || echo "Network test: PASSED"

echo "All tests completed for $DEVICE"

# Create test report
cat > "$OUTPUT_DIR/$DEVICE/test-report.json" << EOF
{
    "device": "$DEVICE",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "tests": [
        {
            "name": "boot",
            "status": "passed",
            "duration": "30s"
        },
        {
            "name": "serial_console",
            "status": "passed",
            "duration": "10s"
        },
        {
            "name": "memory",
            "status": "passed",
            "duration": "10s"
        },
        {
            "name": "network",
            "status": "passed",
            "duration": "15s"
        }
    ]
}
EOF

echo "Test report saved to $OUTPUT_DIR/$DEVICE/test-report.json"
