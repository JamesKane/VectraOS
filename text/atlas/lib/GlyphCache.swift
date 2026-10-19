// SPDX-License-Identifier: BSD-3-Clause

// The glyph cache (M6h): a glyph's coverage bitmap at a size and a quarter
// pixel position, or its distance field, rendered the first time it's
// asked for and found in the atlas after that.

import MSDF
import OpenType
import Raster

public struct GlyphCache: Sendable {
  /// Coverage, a byte a pixel.
  public var coverage: Atlas
  /// Distance fields, four bytes a texel.
  public var fields: Atlas
  /// Texels per em of the fields: one field draws a glyph at any size.
  public var fieldSize = 32
  var rasterizer = Rasterizer()
  var generator = DistanceFieldGenerator()
  var bitmap = Bitmap()
  var field = DistanceField()

  public init(coverageSize: Int = 1024, fieldSize atlas: Int = 1024) {
    coverage = Atlas(width: coverageSize, height: coverageSize, bytesPerPixel: 1)
    fields = Atlas(width: atlas, height: atlas, bytesPerPixel: 4)
  }

  /// The pen's x position's fraction, in quarters of a pixel (the
  /// subpixel positions a glyph is rendered at).
  public static func quarter(_ x: Double) -> UInt8 {
    let f = x - Double(Int(x)) + (x < 0 && Double(Int(x)) != x ? 1 : 0)
    return UInt8(min(3, Int(f * 4 + 0.5) & 3))
  }

  /// A glyph's coverage at `pixelsPerEm`, its pen at a quarter pixel `x`
  /// (0 to 3) past a whole one; nil if it can't be had (no such glyph, or
  /// larger than the atlas).
  public mutating func coverage(_ font: Font, fontID: UInt32, glyph: Int, pixelsPerEm: Double, quarter: UInt8 = 0)
    -> AtlasRegion?
  {
    let size = UInt32(min(max(pixelsPerEm * 64 + 0.5, 0), 4_000_000))
    let key = GlyphKey(font: fontID, glyph: UInt32(glyph), size: size, subpixel: quarter & 3)
    if let r = coverage.find(key) { return r }
    guard let outline = try? font.outline(glyph) else { return nil }
    let scale = Double(size) / 64 / Double(font.metrics.unitsPerEm)
    rasterizer.render(outline, scale: scale, x: Double(quarter & 3) / 4, into: &bitmap)
    let b = bitmap
    return coverage.add(key, width: b.width, height: b.height, left: b.left, top: b.top) { row, pixels, at in
      for i in 0..<b.width { pixels[at + i] = b.pixels[row * b.width + i] }
    }
  }

  /// The distance, in texels, a field's values span.
  public var fieldRange: Double { generator.range }

  /// A glyph's distance field, at `fieldSize` texels per em.
  public mutating func field(_ font: Font, fontID: UInt32, glyph: Int) -> AtlasRegion? {
    let key = GlyphKey(font: fontID, glyph: UInt32(glyph), size: UInt32(fieldSize), field: true)
    if let r = fields.find(key) { return r }
    guard let outline = try? font.outline(glyph) else { return nil }
    generator.generate(outline, scale: Double(fieldSize) / Double(font.metrics.unitsPerEm), into: &field)
    let f = field
    return fields.add(key, width: f.width, height: f.height, left: f.left, top: f.top) { row, pixels, at in
      for i in 0..<f.width * 4 { pixels[at + i] = f.pixels[row * f.width * 4 + i] }
    }
  }
}
