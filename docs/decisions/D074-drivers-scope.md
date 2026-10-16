# D74. Drivers as todhchai's, ported to V1: real IOMMUs, ACPI platform devices, the runtime's MMIO accessors (2026-10-16, decided)

V2's item 7 lifts todhchai's drivers (provenance: Lift, V2): its AML
interpreter (bus/acpi), PCI over ECAM (bus/pci), devmgr, the driver host,
the virtio library and virtio-input. They were written before V1, against
interrupt_bind and interrupt_wait (cut, D29) and their own ring formats,
so they are ported to V1's ABI (object_bind, D20; acks in arrays, D40)
and the one ring (D43), not lifted as they are. Three choices differ from
todhchai's:
- **Every driver host's DMA goes through a real IOMMU.** todhchai's hosts
  took the stub (`resource system`). croi has VT-d, AMD-Vi, SMMUv3 and the
  RISC-V IOMMU, and QEMU attaches one on every arch: devmgr creates a
  BTI for each device on the unit that covers it and narrows it
  (`bti_set_properties`: window, address width) before it hands it over.
  A machine with no IOMMU still runs drivers, through the kernel's
  passthrough BTI and its WARNING, and devmgr says so in its status.
  This is also V4's: the Sky1's two SMMUv3 are taken over by a board rule.
- **devmgr binds ACPI platform devices as well as PCI ones**, matched by
  `_HID`/`_CID`, their resources (MMIO, IRQ, I/O ports) granted from
  `_CRS`, as NeoVectra's ADR-0024 has it. todhchai's manifest grammar has
  the ACPI ids already, and its devmgr matched PCI alone. The Sky1 is
  SystemReady ACPI and most of its devices are platform devices.
- **Registers are reached through the runtime's MMIO accessors**
  (`croi_mmio_read*`/`croi_mmio_write*`, user/include/croi/runtime.h,
  which the interrupts suite uses), widened to 8 to 64 bits, with a Swift
  `Registers` over them, not Swift's experimental `_Volatile` module,
  which todhchai's host imported. One way to touch a device, and no
  experimental language feature on the device.

Left as todhchai has them: the match order (an exact id, then a
compatible one, then a class, then a fallback; a tie binds neither),
`driver.manifest` records, one host per device started through the
launcher, the modern virtio-pci transport only (QEMU attaches nothing
on virtio-mmio here, and legacy virtio is refused), and ECAM only (no
0xCF8 port access: q35 and both virt machines have ECAM).
