// SPDX-License-Identifier: BSD-3-Clause

// What an output's EDID (VESA E-EDID 1.4) says that the display class's
// clients use: its maker's PNP id and the monitor's name, which name an
// output (D120), and its preferred mode, the first detailed timing.

public struct EDID: Equatable, Sendable {
  /// Three letters (`DEL`).
  public var maker: String
  public var product: UInt16
  public var serial: UInt32
  /// The monitor name descriptor's text (`U2720Q`), or empty.
  public var name: String
  /// The first detailed timing's active size and refresh (millihertz).
  public var preferred: (width: Int, height: Int, refresh: Int)?
  /// Extension blocks it counts.
  public var extensions: Int

  public static func == (a: EDID, b: EDID) -> Bool {
    // Bytes: String's == needs Unicode tables tier 0 doesn't link.
    a.maker.utf8.elementsEqual(b.maker.utf8) && a.product == b.product && a.serial == b.serial
      && a.name.utf8.elementsEqual(b.name.utf8)
      && a.extensions == b.extensions && a.preferred?.width == b.preferred?.width
      && a.preferred?.height == b.preferred?.height && a.preferred?.refresh == b.preferred?.refresh
  }

  /// Block 0 of `bytes`: nil without the header, or if its checksum fails.
  public init?(_ bytes: [UInt8]) {
    guard bytes.count >= 128, bytes[0..<8].elementsEqual([0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0]),
      bytes[0..<128].reduce(0, &+) == 0
    else { return nil }
    let id = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
    maker = String(decoding: [10, 5, 0].map { UInt8(0x40 + (id >> UInt16($0) & 0x1F)) }, as: UTF8.self)
    product = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
    serial = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
    extensions = Int(bytes[126])
    name = ""
    preferred = nil
    for d in stride(from: 54, to: 126, by: 18) {
      let pixelClock = Int(bytes[d]) | Int(bytes[d + 1]) << 8  // 10 kHz
      if pixelClock != 0 {
        guard preferred == nil else { continue }
        let w = Int(bytes[d + 2]) | Int(bytes[d + 4] >> 4) << 8
        let hBlank = Int(bytes[d + 3]) | Int(bytes[d + 4] & 0xF) << 8
        let h = Int(bytes[d + 5]) | Int(bytes[d + 7] >> 4) << 8
        let vBlank = Int(bytes[d + 6]) | Int(bytes[d + 7] & 0xF) << 8
        let total = (w + hBlank) * (h + vBlank)
        preferred = (w, h, total == 0 ? 0 : Int((Int64(pixelClock) * 10_000_000 + Int64(total / 2)) / Int64(total)))
      } else if bytes[d + 3] == 0xFC {
        // Up to 13 characters, ended by a line feed, padded with spaces.
        var text: [UInt8] = []
        for c in bytes[(d + 5)..<(d + 18)] {
          if c == 0x0A { break }
          text.append(c)
        }
        while text.last == 0x20 { text.removeLast() }
        name = String(decoding: text, as: UTF8.self)
      }
    }
  }

  /// `DEL U2720Q, preferred 3840x2160 at 60.000 Hz`.
  public var text: String {
    var t = maker + (name.isEmpty ? "" : " " + name)
    if let p = preferred { t += ", preferred \(p.width)x\(p.height) at \(p.refresh / 1000).\(threeDigits(p.refresh % 1000)) Hz" }
    return t
  }
}

func threeDigits(_ v: Int) -> String { v < 10 ? "00\(v)" : v < 100 ? "0\(v)" : "\(v)" }

/// A mode as a monitor's EDID gives it, VESA's terms: the pixel clock in
/// kHz, the active area, where each sync starts and ends, the totals, and
/// the syncs' polarity (true: active high).
public struct ModeTiming: Equatable, Sendable {
  public var clock: UInt32
  public var hActive: UInt32, hSyncStart: UInt32, hSyncEnd: UInt32, hTotal: UInt32
  public var vActive: UInt32, vSyncStart: UInt32, vSyncEnd: UInt32, vTotal: UInt32
  public var hPositive: Bool, vPositive: Bool

  public init(_ clock: UInt32, _ h: (UInt32, UInt32, UInt32, UInt32), _ v: (UInt32, UInt32, UInt32, UInt32),
              _ hPositive: Bool, _ vPositive: Bool) {
    self.clock = clock
    (hActive, hSyncStart, hSyncEnd, hTotal) = h
    (vActive, vSyncStart, vSyncEnd, vTotal) = v
    self.hPositive = hPositive
    self.vPositive = vPositive
  }

