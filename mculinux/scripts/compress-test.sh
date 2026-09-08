#!/bin/bash
# Compare filesystem compression variants
# Compare filesystem compression variants
# Builds SquashFS variants and EROFS images and compares sizes
# Usage: ./scripts/compress-test.sh

set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$MCULINUX_DIR/build"
TARGET_DIR="${ROOTFS_STAGING:-/tmp/rootfs-staging}"
OUTPUT_DIR="$MCULINUX_DIR/output/compression"

if [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: rootfs staging not found at $TARGET_DIR"
    echo "Run: make rootfs first"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=== Filesystem Compression Comparison ==="
echo "Source: $TARGET_DIR"
echo ""

# Check available tools
HAS_SQUASHFS=0
HAS_EROFS=0

command -v mksquashfs >/dev/null 2>&1 && HAS_SQUASHFS=1
command -v mkfs.erofs >/dev/null 2>&1 && HAS_EROFS=1

# Install tools if missing (no sudo here — install them yourself)
if [ $HAS_SQUASHFS -eq 0 ] || [ $HAS_EROFS -eq 0 ]; then
    echo "WARN: missing tools (need squashfs-tools and/or erofs-utils), skipping those variants"
fi

echo "Tools: squashfs=$HAS_SQUASHFS erofs=$HAS_EROFS"
echo ""

# Source size
echo "Source rootfs: $(du -sh "$TARGET_DIR" | awk '{print $1}')"
echo ""

# Build each variant and report
echo "--- Results ---"
printf "%-25s %8s %s\n" "Format" "Size" "Ratio"
printf "%-25s %8s %s\n" "------" "----" "-----"

SOURCE_SIZE=$(du -sb "$TARGET_DIR" | awk '{print $1}')

if [ $HAS_SQUASHFS -eq 1 ]; then
    # SquashFS + gzip
    SQZ_OUT="$OUTPUT_DIR/rootfs_squashfs_gzip.bin"
    mksquashfs "$TARGET_DIR" "$SQZ_OUT" -comp gzip -b 16384 -no-xattrs -quiet 2>/dev/null
    SQZ_SIZE=$(stat -c%s "$SQZ_OUT")
    SQZ_RATIO=$(echo "scale=2; $SOURCE_SIZE / $SQZ_SIZE" | bc 2>/dev/null || echo "?")
    printf "%-25s %8s %sx\n" "squashfs+gzip" "$(ls -lh "$SQZ_OUT" | awk '{print $5}')" "$SQZ_RATIO"

    # SquashFS + zstd (if available)
    if mksquashfs 2>&1 | grep -q zstd; then
        SZT_OUT="$OUTPUT_DIR/rootfs_squashfs_zstd.bin"
        mksquashfs "$TARGET_DIR" "$SZT_OUT" -comp zstd -b 16384 -no-xattrs -quiet 2>/dev/null
        SZT_SIZE=$(stat -c%s "$SZT_OUT")
        SZT_RATIO=$(echo "scale=2; $SOURCE_SIZE / $SZT_SIZE" | bc 2>/dev/null || echo "?")
        printf "%-25s %8s %sx\n" "squashfs+zstd" "$(ls -lh "$SZT_OUT" | awk '{print $5}')" "$SZT_RATIO"
    fi

    # SquashFS + xz (if available)
    if mksquashfs 2>&1 | grep -q xz; then
        SXZ_OUT="$OUTPUT_DIR/rootfs_squashfs_xz.bin"
        mksquashfs "$TARGET_DIR" "$SXZ_OUT" -comp xz -b 16384 -no-xattrs -quiet 2>/dev/null
        SXZ_SIZE=$(stat -c%s "$SXZ_OUT")
        SXZ_RATIO=$(echo "scale=2; $SOURCE_SIZE / $SXZ_SIZE" | bc 2>/dev/null || echo "?")
        printf "%-25s %8s %sx\n" "squashfs+xz" "$(ls -lh "$SXZ_OUT" | awk '{print $5}')" "$SXZ_RATIO"
    fi
fi

if [ $HAS_EROFS -eq 1 ]; then
    EROFS_OUT="$OUTPUT_DIR/rootfs_erofs.bin"
    mkfs.erofs -zlzma,level=109 -C 16384 \
      -E fragments,dedupe,ztailpacking,force-inode-compact \
      -x -1 -T 0 \
      "$EROFS_OUT" "$TARGET_DIR" 2>/dev/null
    EROFS_SIZE=$(stat -c%s "$EROFS_OUT")
    EROFS_RATIO=$(echo "scale=2; $SOURCE_SIZE / $EROFS_SIZE" | bc 2>/dev/null || echo "?")
    printf "%-25s %8s %sx\n" "erofs+lzma(opt)" "$(ls -lh "$EROFS_OUT" | awk '{print $5}')" "$EROFS_RATIO"
fi

echo ""
echo "All images saved to: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
