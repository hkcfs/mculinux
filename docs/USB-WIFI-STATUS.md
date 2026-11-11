# USB and WiFi Support - Verified State

Branch: `exp-wifi-usb-support`. Kernel: Linux 7.2.8, `xtensa-esp32s3-linux-muslfdpic-gcc` 14.0.1.
Measured across 2 full runs of all three device profiles (6 boots, 5 captured).

This is a status record, not a plan. Everything marked Verified was observed in
a QEMU boot; everything marked Needs hardware cannot be observed in QEMU at all,
and the reason is stated so nobody re-derives it.

## Summary

| Area | State | QEMU-verifiable |
|------|-------|-----------------|
| DWC2 USB host driver builds | Working | yes |
| DWC2 probe reaches the controller | Working, was silently deferring before | yes |
| DWC2 enumerates a device | Not in QEMU, USB peripheral is not modelled | no |
| eth0 (WiFi over IPC) probes | Working | yes |
| WiFi control IPC round trip | Working end to end | yes |
| `wificfg mac` | Working, returns all-zero MAC in QEMU | yes |
| `wificfg scan` | Linux and firmware sides complete, no radio in QEMU | no |
| `wificfg connect` / association | Needs hardware | no |
| USB host on real hardware | Needs hardware | no |

## USB: the bug that was found and fixed

### Symptom

With `CONFIG_USB_DWC2=y` and `CONFIG_USB_DWC2_HOST=y` enabled, a boot produced
usbcore registering its drivers and then nothing at all. No `dwc2` string
anywhere in 3,432 lines of dmesg, and `/proc/interrupts` showed only three IRQs
(ipc, uart, timer) with nothing for the controller.

The first reading of that was "the platform device is never created". That was
wrong.

### What was actually happening

Instrumenting `dwc2_driver_probe` in the build tree showed the probe *was*
running:

```
dwc2 60080000.usb: DIAG: dwc2_driver_probe entered
dwc2 60080000.usb: DIAG: regs mapped at 60080000
dwc2 60080000.usb: DIAG: lowlevel_hw_init failed -517
```

`-517` is `-EPROBE_DEFER`. The probe deferred, DWC2's error path prints nothing
at the `error:` label, and deferred probes are not retried because nothing else
ever registers a provider. So the failure was completely silent, which is why it
survived a `patchcheck` pass, a clean 9-patch apply, and a passing boot test.

### Cause

The DWC2 node carried `resets = <&reset 23>`. The `reset` node is declared
`compatible = "esp,esp32-reset"` and **no mainline driver binds it**. So
`devm_reset_control_get_optional()` inside `dwc2_lowlevel_hw_init()` returns
`-EPROBE_DEFER` forever.

The `_optional` suffix is misleading here: it only means "return NULL if there is
no `resets` property". A property that *is* present but has no provider still
defers.

Why the other nodes were unaffected: `spi2`, `uart`, `ipc` and friends all carry
`resets` too, but their drivers never call the reset API, so a missing provider
is invisible. DWC2 is the only one that actually requests a reset.

### Fix

Drop `resets` / `reset-names` from the `usb@60080000` node in
`0007-xtensa-esp32s3-variant-dts.patch`, with a comment recording the reason.
This follows the precedent already set in the same node for the PHY, which is
omitted for the same reason: no mainline driver for
`"esp,esp32s3-usb-phy"`.

The clock gate is the real enable for the block, and `dwc2_core_reset()` runs
during probe. Cost of the change: 40 bytes of kernel image.

The upstreamable fix is a real `esp,esp32-reset` reset driver, not the omission.
Noted as follow-up.

### After the fix

```
dwc2 60080000.usb: Bad value for GSNPSID: 0x00000000
```

The probe now walks the entire software path: ioremap, `lowlevel_hw_init`,
`dr_mode` (correctly reads `USB_DR_MODE_HOST` = 1), and then fails at
`dwc2_check_core_version()` because the register read returns 0.

That failure is the emulator, not the driver. The Espressif QEMU `esp32s3`
machine does not model the USB peripheral, so `0x60080000` reads as zero and
GSNPSID cannot be a valid ID. On real hardware this read returns a real value
and the probe continues. `/proc/interrupts` still shows no USB IRQ in QEMU
because the probe fails before `devm_request_irq()`.

## WiFi: what is actually verified

### eth0 probe

```
esp32-wifi-shmem 600c0004.ipc:wifi@1 eth0: ESP32-S3 WiFi shmem on IPC slot 1, MAC b6:fe:86:fc:57:d9
```

`ifconfig eth0` confirms the interface is present with MTU 1500.

### Control IPC round trip (the useful one)

`wificfg mac` produces a full round trip: Linux issues `SIOCDEVPRIVATE` over
`eth0`, the driver frames it onto the shmem channel, Core 0 firmware's
`process_priv_commamd` dispatches `CMD_GET_MAC`, and the answer comes back:

```
I (23788) FW_MAIN: Get MAC command
eth0 firmware MAC: 00:00:00:00:00:00
```

