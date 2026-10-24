// SPDX-License-Identifier: BSD-3-Clause

// What a driver host is given for its device (architecture §9: exactly
// the MMIO, IRQ, BTI and I/O port handles for it): a resource for each
// BAR, MMIO or I/O ports as the BAR is, and an MMIO resource over the
// function's 4 KiB of ECAM, and an IRQ resource for the GSI its interrupt
// pin is routed to (Routing.swift), and a BTI for its DMA, on the IOMMU
// that covers it (D74, IOMMUs.swift; the stub, which the kernel warns
// about, only where none does), narrowed to the device's address width.
// An ACPI platform device is given its _CRS's ranges and interrupt
// instead (`platformGrants`). They come as startup handles of type
// `HandleType.device` (DriverHost's DeviceHandle says which), which the
// driver takes as DeviceResources.

import DriverHost
import PCI
import Sys

/// The resources for function `f`, made under devmgr's MMIO and I/O port
/// ranged roots, with their startup info words. `ecam` is the physical
/// address of bus `startBus`'s window. A memory BAR is made at the CPU's
/// address for it through `bridge`, the root bridge above it, and left out
/// if none of its windows decodes it; with no bridge, at the BAR's own.
/// A BAR whose kind devmgr has no root
/// for (I/O ports off amd64) is left out, and so are an MSI allocation the
/// kernel can't make and a BTI no IOMMU gives. `iommus` are raw handles to
/// the units' objects, which stay the caller's, and `stub` the stub
/// IOMMU's (0: none); `dma` says where the BTI came from.
public func grants(for f: Function, ecam: UInt64, startBus: UInt8, bridge: RootBridge? = nil, mmio: borrowing Handle,
                   ioports: borrowing Handle?, interrupt: InterruptRoute? = nil, irqs: borrowing Handle? = nil,
                   iommus: [(raw: UInt32, name: String)] = [], stub: UInt32 = 0, addressBits: UInt32 = 64,
                   msi: borrowing Handle? = nil, dma: inout String)
  throws(Status) -> [(info: UInt32, handle: UInt32)]
{
  var out: [(info: UInt32, handle: UInt32)] = []
  func add(_ info: UInt32, _ make: () throws(Status) -> Handle) throws(Status) {
    do throws(Status) {
      out.append((info, try make().release()))
    } catch {
      for e in out { close(raw: e.handle) }
      throw error
    }
  }
  let name = f.address.description
  for bar in f.bars {
    switch bar.space {
    case .memory:
      var base = bar.address
      if let bridge {
        guard let cpu = bridge.cpuAddress(bar.address, size: bar.size) else { continue }
        base = cpu
      }
      try add(DeviceHandle.bar(bar.index)) { () throws(Status) in
        try Resource.create(parent: mmio, kind: .mmio, base: base, size: bar.size, name: "\(name) bar\(bar.index)")
      }
    case .io:
      switch ioports {
      case .some(let ports):
        try add(DeviceHandle.bar(bar.index)) { () throws(Status) in
          try Resource.create(parent: ports, kind: .ioport, base: bar.address, size: bar.size,
                              name: "\(name) bar\(bar.index)")
        }
      case .none: break
      }
    }
  }
  let config = ecam + UInt64(ECAM.offset(bus: Int(f.address.bus - startBus), device: f.address.device,
                                         function: f.address.function))
  try add(DeviceHandle.config) { () throws(Status) in
    try Resource.create(parent: mmio, kind: .mmio, base: config, size: 4096, name: "\(name) config")
  }
  if let interrupt {
    switch irqs {
    case .some(let root):
      try add(DeviceHandle.interrupt(interrupt.mode)) { () throws(Status) in
        try Resource.create(parent: root, kind: .irq, base: UInt64(interrupt.gsi), size: 1, name: "\(name) irq")
      }
    case .none: break
    }
  }
  // MSI-X or MSI: one vector for now (virtio's queue, its configuration
  // changes not asked for; HDA's controller, M4g). More come with the
  // drivers that want them. Where the kernel has no MSIs yet, none.
  if f.capability(0x11) != nil || f.capability(0x05) != nil {
    switch msi {
    case .some(let resource):
      if let allocation = try? Interrupt.msiAllocate(resource: resource, count: 1) {
        out.append((DeviceHandle.msi, allocation.release()))
      }
    case .none: break
    }
  }
  // The requester id, bus << 8 | device << 3 | function, which each kind
  // of unit maps to its own device id: the first unit that covers it.
  let a = f.address
  let id = UInt64(a.bus) << 8 | UInt64(a.device) << 3 | UInt64(a.function)
  dma = "none"
  for unit in iommus {
    let (bti, failure) = makeBTI(unit.raw, id)
    if bti != 0 {
      dma = unit.name
      try add(DeviceHandle.bti) { () throws(Status) in try narrow(bti, addressBits) }
      return out
    }
    if let failure, failure != .outOfRange { dma = unit.name + " refused it: \(failure.rawValue)" }
  }
  if stub != 0 {
    let (bti, _) = makeBTI(stub, UInt64(a.segment) << 16 | id)
    if bti != 0 {
      dma = "passthrough: no IOMMU covers it"
      try add(DeviceHandle.bti) { () throws(Status) in try narrow(bti, addressBits) }
    }
  }
  return out
}

