// SPDX-License-Identifier: BSD-3-Clause

// The text stack's specimen page (M6h): what bin/text-test shows on croi
// and `td text-specimen` draws on the host, so the two can be compared
// pixel for pixel. A heading from distance fields, English prose set in a
// column at text size (ligatures, kerning, quotes, dashes, numbers,
// accents precomposed and combining, a soft hyphen), the sizes from 9 to
// 24 pixels, and the European alphabets, in the desktop's colours.

import GlyphAtlas
import OpenType

public enum Specimen {
  public static let background: UInt32 = 0x0A0A12
  public static let ink: UInt32 = 0xD8E1FF
  public static let accent: UInt32 = 0x7FD4FF

  static let prose = """
    Todhchai sets its own type. This paragraph was shaped by our OpenType shaper, broken into lines \
    by Unicode’s line-breaking rules, and drawn by our rasterizer: “office”, “waffle” and “fjord” \
    ligate; AV, Ta and “Yo” kern; naïve café résumés cost £3.50–€4 (10% off) — 1,234 of them… \
    A soft hyphen is invisible: co\u{AD}operate. Combining marks find their anchors: Q\u{303}, x\u{331}, \
    i\u{323}\u{302}, and a\u{308}\u{301}.
    """

  static let alphabets = [
    "Größe Straße · Zażółć gęślą jaźń · Příliš žluťoučký kůň",
    "Árvíztűrő tükörfúrógép · Ærøskøbing · Þór og ðæ · İstanbul",
    "Fiță, ș ț · Tiếng Việt có dấu · œuvre · IJsland · L·l",
  ]

  /// The page, `width` by `height`, in `font` (its `fontID` the cache's).
  public static func render(width: Int, height: Int, font: Font, fontID: UInt32 = 1,
                            cache: inout GlyphCache) -> Canvas
  {
    var canvas = Canvas(width: width, height: height, color: background)
    let setter = Typesetter(font)
    let margin = 48.0
    let column = min(Double(width) - 2 * margin, 760)
    var y = margin
    func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map { $0.value } }

    // A heading, from the distance fields.
    let heading = setter.set(scalars("Text on croi"), size: 56, width: Double(width), x: margin, y: y)
    canvas.drawFields(heading, size: 56, color: accent, font: font, fontID: fontID, cache: &cache)
    y += heading.height + 8
    canvas.fill(x: Int(margin), y: Int(y), width: Int(column), height: 1, 0x2A2F45)
    y += 16

    // Prose at text size.
    let body = setter.set(scalars(prose), size: 17, width: column, x: margin, y: y)
    canvas.draw(body, size: 17, color: ink, font: font, fontID: fontID, cache: &cache)
    y += body.height + 20

    // The sizes.
    for size in [9.0, 11, 13, 15, 18, 21, 24] {
      let line = setter.set(scalars("\(Int(size)) px: The quick brown fox jumps over the lazy dog."), size: size,
                            width: Double(width) - 2 * margin, x: margin, y: y)
      canvas.draw(line, size: size, color: ink, font: font, fontID: fontID, cache: &cache)
      y += line.height
    }
    y += 16

    // The European alphabets.
    for text in alphabets {
      let line = setter.set(scalars(text), size: 16, width: Double(width) - 2 * margin, x: margin, y: y)
      canvas.draw(line, size: 16, color: ink, font: font, fontID: fontID, cache: &cache)
      y += line.height
    }
    return canvas
  }
}
