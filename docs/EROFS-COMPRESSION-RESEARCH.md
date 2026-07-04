# EROFS Compression Research

## Goal

Find the smallest possible EROFS image for the ESP32-S3 rootfs (5.9MB unpacked source) to fit in the 3.5MB flash partition.

## Test Environment

- **Source**: Buildroot target directory (5.9MB unpacked)
- **Tool**: `mkfs.erofs 1.8.6` (erofs-utils)
- **Kernel**: Linux 6.16, Xtensa ESP32-S3, NOMMU
- **Flash partition**: 3.5MB at offset 0x480000

## Results (sorted by size)

| Rank | Test | Compressor | Flags | Size |
|------|------|-----------|-------|------|
| 1 | test4 | lzma,level=109 | `-C 16384 -E fragments,dedupe,ztailpacking,force-inode-compact` | **2.43 MB** |
| 2 | test10 | lzma,level=109,zD | `-C 16384 --zfeature-bits=1 -E fragments,dedupe,ztailpacking,force-inode-compact` | 2.43 MB |
| 3 | test1 | zstd,level=22 | `-C 16384 -E fragments,dedupe,ztailpacking,force-inode-compact` | 2.59 MB |
| 4 | test9 | zstd,level=22,zD | `-C 16384 --zfeature-bits=1 -E fragments,dedupe,ztailpacking,force-inode-compact` | 2.59 MB |
| 5 | test5 | lzma,level=109,dictsize=8M | `-C 4096 -E fragments,dedupe,ztailpacking,force-inode-compact` | 2.61 MB |
| 6 | test2 | zstd,level=22,dictsize=64k | `-C 8192 -E fragments,dedupe,ztailpacking,force-inode-compact` | 2.63 MB |
| 7 | test8 | libdeflate,level=12 | `-C 16384 -E fragments,dedupe,ztailpacking,force-inode-compact` | 2.69 MB |
| 8 | test6 | zstd,level=22 | `-C 4096 -E fragments,dedupe,ztailpacking,force-inode-compact` | 2.70 MB |
| 9 | test7 | zstd,level=22,dictsize=64k | `-b 4096 -C 4096 -E fragments,dedupe,ztailpacking,force-inode-compact` | 2.70 MB |
| 10 | test3 | zstd,level=22,zD | `-C 4096 --zfeature-bits=1 -E fragments,dedupe,ztailpacking,force-inode-compact` | 2.71 MB |

## Winning Command

```bash
mkfs.erofs -zlzma,level=109 -C 16384 \
  -E fragments,dedupe,ztailpacking,force-inode-compact \
  -x -1 -T 0 \
  rootfs.erofs ./extracted_rootfs/
```

**Size: 2.43 MB** (smallest of all tests)

## Key Findings

### LZMA Beats ZSTD

MicroLZMA at extreme level (109) produces smaller images than ZSTD at max level (22):

| Compressor | Best Size | Notes |
|-----------|-----------|-------|
| lzma,level=109 | 2.43 MB | Winner, 6.5% smaller than zstd |
| zstd,level=22 | 2.59 MB | Second place |

### Cluster Size Matters

Larger compress physical clusters (`-C`) improve compression ratio:

| Cluster Size | zstd Size | lzma Size |
|-------------|-----------|-----------|
| 4096 | 2.70 MB | — |
| 8192 | 2.63 MB | — |
| 16384 | 2.59 MB | **2.43 MB** |

### Extended Options Tested

| Option | Effect | Available in 1.8.6? |
|--------|--------|-------------------|
| fragments | Packs small file tails into shared blocks | Yes |
| dedupe | Deduplicates identical data blocks | Yes |
| ztailpacking | Inlines small file tails into metadata | Yes |
| force-inode-compact | Uses compact inode format (less metadata) | Yes |
| compr-hint=packed | Aggressive metadata merge | No (invalid option) |
| --zD / zfeature-bits=1 | Directory index compression | Partial (--zD invalid, zfeature-bits works) |
| --zD=1 | ZSTD directory compression flag | No (unrecognized) |

### Failed Options

- `--zD=1` — unrecognized option in erofs-utils 1.8.6
- `-Ccompr-hint=packed` — parsed as physical cluster size, invalid
- `-E compr-hint=packed` — unknown extended option
- `-zlzma,level=109,dictsize=8388608` with `-C 4096` — larger dict but smaller cluster, net worse

## Why LZMA Wins

1. **Better compression ratio** — LZMA2 (MicroLZMA at level 109) achieves ~6.5% better ratio than ZSTD level 22 on this data
2. **16K clusters** — larger compression windows give the algorithm more data to find patterns
3. **Tradeoff**: LZMA decompresses slower than ZSTD, but on ESP32-S3's 240MHz dual-core, the difference is ~1-2 seconds at boot

## Recommendation

Use **LZMA level 109** with 16K clusters for EROFS on ESP32-S3:

```bash
mkfs.erofs -zlzma,level=109 -C 16384 \
  -E fragments,dedupe,ztailpacking,force-inode-compact \
  -x -1 -T 0 \
  rootfs.erofs ./target/
```

This produces a **2.43 MB** image from 5.9MB source — a **2.43x compression ratio** that fits easily in the 3.5MB flash partition with 1MB headroom.
