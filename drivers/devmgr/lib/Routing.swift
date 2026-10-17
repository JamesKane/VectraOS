// SPDX-License-Identifier: BSD-3-Clause

// PCI interrupt routing from ACPI (ACPI 6.5 §6.2.13 _PRT, §5.8.1 _PIC,
// §6.4.3.6 the Extended Interrupt descriptor): which global system
// interrupt each slot's INTA-INTD reaches on the root bus, and how it
// signals. devmgr first tells the firmware the OS uses the APIC (\_PIC(1)),
// as _PRT's answer depends on it; a route through a link device takes the
// link's current _CRS. Slots behind bridges (swizzled through each
// bridge's own _PRT or the standard rotation) come with the first device
// that needs them.

import Sys
import TDACPI

public struct InterruptRoute: Equatable, Sendable {
  public var slot: UInt8
  /// 1-4: INTA-INTD, as the configuration space's Interrupt Pin says.
  public var pin: UInt8
  public var gsi: UInt32
  public var mode: Interrupt.Mode

  public init(slot: UInt8, pin: UInt8, gsi: UInt32, mode: Interrupt.Mode) {
    self.slot = slot
    self.pin = pin
    self.gsi = gsi
    self.mode = mode
  }
}

extension Namespace {
  /// \_PIC(1): the OS uses the APIC (or GIC) model. Absent on many machines.
  public mutating func useAPIC<H: ACPIHost>(host: H) throws(ACPIError) {
    guard let pic = lookup("\\_PIC") else { return }
    _ = try evaluate(pic, [.integer(1)], host: host)
  }

  /// The PCI root bridge for bus 0 (PNP0A08 or PNP0A03), if any.
  public mutating func rootBridge<H: ACPIHost>(host: H) -> Int? {
    for d in deviceNodes() {
      var ids: [[UInt8]] = []
      if let hid = (try? hardwareID(d, host: host)) ?? nil { ids.append(hid) }
      ids += (try? compatibleIDs(d, host: host)) ?? []
      guard ids.contains(Array("PNP0A08".utf8)) || ids.contains(Array("PNP0A03".utf8)) else { continue }
      let bus = (try? childInteger(d, "_BBN", host: host)) ?? 0
      if bus == 0 { return d }
    }
    return nil
  }

  mutating func childInteger<H: ACPIHost>(_ device: Int, _ name: StaticString, host: H) throws(ACPIError) -> UInt64? {
    guard let v = try childValue(device, name, host: host) else { return nil }
    return v.integer
  }

  /// The root bus's routes, each resolved to a GSI and mode.
  public mutating func interruptRoutes<H: ACPIHost>(host: H) throws(ACPIError) -> [InterruptRoute] {
    guard let root = rootBridge(host: host), let routes = try routing(root, host: host) else { return [] }
    var out: [InterruptRoute] = []
    for r in routes {
      let slot = UInt8(truncatingIfNeeded: r.device), pin = r.pin + 1
      guard let link = r.link else {
        // A GSI directly: PCI's default, level and active low.
        out.append(InterruptRoute(slot: slot, pin: pin, gsi: r.index, mode: .levelLow))
        continue
      }
      guard let resources = try currentResources(link, host: host) else { continue }
      for res in resources {
        switch res {
        case .extendedIRQ(let flags, let interrupts, _):
          guard Int(r.index) < interrupts.count else { continue }
          out.append(InterruptRoute(slot: slot, pin: pin, gsi: interrupts[Int(r.index)], mode: Self.mode(edge: flags & 2 != 0,
                                                                                                         low: flags & 4 != 0)))
        case .irq(let mask, let flags):
          guard mask != 0 else { continue }
          out.append(InterruptRoute(slot: slot, pin: pin, gsi: UInt32(mask.trailingZeroBitCount),
                                    mode: Self.mode(edge: flags & 1 != 0, low: flags & 8 != 0)))
        default:
          continue
        }
        break
      }
    }
    return out
  }

  static func mode(edge: Bool, low: Bool) -> Interrupt.Mode {
    switch (edge, low) {
    case (true, true): .edgeLow
    case (true, false): .edgeHigh
    case (false, true): .levelLow
    case (false, false): .levelHigh
    }
  }
}

extension Device.PlatformResource {
  /// What devmgr grants for a platform device's _CRS (D74): its memory
  /// and I/O ranges (where firmware placed them: a range's minimum) and its
  /// interrupts. DMA channels, GPIO and serial buses wait for the drivers
  /// that need them, and so does ISA's 24-bit memory.
  public static func of(_ resources: [TDACPI.Resource]) -> [Device.PlatformResource] {
    var out: [Device.PlatformResource] = []
    for r in resources {
      switch r {
      case .io(_, let minimum, _, _, let length) where length > 0: out.append(.ioport(base: minimum, count: UInt16(length)))
      case .fixedIO(let base, let length) where length > 0: out.append(.ioport(base: base, count: UInt16(length)))
      case .memory32(_, let minimum, _, _, let length) where length > 0:
        out.append(.mmio(base: UInt64(minimum), size: UInt64(length)))
      case .memory32Fixed(_, let base, let length) where length > 0:
        out.append(.mmio(base: UInt64(base), size: UInt64(length)))
      case .address(let a) where a.length > 0 && (a.kind == 0 || a.kind == 1):
        if a.kind == 0 {
          out.append(.mmio(base: a.minimum, size: a.length))
        } else if a.minimum <= 0xFFFF, a.length <= 0x10000 {
          out.append(.ioport(base: UInt16(a.minimum), count: UInt16(truncatingIfNeeded: a.length)))
        }
      case .irq(let mask, let flags):
        for bit in 0..<16 where mask & (1 << UInt16(bit)) != 0 {
          out.append(.interrupt(UInt32(bit), Namespace.mode(edge: flags & 1 != 0, low: flags & 8 != 0)))
        }
      case .extendedIRQ(let flags, let interrupts, _):
        for n in interrupts { out.append(.interrupt(n, Namespace.mode(edge: flags & 2 != 0, low: flags & 4 != 0))) }
      default:
        continue
      }
    }
    return out
  }
}
