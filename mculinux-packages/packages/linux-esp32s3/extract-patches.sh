#!/bin/bash
# Extract ESP32-S3 patches from jcmvbkbc/linux-xtensa fork
# This script clones the fork and creates individual patches for each component

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
FORK_DIR="$SCRIPT_DIR/work/linux-xtensa"

FORK_URL="https://github.com/jcmvbkbc/linux-xtensa.git"
FORK_BRANCH="xtensa-6.16-esp32-tag"

mkdir -p "$PATCHES_DIR" "$SCRIPT_DIR/work"

timestamp() { date '+%H:%M:%S'; }
log() { echo "[$(timestamp)] $*"; }

echo "=========================================="
log "Extracting ESP32-S3 Patches"
echo "=========================================="

# ──────────────────────────────────────────────
# Step 1: Clone the fork (or pull updates)
# ──────────────────────────────────────────────
if [ -d "$FORK_DIR" ]; then
    log "Fork already cloned, pulling latest..."
    cd "$FORK_DIR"
    git fetch origin "$FORK_BRANCH"
    git checkout "$FORK_BRANCH"
    git pull origin "$FORK_BRANCH" || true
else
    log "Cloning jcmvbkbc/linux-xtensa fork..."
    git clone --branch "$FORK_BRANCH" "$FORK_URL" "$FORK_DIR"
    cd "$FORK_DIR"
fi

log "Fork at commit: $(git log --oneline -1)"

# ──────────────────────────────────────────────
# Step 2: Identify ESP32-S3 specific files
# ──────────────────────────────────────────────
log "Identifying ESP32-S3 files..."

# Files that are ESP32-S3 specific (not in mainline)
ESP32S3_FILES=(
    # Xtensa variant
    "arch/xtensa/variants/esp32s3/"
    "arch/xtensa/variants/esp32/"
    # Xtensa platform
    "arch/xtensa/platforms/esp32/"
    # Drivers
    "drivers/irqchip/irq-esp32-intc.c"
    "drivers/clk/clk-esp32s3.c"
    "drivers/clk/clk-esp32.c"
    "drivers/tty/serial/esp32_uart.c"
    "drivers/tty/serial/esp32_acm.c"
    "drivers/gpio/gpio-esp32.c"
    "drivers/spi/spi-esp32.c"
    "drivers/char/hw_random/esp32-trng.c"
    "drivers/misc/esp32-ipc.c"
    "drivers/misc/esp32-ipc.h"
    "drivers/mtd/chips/map_esp32.c"
    "drivers/phy/phy-esp32s3-usb.c"
    "drivers/net/wireless/espressif/"
    # DTS
    "arch/xtensa/boot/dts/esp32s3*"
    "arch/xtensa/boot/dts/gpio-esp32.h"
    # Kconfig additions
    "arch/xtensa/Kconfig"
    "drivers/irqchip/Kconfig"
    "drivers/clk/Kconfig"
    "drivers/tty/serial/Kconfig"
    "drivers/gpio/Kconfig"
    "drivers/spi/Kconfig"
    "drivers/char/hw_random/Kconfig"
    "drivers/misc/Kconfig"
    "drivers/mtd/chips/Kconfig"
    "drivers/phy/Kconfig"
    "drivers/net/wireless/Kconfig"
    # Include files
    "include/linux/esp32-ipc-api.h"
)

# ──────────────────────────────────────────────
# Step 3: Generate patches
# ──────────────────────────────────────────────
log "Generating patches..."

cd "$FORK_DIR"

# Find the base mainline commit (parent of first ESP32 commit)
# We'll generate patches against the fork's own history
PATCH_NUM=1

generate_patch() {
    local name="$1"
    local files=("${!2}")
    local patch_file="$PATCHES_DIR/$(printf '%03d' $PATCH_NUM)-${name}.patch"
    
    log "  Generating patch for $name..."
    
    # Create a diff of all files in this category
    {
        echo "# ESP32-S3 patch: $name"
        echo "# Generated from jcmvbkbc/linux-xtensa fork"
        echo "#"
        
        for f in "${files[@]}"; do
            # Use find to handle globs
            find . -path "./$f" -type f 2>/dev/null | while read -r filepath; do
                if [ -f "$filepath" ]; then
                    # Get the file content relative to root
                    echo "diff --git a/$filepath b/$filepath"
                    echo "new file mode 100644"
                    echo "--- /dev/null"
                    echo "+++ b/$filepath"
                    echo "@@ -0,0 +1,$(wc -l < "$filepath") @@"
                    sed 's/^/+/' "$filepath"
                fi
            done
        done
    } > "$patch_file"
    
    ((PATCH_NUM++))
}

# Generate patches for each component
generate_patch "xtensa-esp32s3-variant" ESP32S3_VARIANT_FILES
generate_patch "esp32-platform" ESP32S3_PLATFORM_FILES
generate_patch "irq-esp32-intc" ESP32S3_IRQ_FILES
generate_patch "clk-esp32s3" ESP32S3_CLK_FILES
generate_patch "serial-esp32-uart" ESP32S3_UART_FILES
generate_patch "gpio-esp32" ESP32S3_GPIO_FILES
generate_patch "spi-esp32" ESP32S3_SPI_FILES
generate_patch "hwrng-esp32-trng" ESP32S3_TRNG_FILES
generate_patch "ipc-esp32" ESP32S3_IPC_FILES
generate_patch "mtd-esp32-flash" ESP32S3_MTD_FILES
generate_patch "usb-esp32-acm" ESP32S3_USB_ACM_FILES
generate_patch "phy-esp32s3-usb" ESP32S3_USB_PHY_FILES
generate_patch "dts-esp32s3" ESP32S3_DTS_FILES
generate_patch "wifi-esp32-ng" ESP32S3_WIFI_FILES
generate_patch "esp32s3-kconfig" ESP32S3_KCONFIG_FILES

log ""
log "=========================================="
log "Patch extraction complete!"
log "  Patches: $PATCHES_DIR/"
log "=========================================="
ls -lh "$PATCHES_DIR/"
