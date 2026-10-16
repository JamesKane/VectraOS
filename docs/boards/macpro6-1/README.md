# Mac Pro (Late 2013, MacPro6,1), dual FirePro D700

The amd64 baseline machine (D52) and the desktop track's first discrete
GPUs (D62, D63). The test unit is the dual D700 model. Its CPU and both
GPUs share one thermal core and one fan, and it overheats unless power and
fan management are close to flawless. Thermal safety (below) comes before
everything else on this machine.

Facts read from other trees and pages are marked with their source. Facts
marked **(memory)** are not yet checked against a document or the machine;
**On the machine** lists what bring-up must read first. Code is not lifted
from these sources (D4); Linux is read as hardware documentation only
(provenance.md).

| Source | Commit or date | Paths |
|---|---|---|
| Linux (`../linux`) | `24a19b953e2a` (2026-10-11) | `drivers/hwmon/applesmc.c`, `drivers/gpu/drm/amd/pm/legacy-dpm/si_dpm.c`, `drivers/gpu/drm/amd/amdgpu/amdgpu_bios.c`, `gfx_v6_0.c` and siblings (firmware names) |
| digital951/D700macpro (GPL-2.0, read only) | 2026-10 | README: the D700s' stuck clocks and VBIOS selection |
| CrystalIDEA, "Optimizing thermals on Mac Pro 2013" | blog | the SMC's fan curve under macOS |
| AbyssBSD (`../AbyssBSD`) | `bfc0b05` (2026-10-09) | `desktop/docs/PHASE4.md` (P4.0, §6.2–6.3), `PLAN.md`, `HANDOFF.md` §2.49, `desktop/abyss/mk/live-image.sh`, `desktop/de/install/Steps.swift` |
| FreeBSD (`../freebsd-src`) | `fe90f180047b` (2026-10-13) | `sys/dev/asmc/asmc.c`, `asmcmmio.c` |

## What AbyssBSD's boot shows

AbyssBSD booted FreeBSD's installer on this machine on 2026-09-05, then
moved its desktop bring-up to an i7-12700KF with an RX 6750 XT the same
day. The Mac Pro is now the second row of its test matrix (PHASE4 §1.1).
What it found:
- **Apple's EFI lists a USB stick only if the ESP is FAT16 with media
  descriptor `0xF8`.** makefs's default, FAT32 with `0xF0` (the floppy
  byte), is not listed at all. makefs takes the descriptor in decimal
  only (`248`) (PHASE4 P4.0, HANDOFF §2.49). FAT16 is legal for a
  removable ESP on any firmware, and the MSI board's ordinary UEFI read it
  too. When `vx` writes a stick image, it writes this.
