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
- **NVMe:** a Crucial P3 500 GB (`CT500P3SSD8`, `1344:5416`, Micron's), FreeBSD's, with a host memory buffer, behind
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
  firmware rounds requests up to operating points (AbyssBSD). power(8)
  (D130) writes each CPU's highest level at boot: 12 CPUs in 5 `_PSD`
  domains, every register in mailbox 6's page, 1800-2600 MHz at their
  highest levels. Firmware's own level isn't the lowest: power's chain
  of dependent multiplies runs 1.28 times faster at the highest (5.5 ms
  to 4.3 ms). KP's frequency floor and a governor are still to come.
- **Thermal:** 13 ACPI thermal zones (`_TMP`), about 42 °C idle, passive
  from 85 °C, critical at 98 °C. The little cluster has no zone, and
  critical shutdown is untested (AbyssBSD). All AML: devmgr evaluates
  `_TMP` (through the AML's own SCMI agent, `\_SB.PMMX`, mailbox
  `0x065D0000`) and power(8) steps the CPUs down at a passive trip and
  powers off at a critical one. First reading under VectraOS: 43-49 °C
  at idle. Neither trip has been reached by heat yet.

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
- **Display:** five Arm China Linlon-D6 engines, Arm's Mali-D71 (`CIXH5010`,
  komeda under Linux), each with a Trilinear DP transmitter
  (`CIXH502F`, `\_SB_.DP00`-`DP04`, `_STA` a firmware variable, no
  power resource: in the engine's power domain). HDMI comes from DP-4
  through a PS185, a DisplayPort-to-HDMI branch that passes the
  monitor's EDID over AUX (dptx(3), 2026-10-29: DPCD 1.2, HBR2 x4 at
  most, a branch with one sink; firmware trained HBR x4; the monitor a
  DELL ST2421L, 1920x1080 at 60 Hz preferred). AbyssBSD's "no EDID"
  never drove AUX. NeoVectra's ADR-0027 is the design; linlon(3) is
  its first step, D146 the rest.
  - **What firmware leaves on DP-4** (read 2026-10-29): the combo PHY
    (`\_SB_.UCP3`, `CIXH2033`, `0x09180000`, `default_conf` 2, its
    `pclk` SCMI clock 119) in DisplayPort-only mode (lane map
    `0x51D9`), PLL1 at HBR exactly as the vendor's rate table has it;
    its drive registers are its own, not the vendor's table (txcc
    `0x2A84`, driver `0x00B3`, margin `0x07`, post-cursor `0x20` on
    every lane). DP04's `_CRS`: core, dsc, PHY interface
    (`0x1422FF00`), RCSU (`0x14210000`, 0x304); its `_DSD`'s `dp_phy`
    is `UCP3.UDPP`; `CLKT` vid_clk0 57, vid_clk1 58, apb_clk 63;
    `RSTL` dp_reset (RST0 28). The stream is 1080p60 with the MSA's
    polarity positive (as the mode) but the DPU's BS sync bits clear
    (inverted, as the vendor's driver drives them); the secondary
    stream off; BS programmed line 0, prefetch 4. DPU4's `CLKT`: aclk
    48, `pipeline@0` 41, `pipeline@1` 42; `RSTL` rcsu_reset (114) and
    ip_reset (23, S5 `0x400` bit 20); `aclk_freq_fixed` 800 MHz. SCMI
    sets pipeline 0's clock to 148.5, 74.25 and 25.175 MHz exactly.
  - **The DSDT** (2026-10-24): engine *n*'s registers at
    `0x14010000 + n × 0x70000`, 0x20000 bytes, its RCSU 0x10000 below;
    GSIVs 348, 350, 352, 354, 356; `_CCA` 0. `_STA` is firmware's
    variable 0x23 + *n*. Each has a power resource whose `_STA` is bit 1
    of its RCSU's `0x210`, and whose `_ON` sets `0xFFE` there and runs
    memory repair (DMRP), as the GPU's does. `CLKT`: `aclk` (SCMI
    0x2C for DPU0) and a pixel clock for each pipeline (0x21, 0x22).
    `RSTL`: `rcsu_reset` and `ip_reset` in RST0. `_DSD`'s
    `enabled_by_gop` is 0 on all five, so it doesn't say which output
    firmware lit: the power resources' `_STA` does, before any engine
    register is read (an unpowered engine's read would fault).
    DPU2's AML logs its power state (`CIX Debug: DPU2 get current
    state=…088C0001`, bit 1 clear: off at boot).
  - **What firmware leaves** (linlon(3), 2026-10-24): only DPU4, the
    HDMI engine, is powered; DPU2's AML says so for itself above.
    DPU4's `CORE_ID` is `0x00600000` (a Linlon-D6 r0p0, komeda's
    `LINLONDP_D6_PRODUCT_ID`), `ARCH_ID` `0x44500000`, 2 pipelines and
    39 blocks. Its GCU is in `DO0_ACTIVE` (status `0x80000003`);
    pipeline 0's layer 0 scans out the GOP framebuffer, `0x84800000`,
    1920×1080 XRGB8888, stride 7680; the timing controller runs CEA
    1080p (2200×1125, h 88/44/148, v 4/5/36), and the output unit's
    line interrupt counts 60.0 Hz. The GCU's configuration-valid
    interrupt arrives at each flip (GSIV 356).
  - **The IORT** names five stream ids for DPU0 (0, 1, 3, 4, 5) into
    the display SMMU, and engine *n* has 6n, 6n+1 and 6n+3 to 6n+5 (6n+2
    is its AFBC encoder's; `linlon-dpu/08 §8.2.1`). They stay in bypass,
    the framebuffer's RMR kept, until a driver's BTI claims them: devmgr
    gives each engine's driver a BTI for its named component (D146), and
    linlon scans out its clients' images through it, with no copy.

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
   released one goes back to bypass. A display engine's own DMA is
   translated through its named component's BTI (D146).
3. **The GPU's power-up order** (above): getting it wrong costs an SError
   and a power cycle. croi panics on any kernel SError and doesn't yet
   deliver one to the faulting process. mali(3)'s first probe follows
   AbyssBSD's order exactly, each step through its owner: scmi(3) for
   the domain and clocks, devmgr for `_ON`, the reset controller devmgr
   grants from RSTL (2026-10-24: GPU_ID `0xc8700008`, every feature
   register as Linux reads it). Two findings on the way:
   - Firmware leaves `PPRS._STA`'s bit 12 set with the rest of `_ON`
     undone (RCSU `0x218` reads `0x03e77001`, the Q-channel bits
     `0xFFC` clear). An OS that trusts `_STA` skips `_ON` and the memory
     repair; devmgr runs `_ON` on first use, as Linux does (`0x03e77ffd`
     after).
   - **Don't peek at the RCSU or the reset controller from FreeBSD**
     through an mmap of `/dev/mem`: a read-only peek of RCSU `0x218`,
     reset `0x400`/`0x800` and TF-A's SCMI memory hung the board until a
     power cycle (2026-10-24). Which read did it is unknown; FreeBSD's
     mapping of a non-RAM address may be cacheable, and a speculative
     fill near `0x218` would touch RCSU registers that stall the bus.
     VectraOS maps them as Device memory and reads all three safely.

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
build/arm64 --target esp-board`): every service, the console and its
shell on the framebuffer among them, without the test programs or the
launcher's QEMU test, run until
`bin/board-test` ends. board-test waits for devmgr, checks every bound
driver runs with its DMA on an IOMMU, that ether0's link comes up and
`net` takes an address by DHCP, prints each driver's status, and ends
within 90 s; the image then reboots into FreeBSD. Its last line is
`board-test: passed` or `board-test: FAILED, <n> checks`. fs keeps its
volume on the Samsung 990 PRO, nda1 in FreeBSD and `/dev/sdN1` here, in its partition named `taisce` (below, "The disks and the boot entry, 2026-11-20"). boot-board runs
the same image in QEMU. Add `croi.test=kernel` to its cmdline for the
kernel's self-tests first.

