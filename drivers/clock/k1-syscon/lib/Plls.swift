// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's PLL unit (the APBS, at 0xd4090000), read only: each
// of its three PLLs' rate and whether it runs, and whether each of PLL2's
// and PLL3's eight divided outputs (D1 to D8) is gated on, as
// bin/k1-syscon serves them in `rates` for the APMU's driver, whose
// clocks' parents they are (chinese-wall's spacemit-k1 01 §1.4, §1.5). A
// PLL's rate is its configuration matched against the rates the chip's
// tables give (§1.4.5); one that matches none is unknown. PLL1, whose one
// rate every peripheral clock assumes, is taken at it. Nothing here
// changes a PLL: PLL1 and PLL2 feed nearly every clock, and PLL3 the CPUs.

/// What the PLLs run at, as the APMU's clocks' parents need it.
public struct PLLRates: Equatable, Sendable {
  /// PLL1 to PLL3, in Hz; nil where unknown or not running.
  public var rates: [UInt64?]
  /// For each, its outputs D1 to D8 gated on: PLL2's and PLL3's (PLL1's
  /// gates are laid out otherwise, and none of its parents here use
  /// them: empty).
  public var outputs: [[Bool]]

  public init(rates: [UInt64?], outputs: [[Bool]]) {
    self.rates = rates
    self.outputs = outputs
  }

  /// PLL1's rate, which every peripheral tree assumes (§1.4.5).
  public static let pll1: UInt64 = 2_457_600_000

  /// What a driver without the PLL unit's knows: PLL1 at its rate; PLL2
  /// and PLL3 unknown.
  public static let assumed = PLLRates(rates: [pll1, nil, nil],
                                       outputs: [[], Array(repeating: false, count: 8), Array(repeating: false, count: 8)])

  /// PLL `n`'s (1 to 3) rate divided by `divisor`, from its output D
  /// `divisor` (1 to 8), which must be on; nil if it isn't, or the rate is
  /// unknown. PLL1's APMU parents are branches the MPMU gates, which
  /// aren't read: PLL1's are taken to be on.
  public func output(_ n: Int, _ divisor: UInt64) -> UInt64? {
    guard n >= 1, n <= 3, divisor >= 1, let rate = rates[n - 1] else { return nil }
    if n != 1 {
      let i = Int(divisor) - 1
      guard i < 8, i < outputs[n - 1].count, outputs[n - 1][i] else { return nil }
    }
    return rate / divisor
  }

  /// `rates`' lines: `pll<n> <hz|-> on|off` for each PLL, then
  /// `pll<n>_d<k> <hz|-> on|off` for each of PLL2's and PLL3's outputs.
  public var text: String {
    var out = ""
    for n in 0..<3 {
      out += "pll\(n + 1) \(rates[n].map { String($0) } ?? "-") \(rates[n] != nil ? "on" : "off")\n"
    }
    for n in 0..<3 {
      for k in 0..<8 where k < outputs[n].count {
        let hz = rates[n].map { String($0 / UInt64(k + 1)) } ?? "-"
        out += "pll\(n + 1)_d\(k + 1) \(hz) \(outputs[n][k] ? "on" : "off")\n"
      }
    }
    return out
  }

  /// `rates` read back; PLL1 as assumed where it isn't given, and an
  /// output not listed off.
  public init(text: String) {
    var rates: [UInt64?] = [nil, nil, nil]
    var outputs: [[Bool]] = [[], Array(repeating: false, count: 8), Array(repeating: false, count: 8)]
    var pll1Given = false
    for line in text.utf8.split(separator: 0x0A) {
      let w = line.split(separator: 0x20).map { Array($0) }
      guard w.count == 3, w[0].count >= 4, w[0].starts(with: Array("pll".utf8)) else { continue }
      let n = Int(w[0][3]) - 0x30
      guard n >= 1, n <= 3 else { continue }
      let on = w[2] == Array("on".utf8)
      let hz = UInt64(String(decoding: w[1], as: UTF8.self))
      if w[0].count == 4 {
        if n == 1 { pll1Given = true }
        rates[n - 1] = on ? hz : nil
      } else if w[0].count == 7, w[0][4] == UInt8(ascii: "_"), w[0][5] == UInt8(ascii: "d") {
        let k = Int(w[0][6]) - 0x31
        if n > 1, k >= 0, k < 8 { outputs[n - 1][k] = on }
      }
    }
    if !pll1Given { rates[0] = Self.pll1 }
    self.init(rates: rates, outputs: outputs)
  }
}

