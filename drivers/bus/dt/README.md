# The devicetree as a bus

`DeviceTreeBus` (`lib/`, D154): the devices a flattened devicetree
describes, which devmgr binds beside ACPI's and PCI's on a machine whose
firmware gave only a tree (the loader made the ACPI tables from it, and
the boot data carries it; `lib/fdt` reads it in place).

- **Devices:** an enabled node with a `compatible`, on the root or on a
  `simple-bus`, or with a `compatible` and a `reg` under an I2C
  controller (`i2c@...`, D158): no range, and an `i2c` link to the
  controller, its address the cell. Any other node's children are its
  driver's to read (an Ethernet MAC's MDIO bus), as Linux's platform
  bus leaves them, and what the kernel owns (the PLIC, APLIC, IMSICs, CLINT,
  GIC and its ITS, the arch timer) is not a device.
- **Ranges:** each `reg` range, translated to the CPU's address through
  each bus's `ranges` up to the root; one no bus translates is noted.
- **Interrupts:** `interrupts` on the node's `interrupt-parent` (its own
  or a bus's above it), or `interrupts-extended`, followed through each
  nexus's `interrupt-map` (and `interrupt-map-mask`) to a controller. On
  the kernel's controller an interrupt is its GSI: a PLIC's or APLIC's
  source, a GIC's SPI from 32 or PPI from 16, its trigger from the
  flags cell (level-high without one). On another controller (a GPIO
  block's) it is a link to that controller's device.
- **DMA:** coherent unless the nearest `dma-coherent` or
  `dma-noncoherent`, on the node or a bus above it, says otherwise; the
  default is the arch's (coherent on RISC-V, not on arm64). Its reach
  is the least, over the buses above it, of each `dma-ranges` range
  that maps address 0 to the CPU's 0, rounded down to a power of two
  (`dmaBits`, which devmgr narrows the device's BTI to).
- **IOMMUs:** each `iommus` entry's unit, by path, and its id cells.
- **Links:** what the node's phandles name (`DeviceLink`, devmgr's one
  link record, which CIX's `CLKT` and `RSTL` also fill): `clocks`,
  `resets`, `power-domains` and `phys` with their cells and their
  `-names`; `pinctrl-N` states by `pinctrl-names`; `NAME-supply`;
  `NAME-gpios` with their cells; and a vendor's reference into a system
  controller's registers, `spacemit,apmu` (a `syscon` link, its offset
  the cell), or to the unit alone, `spacemit,apbc` (one with no cells). A PCI host's root ports' links are the host's (their PHYs
  and slot supplies), an MDIO bus's `reset-gpios` and its PHYs' are the
  device's that holds it (`mdio-reset`, `phy-reset`: an Ethernet MAC's), and a binding may imply a link no phandle names:
  the K1's PCIe PHYs' to the combo PHY, whose calibration they take.
  A link's provider is the device whose
  node is the one named or holds it (a pin controller its states); a
  fixed clock outside any bus is no device's. devmgr starts a provider's
  driver first and mounts its tree in each consumer's at
  `/dev/provider/SERVICE` (`drivers/devmgr/lib/Links.swift`).
- **Properties:** the node's and those of the nodes under it, as text a
  line each (`NAME VALUE`, values as dtc writes them), which devmgr
  serves to its driver at `/dev/dt/node`: an EMAC's `phy-mode`, delays
  and its PHY's `mdio-bus/phy@1/reg`.
- **Thermal zones** (D160, `Zones.swift`): each enabled child of
  `/thermal-zones`, the node and cell its `thermal-sensors` names, its
  first `passive` and first `critical` trip, and its `polling-delay`;
  devmgr lists them in its `thermal`, each read from its sensor's
  driver.
- **Names:** a node's name (`ethernet@cac80000`), or, where two devices'
  nodes share one, its path's components joined by dots.

It allocates only its results, and is tier 0, so devmgr runs it.

**Tests.** `DeviceTreeTests` (hosted, `swift test`): the Orange Pi RV2's
own tree, compiled from `firmware/dts` as CMake builds it (its EMACs,
SDHCIs, UART and PCIe hosts, its thermal zones, what isn't a device, the K1's
non-coherent DMA, its devices' links onto the APBC and APMU), and small trees for ranges through nested buses, a
GIC's cells, `interrupt-map`, `interrupts-extended` onto a provider, each kind of link,
`iommus`, names and status. Natively, `bin/dt-test`
(`tests/native`, rv64's boot-devicetree-bus): QEMU's firmware with only
a tree, and devmgr lists each of its devices; on the RV2, also its
APBC and APMU running k1-syscon, and a clock turned on through one.

Not yet: providers for PHYs and power domains (the K1's APBC and APMU,
pins and GPIOs, and fixed regulators, are providers);
`iommus` units named to the kernel; PCI hosts' `interrupt-map`
for INTx, and an MCFG for a plain ECAM host.
