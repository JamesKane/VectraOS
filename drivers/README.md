# Drivers

todhchai's drivers, ported to V1 (D74, V2 item 7): organized by
function class, then by driver. A driver is one program, run by devmgr
in a driver host of its own and given exactly its device's resources.

```
drivers/
  bus/acpi/      TDACPI: firmware tables and the AML interpreter (7a)
  bus/pci/       PCI: configuration space, ECAM, enumeration (7b)
  bus/dt/        DeviceTreeBus: a devicetree's devices, their ranges and interrupts (D154)
  host/          DriverHost: DeviceResources, Registers, InterruptPort, PinnedMemory
  devmgr/        bin/devmgr (Main.swift), its library (lib/: firmware, IOMMUs,
                 routing, grants, the match index) and its manifest
  virtio/        Virtio: the modern transport, split queues, devices' configurations (7d)
  block/virtio-blk/lib/  VirtioBlk: virtio-blk's request format (its class comes in V4, D76)
  block/nvme/    NVMe controllers' first namespaces, as sd(3) disks
  block/sdhci/   SD host controllers (PCI's, the SpacemiT K1's) and their cards, as sd(3) disks
  net/rge/       the Realtek RTL8126, as ether(3)
  net/k1-emac/   the SpacemiT K1's Ethernet MAC and its PHY, as ether(3)
  input/         the input class: lib/ (InputDevice: evdev's codes as HID usages, D83)
    virtio-input/  keyboards, mice and tablets (7d)
  usb/           lib/ (USB: descriptors, xHCI's endpoint rules, a DWC3's setup),
                 bus/ (the bus below a host controller: hubs, and HID's boot
                 keyboards and mice), and its hosts: xhci/ (xHCI) and ehci/ (EHCI)
  display/       the display class: lib/ (DisplayDevice, D120)
    virtio-gpu/    virtio's 2D commands, and its 3D as the GPU class
    linlon/        a Linlon-D6 engine (the Sky1's): firmware's output, scanned out
    dptx/          its DisplayPort transmitter: the sink's DPCD, EDID and HPD
  gpu/           the GPU class: lib/ (GPUDevice, D121), client/ (GPUClient),
                 mali/ (an Arm Mali CSF GPU: the CIX Sky1's powered up and probed)
  power/scmi/    the power class: the SCMI agent, firmware's power domains and clocks
  clock/k1-syscon/  the SpacemiT K1's APBC and APMU: clock gates and resets, a devicetree provider,
                    and its EMACs' interface and delay lines
  bus/k1-pcie/   the SpacemiT K1's PCIe hosts: DesignWare root complexes, their buses given to devmgr
  pinctrl/k1-pinctrl/  the SpacemiT K1's pin controller: pin states, a devicetree provider
  gpio/k1-gpio/   the SpacemiT K1's GPIO controller: its pins driven, a devicetree provider
  phy/k1-pcie-phy/  the SpacemiT K1's PCIe PHYs: the combo PHY's calibration (and its USB 3 mode), the lanes and PLL of ports B and C
  phy/k1-usb2-phy/  the SpacemiT K1's USB 2 PHYs, the DWC3's and the EHCIs'
  i2c/           lib/ (vectraos.i2c: a bus's transfers, D158), k1-i2c/ (the SpacemiT K1's controllers)
  power/p1/      the SpacemiT P1 PMIC, on an I2C bus: regulators, its RTC, power off
  power/regulator-fixed/  a fixed regulator switched by a GPIO, a devicetree provider of a supply
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
match dt spacemit,k1-emac  # a devicetree node's compatible
fallback                   # a generic driver: any other's match wins
dma-bits 28                # the device's DMA address width
sd F                       # a disk's sd(3) letter
poweroff                   # its ctl's `poweroff` turns the machine off
```

devmgr matches in NeoVectra's order: exact ids, then compatible ids in
the device's order (ACPI's, or a devicetree node's `compatible`), then classes (with a programming interface first),
then fallback drivers. Two drivers tied at the deciding level bind
neither, and devmgr's `status` says so.

## devmgr

