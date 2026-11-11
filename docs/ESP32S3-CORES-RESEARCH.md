# ESP32-S3 Cores and ULP Coprocessors - Research

Answers three questions that come up whenever the split-core design is
explained to someone new:

1. Does the ESP32-S3 really have a RISC-V low-power core?
2. Can that core run the WiFi stack instead of a full Xtensa core?
3. Can Linux have both cores (real SMP)?

Short answers: yes to 1, no to 2, and 3 is possible but much larger than a
config line. Everything below is from the ESP32-S3 Series Datasheet v2.2 and
the ESP-IDF v6.1 programming guide, both linked at the end.

## The three execution engines

The ESP32-S3 is not just "dual core Xtensa". It has three distinct execution
engines, which is easy to miss because the marketing material only says
"dual-core".

| Engine | ISA | Clock | What it is for |
|--------|-----|-------|----------------|
| CPU0, CPU1 | Xtensa LX7, 32-bit | up to 240 MHz | General purpose, SMP-capable |
| ULP-RISC-V | RV32IMC, 32-bit | internal fast RC oscillator | Sensor polling, wakeup handling in sleep |
| ULP-FSM | Finite state machine | internal fast RC oscillator | Same, cheaper and lower power |

The ULP-RISC-V, per the datasheet, has 32 general-purpose registers, a 32-bit
multiplier and divider, support for interrupts, and can be booted by the CPU,
by its dedicated timer, or by an RTC GPIO.

> Correction (2026-09): an earlier claim in this project was that the
> ESP32-S3 has no RISC-V core at all, and that the ~20 MHz RISC-V low-power
> core is the only one. Both wrong. The S3 has a ULP-RISC-V coprocessor. What
> it does not have is the *LP Core*, which is a different and more capable
> thing. See the tier table below.

## Three tiers, and which chip gets which

Espressif grades the coprocessors into three tiers. This distinction is the
whole answer to question 2, so it is worth stating exactly.

| Tier | Chips | Runs while system fully active | Notes |
|------|-------|--------------------------------|-------|
| ULP FSM | ESP32, S2, S3 | no | Assembly or C macros |
| ULP RISC-V | S2, S3 | no | RV32IMC, programmable in C |
| ULP LP Core | **C5, C6, P4** | **yes** | Extended memory access, broader peripheral access, debug module, interrupt controller |

The ESP32-S3 has the middle tier. The tier that "combines the advantages of
the ULP RISC-V type with additional features" and that can run even when the
whole system is active is on the C5, C6 and P4.

A note on the clock figure: the frequently quoted 20 MHz (sometimes 17.5 MHz)
number belongs to the LP Core on C6 and P4. The ESP32-S3 datasheet does not
give a frequency for its ULP-RISC-V, only that "the clock of the coprocessors
is the internal fast RC oscillator". No timing assumption in this project
should be built on a 20 MHz figure for the S3.

## Why the ULP-RISC-V cannot be the WiFi core

The idea is attractive: run WPA and the radio stack on a 17 MHz core, leave a
240 MHz core for Linux, and have Linux SMP across the other two. It does not
work, and the IDF documentation gives four independent reasons.

**1. An 8 KiB memory ceiling.** `ulp_riscv_load_binary()` returns
`ESP_ERR_INVALID_SIZE` if the program is larger than 8 KiB, and the only
memory the coprocessor can reach is `RTC_SLOW_MEM`. `esp_wifi` plus lwIP is
hundreds of KB. The gap is not marginal.

**2. Peripheral reach is RTC-domain only.** The documented peripheral set is
`RTC_CNTL`, `RTC_IO`, `SARADC`, and the RTC I2C controller. The WiFi MAC and
PHY register block lives in the Core System peripheral range, which the
coprocessor cannot address. It cannot drive the radio even in principle.

**3. No OS, and it is not a long-running process.** It is bare metal with no
scheduler. The documented flow is: the main app loads a binary into RTC
memory, calls `ulp_riscv_run()`, the coprocessor executes from an entry point
until it writes `RTC_CNTL_COCPU_DONE` or traps, and then "the ULP RISC-V
coprocessor will power down, and the timer will be started again". Every
shipped IDF example is a short burst: read a sensor, wake the main CPU, print
over a bit-banged UART.

**4. The concurrency primitives are too weak.** Mutual exclusion between the
ULP and the main cores is Peterson's algorithm implemented in software, with
no hardware atomicity, and the docs state it "will not provide mutual
exclusion if used simultaneously from multiple threads". Interrupt handling
is partial: internal interrupt sources are not supported, only two RTC
peripheral sources are (software-triggered and RTC IO-triggered), and there
is no nesting. A rate-control and MAC path cannot be built on that.

## Where the ULP-RISC-V is genuinely useful here

It is a real, programmable execution engine, and it is already paid for. The
most concrete fit is the USB work rather than WiFi.

**USB bus keeper across deep sleep.** Patch `0007` already routes the USB
differential pair through two different domains on purpose: `usb_pins` in
`iomux` with `MUX_SLP_SEL`, and `usb_rtc_pins` in `rtc_iomux` with
`RTC_MUX_SEL`, so the RTC domain holds D- and D+ at a defined level while the
core sleeps. The ULP-RISC-V owns `RTC_IO`, which is exactly that domain. A ULP
program can therefore hold the bus while Linux is idle, watch the ID and VBUS
sense pins, and wake the main cores on a cable event.

