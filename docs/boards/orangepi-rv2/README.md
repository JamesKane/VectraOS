# Orange Pi RV2 (Ky X1)

The rv64 board (D51). Its SoC is sold as the Ky X1, an 8-core "RISC-V AI
CPU". Linux and FreeBSD know it as the SpacemiT K1: Linux's
`k1-orangepi-rv2.dts` includes `k1.dtsi` (compatible
`"xunlong,orangepi-rv2", "spacemit,k1"`). This file uses K1 for the SoC.

These are facts read from other trees, not from our own bring-up. Each one
names its source. Code is not lifted from them (D4); they are read as
hardware documentation, as AbyssBSD's notes are for the Q8B.

| Source | Commit | Paths |
|---|---|---|
| Linux (`../linux`) | `24a19b953e2a` (2026-10-11) | `arch/riscv/boot/dts/spacemit/k1.dtsi`, `k1-orangepi-rv2.dts`, `Documentation/devicetree/bindings/*/spacemit,*` |
| FreeBSD (`../freebsd-src`) | `fe90f180047b` (2026-10-13) | `sys/riscv/include/cpu.h`, `sys/riscv/riscv/identcpu.c`, `sys/riscv/spacemit/`, `sys/dev/clk/spacemit/` |
| SpacemiT EDK2, K1 (gitee `bianbu-linux/edk2-platforms`, branch `k1`) | `1bad7a5` (2025-10-09) | `Platform/Spacemit/K1/MUSE-Pi-Pro/`, `Silicon/Spacemit/Include/IndustryStandard/Acpi66Temp.h` |
| SpacemiT EDK2, K3 (github `spacemit-com/edk2-platforms`, branch `k3`) | `0b8b7182d8a2` (2026-09-30) | `Platform/Spacemit/K3/AcpiTables/` |
| EDK2 (github `tianocore/edk2`) | `27cb976bba49` (2026-10-01) | `DynamicTablesPkg/Library/Acpi/RiscV/`, `DynamicTablesPkg/Library/FdtHwInfoParserLib/RiscV/` |
| Planar (`../planar-os`), the owner's OS that ran on this board | `4ef44c2` (2026-10-27) | `docs/boards/orangepi-rv2/README.md`, `docs/v1-plan.md`, `docs/06-platforms.md`, `arch/rv64/arch.c`, `plat/ky-x1/` |

## CPU

- **8 SpacemiT X60 harts** in two clusters of 4 (`cpu-map`), each cluster
  with a 512 KiB L2. Each hart: 32 KiB I and D caches, 64-byte lines.
- **ISA** (`riscv,isa-extensions`, the same on every hart):
  `imafdcbv`, Zicbom, Zicbop, Zicboz (64-byte blocks), Zicntr, Zicond,
  Zicsr, Zifencei, Zihintpause, Zihpm, Zfh, Zba, Zbb, Zbc, Zbs, Zkt, Zvfh,
  Zvkt, Sscofpmf, Sstc, Svinval, Svnapot, Svpbmt.
- **That is RVA22 (RVA22U64 and RVA22S64) with V.** Of RVA22's optional
  extensions it also has Sstc, Sscofpmf, Svnapot, Zfh and V. It is not
  RVA23: it lacks Zcb, Zfa, Zawrs, Zimop, Zcmop, Zvbb and Zihintntl, among
  others. The DT doesn't list RVA22's unnamed features (Ziccif, Za64rs,
  Zic64b and so on); they are assumed from the profile, and checked in
  bring-up.
- **No H extension** (we have no hypervisor, so nothing is lost), **no
  Ssaia** (see Interrupts).
- **MMU: Sv39 only** (`mmu-type = "riscv,sv39"`). The kernel already runs
  Sv39 on rv64 (`KernelLayout.swift`, `start.S`).
- **Timebase: 24 MHz** (`timebase-frequency`).
- **IDs** (FreeBSD `cpu.h`): mvendorid `0x710` (SpacemiT), marchid
  `0x8000000058000001` (`MARCHID_COMMERCIAL(0x58000001)`, "X60").

## Physical memory

- **DRAM is split around a 2 GiB MMIO hole.** The first 2 GiB are at
  CPU address `0x0`; the rest starts at `0x1_0000_0000`. The DT has no
  `memory` node: the firmware fills it, and our loader takes the UEFI
  memory map as usual.
- **Devices see DRAM without the hole.** Every bus's `dma-ranges` maps the
  first 2 GiB 1:1 and the rest at CPU address − `0x8000_0000`. So a DMA
  address is not the physical address above 2 GiB, as on the Q8B (where
  the offset is `0x10_0000_0000`). Each bus also has its own reach:

  | Bus (`k1.dtsi`) | Devices | DRAM reachable (CPU addresses) |
  |---|---|---|
  | `network-bus` | the two EMACs | `0x0`–`0x7fff_ffff`, `0x1_0000_0000`–`0x1_7fff_ffff` (4 GiB) |
  | `pcie-bus` | PCIe 0–2 | `0x0`–`0x7fff_ffff`, `0x1_3800_0000` up (the first 896 MiB above the hole are not reachable) |
  | `dma-bus` | PDMA, UARTs, QSPI, SPI 3 | `0x0`–`0x7fff_ffff`, `0x1_8000_0000` up (bus addresses from `0x1_0000_0000`) |
  | `storage-bus` | eMMC, microSD, USB 3 (DWC3) | `0x0`–`0x7fff_ffff` only |

  `camera-bus` and `multimedia-bus` have windows but no devices in this
  DT yet. So storage and USB buffers must come from the first 2 GiB. The
  table is a reading of `k1.dtsi`; bring-up checks it.
- **No IOMMU.** DMA goes through BTIs without one (`drivers.md`), with a
  per-bus window and offset as above.

## Interrupts and timers

- **PLIC** at `0xe000_0000` (`"spacemit,k1-plic", "sifive,plic-1.0.0"`),
  159 sources, M and S contexts per hart. The kernel's PLIC path is the
  one that applies; there is no AIA, so `Aia.initialize` is never taken.
- **CLINT** at `0xe400_0000` (`"sifive,clint0"`), owned by M-mode
  firmware. The kernel's timer goes through SBI `set_timer`, as on QEMU;
  Sstc is available.
- **MSIs:** PCIe uses the DesignWare controller's own MSI block (256
  vectors), which raises one wired PLIC line per controller (`msi`,
  e.g. 141 for PCIe 0). Our MSI objects on rv64 need AIA's IMSICs and
  return NOT_SUPPORTED on the PLIC (`drivers.md`), so the kernel takes
  each host's block as an MSI frame (D156, msi(2)), which devmgr makes
  from what k1-pcie(3) found.

## Devices on the RV2

