// SPDX-License-Identifier: BSD-3-Clause

// Text set and drawn (M6h): the stack's parts together. A Typesetter
// shapes a paragraph (Shape), breaks it into lines no wider than asked at
// UAX #14's opportunities (TDUnicode; mandatory breaks always, spaces
// hanging past the edge), and places its glyphs; a Canvas draws them,
// small text as coverage from the glyph cache at quarter-pixel positions,
// large text from distance fields (sampled bilinearly, the median's
// distance turned into coverage over a pixel), blended over what's there
// in linear light (Light, D110), a glyph's coverage first raised by the
// canvas's contrast curve. Pixels are 0x00RRGGBB, sRGB, rows from the
// top, as Radharc's images are.

import GlyphAtlas
import Light
import MSDF
import OpenType
import PixelKernels
import Shape
import TDUnicode

/// A glyph placed: its pen position (x from the left, the baseline's y
/// from the top, in pixels).
public struct PlacedGlyph: Equatable, Sendable {
  public var glyph: Int
  public var x: Double
  public var y: Double
  public var cluster: Int
}

/// A paragraph set: its glyphs, line by line, and how tall it is.
public struct Paragraph: Sendable {
  public var glyphs: [PlacedGlyph] = []
  /// Each line's glyphs (a range of `glyphs`) and width.
  public var lines: [(glyphs: Range<Int>, width: Double)] = []
  public var height = 0.0
  /// The pen's advance over the whole text on one line, trailing spaces
  /// included (where the next run would start).
  public var advance = 0.0
  public init() {}
}

public struct Typesetter: Sendable {
  public let font: Font
  let shaper: Shaper

  public init(_ font: Font) {
    self.font = font
    shaper = Shaper(font)
  }

  /// The distance from one baseline to the next at `size` pixels an em:
  /// the font's ascender, descender and line gap.
  public func lineHeight(_ size: Double) -> Double {
    let m = font.metrics
    return Double(m.ascender - m.descender + m.lineGap) * size / Double(m.unitsPerEm)
  }

  /// `text` set at `size` pixels an em in lines no wider than `width`,
  /// its first baseline an ascender below `y`, from `x`; `tracking`
  /// pixels after each character (CSS's letter-spacing, which also turns
  /// common ligatures off).
  public func set(_ text: [UInt32], size: Double, width: Double, x: Double = 0, y: Double = 0,
                  features: [Feature] = [], tracking: Double = 0) -> Paragraph
  {
    var p = Paragraph()
    let shaped = shaper.shape(text, features: tracking != 0 ? [Feature("liga", 0)] + features : features)
    let scale = size / Double(font.metrics.unitsPerEm)
    // Each glyph's pen position along one unbroken line; the spacing after
    // each cluster's last glyph.
    var pen = [Double](repeating: 0, count: shaped.count + 1)
    for (i, g) in shaped.enumerated() {
      let ends = i + 1 == shaped.count || shaped[i + 1].cluster != g.cluster
      pen[i + 1] = pen[i] + Double(g.xAdvance) * scale + (ends ? tracking : 0)
    }
    // Where a line may end: after the glyphs before each break.
    let breaks = Segmentation.lineBreaks(text)
    func firstGlyph(atOrAfter index: Int) -> Int {
      var k = 0
      while k < shaped.count && shaped[k].cluster < index { k += 1 }
      return k
    }
    func isSpace(_ g: ShapedGlyph) -> Bool {
      let c = text[g.cluster]
      return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x3000 || c == 0x2029 || c == 0x2028
        || c == 0x85
    }
    /// A line from glyph `start` to `end`: its width without the spaces it
    /// ends with.
    func measure(_ start: Int, _ end: Int) -> Double {
      var e = end
      while e > start && isSpace(shaped[e - 1]) { e -= 1 }
      return pen[e] - pen[start]
    }
    var start = 0
    var lastFit: Int? = nil
    var lines: [(Int, Int)] = []
    for b in breaks {
      let end = firstGlyph(atOrAfter: b.index)
      if measure(start, end) > width, let fit = lastFit, fit > start {
        lines.append((start, fit))
        start = fit
      }
      lastFit = end
      if b.kind == .mandatory {
        lines.append((start, end))
        start = end
        lastFit = nil
      }
    }
    if start < shaped.count || lines.isEmpty { lines.append((start, shaped.count)) }
    let ascent = Double(font.metrics.ascender) * scale
    let leading = lineHeight(size)
    for (n, (s, e)) in lines.enumerated() {
      let baseline = y + ascent + Double(n) * leading
      let first = p.glyphs.count
      for k in s..<e {
        let g = shaped[k]
        if isSpace(g) && (k + 1 == e || text[g.cluster] == 0x0A) { continue }
        p.glyphs.append(PlacedGlyph(glyph: g.glyph, x: x + pen[k] - pen[s] + Double(g.xOffset) * scale,
                                    y: baseline - Double(g.yOffset) * scale, cluster: g.cluster))
      }
      p.lines.append((first..<p.glyphs.count, measure(s, e)))
    }
    p.height = Double(lines.count) * leading
    p.advance = pen[shaped.count]
    return p
  }
}

