#!/bin/bash
# Single device build wrapper
# Usage: ./build.sh <device> [keep]

DEVICE="${1:-r8n8}"
KEEP="${2:-}"

if [ "$KEEP" = "keep" ]; then
    export keep_toolchain=y
    export keep_buildroot=y
    export keep_rootfs=y
    export keep_bootloader=y
fi

exec ./build-all.sh "$DEVICE"