| Device | DT node / compatible | Address | Notes |
|---|---|---|---|
| Console UART | `uart0`, `"spacemit,k1-uart", "intel,xscale-uart"` | `0xd401_7000` | 16550-style, `reg-shift = 2`, 32-bit access, PLIC 42. `serial0`, `stdout-path` |
| Ethernet ×2 | `eth0`, `eth1`, `"spacemit,k1-emac"` | `0xcac8_0000`, `0xcac8_1000` | SpacemiT's own MAC (Linux `k1_emac.c`), not stmmac. RGMII, Motorcomm PHYs at MDIO 1 |
| eMMC | `emmc`, `"spacemit,k1-sdhci"` | `0xd428_1000` | 8-bit, HS400 |
| microSD | `sdhci0`, `"spacemit,k1-sdhci"` | `0xd428_0000` | UHS to SDR104, card detect on GPIO 80 |
| PCIe | `pcie1`, `pcie2`, `"spacemit,k1-pcie"` (DesignWare) | `0xca40_0000`, `0xca80_0000` | Each with its own PHY; slot power on GPIO 116 |
| USB 3 | `usb_dwc3`, `"spacemit,k1-dwc3"` | `0xc0a0_0000` | Host only, behind a Genesys Logic hub (`usb5e3,610`/`620`): the blue ports |
| USB 2 ×2 | `ehci`, `ehci1`, `"ky,mv-ehci"` (the vendor's, D157; upstream has none) | `0xc090_0100`, `0xc098_0100` | ChipIdea EHCI, one root port each: the white ports. PHYs at `0xc094_0000`, `0xc09c_0000`; PLIC 105, 118 |
| SPI NOR | `qspi`, `"jedec,spi-nor"` | `0xd420_c000` | Holds the boot chain: `bootinfo`, `fsbl`, `env`, `opensbi`, `uboot` |
| PMIC | SpacemiT P1 on `i2c8`, address `0x41` | — | Regulators and reboot (Linux `spacemit-p1-reboot.c`) |
| Status LED | `gpio-leds`, GPIO 96, active low | — | |
| Thermal | `"spacemit,k1-tsensor"` | `0xd401_8000` | |

Clocks and resets come from the `syscon_*` controllers (APBC, APMU,
MPMU), and pins from `pinctrl` at `0xd401_e000`. FreeBSD has drivers for
the clock units and the SDHCI only (`files.spacemit`); Linux has the rest.

## Firmware and boot

- **The shipped chain** is the SPI NOR's partitions: FSBL, OpenSBI,
  U-Boot. U-Boot gives the OS a devicetree. Linux has no ACPI IDs for the
  K1, so no ACPI tables are known to exist for it.
- **VectraOS is ACPI-only** (architecture §2). On the RV2 the loader
  meets that first (D51, the owner, 2026-10-30): it reads the DTB that
  U-Boot's EFI passes as a configuration table and fills the handoff, so
  the kernel never sees DT. ACPI firmware (below) can follow.

### Toward ACPI firmware (research, 2026-10-16)

No one ships ACPI tables for the K1, but the parts to make them exist:

- **SpacemiT's K1 EDK2 port** targets the MUSE Pi Pro, another K1 board.
  Its chain is FSBL (from U-Boot SPL; it trains DDR and loads the rest),
  OpenSBI (`FW_DYNAMIC`), then EDK2 in S-mode, all from SPI NOR. The
  firmware is a FIT `.itb` holding the EDK2 `.fd` and a DTB, and it
  boots GRUB from the EDK2 shell. Its Readme says it has no ACPI yet and
  passes the DTB. The groundwork is there: `Acpi66Temp.h` defines the
  ACPI 6.6 MADT PLIC structure (type `0x1B`), and the FV rules have an
  `ACPITABLE` section. Bianbu's guide (July 2025) says only SPI NOR
  boards can boot UEFI. An RV2 port is a board `.dsc` and the RV2's DT,
  if the RV2's FSBL and SPI NOR layout take an EDK2 payload.
- **SpacemiT's K3 EDK2 port has a full static table set**: MADT, RHCT,
  PPTT, SPCR, MCFG and FADT, and a DSDT with CPUs, UART, USB, PCI and the
  APLIC. It is a template for K1 tables. The K3 has AIA, so the K1's MADT
  replaces the IMSIC and APLIC entries with one PLIC entry (`0xe000_0000`,
  159 sources), and its RHCT carries the RVA22 ISA string, the Zicbom
  block size (64) and Sv39.
- **Upstream EDK2 can make the tables from the DT at boot.**
  `DynamicTablesPkg` has RISC-V MADT and RHCT generators, an SSDT for the
  PLIC and APLIC, and a serial-port fixup, fed by `FdtHwInfoParserLib`'s
  RISC-V parser (still being fixed in September and October 2026). Its
  PLIC parser accepts only `"riscv,plic0"`, and the K1's PLIC is
  `"spacemit,k1-plic", "sifive,plic-1.0.0"`, so this path needs that
  string added (a patch) or the DT's compatible changed.
- **U-Boot is the weaker path.** Its RISC-V ACPI passes through the
  tables QEMU supplies; nothing found shows it making a MADT or RHCT for
  real hardware. Mainline U-Boot's K1 support was still a patch series
  (v2) in May 2026.
- **The specs are settled.** ACPI 6.6 has the RISC-V MADT entries
  (RINTC, PLIC, APLIC, IMSIC) and the RHCT, and the RISC-V BRS 1.0 boot
  spec was ratified in August 2025. K1 tables would use only standard
  structures.
- **Settled since:** the K1's DesignWare PCIe has no ECAM an MCFG could
  name (its config window is 8 KiB, retargeted through the iATU), so its
  hosts are a driver's (D154, D156); and the clocks, resets and pins
  stay with the drivers, read from the tree (D154), with no `_DSD`.
- **To verify on the board:** that the shipped U-Boot runs a UEFI
  application (`bootefi`) and passes the memory map, and whether its SBI
  implements HSM (to start the other harts), SRST (reset and power off)
  and PMU.

## QEMU stand-in

QEMU has no K1 machine. `-machine virt -cpu rva22s64` gives the profile
without the board, which is what D51's baseline is tested against; the
board's devices are tested on the board.

## Bring-up (handoff, 2026-10-30)

V6b is driven from the Mac Studio, which has the SD card slot (the owner,
2026-10-30). Everything a session there needs to pick up from is below or
linked; nothing here depends on another machine's notes.

### Where rv64 stands

- **In QEMU, rv64 is complete:** the whole QEMU suite passes under `vx ci`
  (2026-10-30), tier 1 included (llvm 0005-0007,
  `tools/toolchain/riscv64.md`), on `-machine virt` with ACPI and edk2.
- **On the board, nothing has run yet.** No VectraOS code has executed on
  the RV2, and none of the facts above has been checked there.

### Before the board: three things

1. **The firmware path is decided** (D51, 2026-10-30): the loader reads
   the DTB first, with the shipped chain left as it is. ACPI firmware
   ("Toward ACPI firmware" above) can follow.
2. **RVA22 in the build, D51's follow-ups, half done:**
   - User code builds for `-march=rva22u64` (`cmake/arch/rv64.cmake`,
     `CROI_USER_CFLAGS`). The kernel and the loader still build for
     `rv64imac_zicsr_zifencei` (`CROI_ARCH_CFLAGS`), RVA20's floor: they
     should take RVA22S64's mandatory extensions.
   - QEMU's rv64 runs use `-cpu max` (`tools/qemu.sh`); D51 wants
     `-cpu rva22s64` as the floor beside it. The loader already refuses a
     hart below the profile (`boot-below-baseline`, `-cpu rv64,zba=false`,
     "baseline: no ...").
   - The Svpbmt fallback is still in the kernel (`Main.swift`: "no
     Svpbmt: PMAs decide memory types"); D51 retires it, since every
     RVA22 hart has Svpbmt.
   These are QEMU work and need no board.
3. **The Mac as the host: done** (2026-10-30). `vx` and what CMake asks
   SwiftPM for (IPC and its macro) build on macOS 27 (`Package.swift`'s
   `platforms`), through `HostSystem` (`tools/host`: Glibc or Darwin, and
   their differences), and `vx build rv64` makes the ESP. Not yet ported:
   the host test targets that compare against glibc (`system/libc/tests`,
   pthreads), idlc, and `tools/qemu.sh`'s edk2 path (Homebrew's QEMU ships
   `edk2-riscv-code.fd`). The tier 1 toolchain (`tools/toolchain`, hours
   to build) is needed only for tier 1's programs, not for the first boots.

### The DT path and the timer, in QEMU (2026-10-31)

- **The loader makes ACPI tables from the DT** (lib/dtacpi, intro(8)): a
  MADT, RHCT, SPCR, FADT and empty DSDT, with the X60's ISA from its
  SBI IDs when the tree lists base letters only. Checked on host against
  the RV2's tree's shape and on Planar's capture of it (8 harts, S
  contexts 1, 3, ... 15, 1344 bytes of tables), and in QEMU with
  `--no-acpi` (`boot-devicetree`, on the lean ESP: the drivers suite
  needs a device the tables don't describe): through `m2 exited with 0`;
  `vx ci` passes on brimstone with it.
- **The kernel's timer** arms through Sstc where every hart lists it,
  else SBI TIME, else the legacy set_timer; the `time:` line says which.
- **Open:** on the Mac's QEMU 11.1.2 (Homebrew's OpenSBI) every rv64
  boot with self-tests panics in `pmu self-test: overflow sampling` (no
  Sscofpmf overflow interrupt arrives), with ACPI or without. Brimstone's
  QEMU 10.2.2 passes it (58 samples), so it is QEMU 11's or its OpenSBI's,
  not the kernel's; rv64's self-test boots run on brimstone until then. Reboot
  through the SoC's watchdog came later (below, "Reset"), and so did
  the SoC's watchdog as the kernel's ("The SoC's watchdog, running").

### First kernel on the board (2026-10-31)

