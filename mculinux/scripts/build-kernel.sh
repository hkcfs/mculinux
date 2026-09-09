#!/bin/bash
# Build kernel xipImage from upstream tinyconfig + ESP32 fragment. No Buildroot.
# Always builds the latest stable kernel unless KERNEL_VERSION pins one.
# Usage: [KERNEL_VERSION=latest|7.2.4] [KSRC=/path] ./scripts/build-kernel.sh
set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$MCULINUX_DIR/build"
PATCHES_DIR="$MCULINUX_DIR/patches/linux-esp32"

KVER_REQ="${KERNEL_VERSION:-latest}"
if [ "$KVER_REQ" = "latest" ]; then
    KVER_REQ="$("$MCULINUX_DIR/scripts/latest-stable.sh")"
fi
[ -n "$KVER_REQ" ] || { echo "FAIL: could not resolve kernel version"; exit 1; }
KV_SHORT="$(echo "$KVER_REQ" | cut -d. -f1,2)"

KSRC="${KSRC:-$BUILD_DIR/kernel-src/linux-$KVER_REQ}"
CROSS="${XTENSA_CROSS:-$BUILD_DIR/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-}"

echo "=== Building Linux $KVER_REQ (tinyconfig + ESP32 fragment) ==="

# Toolchain must be visible BEFORE any *config step: Kconfig probes the
# compiler, and the wrong/missing compiler flips CONFIG_KERNEL_ABI_* and
# breaks the build (WindowVectors link errors).
command -v "${CROSS}gcc" >/dev/null 2>&1 || {
    echo "FAIL: cross gcc not found: ${CROSS}gcc"
    echo "  Run: make setup  (or export XTENSA_CROSS=<prefix>)"
    exit 1
}
export PATH="$(dirname "${CROSS}gcc"):$PATH"
export ARCH=xtensa
export CROSS_COMPILE="$(basename "$CROSS")"
echo "Toolchain: $("${CROSS}gcc" --version | head -1)"

# Acquire pristine source: builder prefetch > download (cdn, edge fallback).
if [ ! -d "$KSRC" ]; then
    echo "Acquiring linux-$KVER_REQ source..."
    mkdir -p "$(dirname "$KSRC")"
    if [ -f "/opt/src/linux-$KVER_REQ.tar.xz" ]; then
        tar -xf "/opt/src/linux-$KVER_REQ.tar.xz" -C "$(dirname "$KSRC")"
    else
        (wget -q --tries=3 --timeout=120 \
            "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KVER_REQ.tar.xz" \
            -O "/tmp/linux-$KVER_REQ.tar.xz" || \
         wget -q --tries=5 --timeout=120 \
            "https://mirrors.edge.kernel.org/pub/linux/kernel/v7.x/linux-$KVER_REQ.tar.xz" \
            -O "/tmp/linux-$KVER_REQ.tar.xz") \
            || { echo "FAIL: kernel tarball download failed"; exit 1; }
        tar -xf "/tmp/linux-$KVER_REQ.tar.xz" -C "$(dirname "$KSRC")"
        rm -f "/tmp/linux-$KVER_REQ.tar.xz"
    fi
fi
[ -f "$KSRC/Makefile" ] || { echo "FAIL: no kernel source at $KSRC"; exit 1; }

cd "$KSRC"

# Apply ESP32 patches STRICT: any failure is fatal. Idempotency is decided
# by SENTINELS (a trace each patch must leave), never by `patch` exit codes:
# GNU patch's skip/already-applied exit status differs between versions
# (e.g. ubuntu:latest vs debian), and trusting it silently skipped every
# patch in CI once — no ESP32 symbols, red build, confusing log.
echo "Applying ESP32 patches..."
sentinel_ok() { # $1 = patch basename (000N-...)
    case "$1" in
        0001*) grep -qF "esp,esp32-clk-gpio" "$KSRC/drivers/gpio/gpio-mmio.c" 2>/dev/null ;;
        0002*) [ -f "$KSRC/drivers/irqchip/irq-esp32-intc.c" ] ;;
        0003*) [ -f "$KSRC/drivers/misc/esp32-ipc.c" ] ;;
        0004*) [ -f "$KSRC/drivers/mtd/chips/map_esp32.c" ] ;;
        0005*) [ -f "$KSRC/drivers/tty/serial/esp32_uart.c" ] ;;
        0006*) [ -f "$KSRC/arch/xtensa/platforms/esp32/include/platform/serial.h" ] ;;
        0007*) [ -f "$KSRC/arch/xtensa/boot/dts/esp32s3.dtsi" ] ;;
        0008*) [ -f "$KSRC/drivers/gpio/gpio-esp32s3.c" ] ;;
        0009*) [ -f "$KSRC/drivers/net/ethernet/esp32-wifi-shmem.c" ] ;;
        *) return 1 ;;
    esac
}
for patch in "$PATCHES_DIR"/0*.patch; do
    base="$(basename "$patch")"
    if sentinel_ok "$base"; then
        echo "  $base (already applied, skipping)"
    else
        echo "  $base"
        patch -p1 --batch < "$patch" || exit 1
        sentinel_ok "$base" || { echo "FAIL: $base applied but left no trace"; exit 1; }
    fi
