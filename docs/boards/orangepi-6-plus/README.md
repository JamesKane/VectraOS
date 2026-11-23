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
- **Pipeline state on the core's Mali backend** (2026-11-21, D174 step 3,
  fixed function): the depth and stencil target, rasterization, blend,
  dynamic state and several colour targets, each judged on the board by
  loinnir-test's CoreCases (depth, stencil, cull, blend) and its pipeline
  cases (graphics/loinnir/tests/native/PipelineCases*.swift), which say
  every mismatch and go on.
  - **Depth and stencil:** the framebuffer group grows a 64-byte
    extension; Z internal format D16 or D32, S8 in the stencil record,
    each plane written back linear; clears in the parameters block. Four
    rectangles out of order on depth32f: 1024 of 1024 pixels exact;
    every compare op against three relations (0.4, 0.5, 0.6 over a
    written 0.5): exact; stencil replace, increment, equal, a dynamic
    reference, and two-sided operations with a write mask: exact. Depth
    bias is the API's constant, slope and clamp straight into words 5 to 7
    (6.8.4's open questions): a negative constant of 64 passed `less`
    against an equal depth, a clamp of -0.01 held a bias of -1e9 behind a
    depth 0.2 further, and a positive 1e9 failed. Depth clamp needs the
    tiler flags' low and high depth-cull bits clear as well as the
    descriptor's clip bit (a rectangle at 1.5 drew at 1.0 only then).
    The shader's depth needs depth source 3 in the descriptor (the first
    run used the geometry's depth, 16 of 32 pixels wrong). Early and late
    by 6.10.2: a discarding shader that writes depth updates late, and the
    discarded fragments left the depth alone.
  - **Rasterization:** cull back, front and none, and back with the other
    front face (2048 pixels exact), the draw flags' front-face-CCW bit set
    from the API's counter-clockwise;
    point list (one pixel each), line list and strip, triangle strip and
    fan, primitive restart with 16- and 32-bit indices, line width 4
    (static and set by the pass, four rows, with `PRIMITIVE_SIZE` the
    width), a scissor and sub-rectangle viewports, and rasterizer discard
    (the draw is not run: the vertex stage has no output but the
    position).
  - **Blend (`generalBlend`, `dualSourceBlend`, `logicOps` on):** the
    fixed-function equations of 09.4.2 where the blender can do them, and a
    blend shader (09.9, 09.10.1; `BlendShader.swift`) where it can't:
    minimum and maximum, the saturated source alpha, constants that differ
    between channels, dual-source factors, logic operations, alpha to one
    (the generator does it; the device flag stays off with MSAA). The
    fragment shader calls it after the BLEND (16-byte sequence, 09.9.1),
    with the colour staged in r0 to r3 and the second source in r4 to r7.
    CoreCases' 14 sets (alpha, additive, multiply, subtract, reverse
    subtract, min, max, constants, saturate, write mask, dynamic
    constants, xor) are each within 1 of the formula and xor is exact,
    on the board first time with the spec's sequence (f16 tile load and
    store, f32 arithmetic); the dual-source sets are judged the same way.
    The blend shaders live in the pass's block (one 4 GiB window), the
    constants in the fragment FAU's first two slots.
  - **Several colour targets:** three targets written by one shader's
    three outputs with an opaque, an additive and a green-only blend, and
    eight targets of which five are not written (their descriptors are
    off): every target exact. The tile plan gives each target 4 bytes a
    pixel; the blend descriptors' constant is the first one used, in all.
  - **Not done:** polygon modes line and point (the hardware has no path:
    06.4.6 says a compute pass would rewrite the indices), MSAA and
    resolve, alpha to coverage and to one, sample shading, layers and
    multiview, depth and stencil loaded from an image (a frame shader that
    writes depth, 08.10), and the
    depth bounds test (06.8.5: none in the hardware). Dirty-room: none open on blend shaders.
  - **Not this branch's:** vulkan-test fails its swizzled-view case
    (`vkCreateImageView` refused by the core: a mapped view) and its input
    attachment case on the board, and so compose-test's check that
    vulkan-test passed; both are gpu-gaps' device features, off on Mali.

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
- **The GPU resets, found** (2026-11-21): the 1 to 4 resets a run
  ("STATUS_UPDATE was not acknowledged", 100 ms spent each) were a lost
  request, not slowness. Instrumented images showed:
  - an answered STATUS_UPDATE takes 4 to 13 us, with the shader cores
    powered off or on alike; a failing one is never answered in the 100 ms;
  - at 10 ms into a failing wait the global IDLE event was pending
    (`JOB_IRQ_RAWSTAT` 0x80000000, GLB_REQ/ACK differing in bit 26), the
    GPU idle (`GPU_STATUS` 0, shader cores off, MCU enabled), and
    GLB_DB_REQ equal to GLB_DB_ACK: the firmware had taken the doorbell
    and not acted on the request;
  - ringing doorbell 0 again, and acknowledging the events, did not help; a
    second GLB_DB toggle with doorbell 0 (`kickGroup`) answered it within
    8 us, 60 ms into the wait.
  - So the firmware drops a CSG request whose doorbell lands as it raises
    IDLE. The fix is in `CSFLink.statusUpdate`: after 1 ms without an
    answer, kick the group again, every millisecond until the 100 ms
    request timeout, which is unchanged. 5 board runs after: gpu-test,
    loinnir-test, vulkan-test and board-test passed, 0 resets, 1 to 5
    repeated doorbells a run (`status doorbells repeated N` in the
    scheduler line). Open: why the firmware drops it, and whether suspend,
    priority and start requests can be dropped the same way (none seen).
  - **Every request, and the order** (the dirty room's panthor 06 section
    6.3.8, all three questions still open there): the re-ring now covers
    every CSG request (start, resume, suspend, terminate, endpoint config,
    status update), waits for the request's own acknowledge bits, toggles
    again only once GLB_DB_ACK has caught up with GLB_DB_REQ, every 0.5 ms,
    and the 100 ms hang stays the last escalation. The ordering experiment:
    acknowledge the global events, toggle and ring the doorbell and see it
    taken, then write CSG_REQ. Dropped requests per board run (the repeated
    doorbell counts, 250 or so status updates a run):
    - the unordered sequence, 0.5 ms re-ring: 0, 2, 2 over 3 runs (the
      1 ms one earlier: 4, 2, 4, 1, 5);
    - the ordered sequence: 0, 0, 0, 0 over 4 runs, all 250 status updates
      ordered.
    The ordered sequence is adopted for the status update (the IDLE event it
    acknowledges is handed back to the scheduler), the re-ring stays as the
    safety net.
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
- **The Vulkan layer on Mali** (2026-11-21, D174 step 5, main 9962976f):
  vulkan-test, a tier 1 C program, ran through our loader, the layer over
  the core, the SPIR-V lowering, MaliDevice and our compiler.
  - The compute test (two storage buffers, a push constant) read back
    exactly.
  - The triangle, drawn from a vertex buffer in a render pass, had 1089
    pixels inside, 2682 outside, 325 at an edge not judged and 0 wrong.
  - board-test passed on two boots.
  - The pre-existing reset ("STATUS_UPDATE was not acknowledged") came 4
    times in the first run and once in the second. Every time it was
    during gpu-test and loinnir-test, before vulkan-test started.
  - `theme.compose.1080p` was 1.79 ms in both themes.
