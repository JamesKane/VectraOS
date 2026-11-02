// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's pin controller (k1-pinctrl(3)), as bin/k1-pinctrl
// drives it: a register for each of its 128 pins, which holds the pin's
// function (its mux, bits 0-2) and its pad's settings: pulls, drive
// strength, Schmitt trigger and slew rate. A pin state is a node under
// the controller's (`gmac1-cfg`), each group under it a `pinmux` list
// (`K1_PADCONF(pin, function)`, pin << 16 | function) and the settings
// its pins take, by the generic pin configuration binding's names. The
// driver reads them from its node's properties (devmgr's /dev/dt/node).
// A drive strength in mA is the register's code by the pin's voltage:
// most pins are 1.8 V, and those whose voltage comes from outside take
// the group's `power-source`, 1.8 or 3.3 V. Registers, bits and tables
// are the hardware's (chinese-wall's spacemit-k1 02).

/// The pad register's bits.
public enum Pad {
  public static let mux: UInt32 = 0x7
  public static let strongPull: UInt32 = 1 << 3
  public static let slewRateEnable: UInt32 = 1 << 7
  public static let schmittShift: UInt32 = 8
  public static let driveShift: UInt32 = 10
  public static let slewShift: UInt32 = 11
  public static let pullDown: UInt32 = 1 << 13
  public static let pullUp: UInt32 = 1 << 14
  public static let pullEnable: UInt32 = 1 << 15
  /// What a state sets: all but the edge detection bits (4-6).
  public static let settings: UInt32 = 0xFF8F
}

/// The K1's pins: where each one's register is, and its voltage.
public enum K1Pins {
  public static let count = 128
  /// The controller's registers' extent, its node's `reg`.
  public static let size = 0x1000

  /// Pin `pin`'s register's offset (the MFPR numbering); nil past the
  /// last pin.
  public static func offset(_ pin: Int) -> Int? {
    let n: Int
    switch pin {
    case 0...85: n = pin + 1
    case 86...92: n = pin + 37
    case 93...97: n = pin + 24
    case 98: n = 93
    case 99: n = 92
    case 100: n = 91
    case 101: n = 90
    case 102: n = 95
    case 103: n = 94
    case 104...110: n = pin + 6
    case 111...127: n = pin + 20
    default: return nil
    }
    return n << 2
  }

  /// Whether the pin's voltage comes from outside (an SD card's, a
  /// QSPI's), and so from its group's `power-source`; else it is 1.8 V.
  public static func external(_ pin: Int) -> Bool {
    (47...52).contains(pin) || (75...80).contains(pin) || (98...109).contains(pin)
  }
}

/// A group's settings, as its node's properties give them.
public struct PinConfig: Equatable, Sendable {
  public enum Bias: Equatable, Sendable { case none, disable, down, up(strong: Bool) }
  public var bias = Bias.none
  /// `drive-strength`, in mA.
  public var drive: UInt32?
  public var schmitt: UInt32?
  /// `power-source`, in mV.
  public var power: UInt32?
  public var slew: UInt32?

  public init(bias: Bias = .none, drive: UInt32? = nil, schmitt: UInt32? = nil, power: UInt32? = nil,
              slew: UInt32? = nil) {
    self.bias = bias
    self.drive = drive
    self.schmitt = schmitt
    self.power = power
    self.slew = slew
  }

  /// The settings' bits for pin `pin` (spacemit-k1 02 §2.2); nil if it
  /// needs a voltage the group doesn't give.
  public func bits(_ pin: Int) -> UInt32? {
    var v: UInt32 = 0
    switch bias {
    case .none, .disable: break
    case .down: v |= Pad.pullEnable | Pad.pullDown
    case .up(let strong): v |= Pad.pullEnable | Pad.pullUp | (strong ? Pad.strongPull : 0)
    }
    if let schmitt { v |= (schmitt & 0x3) << Pad.schmittShift }
    if let drive {
      let volts3 = K1Pins.external(pin) ? power == 3300 : false
      if K1Pins.external(pin), power != 1800, power != 3300 { return nil }
      // Each code and the high-level current it drives, in mA.
      let table: [(code: UInt32, mA: UInt32)] = volts3
        ? [(0, 7), (2, 10), (4, 13), (6, 16), (1, 19), (3, 23), (5, 26), (7, 29)]
        : [(0, 11), (2, 21), (4, 32), (6, 42)]
      let code = table.first { drive <= $0.mA }?.code ?? table[table.count - 1].code
      v |= code << Pad.driveShift
    }
    if let slew, slew != 0 {
      v |= Pad.slewRateEnable
      if drive == nil { v |= ((slew > 1 ? slew - 2 : 0) & 0x3) << Pad.slewShift }
    }
    return v
  }
}

/// A group of a state: its pins, each with its function, and their
/// settings.
public struct PinGroup: Equatable, Sendable {
  public var name: String
  public var pins: [(pin: Int, function: UInt32)]
  public var config: PinConfig

  public init(name: String, pins: [(pin: Int, function: UInt32)], config: PinConfig) {
    self.name = name
    self.pins = pins
    self.config = config
  }

  public static func == (a: PinGroup, b: PinGroup) -> Bool {
    a.name.utf8.elementsEqual(b.name.utf8) && a.config == b.config && a.pins.count == b.pins.count
      && zip(a.pins, b.pins).allSatisfy { $0.pin == $1.pin && $0.function == $1.function }
  }
}

