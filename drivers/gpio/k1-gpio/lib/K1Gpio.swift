// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's GPIO controller (k1-gpio(3)), as bin/k1-gpio drives
// it: 128 GPIOs in four banks of 32, each bank's registers at its own
// offset, a pin's level read from GPLR, driven through the set and clear
// registers (GPSR, GPCR) and turned to an output or input through GSDR
// and GCDR. A consumer's `gpios` specifier is three cells, the bank, the
// pin in it and flags (bit 0 active low), and its command names them:
// `gpio BANK PIN FLAGS on|off|input`, `on` the pin's active level.
// Registers and offsets are the hardware's, as Linux's gpio-spacemit-k1.c
// lists them.

/// A bank's registers, from the bank's offset.
public enum GpioRegister {
  public static let level = 0x00
  public static let direction = 0x0C
  public static let set = 0x18
  public static let clear = 0x24
  public static let setDirection = 0x54
  public static let clearDirection = 0x60
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

  public var description: String { "no such pin" }
}

/// A command a line of `ctl`: `gpio BANK PIN FLAGS on|off|input`.
public struct GpioCommand: Equatable, Sendable {
  public enum Action: Equatable, Sendable { case on, off, input }

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
    } else {
      return nil
    }
    bank = Int(b)
    pin = Int(p)
    activeLow = f & 1 != 0
  }

  public var description: String {
    "gpio \(bank) \(pin) \(activeLow ? 1 : 0) " + (action == .on ? "on" : action == .off ? "off" : "input")
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
    }
  }
}

/// A decimal or `0x` hexadecimal number.
func number(_ s: String) -> UInt32? {
  s.utf8.starts(with: "0x".utf8) ? UInt32(String(decoding: s.utf8.dropFirst(2), as: UTF8.self), radix: 16) : UInt32(s)
}
