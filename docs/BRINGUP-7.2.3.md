# ESP32-S3 Linux 7.2.3 Bring-Up Notes

> Historical (2026-09-07): references `build/build-buildroot-*`,
> `patches/linux-7.1.3/`, and `xipImage-7.1`, all since removed. Current
> flow: tinyconfig + `patches/linux-esp32/fragment.config`, no Buildroot.
> Kept for the debug trail.

How the 7.2.3 XIP kernel went from "hangs in `memmap_init`" to a root login
on QEMU `esp32s3` (r8n16, 8M RAM). Written 2026-09-07 after first login.

Related docs: `KERNEL-SIZE-OPTIMIZATION.md` (size work),
`LIBC-COMPARISON.md` (toolchain), `BUILD-PROCESS.md` (build contract).

## 0. Starting point

- Toolchain: `xtensa-esp32s3-linux-muslfdpic-gcc 14.0.1` (crosstool-NG,
  musl-xtensa FDPIC fork), repo `mculinux/`.
- Reference: 6.16 ESP32 fork tree
  (`build/build-buildroot-esp32s3_devkit_c1_8m/build/linux-xtensa-6.16-esp32-tag/`)
  and the working 7.1.3 port (`patches/linux-7.1.3/`: 13 patches + `defconfig`,
  prebuilt `xipImage-7.1` boots to login).
- Goal: same thing on vanilla 7.2.3 (latest stable at the time),
  `Makefile: KERNEL_VERSION ?= 7.2.3`, work tree `/tmp/linux-7.2.3`
  (scratch, not yet captured as a patch series!).

## 1. Port reconstruction (7.1.3/6.16 → 7.2.3)

Rebuilt 9 port files from the 13 diff-patches against the 6.16 tree:

- `drivers/gpio/gpio-mmio.c`: `+{esp,esp32-clk-gpio}` (UART clock gate —
  without it `uart0_clk` probe defers forever; same fix as 7.1.3)
- `drivers/irqchip/irq-esp32-intc.c` + Makefile entry, `SERIAL_ESP32` Kconfig,
  `arch/xtensa` Kconfig (`XTENSA_PLATFORM_ESP32`, `ESP32_INTC`),
  `irq-esp32-intc.c`, `esp32_uart.c`, `esp32_acm.c`, `map_esp32.c`,
  `esp32-ipc.c` + headers, `esp32s3.dtsi` + `esp32s3-devkit-c1.dts` +
  `gpio-esp32.h`, `tie.h`/`core.h`/`tie-asm.h`, `MTD_ESP32`, `ESP32_IPC`,
  `processor.h __ASSEMBLY__` guard, `XCHAL_HAVE_EXTERN_REGS=0`
- Kconfig `---help---` → `help` fix so `olddefconfig` parses.
- defconfig cloned from 7.1.3, `LOG_BUF_SHIFT 17→14` to fit the 4063232-byte
  `linux` partition (xipImage 3743984 B, ~319 KB margin at that stage).

## 2. Size optimization (summary, see KERNEL-SIZE-OPTIMIZATION.md)

`-Os` + `-Oz` (real in this GCC, wins as last `-O` via `KCFLAGS`) +
`SLUB_TINY` + `LD_DEAD_CODE_DATA_ELIMINATION` (needed a one-line
`select HAVE_LD_DEAD_CODE_DATA_ELIMINATION` in `arch/xtensa/Kconfig`;
xtensa is the only arch missing it) + `KALLSYMS=n` +
`-fmerge-all-constants` + objcopy `-R .xt.prop -R .comment` on vmlinux.
Result: xipImage 3748080 → 2830960 B (−24.5%), static RAM −8734 B.
LTO/ICF unavailable (Clang-only LTO, no xtensa `ARCH_SUPPORTS_LTO`,
GNU ld has no `--icf`); `-Oz` already enables `-fipa-icf*` and disables
alignment. `free -m` on the booted system: **total 8 / used 4 / free 2 /
available 2** vs 7.1.3's total 7 / free 1 / available 1.

## 3. The boot hang

### 3.1 Symptom

