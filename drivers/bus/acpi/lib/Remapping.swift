// SPDX-License-Identifier: BSD-3-Clause

// The tables that describe IOMMUs (V2 item 7c, D74), for devmgr to name
// each unit to the kernel (iommu_create): Intel's DMAR (VT-d 4.1 §8), AMD's
// IVRS (AMD I/O Virtualization 3.08 §5.2), Arm's IORT (DEN0049E §3) and
// RISC-V's RIMT (IO Mapping Table 1.0 §2). Only what devmgr uses is read:
// each unit's registers and the devices or memory it names. Malformed
// entries end the walk; what came before them stands.

/// Intel's DMA remapping table: its remapping units (DRHDs) and the
/// memory firmware's own DMA uses (RMRRs).
public struct DMAR: Sendable {
  /// A device scope (§8.3.1): what a unit or a reserved range applies to.
  public struct Scope: Equatable, Sendable {
    /// 1 a PCI endpoint, 2 a sub-hierarchy (a bridge and all below), 3 an
    /// IOAPIC, 4 an HPET, 5 an ACPI namespace device.
    public var type: UInt8
    /// An IOAPIC's or HPET's id, or an ACPI device's number.
    public var enumerationID: UInt8
    public var startBus: UInt8
    /// Each hop's device << 3 | function, from the start bus down.
    public var path: [UInt8]

    public init(type: UInt8, enumerationID: UInt8 = 0, startBus: UInt8, path: [UInt8]) {
      self.type = type
      self.enumerationID = enumerationID
      self.startBus = startBus
      self.path = path
    }

    /// A PCI endpoint one hop from the host bridge.
    public static let endpoint: UInt8 = 1
    public static let subHierarchy: UInt8 = 2
  }

  /// A remapping unit (DRHD, §8.3).
  public struct Unit: Equatable, Sendable {
    public var registerBase: UInt64
    public var segment: UInt16
    /// INCLUDE_PCI_ALL: every device of the segment that no other unit's
    /// scopes name.
    public var includesAll: Bool
    public var scopes: [Scope]
  }

  /// Reserved memory (RMRR, §8.4): firmware's DMA to it continues for the
  /// devices named, so their domains must map it.
  public struct ReservedMemory: Equatable, Sendable {
    public var segment: UInt16
    public var base: UInt64
    /// The last byte's address.
    public var limit: UInt64
    public var scopes: [Scope]
  }

  public static let signature = Signature("DMAR")
  /// The widest DMA address the platform takes, in bits.
  public let hostAddressWidth: Int
  public let units: [Unit]
  public let reserved: [ReservedMemory]

  public init(_ table: Table) throws(ACPIError) {
    guard table.signature == Self.signature else { throw .badSignature }
    guard table.length >= 48 else { throw .truncated }
    let b = table.bytes
    hostAddressWidth = Int(b[36]) + 1
    var units: [Unit] = [], reserved: [ReservedMemory] = []
    var at = 48
    while at + 4 <= table.length {
      let type = b.le16(at), length = Int(b.le16(at + 2))
      guard length >= 4, at + length <= table.length else { break }
      if type == 0, length >= 16 {
        units.append(Unit(registerBase: b.le64(at + 8), segment: b.le16(at + 6), includesAll: b[at + 4] & 1 != 0,
                          scopes: Self.scopes(b, from: at + 16, to: at + length)))
      } else if type == 1, length >= 24 {
        reserved.append(ReservedMemory(segment: b.le16(at + 6), base: b.le64(at + 8), limit: b.le64(at + 16),
                                       scopes: Self.scopes(b, from: at + 24, to: at + length)))
      }
      at += length
    }
    self.units = units
    self.reserved = reserved
  }

  static func scopes(_ b: [UInt8], from start: Int, to end: Int) -> [Scope] {
    var out: [Scope] = []
    var at = start
    while at + 6 <= end {
      let length = Int(b[at + 1])
      guard length >= 6, at + length <= end, (length - 6) % 2 == 0 else { break }
      var path: [UInt8] = []
      var hop = at + 6
      while hop + 2 <= at + length {
        path.append((b[hop] & 0x1F) << 3 | (b[hop + 1] & 0x7))
        hop += 2
      }
      out.append(Scope(type: b[at], enumerationID: b[at + 4], startBus: b[at + 5], path: path))
      at += length
    }
    return out
  }
}

/// AMD's I/O virtualization reporting structure: its IOMMUs (IVHDs) and
/// the memory firmware's DMA uses (IVMDs).
public struct IVRS: Sendable {
  public struct Unit: Equatable, Sendable {
    public var registerBase: UInt64
    public var segment: UInt16
    /// The IOMMU's own PCI function (bus << 8 | device << 3 | function).
    public var deviceID: UInt16
  }

