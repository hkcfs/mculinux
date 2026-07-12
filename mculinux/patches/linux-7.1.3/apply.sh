#!/bin/bash
# Patches for Linux 7.1.3 to build for ESP32-S3 with host toolchain
# Run from kernel source root: bash /path/to/apply.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Applying Linux 7.1.3 ESP32-S3 patches..."

# Fix 1: processor.h guard macro (__ASSEMBLER__ -> __ASSEMBLY__)
# GCC defines __ASSEMBLY__ for .S files, not __ASSEMBLER__
sed -i 's/#ifndef __ASSEMBLER__/#ifndef __ASSEMBLY__/g' arch/xtensa/include/asm/processor.h
echo "  Patched processor.h: __ASSEMBLER__ -> __ASSEMBLY__"

# Fix 2: Disable coprocessor 3 (AI) - assembler lacks rur/wur/st.qr/ld.qr
sed -i 's/XCHAL_CP_MASK.*=.*0x09/XCHAL_CP_MASK                          = 0x01/' arch/xtensa/variants/esp32s3/include/variant/tie.h
echo "  Patched tie.h: XCHAL_CP_MASK 0x09 -> 0x01"

# Fix 3: Disable external registers - assembler lacks rer/wer opcodes
sed -i 's/XCHAL_HAVE_EXTERN_REGS.*=.*1/XCHAL_HAVE_EXTERN_REGS                  = 0/' arch/xtensa/variants/esp32s3/include/variant/core.h
echo "  Patched core.h: XCHAL_HAVE_EXTERN_REGS 1 -> 0"

# Fix 4: Add XIP_KERNEL and XTENSA_LOAD_STORE selects to ESP32 platform
sed -i '/select XTENSA_PLATFORM_ESP32$/a\\tselect XIP_KERNEL\n\tselect XTENSA_LOAD_STORE' arch/xtensa/Kconfig
echo "  Patched Kconfig: added XIP_KERNEL, XTENSA_LOAD_STORE selects"

# Fix 5: Add MTD_ESP32 config option
if ! grep -q "MTD_ESP32" drivers/mtd/chips/Kconfig; then
    sed -i '/^config MTD_BLOCK$/a\\nconfig MTD_ESP32\n\ttristate "ESP32 flash mapping"\n\tdepends on MTD\n\tselect MTD_PARTITIONS\n\tselect MTD_MTDRAM\n\t---help---\n\t  Map driver for ESP32 SPI flash.\n' drivers/mtd/chips/Kconfig
    echo "  Added MTD_ESP32 to drivers/mtd/chips/Kconfig"
fi

# Fix 6: Add ESP32_IPC config option
if ! grep -q "ESP32_IPC" drivers/misc/Kconfig; then
    cat >> drivers/misc/Kconfig << 'KCONF'

config ESP32_IPC
	tristate "ESP32 IPC driver"
	depends on OF
	---help---\n\t  Inter-processor communication driver for ESP32.
KCONF
    echo "  Added ESP32_IPC to drivers/misc/Kconfig"
fi

# Fix 7: Add Makefile entries
if ! grep -q "map_esp32" drivers/mtd/chips/Makefile; then
    echo 'obj-$(CONFIG_MTD_ESP32) += map_esp32.o' >> drivers/mtd/chips/Makefile
    echo "  Added map_esp32.o to drivers/mtd/chips/Makefile"
fi
if ! grep -q "esp32-ipc" drivers/misc/Makefile; then
    echo 'obj-$(CONFIG_ESP32_IPC) += esp32-ipc.o' >> drivers/misc/Makefile
    echo "  Added esp32-ipc.o to drivers/misc/Makefile"
fi

echo "All patches applied."