Every boot stopped after (44-line log):
```
[    0.000000] ESPDBG: calc_nr_kernel_pages done
```
i.e. inside `memmap_init()`, the first thing after `calc_nr_kernel_pages()`
in `free_area_init()`. No panic, no fault message — total silence.

### 3.2 How it was localized (breadcrumbs)

Added temporary `ESPDBG` printks stage by stage
(`init/main.c`, `mm/mm_init.c`, `mm/percpu.c`, `arch/xtensa/kernel/setup.c`),
then per-zone / per-range / per-page prints in `memmap_init()` →
`memmap_init_zone_range()` → `memmap_init_range()`. Result:

```
ESPDBG: memmap_init range i=0 start=251904 end=253952 nid=0
ESPDBG: memmap_init zone j=0
ESPDBG: zonerange zid=0 start=251904 end=253952 ...
ESPDBG: range enter size=2048 nid=0 zone=0 start=251904 sp=3d801ee0
ESPDBG: range pfn=251904 sp=3d801ee0
ESPDBG: pg 251904
(no pg 251905 — death inside the FIRST __init_single_page)
```

SP was sane (`0x3d801ee0`, inside the init stack). Next probe printed the
mapping itself:

```
ESPDBG: mem_map=3dfe91a0 page0=3e7991a0 off=0
```

`page0 = 0x3e7991a0` is **past the end of RAM** (`0x3d800000–0x3e000000`).
The first `memset` in `__init_single_page` wrote 16 MB past the array.

### 3.3 Root cause #1: `CONFIG_DEFAULT_MEM_START=0x0`

`ARCH_PFN_OFFSET = PHYS_OFFSET >> PAGE_SHIFT`, and on noMMU xtensa
`PHYS_OFFSET = CONFIG_DEFAULT_MEM_START`. Our 7.2.3 `.config` had
`CONFIG_DEFAULT_MEM_START=0x00000000`, so `pfn_to_page()` subtracted 0
instead of 251904 (`0x3d800000>>12`). The working 7.1.3/6.16 configs both
have `CONFIG_DEFAULT_MEM_START=0x3d800000`; the 7.2.3 defconfig
reconstruction dropped the line. Everything before the first `mem_map[]`
dereference worked because with `PAGE_OFFSET == PHYS_OFFSET == 0`,
`__pa`/`__va` are accidentally identity on noMMU.

Fix: `scripts/config --set-val DEFAULT_MEM_START 0x3d800000` (+ `olddefconfig`).
Boot immediately proceeded past `memmap_init` (`memmap_init done`,
`Memory: 7540K/8192K available`, scheduler, ...).

### 3.4 The int12-storm misadventure (lesson!)

QEMU `-d int` tracing showed ~8M `do_interrupt(12)` hits and factory-app
bytes at the stuck PC, which looked like an interrupt-routing bug (SPI3→CPU12
suspect, intc `disconnect_all` timing, etc.). Two days of forensics followed
— most of it later proven **worthless**, because PCs were symbolized against
the WRONG build's `System.map` (`#8` trace vs `#12` map gave phantom
`tty_init`/`__irq_domain_instantiate` hits).

**Lesson: always verify the `System.map`/`vmlinux` matches the exact image
under test (`Linux version ... #N` banner).** Re-traced on the current build
with correct symbols, the "storm" PCs were the kernel exception/double-fault
vectors — i.e. aftermath of the wild `memset`, not a cause. The INTENABLE
mask experiment (setup_arch) was proven no-effect and is slated for removal.

GDB attempts: Debian `gdb-multiarch` (installed user-local via
`apt-get download` + `dpkg-deb -x` to `/tmp/opencode/gdbroot`) connects but
fails with `Remote 'g' packet reply is too long (944 vs 180 bytes)` — QEMU's
LX7 register layout vs GDB's built-in xtensa core. Espressif's toolchain
tarball (`xtensa-esp-elf-16.1.0`, 89 MB, in `/tmp/opencode/`) ships **no GDB
binary**. QEMU monitor (`info registers`, `xp`, `pmemsave`, `-d int`) plus
printks did the whole job instead.

## 4. Post-memmap bring-up (one bug per rebuild cycle)

