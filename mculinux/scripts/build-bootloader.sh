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

# mculinux firmware extensions (patches/esp-hosted/*.patch). Applied
# host-side before the Docker build; skips cleanly if already applied.
FW_PATCH_DIR="$MCULINUX_DIR/patches/esp-hosted"
if [ -d "$FW_PATCH_DIR" ]; then
    for p in "$FW_PATCH_DIR"/*.patch; do
        [ -e "$p" ] || break
        echo "Firmware patch: $(basename "$p")"
        if (cd "$ESP_DRIVER" && patch -p1 -R --dry-run < "$p" >/dev/null 2>&1); then
            echo "  already applied, skipping"
        elif (cd "$ESP_DRIVER" && patch -p1 --dry-run < "$p" >/dev/null 2>&1); then
            (cd "$ESP_DRIVER" && patch -p1 < "$p") || { echo "FAIL: $p"; exit 1; }
        else
            echo "FAIL: $p does not apply (clean or applied)"; exit 1
        fi
    done
fi

# NOTE: plain `docker` (no sudo): CI runs as root, local users need the
# docker group. Container runs as root (persisted tools live in the
# checkout mount); outputs are copied out with cp, so no fallout.
# mculinux sdkconfig overlay (committed): copied fresh every build so
# build/ stays reproducible without mutating the fork's trimmed file.
FW_SDKCFG="$MCULINUX_DIR/patches/esp-hosted/sdkconfig.mculinux"
if [ -f "$FW_SDKCFG" ]; then
    cp "$FW_SDKCFG" "$ESP_DRIVER/network_adapter/sdkconfig.mculinux"
fi
docker run --rm \
  -v "$ESP_DRIVER:/project" \
  -w /project \
  -e HOME=/tmp \
  -e IDF_GIT_SAFE_DIR='/project' \
  "espressif/idf:$IDF_TAG" \
  bash -c "
set -e

export IDF_PATH=/project/esp-idf
export IDF_TOOLS_PATH=/project/.idf-tools
export PATH="\$IDF_PATH/tools:\$PATH"

# Use the checkout's esp-idf SUBMODULE (the exact IDF the esp-hosted
# fork pins: guaranteed API-compatible, incl. internal wifi symbols).
# The image only provides a container + system python; tools + python
# env install into IDF_TOOLS_PATH (persisted in the checkout mount,
# so repeat builds skip the download). No mixing with /opt/esp/idf.
cd /project/esp-idf
./install.sh esp32s3 2>&1 | tail -2
. ./export.sh 2>&1 | tail -1
hash -r
echo '--- IDF check ---'
idf.py --version 2>&1 | head -1
echo \$IDF_PATH

cd /project/network_adapter
rm -rf build
cp sdkconfig.defaults.esp32s3 sdkconfig

idf.py set-target esp32s3 2>&1 | tail -1
test \${PIPESTATUS[0]} -eq 0 || { echo 'FAIL: set-target'; exit 1; }
[ -f sdkconfig ] || { echo 'FAIL: no sdkconfig after set-target'; exit 1; }

if [ '$USE_TRIMMED' = '--trimmed' ] && [ -f sdkconfig.trimmed ]; then
    echo 'Applying trimmed config...'
    while IFS='=' read -r key value; do
        [ -z \"\$key\" ] || [[ \"\$key\" == \\#* ]] && continue
        if [ \"\$value\" = 'n' ]; then
            sed -i \"s/^\${key}=y/# \${key} is not set/\" sdkconfig
            sed -i \"s/^\${key}=[0-9].*/# \${key} is not set/\" sdkconfig
        else
            # Replace either a set line or a '# KEY is not set' comment
            # (needed to flip Kconfig choices like LOG_DEFAULT_LEVEL_*).
            sed -i \"s/^# \${key} is not set/\${key}=\${value}/;t;s/^\${key}=.*/\${key}=\${value}/\" sdkconfig
        fi
    done < <(cat sdkconfig.trimmed sdkconfig.mculinux 2>/dev/null || cat sdkconfig.trimmed)
fi

idf.py build 2>&1 | tail -3
test \${PIPESTATUS[0]} -eq 0 || { echo 'FAIL: idf.py build'; exit 1; }

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
