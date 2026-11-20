// SPDX-License-Identifier: BSD-3-Clause

// The CIX Sky1's Cadence GPIO controller (cdns-gpio(3)), as bin/cdns-gpio
// drives it: up to 32 lines a controller, each register a word with a bit
// a line. A line is an input or an output (DIRECTION_MODE, OUTPUT_EN,
// OUTPUT_VALUE), passed through to another function while its BYPASS_MODE
// bit is set, and an interrupt source by a trigger of three registers
// (IRQ_TYPE, IRQ_VALUE, IRQ_ANY_EDGE) and its bit in the mask, set and
// cleared through IRQ_EN and IRQ_DIS. A consumer's specifier is the line
// and flags (bit 0 active low), and its command names them: `gpio PIN
// FLAGS on|off|input|watch [TRIGGER]`. Registers and offsets are the
// hardware's (chinese-wall's sky1-peripherals 01 §1.2).

/// A controller's registers.
public enum CdnsRegister {
  public static let bypass = 0x00
  public static let direction = 0x04
  public static let outputEnable = 0x08
  public static let outputValue = 0x0C
  public static let inputValue = 0x10
  /// A bit set: the line's interrupt is masked.
  public static let mask = 0x14
  /// Writing a bit unmasks its line (a set port: no read-modify-write).
  public static let enable = 0x18
  /// Writing a bit masks its line.
  public static let disable = 0x1C
  /// A bit set: an interrupt pending on the line, cleared by writing it.
  public static let status = 0x20
  public static let type = 0x24
  public static let value = 0x28
  public static let anyEdge = 0x2C
}

public enum CdnsGpios {
  /// The registers' extent.
  public static let size = 0x30

  /// How many lines the controller at physical address `base` has: the
  /// FCH's fourth has 17, the S5's second and third 10, the others 32.
  public static func lines(base: UInt64) -> Int {
    switch base {
    case 0x0415_0000: return 17
    case 0x1600_5000, 0x1600_6000: return 10
    default: return 32
    }
  }

  /// The `ngpios` a device's `_DSD` gives (`/dev/acpi/properties`, a
  /// `name value` line each): one to 32; nil if it has none or another.
  public static func ngpios(properties: String) -> Int? {
    for line in properties.utf8.split(separator: 0x0A) {
      let w = line.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
      if w.count == 2, w[0].utf8.elementsEqual("ngpios".utf8), let n = Int(w[1]) { return (1...32).contains(n) ? n : nil }
    }
    return nil
  }

  /// A controller's line count: its `ngpios`, else its address's.
  public static func count(properties: String, base: UInt64) -> (lines: Int, byAddress: Bool) {
    if let n = ngpios(properties: properties) { return (n, false) }
    return (lines(base: base), true)
  }

  /// A bit for each of `lines`.
  public static func all(_ lines: Int) -> UInt32 { lines >= 32 ? 0xFFFF_FFFF : (UInt32(1) << UInt32(lines)) - 1 }
}

public enum GpioError: Error, Equatable {
  case noSuchPin
  /// A watch with no interrupt to serve it.
  case noInterrupt

  public var description: String { self == .noSuchPin ? "no such pin" : "no interrupt to watch it by" }
}

/// What a watched line raises its interrupt on.
public enum Trigger: Equatable, Sendable {
  case rising, falling, both, high, low

  public init?(_ word: String) {
    let w = word.utf8
    if w.elementsEqual("rising".utf8) {
      self = .rising
    } else if w.elementsEqual("falling".utf8) {
      self = .falling
    } else if w.elementsEqual("both".utf8) {
      self = .both
    } else if w.elementsEqual("high".utf8) {
      self = .high
    } else if w.elementsEqual("low".utf8) {
      self = .low
    } else {
      return nil
    }
  }

  public var name: String {
    switch self {
    case .rising: return "rising"
    case .falling: return "falling"
    case .both: return "both"
    case .high: return "high"
    case .low: return "low"
    }
  }

  public var isLevel: Bool { self == .high || self == .low }

  /// Each trigger register's bit for it (spec §1.2.1): level or edge,
  /// high or rising, both edges. All three are always programmed: an
  /// any-edge bit left from before would override a single edge.
  public var bits: (type: Bool, value: Bool, anyEdge: Bool) {
    switch self {
    case .high: return (true, true, false)
    case .low: return (true, false, false)
    case .rising: return (false, true, false)
    case .falling: return (false, false, false)
    case .both: return (false, false, true)
    }
  }
}

