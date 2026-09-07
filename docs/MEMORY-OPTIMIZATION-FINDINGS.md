# Memory Optimization Findings (7.2.3 / r8n16 / 8M RAM)

Experiment campaign E0–E9, September 2026. Raw per-cycle log:
`OPTIMIZATION-EXPERIMENTS.md`. Compiler-flag groundwork (rounds 1–2):
`KERNEL-SIZE-OPTIMIZATION.md`. Bring-up story: `BRINGUP-7.2.3.md`.

## Result in one paragraph

One variable per cycle, login re-verified every cycle. xipImage went
**3,748,080 → 1,790,288 bytes (−52%)**, back to ~2.3M headroom under the
4,063,232-byte `linux` partition. `free` went from `8 4 2 2` to roughly
`8 2 3 3` — free RAM about doubled. Two config options (`SYSFS=n`,
`NET=n`) delivered ~90% of the RAM gain; everything else was flash diet.

## Why this worked: where the RAM was going

This is an XIP kernel: `.text` executes from flash and costs zero RAM, so
flash size and RAM size are almost independent problems. The RAM hogs were
all **slab caches**, found via a tracing build (E4, `SLUB_DEBUG` +
`alloc_traces` + `addr2line`):

- `kernfs_node_cache` ~934K / 5678 objs — gone with `SYSFS=n` (E5).
  A headless MCU with no `/sys` consumers pays over 1M for sysfs nodes.
- `biovec-max` 262K — needs the BLOCK layer (root is erofs-on-mtdblock);
  still present, see § Open levers.
- `dentry`, `task_struct`/`sighand` (~32 procs at idle), `radix_tree_node`
  — the long tail of a general-purpose kernel config on an MCU.

## Findings per experiment

| # | Change | Flash | RAM | Why it behaved that way |
|---|---|---|---|---|
| E0 | `-Oz`, `SLUB_TINY`, `KALLSYMS=n`, merge-constants, strip | 3748080 → 2830960 | slab 3492K → 2224K | Compiler/linker only; `SLUB_TINY` alone saved ~1.3M slab. |
| E1 | `BASE_SMALL=y`, legacy PTYs off, `LOG_BUF_SHIFT` 14→12 | −46K | −12K logbuf | Small static buffers; `GPIO_CDEV` refused (something selects it — still open). |
| E2 | DCE on (re-test) | −500K (unbootable) | n/a | **REVERTED.** xtensa LDS lacks `KEEP()`s; dies after `sched_clock`, before `Calibrating delay loop`. Biggest known flash prize, needs linker-script surgery. |
| E3 | `SLUB_TINY` off (probe) | +594K | used 4→5, free 2→1 | **REVERTED** (instrument only). Confirmed TINY's value + yielded the slab-ranking method. |
| E4 | Tracing build | instrument only | instrument only | **REVERTED.** Yield: the slab ranking above. Debug builds stay out of `tools/prebuilt/`. |
| E5 | `SYSFS=n` | −56K | **MemFree +1.16M, slab −1.1M** | The kernfs cache was the #1 RAM hog. No `/sys` consumers on this board. |
| E6 | `NET=n` (cascades INET/UNIX/WIRELESS/NETDEVICES) | **−1.06M** | +524K | No NIC on board; the whole stack was dead weight. |
| E7 | Bus diet (`USB/MMC/SPI/I2C/FW_LOADER/CRYPTO_SHA256=n`) | −203K | +44K | DTS has only dormant nodes. Rootfs needs LZMA so XZ stays. |
| E8 | Residue (`MTD_OF_PARTS/KEYS/MTDRAM=n`, XZ filters off) | −91K | ~neutral | `MTD_MTDRAM=y` was stale carryover — nothing selects it. |
| E9 | `VFAT/EXFAT=n` (`FAT_FS` auto-dropped) | −108K | ~neutral, boot to init 2.1s→~1s | Reconstruction noise; exFAT probe failures were just fs-try order before erofs matched. |

Current state: xipImage 1,790,288; `free` 7952/2896/3308/1748/3932;
MemTotal 7952K, slab ~920K (unreadable under `SLUB_TINY` — no
`/proc/slabinfo`), 32 procs at idle.

## Checked and rejected: kernel modules

Modules were proposed as "load only when needed". Verdict: **skip** —
`=n` strictly dominates `=m` on this board:

1. XIP text already costs zero RAM; modules would live in flash too but
   cost RAM when loaded **plus** ~50–100K for `CONFIG_MODULES` itself and
   per-module tables.
2. Nothing load-worthy remains: NET/USB/MMC/SPI/I2C are already `=n`,
   and everything still built-in (MTD, erofs, serial) is needed to mount
   root, so it cannot be deferred anyway.
3. Module support on noMMU xtensa/FDPIC is thinly tested upstream —
   risk for no gain.

## Open levers (in expected-value order)

1. **BLOCK diet** (biovec 262K slab) — needs root-on-MTD feasibility:
   JFFS2 is MTD-direct (no block layer) vs current erofs-on-mtdblock.
   Requires measuring JFFS2 mount time/scan RAM on 3M flash.
2. **Kthread/proc diet** — 32 procs at idle; audit what spawns them.
3. **DCE linker fix** — ~500K flash; add missing `KEEP()`s to
   `arch/xtensa/kernel/vmlinux.lds.S`, re-test E2.
4. Small: `LOG_BUF_SHIFT` 13, `GPIO_CDEV` select source.

## How to reproduce / continue

```
export PATH=<toolchain>/bin:$PATH   # NEVER run *config without this (§ Lessons)
export ARCH=xtensa CROSS_COMPILE=xtensa-esp32s3-linux-muslfdpic-
make olddefconfig
make -j$(nproc) KCFLAGS="-Oz -fmerge-all-constants" xipImage
cp arch/xtensa/boot/xipImage mculinux/tools/prebuilt/binaries/xipImage-7.2
cd mculinux && ./scripts/build-image.sh r8n16 --kernel 7.2
python3 /tmp/opencode/qmeasure.py output/r8n16/flash_r8n16.bin /tmp/opencode/eN.txt 90
```

`qmeasure.py` boots the image in QEMU, auto-logins on the `/ # ` prompt
(note: no `login:` prompt — init spawns a shell directly), runs
`free`/`meminfo`/`slabinfo`/`ps`, saves the serial log. `test-qemu.sh`
verdicts are hints; the serial log is truth.

## Lessons (paid for in full)

- **Always export the toolchain PATH before any `*config`.** A 2026-09-07
  `olddefconfig` without PATH silently flipped `KERNEL_ABI_CALL0=y` →
  `KERNEL_ABI_DEFAULT=y` (choice guarded by `CC_HAVE_CALL0_ABI`, sticky
  after), and mixed-config objects broke the link
  (`_WindowVectors_text_start/end` undefined). Fix was re-enable + clean
  rebuild; rule is now documented in `OPTIMIZATION-EXPERIMENTS.md`.
- **Match `System.map`/`vmlinux` to the exact image under test**
  (`Linux version ... #N` banner) before symbolizing anything — days were
  once lost to phantom traces from a wrong build's map.
- Debug builds and `ESPDBG*` scaffolding stay out of `tools/prebuilt/`;
  restore production + re-verify login after every instrument cycle.
