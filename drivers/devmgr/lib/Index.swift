// SPDX-License-Identifier: BSD-3-Clause

// The drivers' match records (M4h, after NeoVectra's drivers-on-demand
// sketch, docs/19 §6 there). Each driver's directory holds a
// `driver.manifest`, one directive a line, `#` starting a comment:
//
//     driver hda                 # first: the program, bootfs's bin/NAME
//     class audio                # its function class (drivers/CLASS)
//     match pci 8086:2668        # a PCI vendor and device
//     match pci-class 04.03      # a PCI class and subclass, or cc.ss.pp
//     match acpi PNP0B00         # an ACPI hardware id
//     match acpi-compatible PNP0C50   # an ACPI compatible id
//     fallback                   # a generic driver: any other's match wins
//     dma-bits 28                # its device's DMA address width
//     sd F                       # a disk's sd(3) letter: /dev/sdF0, sdF1, ...
//
// td collects them into bootfs's `etc/drivers`, and devmgr matches each
// device against the index as data: exact ids first (PCI vendor and
// device, ACPI hardware id), then compatible ids (in the order the device
// lists them), then classes (with a programming interface before
// without), then a fallback driver's rules in the same order. The first
// level any driver matches at decides; two drivers there is an error and
// neither runs. td refuses an index in which two drivers share a rule.

import Directives
import PCI

/// A rule a driver matches devices by.
public enum MatchRule: Equatable, Sendable {
  case pci(vendor: UInt16, device: UInt16)
  case pciClass(UInt8, UInt8, progIF: UInt8?)
  case acpi(String)
  case acpiCompatible(String)

  public var description: String {
    func h(_ v: UInt32, _ n: Int) -> String {
      let s = String(v, radix: 16)
      return String(repeating: "0", count: max(0, n - s.utf8.count)) + s
    }
    switch self {
    case .pci(let v, let d): return "pci \(h(UInt32(v), 4)):\(h(UInt32(d), 4))"
    case .pciClass(let c, let s, let p):
      return "pci-class \(h(UInt32(c), 2)).\(h(UInt32(s), 2))" + (p.map { "." + h(UInt32($0), 2) } ?? "")
    case .acpi(let id): return "acpi \(id)"
    case .acpiCompatible(let id): return "acpi-compatible \(id)"
    }
  }
}

public struct DriverManifest: Equatable, Sendable {
  /// The program, bootfs's `bin/NAME`.
  public var name: String
  public var deviceClass = ""
  public var rules: [MatchRule] = []
  public var fallback = false
  /// The device's DMA address width: its BTI is narrowed to it.
  public var addressBits: UInt32 = 64
  /// A block driver's sd(3) letter (D106): its units are /dev/sd<letter><n>.
  public var sdLetter = ""
  /// Where it was read, for errors: "file:line".
  public var origin: String

  public init(name: String, origin: String) {
    self.name = name
    self.origin = origin
  }
}

public struct IndexError: Error, Equatable, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// What a device binds to.
public enum Binding: Equatable, Sendable {
  /// The index's driver `n`.
  case driver(Int)
  case none
  /// Two or more drivers match at the deciding level: none runs.
  case ambiguous([String])
}

public struct DriverIndex: Sendable {
  public var drivers: [DriverManifest] = []

  public init(drivers: [DriverManifest]) { self.drivers = drivers }

  /// The directives a driver's manifest takes (driver(6)).
  public static let directives: [StaticString] = ["driver", "class", "fallback", "dma-bits", "sd", "match"]

  /// Manifests, one after another (a driver starts at its `driver` line),
  /// read as directives (D86).
  public init(text: String, file: String) throws(IndexError) {
    let read: [Directive]
    do throws(DirectiveError) { read = try Directives.read(Array(text.utf8), file: file, known: Self.directives) } catch {
      throw IndexError(error.description)
    }
    for d in read {
      let line = d.line, directive = d.name, rest = d.arguments
      func fail(_ what: String) -> IndexError { IndexError("\(file):\(line): \(what)") }
      if same(directive, "driver") {
        guard rest.count == 1, !rest[0].isEmpty else { throw fail("'driver' takes a program's name") }
        drivers.append(DriverManifest(name: rest[0], origin: "\(file):\(line)"))
        continue
      }
      guard !drivers.isEmpty else { throw fail("'driver' must come first") }
      let i = drivers.count - 1
      if same(directive, "class") {
        guard rest.count == 1 else { throw fail("'class' takes a class") }
        drivers[i].deviceClass = rest[0]
      } else if same(directive, "fallback") {
        guard rest.isEmpty else { throw fail("'fallback' takes nothing") }
        drivers[i].fallback = true
      } else if same(directive, "dma-bits") {
        guard rest.count == 1, let bits = Self.number(Array(rest[0].utf8), radix: 10), bits >= 12, bits <= 64 else {
          throw fail("'dma-bits' takes 12 to 64")
        }
        drivers[i].addressBits = bits
      } else if same(directive, "sd") {
        guard rest.count == 1, rest[0].utf8.count == 1, let c = rest[0].utf8.first, c >= 0x41, c <= 0x5A else {
          throw fail("'sd' takes a capital letter")
        }
        drivers[i].sdLetter = rest[0]
      } else if same(directive, "match") {
        guard rest.count == 2 else { throw fail("'match' takes a kind and an id") }
        guard let rule = Self.rule(rest[0], rest[1]) else { throw fail("bad match '\(rest[0]) \(rest[1])'") }
        drivers[i].rules.append(rule)
      }
    }
    for d in drivers where d.rules.isEmpty { throw IndexError("\(d.origin): driver '\(d.name)' matches nothing") }
  }