`bin/devmgr` reads the firmware's tables from the boot data, loads
ACPI's namespace with its regions over the machine, enumerates PCI over
the MCFG's ECAM (each bus mapped as it is walked), routes INTx through
`_PRT`, and lists ACPI's present devices with their `_CRS`: the platform
devices, bound like PCI ones (D74). On a machine whose firmware gave
only a devicetree, it reads the tree the boot data carries as a bus
(`bus/dt`, D154): each device is given its `reg` ranges, its first
interrupt and the stub's BTI, with `--noncoherent` where the tree says
its DMA isn't coherent; with no MCFG there, there is no PCI. It names each IOMMU the DMAR, IVRS,
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
`enumeration`, `acpi` (the tables, and how long loading, `_INI`,
`_STA` and `_PRT` took) and `devicetree` (each of the tree's devices:
its ranges, interrupts and DMA, and what couldn't be resolved).

## Platform devices' links and power

A platform device can need what other devices hold: an SCMI agent its
shared memory and mailboxes, a GPU its reset controller and the
firmware that powers it. devmgr (`lib/Platform.swift`) grants a device
the ranges of the devices its `_DSD` names as `shmem` and `mboxes` and
of the reset controllers CIX's `RSTL` names, after its own, and says
which BAR each is (`--bar=INDEX:ROLE`); a board rule adds firmware the
tables leave out (the Sky1's TF-A agent, an SMC function). Its host's
`/dev/acpi` is its `platform/SERVICE` directory: `clocks` and `resets`
from CIX's tables, and `power`, where writing `on` runs its power
resources' `_ON` (AML is devmgr's alone). The power class, `scmi`,
starts first, and its tree is the `/dev/scmi` of each device with
clocks or SCMI power domains. `mali` powers the Sky1's GPU up through
both, in the order the board needs, before its first register read.
On a devicetree machine the record is the tree's links, what a node's
phandles name (`DeviceLink`, which CIX's `CLKT` and `RSTL` also fill):
a provider's driver, such as `k1-syscon` for the K1's APBC and APMU,
starts before the drivers of the devices that link to it, and its tree
is their `/dev/provider/SERVICE`; their `/dev/dt/links` gives the
specifier cells that say which clock or reset is theirs
(`lib/Links.swift`), and `/dev/dt/node` their node's properties and
those of the nodes under it (`k1-emac` reads its PHY's there).
Reading `power` before any write gives what firmware left, its
resources' `_STA`: `linlon` reads none of an engine's registers unless
firmware left it powered, and then only flips the layer of the output
firmware lit.

## The input class

Keyboards are 9front's, keyed by HID usages (D83): a keyboard driver
pushes the keyboard page's usages to kbdfs's `kbin` (`services/kbdfs`),
each record a usage then 1 pressed or 0 released, one write a batch.
devmgr mounts `/dev/kbin` into every host whose driver's class is
`input` or `usb`; `KeyboardUsage` (`drivers/input/lib`) turns evdev's codes,
which virtio-input reports, into usages. kbdfs makes runes of them and
serves `/dev/kbd` and `/dev/cons`. Pointers write mouse(4)'s records,
`m dx dy buttons` or `a x y buttons` scaled to 0 to 2^31, a line each, to
the mouse service's `mousein` (`services/mouse`), which devmgr mounts at
`/dev/mousein` in the same hosts; `PointerReport` gathers evdev's motion,
wheel and buttons to each report. virtio-input reads its device's event
queue on MSI-X where the kernel has MSIs, else INTx. A USB keyboard's boot
reports, and a mouse's as its report descriptor lays them out (the boot
report where it has none), become the same records (`BootKeyboard`,
`HIDMouse`), in the USB bus (`drivers/usb/bus`) that each host
controller's driver runs over it, xhci's and ehci's: hubs and HID's boot
devices are the bus's own, not drivers devmgr binds.

## The display class

A display driver serves `todhchai.display.device`'s `Display`
(`drivers/display/lib`, D120): its outputs and their EDIDs, a client's
VMO attached as an image the device reads, which image each output
shows, the flush of an image's damage, and `outputsChanged` when the
device says its displays changed. devmgr mounts each display host's tree
at `dev/display<n>`; Radharc composes onto `/dev/display0`'s outputs where
it is there. virtio-gpu drives a virtio GPU's 2D commands, and where the
device has virgl, blobs and context init, serves the GPU class
(`drivers/gpu`, `GPUDeviceIPC`) at `gpu` beside `display`: contexts on
its capsets, blobs mapped from its host-visible BAR, command streams
and fences, which the Venus client driver uses (loinnir(2)).

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
(`user/include/croi/mmio.h`); `PCIInterrupt(resources, config:)` takes a function's MSI-X vector 0, else
its INTx, for a driver that isn't virtio's, and `pciCapability` finds a
capability; `InterruptPort(device.interrupt())`
waits for its interrupt on a bound port and acks it (V1 has no
interrupt_wait); `PinnedMemory(bti:)` gives zeroed memory and the
device address it is pinned at.

**Adding a driver:** a directory under its class with `Main.swift` and
`driver.manifest`, its program in `kernel/CMakeLists.txt` and bootfs, and
a library target in both builds if it has a `lib/`.

## Tests

`swift test`: ACPITests, PCITests, DeviceTreeTests, DevMgrTests, VirtioTests and InputTests (the match index, the
manifest directives, q35's regions and routes, the IOMMU descriptors,
a platform device's `_CRS` and a devicetree's devices). Natively: `bin/acpi-test` (boot-acpi),
`bin/pci-test` (boot-pci), `bin/dt-test` (rv64's boot-devicetree-bus), and devmgr itself in boot-launch, where
launch-test checks devmgr's status, edu's findings and a key typed
through QEMU's monitor (qemu.sh's `qemu: sendkey`) on every arch.
