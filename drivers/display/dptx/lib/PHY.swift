// SPDX-License-Identifier: BSD-3-Clause

// The CIX Sky1's USB-C/DisplayPort combo PHY (CIXH2033, a Cadence
// Torrent-family SerDes; sky1-dp-tx 03), as bin/dptx changes a link's
// rate and its drive levels on it: PLL1, the DisplayPort PLL, set for the
// rate, and each lane's swing and pre-emphasis. Firmware brings the PHY up
// in DisplayPort-only mode and nothing here resets or reinitialises it.
// Its registers are 16 bits wide, each in a 32-bit slot: a register's
// index times 4 is its byte offset. Beside it, each transmitter has a
// window of its own onto the PHY's interface (`PHYInterface`): the
// lanes' power states, their PLL clock and the data enable.

public enum ComboPHY {
  /// A register's byte offset from its index (§3.3), lane `lane`'s for a
  /// per-lane one.
  public static func offset(_ index: Int, lane: Int = 0) -> Int { (index + 0x200 * lane) * 4 }

  /// PHY_PMA_CMN_CTRL2: bit 1 PLL1 ready, bit 7 PLL1 locked.
  public static let commonStatus = 0xE001
  /// PHY_PMA_PLL_CTRL: bit 1 lets PLL1 run.
  public static let pllControl = 0xE003
  public static let pll1Run: UInt32 = 1 << 1
  public static let pll1Locked: UInt32 = 1 << 7
  /// PHY_PMA_LANE_MAP: 0x51D9 in DisplayPort-only mode, the only one
  /// bin/dptx changes rates in (all four lanes DisplayPort's).
  public static let laneMap = 0xC010
  public static let displayPortOnly: UInt32 = 0x51D9

  // PLL1 (§3.4.2).
  public static let pll1IntDiv = 0x00D0
  public static let pll1FracDivL = 0x00D1
  public static let pll1HighThreshold = 0x00D3
  public static let pll1SSControl2 = 0x00D9
  public static let pll1SSControl3 = 0x00DA
  public static let pll1SSControl4 = 0x00DB
  public static let pll1ClockSelect = 0x01C1
  public static let pll1CurrentTrim = 0x01C3

  // Per lane (§3.4.3).
  public static let txccControl = 0x4040
  public static let postCursor = 0x404C  // TX_TXCC_CPOST_MULT_00
  public static let margin = 0x4050  // TX_TXCC_MGNFS_MULT_000
  public static let driverDiag = 0x40C6  // DRV_DIAG_TX_DRV
  public static let hsClockDivider = 0x40E7  // XCVR_DIAG_HSCLK_DIV
  public static let txDiagACYA = 0x41E7  // bit 0 holds the coefficients while they change

  /// PLL1's registers for a rate (§3.8.2), by the DPCD's code: the
  /// rate-dependent extras first, then the lanes' clock divider, then
  /// PLL1's divider, threshold and clock select. HBR3's is left out: its
  /// spread-spectrum writes are an open question (§3.8.2), and no sink
  /// here trains it.
  public struct RateSetting: Equatable, Sendable {
    public var currentTrim: UInt32
    public var spread2: UInt32, spread3: UInt32, spread4: UInt32
    public var hsClockDivider: UInt32
    public var intDiv: UInt32, fracDivL: UInt32, highThreshold: UInt32, clockSelect: UInt32
  }

  public static func setting(rate: UInt8) -> RateSetting? {
    switch rate {
    case 0x06:
      RateSetting(currentTrim: 0x3F, spread2: 0x44F, spread3: 0x7F, spread4: 0x3, hsClockDivider: 2, intDiv: 0x195,
                  fracDivL: 0, highThreshold: 0x10E, clockSelect: 0x0F01)
    case 0x0A:
      RateSetting(currentTrim: 0x3F, spread2: 0x44F, spread3: 0x7F, spread4: 0x3, hsClockDivider: 1, intDiv: 0x1C2,
                  fracDivL: 0, highThreshold: 0x12C, clockSelect: 0x0701)
    case 0x14:
      RateSetting(currentTrim: 0x3F, spread2: 0x44F, spread3: 0x7F, spread4: 0x3, hsClockDivider: 0, intDiv: 0x1C2,
                  fracDivL: 0, highThreshold: 0x12C, clockSelect: 0x0301)
    default: nil
    }
  }

  /// The rate PLL1's registers say, if one of `setting`'s.
  public static func rate(clockSelect: UInt32, intDiv: UInt32, hsClockDivider: UInt32) -> UInt8? {
    for r: UInt8 in [0x06, 0x0A, 0x14] {
      if let s = setting(rate: r), s.clockSelect == clockSelect, s.intDiv == intDiv, s.hsClockDivider == hsClockDivider {
        return r
      }
    }
    return nil
  }

  /// The writes, as (index, value, lane or nil for a common register), that
  /// set PLL1 for `rate` while it is stopped (§3.8.3 steps 3 to 5): every
  /// lane's divider, the four DisplayPort's in this mode.
  public static func rateWrites(_ s: RateSetting) -> [(index: Int, value: UInt32, lane: Int?)] {
    var w: [(index: Int, value: UInt32, lane: Int?)] = [
      (pll1CurrentTrim, s.currentTrim, nil), (pll1SSControl2, s.spread2, nil), (pll1SSControl3, s.spread3, nil),
      (pll1SSControl4, s.spread4, nil),
    ]
    for l in 0..<4 { w.append((hsClockDivider, s.hsClockDivider, l)) }
    w += [(pll1IntDiv, s.intDiv, nil), (pll1FracDivL, s.fracDivL, nil), (pll1HighThreshold, s.highThreshold, nil),
          (pll1ClockSelect, s.clockSelect, nil)]
    return w
  }

  /// A lane's margin and post-cursor for a swing and pre-emphasis (§3.9),
  /// their sum at most 3 (others clamped as the vendor's table fills them).
  public static func drive(swing: UInt8, preEmphasis: UInt8) -> (margin: UInt32, postCursor: UInt32) {
    let s = min(swing, 3), p = min(preEmphasis, 3 - min(swing, 3))
    let table: [[(UInt32, UInt32)]] = [
      [(0x28, 0x00), (0x1F, 0x14), (0x12, 0x20), (0x00, 0x27)],
      [(0x1F, 0x00), (0x13, 0x12), (0x00, 0x1F)],
      [(0x13, 0x00), (0x00, 0x13)],
      [(0x00, 0x00)],
    ]
    let e = table[Int(s)][Int(p)]
    return (e.0, e.1)
  }

  /// What §3.9 writes besides the two coefficients.
  public static let txccControlValue: UInt32 = 0x08A4
  public static let driverDiagValue: UInt32 = 0x0003
}

/// The transmitter's window onto its PHY's interface (sky1-dp-tx 03
/// §3.10, its third `_CRS` range), by byte offset.
public enum PHYInterface {
  public static let commonReady = 0x44
  public static let dataEnable = 0x50
  public static let powerStateRequest = 0x60
  public static let powerStateAck = 0x64
  public static let pllClockEnable = 0x68
  public static let pllClockAck = 0x6C
  /// ID_REV: bits 31:16 0x54 for the USB-C combo PHY's interface.
  public static let idRevision = 0xFC
  public static let comboType: UInt32 = 0x54

  // LANE_PWR_STATE_REQ's states.
  public static let a0: UInt32 = 0x1
  public static let a2: UInt32 = 0x4
  public static let a3: UInt32 = 0x8
}
