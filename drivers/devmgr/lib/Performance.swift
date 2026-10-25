// SPDX-License-Identifier: BSD-3-Clause

// What the power service (power(8), D130) needs of ACPI's namespace, which
// only devmgr holds: each processor's performance controls, its _CPC
// (ACPI 6.5 §8.4.6.1, CPPC) and its _PSD domain (§8.4.5.5), and each
// thermal zone's temperature and trip points (§11), as devmgr's `cpus`
// and `thermal` files give them, a line each.

import TDACPI

/// A register a _CPC entry names (a Generic Register Descriptor, §6.4.3.7).
public struct CPCRegister: Equatable, Sendable {
  /// 0 SystemMemory, 1 SystemIO, 0x0A PCC, 0x7F FFixedHW.
  public var space: UInt8
  public var bitWidth: UInt8
  public var bitOffset: UInt8
  public var address: UInt64

  public init(space: UInt8, bitWidth: UInt8, bitOffset: UInt8, address: UInt64) {
    self.space = space
    self.bitWidth = bitWidth
    self.bitOffset = bitOffset
    self.address = address
  }
}

/// A processor's CPPC, as far as setting its performance goes.
public struct CPC: Equatable, Sendable {
  public var highest: UInt32
  public var nominal: UInt32
  public var lowestNonlinear: UInt32
  public var lowest: UInt32
  /// Where a level is asked for; nil if _CPC gives none.
  public var desired: CPCRegister?
  /// The frequencies, in MHz, lowest and nominal performance run at (0 if
  /// not given), so levels can be named as clocks.
  public var lowestMHz: UInt32
  public var nominalMHz: UInt32

  public init(highest: UInt32, nominal: UInt32, lowestNonlinear: UInt32, lowest: UInt32, desired: CPCRegister?,
              lowestMHz: UInt32, nominalMHz: UInt32) {
    self.highest = highest
    self.nominal = nominal
    self.lowestNonlinear = lowestNonlinear
    self.lowest = lowest
    self.desired = desired
    self.lowestMHz = lowestMHz
    self.nominalMHz = nominalMHz
  }

  /// _CPC's package (revision 2 or 3): its performance levels when they
  /// are integers (a level kept in a register isn't read here), and the
  /// desired-performance register when one is given (not a null
  /// SystemMemory register at 0).
  public static func decode(_ cpc: Datum) -> CPC? {
    guard case .package(let p) = cpc, p.elements.count >= 21 else { return nil }
    let e = p.elements
    func integer(_ i: Int) -> UInt32? {
      guard i < e.count, case .integer(let v) = e[i] else { return nil }
      return UInt32(truncatingIfNeeded: v)
    }
    func register(_ i: Int) -> CPCRegister? {
      guard i < e.count, case .buffer(let b) = e[i], let resources = try? Resources.decode(b.bytes) else { return nil }
      for r in resources {
        guard case .genericRegister(let space, let width, let offset, _, let address) = r else { continue }
        if space == 0 && address == 0 { return nil }  // the null register
        return CPCRegister(space: space, bitWidth: width, bitOffset: offset, address: address)
      }
      return nil
    }
    guard let highest = integer(2), let nominal = integer(3), let nonlinear = integer(4), let lowest = integer(5),
      lowest <= highest
    else { return nil }
    return CPC(highest: highest, nominal: nominal, lowestNonlinear: nonlinear, lowest: lowest, desired: register(7),
               lowestMHz: integer(21) ?? 0, nominalMHz: integer(22) ?? 0)
  }

  /// `cpus`' line for processor `uid` at `path`, in its domain.
  public func line(uid: UInt64, path: String, domain: PSD?) -> String {
    var s = "\(uid) \(path) perf \(lowest) \(lowestNonlinear) \(nominal) \(highest) mhz \(lowestMHz) \(nominalMHz)"
    if let d = desired {
      s += " desired \(d.space) 0x\(String(d.address, radix: 16)) \(d.bitWidth) \(d.bitOffset)"
    } else {
      s += " desired none"
    }
    if let domain { s += " domain \(domain.domain) \(domain.coordination) \(domain.processors)" }
    return s
  }
}

/// A _PSD's dependency: the domain, how its processors are coordinated
/// (0xFC SW_ALL, 0xFD SW_ANY, 0xFE HW_ALL), and how many it has.
public struct PSD: Equatable, Sendable {
  public var domain: UInt32
  public var coordination: UInt32
  public var processors: UInt32