**Cheap WiFi-adjacent supervision.** Not the MAC, but the bookkeeping around
it: periodic RSSI sampling, a reconnection watchdog, or beacon supervision
that pokes Core 0 when the link looks bad. The 802.11 work stays on Core 0
where the radio lives.

**Deep-sleep sensor polling.** The documented use case, via RTC I2C, with the
usual pin restriction (SDA only GPIO1 or GPIO3, SCL only GPIO0 or GPIO2) and
8-bit sub-register addressing.

**Toolchain is already present.** ULP code compiles with `riscv32-esp-elf-gcc`,
which ships with ESP-IDF, and this project already builds ESP-IDF firmware for
the network adapter. There is no new toolchain to introduce.

## Two-core support in this project today

This is a split-core design, not SMP, and both cores are already doing work.

```
Core 0 (Xtensa LX7)   ESP-IDF network_adapter
                      WiFi radio, WPA, association, IP
                      \_______________________________/
                       IPC control channel + shmem data
                      /_______________________________\
Core 1 (Xtensa LX7)   Linux
                      eth0 (esp32-wifi-shmem), userspace
```

- `CONFIG_SMP` is **not** set. The only `CONFIG_SMP` references anywhere in the
  tree are two inactive `#ifdef CONFIG_SMP` blocks in
  `0002-irq-esp32-intc.patch`, so nothing was lost by leaving it off.
- The IPC transport is `0003-esp32-ipc.patch`, and the network driver on top of
  it is `0009-esp32-wifi-shmem.patch`.
- Boot log confirmation from a QEMU run:
  `esp32-wifi-shmem 600c0004.ipc:wifi@1 eth0: ESP32-S3 WiFi shmem on IPC slot 1`.

The firmware side has a matching accommodation. `idf-v6.0-flash-skip.patch`
exists because ESP-IDF v6.0's `spi_flash` performs a rendezvous with the other
CPU that spins forever when that CPU is running Linux instead of FreeRTOS. The
patch restores a `g_spi_flash_skip_ipc` escape hatch forked around flash
operations issued on Linux's behalf. That patch is the clearest statement in
the tree of how deeply the split-core assumption runs.

### What real SMP would cost

Giving both Xtensa cores to Linux means taking them away from the firmware, so:

- The IPC rendezvous has no partner. The shmem transport would need rework,
  because it currently assumes a cooperative FreeRTOS peer rather than a
  scheduler that can preempt it mid-transaction.
- The flash escape hatch above becomes mandatory on every path, not just the
  ones already discovered.
- The WiFi path is lost, which is the project's reason for existing.

This is a multi-week change to the transport and the boot sequence, not a
Kconfig line. It is also the direction upstream would want to push eventually,
since a Linux that owns both cores is a more honest port, but it is a
different project from the one shipping today.

### What is already SMP-ready

Not nothing. `0002-irq-esp32-intc.patch` carries two `#ifdef CONFIG_SMP` blocks
that are inert today but deliberate:

- `MAX_CPU_COUNT` is 2 under SMP and 1 otherwise, so the IRQ chip sizes its
  descriptor arrays for two CPUs as soon as SMP is enabled.
- `.irq_set_affinity = irq_chip_set_affinity_parent` is compiled in under SMP,
  so the controller already knows how to route an interrupt to a specific CPU.

So the interrupt controller would not need new work. The cost is concentrated
in the IPC transport and the boot sequence, not in the IRQ layer.

## Testing constraints

None of this can be validated in QEMU. The Espressif QEMU `esp32s3` machine
(9.2.2, `esp_develop_9.2.2_20260417`) models no WiFi radio at all: there is no
`esp32-wifi` device, and the `netdev` types available are `socket`, `stream`,
`dgram` and `hubport`. The radio exists in the hardware and in the Core 0
firmware, so there is nothing for the emulator to model.

What QEMU *can* do is regression-check that Linux still boots with a given
config, which is how the current split-core design is tested. Anything
touching ULP-RISC-V execution, WiFi association, or USB enumeration needs real
hardware.

QEMU does model an Ethernet MAC (`open_eth`), so a genuine host-network path is
possible in principle, but there is no EMAC driver or DTS node for it in this
tree or in Max's `xtensa-6.11-esp32` branch. That would be a new driver
rather than a config change.

## Summary

| Question | Answer |
|----------|--------|
| Does the S3 have a RISC-V core? | Yes, a ULP-RISC-V coprocessor (RV32IMC) |
| Can it run WiFi? | No: 8 KiB memory cap, RTC-domain peripherals only, no OS, no nested interrupts |
| Are both cores used? | Yes, split-core: Core 0 firmware + radio, Core 1 Linux |
| Can Linux use both cores? | Not without abandoning the firmware core and reworking IPC and flash |
| What is the ULP good for here? | USB bus keeping in deep sleep, wakeup handling, cheap link supervision |
| Can any of it be tested in QEMU? | No, only boot regression |

## Resources

- ESP32-S3 Series Datasheet v2.2: https://documentation.espressif.com/esp32-s3_datasheet_en.pdf
- IDF ULP coprocessor overview (the three-tier table): https://docs.espressif.com/projects/esp-idf/en/v6.1/esp32s3/api-reference/system/ulp.html
- IDF ULP RISC-V programming: https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/system/ulp-risc-v.html
- IDF ULP LP Core (C5/C6/P4, for contrast): https://docs.espressif.com/projects/esp-idf/en/stable/esp32c6/api-reference/system/ulp-lp-core.html
- Max Filippov's ESP32 tree: https://github.com/jcmvbkbc/linux-xtensa/tree/xtensa-6.11-esp32
