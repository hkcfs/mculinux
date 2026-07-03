#!/bin/bash
# Build WiFi bootloader (network_adapter.bin)
# Uses espressif/idf:v5.1 Docker image
# Usage: ./scripts/build-bootloader.sh [--trimmed]

set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ESP_DRIVER="$MCULINUX_DIR/build/esp-hosted/esp_hosted_ng/esp/esp_driver"
USE_TRIMMED="${1:---trimmed}"

echo "=== Building WiFi Bootloader ==="

if [ ! -d "$ESP_DRIVER" ]; then
    echo "ERROR: esp-hosted not found at $ESP_DRIVER"
    echo "Run: cd build && git clone https://github.com/jcmvbkbc/esp-hosted -b ipc-5.1.1"
    exit 1
fi

sudo docker run --rm \
  -v "$ESP_DRIVER:/project" \
  -w /project \
  -u "$(id -u)" \
  -e HOME=/tmp \
  -e IDF_GIT_SAFE_DIR='/project' \
  espressif/idf:v5.1 \
  bash -c "
set -e

export IDF_PATH=/project/esp-idf
export PATH=\"\$IDF_PATH/tools:\$PATH\"

cd /project/esp-idf
python3 tools/idf_tools.py install 2>&1 | tail -1
. export.sh 2>&1 | tail -1

cd /project/network_adapter
rm -rf build
cp sdkconfig.defaults.esp32s3 sdkconfig

idf.py set-target esp32s3 2>&1 | tail -1

if [ '$USE_TRIMMED' = '--trimmed' ] && [ -f sdkconfig.trimmed ]; then
    echo 'Applying trimmed config...'
    while IFS='=' read -r key value; do
        [ -z \"\$key\" ] || [[ \"\$key\" == \\#* ]] && continue
        if [ \"\$value\" = 'n' ]; then
            sed -i \"s/^\${key}=y/# \${key} is not set/\" sdkconfig
            sed -i \"s/^\${key}=[0-9].*/# \${key} is not set/\" sdkconfig
        else
            sed -i \"s/^\${key}=.*/\${key}=\${value}/\" sdkconfig
        fi
    done < sdkconfig.trimmed
fi

idf.py build 2>&1 | tail -3

echo ''
echo 'Output:'
ls -lh build/network_adapter.bin build/bootloader/bootloader.bin build/partition_table/partition-table.bin
"

# Copy to output
OUTPUT_DIR="$MCULINUX_DIR/output/bootloader"
mkdir -p "$OUTPUT_DIR"
cp "$ESP_DRIVER/network_adapter/build/network_adapter.bin" "$OUTPUT_DIR/"
cp "$ESP_DRIVER/network_adapter/build/bootloader/bootloader.bin" "$OUTPUT_DIR/"
cp "$ESP_DRIVER/network_adapter/build/partition_table/partition-table.bin" "$OUTPUT_DIR/"

echo ""
echo "=== Bootloader built ==="
echo "Output: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