/// The registers a command changes a bit of, as they read now.
public struct LineRegisters: Equatable, Sendable {
  public var bypass: UInt32, direction: UInt32, outputEnable: UInt32, outputValue: UInt32
  public var type: UInt32, value: UInt32, anyEdge: UInt32

  public init(bypass: UInt32 = 0, direction: UInt32 = 0, outputEnable: UInt32 = 0, outputValue: UInt32 = 0,
              type: UInt32 = 0, value: UInt32 = 0, anyEdge: UInt32 = 0) {
    self.bypass = bypass
    self.direction = direction
    self.outputEnable = outputEnable
    self.outputValue = outputValue
    self.type = type
    self.value = value
    self.anyEdge = anyEdge
  }
}

public typealias RegisterWrite = (offset: Int, value: UInt32)

/// A command a line of `ctl`: `gpio PIN FLAGS on|off|input|watch [TRIGGER]`.
public struct GpioCommand: Equatable, Sendable {
  public enum Action: Equatable, Sendable { case on, off, input, watch }

  public var pin: Int
  public var activeLow: Bool
  public var action: Action
  /// A watch's trigger: both edges unless it names one.
  public var trigger: Trigger

  public init(pin: Int, activeLow: Bool = false, action: Action, trigger: Trigger = .both) {
    self.pin = pin
    self.activeLow = activeLow
    self.action = action
    self.trigger = trigger
  }

  public init?(_ line: String) {
    let w = line.utf8.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
    guard w.count == 4 || w.count == 5, w[0].utf8.elementsEqual("gpio".utf8), let p = number(w[1]), let f = number(w[2])
    else { return nil }
    let a = w[3].utf8
    if a.elementsEqual("on".utf8) {
      action = .on
    } else if a.elementsEqual("off".utf8) {
      action = .off
    } else if a.elementsEqual("input".utf8) {
      action = .input
    } else if a.elementsEqual("watch".utf8) {
      action = .watch
    } else {
      return nil
    }
    // A trigger only a watch takes.
    if w.count == 5 {
      guard action == .watch, let t = Trigger(w[4]) else { return nil }
      trigger = t
    } else {
      trigger = .both
    }
    pin = Int(p)
    activeLow = f & 1 != 0
  }

  public var description: String {
    let a = action == .on ? "on" : action == .off ? "off" : action == .input ? "input" : "watch"
    return "gpio \(pin) \(activeLow ? 1 : 0) \(a)" + (action == .watch && trigger != .both ? " " + trigger.name : "")
  }

  /// The writes it makes to a controller of `lines` lines whose registers
  /// read `now`, each a register's offset and the value written. Only its
  /// own line's bits change. An output's level is set before it is driven
  /// and its direction last, so it never drives the other level; a
  /// watch's line is masked while its trigger changes, an old interrupt
  /// cleared, and unmasked last.
  public func writes(lines: Int, now r: LineRegisters) throws(GpioError) -> [RegisterWrite] {
    guard (0..<lines).contains(pin) else { throw .noSuchPin }
    let bit = UInt32(1) << UInt32(pin)
    func with(_ v: UInt32, _ on: Bool) -> UInt32 { on ? v | bit : v & ~bit }
    switch action {
    case .input:
      return [(CdnsRegister.bypass, with(r.bypass, false)), (CdnsRegister.direction, with(r.direction, true))]
    case .on, .off:
      let high = (action == .on) != activeLow
      return [
        (CdnsRegister.outputValue, with(r.outputValue, high)), (CdnsRegister.outputEnable, with(r.outputEnable, true)),
        (CdnsRegister.bypass, with(r.bypass, false)), (CdnsRegister.direction, with(r.direction, false)),
      ]
    case .watch:
      let t = trigger.bits
      return [
        (CdnsRegister.disable, bit), (CdnsRegister.bypass, with(r.bypass, false)),
        (CdnsRegister.direction, with(r.direction, true)),
        (CdnsRegister.type, with(r.type, t.type)), (CdnsRegister.value, with(r.value, t.value)),
        (CdnsRegister.anyEdge, with(r.anyEdge, t.anyEdge)),
        (CdnsRegister.status, bit), (CdnsRegister.enable, bit),
      ]
    }
  }
}

