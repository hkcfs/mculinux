# RootFS Filesystem Comparison for ESP32-S3

## Background

The ESP32-S3 has an 8MB flash layout where the root filesystem partition starts at offset `0x480000` with a maximum size of ~3.5MB (minus kernel/xipImage at `0x120000`).

The original build used **cramfs** via Buildroot, producing a `rootfs.cramfs` of **4.3MB** -- exceeding the partition and requiring manual stripping of packages (wpa_supplicant, dropbear, iw, htop, nano, etc.) to fit.

## Migration

Removed cramfs support from both the kernel config and Buildroot. Replaced with **SquashFS + ZSTD** as the default. Also enabled SquashFS+XZ and EROFS+ZSTD in the kernel for flexibility.

## Results (source rootfs: 5.9M unpacked)

| Filesystem | Compression | Block/Cluster | Image Size | Fits 3.5M? |
|------------|-------------|---------------|------------|------------|
| cramfs     | zlib        | —             | 4.3 MB     | No (stripped) |
| SquashFS   | gzip        | 16K           | 2.8 MB     | Yes |
| SquashFS   | zstd        | 16K           | 2.7 MB     | Yes |
| SquashFS   | xz          | 16K           | 2.5 MB     | Yes |
| EROFS (default) | zstd,level=3 | 4K       | 3.6 MB     | Yes |
| EROFS (opt) | zstd,level=22,dict=64k,frag,dedupe | 4K/64K | 2.6 MB | Yes |

## Flags Used for Optimized EROFS
|
### Original command
```
# mkfs.erofs -z zstd,level=22,dictsize=64k -C 65536 \
#   -E fragments,dedupe \
#   rootfs.erofs ./rootfs_dir
```
|
### Updated command
```
mkfs.erofs -zlzma,level=109 -C 16384 -E fragments,dedupe,ztailpacking,force-inode-compact -x -1 -T 0 test4.erofs ./extracted_rootfs/
```

- `-z zstd,level=22,dictsize=64k` -- maximum ZSTD compression level with a 64KB dictionary for better pattern matching across files
- `-C 65536` -- 64KB compress physical cluster; larger clusters = better ratios (like SquashFS's 16K blocks)
- `-E fragments,dedupe` -- packs small file tails into shared blocks and deduplicates identical data

## Why Default EROFS Was Larger (3.6 MB)

1. **Small block size** -- EROFS mandates block size = page size (4K on Xtensa), vs SquashFS's 16K default. Less data per compression window = worse ratio.
2. **Low default compression level** -- `-z zstd` defaults to level 3. Cranking to 22 with dictsize=64K recovers most of the gap.
3. **No fragment packing or dedupe** -- without `-E fragments,dedupe`, small file tails and duplicate data are stored uncompressed/redundantly.

## Recommendations

| Use Case | Filesystem | Size |
|----------|------------|------|
| General purpose | SquashFS + ZSTD | 2.7 MB |
| Max density | SquashFS + XZ | 2.5 MB |
| Fast random read / low RAM | EROFS + ZSTD (optimized) | 2.6 MB |

All three fit easily in the 3.5 MB partition with headroom.

## Kernel Support

The kernel config now includes:

- `CONFIG_SQUASHFS=y` with `ZSTD` and `XZ` decompressors
- `CONFIG_EROFS_FS=y` with `ZSTD` and `LZMA` decompressors
- `# CONFIG_CRAMFS is not set` (removed)
- `root=/dev/mtdblock5` in DTB (auto-detects filesystem type, no `rootfstype=` needed)

## QEMU Boot Tests

All pass:

1. **SquashFS + ZSTD** (2.7 MB) -- `Mounted root (squashfs filesystem)`
2. **EROFS + ZSTD optimized** (2.6 MB) -- `Mounted root (erofs filesystem)`
3. **SquashFS + XZ** (2.5 MB) -- `Mounted root (squashfs filesystem)`