After the MEM_START fix, each boot got further and each stop had exactly one
cause. All were 7.2.3-reconstruction misses (config or fork code absent from
the 13 patches):

1. **`CONFIG_LD_DEAD_CODE_DATA_ELIMINATION` off** — the tree briefly had no
   output past `sched_clock`; turning DCE back off got UART probing.
   (Status: DCE currently OFF. The jcmvbkbc fork enables DCE for xtensa, so
   DCE may be innocent and the earlier stop may have been timing luck —
   re-test candidate for regaining ~460 KB ROM. NOT YET RETRIED.)
2. **`CONFIG_EROFS_FS` (+`_XATTR/_POSIX_ACL/_SECURITY/_BACKED_BY_FILE/_ZIP/_ZIP_LZMA`)**
   — rootfs is EROFS; without it `VFS: Unable to mount root fs`.
3. **`CONFIG_MTD_PHYSMAP_OF=y` + `|| MTD_ESP32` dep fix** in
   `drivers/mtd/maps/Kconfig` — without the dep, `MTD_PHYSMAP` is
   unselectable (needs CFI/JEDEC/ROM/RAM/LPDDR, all off), so `physmap`
   never binds `flash@42000000` ("mtd-rom"): no MTD, no partitions.
   (The `|| MTD_ESP32` exists in the 7.1 live tree but in none of the 13
   patches — fork-level change.)
4. **PIC hierarchy alloc/free** — `irq_domain_alloc_irqs_parent returned -38`
   (`-ENOSYS`): the parent `xtensa-pic` domain has no `.alloc`, so the
   intc's parent alloc fails → IPC and UART get no IRQ
   (`error -6: IRQ index 0 not found`). Ported `xtensa_pic_irq_domain_alloc`
   / `xtensa_pic_irq_domain_free` (+ empty `xtensa_irq_eoi`) from the fork's
   `irq-xtensa-pic.c` into 7.2.3's. IPC+UART IRQs allocate, MTD partitions
   appear (`6 esp32 partitions found on MTD device 42000000.flash`),
   `erofs (device mtdblock5): mounted`, `Run /sbin/init`.
5. **ISS `rs_init` steals `ttyS0`** — `arch/xtensa/platforms/iss/console.c`
   `late_initcall(rs_init)` bulk-registers a single-port "ttyS" driver with
   no `DYNAMIC_DEV`, racing (and beating, ~2.34s vs ~2.5s) the real ESP32
   UART port registration → `sysfs: cannot create duplicate filename
   '/class/tty/ttyS0'` → serial core sets `UPF_DEAD` → every console open
   fails with `-ENXIO` (`Warning: unable to open an initial console (-6)`)
   → init runs deaf/mute, no login. Debug path: `ESPDBG-TTYREG` prints in
   `tty_register_device_attr` caught both creators; `drv=ttyS num=1
   flags=4 caller=rs_init` vs `num=3 flags=d caller=serial_core_register_port`;
   `uart_port_activate: UPF_DEAD → -ENXIO` identified as the errno source.
   Fixes: moved `config XTENSA_PLATFORM_ESP32` INSIDE the `choice` block
   (it was reconstructed after `endchoice`, so `XTENSA_PLATFORM_ISS` stayed
   y alongside ESP32), added the missing
   `platform-$(CONFIG_XTENSA_PLATFORM_ESP32) := esp32` Makefile mapping +
   `arch/xtensa/platforms/esp32/include/platform/serial.h`
   (`BASE_BAUD 115200`, both copied from the 7.1 tree which has them),
   and gated `rs_init`/`late_initcall` on `CONFIG_XTENSA_PLATFORM_ISS`.
   (Latent on 7.1.3 too — its boots never reach late_initcall timing in the
   observed window.)

Missing-but-harmless notes: `CONFIG_JFFS2_FS` is off (same as working tree;
`/etc` jffs2 mount will fail in userspace — check later), VFAT/EXFAT stay on
(reconstruction noise, harmless; exFAT probe failures in the log are just
filesystem-try order before erofs matches).

## 5. Config changes vs the reconstructed defconfig

