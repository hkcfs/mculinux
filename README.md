# MCUlinux

Pre-built binary images of Linux for ESP32-S3 microcontrollers.

## Supported Devices

| Device | PSRAM | SPI Flash | Build |
|--------|-------|-----------|-------|
| r8n8   | 8MB   | 8MB       | `r8n8` |
| r8n16  | 8MB   | 16MB      | `r8n16` |
| r16n16 | 16MB  | 16MB      | `r16n16` |

## Repository Structure

| Repository | Description |
|------------|-------------|
| [mculinux-packages](./mculinux-packages) | Alpine Linux package manifests for ESP32-S3 |
| [images](./images) | Firmware build system and pre-built binaries |
| [website](./website) | Download page, documentation, and serial flasher |

## Quick Start

1. Download the latest image for your device from [releases](https://github.com/mculinux/mculinux/releases)
2. Flash using the web flasher or `esptool.py`
3. Connect via serial console (115200 baud)

## Building

```bash
# Build all packages and images
make build

# Build specific device image
make build DEVICE=r8n8

# Run QEMU tests
make test

# Create release
make release VERSION=1.0.0
```

## Architecture

MCUlinux is built on Alpine Linux, cross-compiled for Xtensa (ESP32-S3), and packaged using Alpine's APKBUILD system.

```
┌─────────────────────────────────────────┐
│           mculinux-images               │
│  ┌─────────┐ ┌──────────┐ ┌─────────┐  │
│  │  r8n8   │ │  r8n16   │ │ r16n16  │  │
│  └────┬────┘ └────┬─────┘ └────┬────┘  │
│       └───────────┼────────────┘        │
│                   ▼                     │
│  ┌─────────────────────────────────┐    │
│  │       Alpine Linux Base         │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
                   ▲
                   │
┌─────────────────────────────────────────┐
│         mculinux-packages               │
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐      │
│  │ htop│ │ btop│ │ nano│ │ ... │      │
│  └─────┘ └─────┘ └─────┘ └─────┘      │
└─────────────────────────────────────────┘
```

## License

GPL-3.0
