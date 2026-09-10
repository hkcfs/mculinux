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
IDF_TAG="${IDF_IMAGE_TAG:-v6.0}"
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
        case "$(basename "$p")" in
            idf-*) continue ;;  # image-IDF patches: applied in-container below
        esac
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
# Same for image-IDF patches (applied in-container to /opt/esp/idf).
FW_SDKCFG="$MCULINUX_DIR/patches/esp-hosted/sdkconfig.mculinux"
if [ -f "$FW_SDKCFG" ]; then
    cp "$FW_SDKCFG" "$ESP_DRIVER/network_adapter/sdkconfig.mculinux"
fi
mkdir -p "$ESP_DRIVER/idf-patches"
rm -f "$ESP_DRIVER"/idf-patches/*.patch 2>/dev/null || true
for p in "$MCULINUX_DIR"/patches/esp-hosted/idf-*.patch; do
    [ -e "$p" ] || break
    cp "$p" "$ESP_DRIVER/idf-patches/"
done
docker run --rm \
  -v "$ESP_DRIVER:/project" \
  -w /project \
  -e HOME=/tmp \
  -e IDF_GIT_SAFE_DIR='/project' \
  "espressif/idf:$IDF_TAG" \
  bash -c "
set -e

export IDF_PATH=/opt/esp/idf
export PATH="\$IDF_PATH/tools:\$PATH"

# IDF v6.0 is authoritative here: the checkout's esp-idf submodule is
# v5.1-era and mixes badly with a v6 image (wrong tools, wrong python
# env, wrong internal APIs). The fork carries version-guarded shims
# for the v6 API deltas (patches/esp-hosted/0002-*). No install step:
# the image ships a consistent IDF + python env + tools.
. /opt/esp/idf/export.sh 2>&1 | tail -1
hash -r
echo '--- IDF check ---'
idf.py --version 2>&1 | head -1
echo \$IDF_PATH

# mculinux image-IDF extensions (committed idf-*.patch, copied to
# /project/idf-patches/ above): git apply validates strictly. Applied
# fresh every build since the image filesystem is ephemeral.
for p in /project/idf-patches/*.patch; do
  [ -e "\$p" ] || break
  echo 'IDF patch applying:'
  echo \$p
  git -C /opt/esp/idf apply --check "\$p" || { echo 'FAIL: IDF patch check'; exit 1; }
  git -C /opt/esp/idf apply "\$p" || { echo 'FAIL: IDF patch apply'; exit 1; }
done

cd /project/network_adapter
rm -rf build
cp sdkconfig.defaults.esp32s3 sdkconfig

# v6.0 validates partition tables at build time: the fork's table has a
# 4K nvs (needs >=12K unless readonly). The flashed table is mculinux's
# own (untouched); this only satisfies the build gate. Idempotent.
sed -i '/^nvs,/ { /readonly/! s/$/,readonly/ }' partition_table.esp32s3

# v6.0 removed several Kconfig choices (APPTRACE_DESTINATION members,
# ESP32-only tracemem); stale lines for surviving members crash kconfgen
# (all-n on an invisible choice) — and kconfgen reads BOTH the seed copy
# and sdkconfig.defaults.esp32s3 as defaults, so strip both files.
# Idempotent (re-deleting is a no-op); fork source itself stays pristine.
# S3 never uses these anyway.
sed -i '/APPTRACE_DEST_JTAG is not set/d; /CONFIG_ESP32_APPTRACE/d' sdkconfig
sed -i '/APPTRACE_DEST_JTAG is not set/d; /CONFIG_ESP32_APPTRACE/d' sdkconfig.defaults.esp32s3

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
