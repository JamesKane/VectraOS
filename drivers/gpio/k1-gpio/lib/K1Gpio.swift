// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's GPIO controller (k1-gpio(3)), as bin/k1-gpio drives
// it: 128 GPIOs in four banks of 32, each bank's registers at its own
// offset, a pin's level read from GPLR, driven through the set and clear
// registers (GPSR, GPCR), turned to an output or input through GSDR and
// GCDR, and watched for edges through its edge enables, status and mask
// (GRER, GFER, GEDR, GAPMASK). A consumer's `gpios` specifier is three
// cells, the bank, the pin in it and flags (bit 0 active low), and its
// command names them: `gpio BANK PIN FLAGS on|off|input|watch`, `on` the
// pin's active level. Registers and offsets are the hardware's
// (chinese-wall's spacemit-k1 02 §2.5).

/// A bank's registers, from the bank's offset.
public enum GpioRegister {
  public static let level = 0x00
  public static let direction = 0x0C
  public static let set = 0x18
  public static let clear = 0x24
  public static let setDirection = 0x54
  public static let clearDirection = 0x60
  public static let risingEdge = 0x30
  public static let fallingEdge = 0x3C
  /// The edges seen, a bit a line, each cleared by writing it back.
  public static let edges = 0x48
  public static let setRising = 0x6C
  public static let setFalling = 0x84
  /// The lines whose edges raise the block's one interrupt.
  public static let mask = 0x9C
}

public enum K1Gpios {
  public static let banks = 4
  public static let count = 128
  /// The registers' extent: the last bank is 0x100 in, past the node's
  /// `reg`, within the page devmgr grants.
  public static let size = 0x200

  public static func bank(_ n: Int) -> Int { [0x0, 0x4, 0x8, 0x100][n] }
}

public enum GpioError: Error, Equatable {
  case noSuchPin
  /// A watch with no interrupt to serve it.
  case noInterrupt

  public var description: String { self == .noSuchPin ? "no such pin" : "no interrupt to watch it by" }
}

/// A command a line of `ctl`: `gpio BANK PIN FLAGS on|off|input`.
public struct GpioCommand: Equatable, Sendable {
  public enum Action: Equatable, Sendable { case on, off, input, watch }

  public var bank: Int
  public var pin: Int
  public var activeLow: Bool
  public var action: Action

  public init(bank: Int, pin: Int, activeLow: Bool = false, action: Action) {
    self.bank = bank
    self.pin = pin
    self.activeLow = activeLow
    self.action = action
  }

  public init?(_ line: String) {
    let w = line.utf8.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
    guard w.count == 5, w[0].utf8.elementsEqual("gpio".utf8), let b = number(w[1]), let p = number(w[2]),
      let f = number(w[3])
    else { return nil }
    let a = w[4].utf8
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
    bank = Int(b)
    pin = Int(p)
    activeLow = f & 1 != 0
  }

  public var description: String {
    "gpio \(bank) \(pin) \(activeLow ? 1 : 0) "
      + (action == .on ? "on" : action == .off ? "off" : action == .input ? "input" : "watch")
  }

  /// The writes it makes, each a register's offset and the value written:
  /// for an output, its level first, then its direction, so it never
  /// drives the other level.
  public func writes() throws(GpioError) -> [(offset: Int, value: UInt32)] {
    guard (0..<K1Gpios.banks).contains(bank), (0..<32).contains(pin) else { throw .noSuchPin }
    let base = K1Gpios.bank(bank), bit = UInt32(1) << UInt32(pin)
    switch action {
    case .input:
      return [(base + GpioRegister.clearDirection, bit)]
    case .on, .off:
      let high = (action == .on) != activeLow
      return [(base + (high ? GpioRegister.set : GpioRegister.clear), bit), (base + GpioRegister.setDirection, bit)]
    case .watch:
      // Both edges caught, an edge from before forgotten; the mask is
      // the watches' (Watches.watch).
      return [(base + GpioRegister.setRising, bit), (base + GpioRegister.setFalling, bit), (base + GpioRegister.edges, bit)]
    }
  }
}