The bring-up link: deploy `build/arm64/esp-board-cpu` once (the cpu
image, with a cpu server for this terminal's key, `vx cpu-keys`), then
from the dev machine `vx cpu 192.168.0.19`, and `vx remote boot arm64
--image board-cpu 192.168.0.19` to warm-boot it into a new build. The
board stays in VectraOS until reset; a reset returns it to FreeBSD.

The desktop: `build/arm64/esp-board-desktop` is the cpu image with
Radharc, rio and its apps, on linlon(3)'s HDMI output (1080p60, CPU
composited). The keyboard and mouse on USB1's Terminus hub are a
Microdia 0c45:0133 keyboard and a Corsair 1b1c:1bac mouse; the mouse
claims the boot protocol (interface 0, subclass 1, protocol 2) but
sends its own reports after SET_PROTOCOL(0): five button bits and three
of padding, 16-bit X and Y, a wheel byte and five vendor bytes, 11
bytes in all (its report descriptor, read in FreeBSD with `usbconfig
-d ugen7.3 do_request 0x81 0x06 0x2200 0 0x200`). Read as a boot
report, the pointer only went up. xhci(3) now reads mice by their
report descriptors.

The desktop's budgets, judged on the board (2026-10-25, main past
3b0d9ee, CPPC's highest level, Neon Tab: the owner's choice, kept in
/data/Settings; `desktop-budgets.drive` with drive(1), and compose-cpu
started through the launcher):
`terminal.key_draw` 136 us median, 474 us most (< 1 ms);
`terminal.key_glass` 1 frame (<= 2); `desktop.cold_start` 41.4, 44.7 and
11.3 ms (< 50 ms; the first two cold, close to the limit);
`ui.compose_cpu.1080p` 2.57 ms, Neon Tab 2.56 ms (< 4 ms). A second boot
(main 35cb192), both themes: key_draw 366 us Neon Tab, 156 us Platinum
Indigo; key_glass 1 frame; cold_start 27-34 ms, except minimal's first
start right after `load platinum-indigo`, 56.2 ms (a miss); compose_cpu
2.58-2.59 ms; and Radharc's own `theme switch` 3 frames into Platinum
Indigo (theme.switch, <= 2: a miss) and 2 back. At main 7a49d61, with
the D129 session's desk-grid fix (34e84b8): theme.switch 1-2 frames each
way over five readings, and desktop.cold_start 27-37 ms with no switch
running (the misses were starts during a switch). Not yet on the board:
the workspace mode switch, the idle desktop's wakeups and RSS.

