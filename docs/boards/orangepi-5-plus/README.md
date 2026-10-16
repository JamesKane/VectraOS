# Orange Pi 5 Plus (Rockchip RK3588)

A research pass (2026-10-16), not a board decision. The board is on hand
(owner). The roadmap's research tracks name the RK3588 as "DT-only, so it
needs an ADR"; this pass checks that, and what the BSDs support.

Facts come from the sources below and are marked with them. Facts marked
**(memory)** are not yet checked against a document or the machine; **On
the machine** lists what to read first. Code is not lifted from these
sources (D4); they are read as hardware documentation (provenance.md).

| Source | Commit or date | Paths |
|---|---|---|
| Linux (`../linux`) | `24a19b953e2a` (2026-10-11) | `arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dts`, `rk3588-orangepi-5.dtsi`, `rk3588-base.dtsi`, `rk3588-extra.dtsi`; `drivers/irqchip/irq-gic-v3-its.c`; `Documentation/arch/arm64/silicon-errata.rst` |
| FreeBSD (`../freebsd-src`) | `fe90f180047b` (2026-10-13) | `sys/conf/files.arm64`, `sys/arm64/rockchip/`, `sys/dev/clk/rockchip/` |
| NetBSD (`../netbsd-src`) | `cd173776c` (2026-05-18) | `sys/arch/arm/rockchip/`, `sys/arch/evbarm/conf/GENERIC64`, `sys/dev/acpi/sdhc_acpi.c`, `dwcmmc_acpi.c` |
| OpenBSD (`../openbsd-src`) | `cd1cface2` (2026-06-08) | `sys/dev/fdt/`, `sys/arch/arm64/stand/efiboot/efiboot.c` |
| croi's code (this tree) | — | `kernel/Kernel/Irq/Its.swift`, `kernel/Kernel/Uart.swift`, `boot/Loader/Acpi.swift` |

## The short version

- **Not the RV2's case.** Rockchip and Xunlong ship U-Boot with a
  devicetree, but a community EDK2 port for the RK3588 boots the board
  with UEFI and ACPI. NetBSD's ACPI drivers match its tables: `RKCP0D40`,
  the eMMC controller, with a Rockchip `_DSM` that sets the card clock
  (`sdhc_acpi.c`). So D51's preferred candidate for the RV2, firmware
  that provides ACPI, already exists here. It is third-party firmware,
  flashed to the board's SPI flash: firmware counts as hardware, with its
  provenance in `firmware/README.md`, as for the Q8B. Which boards and
  devices its ACPI mode covers is **(memory)**, to read from its source.
- **FreeBSD has no RK3588 support in main.** It has the RK3588
  devicetree bindings and builds the boards' `.dtb` files (commit
  `67fc0ff33d`), but no clock, pin or PCIe driver; its Rockchip drivers
  stop at the RK3568, all through FDT (`files.arm64`). OpenBSD is the
  furthest along, also through FDT. NetBSD has the RK3588's clock and pin
  drivers through FDT and the eMMC through ACPI.
- **croi would hit one kernel bug first:** its ITS programs its tables
  inner shareable, and the RK3588's GIC can't snoop them (Bring-up
  hazards).
- **Its NICs are on PCIe:** two Realtek 2.5 GbE, of the same family as the
  Orange Pi 6 Plus's RTL8126 (memory), so one Realtek net-class driver
  could serve both boards.

## CPU

- **8 cores:** 4 Cortex-A55 (`cpu@0`…) and 4 Cortex-A76 (`cpu@400`…)
  (`rk3588-base.dtsi`).
- **Against D53's baseline** (`armv8.2-a+fp16+dotprod+rcpc`): both cores
  are Armv8.2 with FP16, the dot product and RCpc (memory), so it meets
  it. Crypto is a licensee option (memory); on the machine.

## Firmware and boot

- **Shipped:** U-Boot with a devicetree (memory). Mainline Linux has the
  board's DT (`compatible "xunlong,orangepi-5-plus", "rockchip,rk3588"`).
- **ACPI:** the community EDK2 port (memory: `edk2-porting/edk2-rk3588`),
  flashed to the SPI NOR (`&sfc`, `spi_flash`). NetBSD's ACPI attachments
  for its eMMC (`RKCP0D40`) and SD (`rockchip,rk3288-dw-mshc` through
  `_DSD`) show its tables in use.
- **Console:** UART2 at `0xfeb50000`, 1,500,000 baud 8N1 (DT
  `stdout-path`; NetBSD's `CONSADDR`). A DesignWare 16550 with 32-bit
  registers 4 bytes apart (memory). croi's loader builds a 16550 console
  with 32-bit access from SPCR's address structure (`Acpi.swift`,
  `Uart.swift`), so an SPCR from EDK2 should be enough (on the machine).
- **Not the RV2's problem:** the RV2 has no ACPI firmware known, so D51
  leaves its path open. Here, an ACPI path exists to try.

## Interrupts

- **GIC-600:** GICv3 at `0xfe600000`, two ITSes at `0xfe640000` and
  `0xfe660000`, all marked `dma-noncoherent` (`rk3588-base.dtsi`).