/// The lines watched for interrupts (`watch`), and what each has seen.
public struct Watches: Sendable {
  public struct Line: Equatable, Sendable {
    public var pin: Int
    public var activeLow: Bool
    public var trigger: Trigger
    /// Interrupts that found its trigger on it: two edges close together
    /// may be one.
    public var edges: Int
    /// A level line is masked once it has fired (nothing here services
    /// its source), until it is watched again.
    public var masked: Bool

    public init(pin: Int, activeLow: Bool, trigger: Trigger, edges: Int = 0, masked: Bool = false) {
      self.pin = pin
      self.activeLow = activeLow
      self.trigger = trigger
      self.edges = edges
      self.masked = masked
    }
  }

  public private(set) var lines: [Line] = []

  public init() {}

  /// At start: every line masked, its pending interrupt cleared (the
  /// status is written back as read, `pending`), before the controller's
  /// interrupt is unmasked at the interrupt controller.
  public static func reset(lines: Int, pending: UInt32) -> [RegisterWrite] {
    [(CdnsRegister.disable, CdnsGpios.all(lines)), (CdnsRegister.status, pending)]
  }

  /// Records the watch `c` makes (again, with its flags and trigger).
  public mutating func watch(_ c: GpioCommand) {
    if let i = lines.firstIndex(where: { $0.pin == c.pin }) {
      lines[i].activeLow = c.activeLow
      lines[i].trigger = c.trigger
      lines[i].masked = false
    } else {
      lines.append(Line(pin: c.pin, activeLow: c.activeLow, trigger: c.trigger))
    }
  }

  /// The interrupt, the status and mask registers read once (`status`
  /// may clear as it is read): the writes that mask a level line that
  /// fired, then clear every interrupt found, and whether a watched
  /// line's count went up. A masked line's bit is no interrupt.
  public mutating func take(status: UInt32, mask: UInt32) -> (writes: [RegisterWrite], changed: Bool) {
    let pending = status & ~mask
    guard pending != 0 else { return ([], false) }
    var level: UInt32 = 0
    var changed = false
    for i in lines.indices where pending & (UInt32(1) << UInt32(lines[i].pin)) != 0 {
      lines[i].edges += 1
      changed = true
      if lines[i].trigger.isLevel {
        lines[i].masked = true
        level |= UInt32(1) << UInt32(lines[i].pin)
      }
    }
    var writes: [RegisterWrite] = []
    if level != 0 { writes.append((CdnsRegister.disable, level)) }
    writes.append((CdnsRegister.status, pending))
    return (writes, changed)
  }

  /// `events`: a line for each watched line, `gpio PIN FLAGS
  /// active|inactive edges N`, its level from `level` (INPUT_VALUE); or
  /// `none` with nothing watched.
  public func text(level: UInt32) -> String {
    guard !lines.isEmpty else { return "none\n" }
    return lines.map { l in
      let high = level & (UInt32(1) << UInt32(l.pin)) != 0
      return "gpio \(l.pin) \(l.activeLow ? 1 : 0) \(high != l.activeLow ? "active" : "inactive") edges \(l.edges)\n"
    }.joined()
  }
}

/// A line of `status` for a line a client has named, from the registers
/// as they read now.
public func pinStatus(pin: Int, direction: UInt32, level: UInt32, bypass: UInt32, mask: UInt32, watch: Watches.Line?) -> String {
  let bit = UInt32(1) << UInt32(pin)
  var s = "pin \(pin) " + (direction & bit != 0 ? "input" : "output") + " level \(level & bit != 0 ? 1 : 0)"
  if bypass & bit != 0 { s += " bypassed" }
  if let w = watch {
    s += " watched \(w.trigger.name) edges \(w.edges)" + (mask & bit != 0 ? " masked" : "")
  }
  return s
}

/// A decimal or `0x` hexadecimal number.
func number(_ s: String) -> UInt32? {
  s.utf8.starts(with: "0x".utf8) ? UInt32(String(decoding: s.utf8.dropFirst(2), as: UTF8.self), radix: 16) : UInt32(s)
}
