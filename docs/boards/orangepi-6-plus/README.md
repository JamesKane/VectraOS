# Orange Pi 6 Plus (CIX P1 / Sky1)

A research pass (2026-10-16). Since D69 (2026-10-16) this is the first
board, V6's, and the CIX Sky1 is planned in `docs/hardware/support.tsv`;
D53 checks arm64's baseline against it. AbyssBSD now runs FreeBSD
16-CURRENT on this board through ACPI, from its NVMe, with the platform,
the GPU, the NPU and the video codec working. This file reads those
notes for what VectraOS would meet on the board. The same SoC is in the
Radxa Orion O6.

Facts come from the sources below and are marked with them. Facts marked
**(memory)** are not yet checked against a document or the machine; **On
the machine** lists what to read first. Code is not lifted from these
sources (D4). AbyssBSD's and Linux's drivers are read as hardware
documentation only (provenance.md).

| Source | Commit or date | Paths |
|---|---|---|
| AbyssBSD (`../AbyssBSD`) | `bfc0b05` (2026-10-09) | `docs/boards/orangepi-6-plus/README.md`, `gpu.md`, `npu.md`, `vpu.md` |
| croi's notes (this tree) | — | `docs/kernel/roadmap.md` "Review: board requirements (2026-10-09)", `design/boot.md` "Bring-up aids", `design/iommu.md` |

## The short version

- **The firmware is what the kernel already expects:** UEFI and complete
  SystemReady ACPI, written for an OS, not routed through Windows' PEP as
  on the Q8B. Power domains are ACPI power resources, clocks are AML
  methods calling SCMI, CPU performance is `_CPC`, idle is `_LPI`
  (AbyssBSD).
- **EL2 is ours:** no vendor hypervisor. UEFI enters at EL2 with VHE, and
  nothing polices the SMMUs (AbyssBSD). croi drops EL2 to EL1 already
  (`boot-smoke-el2`).
- **Most of its first-boot path exists in croi, tested in QEMU:** the
  DBG2 PL011 console, GICv3 with ITS, SMMUv3, PCIe ECAM, the SBSA
  watchdog's Sky1 refresh method, SVE state.
- **Two croi defaults are wrong here** and need board rules (D126,
  compiled in): the watchdog's refresh (done), and the SMMUs that
  firmware leaves on. See Bring-up hazards.
- **New drivers for the V3 link:** an RTL8126 driver in the net class (rge(3): DHCP works through it), and
  NVMe (which V6 needs anyway).

## CPU

- **12 cores, Armv9.2:** 4 Cortex-A720 up to 2.6 GHz, 4 A720 at 2.5 GHz, 4
  A520. PSCI 1.1 over SMC, PPTT, 6 frequency domains of 2 cores (AbyssBSD).
  FreeBSD found CPUs 0-1 and 6-11 to be the A720s and 2-5 the A520s.