The workspace mode switch and the idle desktop (2026-10-25, a warm
boot of the desktop image): `echo start twenty >/svc/launcher/ctl` opens
twenty windows, and drive(1)'s `modeswitch 6` gave desktop.mode_switch 1
frame for each of six switches (limit 2). Then, 40 s with no input and
Radharc `idle`, /proc/sysstat read 60 s apart counted 5,582 wakeups
(limit 0): CPU 0 took all 944 device interrupts; 850 timer interrupts
and 3,788 rescheduling IPIs across the twelve. A 10 s trace (`vx remote
trace arm64 ... 10 hz 1 sched irq`) put them on devmgr's AML thread,
woken by its timers about 16 times a second as power reads the thirteen
thermal zones each second, power itself, and rge's interrupt thread
(about 6 a second, MSI 8194, the LAN's traffic) with net; Radharc and
the apps woke none. `/svc/launcher/memory` summed 361 MiB resident
(limit 256 MiB): fs 253 MiB, devmgr 35, Radharc 32, Tracker 13, rio 7,
Deskbar 5.5. fs's is the allocator's six bitmaps of the 931 GiB volume.

Boot budgets (2026-10-25, the desktop image; performance.md): a cold
boot from FreeBSD's reboot gave the loader 169 ms, userboot at 221 ms,
boot.console 300 ms (limit 100 ms: a miss), boot.desktop 2.45 s (limit
3 s); three warm boots by `vx remote boot arm64 --image board-desktop`
gave remote.warmboot.board 5.02, 5.02 and 5.04 s (limit 5 s: a miss) and
boot.desktop 2.29 s. In a warm boot the cpu server listens at 1.30 s, but
rge's reset drops the link (0.38 s) and it is up again at 3.32 s, 1000
Mb/s, and DHCP's address follows its first retry, 1 s later. Firmware's
time can't be read after a reset: the generic counter isn't reset with
the SoC (boot.firmware said 3179 s, the time since the last power cut).
rge now keeps a link it finds up as it would leave it (rge(3)): three
warm boots came back in 2.03, 2.11 and 2.34 s, the link up at 0.38 s and
the address at 1.38 s. Of the kernel's 200 ms to userboot in a warm boot,
119 ms is waiting on the PL011 at 115200 baud for the banner (a temporary
count, not kept). With the banner buffered for the debuglog's dumper on
the last CPU, and the console drawing no row it shows blank already,
three warm boots gave userboot at 81 ms, boot.console 118 ms (limit
100 ms: a miss still; 14 ms of it mapping and clearing the screen), and
boot.desktop 2.58-2.66 s.

Power cuts (2026-10-25, crash-test(8) on /data, the 990 PRO): three cuts
mid-run, each verified on the next boot with fs's --check: the last
durable mark printed before each cut was 1280, 2592 and 11240, and the
whole files found 1281, 2592 and 11240, none wrong; each check passed
(1295, 2605 and 11253 nodes; 1.1, 2.5 and 10.9 s). The 11 s check first
outran the launcher's 5 s wait for fs's export, which ended the boot:
the check now runs on the volume's thread after fs answers.

### The disks and the boot entry, 2026-11-20

The board was set up again since V6, and what follows replaces the
layout above where they differ.

- **The disks:** nda0, the Crucial P3, holds FreeBSD's root
  (`/dev/gpt/rootfs`) and the ESP our loader is on (`nda0p1`:
  `\EFI\vectra\BOOTAA64.EFI`, `\croi\kernel.elf`, `bootfs.img`,
  `cmdline`; the previous build kept beside them as `croi.20261031`
  and `BOOTAA64.EFI.20261031`). nda1, the 990 PRO, holds AbyssBSD's
  partitions, `vectraesp` and `vectrastore` (another system's, left
  alone), and since 2026-11-20 `nda1p7`, 64 GiB, named `taisce` with
  Taisce's type (`4b7e1c5a-3d0e-9a4f-8c21-560bd739e412`), its first and
  last MiB zeroed: fs formats it at its first boot. 64 GiB keeps fs's
  bitmaps small (the 931 GiB volume's cost 253 MiB resident).
- **The boot entry:** `Boot000A VectraOS`, on `nda0p1`, never in
  BootOrder. FreeBSD's `efibootmgr -c` puts a new entry first in
  BootOrder, so the order is set back after it. A boot is `efibootmgr
  -n -b 000A` and a reboot, as root (passwordless `su` on this image).
- **The console** is this Mac's `/dev/cu.usbserial-ABSCDIMD` (COM2's
  FTDI adapter, 115200 8N1), one reader at a time; start the capture
  before the boot.
- **A board image built on the Mac** has no rc: rc is a tier 1
  program, and the Mac has no tier 1 toolchain. Its cpu server then
  answers but can't start a session (`can't start the session's
  program`), so neither `vx cpu` nor `vx remote boot` reach it, and
  only a power cycle brings the board back. While a build is being
  tried, add `userboot.shutdown=reboot` to the ESP's `cmdline`: a
  launcher that exits then reboots the board into FreeBSD.
- **First boot of the I2C wave** (2026-11-20, `658ff03`): devmgr bound
  41 devices; cdns-gpio(3) brought up all seven GPIO controllers, their
  line counts from `ngpios` (32, 32, 32, 17, 32, 10, 10); cdns-i2c(3)
  all seven I2C controllers (I2C6 is disabled), each input clock read
  through scmi(3) at 200 MHz; rx8900(3) read `2026-11-20T15:24:02Z` at
  0x32 on I2C3, within seconds of UTC (flags AF and UF set, VLF clear),
  and the time service set UTC from it. The five boots before faulted
  in devmgr on arm64's short-String miscompile (CLAUDE.md): a cell's
  text in `DeviceLink.summary`, made in a closure (` 50`, its top byte
  0xe3 read as 0x83), which a backtrace added to the kernel's report of
  a user fault found. The provider paths and property words made in a
  closure, and the provider lookups, were rewritten on the way.
- **One owner a register page, on the board** (2026-11-20, `e476486`,
  board-test, 73 checks passed, none failed): devmgr granted every
  driver's registers exclusively by the page and listed no page in two
  hosts; sky1-reset(3) served both reset controllers, mali(3) pulsing
  `gpu_reset` and linlon(3) DPU4's `ip_reset` through it; power(8) set
  all 12 CPUs to their highest level through scmi(3) (6.2 ms to 4.5 ms
  on its chain, as before); mali's GPU powered up and its GPU_ID read
  with no SError, its BTI passthrough (`own-mmu`) and its coherence the
  record's. The first boot of it failed mali's power resource: its `_ON`
  writes the GPU's RCSU, a page mali holds, and devmgr's second resource
  on it was refused; devmgr now maps a page it granted through its own
  copy of that grant. With `croi.watchdog_limit=300` and board-test's
  reboot the board came back to FreeBSD by itself.
- **Supply leases, the GPU powered off and on** (2026-11-20, `39ceed4`,
  board-test, 74 checks passed, none failed): devmgr powered the G720 up
  before mali started (SCMI domain 21, gpu_clk_core and gpu_clk_stacks,
  `_ON`, gpu_reset pulsed for 20 µs) and mali kept only Q-channel gating
  and its probe; `power mali-acpi-_SB_.GPU_ off` ended its supplies, mali
  released (`supply ending: releasing`) and devmgr cut in reverse, and
  `on` powered it up again and a new mali read the same GPU_ID, with no
  SError and the console drawing throughout. On the way: pulsing every
  reset in the GPU's RSTL cleared its RCSU after `_ON` and the GPU's
  secure accesses then raised an SError (the record now names
  `gpu_reset` alone, `power-resets`), and a restarted host's grants were
  refused beside the old ones until devmgr dropped them with the host.
- **B2's exit, the G720 off and on under a running desktop** (2026-11-20,
  `27ae6ce`, the desktop image built on brimstone with tier 1): with
  Radharc up (desktop at 1024 ms, four windows), a cpu session from
  brimstone wrote `power mali-acpi-_SB_.GPU_ off` and `on` to
  `/mnt/devmgr/ctl`: mali released at the supply's end, devmgr cut and
  then powered the GPU up again, a new mali read the same GPU_ID, and
  Radharc missed no frame; no SError, and `reboot` from the session
  brought the board back to FreeBSD. Images with rc (cpu, desktop) are
  built on brimstone, whose tier 1 toolchain builds in about 20 minutes,
  and driven from there: `vx cpu -k 50ced1f1… -c '…' 192.168.0.19`, since
  the image carries brimstone's terminal key.
- **Firmware for devices and a run that ends itself** (2026-11-20,
  `esp-board-wedge` built on the Mac, the backlog wave: D164, B7, B4,
  B8): board-test passed its 74 checks, the GPU powered off and on as
  before. mali(3) read its CSF image through devmgr's per-host
  `/lib/firmware` (`firmware 307200 bytes, first word 0xc3f13a6e, not
  loaded`, the blob's own first word), and devmgr logged no `no
  firmware`. The launcher then waited on `bin/wedge`; at 150 s
  (`croi.watchdog_limit=150`) the kernel's stuck report listed every
  thread's wait, 147 threads in 61 processes, `"wedge-port": blocked in
  port_wait ... no timeout` among them, taking 2.3 s at the dumper's
  pace, and the SBSA watchdog reset the board into FreeBSD one timeout
  later, with no power cycle. The tables D171's checks read were taken
  that day from FreeBSD: each table from `/dev/mem` at the XSDT's
  addresses (`acpidump -dt` gives text only), kept in `.cache/acpi/
  orangepi-6-plus` (SSDT1, SSDT2 in the XSDT's order), and the firmware
  from FreeBSD's `/boot/firmware` (`vx firmware fetch --from
  root@192.168.0.19:/boot/firmware`).
- **The GPU's firmware booted** (2026-11-20, `esp-board` built on the
  Mac, D173 parts 1 to 4): mali(3) took the G720 through the Sky1's
  order and booted its CSF firmware on the first run. In its status:
  - the harvest word 0x0000000f leaves all 10 shader cores
    (0x00550555);
  - RESET_COMPLETED after 2 us, COHERENCY_FEATURES 0x00000001 (ACE-Lite
    only), the L2 ready after 3 us;
  - the image's 8 sections (one protected, skipped) in 960 KiB of
    write-combining memory, the MCU's VM in 48 VA bits, 10 table pages;
  - the global interface's interrupt within 1 ms of `MCU_CONTROL`
    AUTO: interface **3.13.0**, 8 CSG slots of 8 CS slots, 128 work
    registers and 16 scoreboards, suspend buffers of 27584 bytes;
  - GPU_TIMESTAMP at 1 GHz, the global configuration acknowledged, the
    ping answered;
  - `gpu.mali.boot_ms` 3 ms at boot, and 7 ms after D170's power off
    and on (the firmware boots again).

  board-test's new check `boots the GPU's firmware` passes; 75 checks.
  MMU_IRQ_RAWSTAT bit 16, first taken for a fault, is AS 0's command
  complete (panthor 02 §2.7.1). Two runs before ended with board-test's
  report cut short at the reboot, verdict and all: the kernel gave the
  console 2 s to drain, and the report is some 40 KB at 115200 baud.
  The cap is now 10 s, and the drain took 5.7 s (`power.log_drain`).
  Not yet: interrupts (devmgr grants a platform device only its first,
  so mali polls), the MCU halted before a power cut, and the `csf`
  capset served.
- **The GPU ran a command stream** (2026-11-20, `esp-board` built on the
  Mac, D173 part 5 and the wiring): gpu-test, started by board-test
  through the launcher, opened the `csf` capset at `/dev/gpu0/gpu`.
  - Its user stream (MOV48, STORE_STATE timestamp, SYNC_ADD64) wrote GPU
    timestamp 18875108842160 into its buffer and raised its counter.
  - A stream calling an unmapped VA raised `TRANSLATION_FAULT level 1 on
    a read of 0x70000000` on address space 1, and only that group ended:
    group state 2, one fatal queue. A fresh context ran after it.
  - `gpu.mali.empty_job_us` 16 us; JOB interrupts 16, MMU faults 1,
    resets 0.
  - Before the supply ended, `mali: supply ending: the MCU halted in 0
    ms`.

  board-test passed, 76 checks. The first try skipped (`no csf GPU`):
  devmgr mounted `dev/gpu<n>` only where it starts hosts it doesn't
  power up, and mali is started by the power-up path.
- **The first shader** (2026-11-20, D174 step 1's MaliCore, before the
  compiler): gpu-test dispatched a compute shader assembled by hand from
  valhall 11b and 12a. It is two instructions:
  - `SHADD.u64` makes the address of word `global id x` in a buffer;
  - `STORE.i32 ... end` writes the id there.

  It ran as 4 workgroups of 16 through MaliCore's resource-table-free
  recipe, and all 64 words were exact (word 64 untouched).
  `gpu.mali.compute_dispatch_us` 43 us (the median of 20 one-workgroup
  dispatches), `gpu.mali.empty_job_us` 15 us. The faulting stream's group
  ended with `CS_BUS_FAULT` (CSG 0, CS 0) beside the translation fault,
  and this time mali also reset the GPU once (`resets 1`, the firmware
  answered); the run before had no reset. mali's events have no times
  yet, so which came first is open.
- **The first triangle, and the first compiled shader** (2026-11-20, D174
  steps 1 and 2 before the compiler has graphics stages):
  - **The triangle.** gpu-test drew one triangle offscreen into a 64x64
    linear RGBA8 target with a hand-assembled vertex shader (positions
    from a table, stored per 12c's vertex-stage recipe) and fragment
    shader (ATEST, then BLEND to render target 0, opaque), through
    MaliCore's tiler, framebuffer and IDVS recipe.
    - The two-queue layout (a vertex and tiler queue that signals a sync
      object, a fragment queue that waits on it) drew it first.
    - 1017 pixels inside were exactly the colour and 2687 outside exactly
      the clear; 392 within a pixel of an edge are not judged (no fill
      rule in the spec).
    - First pass 207 us, then 80 us; `gpu.mali.triangle_ms` 1.
    - Nothing is shown on the display: the target is GPU memory read back
      by the CPU.
  - **Compiled shaders.** The compiler built into gpu-test (Embedded)
    compiled three SPIR-V shaders on the board: globalID 2 instructions,
    saxpy 13, reduce 35; slowest 6.7 ms (the first),
    `compiler.valhall.compile_ms` 7.
    - Compiled globalID ran exactly.
    - Compiled saxpy wrote 0xfff00000 (a NaN) in all 100 results, where
      the host interpreter is exact. Being isolated by assembling
      variants of its listing on the board.
  - board-test said `passed` though gpu-test failed: it checked only that
    gpu-test ended.
- **Compiled compute is exact, after the wait rule was found** (2026-11-20,
  four board runs of gpu-test's probes): compiled saxpy's NaNs bisected to
  the flow field's waits.
  - **The finding:** on the G720 a wait carried by an instruction takes
    effect *after* it, so it protects the next instruction, never its own
    reads.
    - `NOP.wait0` then reading a slot-0 load: right.
    - `FADD.wait0` reading it: stale.
    - slot-2 waits never covered it, so slot numbering is as specified.

    The spec had said "before"; the dirty room confirmed "after" against
    the source and fixed every section that depended on it (chinese-wall
    a981823). The validator, the interpreter (which now reproduces the
    old failure) and the backend's wait placement follow it, and so does
    the triangle's fragment shader (its wait moved off ATEST).
  - **The run after the fix:** gpu-test passed.
    - compiled globalID exact;
    - compiled saxpy 100 results bit-exact;
    - compiled reduce (4 workgroups of 64, workgroup memory and barriers)
      exact;
    - the triangle as before (77 us a pass).

    A load carrying a wait on its own slot protects the next instruction
    (probe q5); the old saxpy words still fail. board-test now fails when
    gpu-test does, and passed.
- **A compiled triangle** (2026-11-20, D174 step 2 done): the compiler built
  into gpu-test compiled a vertex shader (39 instructions, 0.56 ms) and a
  fragment shader (8 instructions, 0.17 ms) from SPIR-V on the board.
  - The vertex shader does the viewport transform itself and reads its
    positions through a root pointer from its push constants.
  - The fragment shader ends in `NOP.wait0126`, ATEST, `NOP.wait`, BLEND.
  - The compiled triangle drew exactly as the hand-assembled one did:
    1017 pixels inside, 2687 outside, 392 at an edge not judged.
  - gpu-test passed, compiled compute exact as before.
- **Textures and blend** (2026-11-21, D174 step 3's draws): a textured
  quad and an alpha-blended one, both compiled from SPIR-V, drew on the
  board.
  - Before the fix, every pixel sampled texel (0,0): the varyings read
    zero. The address probes showed only the position pass ran
    (shader_output 0x1) and no varying buffer was allocated.
  - The cause: a draw with varyings must set the primitive flags'
    secondary-shader bit (TILER_FLAGS bit 18) on arch 12 too. The spec
    had it for arch 10 and 11 only; the dirty room fixed it (chinese-wall
    3e51d91), and MaliCore sets it for any draw with a varying buffer.
  - The run after the fix: the textured quad exact (3906 pixels judged,
    190 on the diagonal not judged, 80 us a pass,
    `gpu.mali.textured_quad_ms` 1), alpha blending within 1 of the
    equation in each channel. gpu-test and board-test passed.
- **Loinnir on the core over Mali** (2026-11-21, D174 section 5): loinnir-test
  found the GPU class on gpu0, picked the Mali backend, and drew a
  constant-colour triangle and a varying one through the root pointer
  (1953 pixels inside, 1953 outside, each exact). Its texture test is
  skipped: the core's Mali backend doesn't yet put sampled images in the
  heap. Submissions count up the timeline. loinnir-test, gpu-test and
  board-test passed.
- **A texture sampled from the core's heap** (2026-11-21, D174 step 3's
  last check): loinnir-test's texture test ran on Mali. It sampled an
  8×8 linear rgba8 texture by its heap index, through a per-draw copy of
  the heap and its resource table, and read back exactly.
  - The first run faulted on the GPU's MMU, and loinnir-test's error
    couldn't be printed in Embedded Swift. The pass's shaders had no
    thread storage for their stack. The texture's fragment shader is the
    first through the core to need it.
  - The run after the fix: all of loinnir-test's draws passed, with the
    MMU fault count back to gpu-test's one deliberate fault. gpu-test and
    board-test passed.
- **Radharc's GPU renderer on the core over Mali** (2026-11-21, D174 step 4):
  Radharc composed on the CPU here until the Mali backend took what its
  GPU renderer needs; it now draws through Loinnir on the G720 and the
  frame reaches linlon with no copy.
  - The backend gained `bgra8srgb` images and targets (the clear is
    encoded, the blend descriptors carry the sRGB bits; the render target
    descriptor's own sRGB bit stays clear, and the colours came out exact),
    the pipeline's fixed-function blend, passes of up to 16 draws with
    instances, and one tiler heap (context, chunk, geometry buffer) for the
    device's life. A heap made and freed each pass faulted every pass after
    the first.
  - Readback memory and targets only the CPU reads are mapped cached by the
    CPU (`BO_CREATE` flag 1) and cleaned and invalidated by the client
    around the GPU's work. The service doing that itself delayed the
    firmware's status updates: 9 resets a run; with the client doing it, 1.
    4K readback went from 33.6 ms to 5.5 ms and the CPU's copy of it from
    71.8 ms to 5.7 ms.
  - **Zero copy:** Radharc draws into two scanout targets, Mali buffers
    whose VMOs are exported (rights to transfer, read and measure) and
    attached to linlon once; each frame is drawn into the one not shown and
    presented with empty damage. Removed: the GPU-to-readback copy, the
    CPU's copy into the shadow, and the copy into the output's image. The
    pass's tail already cleans the GPU's caches, so no CPU maintenance
    either. A readback stays for tests and `pixel`.
  - **The missing quads:** the first runs differed from the CPU's frame in
    about 55 pixels, 2x2 quads left clear, a few different ones each frame.
    Not the upload (a separate submission changed nothing), the heap, the
    geometry buffer or the kill modes (none brought the count to 0, a 4 MiB
    geometry buffer faulted). The cause was a texture handle that differs
    between the lanes of a warp: compose.frag indexes its textures by a flat
    varying, a fragment warp mixes instances, and the hardware reads one
    handle per warp (valhall 12b 12b.2.1, row Q16), so a lane read another
    instance's texture. The compiler now makes such a handle uniform with a
    loop over the distinct values (`WMASK`, the lowest set lane, a `CLPER`
    broadcast, at most 16 rounds); a host test runs compose.frag's loop over
    a warp of three textures on the interpreter, and without the loop the
    interpreter refuses the fetch.
  - **Run after the fix** (bca21654): both themes' 1080p frames equal the
    CPU's, 0 pixels off, a second frame too; `theme.compose.1080p` 1.72 and
    1.77 ms (target 2 ms), 4K reported at 2.77 and 2.75 ms. gpu-test,
    loinnir-test and board-test passed, 1 reset, and the MMU fault count was
    gpu-test's one deliberate fault.
- **The GPU's 4K ceiling** (2026-11-21, gpu-test's ceiling probes): the core
  clock is 900 MHz and the shader stacks run at 1 GHz (SCMI clocks 31 and
  32).
  - At 3840x2160 bgra8, a clear alone took 1.30 ms (25.5 GB/s written).
    One full-screen texel a pixel took 1.80 ms, and two blended layers
    1.88 ms.
  - A 64 MiB compute copy reached 6.9 GB/s, which is the compiler's limit,
    not the memory's.
  - The owner set the board's aim at 1080p or lower: `theme.compose.1080p`
    is the judged budget (2 ms), and 4K is reported. The paths to faster
    frames are in docs/performance.md.
