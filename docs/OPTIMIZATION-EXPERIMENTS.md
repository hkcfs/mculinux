# Optimization Experiment Log (7.2.3 / r8n16 / 8M)

One variable per cycle. Baseline: production config
(`-Oz -fmerge-all-constants`, `KALLSYMS=n`, `SLUB_TINY=y`, DCE off).
`free -m` baseline was `8 4 2 2` (total/used/free/avail).

| # | Experiment | Flash Δ | RAM Δ | Verdict |
|---|---|---|---|---|
| E0 | Size rounds 1+2 (`-Oz`, `SLUB_TINY`, `KALLSYMS=n`, merge-constants, strip) | 3748080 → 2830960 (Round2, DCE-on, didn't boot — see E2) | slab 3492K → 2224K | partial KEEP (DCE part reverted) |
| E1 | Config trims: `BASE_SMALL=y`, `LEGACY_PTYS/UNIX98_PTYS/LDISC_AUTOLOAD=n`, `LOG_BUF_SHIFT 14→12` (`GPIO_CDEV` refused — reselected; `VT` already off) | 3391440 → 3344784 (−46K) | −12K logbuf + data | KEEP, login PASS |
| E2 | DCE on (re-test with all fixes) | 3391440 → 2892528 (−500K!) | n/a | **REVERT — guilty**: boots through `sched_clock`, dies silently before `Calibrating delay loop`. xtensa LDS lacks `KEEP()`s; needs linker-script work. Log: `/tmp/opencode/dceboot.txt` |
| E3 | `SLUB_TINY` off (slab visibility probe) | +594K (2830960→3424720 scale) | used 4→5, free 2→1 | REVERT (instrument only). Yield: slab ranking method |
| E4 | Tracing build (`SLUB_DEBUG`+`DEBUG_FS`+`SLUB_DEBUG_ON`) + `alloc_traces` | instrument only | instrument only | REVERT. Yield: **kernfs_node_cache 934K/5678 objs #1**, debugfs_inode 280K self-inflicted, biovec 262K, 33 kthreads |
| E5 | **`SYSFS=n`** | 3344784 → 3288432 (−56K) | **MemFree 1400→2560K (+1.16M), Slab 2224→1128K (−1.1M), MemTotal +68K**; `free` now `8 3 3 3` | **KEEP, login PASS** |
| E6 | **`NET=n`** (cascades INET/UNIX/WIRELESS/NETDEVICES/DIAGs all off — board has no NIC) | 3288432 → 2199888 (**−1.06M**) | MemFree 2560→3084K (+524K), Slab 1128→948K, MemTotal +36K; `free` now `8 3 3 4` | **KEEP, login PASS** |
| E7 | **Bus diet: `USB/MMC/SPI/I2C/FW_LOADER/CRYPTO_SHA256=n`** (DTS has only dormant i2c0 node + USB pinmux; rootfs needs LZMA so XZ stays) | 2199888 → 1992208 (**−203K**, xipImage under 2M) | MemFree 3084→3128K (+44K), Slab −24K, stacks 256→240K | **KEEP, login PASS** |
| E8 | **Kconfig residue: `MTD_OF_PARTS=n`, `KEYS=n`, XZ filters `X86/POWERPC/ARM/ARMTHUMB/SPARC/RISCV=n`, `MTD_MTDRAM=n`** (MTDRAM was a stale `=y` nothing selects — pure carryover; `select MTD_MTDRAM` already removed from `MTD_ESP32`) | 1992208 → 1901200 (**−91K**) | MemFree 3128→3144K, Slab 920K, MemTotal 7952K | **KEEP, login PASS** |
| E9 | **`VFAT_FS/EXFAT_FS=n`** (`FAT_FS` auto-dropped; reconstruction noise — exFAT probe failures were just fs-try order) | 1901200 → 1790288 (**−108K**, xipImage now 1.7M) | RAM ~neutral (MemFree 2960 vs 3144 = session noise, no RAM mechanism — XIP text + unmounted-fs caches; `free`: 7952/2896/3308/1748/3932; slabinfo unreadable under `SLUB_TINY`); boot to init **~0.99s vs ~2.1s** (less fs probing) | **KEEP, login PASS** |

## Notes
- `test-qemu.sh` sometimes reports `Kernel:false` alongside `Login:true` — harness grep quirk; serial log is authoritative.
- Version-string bytes differ between bit-identical-content rebuilds (`Linux version #N`); compare with that in mind.
- Debug builds stay out of `tools/prebuilt/` — restore production + re-verify after every instrument cycle.
- Scaffolding (`ESPDBG*` probes) still in tree — remove before final capture.
- Open: DCE linker fix (~500K flash), BLOCK diet (biovec 262K — needs root-on-MTD feasibility), driver/kthread diet (32 procs at idle), `GPIO_CDEV` select source.
- 2026-09-07 incident: `.config` silently flipped `KERNEL_ABI_CALL0=y` → `KERNEL_ABI_DEFAULT=y` (choice guarded by `CC_HAVE_CALL0_ABI` — any `olddefconfig` without toolchain in PATH drops it, sticky after). Mixed-config objects broke link (`_WindowVectors_text_start/end` undefined, `dangerous relocation: _WindowUnderflow*`). Fix: `--enable KERNEL_ABI_CALL0` + `olddefconfig` **with PATH exported** + `make clean` rebuild. Lesson: never run `*config` without the toolchain PATH.
- Interactive measure helper: `/tmp/opencode/qmeasure.py` (boots flash in QEMU, auto-logins on `/ # `, runs `free`/meminfo/slabinfo/ps, saves serial log). Note test-qemu.sh goes straight to `/ # ` shell (no `login:` prompt).