  public init(domain: UInt32, coordination: UInt32, processors: UInt32) {
    self.domain = domain
    self.coordination = coordination
    self.processors = processors
  }

  public static func decode(_ psd: Datum) -> PSD? {
    guard case .package(let outer) = psd, let first = outer.elements.first, case .package(let p) = first,
      p.elements.count >= 5, case .integer(let domain) = p.elements[2], case .integer(let coordination) = p.elements[3],
      case .integer(let processors) = p.elements[4]
    else { return nil }
    return PSD(domain: UInt32(truncatingIfNeeded: domain), coordination: UInt32(truncatingIfNeeded: coordination),
               processors: UInt32(truncatingIfNeeded: processors))
  }
}

/// A thermal zone as read: its temperature and trip points in tenths of a
/// kelvin (nil where it has none, or _TMP failed), and how often it asks
/// to be polled, in tenths of a second (_TZP; 0 if it doesn't).
public struct ZoneReading: Equatable, Sendable {
  public var path: String
  public var temperature: UInt32?
  public var passive: UInt32?
  public var critical: UInt32?
  public var polling: UInt32

  public init(path: String, temperature: UInt32?, passive: UInt32?, critical: UInt32?, polling: UInt32) {
    self.path = path
    self.temperature = temperature
    self.passive = passive
    self.critical = critical
    self.polling = polling
  }

  /// `thermal`'s line: `<path> <dK|-> passive <dK|-> critical <dK|-> polling <ds>`.
  public var line: String {
    func v(_ x: UInt32?) -> String { x.map { "\($0)" } ?? "-" }
    return "\(path) \(v(temperature)) passive \(v(passive)) critical \(v(critical)) polling \(polling)"
  }

  /// A temperature method's result: tenths of a kelvin, or nil for one no
  /// zone could have (Ones, or 0: _TMP's failures).
  public static func kelvin(_ d: Datum?) -> UInt32? {
    guard case .integer(let v)? = d, v > 0, v < 0xFFFF_FFFF else { return nil }
    return UInt32(v)
  }
}

extension Namespace {
  /// Each processor device (ACPI0007, or a Processor object) with its node.
  public mutating func processorNodes<H: ACPIHost>(host: H) -> [Int] {
    deviceNodes().filter { n in
      if case .processor = nodes[n].object { return true }
      guard case .device = nodes[n].object, let id = try? hardwareID(n, host: host) else { return false }
      return id.elementsEqual("ACPI0007".utf8)
    }
  }

  /// Each thermal zone's node.
  public func thermalZoneNodes() -> [Int] {
    deviceNodes().filter { if case .thermalZone = nodes[$0].object { true } else { false } }
  }

  /// `cpus`: a line for each processor with a _CPC, `<uid> <path> no _CPC`
  /// for one without.
  public mutating func performanceText<H: ACPIHost>(host: H) -> String {
    var out = ""
    for n in processorNodes(host: host) {
      let path = String(decoding: self.path(n), as: UTF8.self)
      var uid: UInt64 = 0
      if case .integer(let u)? = try? childValue(n, "_UID", host: host) { uid = u }
      guard let datum = try? childValue(n, "_CPC", host: host), let cpc = CPC.decode(datum) else {
        out += "\(uid) \(path) no _CPC\n"
        continue
      }
      let psd = (try? childValue(n, "_PSD", host: host)).flatMap { PSD.decode($0) }
      out += cpc.line(uid: uid, path: path, domain: psd) + "\n"
    }
    return out
  }

  /// `thermal`: a line for each zone, its _TMP evaluated now.
  public mutating func thermalText<H: ACPIHost>(host: H) -> String {
    var out = ""
    for n in thermalZoneNodes() {
      var polling: UInt32 = 0
      if case .integer(let p)? = try? childValue(n, "_TZP", host: host) { polling = UInt32(truncatingIfNeeded: p) }
      let zone = ZoneReading(path: String(decoding: path(n), as: UTF8.self),
                             temperature: ZoneReading.kelvin(try? childValue(n, "_TMP", host: host)),
                             passive: ZoneReading.kelvin(try? childValue(n, "_PSV", host: host)),
                             critical: ZoneReading.kelvin(try? childValue(n, "_CRT", host: host)), polling: polling)
      out += zone.line + "\n"
    }
    return out
  }
}
