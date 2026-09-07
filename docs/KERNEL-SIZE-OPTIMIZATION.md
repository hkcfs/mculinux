# Kernel Size Optimization for ESP32-S3 (Linux 7.2.3 XIP)

## Background

The 7.2.3 XIP kernel (`xipImage`) was **3,748,080 bytes** against the `linux` partition limit of **4,063,232 bytes** (~315 KB headroom), and static RAM (`.data`+`.bss`) was 238,314 bytes. Goal: maximize free ROM and RAM using compiler/linker optimization only — no features disabled (round 1). Removing kallsyms symbol debug was explicitly approved afterwards (round 2).

Toolchain: `xtensa-esp32s3-linux-muslfdpic-gcc 14.0.1` (crosstool-NG-custom), GNU ld 2.42.50. Tree: `/tmp/linux-7.2.3` (7.2.3 + ESP32-S3 port).

## Why no LTO / ICF

Checked before optimizing; all three are unavailable, so they were replaced with `--gc-sections` + `-Oz`:

- Kernel LTO is Clang-only (`CONFIG_LTO_CLANG`); xtensa has no `ARCH_SUPPORTS_LTO`; kbuild does not support GCC `-flto`.
- This toolchain's `ld` has no `--icf` (verified via `ld --help`).
- `-Oz` is real in this GCC and already enables `-fipa-icf` (+functions, +variables) and disables function/loop/jump/label alignment (verified via `gcc -Q --help=optimizers -Oz`).

## Changes

Already present before this work (kept): `CC_OPTIMIZE_FOR_SIZE` (`-Os`), `LOG_BUF_SHIFT=14`, `-mtext-section-literals` (literals stay in flash `.text`, not RAM `.data`), no modules, no debug info, no `.eh_frame`.

### Round 1 — no features touched

1. **`CONFIG_LD_DEAD_CODE_DATA_ELIMINATION=y`** (`-ffunction-sections`/`-fdata-sections` + `--gc-sections`). It was in an old `.config` but kept getting dropped by `olddefconfig`, because **xtensa never selects `HAVE_LD_DEAD_CODE_DATA_ELIMINATION`** (arm/mips/m68k/riscv do). Fixed with a one-line addition to `arch/xtensa/Kconfig` under `config XTENSA`:
   ```
   select HAVE_LD_DEAD_CODE_DATA_ELIMINATION
   ```
   This must be captured as a patch when the 7.2.3 series is extracted (there is no `patches/linux-7.2.3/` dir yet).
2. **`CONFIG_SLUB_TINY=y`** (slimmer slab tuning). Kconfig auto-resolved side effects, all slab-debug only: dropped `SLAB_FREELIST_RANDOM/HARDENED`, `SLUB_STATS`, `SLUB_DEBUG`, `SLAB_BUCKETS`, `KMALLOC_PARTITION_CACHES`, `KVFREE_RCU_BATCHED`. No user-facing feature affected; `KALLSYMS` kept at this stage.
3. **`KCFLAGS="-Oz"`** for the build. `KBUILD_CFLAGS += $(KCFLAGS)` (top `Makefile:1222`) sits after `-Os`, so `-Oz` wins as the last `-O` flag.

### Round 2 — user-approved extras

4. **`CONFIG_KALLSYMS=n`** (`.config` diff was exactly the 3 kallsyms lines; nothing depended on it). Measured footprint before removal: **~290 KB** of `.rodata` (24,069 symbols, token table). Cost of removal: `%pS`/`%ps` printks and traces show raw addresses, no `/proc/kallsyms`. `System.map` + `nm vmlinux` still work, so QEMU-monitor/monitor-debug workflow is preserved.
5. **`KCFLAGS="-Oz -fmerge-all-constants"`** (the one `-Oz` extra not provably default-on; harmless no-op if already on).
6. **Strip non-loaded sections from the vmlinux *file*** (cosmetic, never reaches flash):
   ```
   xtensa-esp32s3-linux-muslfdpic-objcopy -R .xt.prop -R .comment vmlinux vmlinux.tmp && mv vmlinux.tmp vmlinux
   ```
   vmlinux file 5.98 MB → 3.68 MB; symtab kept. **Non-sticky**: any full rebuild regenerates these sections; re-run after rebuilding.

