// SPDX-License-Identifier: BSD-3-Clause

import TDACPI

// AML for tests, built from its grammar (ACPI 6.5 §20.2): what an ASL
// compiler would emit, so the synthetic tests need neither a compiler nor
// third-party tables.

enum AML {
  /// PkgLength (§20.2.4) for `content` bytes: the length counts its own
  /// bytes. One byte below 64; else a lead byte (how many follow, in bits
  /// 7-6, and the low nibble) and up to three more.
  static func pkgLength(_ content: Int) -> [UInt8] {
    if content + 1 < 0x40 { return [UInt8(content + 1)] }
    for n in 2...4 {
      let total = content + n
      guard total < 1 << (4 + 8 * (n - 1)) else { continue }
      var out = [UInt8((n - 1) << 6 | (total & 0x0F))]
      for k in 0..<(n - 1) { out.append(UInt8(truncatingIfNeeded: total >> (4 + 8 * k))) }
      return out
    }
    fatalError("a package over 256 MiB")
  }

  /// A package: PkgLength, then its bytes.
  static func package(_ content: [UInt8]) -> [UInt8] { pkgLength(content.count) + content }

  /// A NameSeg (§20.2.2): four characters, padded with "_".
  static func seg(_ s: Substring) -> [UInt8] {
    let b = Array(s.utf8)
    precondition(b.count >= 1 && b.count <= 4, "a name segment is 1 to 4 characters: \(s)")
    return b + [UInt8](repeating: 0x5F, count: 4 - b.count)
  }

  /// A NameString: "\" for the root, "^" for each parent, then segments
  /// joined by "." (one plain; two DualNamePrefix; more MultiNamePrefix;
  /// none NullName).
  static func name(_ path: String) -> [UInt8] {
    var rest = Substring(path)
    var out: [UInt8] = []
    if rest.first == "\\" {
      out.append(0x5C)
      rest = rest.dropFirst()
    }
    while rest.first == "^" {
      out.append(0x5E)
      rest = rest.dropFirst()
    }
    let segments = rest.isEmpty ? [] : rest.split(separator: ".", omittingEmptySubsequences: false)
    switch segments.count {
    case 0: out.append(0x00)
    case 1: out += seg(segments[0])
    case 2: out += [0x2E] + seg(segments[0]) + seg(segments[1])
    default:
      out += [0x2F, UInt8(segments.count)]
      for s in segments { out += seg(s) }
    }
    return out
  }

  /// An integer in the shortest form (§20.2.3): Zero, One, Ones, then
  /// byte, word, dword or qword.
  static func integer(_ v: UInt64) -> [UInt8] {
    switch v {
    case 0: [0x00]
    case 1: [0x01]
    case UInt64.max: [0xFF]
    case ..<0x100: [0x0A, UInt8(v)]
    case ..<0x1_0000: [0x0B] + le(v, 2)
    case ..<0x1_0000_0000: [0x0C] + le(v, 4)
    default: [0x0E] + le(v, 8)
    }
  }

  static func string(_ s: String) -> [UInt8] { [0x0D] + Array(s.utf8) + [0] }

  static func buffer(_ bytes: [UInt8]) -> [UInt8] { [0x11] + package(integer(UInt64(bytes.count)) + bytes) }

  static func packageOf(_ elements: [[UInt8]]) -> [UInt8] {
    [0x12] + package([UInt8(elements.count)] + elements.flatMap { $0 })
  }

  static func scope(_ path: String, _ body: [UInt8]) -> [UInt8] { [0x10] + package(name(path) + body) }

  static func device(_ path: String, _ body: [UInt8]) -> [UInt8] { [0x5B, 0x82] + package(name(path) + body) }

  static func nameObject(_ path: String, _ value: [UInt8]) -> [UInt8] { [0x08] + name(path) + value }

  /// A method: argument count (0-7), serialized, sync level (0-15).
  static func method(_ path: String, args: Int = 0, serialized: Bool = false, syncLevel: Int = 0, _ body: [UInt8])
    -> [UInt8]
  {
    let flags = UInt8(args) | (serialized ? 0x08 : 0) | UInt8(syncLevel << 4)
    return [0x14] + package(name(path) + [flags] + body)
  }

  static func returning(_ value: [UInt8]) -> [UInt8] { [0xA4] + value }

  /// A DSDT whose AML is `body`.
  static func dsdt(_ body: [UInt8], revision: UInt8 = 2) -> [UInt8] { table("DSDT", revision: revision, body) }
}

extension AML {
  /// An opcode and its operands, in order.
  static func op(_ code: UInt8, _ parts: [UInt8]...) -> [UInt8] { [code] + parts.flatMap { $0 } }
  static func ext(_ code: UInt8, _ parts: [UInt8]...) -> [UInt8] { [0x5B, code] + parts.flatMap { $0 } }
  static func local(_ i: Int) -> [UInt8] { [UInt8(0x60 + i)] }
  static func arg(_ i: Int) -> [UInt8] { [UInt8(0x68 + i)] }
  static let none: [UInt8] = [0x00]  // a Target of NullName
  static let debug: [UInt8] = [0x5B, 0x31]