  /// Memory (IVMD, §5.2.2.3) a range of devices reaches identity mapped.
  public struct Memory: Equatable, Sendable {
    public var firstDevice: UInt16
    /// Inclusive.
    public var lastDevice: UInt16
    public var base: UInt64
    public var length: UInt64
    /// Bit 0 unity mapped, 1 readable, 2 writable, 3 exclusion range.
    public var flags: UInt8
  }

  public static let signature = Signature("IVRS")
  /// Each IOMMU once, though firmware may describe it in several IVHD
  /// types (0x10, 0x11, 0x40).
  public let units: [Unit]
  public let memory: [Memory]

  public init(_ table: Table) throws(ACPIError) {
    guard table.signature == Self.signature else { throw .badSignature }
    guard table.length >= 48 else { throw .truncated }
    let b = table.bytes
    var units: [Unit] = [], memory: [Memory] = []
    var at = 48
    while at + 4 <= table.length {
      let type = b[at], length = Int(b.le16(at + 2))
      guard length >= 4, at + length <= table.length else { break }
      if type == 0x10 || type == 0x11 || type == 0x40, length >= 24 {
        let unit = Unit(registerBase: b.le64(at + 8), segment: b.le16(at + 16), deviceID: b.le16(at + 4))
        if !units.contains(where: { $0.registerBase == unit.registerBase }) { units.append(unit) }
      } else if type >= 0x20 && type <= 0x22, length >= 32 {
        let device = b.le16(at + 4), aux = b.le16(at + 6)
        let (first, last): (UInt16, UInt16) = switch type {
        case 0x20: (0, 0xFFFF)
        case 0x21: (device, device)
        default: (device, aux)
        }
        memory.append(Memory(firstDevice: first, lastDevice: last, base: b.le64(at + 16), length: b.le64(at + 24),
                             flags: b[at + 1]))
      }
      at += length
    }
    self.units = units
    self.memory = memory
  }
}

/// Arm's IO remapping table: its SMMUs. Which SMMU a PCI requester id
/// reaches is the kernel's to work out from the same table.
public struct IORT: Sendable {
  public struct SMMU: Equatable, Sendable {
    public var registerBase: UInt64
    /// 3 for SMMUv3 (node type 4); 2 for SMMUv1/v2 (node type 3).
    public var version: Int
  }

  public static let signature = Signature("IORT")
  public let smmus: [SMMU]

  public init(_ table: Table) throws(ACPIError) {
    guard table.signature == Self.signature else { throw .badSignature }
    guard table.length >= 48 else { throw .truncated }
    let b = table.bytes
    let count = Int(b.le32(36))
    var at = Int(b.le32(40))
    var smmus: [SMMU] = []
    for _ in 0..<count {
      guard at + 16 <= table.length else { break }
      let type = b[at], length = Int(b.le16(at + 1))
      guard length >= 16, at + length <= table.length else { break }
      if type == 4, length >= 48 { smmus.append(SMMU(registerBase: b.le64(at + 16), version: 3)) }
      if type == 3, length >= 60 { smmus.append(SMMU(registerBase: b.le64(at + 16), version: 2)) }
      at += length
    }
    self.smmus = smmus
  }
}

/// RISC-V's IO mapping table: its IOMMUs, each a platform device at a
/// base or a PCIe function whose BAR 0 holds its registers.
public struct RIMT: Sendable {
  public struct IOMMU: Equatable, Sendable {
    /// A platform IOMMU's registers (0 for a PCIe one).
    public var base: UInt64
    /// A PCIe-based IOMMU: its segment and function (bus << 8 | device << 3
    /// | function).
    public var pci: (segment: UInt16, function: UInt16)?

    public static func == (a: Self, b: Self) -> Bool {
      a.base == b.base && a.pci?.segment == b.pci?.segment && a.pci?.function == b.pci?.function
    }
  }

  public static let signature = Signature("RIMT")
  public let iommus: [IOMMU]

  public init(_ table: Table) throws(ACPIError) {
    guard table.signature == Self.signature else { throw .badSignature }
    guard table.length >= 48 else { throw .truncated }
    let b = table.bytes
    let count = Int(b.le32(36))
    var at = Int(b.le32(40))
    var iommus: [IOMMU] = []
    for _ in 0..<count {
      guard at + 8 <= table.length else { break }
      let type = b[at], length = Int(b.le16(at + 2))
      guard length >= 8, at + length <= table.length else { break }
      if type == 0, length >= 40 {
        let pci = b.le32(at + 24) & 1 != 0
        iommus.append(IOMMU(base: b.le64(at + 16), pci: pci ? (b.le16(at + 32), b.le16(at + 34)) : nil))
      }
      at += length
    }
    self.iommus = iommus
  }
}
