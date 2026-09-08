#!/bin/bash
# Build etc.jffs2 from mculinux/rootfs/etc/ (single source of /etc).
# The eraseblock MUST match what the MTD layer advertises (erase-size =
# <0x10000> in esp32s3.dtsi); a mismatch produces an unmountable image.
# Output must fit the etc partition (0xB0000, 448KB).
# Usage: ./scripts/build-etc-jffs2.sh [output.jffs2]
set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ETC_SRC="$MCULINUX_DIR/rootfs/etc"
OUTPUT="${1:-$MCULINUX_DIR/tools/prebuilt/binaries/etc.jffs2}"
ERASEBLOCK="${JFFS2_ERASEBLOCK:-0x10000}"
PART_SIZE=$((0x70000))

command -v mkfs.jffs2 >/dev/null 2>&1 || {
    echo "FAIL: mkfs.jffs2 missing."
    echo "  CI builder image has it (mtd-utils). Locally: apt install mtd-utils"
    exit 1
}

echo "=== Building etc.jffs2 (eraseblock $ERASEBLOCK) ==="
# --pad fills the whole partition with cleanmarkers. An unpadded tiny image
# mounts and reads fine, but the first WRITE hangs the filesystem (JFFS2
# cannot classify the unmarked blocks). Full-partition pad is canonical.
mkfs.jffs2 --eraseblock="$ERASEBLOCK" --pad="$PART_SIZE" --squash-uids \
    -r "$ETC_SRC" -o "$OUTPUT"

SIZE=$(stat -c%s "$OUTPUT")
if [ "$SIZE" -gt "$PART_SIZE" ]; then
    echo "FAIL: etc.jffs2 ($SIZE bytes) exceeds etc partition ($PART_SIZE bytes)"
    exit 1
fi
echo "etc.jffs2: $OUTPUT ($(ls -lh "$OUTPUT" | awk '{print $5}'))"
