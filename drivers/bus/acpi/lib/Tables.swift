// SPDX-License-Identifier: BSD-3-Clause

/// What can go wrong reading ACPI tables and AML. Tier 0: no strings.
public enum ACPIError: Error, Equatable, Sendable {
  /// Fewer bytes than the structure needs, or than its length says.
  case truncated
  /// The signature isn't the one expected.
  case badSignature
  /// The bytes don't sum to zero (ACPI 6.5 §5.2.5.3, §5.2.6).
  case badChecksum
  /// The table set has no table with this signature.
  case missingTable
  /// AML that doesn't follow the grammar, at this offset in its table.
  case malformed(UInt32)
  /// An opcode ACPI 6.5 doesn't define (0x5Bxx for extended ones).
  case unknownOpcode(UInt16, at: UInt32)
  /// Terms nested deeper than any real table: taken as malformed.
  case tooDeep
  // Run-time errors (A0c): each aborts the method, as §19.3.5.4 says.
  /// A name that isn't in the namespace.
  case notFound
  /// An operand of the wrong type, or a conversion the rules forbid
  /// (such as an empty string or buffer to an integer).
  case typeMismatch
  /// An uninitialized local, argument or element was read.
  case uninitialized
  case divideByZero
  /// An index past the end of a package, buffer or string.
  case outOfBounds
  /// Methods called too deep (recursion without end).
  case callTooDeep
  /// A While that didn't finish within its limit.
  case loopLimit
  /// Break or Continue outside a While.
  case misplacedBreak
  /// Something the interpreter doesn't do yet (fields until A0d).
  case unsupported
  /// Acquire out of sync-level order, or Release of a mutex not held.
  case mutexOrder
  /// A resource template (§6.4) that doesn't parse: a descriptor cut
  /// short, an unknown type, no end tag.
  case badResourceTemplate
  // Limits (A0f): what keeps any input, however hostile, from trapping
  // or exhausting the process.
  /// An evaluation ran more statements than its budget (`stepLimit`).
  case stepLimit
  /// A string, buffer or field larger than the interpreter makes.
  case tooLarge
  /// More namespace objects than the interpreter keeps.
  case tooManyObjects
  /// An object whose value depends on itself (a region whose offset reads
  /// its own field, a reference to itself, an index field through itself).
  case recursive
}

/// Little-endian reads from table bytes.
extension Array where Element == UInt8 {
  func le16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
  func le32(_ at: Int) -> UInt32 { UInt32(le16(at)) | UInt32(le16(at + 2)) << 16 }
  func le64(_ at: Int) -> UInt64 { UInt64(le32(at)) | UInt64(le32(at + 4)) << 32 }
}

/// Whether `bytes` sum to zero, modulo 256: how every ACPI checksum works.
func sumsToZero(_ bytes: ArraySlice<UInt8>) -> Bool {
  var sum: UInt8 = 0
  for b in bytes { sum &+= b }
  return sum == 0
}

/// A four-character table signature ("DSDT", "FACP", "SSDT").
public struct Signature: Equatable, Sendable {
  public var bytes: [UInt8]
  public init(_ text: StaticString) { bytes = unsafe text.withUTF8Buffer { unsafe Array($0) } }
  public init(bytes: [UInt8]) { self.bytes = bytes }

  public static let dsdt = Signature("DSDT")
  public static let ssdt = Signature("SSDT")
  public static let fadt = Signature("FACP")
  public static let rsdt = Signature("RSDT")
  public static let xsdt = Signature("XSDT")
}

/// A system description table: its 36-byte header (ACPI 6.5 §5.2.6) and
/// all its bytes.
public struct Table: Sendable {
  public let bytes: [UInt8]

  public static let headerSize = 36

  /// A table from its bytes: the header's length must fit them (extra
  /// bytes after it are dropped) and the whole table must sum to zero.
  public init(_ bytes: [UInt8]) throws(ACPIError) {
    guard bytes.count >= Self.headerSize else { throw .truncated }
    let length = Int(bytes.le32(4))
    guard length >= Self.headerSize, length <= bytes.count else { throw .truncated }
    let table = Array(bytes[..<length])
    guard sumsToZero(table[...]) else { throw .badChecksum }
    self.bytes = table
  }

  public var signature: Signature { Signature(bytes: Array(bytes[0..<4])) }
  public var length: Int { bytes.count }
  /// For the DSDT and SSDTs, whether integers are 64-bit (2 and later) or
  /// 32-bit (ACPI 6.5 §5.2.11.1).
  public var revision: UInt8 { bytes[8] }
  public var oemID: [UInt8] { Array(bytes[10..<16]) }
  public var oemTableID: [UInt8] { Array(bytes[16..<24]) }
  public var oemRevision: UInt32 { bytes.le32(24) }
  public var creatorID: [UInt8] { Array(bytes[28..<32]) }
  public var creatorRevision: UInt32 { bytes.le32(32) }
  /// Everything after the header: for a DSDT or SSDT, its AML.
  public var body: ArraySlice<UInt8> { bytes[Self.headerSize...] }
}

/// The Root System Description Pointer (ACPI 6.5 §5.2.5.3): where the
/// table walk starts.
public struct RSDP: Equatable, Sendable {
  public var revision: UInt8
  public var rsdtAddress: UInt32
  /// From revision 2: the XSDT, which wins over the RSDT when present.
  public var xsdtAddress: UInt64?

