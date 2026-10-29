// SPDX-License-Identifier: BSD-3-Clause

// A stream on the link (sky1-dp-tx 02 §2.5.1, §2.6): which rate and lanes
// carry a mode, and source 0's registers for it: its main stream
// attributes (the timing the sink is told), its transfer unit, and how
// the engine's pixels come in (8 bits a component, RGB, a pixel a clock).

extension DPTXRegisters {
  // Source 0's main-stream block (01 §1.5).
  public static let secondaryDataWindow = 0x808
  public static let dataControl = 0x810
  public static let streamOverride = 0x814
  public static let hTotal = 0x820
  public static let vTotal = 0x824
  public static let polarity = 0x828
  public static let hSyncWidth = 0x82C
  public static let vSyncWidth = 0x830
  public static let hResolution = 0x834
  public static let vResolution = 0x838
  public static let hStart = 0x83C
  public static let vStart = 0x840
  public static let misc0 = 0x844
  public static let misc1 = 0x848
  public static let transferUnit = 0x850
  public static let userPixelCount = 0x858
  public static let userDataCount = 0x85C
  public static let userSyncPolarity = 0x864
}

/// The RCSU's video adapter (01 §1.10, the fourth `_CRS` range):
/// pipeline 0's input, bit 29 two pixels a clock, 31:30 the encoding.
public enum VideoAdapter {
  public static let pipeline0 = 0x300
  public static let fieldMask: UInt32 = 0b111 << 29
}

/// A stream's timing as the engine sends it: VESA's terms, the pixel
/// clock in kHz, the syncs' polarity (true: active high).
public struct StreamTiming: Equatable, Sendable {
  public var clock: UInt32
  public var hActive: UInt32, hSyncStart: UInt32, hSyncEnd: UInt32, hTotal: UInt32
  public var vActive: UInt32, vSyncStart: UInt32, vSyncEnd: UInt32, vTotal: UInt32
  public var hPositive: Bool, vPositive: Bool

  public init(clock: UInt32, hActive: UInt32, hSyncStart: UInt32, hSyncEnd: UInt32, hTotal: UInt32,
              vActive: UInt32, vSyncStart: UInt32, vSyncEnd: UInt32, vTotal: UInt32, hPositive: Bool,
              vPositive: Bool) {
    self.clock = clock
    self.hActive = hActive
    self.hSyncStart = hSyncStart
    self.hSyncEnd = hSyncEnd
    self.hTotal = hTotal
    self.vActive = vActive
    self.vSyncStart = vSyncStart
    self.vSyncEnd = vSyncEnd
    self.vTotal = vTotal
    self.hPositive = hPositive
    self.vPositive = vPositive
  }

  /// Ordered as the engine needs it: sync after the active area, within the total.
  public var isValid: Bool {
    clock > 0 && hActive > 0 && hActive < hSyncStart && hSyncStart < hSyncEnd && hSyncEnd <= hTotal && vActive > 0
      && vActive < vSyncStart && vSyncStart < vSyncEnd && vSyncEnd <= vTotal
  }

  /// `1920x1080, 148500 kHz, total 2200x1125`.
  public var text: String { "\(hActive)x\(vActive), \(clock) kHz, total \(hTotal)x\(vTotal)" }
}

/// Link rates and what they carry.
public enum LinkMath {
  /// The rates bin/dptx trains, slowest first: RBR, HBR, HBR2 (HBR3's PHY
  /// setting is an open question, ComboPHY.setting).
  public static let rates: [UInt8] = [0x06, 0x0A, 0x14]

  /// A rate's link symbol clock in kHz (8b/10b: a byte a symbol a lane).
  public static func symbolClock(_ rate: UInt8) -> UInt32 { UInt32(rate) * 27_000 }

  /// Whether `lanes` lanes at `rate` carry a stream of `clock` kHz at 24
  /// bits a pixel, with 5 % to spare (the community's rule, after zero
  /// margin failed in practice).
  public static func carries(clock: UInt32, rate: UInt8, lanes: Int) -> Bool {
    UInt64(clock) * 24 * 100 <= 95 * UInt64(symbolClock(rate)) * UInt64(lanes) * 8
  }

