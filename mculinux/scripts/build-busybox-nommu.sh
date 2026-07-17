#!/bin/bash
# Build busybox 1.38.0 for NOMMU Xtensa
# Usage: ./scripts/build-busybox-nommu.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUSYBOX_VERSION="1.38.0"
BUSYBOX_DIR="/tmp/busybox-${BUSYBOX_VERSION}"
PATCHES_DIR="$SCRIPT_DIR/patches/busybox-nommu"
BUILDROOT_OUT="$SCRIPT_DIR/build/build-buildroot-esp32s3_devkit_c1_8m"
TARGET="$BUILDROOT_OUT/target"
CROSS="$SCRIPT_DIR/build/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-"
XTPROJECT="$SCRIPT_DIR/tools/project/xtensa/esp32s3"
XTDYNAMIC="$SCRIPT_DIR/build/xtensa-dynconfig/esp32s3.so"
INIT_SRC="$PATCHES_DIR/init_final.c"

echo "=== Building busybox $BUSYBOX_VERSION for NOMMU ==="

# Download if needed
if [ ! -d "$BUSYBOX_DIR" ]; then
    echo "Downloading busybox $BUSYBOX_VERSION..."
    cd /tmp
    wget -q "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" -O "busybox-${BUSYBOX_VERSION}.tar.bz2"
    tar xjf "busybox-${BUSYBOX_VERSION}.tar.bz2"
fi

# Configure
cd "$BUSYBOX_DIR"
cp "$PATCHES_DIR/defconfig" .config

# Apply NOMMU hush patch
bash "$PATCHES_DIR/apply-nommu-patch.sh"

# Build
echo "Building busybox..."
make ARCH=xtensa CROSS_COMPILE="$CROSS" XTPROJECT="$XTPROJECT" XTDYNAMIC_CONFIG="$XTDYNAMIC" \
    tc=no brctl=no -j$(nproc) 2>&1 | tail -5

# Strip
"${CROSS}strip" busybox
echo "Busybox size: $(ls -lh busybox | awk '{print $5}')"

# Deploy to rootfs
cp busybox "$TARGET/bin/busybox"
chmod +x "$TARGET/bin/busybox"

# Create symlinks
cd "$TARGET"
for applet in $(bin/busybox --list 2>/dev/null); do
    dir="usr/bin"
    case "$applet" in
        init|mount|reboot|poweroff|halt|ifconfig|route|modprobe|insmod|rmmod|lsmod|depmod|switch_root|pivot_root) dir="sbin" ;;
        sh|hush) dir="bin" ;;
    esac
    mkdir -p "$dir" 2>/dev/null
    ln -sf busybox "$dir/$applet" 2>/dev/null || true
done
ln -sf busybox bin/sh
ln -sf busybox bin/hush
ln -sf busybox sbin/init

echo ""
echo "=== Building init binary ==="
"${CROSS}gcc" -static -o "$TARGET/sbin/init" "$INIT_SRC"
chmod +x "$TARGET/sbin/init"
echo "Init binary: $(ls -lh "$TARGET/sbin/init" | awk '{print $5}')"

echo ""
echo "=== Creating rootfs ==="
cd "$TARGET"
mkfs.erofs -z lzma,level=9 "$SCRIPT_DIR/tools/prebuilt/binaries/rootfs.erofs" .
echo "Rootfs: $(ls -lh "$SCRIPT_DIR/tools/prebuilt/binaries/rootfs.erofs" | awk '{print $5}')"

echo ""
echo "=== Done ==="
