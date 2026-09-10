#!/bin/bash
# Install Espressif QEMU (xtensa-softmmu with esp32s3 machine)
# Prefers repo binary; falls back to Espressif prebuilt release.
# Usage: ./scripts/install-qemu-esp32.sh [--print-path]
# Prints the qemu-system-xtensa path on success.
set -uo pipefail

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_QEMU="$MCULINUX_DIR/tools/qemu/qemu/bin/qemu-system-xtensa"
DEST_DIR="$MCULINUX_DIR/tools/qemu/esp-prebuilt"
DEST_BIN="$DEST_DIR/bin/qemu-system-xtensa"
# Espressif QEMU release with esp32s3 machine (xtensa-softmmu).
# Pinned to esp-develop-9.2.2-20260417: the 20250228 tag's asset was
# re-rolled upstream and breaks octal PSRAM init (v6.0 firmware aborts
# in cpu_start); the 20260417 bits are verified working.
TARBALL_URL="${QEMU_TARBALL_URL:-https://github.com/espressif/qemu/releases/download/esp-develop-9.2.2-20260417/qemu-xtensa-softmmu-esp_develop_9.2.2_20260417-x86_64-linux-gnu.tar.xz}"

if [ -x "$REPO_QEMU" ]; then
    echo "$REPO_QEMU"
    exit 0
fi

if [ -x "$DEST_BIN" ]; then
    echo "$DEST_BIN"
    exit 0
fi

echo "=== Installing Espressif QEMU (esp32s3) ===" >&2
mkdir -p "$DEST_DIR"
TMP_TARBALL="$(mktemp /tmp/espressif-qemu-XXXXXX.tar.xz)"
if ! wget -q "$TARBALL_URL" -O "$TMP_TARBALL"; then
    echo "FAIL: could not download $TARBALL_URL" >&2
    exit 1
fi
mkdir -p /tmp/espressif-qemu-extract
tar -xf "$TMP_TARBALL" -C /tmp/espressif-qemu-extract
# Tarball contains qemu/ (bin/qemu-system-xtensa, ...)
if [ -d /tmp/espressif-qemu-extract/qemu ]; then
    cp -r /tmp/espressif-qemu-extract/qemu/* "$DEST_DIR/"
else
    cp -r /tmp/espressif-qemu-extract/* "$DEST_DIR/"
fi
rm -rf /tmp/espressif-qemu-extract "$TMP_TARBALL"

if [ -x "$DEST_BIN" ]; then
    echo "$DEST_BIN"
    exit 0
fi

echo "FAIL: qemu-system-xtensa not found after install" >&2
exit 1