- **A PCIe power-fault storm.** The internal PCIe bridges report a
  power-fault bit that never clears, so FreeBSD's pcib(4) logs "pcib26:
  Power Fault Detected" in a loop and buries the console. FreeBSD's fix
  is to turn off PCIe native hotplug for the whole machine
  (`hw.pci.enable_pcie_hp="0"`), applied only when SMBIOS says MacPro6,1
  (`live-image.sh`, `Steps.swift`). For our PCI driver (V2 item 7): don't
  enable hotplug interrupts on a slot nobody needs hotplug on, and a
  latched power fault must be reported once and masked, never re-armed in
  a loop. Which bridges these are is read on the machine (likely the
  Thunderbolt 2 ports' bridges, memory).
- **The D700s were never driven.** Whether FreeBSD's amdgpu binds GCN 1.0
  with `si_support=1` was never answered on the machine. AbyssBSD's
  fallbacks are amdgpu, then radeonkms, then running headless (PHASE4
  §6.2), and its multi-GPU handling is deferred with the Mac Pro (§6.3).
  The installer ran on the EFI framebuffer.
- **Nothing in AbyssBSD manages its heat.** No fan, SMC or thermal code in
  the desktop tree or its docs. On FreeBSD the SMC's automatic curve and
  the firmware's GPU clocks were the only protection, for boots of unknown
  length. So AbyssBSD's boot is evidence about firmware and PCIe, not
  about thermals: D700macpro's 10-second test is still the only GPU
  temperature on record.
- **Also:** Apple NVMe, Thunderbolt 2 and Broadcom Wi-Fi (no driver;
  AbyssBSD's installer is offline-first for this machine) (PLAN.md).

## CPU

Xeon E5 v2 (Ivy Bridge-EP). The SIMD baseline is D52's
`-march=ivybridge`. P-states come from ACPI; Ivy Bridge has no HWP
(memory).

## GPUs: two FirePro D700

- **Tahiti XT, GCN 1.0** (Linux: `CHIP_TAHITI`, GFX6, "Southern Islands").
  6 GB GDDR5 each (memory).
- **One drives the displays; the other has no outputs** (D700macpro calls
  them the display GPU and the other GPU). So a frame rendered on the
  second GPU must reach the first: D56's multi-GPU case on one machine.
- **Against D62's floor** (D63): GPU pointers through `addr64` buffer
  instructions or synthesized descriptors, since GCN 1.0 has no FLAT
  instructions (LLVM's AMDGPU docs: FLAT is Sea Islands and later);
  descriptors always loaded from memory by scalar loads, so heaps are
  native (memory); no DCC (GCN 3 and later), while CMASK, FMASK and HTILE
  still need decompression on some transitions (memory). AMD published
  the Southern Islands ISA manual (memory), which a driver of ours needs
  under principle 28.
- **VRAM is probably not CPU-writable in full:** no resizable BAR on
  Tahiti (memory), which makes this D56's "discrete, without BAR" machine.
- **Video BIOS from ACPI:** the PowerPlay tables come from the VBIOS, and
  on the Mac the VBIOS images are in the ACPI VFCT table. Linux matches an
  image to a GPU by vendor and device ID, then PCI slot and function, then
  bus number, falling back to identity when the bus differs
  (`amdgpu_acpi_vfct_match`). The two D700s are the same device, so that
  fallback can hand both GPUs the first image (`113-C3861XA-028` and
  `113-C3861XB-028`, D700macpro): match the exact bus first, and refuse
  rather than guess when two images could match.
- **Firmware** (Linux's `MODULE_FIRMWARE`): `tahiti_pfp`, `_me`, `_ce`,
  `_rlc`, `_mc` and `_smc`. Firmware is part of the hardware; its
  provenance goes in `firmware/README.md` as the Q8B's does.

## Power and thermals

Three controllers, one heatsink.

### The Apple SMC: the fan

- **Interface** (`applesmc.c`): data port `0x300`, command port `0x304`;
  four-character keys. Linux finds it by SMBIOS (`DMI_PRODUCT_NAME`
  "MacPro"). We are ACPI-only, so the DSDT's description of the SMC is
  what we use (an `APP0001` device with those ports, memory; on the
  machine).
- **Fan keys:** `FNum` (count), `F0Ac` actual speed, `F0Mn` minimum (rw),
  `F0Mx` maximum, `F0Sf` safe speed (not on every model), `F0Tg` target
  (rw only in manual mode), `FS! ` the manual-mode bitmask.
- **Its automatic curve reacts late.** CrystalIDEA measured the fan
  starting to climb only once temperatures passed 80 °C, and a fixed
  1,500 RPM ran about 9 °C cooler. Linux's `mbpfan` reads only CPU
  temperatures.
- **One report** (iFixit) has a GPU die sensor reading 0 and the SMC
  running the fan high in response. Treat a missing sensor as hot.
- **FreeBSD's `asmc`** attaches to ACPI `APP0001` and finds the fans and
  sensors by their keys, not from a model table. It leaves the fans in
  automatic mode unless asked: manual mode is a sysctl, through the `FS! `
  bitmask on Macs before the T2. Its MMIO backend is for T2 Macs; this
  one uses the ports (`asmc.c`, `asmcmmio.c`).

### The GPUs' own SMC: clocks, voltage, throttling

- Each D700's DPM runs on its own microcontroller (`tahiti_smc`),
  configured from the VBIOS's PowerPlay tables. Without DPM the GPU stays
  at its boot clocks, which is the thermally safe state.
- **The HARDWAREDC trap.** The D700s' PowerPlay tables set
  `ATOM_PP_PLATFORM_CAP_HARDWAREDC` (AC/DC switching signalled by GPIO)
  and carry a 300 MHz core, 150 MHz memory DC ("battery") state. Linux
  set `PPSMC_SYSTEMFLAG_GPIO_DC` for any such GPU, so the D700s never
  left the DC state. The fix (Timur Kristóf, 2026-09-23) sets it only for
  mobile GPUs (`AMD_IS_MOBILITY`, `si_dpm.c`); after it, D700macpro saw
  850 MHz core and 1,370 MHz memory. A desktop GPU's DC capability is
  ignored.
- **Thermal protection:** `CG_THERMAL_CTRL`'s DPM event source and
  `CG_THERMAL_INT`'s high and low interrupts (`si_dpm.c`). The GPU's own
  throttle stays enabled whatever else runs.
- **Evidence so far is thin:** D700macpro's peak was 79 °C in a
  10-second test. No long-load result is published.

### The CPU

ACPI P-states and C-states, under the same power service.

## Rules for this machine (D63)

1. The SMC stays on its automatic curve. VectraOS writes only `F0Mn`,
   the minimum, so if the power service or the kernel dies, the SMC still
   rules above the floor: the failure is louder, not hotter. Manual mode
   (`FS! `, `F0Tg`) needs a decision of its own, with a watchdog that
   hands the fan back.
2. One power service holds the combined budget for the CPU and both GPUs.
3. No D700 runs above its boot clocks until the soak budgets pass.
4. A GPU whose temperature can't be read is treated as at its limit.

## On the machine

Read before any driver work, into this file:
- `lspci -vv`: each D700's device ID, its bus, the BAR sizes, and the
  PCIe link width and speed.
- The DSDT and the VFCT table (`acpidump`): the SMC's device and ports,
  and each VBIOS image's bus, slot and function.
- The SMC's key list (`applesmc` under Linux): which `T…` keys are the
  GPU dies, VRAM and the thermal core, and whether `F0Sf` exists.
- A 30-minute full-load run under Linux with D700macpro's fixes, logging
  the GPU and CPU temperatures and the fan speed. This is the baseline our
  soak budgets are judged against.
- Which bridges latch the power fault (`pcib26` under FreeBSD): their
  bus numbers, what sits behind them, and their slot capabilities.
