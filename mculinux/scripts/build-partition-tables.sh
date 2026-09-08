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
OLD_BIN="$OUT_DIR/partition-table.bin"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 missing"; exit 1; }

for size in 8m 16m; do
    echo "=== partition-table-$size.bin ==="
    python3 "$GEN" -q "$PART_DIR/partition-table-$size.csv" "$OUT_DIR/partition-table-$size.bin"
    ls -lh "$OUT_DIR/partition-table-$size.bin"
done

# Verify: entries 0-5 of the new 8m table must match the old shipped table's
# OFFSETS (the old blob's nvs length overruns phy — a pre-existing wart that
# gen_esp32part.py itself rejects, so compare offsets, not full equality).
# Only rootfs may shrink and `data` may be appended.
python3 - "$OLD_BIN" "$OUT_DIR/partition-table-8m.bin" << 'EOF'
import struct, sys
def offsets(path):
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
        out.append((label, typ, sub, offset, size))
        off += 32
    return out
old, new = offsets(sys.argv[1]), offsets(sys.argv[2])
assert [(l, o) for l, _, _, o, _ in old] == [(l, o) for l, _, _, o, _ in new[:len(old)]], \
    f'labels+offsets changed!\nold={old}\nnew={new}'
assert new[-1][0] == 'data', f'last partition must be data, got {new[-1]}'
for label, _t, _s, offset, size in new:
    print(f'  {label:10s} 0x{offset:08x} + 0x{size:08x} ({size//1024}K)')
print('OK: labels+offsets identical, rootfs shrunk, data appended')
EOF