- **The core's features on Mali** (2026-11-21, D174 step 5's follow-on):
  loinnir-test judges each against the CPU's pixels or words; board-test
  passed.
  - **Indexed draws:** 16 and 32-bit indices, a first index, an offset in the
    index memory, a base vertex (positive and negative), two in a pass, and
    an interpolated quad equal to the non-indexed one: exact. `VertexIndex`
    is the index plus the base vertex. A draw from a first vertex is the same
    quad. 193 us a pass (`gpu.mali.core_indexed_draw_us`).
  - **Indirect draws and dispatch:** the stream loads the draw's words into
    registers 33 to 37 and waits for the load; two draws, an offset, an
    indexed one with a first index and a base vertex, and arguments a compute
    shader wrote: exact (192 us). A dispatch loads its grid into `JOB_SIZE_*`
    and the shader's number of workgroups, from memory, from an offset, of one
    workgroup, of 200, and from arguments a dispatch wrote: the workgroups that
    ran and what the shader saw were exact (150 us). RUN_COMPUTE_INDIRECT is
    not used.
  - **Loaded attachments:** a first pre-frame shader (a fetch of the target at
    the pixel, in a heap of its own, stored in the tile by the opaque blend)
    keeps what an earlier pass drew; three passes over an image, one that
    draws nothing, exact (264 us a pass).
  - **Timestamps:** STORE_STATE of the system timestamp; the counter runs at
    1 GHz (measured against the CPU's clock, 1000 ps a tick). A pass 290 us
    between two timestamps, a 20 ms sleep 20231 us (the CPU saw 20165 us).
    The first calibration put the group's creation inside a sample's bracket
    and read 588 ps; a warm-up sample fixed it. One list of a pass and a CPU
    copy read 101 ms of GPU time once, and 0.3 ms every time after.
  - **Occlusion queries do not work:** with the counter mode in the draw
    flags and the query's address in `OQ`, the counter reads 0 for a
    rectangle of 768 pixels, in a pass, after 20 ms, in cached or
    write-combining memory, with late kill and update, with no forward pixel
    kill, and in mode 2. The predicate mode (1) writes 1 where a sample
    passed and 0 where none did. `occlusionQueries` stays false.
  - **Storage images:** a texture descriptor of one level in table 2 (1024
    slots), handle `2 << 24`; a compute shader wrote a 64 x 64 rgba8 image and
    read it to write another: exact (230 us).
  - **Measurements** (gpu-test, reported): FRCP.f32 is not always the
    correctly rounded reciprocal: of 131072 divisors 127282 were, 2353 above
    it and 1437 below, the worst 1 ulp. WMASK in divergent code reports the
    lanes active now (0x00ff for eight of sixteen), both when the others skip
    to a reconverge and when they end.
- **Main as it stood, three board runs** (2026-11-21, 85a97cfe: the Mali features, the reset fix, the compiler's coverage, the
  core's full types and the Vulkan layer over the widened core): gpu-test, loinnir-test, vulkan-test, compose-test and board-test
  passed in all three, 0 resets, `requests asked again 0`, 458 to 467 ordered status updates, 1 MMU fault (gpu-test's
  deliberate one); vulkan-test printed its two skips (`vulkan depth`: no depth attachment, `vulkan multisample`: no
  four-sample colour) and passed; `theme.compose.1080p` 1.85 to 1.91 ms.
- **Shader atomics need a cacheable GPU mapping; so does the occlusion counter** (2026-11-21, D174 amendment): every GPU mapping was
  write-combining, and in it
  - an atomic of any kind (a hardware add, the backend's compare-exchange loops, an image atomic) did nothing and raised
    GPU_CACHEABILITY_FAULT, which ended no group (the contended counters read 0, the image atomic's old values 0);
  - the occlusion counter mode read 0 for 768 samples whatever was tried (valhall 06 §6.11.1's experiments: the report zeroed by a
    store on the fragment queue and flushed, the clean flush after the fragment work, the draw flags' late and no-forward-kill
    variants, the GPU's own load of the report after the flush: 0 each).
  A bind with the new cacheable flag (CSF bind flag 8: attribute index 1, write-back in the GPU's caches) fixed both: 16384 lanes
  of 256 workgroups each adding 1 to one counter finished exact for a hardware add (2.6 ms for the dispatch), a 16-bit add
  (32 ms) and a float add (31 ms) as the backend's loops, and the occlusion counter read 768 for a rectangle of 768 pixels,
  0 off the target, 1664 for two rectangles, 2016 for the half-target triangle, and the same again in a second pass over the
  queries. The query sets' memory is mapped cacheable now and `occlusionQueries` is on. The GPU's zero store and the CPU's zero
  both gave 768 (a CPU zero before the first use is enough); mode 2 and the predicate mode as before.
  The first attempt wrote its scratch registers over the recipe's sync registers (66 to 71), and the fragment queue read address 0
  (`CS_BUS_FAULT`, a translation fault at level 3): a stream's own registers are listed in RenderPass.swift.
- **The timestamp period is CNTFRQ_EL0's** (2026-11-21): the register reads 1000000000 Hz in user space, so the period is 1000 ps with
  no calibration (the first read of `limits` was 40 ms); loinnir-test measures it once against the CPU's clock and the two agree
  (1000 ps both). The calibration stays as the fallback where the register reads 0.
- **Mali resources** (2026-11-21, D174 amendment step 3, the resource half): images of every shape and format, views, samplers, depth and
  stencil images, copies and clears, compressed textures; the board judged them with loinnir-test's ResourceCases and vulkan-test.
  - **Layout:** every image is linear in CPU-mapped memory, one plane for a colour format and one for each aspect of a depth or stencil
    format; levels, layers, cube faces and volume slices as valhall 05 section 5.5 has them; a view is a texture descriptor over a plane
    array of its own (the whole colour image's is kept after its texels).
  - **On the board, exact or within the stated rounding:** the 13 float-class formats (r8snorm, rg8, rgba8snorm, rgba8srgb, the 16 and 32-bit
    floats, rgb10a2, rg11b10f, rgb9e5), the nine unsigned and nine signed integer formats, views of a mip level, a mip range, a layer, a
    format (sRGB) and component swizzles, the five address modes on each axis (repeat, mirrored, clamp, mirror-clamp, the sampler's own
    border colour), level-of-detail bias (+2, -1), minimum and maximum, anisotropy 4, unnormalized coordinates, depth16, depth32f,
    depth24stencil8, depth32fstencil8 and stencil8 (clear, sampled, copied out; the stencil aspect through an unsigned integer sampler),
    the eight compare functions against three references, clears of 11 colour formats (the bytes of each), a 3D block placed with a row
    length and an image height, a block copied between a mip level and layer of an array, a 2x linear blit within 2 and rgba8 into bgra8,
    and one block each of ASTC 4x4, ETC2 RGB8 and BC1 decoded to its colour.
  - **TEXTURE_FEATURES[0]** reads `0xc3ffff9e`: ETC2 RGB8 (bit 1), R11 (2), RGBA8 (3), RG11 (4); BC1 to BC7 (7 to 16, every one, which is not what
    Mali is thought to have: BC1 decoded right); ETC2 R11 and RG11 signed and RGB8A1 (17 to 19); ASTC 3D LDR and HDR (20, 21); ASTC 2D LDR and
    HDR (22, 23); bit 24, which is not established; AFRC (25); the two arch 7 narrow bits (30, 31). The backend offers a family when all
    its bits are set.
  - **What the first runs found:** a block-compressed view needs the texture descriptor's texel interleave bit (ASTC read zeros without it;
    ETC2 and BC too); the maximum level of detail of a one-level texture doesn't stop a minifying quad from taking the minification filter
    (a level of headroom reads level 1, which isn't there: zeros); `textureLod` with level 0 is a magnification, so a minification test
    needs derivatives; the exported VMO a display pins has no map or duplicate right, so a mappable export is its own call.
  - **Compute shaders sample** (vulkan-test's 1D and swizzled-view cases need it): the compiler's texture access no longer refuses a compute
    shader; its FAU block holds the heap's handles and the dummy sampler; the dispatch's resource table has table 1.
  - **Not claimed, probed:** `samplerMinMagFilters` (the filters read right but for the pixels of the quads the diagonal crosses, which the
    case now leaves out, and the whole suite hasn't run with it on).
  - **Present and import** (2026-11-23, D174 "Mali present, as built"): `importHandle` is claimed after a whole run with it on. A
    window's frame is a `scanout` image with packed rows: render targets 40 and 104 pixels wide (rows of 160 and 416 bytes) were drawn
    and read back through the window's mapping exactly, but the texture unit read zeros from a linear plane of 160 or 400-byte rows
    (imported images of rows of 256 and 512 bytes sampled exactly), so an import needs rows of a multiple of 64 bytes. Memory imported
    and stored to by a compute shader (64 words, the root pointer the import's address) read exactly through the exporter. The timeline's
    counter, duplicated without the write right, read 104 after 104 was signalled and refused an add. compose-test: Radharc's GPU
    renderer sampled a 128-wide window's image from a second context in place and uploaded a 100-wide one, both composed as the CPU
    composes them over two frames in the same pages.
  - **Atomics on an ordinary storage buffer read 0** in all four ways tried (all memory cacheable or only the clients', the stream's end
    cleaning or cleaning and invalidating): a plain store through the root pointer and the single add are in the probe's lines. gpu-test's
    descriptor-buffer atomics are exact in a buffer the client binds cacheable, so the difference is the form (a pointer) or the
    streams and code being cacheable. The question is out with C1; nothing is claimed.
    **Answered (2026-11-23):** the probe was wrong, not the memory. It gave as the root pointer the address of a word holding the
    target's address, and a Loinnir shader's root *is* the target (gpucore(2)), so every store and add went into that word
    (`target word 0 0x5e5e5e5e, holder words 0, 1, 2 0x1 0x2 0x3`). With the root right, panthor 04 section 4.7.4.5's experiments,
    a sentinel written through the write-combining mapping first, read the GPU's results in every arrangement: target and root
    cacheable or not, the driver flushing after or not (`K1 probe both cacheable 0: plain store 0x1 0x2 0x40 (result, result,
    result); 256 atomic adds onto the sentinel 0x5e5e5f5e (result), store 0x7 (result)`); write-combining memory kept the
    sentinel under the adds, as GPU_CACHEABILITY_FAULT says. A first run with the wrong root read the sentinel everywhere, with
    the CPU's lines over the fresh pages cleaned first or after the run, so no CPU line was involved. The kernel's missing clean
    of pages committed into a write-combining VMO (K1.3 item 3) was found reading the chain and fixed, though it hadn't shown.
    A client's memory and storage images are now GPU-cacheable, and the 32-bit atomics are claimed (D174).
  - **Multisampling, clears in a pass, kept depth and stencil** (2026-11-23, D174): 2, 4, 8 and 16 samples resolved by the pass
    exactly as the standard locations predict at an edge half way through a pixel (Average writeback), a target stored and resolved
    by two descriptors over one tile, kept multisampled targets loaded a sample at a time, the sample mask, sample shading, alpha to
    one (a blend shader) and alpha to coverage, whose mapping is measured: alpha 0.5 covers two of four samples (`0x800080c0` over a
    blue clear). `clearAttachments` is a draw with the rectangle as scissor. Depth and stencil are kept by the second pre-frame shader
    (Early ZS Always), the stencil as the shader's reference (`ZS_EMIT.stencil`); the first try was refused by the compiler, which did
    not yet accept the StencilRefReplacingEXT mode glslang emits.
  - **Off:** depth and stencil resolves, polygon modes (no hardware path, valhall 06 section 6.4.6), layers and multiview.
- **Zero counts** (2026-11-21): an indirect draw whose vertex, index or instance count is zero, and an indirect dispatch with a zero
  dimension, are branched over in the stream. loinnir-test's GPU-written zero arguments (no vertices, no instances, each of three axes)
  drew and ran nothing, and the draw or dispatch after each ran exactly.
- **What the G720 does where the spec was silent** (gpu-test's probes, 2026-11-21, reported; the compiler's assumptions are in
  valhallbackend(2)):
  - WMASK of a constant in a branch the odd lanes take is 0xaaaa (the lanes active now), as the subgroup code assumes.
  - `LOAD.i8` and `LOAD.i16` as the backend writes them (no `.sext`) leave the register sign extended (0x83 reads 0xffffff83, 0xf383
    reads 0xfffff383), not zero extended as valhallbackend(2) said; the compiler widens before it looks at upper bits, so nothing changes.
  - Concurrent narrow stores of neighbouring lanes are exact (128 byte stores and 128 half stores into 32 and 64 words).
  - `FADD.v2f16` and `FMA.v2f16` keep binary16 subnormals under flush mode 0 (inputs and results).
  - ST_CVT saturates an integer that does not fit an R8UI, R8I, R16UI or R16I image (256 stores 255, -129 stores -128, 65536 stores
    65535), and a value that fits is stored exactly in all four, signed ones included (auto32 is right on them).
  - An out of bounds `LD_TEX` (negative, past the edge, beyond 16 bits) reads (0, 0, 0, 1) from an R32UI image; an out of bounds store
    and an out of bounds atomic in cacheable memory change no memory outside the in-bounds texels (the atomic returns 0), though some
    runs raise one GPU_CACHEABILITY_FAULT at 0x980000003f that ends nothing.
  - A contended compare-exchange loop finishes and is exact under 16384 lanes in cacheable memory (above).
  - Not measured: a discarded but not yet retired lane's answer to CLPER and WMASK (it needs a fragment shader with the discard flow
    hand-assembled; not written).
- **Texel buffers on Mali** (2026-11-21, D174 section 5): the Valhall backend
  takes a texel-buffer access (`LEA_BUF`, word 7 of the descriptor through
  `LD_PKA`, `LD_CVT` or `ST_CVT`) and `MaliDevice` keeps the Buffer
  descriptors in table 2 after the storage images (slots 1024 to 2047
  uniform, 2048 to 3071 storage). loinnir-test's checks on the board:
  - Four views (r32float, rgba8, rg32float, r8) fetched as a vec4: all 64
    texels exact. The open question of 12b.14.1 is answered as inferred:
    `LD_CVT` of four channels fills the channels a format lacks from the
    component order, an r32f texel reads (g, b, a) = (0x0, 0x0, 0x3f800000),
    an rg32f one (b, a) = (0x0, 0x3f800000). The compiler does no fill. The
    sizes (descriptor size over stride) are 16 each.
  - A read, a store and a read after it, of one texel in one invocation, are
    in program order, exact.
  - No atomic add took effect: on a texel buffer, and on a word of a plain
    buffer (readback and upload memory) alike; a word reads what it did
    before. The compiler's `ATOM.i32.aadd` is as 12a.8 gives it. So no format
    has `storageTexelBufferAtomic`, and vulkan-test's texel-buffer case
    stays skipped. This is atomics on the board generally, not texel
    buffers'; what the GPU needs beyond the instruction is the dirty room's.