/// Pixels to draw on: 0x00RRGGBB, rows from the top.
public struct Canvas: Sendable {
  public let width: Int
  public let height: Int
  public var pixels: [UInt32]
  /// The curve a glyph's coverage takes before it is blended: the theme's
  /// `text.contrast`.
  public var contrast = TextContrast.standard

  public init(width: Int, height: Int, color: UInt32) {
    self.width = width
    self.height = height
    pixels = [UInt32](repeating: color, count: width * height)
  }

  /// `color` over the pixel at (x, y), `coverage` of it (0-255), in light.
  @inline(__always) public mutating func blend(_ x: Int, _ y: Int, _ color: UInt32, _ coverage: Int) {
    guard coverage > 0, x >= 0, y >= 0, x < width, y < height else { return }
    let i = y * width + x
    pixels[i] = Light.over(color, pixels[i], coverage: UInt32(min(coverage, 255)))
  }

  /// A glyph's `coverage` (0-255) of `color` at (x, y), at `alpha`
  /// (0-255): through the contrast curve, in light.
  @inline(__always) public mutating func blendText(_ x: Int, _ y: Int, _ color: UInt32, _ coverage: Int,
                                                  alpha: UInt32 = 255)
  {
    guard coverage > 0, x >= 0, y >= 0, x < width, y < height else { return }
    let i = y * width + x
    pixels[i] = Light.overText(color, pixels[i], coverage: coverage, alpha: alpha, contrast: contrast)
  }

  /// `color` over [x0, x1) of row `y`, `coverage` of it: `blend` along
  /// the row.
  public mutating func blend(row y: Int, _ x0: Int, _ x1: Int, _ color: UInt32, _ coverage: Int) {
    let left = max(x0, 0), right = min(x1, width)
    guard coverage > 0, y >= 0, y < height, left < right else { return }
    let w = width
    pixels.withUnsafeMutableBufferPointer { p in
      unsafe PixelKernels.over(color, coverage: UInt32(min(coverage, 255)), p.baseAddress! + y * w + left, right - left)
    }
  }

  /// A glyph's row of coverage, a byte a pixel from `coverage`, of
  /// `color` along [x0, x1) of row `y`: `blendText` along the row.
  public mutating func blendText(row y: Int, _ x0: Int, _ x1: Int, coverage: UnsafePointer<UInt8>,
                                 ink: inout PixelKernels.TextInk)
  {
    let left = max(x0, 0), right = min(x1, width)
    guard y >= 0, y < height, left < right else { return }
    let w = width
    pixels.withUnsafeMutableBufferPointer { p in
      unsafe PixelKernels.overText(&ink, coverage: coverage + (left - x0), p.baseAddress! + y * w + left,
                                   right - left)
    }
  }

  public mutating func fill(x: Int, y: Int, width w: Int, height h: Int, _ color: UInt32) {
    let left = max(0, x), right = min(width, x + w), stride = width
    guard left < right else { return }
    pixels.withUnsafeMutableBufferPointer { p in
      for row in max(0, y)..<max(max(0, y), min(height, y + h)) {
        unsafe PixelKernels.fill(p.baseAddress! + row * stride + left, right - left, color)
      }
    }
  }

