# Generic Mainline Kernel Test Results

## Date: 2026-07-04
## Kernel: 7.1.2 (latest stable)
## Cross-compiler: xtensa-esp32s3-linux-muslfdpic-gcc (crosstool-NG 1.25.0)

## Result: CANNOT BUILD generic mainline kernel for ESP32-S3

### What we tried
1. `virt_defconfig` — targets dc232b core (MMU)
2. `nommu_kc705_defconfig` — targets de212 core (NOMMU)

Both fail with assembly errors:
```
arch/xtensa/kernel/head.S:48: Error: unknown opcode or format name 'diu'
arch/xtensa/kernel/head.S:48: Error: unknown opcode or format name 'iiu'
arch/xtensa/kernel/head.S:48: Error: unknown opcode or format name 'dii'
```

### Root cause
The generic kernel's Xtensa configs target **different Xtensa cores** (dc232b, de212) than ESP32-S3.
Our cross-compiler was built for the ESP32-S3 core and doesn't support other cores' ISA extensions.

### What the jcmvbkbc fork adds (that mainline lacks)
1. **Xtensa variant** — `arch/xtensa/variants/esp32s3/` (core config, ISA extensions)
2. **Platform support** — `arch/xtensa/platforms/esp32/` (memory map, XIP, noMMU)
3. **Drivers** — 15+ ESP32-S3 specific drivers not in mainline:
   - IRQ controller (`irq-esp32-intc.c`)
   - Clock controller (`clk-esp32s3.c`)
   - UART (`esp32_uart.c`)
   - GPIO (`gpio-esp32.c`)
   - SPI (`spi-esp32.c`)
   - TRNG (`esp32-trng.c`)
   - IPC (`esp32-ipc.c`)
   - MTD flash (`map_esp32.c`)
   - USB ACM (`esp32_acm.c`)
   - USB PHY (`phy-esp32s3-usb.c`)
   - WiFi (`espressif/`)
4. **Device tree** — `esp32s3.dtsi`, `esp32s3-devkit-c1.dts`
5. **Kconfig options** — `XTENSA_PLATFORM_ESP32`, `XTENSA_VARIANT_CUSTOM`

### Conclusion
Using the generic mainline kernel for ESP32-S3 is **not possible** without:
- A cross-compiler built for the target core (dc232b/de212), OR
- Porting the ESP32-S3 variant/platform files into the generic kernel

The jcmvbkbc fork is the only working approach. The fork is based on mainline Linux
with ESP32-S3 support added on top.