The DT card (`build/rv64/esp`, `croi.test=all`): the loader made the
tables (`8 harts, isa from the core's IDs, core 0x710/0x8000000058000001`)
and the kernel ran: 8 of 8 harts, 8183 MiB, the RVA22 ISA with Svpbmt in
use, V at 256 bits, the 24 MHz timer armed through Sstc, the boot
framebuffer's test pattern on HDMI. Its self-tests passed through `sys:`
(SMP, IPIs and shootdowns, scheduler, EDF, mutexes, trace, VM, VMOs, TLB,
phys and cache ops, objects, ports, user mode).

- **It stalls in the vDSO self-test**, with Sstc and with
  `croi.timer=sbi` (SBI's legacy set_timer) alike: the user side's 1 ms
  futex timeout on cpu 7 fired 18 s late (Sstc; the dump: cpu 7 idle
  with `timers 1 pending, hardware disarmed`, then `preempt pending`),
  or never (SBI, where the stuck report's own timer never came). It
  begins as the test's kernel writer loops on cpu 0. QEMU doesn't show
  it. The late interrupt's PC, against the kernel that ran, is
  `arch_wait_for_interrupt` just past `wfi; csrsi sstatus, SIE`: cpu 7
  slept in WFI with its timer due and didn't wake for 18 s. So an idle
  X60 hart isn't woken by its timer while another hart stores in a tight
  loop; plain idle wakes fine (the lean card).

  **That reading was wrong; fixed 2026-10-31.** Probes on the board
  (stimecmp read back, a per-CPU log of timer, scheduler, fault and
  heap events, a once-a-second report IPI) showed cpu 7 armed exactly
  what the timer queue held, and the user thread not yet blocked: it
  spent the 18 s at `futex_wait`'s syscall entry, in
  `Syscalls.count.add(1)`, taking no interrupt until it got through.
  Swift's `add` checks overflow, so it is an `lr.d`/`sc.d` loop, and
  that counter shares a cache line with
  `SharedPages.lock`, which the test's writer took and released in a
  tight loop by compare-and-swap, an `lr.w`/`sc.w` loop. On the X60 the
  second hart's LR/SC didn't complete while the first looped, until the
  first was interrupted (the self-test watchdog at 20 s, or a probe's
  timer). Everything that looked like a missed wakeup was a thread not
  yet asleep. Planar takes its spinlocks with `atomic_exchange`, an
  `amoswap`, which is why it never met this. Now every kernel spin lock
  is taken by exchange (`cpu.md`, Locking) and the syscall counter uses
  `wrappingAdd`: 5 boots of 5 through the vDSO test with no stall, where
  the kernels before stalled in most. Ruled out on the way, each on the
  board: WFI (an idle that polled stalled the same way), `pause` (a
  `nop` stalled too), lost IPIs (none was ever late), lost `stimecmp`
  writes (all read back), and SBI HSM suspend (its three silent boots
  look like the early hang below, not HSM).
- **The PMU self-test's overflow sampling** then failed (`overflows
  0`): LCOFI is delegated and enabled (`sie` 0x2222), but the SBI gave
  the cycles event counter 0, `cycle`, which wrapped with no OF bit to
  set. Probes on the board (2026-10-31), against the vendor kernel's
  PMU node (`orange-pi-6.6-ky`, `arch/riscv/boot/dts/ky/x1.dtsi`):
  its OpenSBI 1.3 gives cycles (1) and instructions (2) `cycle` and
  `instret` whatever the counter mask; branch instructions and misses
  and the stall events (5, 6, 8, 9) go to `hpmcounter3`-`18` (mask
  0x7fff8) and count (20003 branches for 20000 loop passes); cache
  events 3, 4, 7 and 10 are refused. Raw events (type 2, the X60's
  code as data: `s_mode_cycle` 0x21 and the rest of 1-0xff, from the
  vendor's `tools/perf/pmu-events/arch/riscv/ky/x60`) are accepted on
  `hpmcounter18` and count nothing, though raw 0x01 is the very
  `mhpmevent` the map gives branch instructions; the vendor kernel
  encodes them the same way. Now sampling takes only an hpmcounter and
  refuses an event the SBI won't put on one, and the self-test samples
  SBI branch instructions where cycles are refused (pmu(2), BUGS).
  The Mac's QEMU 11 failure (above) is something else: it still fails.
- **Every kernel and program self-test passes** with that (2026-10-31,
  `croi.test=boot,kernel,programs`), then `bin/m2 exited with 0`: 7
  boots of 7 in a row. The IOMMU test skips (the tables describe none)
  and the DMA test runs on the stub BTI. `croi.test=all` also runs the
  drivers suite, which reads a device behind an ECAM window
  (`swift.ecam=`) the tables from the DT don't describe, and fails
  there; the card names the groups instead, as the Orange Pi 6 Plus's
  `croi.test=kernel` does.
- **An intermittent hang after the PMU test**, in the 3 boots before
  those 7, in the process self-test, once again in the IPC test: user
  threads running on one or two CPUs for 20 s, a blocked thread whose
  timer had left its queue without waking it (`armed@4 (not in its
  queue)`), and idle CPUs with a reschedule IPI's bit still in their
  mailbox. With the deadman asking every CPU where it is (by IPI), all
  were idle in `wfi`, and the stuck test then went on; the SBI refused
  no `send_ipi` (an error count, 0). So a wakeup that an IPI completes
  went missing; where, is open.

  More boots with probes (2026-10-31) narrowed it. It now comes in most
  boots, always just after the PMU test, on U-Boot's tree or ours
  alike. A CPU sits with interrupts masked for up to about half a
  second at a time, and its timer and the IPIs sent to it wait: one
  caught with `stimecmp` holding exactly the deadline the queue armed,
  STIP pending and STIE enabled, took both the moment it unmasked; a
  TLB shootdown's caller waited seconds for idle CPUs' acks the same
  way. Ruled out, each on the board: `wfi` (500 timer and 200 IPI
  wakeups, every one on time), the idle loop's one-instruction SIE
  window (0 IPIs of 1000 left pending), IPI delivery (2-3 us round
  trips to every CPU), timer arming (masked, per CPU), the locks' LR/SC
  (they are word AMOs), and PMU overflow sampling (it hangs with the
  sampling skipped). Spin probes at 2 s, 0.5 s and 0.1 s on every
  masked spin made it rarer and caught none at 0.1 s: where a CPU
  waits masked is open (the probes, a timed report on each masked spin
  lock, IPI wait and timer-queue lock, aren't in the tree).

  **Found and fixed (2026-10-31): the IPI acknowledgement's LR/SC.**
  `Ipi.call`'s caller spins, masked, loading `remaining`, and callers
  waiting their turn swap `busy` beside it; each target acknowledged
  with `remaining.subtract(1)`, which Swift compiles to a
  compare-and-swap loop. On the X60 that loop failed while the line was
  hammered (the vDSO stall's starvation again), holding the target in
  its IPI handler, masked, and its caller behind it: their timers fired
  late, idle CPUs' wakeups waited, and the probes' printing, which
  slowed the spinners, made it rarer. With the acknowledgement a
  `wrappingSubtract` (one `amoadd`), three boots of three ran on to
  `m2 exited` with no late IPI or timer, where the four before all hung;
  a late timer now prints its CPU's backtrace on rv64 too.
- **Other LR/SC in the kernel: done** (2026-10-31). Every checked
  atomic `add`/`subtract` (72) is now a wrapping AMO, an exchanged flag a
  word, and the build refuses a new checked one; the image's LR/SC
  sites went from 185 to 51, all compare-and-swaps nothing spins on.
- **One boot hung silently after `croi loader: starting kernel`**,
  before the kernel's first line, with an unchanged image. Open.
- **DMA's cache maintenance is in place:** VMO cache ops, which drivers
  use for non-coherent DMA, run Zicbom's `cbo.clean`/`inval`/`flush` at
  the RHCT's block size, and the board's self-test says `cache ops
  (line 64 B)`. `arch_clean_dcache`, a bare `ret` on rv64, serves only
  the AP start block and warm boot, which the harts' coherent caches
  and rv64's missing warm boot leave unneeded.
- **No watchdog reset** in minutes of the stall: through `bootefi`, the
  watchdogs Planar found under `booti` didn't fire.
- **User space runs** (the lean card, `build/rv64/esp-lean`: no kernel
  self-tests): userboot 213 ms after kernel entry (firmware 6.2 s, the
  loader 2.8 s), `bin/m2`'s checks pass, idle 500 ms with no stray
  wakeup, `m2 exited with 0`, and power-off through SBI's legacy call.
  Its budgets, reported: null syscall 439 ns (100), channel_call 11.4 us
  (1.6), port wake median 8.0 us (2.0), ring 262 us per 1000 slots (10),
  spawn to main 881 us (200); timer wake error p99 4.5 us (100). The
  first numbers for the X60; whether they are the core or our code is
  `vx bench`'s question.

### On the board, in V6b's order

- **First, the shipped chain**: checked (below, "The shipped chain, as
  found"). Distro boot already runs `efi/boot/bootriscv64.efi` from a
  card's FAT partition, so the loader's banner on the console is the
  first thing to see.
- **The card's layout** is the ESP the build makes, a FAT partition:
  `\EFI\BOOT\BOOTRISCV64.EFI` (the loader) and `\croi\` (`kernel.elf`,
  `bootfs.img`, `cmdline`), as `build/rv64/esp/` holds it. Leave the SPI
  NOR's shipped chain as it is unless the firmware decision says
  otherwise: booting from the card keeps the board recoverable.
- **The console** is UART0 (table above: `0xd401_7000`, 16550-style,
  `reg-shift = 2`, 32-bit access) through a 3.3 V USB-serial adapter on
  the RV2's debug header, at 115200 8N1; its pinout is still to be
  written here. On the Mac, set the rate on a descriptor that stays open
  (`stty ... <&3`): macOS resets a `cu` device to 9600 when its last
  descriptor closes, so `stty -f` alone reads garbage. One reader at a
  time: a second (screen beside a logger) splits the bytes.
- **Then** V6b's steps in the roadmap: the platform (8 harts by SBI HSM,
  the PLIC, the SBI timer, DMA windows with no IOMMU), the K1 EMAC, V3's
  link, then storage, PCIe and USB.
- **The platform is in place** (2026-10-31): 8 harts, the PLIC, the
  timer through Sstc, cache ops through Zicbom. The EMAC, SDHCI and
  the rest are described only by the tree, so they wait for D154's
  path: the tree in the boot data (done: `ACPI: ... devicetree N
  bytes`), our own tree built by `vx dtc` from upstream's
  `k1-orangepi-rv2.dts`, `drivers/bus/dt`, and the APMU's clocks and
  resets as providers. The driver follows upstream's binding
  (`spacemit,k1-emac`, Linux's `k1_emac.c`); U-Boot's tree names it
  `ky,x1-emac` and leaves out its interrupt (131).
- **Our tree on the board** (2026-10-31): the loader finds U-Boot's
  tree is `"ky,x1"` with `model "ky x1 orangepi-rv2 board"`, picks
  `dtb/spacemit/k1-orangepi-rv2.dtb` by that firmware identity, merges
  U-Boot's `reserved-memory` (OpenSBI's 512 KiB at 0, the boot
  framebuffer), and makes the tables from it (`devicetree: ours, ...
  (the firmware's identity)`, 32976 bytes): 8 harts with upstream's
  ISA list and Zfhmin added, the same PLIC contexts as U-Boot's tree
  gives, the console, and every kernel self-test through PMU; the
  hang above has kept it from `m2 exited` so far.
- **devmgr reads the tree** (2026-10-31, `drivers/bus/dt`): the
  devicetree card (`build/rv64/esp-devicetree-bus`, dt-test(8)) lists
  30 devices from our tree, each with its `reg` ranges at CPU addresses
  and its PLIC source: the EMACs at `0xcac80000` (131) and `0xcac81000`
  (133), the SDHCIs at `0xd4280000` (99) and `0xd4281000` (101), the
  UART, PDMA, QSPI, both PCIe hosts, DWC3, the syscons, GPIO and
  pinctrl, and the board's regulators and LEDs; every one
  `noncoherent`, as the K1's `soc` node says. None binds yet: the EMAC
  waits for its driver, and that for the APMU's clocks and resets.
  With no NIC the board image's `net` doesn't answer, so the full
  image's launcher still exits 1 here.
- **The APBC and APMU, the first providers** (2026-10-31,
  `drivers/clock/k1-syscon`): on the same card, devmgr reads each
  device's links (the EMAC's `clocks` are the APMU's 37, its `resets`
  its 35) and binds k1-syscon(3) to both units, `apbc: 102 clocks, 51
  resets` and `apmu: 62 clocks, 53 resets`, before anything that links
  to them. dt-test turns on the first clock a device names on a running
  unit, the APMU's 16 (`usb30`), through its `ctl`, and its `status`
  reads it back `on`. The first try failed: the units' services
  (`k1-syscon-dt-system-controller@d4015000`, 39 bytes) were longer than
  the kernel's 32-byte process names, and `process_create` refused them;
  Sys now cuts a process's name. No consumer's driver runs yet, so
  `/dev/provider` waits for the EMAC's to be used here.
- **Both EMACs, with the pins** (2026-10-31, `drivers/net/k1-emac`,
  `drivers/pinctrl/k1-pinctrl`): k1-emac(3) reads its node's
  properties at `/dev/dt/node` and turns on its links through its
  providers: its `default` pin state through k1-pinctrl(3), its clock
  and reset, and its interface and delay lines (`spacemit,apmu`, the
  APMU's `0x3e4` and `0x3ec`, the register that is also EMAC 0's gate
  and reset) through k1-syscon. On the first try EMAC 0's PHY answered
  on its MDIO bus (id `0x4f51e91b`, a Motorcomm YT8531, at 1) and EMAC
  1's didn't, at any address: U-Boot had muxed only EMAC 0's pins. With
  the pin controller setting `gmac1-cfg` (pins 29 to 43, function 1),
  both answer, and dt-test passes with 5 drivers bound. Neither tree
  nor MAC held an address (U-Boot's environment has `C0:74:2B:FC:D4:E6`
  and `...:E7`, but its tree passes neither), so each MAC takes a random
  local one. With a cable in EMAC 1's port, dt-test (which waits for a
  link) saw `link up, 1000 Mb/s full duplex` 3 s after boot and 2 frames
  received from the LAN in 5 s, none dropped: the receive ring works,
  uncached, below 4 GiB. Nothing in that image sends, so transmit waits
  for V3's link. The PHYs' reset lines (GPIO 110 and 115) had no driver then, and
  were as U-Boot left them (below, "The PHYs' resets").
- **V3's link** (2026-10-31): rv64's `bootfs-board-cpu.img`, built on
  brimstone (rc is tier 1, and the Mac has no tier 1 toolchain) with the
  Mac's terminal key added (`-DCROI_CPU_PEERS=`, `vx cpu --show-key`),
  and the card's cmdline `userboot.next=bin/launcher
  croi.debug_syscalls=on croi.halt_on_panic=false`. The board has no
  disk yet, so the image leaves out fs and the services that need its
  volume (swarm, minimal-hot, peer-bench); cpu's and the shell's /data
  are `optional`, and the launcher leaves a mount of a service the image
  hasn't out (manifest(6)). factotum then has no volume, so the node's
  key is new each boot: read it from cpu's `listening` line. net takes
  `/net/ether0`, EMAC 0, so the cable goes in that port. 3 s after
  boot the link was up, at 5 s DHCP gave 192.168.0.16 (so transmit
  works), and `vx cpu -k KEY 192.168.0.16` from the Mac ran rc there:
  `ps`, `/net/ipifc`, and the Mac's files at `/mnt/term`. Two fixes on
  the way: peer-bench's cycle loop had no rv64 instruction, and the Mac's
  `vx cpu` trapped serving its `/dev` (Darwin's `dev_t` is signed, and
  devfs's is negative). `ramdisk(4)` exists; fs on it would give a
  /data that lasts a boot, before SDHCI.
- **Warm boot** (2026-10-31, D101 on rv64): from the Mac, `vx remote
  boot rv64 --kernel K --bootfs B -k KEY 192.168.0.31` with brimstone's
  kernel and `bootfs-board-cpu.img` (the Mac can't build rc), 112 MB
  copied at 16 MB/s, the kernel's part 71 ms, the new boot's cpu server
  answering 3.74 s after the copies (the PHY's autonegotiation is 3 s of
  that; `remote.warmboot`'s limit is 2 s, the board images' 5 s), 8 of 8
  harts back, twice in a row. What it took:
  - **The other harts** stop through SBI HSM's hart_stop after a
    fence.i, and the trampoline writes satp as the loader does
    (boot.md); boot-warmboot now runs on rv64 too.
  - **The EMACs' DMA**: there is no IOMMU, so devmgr holds each running
    tree device in reset (its `resets`, through k1-syscon) before the
    kernel's call, as it clears bus mastering on PCI. The first try hung
    the board silently right after devmgr's `warm boot` line: the
    drivers were still polling their MACs, and on the K1 a read of a
    block in reset stalls the hart that makes it. Now devmgr ends each
    driver first (the launcher's `end`, no restart), then resets.
  - **One node across boots**: with no volume, factotum's key was new
    each boot, so rv64's board cpu image carries a key `vx cpu-keys`
    makes once on the build machine (`build/rv64/cpu/node.keys`, its
    public half in `node.pub`): `3daa3c16...` on brimstone.
  - **One address across boots**: the MACs were random, so DHCP gave a
    new address each boot. They are in an ONIE TlvInfo EEPROM (an
    `atmel,24c02` at 0x50 on TWSI2, `0xd4012000`) that U-Boot reads and
    publishes nowhere: not in its tree, its environment's `ethaddr`
    aside, nor as a UEFI Simple Network Protocol (tried: none). The loader
    now reads it, polled, the TWSI's APBC clock and reset (0x38) set
    first, and puts `c0:74:2b:fc:d4:e6` and `:e7` in our tree as
    `ethernet0`'s and `ethernet1`'s `local-mac-address` (about 0.3 s of
    loader time). DHCP then gives 192.168.0.31, as it gave U-Boot. Tried
    first and dropped: a `k1-emac.mac.<unit>=` boot option, which a
    driver never sees (the command line is the launcher's environment
    only).
- **The native suite** (2026-10-31): `vx remote test rv64 --serial
  /dev/cu.usbserial-ABSCDIMD --kernel K --bootfs B -k KEY orangepi-rv2
  192.168.0.31`, with brimstone's rv64 `kernel.elf` and `bootfs.img`
  (boot-smoke's, tier 1 in it), warm-boots the board into
  `croi.test=all` and judges its console: the kernel's self-tests, then
  every Swift suite, `bin/m2 exited with 0` 7.9 s into the boot. The
  drivers suite had needed a PCI function to read (`swift.ecam=`); with
  no ECAM window it now skips those resource checks and says so. Stop
  the console logger first: one reader at a time. 8 of 17 budgets are
  over their limits (reported): `syscall.null` 427 ns, `ipc.channel_call`
  11.6 us, `port.wake_median` 7.8 us, `counter.wake_median` 6.5 us,
  `ring.per_1000_slots` 262 us, `ring.round_trip` 921 ns,
  `process.spawn_to_main` 885 us, `trace.probe_enabled` 158 ns; to be looked at on the board before
  V6b's exit. Recorded with `--record` (2026-11-01, 788a1ea) in
  `docs/hardware/runs.tsv`; the board and its required components are
  experimental in `support.tsv`. The suite ends in
  `userboot.shutdown=reboot`, and the board stopped there (SBI SRST
  hangs) until it needed a power cycle each run.
- **The clocks under those budgets** (2026-11-02): not the cause.
  Read on the board (spec 01 §1.4-1.8, 14): firmware leaves PLL3 at
  3200 MHz (`SWCR1` 0x0050DD67, `SWCR3` 0xC3EAAAAB) and both clusters
  on its `HI` source, `PLL3_D2` (APMU 0x38C and 0x390 read 0x247: mux 7,
  bit 13 clear, ACE and TCM ÷2), so the harts run at 1.6 GHz, mainline's
  top point, and frequency scaling has nothing to raise. The one low
  clock, the CCI550 interconnect at 245.76 MHz (0x300 = 0x110:
  `PLL1_491` ÷2), was set to the vendor's 614.4 MHz (`PLL1_614` ÷1, FC
  clear at once) by a scratch kernel, and the native suite, run against
  the committed kernel and then it with one bootfs, moved by noise:
  `ipc.channel_call` 11.7 to 11.2 us, `counter.wake_median` 6.2 to 5.7
  us, `process.spawn_to_main` 879 to 852 us, the rest within 2%. So the
  eight are the X60's cost of our paths or our paths: `syscall.null` is
  about 680 cycles, `ring.per_1000_slots` about 420 cycles a slot.
- **The X60's primitives** (2026-11-02), timed on the board by scratch
  loops of a million each (rdtime's 24 MHz) in m2 and at the kernel's
  boot, at 1.6 GHz: a fence (`rw,rw`, `r,rw`, `rw,w` or `w,w`) 1.9 ns,
  an L1 load and store 2.5 ns, `amoadd.d` 8.1 ns (8.8 with `.aqrl`), an
  LR/SC increment 9.4 ns, `rdtime` 7.5 ns (not trapped), the vDSO's
  clock 45.6 ns; `csrr` of `sstatus`, `sscratch` or `sepc` 6.3 ns, a
  write of `sscratch` or `sepc` 6.9 ns, but a write of `sstatus` 11.3 ns
  (`csrrci`, and `csrs` of a zero register, which still writes), a set
  and clear 18 ns. A cache line passed between two harts and back takes
  265 ns, the same within a cluster (1 and 2) as across them (1 and 5).
  So fences and atomics are cheap, and the line's round trip is the
  cost: `ring.per_1000_slots`, 263 ns a slot, is one round trip a slot
  (64-byte slots, a line each; why, in the next entry); the cross-core
  wakes are a few of them each. A null
  syscall, timed in stages by a scratch kernel (whose stamps cost about
  15 ns each): the trap and user loop about 190 ns, `run` about 70, the
  exit's suspend check, preemption check and mask about 90, `leaving`
  about 70; about ten `sstatus` writes (each `Scheduler.current` masks
  and restores) are some 100 ns of it.
- **The ring bench, prefetched and profiled** (2026-11-02), by a scratch
  m2 (200,000 slots a run unless said; harts 1 and 2):
  - The bench runs in lockstep. Its 256-slot ring went in 782 batches
    of 256: the producer fills every free slot and publishes once, the
    consumer drains every ready slot and releases once, so each side
    waits while the other works. PC samples (10 kHz, 8 M slots) put
    about 45% of each side's on its spin over the other's cursor. A
    slot costs the producer's miss on the line plus the consumer's,
    one after the other: 265 ns.
  - Capping a batch, so each side publishes or releases as it goes,
    lets the two overlap: 131 ns a slot at 64 or 32 slots a batch,
    136 at 16, 152 at 8, 181 at 4, 278 to 335 at 1 (a cursor's line
    then moves every slot too). At 64 the samples are in the slot copy
    (libc's `copyForward`, a word at a time): the consumer's first load
    of a slot and the producer's stores to a line the consumer last
    read, each waiting out one line's transfer, about 130 ns, half the
    round trip.
  - Zicbop works: strided loads over 16 MB (4160 bytes apart, past the
    stream prefetcher) take 215 ns each, 88 with `prefetch.r` 2 ahead,
    52 with 8 or 32. But it doesn't help the ring: `prefetch.w` in the
    producer and `prefetch.r` in the consumer, 1 to 16 slots ahead, cost
    20 to 30 ns a slot at every batch size but 1, where 4 ahead took
    335 to 290. Lines another hart holds don't overlap as DRAM's do.
  - Nor does Zicbom (user mode has it: `senvcfg.CBCFE`). `cbo.clean` or
    `cbo.flush` of each slot by the producer, meant to leave it where
    the consumer finds it without asking the producer's L1, took a slot
    from 265 to 391 or 420 ns in lockstep and from 141 to 243 or 259 at
    64 a batch; the consumer's `cbo.flush` after its read, 240 at 64;
    both, 460. The write-backs go to memory. The X60 has no Zihintntl
    or Zawrs (its ISA string: `zicbom_zicbop_zicboz_zihintpause`).
    What the literature does for such rings (FastForward's temporal
    slipping, MCRingBuffer's batched cursor updates) is the batching
    above, or FastForward's other half, below.
  - FastForward's slots (Giacomoni et al., PPoPP 2008), in a scratch
    m2: no shared cursors, a slot's first word its flag (0 empty, n + 1
    holding entry n), the consumer clearing it after its read. The
    same 256 slots of 64 bytes, harts 1 and 2, interleaved with the
    ring: 80 ns a slot (80.3 to 85.0 over eight runs) against the
    ring's 261 in lockstep and 128 to 137 at 64 a batch, and a round
    trip (64-slot rings each way, one submission at a time) 380 ns
    against `ring.round_trip`'s 917. Each slot's line moves twice a
    lap and no cursor's line moves at all; the waits land on different
    slots, so the two sides' misses overlap. `prefetch.w` 4 to 64 slots
    ahead, either side, made it slower again (84.5 to 97.7). Still some
    8 times the throughput limit, and the round trip over 300.
  - The same three on the other arches (2026-11-02). amd64: the same
    scratch m2, three lean boots under KVM on brimstone (load 4.5 to
    5): the ring 4.25 to 4.47 ns a slot in lockstep, 2.91 to 3.05 at 64
    a batch, FastForward 2.54 to 3.10; round trips 86 to 97 (the ring)
    and 93 to 96. arm64: the Orange Pi 6 Plus under FreeBSD 16 (not
    VectraOS), a C port of the three (the ring's layout and protocol as
    ring.h's, 4 M slots, threads pinned by cpuset, powerd stopped and
    every clock domain at its top), three runs a pair. The A720 pairs
    (0,1; 6,7; 8,9; 10,11; 0,6): the ring 27 to 31 ns a slot in
    lockstep, 26 to 28 at 64, FastForward 60 to 63; round trips 372 to
    419 and 346 to 396. CPUs 1 and 2 (m2's pair; 2 is an A520): 36,
    34.5, 127 to 134; 489 to 551 and 401. The A520s 2 and 3: 28 to 35,
    31, 113; 615 to 633 and 461. Each process's first lockstep run was
    7.4 to 20 ns and every later one 27 to 39, whatever ran before it
    and on fresh pages too: not explained. VectraOS's own figure there
    is 14 ns (the roadmap's).
  - So FastForward isn't a win everywhere: its throughput is 3.3 times
    the ring's on rv64, about the batched ring's on amd64, and a half to
    a quarter of it on arm64; its round trip is 2.4 times faster on
    rv64, 5 to 25% on arm64, the same on amd64. Batching the ring's
    cursors at 64 is twice as fast on rv64, 1.5 times on amd64, and
    about the same on arm64 (26 to 28 against 27 to 31 on the A720s),
    slower nowhere by more than the noise but the A520 pair (31 against
    28 to 35).
  - The SBI PMU's per-thread counts: 423 cycles and about 520
    (producer) and 610 (consumer) instructions a slot in lockstep, 210
    cycles and 285 instructions at 64 (in lockstep most of them spin).
    OpenSBI accepts the SBI L1D read and write miss events and counts
    nothing on them.
  - So on the X60 a slot handed from hart to hart costs one line's
    transfer, about 130 ns, with no overlap between slots: some 13
    times `ring.per_1000_slots`'s limit (10 ns a slot) at best. The
    round trip's 921 ns is about seven of them (each ring's cursor and
    slot, out and back).
- **Reset** (2026-11-01): the kernel resets the K1 through the SoC's
  watchdog (a match at the next tick, as Planar does), a board rule
  (D126) before SBI SRST. The loader names its tables for the SoC
  (`VECTRA` / `k1`, the tree's last compatible without its vendor),
  and the boot says `board: SpacemiT K1 (VECTRA k1): reset through the
  SoC's watchdog`. After the native suite the board went back through
  U-Boot to the card's loader by itself; `power.reboot_kernel` 16 us.
  Shutdown through SRST hangs; the P1 PMIC turns the board off instead
  (below, "Power off through the P1").
- **The microSD card** (2026-11-01, `drivers/block/sdhci`): sdhci(3)
  is a generic SD host driver, PCI's SD hosts (QEMU's sdhci-pci, which
  boot-sdhci tests on every arch) and the K1's `spacemit,k1-sdhci`. On
  the K1 it sets its pins, clocks and resets through the providers and
  asks k1-syscon(3) for its `io` clock at 204.8 MHz (PLL1's 409.6 MHz
  halved: `clock ID rate HZ`, the SDHCI clocks' mux and divider, since
  the controller's capabilities give no base clock), turns its PHY on
  and sets its pads as Linux does. Warm-booted into the cpu image, the
  card the board boots from came up as `sdhci: LX32G: 61952000 sectors
  (30250 MiB), high capacity, 4-bit at 34 MHz (high speed), uncached
  DMA` at `/dev/sdM0`, and its first 32 MiB, read over `vx cpu`, were
  its MBR and the FAT32 ESP's boot sector (`VECTRAOS`). The eMMC's
  SDHCI, also bound, says `no SD card or eMMC answers`: this RV2 has no
  eMMC module fitted (U-Boot's `Card did not respond to voltage select`
  on `sdh@d4281000` every boot). sdhci brings an eMMC up where SD's
  ACMD41 finds nothing (CMD1, EXT_CSD, CMD6 to 8 or 4 bits and high
  speed), checked in QEMU's `emmc` beside a card (boot-sdhci). Still 3.3 V (UHS needs the
  PMIC's aldo1), no card detect then (GPIO 80 had no driver; it is
  watched now, below). That read ran
  at about 1.6 MB/s end to end, `cat` through the cpu link, not yet
  measured on the board alone.
