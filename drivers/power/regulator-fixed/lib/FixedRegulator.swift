// SPDX-License-Identifier: BSD-3-Clause

// A fixed regulator (regulator-fixed(3)), as bin/regulator-fixed reads
// its node: a supply at one voltage, switched by a GPIO or always on. Its
// GPIO's level for on is high with `enable-active-high` and low without
// it, whatever the specifier's flags say, as Linux's binding has it (the
// gpiolib quirk for `regulator-fixed`). It may itself take a supply
// (`vin-supply`), which is turned on first, and settle for
// `startup-delay-us` once on.

/// What its node says.
public struct FixedRegulator: Equatable, Sendable {
  public var name = ""
  public var microvolts: UInt32 = 0
  public var activeHigh = false
  public var alwaysOn = false
  public var bootOn = false
  public var startupDelay: UInt32 = 0

  public init() {}

  /// Read from its node's properties, a line each (devmgr's /dev/dt/node).
  public init(node: String) {
    for line in node.utf8.split(separator: 0x0A) {
      let words = line.split(separator: 0x20, maxSplits: 1)
      guard let key = words.first else { continue }
      let value = words.count > 1 ? Array(words[1]) : []
      let named = { (k: String) in key.elementsEqual(k.utf8) }
      if named("regulator-name") {
        name = quoted(value)
      } else if named("regulator-min-microvolt") {
        microvolts = cell(value) ?? 0
      } else if named("enable-active-high") {
        activeHigh = true
      } else if named("regulator-always-on") {
        alwaysOn = true
      } else if named("regulator-boot-on") {
        bootOn = true
      } else if named("startup-delay-us") {
        startupDelay = cell(value) ?? 0
      }
    }
  }

  /// The GPIO provider's command that turns it on or off, for the GPIO
  /// specifier's cells (the K1's three: bank, pin, flags), the level
  /// given as the active one of a pin with no flags.
  public func gpioCommand(_ cells: [UInt32], on: Bool) -> String? {
    guard cells.count >= 2 else { return nil }
    let high = on == activeHigh
    return "gpio " + cells.dropLast(cells.count > 2 ? 1 : 0).map { String($0) }.joined(separator: " ")
      + " 0 " + (high ? "on" : "off")
  }
}

/// `"name"` without its quotes.
func quoted(_ v: [UInt8]) -> String {
  String(decoding: v.filter { $0 != UInt8(ascii: "\"") }, as: UTF8.self)
}

/// `<0x325aa0>`'s one cell.
func cell(_ v: [UInt8]) -> UInt32? {
  let s = String(decoding: v.filter { $0 != UInt8(ascii: "<") && $0 != UInt8(ascii: ">") }, as: UTF8.self)
  return s.utf8.starts(with: "0x".utf8) ? UInt32(String(decoding: s.utf8.dropFirst(2), as: UTF8.self), radix: 16)
    : UInt32(s)
}