  /// `digits` as a number in `radix` (10 or 16), if they are all digits.
  static func number(_ digits: [UInt8], radix: UInt32) -> UInt32? {
    guard !digits.isEmpty, digits.count <= 8 else { return nil }
    var v: UInt32 = 0
    for b in digits {
      let d: UInt32
      switch b {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(b - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f") where radix == 16: d = UInt32(b - UInt8(ascii: "a")) + 10
      case UInt8(ascii: "A")...UInt8(ascii: "F") where radix == 16: d = UInt32(b - UInt8(ascii: "A")) + 10
      default: return nil
      }
      v = v * radix + d
    }
    return v
  }

  static func rule(_ kind: String, _ id: String) -> MatchRule? {
    /// `id`'s parts between `separator`s, each `digits` hexadecimal digits.
    func hex(_ separator: UInt8, _ digits: [Int]) -> [UInt32]? {
      var parts: [[UInt8]] = [[]]
      for b in id.utf8 {
        if b == separator { parts.append([]) } else { parts[parts.count - 1].append(b) }
      }
      guard parts.count == digits.count else { return nil }
      var out: [UInt32] = []
      for (p, n) in zip(parts, digits) {
        guard p.count == n, let v = number(p, radix: 16) else { return nil }
        out.append(v)
      }
      return out
    }
    if same(kind, "pci") {
      guard let v = hex(UInt8(ascii: ":"), [4, 4]) else { return nil }
      return .pci(vendor: UInt16(v[0]), device: UInt16(v[1]))
    }
    if same(kind, "pci-class") {
      if let v = hex(UInt8(ascii: "."), [2, 2, 2]) { return .pciClass(UInt8(v[0]), UInt8(v[1]), progIF: UInt8(v[2])) }
      guard let v = hex(UInt8(ascii: "."), [2, 2]) else { return nil }
      return .pciClass(UInt8(v[0]), UInt8(v[1]), progIF: nil)
    }
    if same(kind, "acpi") { return id.isEmpty ? nil : .acpi(id) }
    if same(kind, "acpi-compatible") { return id.isEmpty ? nil : .acpiCompatible(id) }
    return nil
  }

  /// Rules two drivers share, as errors (td refuses such an index). A
  /// fallback driver may share one with a driver that isn't: that's what
  /// it falls back from.
  public var conflicts: [String] {
    var out: [String] = []
    for (i, a) in drivers.enumerated() {
      for b in drivers[(i + 1)...] where !same(a.name, b.name) && a.fallback == b.fallback {
        for r in a.rules where b.rules.contains(r) {
          out.append("\(a.origin) and \(b.origin): '\(a.name)' and '\(b.name)' both match \(r.description)")
        }
      }
    }
    return out
  }

  /// How well `rule` matches `device`, lower first; nil if it doesn't.
  static func level(_ rule: MatchRule, _ device: Device) -> Int? {
    switch (rule, device.bus) {
    case (.pci(let v, let d), .pci(let f)): return f.vendor == v && f.device == d ? 0 : nil
    case (.acpi(let id), .acpi(let a)): return a.hid.map { same($0, id) } == true ? 0 : nil
    case (.acpiCompatible(let id), .acpi(let a)):
      return a.cids.firstIndex { same($0, id) }.map { 100 + $0 }
    case (.pciClass(let c, let s, let p), .pci(let f)):
      guard f.classCode == c && f.subclass == s else { return nil }
      guard let p else { return 300 }
      return f.progIF == p ? 200 : nil
    default: return nil
    }
  }

  public func match(_ device: Device) -> Binding {
    var best: Int?
    var at: [Int] = []
    for (i, d) in drivers.enumerated() {
      guard let l = d.rules.compactMap({ Self.level($0, device) }).min() else { continue }
      let level = l + (d.fallback ? 1000 : 0)
      if best == nil || level < best! {
        best = level
        at = [i]
      } else if level == best! {
        at.append(i)
      }
    }
    switch at.count {
    case 0: return .none
    case 1: return .driver(at[0])
    default: return .ambiguous(at.map { drivers[$0].name })
    }
  }
}

/// Whether two strings have the same bytes (String's == needs Unicode
/// tables tier 0 doesn't link).
public func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

extension MatchRule {
  public static func == (a: MatchRule, b: MatchRule) -> Bool {
    switch (a, b) {
    case (.pci(let v1, let d1), .pci(let v2, let d2)): v1 == v2 && d1 == d2
    case (.pciClass(let c1, let s1, let p1), .pciClass(let c2, let s2, let p2)): c1 == c2 && s1 == s2 && p1 == p2
    case (.acpi(let x), .acpi(let y)), (.acpiCompatible(let x), .acpiCompatible(let y)): same(x, y)
    default: false
    }
  }
}
