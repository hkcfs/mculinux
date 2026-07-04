#!/bin/bash
# MCUlinux Kernel Builder (v3)
# Builds ESP32-S3 kernel from jcmvbkbc/linux-xtensa fork
# Usage: ./build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCULINUX_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK_DIR="$SCRIPT_DIR/work"
OUTPUT_DIR="$SCRIPT_DIR/output"
BRANCH="xtensa-6.16-esp32"
FORK_URL="https://github.com/jcmvbkbc/linux-xtensa.git"

# Required tools
XTENSA_GNU_CONFIG="$MCULINUX_DIR/build/xtensa-dynconfig/esp32s3.so"
CROSS_COMPILE="$MCULINUX_DIR/build/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-"
export PATH="$(dirname "$CROSS_COMPILE"):$PATH"
export XTENSA_GNU_CONFIG

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

timestamp() { date '+%H:%M:%S'; }
log() { echo "[$(timestamp)] $*"; }

echo "=========================================="
log "MCUlinux Kernel Builder v3"
echo "=========================================="

# ──────────────────────────────────────────────
# Step 1: Clone or update fork
# ──────────────────────────────────────────────
FORK_DIR="$WORK_DIR/linux-xtensa"

if [ -d "$FORK_DIR" ]; then
    log "Fork exists, fetching..."
    cd "$FORK_DIR"
    git fetch origin --depth=100 "$BRANCH" 2>&1 | tail -3
    git checkout FETCH_HEAD 2>&1 | tail -2
else
    log "Cloning jcmvbkbc/linux-xtensa..."
    git clone --depth=100 --branch "$BRANCH" "$FORK_URL" "$FORK_DIR"
    cd "$FORK_DIR"
fi

log "Kernel: $(head -1 Makefile) $(head -2 Makefile | tail -1) $(head -3 Makefile | tail -1)"
log "Commit: $(git log --oneline -1)"

# ──────────────────────────────────────────────
# Step 2: Fix known issues
# ──────────────────────────────────────────────
log "Applying fixes..."

# Fix 1: Patch out atomctl register (not recognized by binutils)
if grep -q 'wsr.*a3, atomctl' arch/xtensa/include/asm/initialize_mmu.h 2>/dev/null; then
    sed -i 's/^\twsr\ta3, atomctl/\t\/\* wsr a3, atomctl - skipped, not needed for NOMMU \*\//' \
        arch/xtensa/include/asm/initialize_mmu.h
    log "  Patched atomctl"
fi

# Fix 2: Force little-endian (ESP32-S3 is LE, but toolchain header says BE)
if grep -q 'def_bool \$(success,test.*__XTENSA_EB__' arch/xtensa/Kconfig; then
    sed -i 's/def_bool \$(success,test "$(shell,echo __XTENSA_EB__ | $(CC) -E -P -)" = 1)/def_bool n/' \
        arch/xtensa/Kconfig
    log "  Fixed endianness detection"
fi

# ──────────────────────────────────────────────
# Step 3: Configure kernel
# ──────────────────────────────────────────────
log "Configuring kernel..."
make ARCH=xtensa CROSS_COMPILE="${CROSS_COMPILE}" mrproper 2>/dev/null
make ARCH=xtensa CROSS_COMPILE="${CROSS_COMPILE}" esp32s3_devkit_c1_defconfig

# Apply our trimmed config
if [ -f "$SCRIPT_DIR/configs/esp32s3_trimmed.config" ]; then
    log "  Applying trimmed config..."
    while IFS='=' read -r key value; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [ -z "$key" ] && continue
        [[ "$key" =~ ^# ]] && continue
        scripts/config --set-val "$key" "$value" 2>/dev/null || \
        scripts/config --enable "$key" 2>/dev/null || true
    done < "$SCRIPT_DIR/configs/esp32s3_trimmed.config"
fi

make ARCH=xtensa CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

log "Config: $(grep "^CONFIG_.*=y" .config | wc -l) options enabled"

# ──────────────────────────────────────────────
# Step 4: Build kernel
# ──────────────────────────────────────────────
log "Building kernel..."
make ARCH=xtensa CROSS_COMPILE="${CROSS_COMPILE}" -j$(nproc) 2>&1 | tee "$OUTPUT_DIR/build.log" | tail -5

# Build DTBs
make ARCH=xtensa CROSS_COMPILE="${CROSS_COMPILE}" dtbs -j$(nproc) 2>&1 | tail -3

# ──────────────────────────────────────────────
# Step 5: Package outputs
# ──────────────────────────────────────────────
VERSION=$(git describe --tags --always 2>/dev/null || echo "unknown")
log "Packaging outputs for $VERSION..."

mkdir -p "$OUTPUT_DIR/$VERSION"

# Copy xipImage
cp arch/xtensa/boot/xipImage "$OUTPUT_DIR/$VERSION/"
log "  xipImage: $(ls -lh "$OUTPUT_DIR/$VERSION/xipImage" | awk '{print $5}')"

# Copy DTBs
for dtb in arch/xtensa/boot/dts/esp32s3*.dtb; do
    [ -f "$dtb" ] && cp "$dtb" "$OUTPUT_DIR/$VERSION/"
done

# Copy config
cp .config "$OUTPUT_DIR/$VERSION/"

log ""
log "=========================================="
log "Build complete!"
log "  Kernel: $VERSION"
log "  xipImage: $(ls -lh "$OUTPUT_DIR/$VERSION/xipImage" | awk '{print $5}')"
log "  Output: $OUTPUT_DIR/$VERSION/"
log "=========================================="
