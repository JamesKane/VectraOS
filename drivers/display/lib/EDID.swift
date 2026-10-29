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
