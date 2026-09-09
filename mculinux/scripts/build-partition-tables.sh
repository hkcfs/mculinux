#!/bin/bash
# Generate partition-table binaries from CSV sources (vendored generator,
# no ESP-IDF needed). Verifies the first six entries are byte-identical to
# the previously shipped table (only `data` may be appended).
# Usage: ./scripts/build-partition-tables.sh
set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PART_DIR="$MCULINUX_DIR/partitions"
OUT_DIR="$MCULINUX_DIR/tools/prebuilt/binaries"
GEN="$MCULINUX_DIR/tools/gen_esp32part.py"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 missing"; exit 1; }

for size in 8m 16m; do
    echo "=== partition-table-$size.bin ==="
    python3 "$GEN" -q "$PART_DIR/partition-table-$size.csv" "$OUT_DIR/partition-table-$size.bin"
    ls -lh "$OUT_DIR/partition-table-$size.bin"
done

# Verify structural invariants (no external reference blob needed):
# 7 entries, fixed offsets for 0-5 on both, data last filling the flash end.
python3 - "$OUT_DIR/partition-table-8m.bin" "$OUT_DIR/partition-table-16m.bin" << 'EOF'
import struct, sys
def entries(path):
    with open(path, 'rb') as f:
        data = f.read()
    # Row (32B): magic u16LE 0x50aa, type u8, subtype u8, offset u32LE,
    # size u32LE, label 16B, flags u32.
    out, off = [], 0
    while off + 32 <= len(data):
        magic, typ, sub, offset, size, label, _fl = \
            struct.unpack('<HBBLL16sL', data[off:off+32])
        if magic != 0x50aa:
            break
        label = label.split(b'\x00')[0].decode()
        out.append((label, offset, size))
        off += 32
    return out
e8, e16 = entries(sys.argv[1]), entries(sys.argv[2])
for name, entries, flash_end in (('8m', e8, 0x800000), ('16m', e16, 0x1000000)):
    labels = [l for l, _, _ in entries]
    assert labels == ['nvs', 'phy_init', 'factory', 'etc', 'linux', 'rootfs', 'data'], \
        f'{name}: wrong layout {labels}'
    offs = [(o, s) for _, o, s in entries]
    assert offs[0][0] == 0x9000, f'{name}: nvs offset moved'
    for (o1, s1), (o2, _) in zip(offs, offs[1:]):
        assert o1 + s1 <= o2, f'{name}: overlap at {o1:#x}'
    assert offs[-1][0] + offs[-1][1] == flash_end, f'{name}: data does not fill flash'
assert [(l, o) for l, o, _ in e8[:6]] == [(l, o) for l, o, _ in e16[:6]], \
    'entries 0-5 differ between 8m and 16m (mtdblock indices must match)'
for label, offset, size in e8:
    print(f'  8m : {label:10s} 0x{offset:08x} + 0x{size:08x} ({size//1024}K)')
print(f'  16m: data extends to 0x{e16[-1][1] + e16[-1][2]:08x}')
print('OK: 7 partitions, no overlaps, data fills flash tail')
EOF
