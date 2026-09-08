#!/bin/bash
# One-time setup: dynconfig, musl toolchain (release tarball), esp-hosted.
# No Buildroot: the kernel builds from tinyconfig+fragment and the rootfs
# assembles from mculinux/rootfs/ + busybox, all without it.
# Usage: ./scripts/setup.sh
#   TOOLCHAIN_SRC=1 ./scripts/setup.sh  # 45-min from-source toolchain build

set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$MCULINUX_DIR/build"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=========================================="
echo "MCUlinux One-Time Setup"
echo "=========================================="

# Step 1: dynconfig
echo ""
echo "--- Step 1/4: dynconfig ---"
if [ ! -f xtensa-dynconfig/esp32s3.so ]; then
    echo "Building dynconfig..."
    git clone https://github.com/jcmvbkbc/xtensa-dynconfig -b original 2>/dev/null || true
    git clone https://github.com/jcmvbkbc/config-esp32s3 esp32s3 2>/dev/null || true
    make -C xtensa-dynconfig ORIG=1 CONF_DIR="$(pwd)" esp32s3.so
    echo "dynconfig: OK"
else
    echo "dynconfig: already built"
fi
export XTENSA_GNU_CONFIG="$(pwd)/xtensa-dynconfig/esp32s3.so"

# Step 2: musl cross-toolchain (release tarball; minutes, not 45)
echo ""
echo "--- Step 2/3: musl cross-toolchain ---"
TOOLCHAIN_PREFIX="crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic"
TOOLCHAIN_GCC="$TOOLCHAIN_PREFIX/bin/xtensa-esp32s3-linux-muslfdpic-gcc"
TOOLCHAIN_URL="${TOOLCHAIN_URL:-https://github.com/hkcfs/mculinux/releases/download/toolchain/xtensa-esp32s3-linux-muslfdpic.tar.xz}"

if [ ! -x "$TOOLCHAIN_GCC" ]; then
    if [ -n "${TOOLCHAIN_SRC:-}" ]; then
        echo "Building musl cross-toolchain from source (~45 min)..."
        git clone https://github.com/jcmvbkbc/crosstool-NG.git -b xtensa-fdpic 2>/dev/null || true
        pushd crosstool-NG
        mkdir -p samples/xtensa-esp32s3-linux-muslfdpic
        cat > samples/xtensa-esp32s3-linux-muslfdpic/crosstool.config << 'CTEOF'
CT_CONFIG_VERSION="4"
CT_EXPERIMENTAL=y
# CT_PREFIX_DIR_RO is not set
CT_ARCH_XTENSA=y
# CT_DEMULTILIB is not set
# CT_ARCH_USE_MMU is not set
CT_TARGET_CFLAGS="-mauto-litpools -Os"
CT_TARGET_VENDOR="esp32s3"
CT_KERNEL_LINUX=y
CT_LINUX_SRC_DEVEL=y
CT_LINUX_DEVEL_URL="https://github.com/jcmvbkbc/linux-xtensa.git"
CT_LINUX_DEVEL_BRANCH="xtensa-6.16-esp32"
CT_ARCH_BINFMT_FDPIC=y
CT_BINUTILS_SRC_DEVEL=y
CT_BINUTILS_DEVEL_URL="https://github.com/jcmvbkbc/binutils-gdb-xtensa.git"
CT_BINUTILS_DEVEL_BRANCH="xtensa-2.42-fdpic-musl"
CT_BINUTILS_PLUGINS=y
# CT_BINUTILS_RELRO is not set
CT_MUSL_SRC_DEVEL=y
CT_MUSL_DEVEL_URL="https://github.com/jcmvbkbc/musl-xtensa.git"
CT_MUSL_DEVEL_BRANCH="xtensa-1.2.5-fdpic"
CT_GCC_SRC_DEVEL=y
CT_GCC_DEVEL_URL="https://github.com/jcmvbkbc/gcc-xtensa.git"
CT_GCC_DEVEL_BRANCH="xtensa-14-9655-fdpic-musl"
# CT_CC_GCC_SJLJ_EXCEPTIONS is not set
CTEOF
        ./bootstrap && ./configure --enable-local && make
        ./ct-ng xtensa-esp32s3-linux-muslfdpic
        CT_PREFIX="$(pwd)/builds" nice ./ct-ng build
        popd
        echo "Toolchain: OK"
    else
        echo "Downloading prebuilt toolchain..."
        rm -rf /tmp/mctoolchain
        mkdir -p /tmp/mctoolchain crosstool-NG/builds
        wget -q "$TOOLCHAIN_URL" -O /tmp/mctoolchain/toolchain.tar.xz \
            || { echo "FAIL: toolchain download failed"; exit 1; }
        tar -xf /tmp/mctoolchain/toolchain.tar.xz -C /tmp/mctoolchain
        # Find the toolchain root (dir containing bin/<triplet>-gcc), whatever
        # the tarball's top-level layout is, and place it at TOOLCHAIN_PREFIX.
        TC_GCC="$(find /tmp/mctoolchain -name xtensa-esp32s3-linux-muslfdpic-gcc -type f | head -1)"
        [ -n "$TC_GCC" ] || { echo "FAIL: gcc not found in toolchain tarball"; exit 1; }
        TC_ROOT="$(dirname "$(dirname "$TC_GCC")")"
        rm -rf "crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic"
        mv "$TC_ROOT" "crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic"
        rm -rf /tmp/mctoolchain
        echo "Toolchain: OK"
    fi
else
    echo "Toolchain: already installed"
fi
echo "  $($TOOLCHAIN_GCC --version 2>/dev/null | head -1)"

# Step 3: esp-hosted clone (master tracks latest IDF; override with
# ESP_HOSTED_BRANCH=ipc-5.1.1 to pair with a pinned espressif/idf:v5.1).
# Only needed for manual `make bootloader` rebuilds.
echo ""
echo "--- Step 3/3: esp-hosted ---"
ESP_HOSTED_BRANCH="${ESP_HOSTED_BRANCH:-master}"
if [ ! -d esp-hosted ]; then
    echo "Cloning esp-hosted ($ESP_HOSTED_BRANCH)..."
    git clone https://github.com/jcmvbkbc/esp-hosted -b "$ESP_HOSTED_BRANCH"
    echo "esp-hosted: OK"
else
    echo "esp-hosted: already cloned"
fi

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  make kernel      # build kernel xipImage, latest stable (~2 min)"
echo "  make busybox     # build busybox + assemble rootfs (~2 min)"
echo "  make etc         # build etc.jffs2 (needs mkfs.jffs2)"
echo "  make image       # assemble flash image"
echo "  make test        # boot in QEMU"
echo ""
echo "Or run everything:"
echo "  make kernel && make busybox && make image DEVICE=r8n8"