- **Against D53's baseline** (`armv8.2-a+fp16+dotprod+rcpc`): met, from the
  cores' architecture (D53). **The crypto instructions are fitted**
  (FreeBSD's ID register decode, 2026-10-24): AES+PMULL, SHA1,
  SHA2+SHA512, SHA3, SM3, SM4, CRC32, and in SVE2 AES, SHA3, SM4 and
  BitPerm. Also PAC (QARMA3, FPAC), BTI, MTE3, I8MM, BF16, WFxT, AMUv1,
  MPAM, SPEv1p2 and PMUv3p7 (20 counters).
- **SVE:** present (AbyssBSD restores the vector length across core
  power-down). croi saves SVE and SME state with per-thread vector lengths
  (cpu.md, K3).
- **Capacity:** croi takes a core-type default until the power service sets
  it from `_CPC` (roadmap's review: AML stays in user space).

## Firmware and boot

- **UEFI 1.3 (2025-11-13), ACPI only:** APIC, GTDT, IORT, MCFG, PCCT, PPTT,
  SDEI, DBG2, CSRT, a DSDT and two SSDTs (AbyssBSD). DMI says "CIX Phecda
  Board", the reference design's name.
- **No SPCR.** DBG2 names COM2, an SBSA UART (`ARMH0011`, PL011) at
  `0x40d0000`. croi's loader takes SPCR, then DBG2, so it should fall
  through to it (boot.md; test `boot-dbg2-console`).
- **Serial header:** the 10-pin debug header is **3.3 V**, so a common
  USB-TTL adapter works (unlike the Q8B's 1.8 V). UART2 is pin 1 TX, pin 3
  RX, pin 5 GND: COM2, the firmware's and the kernel's log. UART4 (the
  power-management firmware's log), UART5 (the secure element) and UART6
  (POST codes) share the header (AbyssBSD).
- **GOP framebuffer:** 1920×1080 at `0x84800000` (AbyssBSD).
- **DSDT bug:** it names `I2C0.UXC0`–`UXC3`, which don't exist
  (`AE_NOT_FOUND` at load). V2's AML interpreter must tolerate it, as
  Linux and FreeBSD do.
- **Mainline Linux goes DT-first** for Sky1 (`acpi=off`), but the firmware
  provides no DTB (AbyssBSD). We follow the firmware's ACPI, as AbyssBSD does.

## Interrupts, timers, idle

- **GICv3 with ITS (GICv4.1), 512 SPIs** (AbyssBSD): an Arm **GIC-700
  r2p1** (GITS_IIDR `0x0402143b`), its ITS at `0xe050000` (GICD +
  0x40000, so its RAS records, GICT, are at `0xe030000`). Its ITS is
  not coherent with the CPUs' caches: tables and commands must be
  cleaned to memory. MADT order puts MPIDR `0xa00` first, so that core
  boots. **Arm erratum 2941627** applies (GIC-700 variants 0-2; it
  concerns deactivating SPIs): croi works around it as Linux does,
  keyed on GICD_IIDR (FreeBSD has none). Our distributor setup touches
  an unimplemented SPI block (`SYN_SPI_BLOCK`, block 30: harmless,
  recorded in GICT record 0).
- **PMU:** PPI 23, level, on every core. Firmware leaves `PMCR_EL0.LP`
  set.
- **Generic timer at 1 GHz** (FreeBSD's timecounter). It **stops in
  `_LPI`'s power-down states**, and the GTDT has no memory-mapped timer.
  The always-on timer is CIX's GPT (`CIXH1007`, 25 MHz), the one Linux
  broadcasts with (AbyssBSD). croi idles in WFI only until KP's idle
  governor exists, so its timers keep running. KP's "board timer such as
  the Sky1's GPT" is this device.
- **`_LPI` states:** LPI-0 WFI; LPI-1 core power-down (PSCI `0x10000`,
  360 µs exit); LPI-2 cluster power-down (`0x1010000`, 500 µs). The
  firmware leaves the context-lost flag clear on both power-down states,
  so read the PSCI state's type bit instead (AbyssBSD).
- **SBSA watchdog** (GTDT, architecture version 1): refresh frame
  `0x16008000`, control `0x16003000`. **A write to the refresh frame does
  not refresh it;** writing `WOR` does (AbyssBSD).

## IOMMU, PCIe and DMA

- **Two SMMUv3:** `0xb010000` for PCIe, and `0xb1b0000` for the display
  (DPU0/1), the NPU, AEU0 and others. The IORT has RMRs (AbyssBSD). The
  firmware leaves them enabled (roadmap K12d).
- **Memory type matters:** FreeBSD's SMMUv3 driver mapped DMA as Device
  memory, and the NPU ran ten times slower. Normal memory by the device's
  coherency fixed it: write-back if coherent, non-cacheable for the NPU
  (AbyssBSD). This is the BTI per-device memory type on croi's list
  ("Normal WB or Normal NC, never Device").
- **Event-queue interrupt storm:** reported on Linux for this board; a fix
  is at github.com/ErcinDedeoglu/orangepi-6plus-cix-sky1-smmu-fix (cited
  by AbyssBSD).
- **PCIe:** ECAM (MCFG), three `PNP0A08` root ports (CIX `1f6c:0001`).
  The generic ACPI host works (AbyssBSD).
- **NVMe:** Micron 2550 (`1344:5416`) with a host memory buffer, behind
  the SMMU; relaxed ordering off (AbyssBSD).
- **Ethernet:** two Realtek RTL8126 5 GbE (`10ec:8126`, rev 2) on PCIe
  (AbyssBSD). This is the board's V3-link NIC: a new net-class driver.
- **USB:** ten xHCI hosts, which firmware puts in host mode and describes
  as standard `PNP0D10`. The Cadence dual-role controllers behind them
  aren't needed for host mode (AbyssBSD).

## Power, clocks, thermal

- **SCMI v2.0, two transports** (AbyssBSD gpu.md):
  - **Over SMC** for power domains: SiP function `0xc2000001`, shared
    memory at `0x84380000`, to TF-A. croi's plan has an SMC resource
    scoped by function-ID range, because an OEN-scoped one (Zircon's)
    would grant every SiP call (roadmap's review).
  - **Over CIX mailboxes** for clocks and performance: ACPI `CIXHA006`,
    shared memory at the start of mailbox 6 (`0x06590000`, `CIXHA004`),
    doorbell at `+0x80`, polled; mailbox 7 (`0x065a0000`) carries the
    platform's messages. The AML's own SCMI agent (`\_SB.PMMX.CLK*`)
    answers NOT_FOUND for every clock, so use the agent Linux uses.
- **CPU frequency:** `_CPC` with the desired-performance register in
  SystemMemory (the SCMI fastchannel, e.g. `0x659009c`), delivered and
  reference counters from the AMU, perf 2520–8192 for 800–2600 MHz. The
  firmware rounds requests up to operating points (AbyssBSD). In croi this
  is the power service's job, and KP's frequency floor.
- **Thermal:** 13 ACPI thermal zones (`_TMP`), about 42 °C idle, passive
  from 85 °C, critical at 98 °C. The little cluster has no zone, and
  critical shutdown is untested (AbyssBSD). All AML, so V2's interpreter
  and the power service handle it. Until then nothing in VectraOS cools
  this board except the firmware.

## GPU and display

- **Immortalis-G720 MC10:** GPU_ID `0xc870` (architecture 12.8), 10 shader
  cores, a CSF GPU whose firmware (`mali_csffw.bin`, interface v3.13)
  schedules command streams. ACPI `CIXH5000`. It has its own MMU, not an
  SMMU (AbyssBSD gpu.md). The firmware blob is part of the hardware; its
  provenance would go in `firmware/README.md`, as the Q8B's does.
- **Bring-up order is strict:** SCMI power domain 21 over SMC, then the
  `gpu_top`/`gpu_core` clocks over the mailbox, then the power resource's
  `_ON`, then the reset at `0x16000000`, then Q-channel gating. A GPU
  register read before all five raises an SError, and the board then
  needs a power cycle. Resource 0 (`0x15000000`) is CIX's RCSU, not the
  GPU; only `0x218` and `0x304` may be read (AbyssBSD).
- **Coherency:** the DSDT says coherent (`_CCA` 1), but CIX's kernel runs
  the GPU on ACE-Lite with non-cacheable mappings, because the display
  controller doesn't snoop (AbyssBSD).
- **DVFS:** SCMI performance domain 0, 72–1000 MHz (AbyssBSD).
- **Against D62's floor** (buffer device address, bindless descriptors in
  GPU memory, timeline semaphores, dynamic rendering): Mesa's panvk
  exposes all four on Valhall and later, and descriptors live in memory
  **(memory)**. To be checked against Arm's architecture documentation
  before D62's board list names it.
- **Display:** five Arm China Linlon DP controllers (`CIXH5010`, komeda
  under Linux) and a Trilinear DP transmitter. HDMI comes from DP-4
  through a PS185 that gives no EDID (AbyssBSD). V5 would start on the
  GOP framebuffer, as on every board.

## Accelerators and the rest

- **NPU: Arm China Zhouyi X2,** 30 TOPS (`CIXH4000`, `CIXH4010` ×3): one
  cluster of three cores, 4 MB of GM, DVFS through SCMI performance domain
  8. CIX's user stack (`libnoe`, ONNX Runtime's provider) is binary, which
  D4 rules out on the device. Arm China's user-mode driver 4.1.0 is open
  source (AbyssBSD npu.md). A first-party V8 backend would need the
  command format documented or read from that source as reference.
- **Video codec:** Arm Mali-V (Linlon v5276), four cores, run by firmware
  (`CIXH3010`; AbyssBSD vpu.md).
- **Audio:** HDA (`CIXH6020`, `0x70c0000`) with a Realtek ALC269VC; I2S
  ×4 and an audio DSP unused (AbyssBSD).
- **Also on the board:** a TPM (`MSFT0101`), OP-TEE (`CIXHA022`), DMA-350
  controllers, Cadence I²C ×7 and GPIO, an RX8900 RTC. UEFI's runtime
  clock works (FreeBSD's `efirtc`).

## Bring-up hazards for croi

1. **The watchdog reset the board about 30 s after boot** (fixed): the
   refresh frame doesn't refresh on the Sky1. Its board rule (D126)
   refreshes through WOR; a boot ran 100 s without a reset
   (2026-10-24).
2. **The SMMUs** (2026-10-24). Firmware leaves the PCIe unit
   (`0x0B010000`) enabled and the display unit (`0x0B1B0000`) disabled.
   The IORT routes all 65,536 PCIe requester ids one to one into the
   PCIe unit (a 4 MiB linear stream table), and named components (DPU0-4,
   AEU0-4, NPU0, ISPM, CBD0/2) into the display unit by single stream
   ids up to 0x22. One RMR: the GOP framebuffer (`0x84800000`, 8 MiB)
   for ten of the display unit's streams. A board rule (D126) takes over
   the PCIe unit; the display unit, off from firmware, comes up with
   bypass entries for every stream the IORT names, and the RMR is
   honored: a claimed display stream keeps the framebuffer mapped, a
   released one goes back to bypass. Translating a display controller's
   own DMA (named components' BTIs) waits for the display driver.
3. **The GPU's power-up order** (above): getting it wrong costs an SError
   and a power cycle. croi panics on any kernel SError and doesn't yet
   deliver one to the faulting process. The GPU driver's first probe
   should follow AbyssBSD's order exactly.

## Against the Q8B

What each board needs before V3's link runs on it:

| Need | Orange Pi 6 Plus (first board since D69; V6 since D76) | Radxa Dragon Q8B (V8 since D69) |
|---|---|---|
| Console | PL011 through DBG2: in croi, tested in QEMU | Qualcomm GENI UART: written ahead in V3, model test only |
| Serial adapter | 3.3 V | 1.8 V |
| EL2 | ours | Qualcomm's hypervisor |
| SMMU | board rule to take over firmware-enabled units, with RMRs | leave alone: policed by the hypervisor |
| Watchdog | board rule (WOR refresh), or off | not read for this table |
| Network | RTL8126: new driver | TC956x (XGMAC2, XPCS, QCA8081): new driver, DMA offset `0x10_0000_0000` |
| Power and clocks | SCMI, `_CPC`, `_LPI`: standard, AML | Windows PEP, `qcom-gcc` |

On paper the Orange Pi 6 Plus is the shorter path to V3's exit on
hardware. When this pass was written, D5 made the Q8B the first board;
D69 has since made this board the first (V6 since D76) and moved the Q8B to V8.

## On the machine

Answered (2026-10-24): the ID registers (CPU, above); the GIC's
revision (GIC-700 r2p1, so erratum 2941627 applies); the loader finds
DBG2's COM2 by itself, no `loader.console=dbg2`; the RTL8126s are chip
revision RTL8126_2 (`0x64a00000`, PCI rev 1), `rge0` the cabled one.

Still to read:
- The RTL8126's PHY, against the Linux and FreeBSD drivers.
- Whether a fan is fitted and controllable, before any thermal test.

## Booting VectraOS on it

The board keeps FreeBSD (AbyssBSD's branch) on its NVMe as its default
boot entry; ssh as `jkane`, root by `su`. Our loader is `\EFI\vectra\BOOTAA64.EFI` on
the ESP (`nda0p1`), with `\croi\kernel.elf`, `bootfs.img` and `cmdline`
beside it, under its own boot entry, which is never in BootOrder: a boot
sets it as the one-shot BootNext (`efibootmgr -n -b <entry>`) and
reboots, so any reset comes back to FreeBSD. It boots as production
does unless `croi.test=` names tests (D125): `croi.test=boot,drivers`
runs the early checks and the drivers suite, `croi.test=all`
everything. `userboot.next=bin/irq-test` takes uart0's interrupt (328)
in loopback from user mode. With `croi.halt_on_panic=false` a panic resets the board;
a hang before the watchdog starts needs a power cycle. COM2 reaches the host through an
FTDI adapter at 115200 8N1.

The board's own image is `build/arm64/esp-board` (`cmake --build
build/arm64 --target esp-board`): every service, the console on the
framebuffer among them, without the test programs, the launcher's QEMU
test, or fs and the shell (they wait for a virtio disk), run until
`bin/board-test` ends. board-test waits for devmgr, checks every bound
driver runs with its DMA on an IOMMU, that ether0's link comes up and
`net` takes an address by DHCP, prints each driver's status, and ends
within 90 s; the image then reboots into FreeBSD. Its last line is
`board-test: passed` or `board-test: FAILED, <n> checks`. boot-board runs
the same image in QEMU. Add `croi.test=kernel` to its cmdline for the
kernel's self-tests first.
