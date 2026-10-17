// SPDX-License-Identifier: BSD-3-Clause

// A fixed-cell bitmap font: glyphs by code point, each `height` rows of
// `(width + 7) / 8` bytes, the leftmost pixel the high bit. The fonts
// themselves are generated data (generated/, fontgen) under their own
// licenses.

public struct Font: Sendable {
  public let width: Int
  public let height: Int
  /// Ascending.
  let codepoints: [UInt32]
  let bitmaps: [UInt8]

  public init(width: Int, height: Int, codepoints: [UInt32], bitmaps: [UInt8]) {
    precondition(bitmaps.count == codepoints.count * height * ((width + 7) / 8))
    self.width = width
    self.height = height
    self.codepoints = codepoints
    self.bitmaps = bitmaps
  }

  public var bytesPerRow: Int { (width + 7) / 8 }
  public var glyphCount: Int { codepoints.count }

  /// The glyph's index, or nil if the font has none.
  public func glyph(_ codepoint: UInt32) -> Int? {
    var lo = 0, hi = codepoints.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if codepoints[mid] < codepoint { lo = mid + 1 } else { hi = mid }
    }
    return lo < codepoints.count && codepoints[lo] == codepoint ? lo : nil
  }

  /// Whether pixel (`x`, `y`) of glyph `index` is set.
  public func pixel(_ index: Int, x: Int, y: Int) -> Bool {
    bitmaps[(index * height + y) * bytesPerRow + x / 8] & (0x80 >> UInt8(x % 8)) != 0
  }

  /// Row `y` of glyph `index`, its bits from the left in the high bits of
  /// a UInt32 (fonts up to 32 pixels wide).
  public func row(_ index: Int, _ y: Int) -> UInt32 {
    var v: UInt32 = 0
    let at = (index * height + y) * bytesPerRow
    for b in 0..<bytesPerRow { v |= UInt32(bitmaps[at + b]) << UInt32(24 - 8 * b) }
    return v
  }
}
