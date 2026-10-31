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
  return NOT_SUPPORTED on the PLIC (`drivers.md`), so PCIe MSIs need a
  DWC MSI backend: an open item for the board.

## Devices on the RV2

| Device | DT node / compatible | Address | Notes |
|---|---|---|---|
| Console UART | `uart0`, `"spacemit,k1-uart", "intel,xscale-uart"` | `0xd401_7000` | 16550-style, `reg-shift = 2`, 32-bit access, PLIC 42. `serial0`, `stdout-path` |
| Ethernet ×2 | `eth0`, `eth1`, `"spacemit,k1-emac"` | `0xcac8_0000`, `0xcac8_1000` | SpacemiT's own MAC (Linux `k1_emac.c`), not stmmac. RGMII, Motorcomm PHYs at MDIO 1 |
| eMMC | `emmc`, `"spacemit,k1-sdhci"` | `0xd428_1000` | 8-bit, HS400 |
| microSD | `sdhci0`, `"spacemit,k1-sdhci"` | `0xd428_0000` | UHS to SDR104, card detect on GPIO 80 |
| PCIe | `pcie1`, `pcie2`, `"spacemit,k1-pcie"` (DesignWare) | `0xca40_0000`, `0xca80_0000` | Each with its own PHY; slot power on GPIO 116 |
| USB 3 | `usb_dwc3`, `"spacemit,k1-dwc3"` | `0xc0a0_0000` | Host only, behind a Genesys Logic hub (`usb5e3,610`/`620`) |
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
- **Still unknown:** whether the K1's DesignWare PCIe works through MCFG's
  ECAM without quirks, and whether SpacemiT's DT bindings for the clocks,
  resets and pins need `_DSD` in the DSDT or can stay with the drivers.
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
  through the SoC's watchdog, and the 60 s watchdogs, are still to do.

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