  /// The fastest pixel clock (kHz, at 24 bits a pixel, no margin) the
  /// sink's best link that bin/dptx trains carries.
  public static func capacity(maxRate: UInt8, maxLanes: Int) -> UInt32 {
    guard let best = rates.last(where: { $0 <= maxRate }), maxLanes > 0 else { return 0 }
    return symbolClock(best) * UInt32(min(maxLanes, 4)) * 8 / 24
  }

  /// The links that carry `clock`, best first: the slowest rate, and at it
  /// the fewest lanes (1, 2 or 4), up to the sink's most.
  public static func candidates(clock: UInt32, maxRate: UInt8, maxLanes: Int) -> [(rate: UInt8, lanes: Int)] {
    var out: [(rate: UInt8, lanes: Int)] = []
    for r in rates where r <= maxRate {
      for l in [1, 2, 4] where l <= maxLanes && carries(clock: clock, rate: r, lanes: l) { out.append((r, l)) }
    }
    return out
  }

  /// TU_CONFIG (02 §2.6.3): a 64-symbol transfer unit, and the valid
  /// symbols in each on average, its integer part in 23:16 and sixteenths
  /// in 27:24.
  public static func transferUnit(clock: UInt32, rate: UInt8, lanes: Int) -> UInt32 {
    // (clock × 3 bytes) × 64 / (lanes × symbol clock), in sixteenths.
    let sixteenths = UInt64(clock) * 3 * 64 * 16 / (UInt64(lanes) * UInt64(symbolClock(rate)))
    return 64 | UInt32(truncatingIfNeeded: sixteenths / 16 & 0xFF) << 16 | UInt32(truncatingIfNeeded: sixteenths % 16) << 24
  }

  /// Source 0's registers for `t` on `lanes` lanes at `rate`, in the
  /// order written (02 §2.6.2-2.6.4): RGB, 8 bits a component, the
  /// stream's clock not locked to the link's; `invertSyncs` the syncs'
  /// polarity as the vendor's driver sends them, inverted.
  public static func streamRegisters(_ t: StreamTiming, rate: UInt8, lanes: Int, invertSyncs: Bool)
    -> [(offset: Int, value: UInt32)]
  {
    let h = t.hPositive != invertSyncs, v = t.vPositive != invertSyncs
    let pol: UInt32 = (h ? 1 : 0) | (v ? 2 : 0)
    let symbol = UInt64(symbolClock(rate))
    let window = UInt64(t.hTotal - t.hActive) * (symbol / 40) * 9 / UInt64(t.clock)
    let bytes = (t.hActive * 3 + UInt32(lanes) - 1) / UInt32(lanes)
    return [
      (DPTXRegisters.misc0, 1 << 5), (DPTXRegisters.misc1, 0), (DPTXRegisters.streamOverride, 0),
      (DPTXRegisters.transferUnit, 64), (DPTXRegisters.transferUnit, transferUnit(clock: t.clock, rate: rate, lanes: lanes)),
      (DPTXRegisters.hTotal, t.hTotal), (DPTXRegisters.vTotal, t.vTotal),
      (DPTXRegisters.hSyncWidth, t.hSyncEnd - t.hSyncStart), (DPTXRegisters.vSyncWidth, t.vSyncEnd - t.vSyncStart),
      (DPTXRegisters.hResolution, t.hActive), (DPTXRegisters.vResolution, t.vActive),
      (DPTXRegisters.hStart, t.hTotal - t.hSyncStart), (DPTXRegisters.vStart, t.vTotal - t.vSyncStart),
      (DPTXRegisters.polarity, pol), (DPTXRegisters.userSyncPolarity, 0xC | pol),
      (DPTXRegisters.userPixelCount, 1), (DPTXRegisters.userDataCount, bytes),
      (DPTXRegisters.secondaryDataWindow, UInt32(truncatingIfNeeded: window)), (DPTXRegisters.dataControl, 0x2004),
    ]
  }
}