  static func store(_ value: [UInt8], _ target: [UInt8]) -> [UInt8] { op(0x70, value, target) }
  static func ifThen(_ predicate: [UInt8], _ body: [UInt8], else other: [UInt8]? = nil) -> [UInt8] {
    [0xA0] + package(predicate + body) + (other.map { [0xA1] + package($0) } ?? [])
  }
  static func whileLoop(_ predicate: [UInt8], _ body: [UInt8]) -> [UInt8] { [0xA2] + package(predicate + body) }
}

extension AML {
  /// A PkgLength-encoded raw value (a field's width in bits counts no
  /// bytes of its own).
  static func raw(_ v: Int) -> [UInt8] {
    if v < 0x40 { return [UInt8(v)] }
    for n in 2...4 where v < 1 << (4 + 8 * (n - 1)) {
      var out = [UInt8((n - 1) << 6 | (v & 0x0F))]
      for k in 0..<(n - 1) { out.append(UInt8(truncatingIfNeeded: v >> (4 + 8 * k))) }
      return out
    }
    fatalError("too wide")
  }

  enum FieldEntry {
    case named(String, Int)
    case reserved(Int)
    case access(UInt8)
  }

  static func fieldList(_ entries: [FieldEntry]) -> [UInt8] {
    entries.flatMap { e -> [UInt8] in
      switch e {
      case .named(let name, let bits): seg(Substring(name)) + raw(bits)
      case .reserved(let bits): [0x00] + raw(bits)
      case .access(let type): [0x01, type, 0x00]
      }
    }
  }

  static func region(_ name: String, space: UInt8, _ offset: [UInt8], _ length: [UInt8]) -> [UInt8] {
    ext(0x80, AML.name(name), [space], offset, length)
  }

  /// Field (region, flags) { entries }: flags are AccessType | LockRule << 4 | UpdateRule << 5.
  static func field(_ region: String, _ flags: UInt8, _ entries: [FieldEntry]) -> [UInt8] {
    [0x5B, 0x81] + package(AML.name(region) + [flags] + fieldList(entries))
  }

  static func indexField(_ index: String, _ data: String, _ flags: UInt8, _ entries: [FieldEntry]) -> [UInt8] {
    [0x5B, 0x86] + package(AML.name(index) + AML.name(data) + [flags] + fieldList(entries))
  }

  static func bankField(_ region: String, _ bank: String, _ value: [UInt8], _ flags: UInt8, _ entries: [FieldEntry])
    -> [UInt8]
  {
    [0x5B, 0x87] + package(AML.name(region) + AML.name(bank) + value + [flags] + fieldList(entries))
  }
}

/// A host that records what the AML asks of it.
final class RecordingHost: ACPIHost {
  /// Each space's bytes, by address (PCI_Config: by function, then offset).
  var memory: [UInt8: [UInt64: UInt8]] = [:]
  var accesses: [(write: Bool, RegionAccess, UInt64)] = []
  /// Spaces with no handler.
  var unhandled: Set<UInt8> = []

  func key(_ a: RegionAccess) -> UInt64 {
    guard let p = a.pci else { return a.address }
    return UInt64(p.segment) << 48 | UInt64(p.bus) << 40 | UInt64(p.device) << 32 | UInt64(p.function) << 24 | a.address
  }

  func readRegion(_ a: RegionAccess) -> UInt64? {
    guard !unhandled.contains(a.space) else { return nil }
    var v: UInt64 = 0
    for i in 0..<a.width { v |= UInt64(memory[a.space]?[key(a) + UInt64(i)] ?? 0) << (8 * UInt64(i)) }
    accesses.append((false, a, v))
    return v
  }

  func writeRegion(_ a: RegionAccess, _ value: UInt64) -> Bool {
    guard !unhandled.contains(a.space) else { return false }
    for i in 0..<a.width { memory[a.space, default: [:]][key(a) + UInt64(i)] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))) }
    accesses.append((true, a, value))
    return true
  }

  var interfaces: [[UInt8]] = [Array("Windows 2015".utf8)]
  var notifications: [(Int, UInt64)] = []
  var debugged: [String] = []
  var slept: UInt64 = 0
  var ticks: UInt64 = 0
  var fatals = 0

  func supportsInterface(_ name: [UInt8]) -> Bool { interfaces.contains(name) }
  func sleep(milliseconds: UInt64) { slept += milliseconds }
  func stall(microseconds: UInt64) {}
  func notify(_ node: Int, _ value: UInt64) { notifications.append((node, value)) }
  func timer() -> UInt64 {
    ticks += 10
    return ticks
  }
  func debug(_ text: [UInt8]) { debugged.append(String(decoding: text, as: UTF8.self)) }
  func fatal(type: UInt8, code: UInt32, argument: UInt64) { fatals += 1 }
}