done
echo "All ESP32 patches applied."

# Dirty-tree guard: sentinels prove a patch was applied, but not WHICH
# version. If the patch set changed since this tree was prepared, a stale
# application would linger silently — fail loud instead. (CI always uses a
# pristine tree, so this only ever fires on reused dev trees.)
STAMP="$KSRC/.patches.stamp"
CUR_STAMP="$(sha256sum "$PATCHES_DIR"/0*.patch | sed "s|$PATCHES_DIR/||")"
if [ -f "$STAMP" ]; then
    if [ "$(cat "$STAMP")" != "$CUR_STAMP" ]; then
        echo "FAIL: patch set changed since $KSRC was prepared."
        echo "  Remove the tree for a clean rebuild: rm -rf $KSRC"
        exit 1
    fi
else
    echo "$CUR_STAMP" > "$STAMP"
fi

# (Patch traces were verified inside the apply loop above.)

# Base = upstream tinyconfig (fresh every time, no stale baggage),
# then our fragment wins, then olddefconfig resolves dependencies.
echo "Configuring (tinyconfig + fragment)..."
make ARCH=xtensa tinyconfig
scripts/kconfig/merge_config.sh -m .config "$PATCHES_DIR/fragment.config"
make ARCH=xtensa olddefconfig

# Guard against silent misconfiguration (e.g. a malformed fragment line that
# merge_config.sh ignores): these symbols are load-bearing for boot.
# Values are dumped first so a failure names every offender, not just the
# first one in the list.
echo "Verifying load-bearing symbols..."
for sym in CONFIG_XTENSA CONFIG_PRINTK CONFIG_PARSE_BOOTPARAM CONFIG_BLOCK \
           CONFIG_MTD_BLOCK CONFIG_EROFS_FS CONFIG_JFFS2_FS CONFIG_SERIAL_ESP32 \
           CONFIG_TTY CONFIG_XTENSA_PLATFORM_ESP32 CONFIG_GPIO_ESP32S3 \
           CONFIG_GPIO_CDEV CONFIG_I2C CONFIG_I2C_CHARDEV CONFIG_I2C_GPIO \
           CONFIG_NET CONFIG_INET CONFIG_IPV6 CONFIG_PACKET CONFIG_NETDEVICES \
           CONFIG_ESP32_WIFI_SHMEM; do
    val="$(grep -E "^$sym=|^# $sym is not set$" .config || echo MISSING)"
    echo "  $sym: $val"
done
for sym in CONFIG_XTENSA CONFIG_PRINTK CONFIG_PARSE_BOOTPARAM CONFIG_BLOCK \
           CONFIG_MTD_BLOCK CONFIG_EROFS_FS CONFIG_JFFS2_FS CONFIG_SERIAL_ESP32 \
           CONFIG_TTY CONFIG_XTENSA_PLATFORM_ESP32 CONFIG_GPIO_ESP32S3 \
           CONFIG_GPIO_CDEV CONFIG_I2C CONFIG_I2C_CHARDEV CONFIG_I2C_GPIO \
           CONFIG_NET CONFIG_INET CONFIG_IPV6 CONFIG_PACKET CONFIG_NETDEVICES \
           CONFIG_ESP32_WIFI_SHMEM; do
    grep -q "^$sym=y$" .config || { echo "FAIL: $sym is not =y after merge"; exit 1; }
done
grep -q '^# CONFIG_LD_DEAD_CODE_DATA_ELIMINATION is not set$' .config \
    || { echo "FAIL: DCE (sched_clock hang) is not disabled after merge"; exit 1; }
echo "Config verified."

echo "Building xipImage..."
make -j"$(nproc)" KCFLAGS="-Oz -fmerge-all-constants" xipImage
ls -lh arch/xtensa/boot/xipImage

echo "$KVER_REQ" > "$BUILD_DIR/.kernel-version"
cp arch/xtensa/boot/xipImage \
    "$MCULINUX_DIR/tools/prebuilt/binaries/xipImage-$KV_SHORT"
echo ""
echo "=== Done: Linux $KVER_REQ -> tools/prebuilt/binaries/xipImage-$KV_SHORT ==="