/// A pin state, its node's name and its groups.
public struct PinState: Equatable, Sendable {
  public var name: String
  public var groups: [PinGroup]

  public init(name: String, groups: [PinGroup]) {
    self.name = name
    self.groups = groups
  }

  /// The states under the controller's node, from its properties' text (a
  /// line each, `STATE/GROUP/PROPERTY VALUE`), in the order they come.
  public static func states(node text: String) -> [PinState] {
    var out: [PinState] = []
    for line in text.utf8.split(separator: 0x0A) {
      let space = line.firstIndex(of: 0x20) ?? line.endIndex
      let path = line[..<space].split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
      guard path.count == 3 else { continue }
      let state = String(decoding: path[0], as: UTF8.self), group = String(decoding: path[1], as: UTF8.self)
      let property = Array(path[2]), value = Array(line[space...].dropFirst())
      let s = out.firstIndex { $0.name.utf8.elementsEqual(state.utf8) } ?? {
        out.append(PinState(name: state, groups: []))
        return out.count - 1
      }()
      let g = out[s].groups.firstIndex { $0.name.utf8.elementsEqual(group.utf8) } ?? {
        out[s].groups.append(PinGroup(name: group, pins: [], config: PinConfig()))
        return out[s].groups.count - 1
      }()
      let cells = Self.cells(value)
      func named(_ n: String) -> Bool { property.elementsEqual(n.utf8) }
      if named("pinmux") {
        out[s].groups[g].pins = cells.map { (Int($0 >> 16), $0 & 0xFFFF) }
      } else if named("bias-disable") {
        out[s].groups[g].config.bias = .disable
      } else if named("bias-pull-down") {
        out[s].groups[g].config.bias = .down
      } else if named("bias-pull-up") {
        // Without a value, the binding's default, 1: a strong pull.
        out[s].groups[g].config.bias = .up(strong: (cells.first ?? 1) == 1)
      } else if named("drive-strength") {
        out[s].groups[g].config.drive = cells.first
      } else if named("input-schmitt") {
        out[s].groups[g].config.schmitt = cells.first
      } else if named("power-source") {
        out[s].groups[g].config.power = cells.first
      } else if named("slew-rate") {
        out[s].groups[g].config.slew = cells.first
      }
    }
    return out
  }

  /// `<0x1 0x2>`'s cells.
  static func cells(_ v: [UInt8]) -> [UInt32] {
    guard v.first == UInt8(ascii: "<"), v.last == UInt8(ascii: ">") else { return [] }
    return v.dropFirst().dropLast().split(separator: 0x20).compactMap { w in
      guard w.count > 2, w.starts(with: "0x".utf8) else { return nil }
      return UInt32(String(decoding: w.dropFirst(2), as: UTF8.self), radix: 16)
    }
  }

  /// The register writes that set it, each pin's whole register (its
  /// function and its group's settings), in its groups' order.
  public func writes() throws(PinError) -> [(offset: Int, value: UInt32)] {
    var out: [(offset: Int, value: UInt32)] = []
    for g in groups {
      for p in g.pins {
        guard let offset = K1Pins.offset(p.pin) else { throw .noSuchPin(p.pin) }
        guard let bits = g.config.bits(p.pin) else { throw .noVoltage(g.name) }
        out.append((offset, p.function & Pad.mux | bits))
      }
    }
    return out
  }
}

/// The I/O power domain of the SD card's pads (pins 104 to 109, MMC1's):
/// a register of the AIB's, in the controller's registers, whose bit 2
/// is 1.8 V and clear 3.3 V (spacemit-k1 02 §2.3-2.4). It is
/// protected: each access needs the APBC's keys written first
/// (k1-syscon's `unlock`).
public enum SDPads {
  public static let domain = 0x81C
  public static let v18: UInt32 = 1 << 2
  public static let pins = 104...109
}

extension PinState {
  /// Whether it puts the SD card's pads at 1.8 V: the `power-source` of
  /// its first group with one of their pins; nil where none says.
  public var sdPadsAt18: Bool? {
    for g in groups where g.pins.contains(where: { SDPads.pins.contains($0.pin) }) {
      if let p = g.config.power { return p == 1800 }
    }
    return nil
  }
}

/// Why a state can't be set.
public enum PinError: Error, Equatable, Sendable {
  case noSuchState
  case noSuchPin(Int)
  /// A group's drive strength on pins whose voltage it doesn't give.
  case noVoltage(String)
  /// The APBC refused its keys, or has no driver.
  case locked
  /// The power domain's bit read back otherwise after its write.
  case untaken

  public var description: String {
    switch self {
    case .noSuchState: "no such state"
    case .noSuchPin(let p): "no pin \(p)"
    case .noVoltage(let g): "\(g): no power-source for its drive strength"
    case .locked: "the APBC didn't unlock the pads' power domain"
    case .untaken: "the pads' power domain read back otherwise"
    }
  }
}

/// A line written to bin/k1-pinctrl's ctl, `state NAME`: the state's name.
public func stateCommand(_ line: String) -> String? {
  let words = line.utf8.split(separator: 0x20)
  guard words.count == 2, words[0].elementsEqual("state".utf8) else { return nil }
  return String(decoding: words[1], as: UTF8.self)
}
