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
- **To verify on the board:** that the shipped U-Boot runs a UEFI
  application (`bootefi`) and passes the memory map, and whether its SBI
  implements HSM (to start the other harts), SRST (reset and power off)
  and PMU.

## QEMU stand-in

QEMU has no K1 machine. `-machine virt -cpu rva22s64` gives the profile
without the board, which is what D51's baseline is tested against; the
board's devices are tested on the board.