/// The lines watched for edges (`watch`), and what each has seen. A
/// line's edge is latched in its bank's edge status once its rising and
/// falling enables are set, and raises the block's one interrupt only
/// where its bit in the bank's mask is (spec 02 §2.5.3); the mask is kept
/// here, a copy written whole, as it can't be set a bit at a time. The
/// edge enables stay on, so an edge isn't lost while the interrupt is
/// being served.
public struct Watches: Sendable {
  public struct Line: Equatable, Sendable {
    public var bank: Int
    public var pin: Int
    public var activeLow: Bool
    /// Interrupts that found an edge on it: two edges close together may
    /// be one.
    public var edges: Int

    public init(bank: Int, pin: Int, activeLow: Bool, edges: Int = 0) {
      self.bank = bank
      self.pin = pin
      self.activeLow = activeLow
      self.edges = edges
    }
  }

  public private(set) var lines: [Line] = []
  public private(set) var masks: [UInt32] = Array(repeating: 0, count: K1Gpios.banks)

  public init() {}

  /// At start, in each bank: no line's edges let through or enabled, and
  /// none pending (their reset values aren't known).
  public static var reset: [(offset: Int, value: UInt32)] {
    var w: [(offset: Int, value: UInt32)] = []
    for b in 0..<K1Gpios.banks {
      let base = K1Gpios.bank(b)
      w += [(base + GpioRegister.mask, 0), (base + GpioRegister.risingEdge, 0), (base + GpioRegister.fallingEdge, 0),
            (base + GpioRegister.edges, 0xFFFF_FFFF)]
    }
    return w
  }

  /// Watches `c`'s line (again, with its flags): the writes that do it,
  /// its edges enabled before its mask bit is set.
  public mutating func watch(_ c: GpioCommand) throws(GpioError) -> [(offset: Int, value: UInt32)] {
    let enable = try c.writes()
    if let i = lines.firstIndex(where: { $0.bank == c.bank && $0.pin == c.pin }) {
      lines[i].activeLow = c.activeLow
    } else {
      lines.append(Line(bank: c.bank, pin: c.pin, activeLow: c.activeLow))
    }
    masks[c.bank] |= UInt32(1) << UInt32(c.pin)
    return enable + [(K1Gpios.bank(c.bank) + GpioRegister.mask, masks[c.bank])]
  }

  /// The interrupt, each bank's edge status read (`seen`): the writes
  /// that clear every edge seen, a watched line's or not, and whether a
  /// watched line's count went up.
  public mutating func take(_ seen: [UInt32]) -> (writes: [(offset: Int, value: UInt32)], changed: Bool) {
    var writes: [(offset: Int, value: UInt32)] = []
    for b in 0..<min(seen.count, K1Gpios.banks) where seen[b] != 0 {
      writes.append((K1Gpios.bank(b) + GpioRegister.edges, seen[b]))
    }
    var changed = false
    for i in lines.indices where lines[i].bank < seen.count && seen[lines[i].bank] & (UInt32(1) << UInt32(lines[i].pin)) != 0 {
      lines[i].edges += 1
      changed = true
    }
    return (writes, changed)
  }

  /// `events`: a line for each watched line, `gpio BANK PIN FLAGS
  /// active|inactive edges N`, its level from its bank's (`levels`); or
  /// `none` with nothing watched.
  public func text(levels: [UInt32]) -> String {
    guard !lines.isEmpty else { return "none\n" }
    return lines.map { l in
      let high = l.bank < levels.count && levels[l.bank] & (UInt32(1) << UInt32(l.pin)) != 0
      return "gpio \(l.bank) \(l.pin) \(l.activeLow ? 1 : 0) \(high != l.activeLow ? "active" : "inactive") edges \(l.edges)\n"
    }.joined()
  }
}

/// A decimal or `0x` hexadecimal number.
func number(_ s: String) -> UInt32? {
  s.utf8.starts(with: "0x".utf8) ? UInt32(String(decoding: s.utf8.dropFirst(2), as: UTF8.self), radix: 16) : UInt32(s)
}