- **PCIe, before a drive** (2026-11-01, D156): k1-gpio(3) and
  regulator-fixed(3) switch the M.2 slots' 3.3 V, GPIO 116, which U-Boot
  leaves on (an output, high); `off` drops it, and with it GPIOs 112
  and 117, which follow the rail. The combo PHY is calibrated by
  firmware (`rx 8 tx 5`), and both port PHYs' PLLs lock (k1-pcie-phy(3)).
  The hosts' cores are DesignWare 5.95a; with both slots empty each
  trains for 900 ms and stops in Polling.Compliance (LTSSM 0x3), not
  Detect: something on the lanes passes receiver detection. The two
  train in parallel, after devmgr's first pass. Next, with a drive: the
  link, its BARs, the MSI frame's first vectors, and nvme(3).
- **USB, the controller** (2026-11-01): xhci(3) binds the DWC3 by its
  tree: its clock on, its three resets pulsed, the hub's VBUS (GPIO 123,
  regulator-fixed(3)) on, k1-usb2-phy(3) and the combo PHY as USB 3's
  (k1-pcie-phy(3)) on; its core reads `0x5533330a` (DWC_usb3 3.30a)
  and is made a host, and its xHCI comes up as `xHCI 1.10, 2 ports, 64
  slots, 64-byte contexts`, firmware letting go, on PLIC 125. Its DMA
  stays in the first 2 GiB because the storage bus's `dma-ranges` says
  so (devmgr reads each bus's). Behind it both halves of the Genesys
  hub: `05e3:0610` on root port 1 (high speed) and `05e3:0620` on root
  port 2 (SuperSpeed), 4 ports each. The SuperSpeed half at first failed
  Address Device with a transaction error (completion 4): xhci didn't
  reset a USB 3 root port, so the hub stayed addressed from U-Boot or
  the kernel before a warm boot; it now resets them, as Linux does. A
  keyboard (`1a2c:506f`) and a mouse (`30fa:0300`, read by its report
  descriptor), both low speed, on the hub's ports 2 and 4: 40 keys to
  kbdfs and 199 pointer reports to mouse, none refused, no transfer
  errors. The blue ports are the hub's; the white ones are the K1's
  other USB 2 controllers (EHCI and OTG).
- **USB, the white ports** (2026-11-01, D157): upstream's tree has no
  node for the K1's two ChipIdea EHCI controllers, so our board file
  (`firmware/dts/vectraos/spacemit/`) adds the vendor's, with their
  PHYs (k1-usb2-phy(3), `ky,usb2-phy`) and a `regulator-fixed` for the
  first port's VBUS (GPIO 126); the second's is the hub's (GPIO 123).
  ehci(3) binds both. At first each timed out halting the controller:
  a ChipIdea controller not yet a host (USBMODE idle) never reports
  HCHalted, so, as Linux does, it is only reset and then made a host.
  Each has one root port. A low-speed mouse (`30fa:0300`) on the first
  is reached through the port's own transaction translator by split
  transactions (hub address 0, the root port); 1817 pointer reports to
  mouse, none refused, no transfer errors.
- **I2C and the PMIC** (2026-11-01, D158): devmgr makes the P1 on
  `i2c8` (`0x41`) a device linked to its controller; k1-i2c(3) serves
  the bus at 400 kHz and p1(3) reads the chip through it: version
  `0xb`; buck1 1.05 V, buck2 0.9 V, buck3 1.8 V, buck4 3.3 V, buck5
  2.1 V, buck6 1.1 V, aldo1 (the SD card's signalling) 3.3 V, dldo1
  1.2 V, dldo4 and dldo6 1.8 V, all on; dldo5 off. At first every
  register read 0 and each transfer timed out: TWSI8's gate and reset
  share APBC 0x20, which reads back 0, so k1-syscon releasing the reset
  by read-modify-write turned the clock it had just turned on off
  again; it now changes the value it last wrote there.
- **The RTC as UTC** (2026-11-02): the P1's clock wasn't counting
  (2000-01-01T00:00:00); p1(3) starts it as the vendor's driver does,
  devmgr mounts p1's tree at `dev/rtc0`, and the time service, now in
  rv64's images (`time-devmgr.manifest`), publishes UTC from it 0.5 s
  into boot. Set from the Mac through a cpu session (`echo set
  2026-11-02T02:17:10Z >/svc/time/ctl`), it read 02:17:30 at a warm
  boot 20 s later. It doesn't keep time unplugged: after a power
  cycle it read 2000-01-01T00:00:00 again, so the board gives the P1
  no backup supply.
- **SD UHS, tried and parked** (2026-11-02): p1(3) sets a regulator's
  voltage (`voltage aldo1 1800000`), k1-syscon(3) writes the APBC's
  keys (`unlock`), and k1-pinctrl(3) sets the SD pads' I/O power domain
  (AIB `0x81c`, bit 2) for the `uhs` state, read back set. sdhci asked
  the card (a 32 GB `LX32G`) for 1.8 V; it said yes (S18A) and took
  CMD11, and the switch went as Linux's goes (clock stopped, aldo1 to
  1.8 V, the controller's bit, the pads, 10 ms, clock back), but CMD
  and DAT[3:0] read low after CMD11 and stayed low 100 ms after the
  clock came back. Tried four ways: the vendor's register order, the
  PHY off (the vendor's BROKEN_PHY_MODULE), then upstream's settings
  (the pad clock, the card clock always on, the domain written as its
  bit alone). With the card idle and no CMD11, the lines read high at
  every step to 1.8 V, so the pads read 1.8 V. A card left in the
  switch answers nothing until the board loses power (its buck4 is
  always on), taking the taisce partition and so `fs` and the launcher
  with it: each try cost a power cycle. UHS is off in sdhci; the next
  step needs aldo1 and the clock pin on a scope, or a Linux that runs
  this card at SDR104 on this board to compare against.
- **Power off through the P1** (2026-11-02): `echo poweroff
  >/dev/rtc0/ctl` from a cpu session sets the P1's shutdown bit
  (PWR_CTRL2 `0x7e`, bit 2, as the vendor's driver does), and the board
  went off within a second: the console stopped mid-line, and nothing
  answered on the LAN after it. reboot(8)'s `poweroff` now goes there
  too: p1's driver manifest says `poweroff` (driver(6)), and devmgr
  writes it to p1's `ctl` before asking SBI, which hangs here. `vx cpu
  -c poweroff` turned the board off 70 ms into the session.
- **The SoC's watchdog, running** (2026-11-02): the kernel arms the
  K1's watchdog for 30 s and refreshes it every 20-25 s, as the SBSA
  one on the Orange Pi 6 Plus (boot.md, a board rule). A scratch kernel
  that masked interrupts and spun once it was armed was reset by it
  and came back through U-Boot by itself, with no power cycle; the
  real one ran 100 s and more without a reset. What the kernel finds
  at boot, read raw: U-Boot leaves the watchdog stopped (WMER 0) with
  its own 60 s match (WMR `0x3c00`), and clears WSR, so a hang reads
  as a power-on; ARSR keeps the reason a reboot through it writes
  (`0x10c`, `0xc` after a hang), so `log` says `watchdog: the last
  reset was a reboot through it`. The boot line is `wdog: the K1's
  watchdog on, 30 s timeout, ...`.
- **The PHYs' resets** (2026-11-02): each EMAC's `mdio-bus` names its
  YT8531's reset line, GPIO 110 and 115, active low, with 10 ms held
  and 100 ms after (chinese-wall's spacemit-k1 6.13.1). devmgr gives a
  device its MDIO bus's and PHYs' `reset-gpios` as links (`mdio-reset`,
  `phy-reset`), and k1-emac(3) pulses them through k1-gpio(3) before
  its first MDIO access. On a warm boot both PHYs answered after it (id
  `0x4f51e91b`) and EMAC 0's link was up at 1000 Mb/s 3.5 s into boot,
  as before; k1-gpio took every command. The lines' levels weren't
  read back: the cpu image doesn't mount devmgr's tree in a session.
- **GPIO interrupts and the card detect** (2026-11-02): k1-gpio(3)
  serves the block's one interrupt, PLIC 58, for the lines a driver
  watches (`gpio BANK PIN FLAGS watch`), both edges each, and its
  `events` file's read waits for an edge (D114's `changing`). sdhci(3)
  watches its `cd`, GPIO 80, active low, before it probes: with the
  card in, it read `active`, so the pad is a GPIO input as firmware
  left it (no pin state of ours names it). A scratch k1-gpio, never
  committed, watched the status LED's line (GPIO 96, an output) and
  drove it six times: an output's edges are latched too, every one was
  counted (5 or 6, the first `on` sometimes the level it had), and the
  interrupt fired twice per edge, the second finding nothing, with or
  without a read back of the edge status before the ack. Why isn't
  known (k1-gpio(3) BUGS). The card wasn't taken out: it holds the ESP
  and /data.
- **The thermal sensor and the zones' trips** (2026-11-02, D160):
  k1-tsensor(3) enables the K1's sensor (chinese-wall's spacemit-k1 13)
  and every one of its five points read within 11 ms of the enable: 55
  to 60 °C idle, the clusters warmest. Firmware leaves it off (PCTRL
  0, no sensor enabled, TIME_CTRL `0x00400044`). devmgr's `thermal`
  lists the tree's five zones beside ACPI's (none here), each read
  from the driver's `temperatures`, and power(8) keeps them: `5
  thermal zones, read every 1000 ms: highest`, 115 °C critical on
  each, 85 °C passive on the GPU's and the clusters'. At first power
  saw none: it waited up to 30 s for devmgr's `cpus`, empty on a
  devicetree machine, before its first zone; it now starts once
  devmgr says `bound`, and board-test checks it reads every zone
  devmgr lists. A passive trip throttles nothing yet (no CPU clock
  driver). board-test's other 28 failures are its IOMMU checks, which
  the K1, having no IOMMU, can't pass.
- **The CPUs' operating points** (2026-11-02, D161): our tree gives
  each hart its cluster's core clock, BUCK1 as `cpu-supply` and four
  points (chinese-wall's spacemit-k1 14), devmgr's `cpus` names the
  APMU's k1-syscon and p1 for them, and power(8) took all eight at
  boot: `opp 8 of 8 CPUs, 2 clocks, 1 supplies`, `step 8 of 8: every
  CPU 1600 MHz, its supply at 1050000 uV`, the chain 31.3 ms before and
  31.2 after (firmware leaves 1.6 GHz). board-test set both clusters to
  614.4 MHz and back: 81 ms against 31, a ratio of 2.60, which is
  1600/614.4, so the HI source with bit 13 clear is 1.6 GHz and PLL3
  is at 3200 MHz as assumed. No zone came near 85 °C (55-59 °C), so
  power's own step down, and BUCK1 at 0.95 V, haven't run on the board.
  The new tree reaches the board only on the card: a warm boot carries
  the kernel and bootfs, and the loader reads the DTB from the ESP.
- **The node's key, after a power cycle** (2026-11-02): the card's cpu
  image (bootfs-board-cpu.img, `lib/factotum/keys` from
  `build/rv64/cpu/node.keys`, whose `node.pub` says `3daa3c16…`)
  answered a cold boot as `06c7dd41…` (`factotum: 1 key from
  /lib/factotum/keys`, then `cpu: listening ... key 06c7dd41…`), and
  refused `-k 3daa3c16…` with `handshake`; the same image warm-booted
  earlier that day had answered `3daa3c16…`. Not yet explained: the
  volume's kept key taken over the image's, or `vx cpu-keys` and
  factotum deriving different public keys. Board-test's reset leaves
  the board on the card's image, so `-k 06c7dd41…` reaches it there.
- **A bring-up trap, found on the way** (2026-11-02): one warm boot
  panicked with an illegal instruction in `Ipi.otherReadyCpus` while
  the secondaries started. `Smp.count` was a plain variable, so a
  running hart's shootdown saw the new count before the new record's
  slot (RVWMO) and unwrapped a 0. It is now published with release and
  read with acquire (cpu.md, SMP); five warm boots in a row after that
  came back clean. The console's lines on this boot came out with
  gaps: a logger from an earlier session still had the port open (one
  reader at a time, above).

### The shipped chain, as found (2026-10-30)

Read at U-Boot's prompt over UART0 (`version`, `sbi`, `bdinfo`,
`printenv`), with no card, no NVMe and no Ethernet cable.

- **U-Boot 2022.10ky** (built 2025-01-07, GCC 13.2.1), the vendor's, as
  `board=x1`, `product_name=x1_orangepi-rv2`. `bootdelay=0`; Ctrl-C
  reaches the prompt only between boot targets (PXE waits out each
  autonegotiation, about 5 s, without a cable).
- **Boot order** (`boot_targets`): `usb0 mmc0 mmc2 mmc1 nvme0 nvmena pxe
  dhcp`, then the vendor's `autoboot`. Each block device is scanned by
  distro boot: extlinux, boot scripts, then EFI: `bootefi bootmgr`, and
  `efi/boot/bootriscv64.efi` with the DT at `fdtcontroladdr` (or one
  loaded from the card's `/`, `/dtb/` or `/dtb/current/`). The microSD
  slot is `sdh@d4280000`; with no card, the other MMC devices didn't
  answer.
- **OpenSBI 1.3, SBI spec 1.0.** IDs as FreeBSD gives them (mvendorid
  `0x710`, marchid `0x8000000058000001`), mimpid `0x1000000049772200`.
  Extensions: the legacy calls (set_timer, console, IPIs, fences,
  shutdown), Base, IPI, RFENCE, **HSM** and **PMU**. **Not listed: TIME
  and SRST** (nor DBCN, which is SBI 2.0's).
- **What that means for the kernel:** it arms its timer through TIME
  (`Timers.swift`, `0x5449_4D45`), so on this firmware it needs the
  legacy set_timer (EID 0) or Sstc's `stimecmp`, which works here (below,
  "Found by Planar"). Power-off has the legacy fallback (`Power.swift`);
  reboot needs the SoC's watchdog, SRST being absent (and hanging where
  present).
- **DRAM: 8 GiB**, as the hole predicts: `0x0`–`0x7fff_ffff` and
  `0x1_0000_0000`–`0x2_7fff_ffff`. OpenSBI keeps `0x0`–`0x7_ffff`;
  U-Boot relocates to `0x7eea_e000` and keeps the top of the first bank.
- **Display:** U-Boot drives `dpu@c0340000` at 1920×1080×32, frame
  buffer at `0x7f70_0000`.
- **SPI NOR** (`d420c000.spi-0`): bootinfo 64K@0, private 64K@64K,
  FSBL 256K@128K, env 64K@384K, OpenSBI 192K@448K, U-Boot from 640K.
- **MACs** in the environment: `C0:74:2B:FC:D4:E6` and `...:E7`.
- **The DT** U-Boot passes (its own control tree, `fdtcontroladdr`): root
  `"ky,x1", "riscv"`; each hart `riscv,isa = "rv64imafdcv"` with no
  multi-letter extensions and no `riscv,cbom-block-size`; the PLIC
  `"riscv,plic0"`, 64 MiB at `0xe000_0000`, 159 sources, its
  `interrupts-extended` an unwired M context (`0xffffffff`) and an S
  context (9) per hart; UART0 `"ns16550"`, reg-shift 2, io-width 4,
  clock 14 MHz; `stdout-path` `serial0`.

### Found by Planar on this board

Planar (the source table) ran on the RV2 through the same U-Boot, booting
its kernel with `booti` and this DT. What it found, which our bring-up
needs:

- **Sstc works:** S-mode reads and writes `stimecmp` under OpenSBI 1.3,
  so the missing TIME extension costs nothing where the kernel arms its
  timer through Sstc. The timer is `rdtime` at 24 MHz; CLINT's `mtime`
  reads all ones from S-mode.
- **SBI SRST hangs on this board** (OpenSBI 1.3). Planar resets through
  the SoC's watchdog instead.
- **U-Boot starts the SoC's and the PMIC's watchdogs at 60 s**, and
  `bootefi` leaves them running: the board resets about a minute after
  U-Boot hands over unless something stops or feeds them. Planar's
  `boot.scr` stops the PMIC's (`wdt dev PMIC_WDT; wdt stop`) and its
  kernel takes the SoC's over (MPMU, `0xd405_1020` its reset register).
- **Svpbmt works** although the DT's ISA string doesn't list it.
- **DMA isn't cache-coherent:** drivers clean and invalidate through
  Zicbom (64-byte blocks).
- **The PLIC ignores the completion of a disabled source**: complete
  before disabling.
- **U-Boot ignores Ctrl-C while it autoboots** (`bootdelay=0`) and reaches
  its prompt only after every boot target, about 80 s; Planar holds it
  with a file its `boot.scr` checks.
- U-Boot's DT has no GPU node; the GPU (a BXE-2-32) is at `0xcac0_0000`,
  sharing its page with Ethernet at `0xcac8_0000`.

### First card (2026-10-30)

`build/rv64/esp/` on a microSD (MBR, one FAT32 partition, written with
`diskutil eraseDisk FAT32 VECTRAOS MBRFormat`), unchanged from QEMU's.

**The card since** (2026-11-01): GPT, so sd(3) serves a partition fs(4)
can use. Partition 1 is the ESP, an EFI system partition of 1 GiB,
FAT32 labelled `VECTRAOS`; partition 2, `taisce`, is the rest, which
the board's fs formats on its first boot (`--format data`) and serves
as `/data` until an NVMe drive has a `taisce` partition of its own
(`/dev/sdM0/taisce` after `/dev/sdN0/taisce` in the board images).
Made on the Mac, the card in its reader as `diskN`:

    sudo vx disk /dev/rdiskN SIZE ESP:1G:efi 'taisce:*' --device --blank
    sudo newfs_msdos -F 32 -v VECTRAOS /dev/rdiskNs1
    diskutil mount diskNs1      # then EFI/ and croi/ put back

U-Boot boots partition 1 (distro boot falls back to it when no
partition is marked bootable), whatever its type. macOS doesn't mount an
EFI system partition when the card goes in: `diskutil mount` does, and
on the Mac Studio's own reader, an internal disk to macOS, only as root.

The first boot from it (2026-11-01): U-Boot booted partition 1, sdhci
served the card's two partitions, and fs, once devmgr had bound its
devices, made a volume on `taisce` and served it as `/data` (7.48
million 4 KiB blocks); a file written there over `vx cpu` read back
after a warm boot, the volume checked as it mounted (6 nodes, 16 ms).
factotum keeps the image's pinned key, so the node is the same one,
and keeps the node's unlock key on the volume.

- Distro boot reached `mmc 0:1`, found `efi/boot/bootriscv64.efi` and ran
  it with `bootefi` at 6.1 s: the loader's banner came out on UART0
  through EFI's console.
- The loader read the kernel, the bootfs (27 MB) and the cmdline from
  the card through EFI's file protocol, and placed the kernel at
  `0x7ce4_f000`, in the first bank.
- `kaslr: counter only, WEAK`: U-Boot's EFI has no `EFI_RNG_PROTOCOL`.
- It stopped at its first ACPI dependency, as expected: "CPU below the
  rva22u64 baseline: no RHCT". It returned to U-Boot, which went on
  to its next boot target.

### How V6's bring-up ran (the template)

- **One-shot boots:** the Orange Pi 6 Plus booted VectraOS from a boot
  entry kept out of its boot order, set for one boot at a time, so a hang
  fell back to the OS beside it. The RV2's equivalent is the SD card
  beside the SPI NOR chain.
- **Serial captured from before each boot:** a line printed once at boot
  (a node's key, a panic) is lost otherwise.
- **Board facts as rules:** a board's quirks go in a compiled-in board
  rule (D126), not in drivers' guesses.
- **Support rows (D66):** each component's row in
  `docs/hardware/support.tsv` moves from planned to experimental with its
  test and commit, and a native-suite run on the board goes in
  `docs/hardware/runs.tsv` (`vx remote test ARCH --serial DEV --record
  BOARD`, once V3's link runs).
- **A board-test image:** V6 had `bin/board-test` (board-test(8)) in an
  image of its own, checking devmgr, the IOMMUs, the link and DHCP and
  ending with `board-test: passed`, run in QEMU by boot-board as well.
- **Board images are build targets** (`esp-board`, `esp-board-cpu`):
  build each by its own target, or it goes stale.
- **rv64 is this milestone's arch:** its own code's changes run rv64's
  QEMU suite (`vx test --changed rv64`), not only amd64 and arm64.
