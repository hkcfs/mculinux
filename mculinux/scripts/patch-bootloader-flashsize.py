#!/usr/bin/env python3
"""Patch an ESP-IDF bootloader binary's declared flash size.

The ESP-ROM validates the partition table against the flash size encoded in
the bootloader image header (byte 3, high nibble: 3=8MB, 4=16MB, 5=32MB).
Our frozen bootloader.bin says 8MB, so any partition table reaching past
8MB makes the ROM reject the table and reboot-loop. For 16/32MB devices we
patch a COPY (never the committed prebuilt) and fix the trailing XOR
checksum (checksum ^= old_byte ^ new_byte).

Usage: patch-bootloader-flashsize.py <input.bin> <output.bin> <size_mb>
"""
import sys

SIZE_NIBBLE = {8: 0x3, 16: 0x4, 32: 0x5}


def main(inp, outp, size_mb):
    size_mb = int(size_mb)
    assert size_mb in SIZE_NIBBLE, f'unsupported size {size_mb}'
    with open(inp, 'rb') as f:
        data = bytearray(f.read())
    assert data[0] == 0xE9, f'not an ESP image (magic {data[0]:#x})'
    old = data[3]
    new = (SIZE_NIBBLE[size_mb] << 4) | (old & 0x0F)
    if old == new:
        print(f'header already declares {size_mb}MB, no change')
    else:
        data[3] = new
        # Trailing byte is XOR checksum over the file; XOR is linear.
        data[-1] ^= old ^ new
        print(f'patched flash size: {old:#04x} -> {new:#04x}, checksum fixed')
    with open(outp, 'wb') as f:
        f.write(data)


if __name__ == '__main__':
    main(*sys.argv[1:4])