/// A BTI for device `id` on the IOMMU `iommu` (a raw handle that stays
/// the caller's): its raw handle, or 0 and why not.
func makeBTI(_ iommu: UInt32, _ id: UInt64) -> (UInt32, Status?) {
  let unit = Handle(raw: iommu)
  var made: (UInt32, Status?) = (0, nil)
  do throws(Status) {
    made = (try DMA.bti(iommu: unit, id: id).release(), nil)
  } catch {
    made = (0, error)
  }
  _ = unit.release()
  return made
}

/// BTI `raw` narrowed to the device's address width (bti_set_properties),
/// as a handle; closed if that fails.
func narrow(_ raw: UInt32, _ addressBits: UInt32) throws(Status) -> Handle {
  let bti = Handle(raw: raw)
  if addressBits < 64 { try DMA.setProperties(bti, DMA.Properties(addressBits: addressBits)) }
  return bti
}

/// What an ACPI platform device is given: an MMIO or I/O port resource
/// for each range its _CRS names, in order, as `DeviceHandle.bar(0...5)`,
/// and its first interrupt. Ranges of a kind devmgr has no root for are
/// left out.
public func platformGrants(for d: Device.ACPIDevice, mmio: borrowing Handle, ioports: borrowing Handle?,
                           irqs: borrowing Handle?) throws(Status) -> [(info: UInt32, handle: UInt32)]
{
  var out: [(info: UInt32, handle: UInt32)] = []
  var index = 0, interrupted = false
  let name = Device(acpi: d).name
  do throws(Status) {
    for r in d.resources {
      switch r {
      case .mmio(let base, let size):
        guard index < 6 else { continue }
        out.append((DeviceHandle.bar(index),
                    try Resource.create(parent: mmio, kind: .mmio, base: base, size: size, name: name).release()))
        index += 1
      case .ioport(let base, let count):
        guard index < 6 else { continue }
        switch ioports {
        case .some(let ports):
          out.append((DeviceHandle.bar(index),
                      try Resource.create(parent: ports, kind: .ioport, base: UInt64(base), size: UInt64(count),
                                          name: name).release()))
          index += 1
        case .none: break
        }
      case .interrupt(let number, let mode):
        guard !interrupted else { continue }
        switch irqs {
        case .some(let root):
          out.append((DeviceHandle.interrupt(mode),
                      try Resource.create(parent: root, kind: .irq, base: UInt64(number), size: 1, name: name)
                        .release()))
          interrupted = true
        case .none: break
        }
      }
    }
  } catch {
    for e in out { close(raw: e.handle) }
    throw error
  }
  return out
}
