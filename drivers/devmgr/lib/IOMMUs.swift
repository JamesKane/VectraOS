// SPDX-License-Identifier: BSD-3-Clause

// The machine's IOMMUs as iommu_create takes them (D74): each remapping
// unit firmware's tables describe (TDACPI's Remapping.swift), with the
// descriptor dma.h lays out for its kind. devmgr creates each unit's
// object, and a device's BTI comes from the first unit that covers it:
// the kernel, which reads the same tables, answers OUT_OF_RANGE for the
// rest. Not yet: VT-d scopes behind bridges (the kernel refuses them, so
// they are left out and those devices fall to no unit), AMD-Vi's
// exclusion ranges, and SMMUv1/v2 (their BTIs need a board's stream
// match pairs).

import PCI
import Sys
import TDACPI

/// A remapping unit: its kind, registers and iommu_create descriptor.
public struct IOMMUUnit: Equatable, Sendable {
  public var type: DMA.IOMMUType
  public var registerBase: UInt64
  public var descriptor: [UInt8]

  public init(type: DMA.IOMMUType, registerBase: UInt64, descriptor: [UInt8]) {
    self.type = type
    self.registerBase = registerBase
    self.descriptor = descriptor
  }

  /// `VT-d fed90000`, for devmgr's status.
  public var name: String {
    let kind = switch type {
    case .stub: "stub"
    case .intel: "VT-d"
    case .amd: "AMD-Vi"
    case .armSMMU: "SMMUv3"
    case .riscv: "RISC-V IOMMU"
    }
    let high = UInt32(truncatingIfNeeded: registerBase >> 32)
    return kind + " " + (high == 0 ? "" : hex(high, digits: 8)) + hex(UInt32(truncatingIfNeeded: registerBase), digits: 8)
  }
}

/// Little-endian bytes, as the kernel's structures are laid out.
struct Bytes {
  var out: [UInt8] = []
  mutating func u8(_ v: UInt8) { out.append(v) }
  mutating func u16(_ v: UInt16) { for i in 0..<2 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt16(i)))) } }
  mutating func u64(_ v: UInt64) { for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
  mutating func zeros(_ n: Int) { out += [UInt8](repeating: 0, count: n) }
}

public enum IOMMUs {
  /// Every unit `tables` describe. A PCIe-based RISC-V IOMMU's registers
  /// are its BAR 0, found among `functions`.
  public static func units(_ tables: TableSet, functions: [Function]) -> [IOMMUUnit] {
    var out: [IOMMUUnit] = []
    if let t = tables.table(DMAR.signature), let dmar = try? DMAR(t) { out += intel(dmar) }
    if let t = tables.table(IVRS.signature), let ivrs = try? IVRS(t) { out += amd(ivrs) }
    if let t = tables.table(IORT.signature), let iort = try? IORT(t) {
      for s in iort.smmus where s.version == 3 {
        var b = Bytes()
        b.u64(s.registerBase)
        out.append(IOMMUUnit(type: .armSMMU, registerBase: s.registerBase, descriptor: b.out))
      }
    }
    if let t = tables.table(RIMT.signature), let rimt = try? RIMT(t) {
      for i in rimt.iommus {
        var base = i.base
        if let pci = i.pci {
          let f = functions.first {
            $0.address.segment == pci.segment
              && UInt16($0.address.bus) << 8 | UInt16($0.address.device) << 3 | UInt16($0.address.function)
                == pci.function
          }
          guard let bar = f?.bars.first(where: { $0.index == 0 && $0.space == .memory }) else { continue }
          base = bar.address
        }
        var b = Bytes()
        b.u64(base)
        out.append(IOMMUUnit(type: .riscv, registerBase: base, descriptor: b.out))
      }
    }
    return out
  }

  /// VT-d's units: an INCLUDE_PCI_ALL unit is the segment less the
  /// devices other units name (`whole_segment`, its scopes the
  /// exceptions); another, the endpoints it names. Each with the
  /// reserved memory of the devices it covers.
  static func intel(_ dmar: DMAR) -> [IOMMUUnit] {
    func endpoints(_ scopes: [DMAR.Scope]) -> [DMAR.Scope] {
      scopes.filter { $0.type == DMAR.Scope.endpoint && !$0.path.isEmpty && $0.path.count <= 5 }
    }
    func same(_ a: DMAR.Scope, _ b: DMAR.Scope) -> Bool { a.startBus == b.startBus && a.path == b.path }
    var out: [IOMMUUnit] = []
    for (i, u) in dmar.units.enumerated() {
      var others: [DMAR.Scope] = []
      for (j, o) in dmar.units.enumerated() where j != i && o.segment == u.segment { others += endpoints(o.scopes) }
      let scopes = u.includesAll ? others : endpoints(u.scopes)
      let covers = { (s: DMAR.Scope) -> Bool in
        u.includesAll ? !scopes.contains { same($0, s) } : scopes.contains { same($0, s) }
      }
      var reserved = Bytes()
      for r in dmar.reserved where r.segment == u.segment && r.limit >= r.base {
        let mine = endpoints(r.scopes).filter(covers)
        guard !mine.isEmpty else { continue }
        reserved.u64(r.base)
        reserved.u64(r.limit - r.base + 1)
        reserved.u8(UInt8(mine.count * 8))
        reserved.zeros(7)
        for s in mine { scope(&reserved, s) }
      }
      guard scopes.count * 8 <= 255, reserved.out.count <= 0xFFFF else { continue }
      var b = Bytes()
      b.u64(u.registerBase)
      b.u16(u.segment)
      b.u8(u.includesAll ? 1 : 0)
      b.u8(UInt8(scopes.count * 8))
      b.u16(UInt16(reserved.out.count))
      b.zeros(2)
      for s in scopes { scope(&b, s) }
      out.append(IOMMUUnit(type: .intel, registerBase: u.registerBase, descriptor: b.out + reserved.out))
    }
    return out
  }

  /// croi_iommu_desc_intel_scope_t: an endpoint, its start bus and hops.
  static func scope(_ b: inout Bytes, _ s: DMAR.Scope) {
    b.u8(0)  // CROI_IOMMU_INTEL_SCOPE_ENDPOINT
    b.u8(s.startBus)
    b.u8(UInt8(s.path.count))
    for i in 0..<5 { b.u8(i < s.path.count ? s.path[i] : 0) }
  }

  /// AMD-Vi's units, each with the unity-mapped memory (IVMD) of its
  /// segment's devices.
  static func amd(_ ivrs: IVRS) -> [IOMMUUnit] {
    ivrs.units.map { u in
      var unity = Bytes()
      for m in ivrs.memory where m.flags & 1 != 0 && m.lastDevice >= m.firstDevice {
        unity.u64(m.base)
        unity.u64(m.length)
        unity.u16(m.firstDevice)
        unity.u16(m.lastDevice)
        unity.zeros(4)
      }
      var b = Bytes()
      b.u64(u.registerBase)
      b.u16(u.segment)
      b.u16(UInt16(truncatingIfNeeded: unity.out.count))
      b.zeros(4)
      return IOMMUUnit(type: .amd, registerBase: u.registerBase, descriptor: b.out + unity.out)
    }
  }
}