  /// A paragraph's glyphs as coverage, from the cache: each at its pen's
  /// whole pixel and quarter.
  public mutating func draw(_ p: Paragraph, size: Double, color: UInt32, font: Font, fontID: UInt32,
                            cache: inout GlyphCache)
  {
    var ink = PixelKernels.TextInk()
    ink.set(color, alpha: 255, contrast: contrast)
    for g in p.glyphs {
      let px = floor(g.x)
      let quarter = GlyphCache.quarter(g.x)
      // A pen that rounds up to the next whole pixel's quarter 0.
      let whole = quarter == 0 && g.x - Double(px) > 0.5 ? px + 1 : px
      let baseline = Int(g.y + 0.5)
      guard let r = cache.coverage(font, fontID: fontID, glyph: g.glyph, pixelsPerEm: size, quarter: quarter) else {
        continue
      }
      let atlasWidth = cache.coverage.width, x0 = whole + Int(r.left)
      cache.coverage.pixels.withUnsafeBufferPointer { atlas in
        for row in 0..<Int(r.height) {
          unsafe blendText(row: baseline - Int(r.top) + row, x0, x0 + Int(r.width),
                           coverage: atlas.baseAddress! + (Int(r.y) + row) * atlasWidth + Int(r.x), ink: &ink)
        }
      }
    }
  }

  /// A paragraph's glyphs from their distance fields, at any size: each
  /// pixel's coverage from the field's median distance there.
  public mutating func drawFields(_ p: Paragraph, size: Double, color: UInt32, font: Font, fontID: UInt32,
                                  cache: inout GlyphCache)
  {
    let texelsPerPixel = Double(cache.fieldSize) / size
    for g in p.glyphs {
      guard let r = cache.field(font, fontID: fontID, glyph: g.glyph), r.width > 1, r.height > 1 else { continue }
      // The field's box on the canvas: texel (0, 0)'s corner at the pen
      // plus left, minus top (scaled).
      let x0 = g.x + Double(r.left) / texelsPerPixel, y0 = g.y - Double(r.top) / texelsPerPixel
      let x1 = x0 + Double(r.width) / texelsPerPixel, y1 = y0 + Double(r.height) / texelsPerPixel
      let range = cache.fieldRange
      for py in max(0, floor(y0))..<min(height, ceil(y1)) {
        for px in max(0, floor(x0))..<min(width, ceil(x1)) {
          // The pixel's centre in texels.
          let u = (Double(px) + 0.5 - x0) * texelsPerPixel - 0.5
          let v = (Double(py) + 0.5 - y0) * texelsPerPixel - 0.5
          let iu = floor(u), iv = floor(v)
          let fu = u - Double(iu), fv = v - Double(iv)
          func texel(_ i: Int, _ j: Int, _ c: Int) -> Double {
            let ci = min(max(i, 0), Int(r.width) - 1), cj = min(max(j, 0), Int(r.height) - 1)
            return Double(cache.fields.pixels[((Int(r.y) + cj) * cache.fields.width + Int(r.x) + ci) * 4 + c])
          }
          func sample(_ c: Int) -> Double {
            (texel(iu, iv, c) * (1 - fu) + texel(iu + 1, iv, c) * fu) * (1 - fv)
              + (texel(iu, iv + 1, c) * (1 - fu) + texel(iu + 1, iv + 1, c) * fu) * fv
          }
          let a = sample(0), b = sample(1), c = sample(2)
          let median = max(min(a, b), min(max(a, b), c))
          // Texels to pixels: inside by `d` pixels covers d + 1/2 of this
          // one, clamped.
          let d = (median / 255 - 0.5) * range / texelsPerPixel
          let coverage = d + 0.5
          blendText(px, py, color, coverage <= 0 ? 0 : coverage >= 1 ? 255 : Int(coverage * 255 + 0.5))
        }
      }
    }
  }
}

