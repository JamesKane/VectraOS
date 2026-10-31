# StarFive VisionFive 2 (JH7110)

The small rv64 board: four SiFive U74 harts below RVA22, run to show
VectraOS on a small, old board through fallbacks (the owner,
2026-10-31). D155 drops rv64's floor for it; D154 says how its
devicetree is read. Its milestone is V6e.

Facts come from the sources below. Facts marked **(memory)** are not yet
checked against a document or the machine. Code is not lifted from these
sources (D4); they are read as hardware documentation.

| Source | Commit | Paths |
|---|---|---|
| Linux (`../linux`) | `65ba8f34ec88` (2026-10-27) | `arch/riscv/boot/dts/starfive/jh7110.dtsi`, `jh7110-common.dtsi`, `jh7110-starfive-visionfive-2.dtsi`, `jh7110-starfive-visionfive-2-v1.3b.dts` |
| FreeBSD (`../freebsd-src`) | `c9dbbe382d` (2026-10-28) | `sys/conf/files.riscv`: no JH7110 entries |

## CPU

- **Four U74 harts** (`cpu@1`…`cpu@4`, `"sifive,u74-mc"`):
  `riscv,isa-extensions` lists i, m, a, f, d, c, Zba, Zbb, Zicntr,
  Zicsr, Zifencei and Zihpm; `mmu-type = "riscv,sv39"`; 64-byte cache
  blocks.
- **One S7 monitor hart** (`cpu@0`, `"sifive,s7"`, `rv64imac_zba_zbb`):
  `status = "disabled"` and no `mmu-type`, so the loader's tables leave
  it out (D154 §1).
- **Against the floor:** it meets D155's `rv64gc_zba_zbb`. It has none
  of RVA22's Zbs, Zicbom, Zicbop, Zicboz, Zihintpause, Zfhmin, Svpbmt
  or Svinval, no Sstc and no V: the kernel takes each fallback D155
  lists, and user libraries run the floor's routines.
- **Misaligned loads:** whether the U74 does them in hardware or traps to
  OpenSBI is on the machine (D128's open question).

## Interrupts and timers

- **PLIC** at `0xc000000`, `"starfive,jh7110-plic", "sifive,plic-1.0.0"`,
  136 sources. The kernel's PLIC path; the loader's MADT gives each U74
  its S-mode context from `interrupts-extended`.
- **CLINT** at `0x2000000` (`"sifive,clint0"`): M mode's. The kernel's
  timer is SBI TIME, since the U74 has no Sstc (ae66e82).

## Caches and DMA

- **L2 cache controller** at `0x2010000`,
  `"starfive,jh7110-ccache", "sifive,ccache0"`, 64-byte blocks. Without
  Zicbom, cache maintenance for a device that doesn't snoop goes through
  its flush register (D155; a board rule under D126).
- **Coherence:** StarFive's JH7100 memo says the JH7110's high-speed
  peripherals sit on the CPU's coherent port (a vendor claim, unverified).
  The JH7110's `.dtsi` files mark no node `dma-noncoherent`, so by the
  binding every master is coherent; the machine confirms it.

## Devices

| Device | Node / compatible | Address | Notes |
|---|---|---|---|
| Console UART | `uart0`, `"starfive,jh7110-uart", "snps,dw-apb-uart"` | `0x1000_0000` | 16550, `reg-shift = 2`, 32-bit access, PLIC 32; `stdout-path = "serial0:115200n8"` |
| Ethernet ×2 | `gmac0`, `gmac1`, `"starfive,jh7110-dwmac", "snps,dwmac-5.20"` | — | Synopsys DesignWare MAC (stmmac's) |
| eMMC, microSD | `mmc0`, `mmc1`, `"starfive,jh7110-mmc"` | — | DesignWare MMC |
| PCIe ×2 | `pcie0`, `pcie1`, `"starfive,jh7110-pcie"` | config `0x9_4000_0000`, `0x9_c000_0000` | PLDA host, its own MSI controller and INTx (`pcie_intc0`); a PHY each. The USB 3 hub (VL805, memory) and the M.2 NVMe sit behind them (memory: which link) |
| USB | `usb0`, `"cdns,usb3"` | — | `dr_mode = "peripheral"` on this board: the device port, not a host |

Clocks and resets come from the `syscrg`, `aoncrg` and `stgcrg` units,
pins from `sys-pinctrl`: providers under D154 §4.

## Firmware and boot

- **Shipped (memory):** SPL, OpenSBI and U-Boot on the QSPI NOR, with
  `bootefi`, passing a tree, as on the RV2. Whether its tree is
  upstream's or StarFive's is on the machine; ours replaces it either
  way (D154 §7, `dtb/starfive/jh7110-starfive-visionfive-2-v1.3b.dtb`).
- **Board revision:** the v1.2A and v1.3B differ (two `.dts` files); the
  loader's pick by root `compatible` tells them apart.

## On the machine

- U-Boot's version, `bootefi`, and the tree it passes.
- OpenSBI's version and its extensions (HSM, SRST, PMU, TIME).
- Misaligned loads: trapped or not, and at what cost.
- Which PCIe link carries the VL805 and which the M.2, and what U-Boot
  leaves trained.
- Which DMA masters snoop.
