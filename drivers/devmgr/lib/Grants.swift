// SPDX-License-Identifier: BSD-3-Clause

// What a driver host is given for its device (architecture §9: exactly
// the MMIO, IRQ, BTI and I/O port handles for it): a resource for each
// BAR, MMIO or I/O ports as the BAR is, and an MMIO resource over the
// function's 4 KiB of ECAM, and an IRQ resource for the GSI its interrupt
// pin is routed to (Routing.swift), and a BTI for its DMA, on the IOMMU
// that covers it (D74, IOMMUs.swift; the stub, which the kernel warns
// about, only where none does), narrowed to the device's address width.
// An ACPI platform device is given its _CRS's ranges, interrupt and the
// stub's BTI instead (`platformGrants`), and a devicetree's device its
// `reg` ranges, interrupts and the stub's BTI (`treeGrants`). They
// come as startup handles of type `HandleType.device` (DriverHost's
// DeviceHandle says which), which the driver takes as DeviceResources.

import DeviceTreeBus
import DriverHost
import PCI
import Sys

/// The resources for function `f`, made under devmgr's MMIO and I/O port
/// ranged roots, with their startup info words. `ecam` is the physical
/// address of bus `startBus`'s window, or `page`, where a host driver put
/// the function's configuration space (HostedBus). A memory BAR is made at the CPU's
/// address for it through `bridge`, the root bridge above it, and left out
/// if none of its windows decodes it; with no bridge, at the BAR's own.
/// A BAR whose kind devmgr has no root
/// for (I/O ports off amd64) is left out, and so are an MSI allocation the
/// kernel can't make and a BTI no IOMMU gives. `iommus` are raw handles to
/// the units' objects, which stay the caller's, and `stub` the stub
/// IOMMU's (0: none); `dma` says where the BTI came from.
public func grants(for f: Function, ecam: UInt64, startBus: UInt8, page: UInt64? = nil, bridge: RootBridge? = nil,
                   mmio: borrowing Handle,
                   ioports: borrowing Handle?, interrupt: InterruptRoute? = nil, irqs: borrowing Handle? = nil,
                   iommus: [(raw: UInt32, name: String)] = [], stub: UInt32 = 0, addressBits: UInt32 = 64,
                   msi: borrowing Handle? = nil, ownMMU: Bool = false, pages: PageLedger? = nil, host: String = "",
                   dma: inout String)
  throws(Status) -> [(info: UInt32, handle: UInt32)]
{
  var out: [(info: UInt32, handle: UInt32)] = []
  var mmios = MMIOGrants(ledger: pages, host: host)
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
        Handle(raw: try mmios.make(parent: mmio, base: base, size: bar.size, name: "\(name) bar\(bar.index)", exclusive: true))
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
  let config = page ?? ecam + UInt64(ECAM.offset(bus: Int(f.address.bus &- startBus), device: f.address.device,
                                                 function: f.address.function))
  try add(DeviceHandle.config) { () throws(Status) in
    Handle(raw: try mmios.make(parent: mmio, base: config, size: 4096, name: "\(name) config", exclusive: false))
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
  for unit in iommus where !ownMMU {
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
      dma = DMAPath.choose(ownMMU: ownMMU, named: false, stub: true).note
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

/// How a device's interrupts are granted: each in its place in the device's
/// description (its index), the first with the info word a host that asks for
/// one interrupt always took (`DeviceHandle.interrupt(_:)`), the later ones
/// with their index in it (`DeviceHandle.interrupt(index:_:)`); at most
/// `DeviceHandle.interruptLimit` of them.
public enum InterruptGrants {
  public struct Grant: Equatable {
    public let index: Int
    public let number: UInt32
    public let mode: Sys.Interrupt.Mode
    public var info: UInt32 { DeviceHandle.interrupt(index: index, mode) }
  }

  public static func plan(_ interrupts: [(number: UInt32, mode: Sys.Interrupt.Mode)]) -> [Grant] {
    var out: [Grant] = []
    for (index, i) in interrupts.prefix(DeviceHandle.interruptLimit).enumerated() {
      out.append(Grant(index: index, number: i.number, mode: i.mode))
    }
    return out
  }
}

/// What an ACPI platform device is given: an MMIO or I/O port resource
/// for each range its _CRS names, in order, as `DeviceHandle.bar(0...5)`,
/// then its linked ranges (Platform.swift), and its interrupts (the first as
/// `DeviceHandle.interrupt(_:)`, the others by index: `InterruptGrants`).
/// Ranges of a kind devmgr has no root for are left out (I/O ports only
/// where no linked range follows them). Its BTI is an IOMMU's where the
/// IORT names it (`named`: the unit, a raw handle that stays the caller's,
/// its name, and bti_create's id for the named component, D146), and
/// otherwise the stub IOMMU's, device `id` (`stub`, a raw handle that
/// stays the caller's; 0: none); `dma` says which. A board rule's firmware call (`call`) adds an SMC
/// resource for its function, made under `smc`, and its memory as the
/// next BAR; where the kernel refuses either, neither is granted, and
/// `firmware` says why.
public func platformGrants(for d: Device.ACPIDevice, mmio: borrowing Handle, ioports: borrowing Handle?,
                           irqs: borrowing Handle?, named: (raw: UInt32, name: String, id: UInt64)? = nil, stub: UInt32 = 0,
                           id: UInt64 = 0, addressBits: UInt32 = 64, ownMMU: Bool = false,
                           call: FirmwareCall? = nil, smc: borrowing Handle? = nil, pages: PageLedger? = nil,
                           host: String = "", firmware: inout String, dma: inout String) throws(Status) -> [(info: UInt32, handle: UInt32)]
{
  var out: [(info: UInt32, handle: UInt32)] = []
  var index = 0, interrupts = 0
  var mmios = MMIOGrants(ledger: pages, host: host)
  let name = Device(acpi: d).name
  dma = "none"
  firmware = call == nil ? "" : "no SMC resource"
  do throws(Status) {
    if let named, !ownMMU {
      let (bti, failure) = makeBTI(named.raw, named.id)
      if bti != 0 {
        out.append((DeviceHandle.bti, try narrow(bti, addressBits).release()))
        dma = "translated by " + named.name
      } else if let failure {
        dma = named.name + " refused it: \(failure.rawValue)"
      }
    }
    if stub != 0, out.isEmpty {
      let (bti, _) = makeBTI(stub, id)
      if bti != 0 {
        out.append((DeviceHandle.bti, try narrow(bti, addressBits).release()))
        dma = ownMMU || named == nil ? DMAPath.choose(ownMMU: ownMMU, named: false, stub: true).note : dma + "; passthrough"
      }
    }
    for r in d.resources {
      switch r {
      case .mmio(let base, let size):
        guard index < 6 else { continue }
        out.append((DeviceHandle.bar(index),
                    try mmios.make(parent: mmio, base: base, size: size, name: name, exclusive: true)))
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
        guard interrupts < DeviceHandle.interruptLimit else { continue }
        switch irqs {
        case .some(let root):
          // The first one a host that wants one interrupt takes; a later one
          // that the kernel refuses is left out, its index kept free.
          let info = DeviceHandle.interrupt(index: interrupts, mode)
          if interrupts == 0 {
            out.append((info, try Resource.create(parent: root, kind: .irq, base: UInt64(number), size: 1, name: name)
              .release()))
          } else if let later = try? Resource.create(parent: root, kind: .irq, base: UInt64(number), size: 1, name: name) {
            out.append((info, later.release()))
          }
          interrupts += 1
        case .none: break
        }
      }
    }
    // A missing I/O port range would shift the indices `--bar` names.
    if let first = PlatformTables.barRoles(d, firmwareCall: call != nil).first, first.index != index {
      throw Status.notSupported
    }
    for l in d.linked where index < 6 {
      out.append((DeviceHandle.bar(index),
                  try mmios.make(parent: mmio, base: l.base, size: l.size, name: name,
                                  exclusive: GrantPolicy.linkedRangesExclusive)))
      index += 1
    }
    if let call, index < 6 {
      switch smc {
      case .some(let root):
        do throws(Status) {
          let function = try Resource.create(parent: root, kind: .smc, base: UInt64(call.function), size: 1, name: name)
          let memory = try mmios.make(parent: mmio, base: call.memory, size: call.size, name: name, exclusive: true)
          out.append((DeviceHandle.bar(index), memory))
          out.append((DeviceHandle.smc, function.release()))
          firmware = "smc " + hex(call.function, digits: 8)
        } catch {
          firmware = "smc refused: \(error.rawValue)"
        }
      case .none: break
      }
    }
  } catch {
    for e in out { close(raw: e.handle) }
    throw error
  }
  return out
}

/// What a devicetree's device is given (D154): an MMIO resource for each
/// of its `reg` ranges, in order, as `DeviceHandle.bar(0...5)`; its
/// interrupts, on the controller the kernel owns (`InterruptGrants`); and the stub
/// IOMMU's BTI, device `id` (`stub`, a raw handle that stays the caller's;
/// 0: none), narrowed to `addressBits`. Its `iommus` units aren't the
/// kernel's yet. `dma` says where the BTI came from.
public func treeGrants(for d: TreeDevice, mmio: borrowing Handle, irqs: borrowing Handle?, stub: UInt32 = 0,
                       id: UInt64 = 0, addressBits: UInt32 = 64, ownMMU: Bool = false,
                       pages: PageLedger? = nil, host: String = "", dma: inout String) throws(Status) -> [(info: UInt32, handle: UInt32)]
{
  var out: [(info: UInt32, handle: UInt32)] = []
  let name = Device(dt: d).name
  var mmios = MMIOGrants(ledger: pages, host: host)
  dma = "none"
  do throws(Status) {
    if stub != 0 {
      let (bti, _) = makeBTI(stub, id)
      if bti != 0 {
        out.append((DeviceHandle.bti, try narrow(bti, addressBits).release()))
        dma = DMAPath.choose(ownMMU: ownMMU, named: false, stub: true).note
      }
    }
    for (index, r) in d.ranges.prefix(6).enumerated() {
      out.append((DeviceHandle.bar(index),
                  try mmios.make(parent: mmio, base: r.base, size: r.size, name: name, exclusive: true)))
    }
    for g in InterruptGrants.plan(d.interrupts.map { (number: $0.gsi, mode: $0.mode) }) {
      switch irqs {
      case .some(let root):
        if g.index == 0 {
          out.append((g.info, try Resource.create(parent: root, kind: .irq, base: UInt64(g.number), size: 1, name: name)
            .release()))
        } else if let later = try? Resource.create(parent: root, kind: .irq, base: UInt64(g.number), size: 1, name: name) {
          out.append((g.info, later.release()))
        }
      case .none: break
      }
    }
  } catch {
    for e in out { close(raw: e.handle) }
    throw error
  }
  return out
}

extension TreeDevice.Interrupt {
  /// How the kernel takes it (interrupt_create's mode).
  public var mode: Sys.Interrupt.Mode {
    switch trigger {
    case .levelHigh: .levelHigh
    case .levelLow: .levelLow
    case .edgeRising: .edgeHigh
    case .edgeFalling: .edgeLow
    }
  }
}