The all-zero MAC is correct for QEMU: there is no radio and no NVRAM MAC, so
Core 0 has no real address to report. The round trip completing *is* the result.
This is the strongest WiFi assertion available without hardware, because it
exercises the driver, the command protocol, the shmem transport and the firmware
dispatcher together. An `eth0` probe line only proves the first of those.

Protocol IDs were checked on both sides and agree:

| Signal | Kernel (`0009`) | Firmware (`esp_hosted_ng`) |
|--------|-----------------|------------------------------|
| scan request | `ESP_CMD_SCAN 4` | `CMD_SCAN_REQUEST 4` |
| scan result | `ESP_EVT_SCAN_RESULT 1` | `EVENT_SCAN_RESULT 1` |

### `wificfg scan`: a real gap, but not a fixable one here

```
I (25798) FW_MAIN: INIT Interface command
I (25798) phy_init: phy_version 711,97bcf0a2,Aug 25 2025,19:04:10
scan: firmware did not answer (Part B scan command needed)
```

This is not a missing implementation. Both sides are complete: the kernel driver
sends `ESP_CMD_SCAN` and accumulates `ESP_EVT_SCAN_RESULT` frames, and the
firmware has `process_start_scan()` wired into the dispatcher.

It cannot work in QEMU because `process_start_scan()` gates on
`sta_init_flag` and calls `esp_wifi_scan_start()`. With no radio, either path
yields nothing to report. An aggressive command sequence in QEMU also loses the
occasional control transaction to the 8s timeout, which is the same "did not
answer" text; that flakiness is why the new test probe accepts an answer from any
of the six bundle iterations rather than the last one.

So the message "Part B scan command needed" is misleading when Part B *is*
present. Worth rewording to say the scan needs a radio, since the current text
sends the next person looking for firmware that is already there.

### Association and IP

`udhcpc -i eth0` is installed and on PATH but nothing invokes it at boot, and
there is no `inittab` in `rootfs/`; busybox supplies `init`. So the system does
not bring up an address automatically. Association needs a real AP and a real
radio, so that is hardware work.

`ip link show eth0` reports "can't find device" while `ifconfig eth0` works.
Not investigated; low impact since the interface is down and has no address
anyway in QEMU.

## Test changes

`test-qemu.sh` gained two probes, both reported as info-only to match the
existing convention for buses and WiFi:

- **WiFi IPC round trip**: greps for `^eth0 firmware MAC: ` in the guest output.
  Anchored so the echoed command line cannot match.
- **DWC2 probe reached controller**: greps for `dwc2 60080000.usb:`. This is the
  regression guard for the deferral above, since a re-added `resets` phandle
  makes the line vanish completely. It does not assert success, because in QEMU
  the probe legitimately ends at GSNPSID.

Stability was measured before deciding how hard to gate: 2 runs x 3 devices,
**5/5 true on both probes, 5/5 PASS**. Still info-only because 5 samples is thin
and the IPC probe has an inherent 8s timeout on a busy runner; promoting them to
gates is a reasonable follow-up once there is more history.

## Size accounting

| Image | Bytes |
|-------|-------|
| `linux` partition limit | 3,997,696 |
| xipImage, 7.2.8, USB on | 3,432,536 |
| headroom | 565,160 |
| xipImage, 7.2.5, no USB (last CI) | 2,982,608 |

The +449,928 delta is USB *and* 7.2.5 to 7.2.8 drift mixed together, so it is not
a clean measurement of the USB cost. The fragment's estimate was 150-250 KB. A
true A/B needs a build of 7.2.8 with the USB block removed from the fragment.

## What hardware validation needs to cover

Ordered by how likely each is to be wrong:

1. **DWC2 GSNPSID**. Confirm the controller reports a valid ID and the probe
   completes. This is the single unknown that QEMU cannot answer.
2. **The `usb_clk` gate.** With `resets` gone, the clock gate is the only enable
   left. If the block is still asleep, reads will return 0 exactly as in QEMU and
   the failure will look identical to the emulator. Check `clk: Disabling unused
   clocks` does not include `usb_clk`.
3. **DWC2 without a PHY.** The `phys` phandle is omitted because no mainline
   driver binds the ESP32-S3 PHY. Host mode may work off the ROM-bootloader PHY
   setup, or may not. This is the assumption most likely to need a real driver.
4. **Hot plug.** Nothing has ever seen a device attach.
5. **WiFi scan and association.** Needs an AP in range.

## Follow-ups, in priority order

1. A real `esp,esp32-reset` reset driver, which removes the DTS omission and is
   upstreamable.
2. An `esp,esp32s3-usb-phy` PHY driver, which removes the other omission and is
   the difference between "DWC2 probes" and "DWC2 works".
3. Reword the `wificfg scan` timeout message, which currently blames firmware
   that is present and correct.
4. A clean 7.2.8 build with the USB block disabled, to get a real A/B size number.
5. Consider gating the two new probes once stability history exists.