  public init(_ bytes: [UInt8]) throws(ACPIError) {
    guard bytes.count >= 20 else { throw .truncated }
    guard Array(bytes[0..<8]) == [0x52, 0x53, 0x44, 0x20, 0x50, 0x54, 0x52, 0x20] else { throw .badSignature }  // "RSD PTR "
    guard sumsToZero(bytes[0..<20]) else { throw .badChecksum }
    revision = bytes[15]
    rsdtAddress = bytes.le32(16)
    if revision >= 2 {
      guard bytes.count >= 36 else { throw .truncated }
      let length = Int(bytes.le32(20))
      guard length >= 36, length <= bytes.count else { throw .truncated }
      guard sumsToZero(bytes[0..<length]) else { throw .badChecksum }
      let x = bytes.le64(24)
      xsdtAddress = x == 0 ? nil : x
    } else {
      xsdtAddress = nil
    }
  }
}

/// The Fixed ACPI Description Table's fields the interpreter needs (ACPI
/// 6.5 §5.2.9).
public struct FADT: Sendable {
  public let table: Table

  public init(_ table: Table) throws(ACPIError) {
    guard table.signature == .fadt else { throw .badSignature }
    guard table.length >= 44 else { throw .truncated }
    self.table = table
  }

  /// The DSDT's address: X_DSDT (offset 140) when the table has it and it
  /// isn't zero, else DSDT (offset 40).
  public var dsdtAddress: UInt64 {
    if table.length >= 148 {
      let x = table.bytes.le64(140)
      if x != 0 { return x }
    }
    return UInt64(table.bytes.le32(40))
  }

  /// The FACS's address, the same way (X_FIRMWARE_CTRL at 132, else 36).
  public var facsAddress: UInt64 {
    if table.length >= 140 {
      let x = table.bytes.le64(132)
      if x != 0 { return x }
    }
    return UInt64(table.bytes.le32(36))
  }

  /// The SCI's interrupt (offset 46).
  public var sciInterrupt: UInt16 { table.length >= 48 ? table.bytes.le16(46) : 0 }
  /// The flags (offset 112); bit 20 is HW_REDUCED_ACPI.
  public var flags: UInt32 { table.length >= 116 ? table.bytes.le32(112) : 0 }
  public var isHardwareReduced: Bool { flags & (1 << 20) != 0 }
}

/// The PCI Express memory-mapped configuration table (PCI Firmware 3.2
/// §4.1.2): each segment's ECAM window. After the header, 8 reserved
/// bytes, then 16 bytes an allocation: base address, segment group, start
/// and end bus.
public struct MCFG: Sendable {
  public struct Window: Equatable, Sendable {
    public var base: UInt64
    public var segment: UInt16
    public var startBus: UInt8
    public var endBus: UInt8

    public init(base: UInt64, segment: UInt16, startBus: UInt8, endBus: UInt8) {
      self.base = base
      self.segment = segment
      self.startBus = startBus
      self.endBus = endBus
    }
  }

  public static let signature = Signature("MCFG")
  public let windows: [Window]

  public init(_ table: Table) throws(ACPIError) {
    guard table.signature == Self.signature else { throw .badSignature }
    guard table.length >= Table.headerSize + 8 else { throw .truncated }
    var windows: [Window] = []
    var at = Table.headerSize + 8
    while at + 16 <= table.length {
      let b = table.bytes
      windows.append(Window(base: b.le64(at), segment: b.le16(at + 8), startBus: b[at + 10], endBus: b[at + 11]))
      at += 16
    }
    self.windows = windows
  }
}

/// Every table a machine's firmware describes: the DSDT, its SSDTs, and
/// the rest by signature.
public struct TableSet: Sendable {
  public private(set) var tables: [Table]

  /// From tables already read (hosted: files named by signature, as Linux
  /// and QEMU's fixtures give them).
  public init(_ tables: [Table]) { self.tables = tables }

  /// By walking from the RSDP: the XSDT (or RSDT), each table it lists,
  /// and the DSDT the FADT points at. `read` returns `count` bytes at a
  /// physical address, or nil. Tables that fail their checksum are left
  /// out, as Linux does.
  public init(rsdp: RSDP, read: (UInt64, Int) -> [UInt8]?) throws(ACPIError) {
    func table(at address: UInt64) -> Table? {
      guard let header = read(address, Table.headerSize), header.count == Table.headerSize else { return nil }
      let length = Int(header.le32(4))
      guard length >= Table.headerSize, length <= 1 << 24, let bytes = read(address, length) else { return nil }
      return try? Table(bytes)
    }
    let root: Table
    let entrySize: Int
    if let x = rsdp.xsdtAddress, let t = table(at: x), t.signature == .xsdt {
      root = t
      entrySize = 8
    } else if let t = table(at: UInt64(rsdp.rsdtAddress)), t.signature == .rsdt {
      root = t
      entrySize = 4
    } else {
      throw .missingTable
    }
    var found: [Table] = []
    var at = Table.headerSize
    while at + entrySize <= root.length {
      let address = entrySize == 8 ? root.bytes.le64(at) : UInt64(root.bytes.le32(at))
      if let t = table(at: address) { found.append(t) }
      at += entrySize
    }
    if let fadt = found.first(where: { $0.signature == .fadt }), let f = try? FADT(fadt),
      let dsdt = table(at: f.dsdtAddress), dsdt.signature == .dsdt
    {
      found.append(dsdt)
    }
    tables = found
  }

  /// The `instance`th table (from 0) with this signature.
  public func table(_ signature: Signature, instance: Int = 0) -> Table? {
    var n = 0
    for t in tables where t.signature == signature {
      if n == instance { return t }
      n += 1
    }
    return nil
  }

  public var dsdt: Table? { table(.dsdt) }
  public var ssdts: [Table] { tables.filter { $0.signature == .ssdt } }
  public var fadt: FADT? { table(.fadt).flatMap { try? FADT($0) } }

  /// AML integers are 64-bit unless the DSDT's revision is below 2.
  public var integerBits: Int { (dsdt?.revision ?? 2) < 2 ? 32 : 64 }
}
