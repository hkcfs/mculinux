#!/bin/bash
# Build WiFi bootloader (network_adapter.bin)
# Uses espressif/idf:latest Docker image (tracks IDF master).
# Override with IDF_IMAGE_TAG=vX.Y for a pinned release.
# Usage: ./scripts/build-bootloader.sh [--trimmed]
#
# NOTE: esp-hosted must be API-compatible with the IDF image used.
# Latest IDF + esp-hosted master are kept in sync by Espressif; a pinned
# IDF tag needs the matching esp-hosted branch (see setup.sh).

set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$MCULINUX_DIR/build"
IDF_TAG="${IDF_IMAGE_TAG:-latest}"
ESP_DRIVER="$MCULINUX_DIR/build/esp-hosted/esp_hosted_ng/esp/esp_driver"
USE_TRIMMED="${1:---trimmed}"

echo "=== Building WiFi Bootloader (espressif/idf:$IDF_TAG) ==="

if [ ! -d "$ESP_DRIVER" ]; then
    echo "ERROR: esp-hosted not found at $ESP_DRIVER"
    echo "Run: cd build && git clone https://github.com/jcmvbkbc/esp-hosted"
    exit 1
fi

sudo docker run --rm \
  -v "$ESP_DRIVER:/project" \
  -w /project \
  -u "$(id -u)" \
  -e HOME=/tmp \
  -e IDF_GIT_SAFE_DIR='/project' \
  "espressif/idf:$IDF_TAG" \
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