  /// Millihertz.
  public var refresh: UInt32 {
    let total = UInt64(hTotal) * UInt64(vTotal)
    return total == 0 ? 0 : UInt32(truncatingIfNeeded: (UInt64(clock) * 1_000_000 + total / 2) / total)
  }

  /// `1920x1080 at 60.000 Hz (148500 kHz)`.
  public var text: String {
    "\(hActive)x\(vActive) at \(refresh / 1000).\(threeDigits(Int(refresh % 1000))) Hz (\(clock) kHz)"
  }

  /// The same mode: size, refresh within 0.5 Hz, and clock within 0.5 %.
  func same(_ o: ModeTiming) -> Bool {
    hActive == o.hActive && vActive == o.vActive && (refresh > o.refresh ? refresh - o.refresh : o.refresh - refresh) < 500
      && (clock > o.clock ? clock - o.clock : o.clock - clock) * 200 <= clock
  }
}

extension EDID {
  /// Every progressive mode `bytes` (block 0 and its extensions) says
  /// the monitor runs, the preferred one (the first detailed timing)
  /// first: its detailed timings, those of its CTA-861 extensions, its
  /// established and standard timings and its CTA video codes where the
  /// tables here know them (DMT's and CTA-861's common ones). Each once.
  public static func modes(_ bytes: [UInt8]) -> [ModeTiming] {
    guard bytes.count >= 128, EDID(bytes) != nil else { return [] }
    var out: [ModeTiming] = []
    func add(_ m: ModeTiming?) {
      guard let m, !out.contains(where: { $0.same(m) }) else { return }
      out.append(m)
    }
    for d in stride(from: 54, to: 126, by: 18) { add(detailed(bytes, d)) }
    var ctaDetailed: [ModeTiming] = [], videoCodes: [UInt8] = []
    for b in 1..<(bytes.count / 128) where bytes[b * 128] == 0x02 {
      let base = b * 128, dtds = Int(bytes[base + 2])
      // Data blocks from byte 4 up to the detailed timings: video (tag 2)'s codes.
      var i = base + 4
      while dtds >= 4, i < base + dtds {
        let tag = bytes[i] >> 5, length = Int(bytes[i] & 0x1F)
        if tag == 2 { for c in bytes[(i + 1)..<min(i + 1 + length, base + dtds)] { videoCodes.append(c & 0x7F) } }
        i += 1 + length
      }
      var d = base + dtds
      while dtds >= 4, d + 18 <= base + 127 {
        if let m = detailed(bytes, d) { ctaDetailed.append(m) } else if bytes[d] == 0 && bytes[d + 1] == 0 { break }
        d += 18
      }
    }
    for m in ctaDetailed { add(m) }
    for c in videoCodes { add(cta(c)) }
    // Established timings I and II (bytes 35-36), then standard timings.
    let established: [(Int, UInt8, ModeTiming)] = [
      (35, 0x80, dmt720x400at70), (35, 0x20, dmt640x480at60), (35, 0x04, dmt640x480at75), (35, 0x01, dmt800x600at60),
      (36, 0x40, dmt800x600at75), (36, 0x08, dmt1024x768at60), (36, 0x02, dmt1024x768at75), (36, 0x01, dmt1280x1024at75),
    ]
    for (byte, bit, m) in established where bytes[byte] & bit != 0 { add(m) }
    for s in stride(from: 38, to: 54, by: 2) where !(bytes[s] == 1 && bytes[s + 1] == 1) && bytes[s] != 0 {
      let w = (UInt32(bytes[s]) + 31) * 8
      let h: UInt32
      switch bytes[s + 1] >> 6 {
      case 0: h = w * 10 / 16
      case 1: h = w * 3 / 4
      case 2: h = w * 4 / 5
      default: h = w * 9 / 16
      }
      let hz = UInt32(bytes[s + 1] & 0x3F) + 60
      add(dmt.first { $0.hActive == w && $0.vActive == h && ($0.refresh + 500) / 1000 == hz })
    }
    // Largest first after the preferred, then fastest.
    guard out.count > 1 else { return out }
    let rest = out[1...].sorted {
      let a = $0.hActive * $0.vActive, b = $1.hActive * $1.vActive
      return a != b ? a > b : $0.refresh > $1.refresh
    }
    return [out[0]] + rest
  }