/// What a renderer draws on: a Canvas, or a window's own buffer.
public protocol PixelTarget {
  var width: Int { get }
  var height: Int { get }
  var contrast: TextContrast { get set }
  mutating func blend(_ x: Int, _ y: Int, _ color: UInt32, _ coverage: Int)
  mutating func blendText(_ x: Int, _ y: Int, _ color: UInt32, _ coverage: Int, alpha: UInt32)
  /// `blend` at each pixel of [x0, x1) in row `y`, through pixelkernels(2).
  mutating func blend(row y: Int, _ x0: Int, _ x1: Int, _ color: UInt32, _ coverage: Int)
  /// `blendText` at each pixel of [x0, x1) in row `y`, the coverage of
  /// pixel x0 + i at `coverage[i]`, in `ink` (its colour, alpha and
  /// contrast set by the caller).
  mutating func blendText(row y: Int, _ x0: Int, _ x1: Int, coverage: UnsafePointer<UInt8>,
                          ink: inout PixelKernels.TextInk)
}

extension Canvas: PixelTarget {}

/// Pixels drawn in place, as a Canvas's are: a window's buffer, which Kit
/// draws its frames into rather than into a canvas it then copies (D124:
/// a canvas was a third frame a window, 4 MB at 1280×820). Its pixel
/// (`x0`, `y0`) is the first of `base`, rows `stride` pixels apart, and
/// drawing lands only in [`x0`, `width`) by [`y0`, `height`): a menu's
/// popup is the window's pixels from its corner.
@safe public struct PixelView: PixelTarget {
  let base: UnsafeMutablePointer<UInt32>
  let stride: Int
  public let x0: Int, y0: Int
  public let width: Int
  public let height: Int
  public var contrast = TextContrast.standard

  /// `base` must hold `stride` pixels a row for `height - y0` rows while
  /// the view is drawn on.
  @unsafe public init(_ base: UnsafeMutablePointer<UInt32>, stride: Int, x0: Int = 0, y0: Int = 0, width: Int,
                      height: Int) {
    unsafe self.base = base
    self.stride = stride
    self.x0 = x0
    self.y0 = y0
    self.width = width
    self.height = height
  }

  @inline(__always) func at(_ x: Int, _ y: Int) -> UnsafeMutablePointer<UInt32> {
    unsafe base + (y - y0) * stride + (x - x0)
  }

  @inline(__always) public mutating func blend(_ x: Int, _ y: Int, _ color: UInt32, _ coverage: Int) {
    guard coverage > 0, x >= x0, y >= y0, x < width, y < height else { return }
    let p = unsafe at(x, y)
    unsafe p.pointee = Light.over(color, unsafe p.pointee, coverage: UInt32(min(coverage, 255)))
  }

  @inline(__always) public mutating func blendText(_ x: Int, _ y: Int, _ color: UInt32, _ coverage: Int,
                                                  alpha: UInt32 = 255)
  {
    guard coverage > 0, x >= x0, y >= y0, x < width, y < height else { return }
    let p = unsafe at(x, y)
    unsafe p.pointee = Light.overText(color, unsafe p.pointee, coverage: coverage, alpha: alpha, contrast: contrast)
  }

  public mutating func blend(row y: Int, _ x0: Int, _ x1: Int, _ color: UInt32, _ coverage: Int) {
    let left = max(x0, self.x0), right = min(x1, width)
    guard coverage > 0, y >= self.y0, y < height, left < right else { return }
    unsafe PixelKernels.over(color, coverage: UInt32(min(coverage, 255)), at(left, y), right - left)
  }

  public mutating func blendText(row y: Int, _ x0: Int, _ x1: Int, coverage: UnsafePointer<UInt8>,
                                 ink: inout PixelKernels.TextInk)
  {
    let left = max(x0, self.x0), right = min(x1, width)
    guard y >= self.y0, y < height, left < right else { return }
    unsafe PixelKernels.overText(&ink, coverage: coverage + (left - x0), at(left, y), right - left)
  }

  /// [x0, x1) by [y0, y1) of `color`, within the view.
  public mutating func fill(x0: Int, y0: Int, x1: Int, y1: Int, _ color: UInt32) {
    let left = max(x0, self.x0), right = min(x1, width)
    guard left < right else { return }
    for y in max(y0, self.y0)..<max(max(y0, self.y0), min(y1, height)) {
      unsafe PixelKernels.fill(at(left, y), right - left, color)
    }
  }
}

func floor(_ v: Double) -> Int {
  let i = Int(v)
  return Double(i) > v ? i - 1 : i
}

func ceil(_ v: Double) -> Int {
  let i = Int(v)
  return Double(i) < v ? i + 1 : i
}
