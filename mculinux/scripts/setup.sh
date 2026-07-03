#!/bin/bash
# One-time setup: dynconfig, musl toolchain, Buildroot, esp-hosted
# Only needs to run once on a fresh machine
# Usage: ./scripts/setup.sh

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

# Step 2: musl cross-toolchain
echo ""
echo "--- Step 2/4: musl cross-toolchain ---"
TOOLCHAIN_PREFIX="crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic"
TOOLCHAIN_GCC="$TOOLCHAIN_PREFIX/bin/xtensa-esp32s3-linux-muslfdpic-gcc"

if [ ! -x "$TOOLCHAIN_GCC" ]; then
    echo "Building musl cross-toolchain (~45 min)..."
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
    echo "Toolchain: already built"
fi
echo "  $($TOOLCHAIN_GCC --version 2>/dev/null | head -1)"

# Step 3: Buildroot clone
echo ""
echo "--- Step 3/4: Buildroot ---"
if [ ! -d buildroot ]; then
    echo "Cloning Buildroot (xtensa-2025.08-fdpic, kernel 6.16)..."
    git clone https://github.com/jcmvbkbc/buildroot -b xtensa-2025.08-fdpic
    echo "Buildroot: OK"
else
    echo "Buildroot: already cloned"
fi

# Step 4: esp-hosted clone
echo ""
echo "--- Step 4/4: esp-hosted ---"
if [ ! -d esp-hosted ]; then
    echo "Cloning esp-hosted (ipc-5.1.1)..."
    git clone https://github.com/jcmvbkbc/esp-hosted -b ipc-5.1.1
    echo "esp-hosted: OK"
else
    echo "esp-hosted: already cloned"
fi

# Configure Buildroot (if not done)
echo ""
echo "--- Configuring Buildroot ---"
BUILDROOT_OUT="build-buildroot-esp32s3_devkit_c1_8m"
if [ ! -d "$BUILDROOT_OUT" ]; then
    echo "Configuring Buildroot..."
    nice make -C buildroot O="$(pwd)/$BUILDROOT_OUT" esp32s3_devkit_c1_8m_defconfig

    buildroot/utils/config --file "$BUILDROOT_OUT/.config" --set-str TOOLCHAIN_EXTERNAL_PATH "$(pwd)/$TOOLCHAIN_PREFIX"
    buildroot/utils/config --file "$BUILDROOT_OUT/.config" --set-str TOOLCHAIN_EXTERNAL_PREFIX '$(ARCH)-esp32s3-linux-muslfdpic'
    buildroot/utils/config --file "$BUILDROOT_OUT/.config" --set-str TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX '$(ARCH)-esp32s3-linux-muslfdpic'
    buildroot/utils/config --file "$BUILDROOT_OUT/.config" --set-str BR2_TOOLCHAIN_HEADERS_AT_LEAST "6.16"

    buildroot/utils/config --file "$BUILDROOT_OUT/.config" --enable BR2_PACKAGE_NCURSES
    buildroot/utils/config --file "$BUILDROOT_OUT/.config" --enable BR2_PACKAGE_NCURSES_WIDE
    buildroot/utils/config --file "$BUILDROOT_OUT/.config" --enable BR2_PACKAGE_HTOP
    buildroot/utils/config --file "$BUILDROOT_OUT/.config" --enable BR2_PACKAGE_NANO
    buildroot/utils/config --file "$BUILDROOT_OUT/.config" --enable BR2_OPTIM_S

    echo "Buildroot config: OK"
else
    echo "Buildroot config: already configured"
fi

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  make bootloader    # build WiFi firmware (~5 min)"
echo "  make kernel        # build kernel + rootfs (~15 min)"
echo "  make image         # assemble flash image"
echo "  make test          # boot in QEMU"
echo ""
echo "Or run everything:"
echo "  make build DEVICE=r8n8"
