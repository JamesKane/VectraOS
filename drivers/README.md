# Drivers

todhchai's drivers, ported to V1 (D74, V2 item 7): organized by
function class, then by driver. A driver is one program, run by devmgr
in a driver host of its own and given exactly its device's resources.

```
drivers/
  bus/acpi/      TDACPI: firmware tables and the AML interpreter (7a)
  bus/pci/       PCI: configuration space, ECAM, enumeration (7b)
  host/          DriverHost: DeviceResources, Registers, InterruptPort, PinnedMemory
  devmgr/        bin/devmgr (Main.swift), its library (lib/: firmware, IOMMUs,
                 routing, grants, the match index) and its manifest
  virtio/        Virtio: the modern transport, split queues, devices' configurations (7d)
  block/virtio-blk/lib/  VirtioBlk: virtio-blk's request format (its class comes in V3)
  input/         the input class: lib/ (InputDevice: Device, its events on the one ring), idl/
    virtio-input/  keyboards, mice and tablets (7d)
  test/edu/      QEMU's edu device: the first driver, devmgr's test
```

## Match records

A driver's directory holds its `driver.manifest`, the records devmgr
binds it by. CMake collects every one into bootfs's `etc/drivers`, and
DevMgrTests checks that no two drivers share a rule.

```
driver edu                 # the program, bootfs's bin/NAME
class test
match pci 1234:11e8        # vendor:device
match pci-class 04.03      # class.subclass, or class.subclass.progif
match acpi PNP0B00         # a hardware id
match acpi-compatible PNP0C50
fallback                   # a generic driver: any other's match wins
dma-bits 28                # the device's DMA address width
```

devmgr matches in NeoVectra's order: exact ids, then compatible ids in
the device's order, then classes (with a programming interface first),
then fallback drivers. Two drivers tied at the deciding level bind
neither, and devmgr's `status` says so.

## devmgr

`bin/devmgr` reads the firmware's tables from the boot data, loads
ACPI's namespace with its regions over the machine, enumerates PCI over
the MCFG's ECAM (each bus mapped as it is walked), routes INTx through
`_PRT`, and lists ACPI's present devices with their `_CRS`: the platform
devices, bound like PCI ones (D74). It names each IOMMU the DMAR, IVRS,
IORT or RIMT describes to the kernel (iommu_create), and gives each
bound device a BTI on the unit that covers it, narrowed to its
`dma-bits`; only where no unit covers it, the stub's, which the kernel
logs and devmgr's status shows (`dma passthrough`). Its manifest grants
it MMIO, IRQ, system and (amd64) I/O port resources, the boot data, and
`programs`; it runs each driver host as a service of its own Launcher,
so hosts restart by policy, and mounts each host's tree at
`drivers/SERVICE`.

Its tree: `status` (a line a device: name, ids, class, host, state and
where its DMA goes, then `bound N` once it is done), `iommus`,
`enumeration` and `acpi` (the tables, and how long loading, `_INI`,
`_STA` and `_PRT` took).

## The input class

An input driver serves `device` (`InputDeviceIPC.Device`, `drivers/input/lib`):
`info`, and `open`, whose argument is a ring the reader made
(`InputReader(slots:)` makes one and `events()` hands it over). Its events
go there, a slot each (when, evdev type, code, value), each batch ending
at SYN_REPORT; the driver never waits for its reader and drops what
doesn't fit, counting it (`InputWriter`). virtio-input reads its device's
event queue on MSI-X where the kernel has MSIs, else INTx.

## virtio

`PCIDevice` opens a virtio device from its grants: the vendor
capabilities, the BARs they name mapped, the common and device
configurations as `Device`. `negotiate` takes VERSION_1 and ACCESS_PLATFORM:
a driver's addresses are its BTI's, which the IOMMU translates, so a
device that bypasses it (QEMU's virtio without `iommu_platform=on`) would
DMA to the wrong memory, and a driver refuses one. `SplitQueue` fences
(`croi_dma_barrier`) between a slot and the index that publishes it, and
`PCIDevice.notify` before telling the device.

## Driver hosts

A host is given its device's resources as `CROI_PA_DEVICE` startup
handles, the argument saying which: 0-5 a BAR (or a platform device's
`_CRS` ranges, in order), 0x10 its configuration space, 0x20 its BTI,
0x30 an MSI allocation, 0x100 plus the trigger mode its interrupt.
`DeviceResources(take:)` takes them; `map(bar:)` and `mapConfig()` give
`Registers`, whose loads and stores are the runtime's `croi_mmio_*`
(`user/include/croi/mmio.h`); `InterruptPort(device.interrupt())`
waits for its interrupt on a bound port and acks it (V1 has no
interrupt_wait); `PinnedMemory(bti:)` gives zeroed memory and the
device address it is pinned at.

**Adding a driver:** a directory under its class with `Main.swift` and
`driver.manifest`, its program in `kernel/CMakeLists.txt` and bootfs, and
a library target in both builds if it has a `lib/`.

## Tests

`swift test`: ACPITests, PCITests, DevMgrTests, VirtioTests and InputTests (the match index, the
manifest directives, q35's regions and routes, the IOMMU descriptors and
a platform device's `_CRS`). Natively: `bin/acpi-test` (boot-acpi),
`bin/pci-test` (boot-pci), and devmgr itself in boot-launch, where
launch-test checks devmgr's status, edu's findings and a key typed
through QEMU's monitor (qemu.sh's `qemu: sendkey`) on every arch.