```
CONFIG_DEFAULT_MEM_START=0x3d800000   (was 0x0 — THE hang)
CONFIG_EROFS_FS=y + _XATTR/_POSIX_ACL/_SECURITY/_BACKED_BY_FILE/_ZIP/_ZIP_LZMA
CONFIG_MTD_PHYSMAP=y
CONFIG_MTD_PHYSMAP_OF=y
CONFIG_LD_DEAD_CODE_DATA_ELIMINATION off (re-test pending, see §4.1)
CONFIG_SLUB_TINY=y, CONFIG_KALLSYMS dropped, KCFLAGS="-Oz -fmerge-all-constants"
```

## 6. Source changes vs vanilla 7.2.3 (+ the 7.1.3-derived port)

Port fixes that must become `patches/linux-7.2.3/` hunks (not captured yet):
- `arch/xtensa/Kconfig`: `XTENSA_PLATFORM_ESP32` moved into `choice`;
  `select HAVE_LD_DEAD_CODE_DATA_ELIMINATION` under `config XTENSA`.
- `arch/xtensa/Makefile`: `platform-$(CONFIG_XTENSA_PLATFORM_ESP32) := esp32`.
- `arch/xtensa/platforms/esp32/include/platform/serial.h`: new file.
- `arch/xtensa/platforms/iss/console.c`: `rs_init` + `late_initcall` gated
  on `CONFIG_XTENSA_PLATFORM_ISS`.
- `drivers/mtd/maps/Kconfig`: `MTD_PHYSMAP` depends `|| MTD_ESP32`.
- `drivers/irqchip/irq-xtensa-pic.c`: `xtensa_irq_eoi`,
  `xtensa_pic_irq_domain_alloc/free` + ops wiring (from fork).

## 7. Validation (build #30+, r8n16, 90 s)

- `test-qemu.sh`: Kernel:true TTY:true **Login:true**
  (note: it once printed `Kernel:false` alongside Login:true — harness grep
  quirk, the serial log is authoritative).
- Manual: `root` login → `/ #` → `free -m` →
  `total 8 used 4 free 2 buff/cache 2 available 2`.
- xipImage 2830960 B (~1.23 MB headroom under the 4063232 B limit).

## 8. Still to do (as of this writing)

- Remove ALL debug scaffolding still in the tree: every `ESPDBG*` printk
  (`init/main.c`, `mm/mm_init.c`, `mm/percpu.c`,
  `arch/xtensa/kernel/setup.c` incl. the INTENABLE mask/dump experiment),
  `ESPDBG-INTC*`, `ESPDBG-IPC`, `ESPDBG-FLASH*`, `ESPDBG-UARTPROBE` (+ the two
  added `#include`s), `ESPDBG-TTYREG`, `ESPDBG-TTYDRV`, the errno printk
  tweak. Then rebuild + retest login.
- Re-test DCE on (fork supports it; ~460 KB at stake); keep off if it hangs.
- Capture `patches/linux-7.2.3/` (`extract-patches`-style) + a 7.2.3
  `defconfig` so the tree is reproducible from vanilla + patches.
- Follow-ups: `/etc` jffs2 (JFFS2 off — decide), `test-qemu.sh` Kernel:false
  quirk, `LOG_BUF_SHIFT` 13 test, r8n8/r16n16 matrix, `make test-loop`.
- The `Guru Meditation Error: Core 1 panic'ed` line seen once after a
  `panic=1` reboot is reboot-path noise (ESP-IDF bootloader), not our bug.

## 9. Method notes (for next time)

- One hypothesis + one variable per rebuild cycle; 10-min full rebuilds
  (~4 min incremental) make this affordable, guessing does not.
- `pmemsave` + `xp` + `-d int` from the QEMU monitor replace GDB here;
  `System.map` nearest-symbol lookup decodes raw stack dumps.
- `test-qemu.sh` verdicts are hints; serial logs are truth (buffering: always
  let QEMU exit orderly or use `timeout`, never trust a killed pipe).
- Diff against the working tree early and completely (config AND fork-only
  files like `irq-xtensa-pic.c`, `platforms/esp32/`, Kconfig deps) — every
  root cause here was a reconstruction miss, not new code.
