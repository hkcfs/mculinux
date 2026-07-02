# MCUlinux Images

Pre-built firmware images for ESP32-S3 microcontrollers.

## Supported Devices

| Device | PSRAM | SPI Flash | Build |
|--------|-------|-----------|-------|
| r8n8   | 8MB   | 8MB       | `r8n8` |
| r8n16  | 8MB   | 16MB      | `r8n16` |
| r16n16 | 16MB  | 16MB      | `r16n16` |

## Download

Download the latest release from [GitHub Releases](https://github.com/mculinux/mculinux/releases).

Each release contains:
- `firmware.bin` - Main firmware image
- `partitions.bin` - Partition table
- `bootloader.bin` - Bootloader image
- `flash.sh` - Flash script

## Building

```bash
# Build specific device
./scripts/build-image.sh r8n8

# Build all devices
./scripts/build-all.sh

# Test with QEMU
./scripts/test-image.sh r8n8
```

## Flashing

### Using Web Flasher
1. Open [flasher.mculinux.org](https://flasher.mculinux.org)
2. Connect your device via USB
3. Select the firmware file
4. Click Flash

### Using esptool.py
```bash
esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 115200 \
    write_flash 0x0 \
    bootloader.bin \
    partitions.bin \
    firmware.bin
```

## Partition Layout

| Name | Offset | Size | Description |
|------|--------|------|-------------|
| bootloader | 0x0 | 64KB | Bootloader binary |
| partition_table | 0x8000 | 32KB | Partition table |
| ota_0 | 0x10000 | Variable | Application firmware |
| ota_1 | Variable | Variable | OTA backup |
| nvs | End | 24KB | Non-volatile storage |
| phy_init | End | 4KB | PHY initialization |

## Configuration

Each device has its own configuration in `config/`:
- `sdkconfig.defaults` - ESP-IDF SDK configuration
- `partitions.csv` - Partition table definition
- `board.h` - Board-specific definitions

## License

GPL-3.0
