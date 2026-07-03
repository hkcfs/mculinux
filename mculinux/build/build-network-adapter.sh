#!/bin/bash
# Build network_adapter.bin with trimmed sdkconfig
# Uses esp-hosted's own ESP-IDF fork inside espressif/idf Docker
# Usage: ./build-network-adapter.sh [--trimmed|--original]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESP_DRIVER="$SCRIPT_DIR/esp-hosted/esp_hosted_ng/esp/esp_driver"
USE_TRIMMED="${1:---trimmed}"

echo "=========================================="
echo "Network Adapter Builder"
echo "=========================================="

if [ "$USE_TRIMMED" = "--trimmed" ]; then
    echo "Mode: TRIMMED (WiFi only, minimal config)"
else
    echo "Mode: ORIGINAL (full config)"
fi
echo ""

sudo docker run --rm \
  -v "$ESP_DRIVER:/project" \
  -w /project \
  -u $(id -u) \
  -e HOME=/tmp \
  -e IDF_GIT_SAFE_DIR='/project' \
  espressif/idf:v5.1 \
  bash -c '
set -e

# Use the esp-hosted bundled ESP-IDF, not the Docker one
export IDF_PATH=/project/esp-idf
export PATH="$IDF_PATH/tools:$PATH"

cd /project/esp-idf
python3 tools/idf_tools.py install 2>&1 | tail -3
. export.sh 2>&1 | tail -3

# Verify we use the right ESP-IDF
echo "IDF_PATH=$IDF_PATH"
idf.py --version

cd /project/network_adapter
rm -rf build
cp sdkconfig.defaults.esp32s3 sdkconfig

idf.py set-target esp32s3 2>&1 | tail -3

if [ "'"$USE_TRIMMED"'" = "--trimmed" ] && [ -f sdkconfig.trimmed ]; then
    echo "Applying trimmed overrides AFTER set-target..."
    while IFS="=" read -r key value; do
        [ -z "$key" ] || [[ "$key" == \#* ]] && continue
        if [ "$value" = "n" ]; then
            sed -i "s/^${key}=y/# ${key} is not set/" sdkconfig
            sed -i "s/^${key}=[0-9].*/# ${key} is not set/" sdkconfig
        else
            sed -i "s/^${key}=.*/${key}=${value}/" sdkconfig
        fi
    done < sdkconfig.trimmed
fi

idf.py build 2>&1 | tail -10

echo ""
echo "Build output:"
ls -lh build/network_adapter.bin build/bootloader/bootloader.bin build/partition_table/partition-table.bin
'

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