/// The PLL unit's registers (§1.4.1, §1.5): each PLL's SWCR1 (its
/// configuration), SWCR2 (its outputs' gates, bit k-1 for D k) and
/// SWCR3 (bit 31 running, bits 30:0 its feedback).
public enum PLLUnit {
  public static let size = 0x1000
  public static let registers: [(swcr1: Int, swcr2: Int, swcr3: Int)] = [
    (0x100, 0x104, 0x108), (0x118, 0x11C, 0x120), (0x124, 0x128, 0x12C),
  ]
  static let running: UInt32 = 1 << 31

  /// Each PLL's rates and its configuration's words (§1.4.5): PLL1's and
  /// PLL2's fixed rates, and PLL3's six.
  static let table: [(pll: Int, hz: UInt64, swcr1: UInt32, swcr3: UInt32)] = [
    (1, 2_457_600_000, 0x0050_DD64, 0x330C_CCCD),
    (2, 3_000_000_000, 0x0050_DD66, 0x3FE0_0000),
    (3, 1_600_000_000, 0x0050_CD61, 0x43EA_AAAB),
    (3, 1_800_000_000, 0x0050_CD61, 0x4B00_0000),
    (3, 2_000_000_000, 0x0050_DD62, 0x2AEA_AAAB),
    (3, 2_457_600_000, 0x0050_DD64, 0x330C_CCCD),
    (3, 3_000_000_000, 0x0050_DD66, 0x3FE0_0000),
    (3, 3_200_000_000, 0x0050_DD67, 0x43EA_AAAB),
  ]

  /// PLL `n`'s (1 to 3) rate from its SWCR1 and SWCR3: nil where it isn't
  /// running or its configuration is in no table.
  public static func rate(_ n: Int, swcr1: UInt32, swcr3: UInt32) -> UInt64? {
    guard swcr3 & running != 0 else { return nil }
    return table.first { $0.pll == n && $0.swcr1 == swcr1 && $0.swcr3 == swcr3 & ~running }?.hz
  }

  /// What the registers say, read through `load`.
  public static func rates(_ load: (Int) -> UInt32) -> PLLRates {
    var rates: [UInt64?] = [], outputs: [[Bool]] = []
    for (i, r) in registers.enumerated() {
      let running = load(r.swcr3) & Self.running != 0
      // PLL1 runs at its one rate whatever its words say (the Orange Pi
      // RV2's match no table's): every clock assumes it.
      rates.append(i == 0 ? PLLRates.pll1 : rate(i + 1, swcr1: load(r.swcr1), swcr3: load(r.swcr3)))
      let gates = load(r.swcr2)
      outputs.append(i == 0 ? [] : (0..<8).map { running && gates & (1 << UInt32($0)) != 0 })
    }
    return PLLRates(rates: rates, outputs: outputs)
  }

  /// `status`' lines: each PLL's registers, `pll3 swcr1 0x50dd67 swcr2
  /// 0xff swcr3 0xc3eaaaab: 3200000000 Hz` (`unknown`, or `off`).
  public static func states(_ load: (Int) -> UInt32) -> [String] {
    registers.enumerated().map { (i, r) in
      let c1 = load(r.swcr1), c2 = load(r.swcr2), c3 = load(r.swcr3)
      let read = rate(i + 1, swcr1: c1, swcr3: c3)
      let what = i == 0 && read == nil
        ? "taken as \(PLLRates.pll1) Hz"
        : c3 & running == 0 ? "off" : read.map { "\($0) Hz" } ?? "unknown"
      return "pll\(i + 1) swcr1 0x\(String(c1, radix: 16)) swcr2 0x\(String(c2, radix: 16)) "
        + "swcr3 0x\(String(c3, radix: 16)): \(what)"
    }
  }
}
