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
- **VectraOS is ACPI-only** (architecture §2). How the RV2 meets that is
  open in D51. Until it is decided, nothing here assumes either answer.

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

1. **The firmware path is the owner's decision, still open** (D51). The
   kernel is ACPI-only; the RV2's shipped chain (FSBL, OpenSBI, U-Boot on
   SPI NOR) gives a devicetree. The candidates are firmware that provides
   ACPI (an RV2 port of SpacemiT's K1 EDK2 with K1 tables, "Toward ACPI
   firmware" above) and a loader that reads the DTB and fills the handoff,
   so the kernel never sees DT. A kernel DT path is not a candidate. The
   roadmap starts V6b only once this is decided: ask before building
   either.
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
3. **The Mac as the host.** The host tools build only on Linux today:
   `vx` and `idlc` import Glibc in every file (`tools/vx/*.swift`,
   `tools/idlc/main.swift`, and `fs/taisce/host/FileDevice.swift`), and
   `tools/qemu.sh` takes edk2 from a Linux path. The pc-9700x notebook's
   "Ground rules" weigh the choices: port them to Darwin (their calls are
   POSIX), or build in a Linux VM on the Mac, or build on the Linux dev
   machine (`brimstone`) and only write cards on the Mac. The tier 1
   toolchain (`tools/toolchain`, hours to build) is needed only for tier
   1's programs, not for the first boots.

### On the board, in V6b's order

- **First, the shipped chain** ("To verify on the board" above): that
  U-Boot's `bootefi` runs a UEFI application and passes the memory map,
  and whether its SBI implements HSM, SRST and PMU. Our loader is a
  PE32+ UEFI application, so this is the first thing to run whichever
  firmware is chosen: its banner on the console proves the path, before
  the kernel needs ACPI.
- **The card's layout** is the ESP the build makes, a FAT partition:
  `\EFI\BOOT\BOOTRISCV64.EFI` (the loader) and `\croi\` (`kernel.elf`,
  `bootfs.img`, `cmdline`), as `build/rv64/esp/` holds it. Leave the SPI
  NOR's shipped chain as it is unless the firmware decision says
  otherwise: booting from the card keeps the board recoverable.
- **The console** is UART0 (table above: `0xd401_7000`, 16550-style,
  `reg-shift = 2`, 32-bit access) through a 3.3 V USB-serial adapter on
  the RV2's debug header; its pinout is to be checked on the board and
  written here.
- **Then** V6b's steps in the roadmap: the platform (8 harts by SBI HSM,
  the PLIC, the SBI timer, DMA windows with no IOMMU), the K1 EMAC, V3's
  link, then storage, PCIe and USB.

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