- **Rockchip erratum RK3588001:** for an ITS with IIDR `0x0201743b` on an
  RK3588, Linux forces the ITS's tables and the redistributors'
  `PROPBASER`/`PENDBASER` non-shareable (`its_enable_rk3588001`). With
  them non-shareable, the CPU must clean its caches to the GIC (or map
  the tables non-cacheable).
- **Not RK3588:** the "GIC600 integration limited to 32-bit PA" quirk is
  the RK3568's (erratum 3568002, `dma_32bit_impaired_platforms`).

## IOMMUs, PCIe and DMA

- **One SMMUv3 for PCIe:** `mmu600_pcie` at `0xfc900000`, enabled, with
  each controller's requester ids mapped through it (`iommu-map`,
  `0x0000`–`0x4fff`). A second, `mmu600_php` at `0xfcb00000`, is disabled
  in the DT.
- **Rockchip's own IOMMUs** (`rockchip,iommu`) sit in front of the display
  (VOP), the video codecs, the RGA and the NPU (`rknn_mmu_*`). croi has
  no driver for this kind; those devices need one when they come.
- **PCIe:** DesignWare controllers, not plain ECAM: `pcie3x4` at
  `0xfe150000` (the M.2 M-key, NVMe), and three PCIe 2.0 x1 links: `l0`
  for the M.2 E-key Wi-Fi slot, `l1` the right Ethernet port, `l2` the
  left (`rk3588-orangepi-5-plus.dts`). How EDK2's ACPI presents them
  (ECAM with quirks, memory) is to read from its source.
- **Ethernet:** two Realtek RTL8125B 2.5 GbE on those links (memory for
  the part; the DT names only the ports).
- **DMA below 4 GiB:** OpenBSD's loader passes a 32-bit DMA constraint for
  the RK3566, RK3568, RK3576 and RK3588 (`efiboot.c`). Which RK3588 masters
  need it is on the machine; croi has address-limited contiguous VMOs
  (K4).

## The rest of the board

- **Storage:** eMMC (`sdhci`), microSD (`sdmmc`), NVMe on M.2, SPI NOR.
- **USB:** two DWC3 xHCI hosts with EHCI and OHCI; USB-C through an FUSB302
  (`usb-typec@22`).
- **Display:** two HDMI outputs and an HDMI input (`hdmi0`, `hdmi1`,
  `hdmi_receiver`); VOP2.
- **GPU:** Mali-G610 (Valhall) (memory), against D62's board list, which
  names the Mali-G720 today.
- **NPU:** RKNN, about 6 TOPS (memory), behind Rockchip IOMMUs, with a
  binary user stack (memory): D4 again, as for the Sky1's.
- **Thermal:** a PWM fan in the DT's cooling maps (`pwm-fan`); who drives
  it under EDK2's ACPI is on the machine. An HYM8563 RTC on I²C 6.

## The BSDs

| | FreeBSD (main) | NetBSD | OpenBSD |
|---|---|---|---|
| Boot | — (RK3568 by FDT; RK3588 `.dtb` files only) | FDT (`SOC_RK3588`) | FDT, EFI loader |
| Clocks, pins | — | `rk3588_cru`, `rk3588_iomux` | `rkclock`, `rkpinctrl` |
| Ethernet | — | `rk_eqos` (the SoC's GMAC; unused on this board) | `dwqe` (GMAC) |
| PCIe | — | (not found) | `dwpcie`, `rkpciephy`, `rkcomphy` |
| USB | — | (generic) | `rkusbphy`, `rkusbdpphy` |
| Storage | — | `sdhc_acpi` (`RKCP0D40`), `dwcmmc_acpi` | `dwmshc` |
| Other | — | — | `rktemp`, `rkotp`, `rkrng` |

What runs on the EDK2 ACPI firmware without SoC drivers (generic GIC,
timer, PCIe, xHCI, NVMe) is **(memory)** for each system.

## Bring-up hazards for croi

1. **The ITS tables (a kernel fix, not a board rule).** `Its.swift`
   writes the device, collection and command tables, and each
   redistributor's `PROPBASER`/`PENDBASER`, as inner shareable,
   write-back, and never reads them back. On the RK3588 the GIC doesn't
   snoop, so MSIs would fail or arrive late. The general fix is Linux's:
   read the shareability back after each write, and when the GIC has
   downgraded it (or a quirk says so, keyed on IIDR `0x0201743b` and the
   SoC), clean the tables and every command to memory, or map them
   non-cacheable. Other GIC-600 integrations may need the same, so it
   belongs in croi's GIC code with the erratum checks the roadmap lists
   ("GIC erratum checks keyed on IIDR").
2. **The firmware is the community's.** Which EDK2 release, what its ACPI
   mode describes (SPCR, IORT, MCFG, the PCIe quirks) and what it leaves
   to DT mode decides the board's level. Read before flashing.
3. **DMA limits:** a 32-bit constraint for some masters (OpenBSD), to
   check per device.

## On the machine

- The firmware on the SPI NOR now; then EDK2's ACPI tables (`acpidump`):
  SPCR, IORT, MCFG, the PCIe description, the GIC's and ITS's entries.
- GICD_IIDR and GITS_IIDR (expect `0x0201743b`), and what
  `GITS_BASER`/`GICR_PROPBASER` read back after a shareable write.
- `/proc/cpuinfo` (crypto) and the Ethernet chips' revision.
- The fan: who controls it in ACPI mode.
