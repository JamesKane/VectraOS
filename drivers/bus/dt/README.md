# The devicetree as a bus

`DeviceTreeBus` (`lib/`, D154): the devices a flattened devicetree
describes, which devmgr binds beside ACPI's and PCI's on a machine whose
firmware gave only a tree (the loader made the ACPI tables from it, and
the boot data carries it; `lib/fdt` reads it in place).

- **Devices:** an enabled node with a `compatible`, on the root or on a
  `simple-bus`. Any other node's children are its driver's to read (an
  I2C controller's, an Ethernet MAC's MDIO bus), as Linux's platform bus
  leaves them, and what the kernel owns (the PLIC, APLIC, IMSICs, CLINT,
  GIC and its ITS, the arch timer) is not a device.
- **Ranges:** each `reg` range, translated to the CPU's address through
  each bus's `ranges` up to the root; one no bus translates is noted.
- **Interrupts:** `interrupts` on the node's `interrupt-parent` (its own
  or a bus's above it), or `interrupts-extended`, followed through each
  nexus's `interrupt-map` (and `interrupt-map-mask`) to a controller. On
  the kernel's controller an interrupt is its GSI: a PLIC's or APLIC's
  source, a GIC's SPI from 32 or PPI from 16, its trigger from the
  flags cell (level-high without one). On another controller (a GPIO
  block's) it is a provider's, and noted.
- **DMA:** coherent unless the nearest `dma-coherent` or
  `dma-noncoherent`, on the node or a bus above it, says otherwise; the
  default is the arch's (coherent on RISC-V, not on arm64).
- **IOMMUs:** each `iommus` entry's unit, by path, and its id cells.
- **Names:** a node's name (`ethernet@cac80000`), or, where two devices'
  nodes share one, its path's components joined by dots.

It allocates only its results, and is tier 0, so devmgr runs it.

**Tests.** `DeviceTreeTests` (hosted, `swift test`): the Orange Pi RV2's
own tree, compiled from `firmware/dts` as CMake builds it (its EMACs,
SDHCIs, UART and PCIe hosts, what isn't a device, the K1's
non-coherent DMA), and small trees for ranges through nested buses, a
GIC's cells, `interrupt-map`, `interrupts-extended` onto a provider,
`iommus`, names and status. Natively, `bin/dt-test`
(`tests/native`, rv64's boot-devicetree-bus): QEMU's firmware with only
a tree, and devmgr lists each of its devices.

Not yet: the links a tree's phandles make (`clocks`, `resets`,
`pinctrl-N`, supplies, PHYs), which come with the providers that serve
them; `iommus` units named to the kernel; PCI hosts' `interrupt-map`
for INTx, and an MCFG for a plain ECAM host.
