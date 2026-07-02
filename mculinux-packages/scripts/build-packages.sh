#!/bin/bash
# Build packages for MCUlinux ESP32-S3

set -e

PACKAGES_DIR="${PACKAGES_DIR:-/packages}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ARCH="xtensa"
TARGET="esp32s3"

# Set up cross-compilation environment
export CROSS_COMPILE="xtensa-esp32s3-elf-"
export CC="${CROSS_COMPILE}gcc"
export CXX="${CROSS_COMPILE}g++"
export AR="${CROSS_COMPILE}ar"
export RANLIB="${CROSS_COMPILE}ranlib"
export STRIP="${CROSS_COMPILE}strip"

# Build specific package or all
BUILD_PACKAGE="${1:-all}"

build_package() {
    local pkg="$1"
    local pkgdir="$PACKAGES_DIR/packages/$pkg"

    if [ ! -d "$pkgdir" ]; then
        echo "Package not found: $pkg"
        return 1
    fi

    echo "Building package: $pkg"
    cd "$pkgdir"

    # Source APKBUILD
    source ./APKBUILD

    # Download source
    echo "Downloading source..."
    wget -q "$source" -O "$srcdir/$(basename $source)" || true

    # Build
    echo "Compiling..."
    build

    # Package
    echo "Packaging..."
    package

    echo "Package $pkg built successfully"
}

build_all() {
    local packages=(
        "busybox"
        "htop"
        "btop"
        "nano"
        "coreutils"
        "bash"
    )

    for pkg in "${packages[@]}"; do
        build_package "$pkg"
    done
}

# Main
case "$BUILD_PACKAGE" in
    all)
        build_all
        ;;
    *)
        build_package "$BUILD_PACKAGE"
        ;;
esac

echo "Build complete!"
