#!/bin/bash
# Build busybox (always latest stable, resolved via git) for NOMMU Xtensa
# Usage: ./scripts/build-busybox-nommu.sh
#   BUSYBOX_VERSION=1.38.0 ./scripts/build-busybox-nommu.sh  # pin if needed

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-$("$SCRIPT_DIR/scripts/latest-busybox.sh")}"
BUSYBOX_TAG="$(echo "$BUSYBOX_VERSION" | tr '.' '_')"
BUSYBOX_DIR="/tmp/busybox-${BUSYBOX_VERSION}"
PATCHES_DIR="$SCRIPT_DIR/patches/busybox-nommu"
CROSS="${XTENSA_CROSS:-$SCRIPT_DIR/build/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-}"
INIT_SRC="$PATCHES_DIR/init_final.c"

echo "=== Building busybox $BUSYBOX_VERSION for NOMMU ==="

# Acquire source: builder pre-extract > prefetched tarball > git clone tag
# (busybox.net is unreliable; git is the primary remote source) > tarball
# download. Fail loudly if nothing works — never silently build stale code.
fetch_busybox() {
    local ver="$1" tag="$2" dest="$3"
    if [ -d "/opt/src/busybox-${ver}" ]; then
        echo "Using builder pre-extracted source /opt/src/busybox-${ver}"
        rm -rf "$dest"
        cp -r "/opt/src/busybox-${ver}" "$dest"
        return 0
    fi
    if [ -f "/opt/src/busybox-${ver}.tar.bz2" ]; then
        echo "Extracting prefetched tarball..."
        rm -rf "$dest"
        tar -xjf "/opt/src/busybox-${ver}.tar.bz2" -C /tmp
        return 0
    fi
    for remote in "git://git.busybox.net/busybox" \
                  "https://git.busybox.net/busybox" \
                  "https://github.com/mirror/busybox"; do
        echo "Cloning tag $tag from $remote ..."
        if timeout 120 git clone --depth 1 --branch "$tag" "$remote" "$dest" 2>/dev/null; then
            return 0
        fi
        rm -rf "$dest"
    done
    echo "Downloading tarball as last resort..."
    if wget -q "https://busybox.net/downloads/busybox-${ver}.tar.bz2" \
        -O "/tmp/busybox-${ver}.tar.bz2"; then
        rm -rf "$dest"
        tar -xjf "/tmp/busybox-${ver}.tar.bz2" -C /tmp
        return 0
    fi
    return 1
}

# Download if needed
if [ ! -d "$BUSYBOX_DIR" ]; then
    echo "Acquiring busybox $BUSYBOX_VERSION source..."
    fetch_busybox "$BUSYBOX_VERSION" "$BUSYBOX_TAG" "$BUSYBOX_DIR" \
        || { echo "FAIL: could not acquire busybox $BUSYBOX_VERSION source"; exit 1; }
fi

# Configure (olddefconfig absorbs new symbols when tracking latest)
cd "$BUSYBOX_DIR"
cp "$PATCHES_DIR/defconfig" .config

# Apply NOMMU hush patch — FAIL LOUD if upstream moved the anchor, so CI
# goes red instead of silently building a MMU-assuming hush. Idempotent:
# an already-patched tree is detected and skipped.
if grep -q '^#define BUILD_AS_NOMMU 1$' shell/hush.c; then
    echo "NOMMU hush patch already applied, skipping."
elif grep -q '^#define BUILD_AS_NOMMU 0$' shell/hush.c; then
    bash "$PATCHES_DIR/apply-nommu-patch.sh"
    grep -q '^#define BUILD_AS_NOMMU 1$' shell/hush.c \
        || { echo "FAIL: NOMMU patch did not apply"; exit 1; }
    echo "NOMMU hush patch applied."
else
    echo "FAIL: shell/hush.c NOMMU anchor not found — upstream changed it."
    echo "Update patches/busybox-nommu/apply-nommu-patch.sh for busybox $BUSYBOX_VERSION."
    exit 1
fi

# Absorb new Kconfig symbols when tracking latest busybox (busybox kconfig
# has no olddefconfig; oldconfig + empty answers = accept upstream defaults)
yes "" | make ARCH=xtensa CROSS_COMPILE="$CROSS" oldconfig >/dev/null

# Build (XTDYNAMIC overlay only if present; the toolchain default core
# already builds a working FDPIC binary, with or without it)
echo "Building busybox..."
XTENSA_ARGS="tc=no brctl=no"
[ -f "$SCRIPT_DIR/build/xtensa-dynconfig/esp32s3.so" ] && \
    XTENSA_ARGS="$XTENSA_ARGS XTDYNAMIC_CONFIG=$SCRIPT_DIR/build/xtensa-dynconfig/esp32s3.so"
make ARCH=xtensa CROSS_COMPILE="$CROSS" $XTENSA_ARGS -j$(nproc) 2>&1 | tail -5

# Strip
"${CROSS}strip" busybox
echo "Busybox size: $(ls -lh busybox | awk '{print $5}')"

# Assemble rootfs (skeleton + symlinks + static init + EROFS)
export XTENSA_CROSS="$CROSS"
BUSYBOX_BIN="$BUSYBOX_DIR/busybox" "$SCRIPT_DIR/scripts/build-rootfs.sh"

echo ""
echo "=== Done ==="