  /// The detailed timing descriptor at `d`, if it is one and progressive.
  static func detailed(_ bytes: [UInt8], _ d: Int) -> ModeTiming? {
    let clock = (UInt32(bytes[d]) | UInt32(bytes[d + 1]) << 8) * 10
    guard clock != 0, bytes[d + 17] & 0x80 == 0 else { return nil }
    let w = UInt32(bytes[d + 2]) | UInt32(bytes[d + 4] >> 4) << 8
    let hBlank = UInt32(bytes[d + 3]) | UInt32(bytes[d + 4] & 0xF) << 8
    let h = UInt32(bytes[d + 5]) | UInt32(bytes[d + 7] >> 4) << 8
    let vBlank = UInt32(bytes[d + 6]) | UInt32(bytes[d + 7] & 0xF) << 8
    let hFront = UInt32(bytes[d + 8]) | UInt32(bytes[d + 11] >> 6) << 8
    let hSync = UInt32(bytes[d + 9]) | UInt32(bytes[d + 11] >> 4 & 3) << 8
    let vFront = UInt32(bytes[d + 10] >> 4) | UInt32(bytes[d + 11] >> 2 & 3) << 4
    let vSync = UInt32(bytes[d + 10] & 0xF) | UInt32(bytes[d + 11] & 3) << 4
    guard w > 0, h > 0, hSync > 0, vSync > 0, hFront + hSync <= hBlank, vFront + vSync <= vBlank else { return nil }
    // Digital separate syncs (bits 4:3 = 3) say each polarity; others are taken as negative.
    let flags = bytes[d + 17]
    let separate = flags >> 3 & 3 == 3
    return ModeTiming(clock, (w, w + hFront, w + hFront + hSync, w + hBlank), (h, h + vFront, h + vFront + vSync, h + vBlank),
                      separate && flags & 2 != 0, separate && flags & 4 != 0)
  }

  /// CTA-861's progressive video codes this knows.
  static func cta(_ code: UInt8) -> ModeTiming? {
    switch code {
    case 1: dmt640x480at60
    case 2, 3: ModeTiming(27000, (720, 736, 798, 858), (480, 489, 495, 525), false, false)
    case 4: ModeTiming(74250, (1280, 1390, 1430, 1650), (720, 725, 730, 750), true, true)
    case 16: ModeTiming(148_500, (1920, 2008, 2052, 2200), (1080, 1084, 1089, 1125), true, true)
    case 17, 18: ModeTiming(27000, (720, 732, 796, 864), (576, 581, 586, 625), false, false)
    case 19: ModeTiming(74250, (1280, 1720, 1760, 1980), (720, 725, 730, 750), true, true)
    case 31: ModeTiming(148_500, (1920, 2448, 2492, 2640), (1080, 1084, 1089, 1125), true, true)
    case 32: ModeTiming(74250, (1920, 2558, 2602, 2750), (1080, 1084, 1089, 1125), true, true)
    default: nil
    }
  }

  // VESA DMT's common modes.
  static let dmt720x400at70 = ModeTiming(28322, (720, 738, 846, 900), (400, 412, 414, 449), false, true)
  static let dmt640x480at60 = ModeTiming(25175, (640, 656, 752, 800), (480, 490, 492, 525), false, false)
  static let dmt640x480at75 = ModeTiming(31500, (640, 656, 720, 840), (480, 481, 484, 500), false, false)
  static let dmt800x600at60 = ModeTiming(40000, (800, 840, 968, 1056), (600, 601, 605, 628), true, true)
  static let dmt800x600at75 = ModeTiming(49500, (800, 816, 896, 1056), (600, 601, 604, 625), true, true)
  static let dmt1024x768at60 = ModeTiming(65000, (1024, 1048, 1184, 1344), (768, 771, 777, 806), false, false)
  static let dmt1024x768at75 = ModeTiming(78750, (1024, 1040, 1136, 1312), (768, 769, 772, 800), true, true)
  static let dmt1280x1024at75 = ModeTiming(135_000, (1280, 1296, 1440, 1688), (1024, 1025, 1028, 1066), true, true)
  static let dmt: [ModeTiming] = [
    dmt640x480at60, dmt800x600at60, dmt1024x768at60, dmt1024x768at75,
    ModeTiming(108_000, (1152, 1216, 1344, 1600), (864, 865, 868, 900), true, true),
    ModeTiming(108_000, (1280, 1328, 1440, 1688), (1024, 1025, 1028, 1066), true, true),
    dmt1280x1024at75,
    ModeTiming(106_500, (1440, 1520, 1672, 1904), (900, 903, 909, 934), false, true),
    ModeTiming(108_000, (1600, 1624, 1704, 1800), (900, 901, 904, 1000), true, true),
    ModeTiming(146_250, (1680, 1784, 1960, 2240), (1050, 1053, 1059, 1089), false, true),
    ModeTiming(148_500, (1920, 2008, 2052, 2200), (1080, 1084, 1089, 1125), true, true),
  ]
}