## Results

| | Start | Round 1 | Round 2 (final) | Total saved |
|---|---|---|---|---|
| `.text` | 3,546,841 | 2,974,923 | **2,655,651** | −891,190 (−25.1%) |
| `.data` | 173,720 | 170,200 | 170,204 | −3,516 |
| `.bss` | 64,594 | 59,380 | 59,380 | −5,214 |
| Static RAM (`.data`+`.bss`) | 238,314 | 229,580 | **229,584** | −8,730 (+ SLUB_TINY runtime savings on top) |
| **xipImage (ROM)** | 3,748,080 | 3,150,448 | **2,830,960** | **−917,120 (−24.5%)** |
| vmlinux file | ~6.9 MB | 5,979,580 | **3,680,268** | file only |
| Headroom under 4,063,232 | ~315 KB | ~913 KB | **~1.23 MB** | |

Round 2 attribution (~319 KB ROM): ~290 KB kallsyms + ~30 KB merge-all-constants.

## How to reproduce

```
export ARCH=xtensa CROSS_COMPILE=xtensa-esp32s3-linux-muslfdpic-
./scripts/config --enable LD_DEAD_CODE_DATA_ELIMINATION --enable SLUB_TINY --disable KALLSYMS
make olddefconfig          # verify: DCE + SLUB_TINY =y, KALLSYMS off, nothing else changed
make -j$(nproc) KCFLAGS="-Oz -fmerge-all-constants" xipImage
xtensa-esp32s3-linux-muslfdpic-size vmlinux   # expect text≈2655651 data≈170204 bss≈59380
xtensa-esp32s3-linux-muslfdpic-objcopy -R .xt.prop -R .comment vmlinux vmlinux.tmp && mv vmlinux.tmp vmlinux
cp arch/xtensa/boot/xipImage <repo>/tools/prebuilt/binaries/xipImage-7.2
scripts/build-image.sh r8n16 --kernel 7.2
scripts/test-qemu.sh r8n16 60
```

Requires the `arch/xtensa/Kconfig` select addition (else `olddefconfig` silently drops DCE again).

## Validation

> Status note (2026-09-07): written before first login. The 7.2.3 boot hang
> is since fixed and the tree boots to login — see `BRINGUP-7.2.3.md`, and
> current flash/RAM numbers in `MEMORY-OPTIMIZATION-FINDINGS.md`
> (xipImage is now ~1.79M after the E1–E9 config diet).

`test-qemu.sh r8n16 60` after each round → `Kernel:true / TTY:false / Login:false`, byte-identical behavior to the pre-change image. The 7.2.3 boot hang (interrupt-12 storm in `memmap_init`, separate open issue) is unaffected — neither caused nor fixed by this work.

## Checked and rejected

- `--icf`, LTO: toolchain/kernel don't support them (see above).
- `const`-ification: profiled top RAM hogs via `nm -S --size-sort` (`irq_desc`, `timer_bases`, `cpuhp_hp_states`, printk ring, `ipv4_net_table`) — all genuine runtime state, no easy wins.
- `.init.text/.init.data/.init.rodata` (~114 KB): already freed after boot (`free_initmem`); ROM cost only.
- `.xt.prop` (1.98 MB) / `.xt.lit`: non-loaded sections, never in flash; file-only.

## Future (deferred)

- Remove the 17 temporary `ESPDBG` breadcrumb printks (~1–2 KB) once the boot hang is fixed.
- Try `LOG_BUF_SHIFT` 14→13 (~30 KB RAM: 8 KB log + ~22 KB ring infos/descs) once full boot logs are no longer needed for hang debugging; the compile-time `#error` guard will reject it if too small.
