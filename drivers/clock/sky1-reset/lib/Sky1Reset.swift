// SPDX-License-Identifier: BSD-3-Clause

// The CIX Sky1's two reset controllers as bin/sky1-reset drives them
// (sky1-reset(3)): RST0 (CIXHA020), the S5 system controller at
// 0x16000000, and RST1 (CIXHA021), the FCH one at 0x04160000. Both are
// plain register banks in which every reset line is one bit, active low:
// the bit clear holds its block in reset, set releases it, and reading it
// gives the state. Other bits of a word belong to other blocks, and
// firmware leaves the controllers live, so a command changes one bit by
// reading the word and writing it back with that bit alone changed. The
// index of a line is the one RSTL's entries give. Registers and indices
// are the hardware's (chinese-wall's sky1-soc 02, section 2.1 and Annex A).

/// One reset line: the word it is in and its bit.
public struct Line: Equatable, Sendable {
  public let register: Int
  public let bit: UInt32
  public init(register: Int, bit: UInt32) {
    self.register = register
    self.bit = bit
  }
}

public enum Controller: Equatable, Sendable {
  /// RST0, the S5 system controller.
  case s5
  /// RST1, the FCH controller.
  case fch

  /// The controller whose registers are at `base`; nil for any other.
  public init?(base: UInt64) {
    switch base {
    case 0x1600_0000: self = .s5
    case 0x0416_0000: self = .fch
    default: return nil
    }
  }

  public var name: String { self == .s5 ? "s5" : "fch" }
  public var hid: String { self == .s5 ? "CIXHA020" : "CIXHA021" }

  /// How many lines it has: the indices 0 up to this.
  public var count: Int { self == .s5 ? 143 : 29 }

  /// The registers it needs mapped: up to and including its last word.
  public var size: Int { self == .s5 ? 0x808 : 0x014 }

  /// The line RSTL's index `index` names; nil past the controller's last.
  public func line(_ index: UInt32) -> Line? {
    let i = Int(index)
    guard i < count else { return nil }
    switch self {
    case .s5:
      // Annex A: three single-line words, then the runs of 27, 21, 20, 20,
      // 32 and 20 lines in words 0x400 to 0x40C, 0x800 and 0x804.
      if i < 3 { return Line(register: 0x304 + 4 * i, bit: 1) }
      let firsts = [3, 30, 51, 71, 91, 123]
      let registers = [0x400, 0x404, 0x408, 0x40C, 0x800, 0x804]
      var run = 0
      while run + 1 < firsts.count, firsts[run + 1] <= i { run += 1 }
      return Line(register: registers[run], bit: 1 << UInt32(i - firsts[run]))
    case .fch:
      // Section 2.1.2's table.
      switch i {
      case 0...7: return Line(register: 0x008, bit: 1 << UInt32(i))
      case 8: return Line(register: 0x008, bit: 1 << 20)
      case 9...11: return Line(register: 0x00C, bit: 1 << UInt32(i - 9))
      case 12...15: return Line(register: 0x00C, bit: 1 << UInt32(i - 12 + 4))
      case 16, 17: return Line(register: 0x00C, bit: 1 << UInt32(i - 16 + 8))
      case 18...25: return Line(register: 0x00C, bit: 1 << UInt32(i - 18 + 12))
      case 26: return Line(register: 0x00C, bit: 1 << 21)
      default: return Line(register: 0x010, bit: 1 << UInt32(i - 27))
      }
    }
  }
}

/// A `ctl` command: `reset N assert`, `reset N deassert` or `reset N pulse
/// US` (asserted for US microseconds, released, and US more).
public enum Command: Equatable, Sendable {
  case assert(UInt32)
  case deassert(UInt32)
  case pulse(UInt32, microseconds: UInt32)

  /// The longest hold a pulse takes.
  public static let longestPulse: UInt32 = 100_000

  public init?(_ line: String) {
    let w = line.utf8.split(separator: 0x20, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    guard w.count >= 3, w[0].utf8.elementsEqual("reset".utf8), let n = Command.number(w[1]) else { return nil }
    let verb = w[2].utf8
    if w.count == 3, verb.elementsEqual("assert".utf8) {
      self = .assert(n)
    } else if w.count == 3, verb.elementsEqual("deassert".utf8) {
      self = .deassert(n)
    } else if w.count == 4, verb.elementsEqual("pulse".utf8), let us = Command.number(w[3]), us <= Command.longestPulse {
      self = .pulse(n, microseconds: us)
    } else {
      return nil
    }
  }

  /// A number in decimal or `0x` hexadecimal.
  static func number(_ s: String) -> UInt32? {
    let b = Array(s.utf8)
    if b.count > 2, b[0] == 0x30, b[1] == 0x78 || b[1] == 0x58 {
      return UInt32(String(decoding: b[2...], as: UTF8.self), radix: 16)
    }
    return UInt32(s)
  }

  public var index: UInt32 {
    switch self {
    case .assert(let n), .deassert(let n), .pulse(let n, _): return n
    }
  }

  public var description: String {
    switch self {
    case .assert(let n): return "reset \(n) assert"
    case .deassert(let n): return "reset \(n) deassert"
    case .pulse(let n, let us): return "reset \(n) pulse \(us)"
    }
  }
}

public enum ResetError: Error, Sendable {
  /// The controller has no such line.
  case noSuchLine

  public var description: String { "no such line" }
}

/// The word `word` with `line`'s bit changed and no other: clear when
/// asserted (active low), set when released.
public func changed(_ word: UInt32, _ line: Line, asserted: Bool) -> UInt32 {
  asserted ? word & ~line.bit : word | line.bit
}

/// Whether `line` reads as held in reset in `word`.
public func isAsserted(_ word: UInt32, _ line: Line) -> Bool { word & line.bit == 0 }
