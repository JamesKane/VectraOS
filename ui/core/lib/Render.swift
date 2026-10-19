// SPDX-License-Identifier: BSD-3-Clause

// Drawing a display list on the CPU (M6i): the reference the GPU's shader
// (part 5) is held to, and what a program without a GPU shows. A shape is
// drawn from its signed distance at each pixel's centre (negative inside):
// coverage is 1/2 - d, clamped, which is exact along a straight edge and
// close at a corner; the border is the band within `border` of the edge;
// the glow, drawn under the whole shape, fades as (1 - d/glow)^2 past it. Glyphs
// come from the glyph cache's atlases. Text set by TextLayout becomes
// glyph quads here: coverage at text sizes, distance fields from
// `fieldSize` pixels an em up.

import GlyphAtlas
import MSDF
import OpenType
import TextLayout

public enum Shapes {
  static let sqrt2 = 1.4142135623730951

  static func length(_ x: Double, _ y: Double) -> Double { DistanceFieldGenerator.squareRoot(x * x + y * y) }

  /// The signed distance from (px, py) to a rectangle with rounded
  /// corners (radius `r`): negative inside.
  public static func rounded(_ px: Double, _ py: Double, x: Double, y: Double, width: Double, height: Double,
                             radius: Double) -> Double
  {
    let hx = width / 2, hy = height / 2
    let r = max(0, min(radius, min(hx, hy)))
    let qx = abs(px - (x + hx)) - hx + r, qy = abs(py - (y + hy)) - hy + r
    return length(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
  }

  /// The signed distance to a rectangle with its corners cut at 45° by
  /// `cut` pixels along each side.
  public static func chamfered(_ px: Double, _ py: Double, x: Double, y: Double, width: Double, height: Double,
                               cut: Double) -> Double
  {
    cutBox(px, py, x: x, y: y, width: width, height: height, radius: 0, cuts: (cut, cut, cut, cut))
  }

  /// The signed distance to a rectangle with rounded corners (radius
  /// `radius`), any corner cut at 45° by its `cuts` (top left, top right,
  /// bottom right, bottom left; 0 for none).
  public static func cutBox(_ px: Double, _ py: Double, x: Double, y: Double, width: Double, height: Double,
                         radius: Double, cuts: (Double, Double, Double, Double)) -> Double
  {
    var d = rounded(px, py, x: x, y: y, width: width, height: height, radius: radius)
    let limit = min(width, height) / 2
    // Each cut is the half-plane past the line joining the points `k`
    // along the two sides from the corner.
    func plane(_ k: Double, _ cx: Double, _ cy: Double, _ sx: Double, _ sy: Double) {
      guard k > 0 else { return }
      let kk = min(k, limit)
      // Inward from corner (cx, cy): sx, sy are +1 or -1 into the box.
      let u = (px - cx) * sx, v = (py - cy) * sy
      d = max(d, (kk - u - v) / sqrt2)
    }
    plane(cuts.0, x, y, 1, 1)
    plane(cuts.1, x + width, y, -1, 1)
    plane(cuts.2, x + width, y + height, -1, -1)
    plane(cuts.3, x, y + height, 1, -1)
    return d
  }

  /// A quad's shape's signed distance.
  static func distance(_ q: UIQuad, _ px: Double, _ py: Double) -> Double {
    let x = Double(q.x), y = Double(q.y), w = Double(q.width), h = Double(q.height)
    if q.cuts == 0 { return rounded(px, py, x: x, y: y, width: w, height: h, radius: Double(q.corner)) }
    return cutBox(px, py, x: x, y: y, width: w, height: h, radius: Double(q.corner),
               cuts: (Double(q.cut(0)), Double(q.cut(1)), Double(q.cut(2)), Double(q.cut(3))))
  }
}

/// A colour's channels, and its alpha.
@inline(__always) func alpha(_ c: UInt32) -> Int { Int(c >> 24) }

/// Two ARGB colours mixed, `t` (0-1) of the second.
func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
  func ch(_ s: UInt32) -> UInt32 {
    let x = Double((a >> s) & 0xFF), y = Double((b >> s) & 0xFF)
    return UInt32(x + (y - x) * t + 0.5) << s
  }
  return ch(24) | ch(16) | ch(8) | ch(0)
}

public struct CPURenderer: Sendable {
  public init() {}

  /// The list drawn onto `canvas`, its glyphs from `cache`, each quad
  /// within its clip.
  public func render(_ list: DisplayList, cache: GlyphCache, images: ImageCache = ImageCache(size: 16),
                     into canvas: inout Canvas, region: (x0: Int, y0: Int, x1: Int, y1: Int)? = nil)
  {
    var c = 0
    // Nothing outside `region` is drawn (M6m: a frame's damage).
    let limit = region.map { (max($0.x0, 0), max($0.y0, 0), min($0.x1, canvas.width), min($0.y1, canvas.height)) }
      ?? (0, 0, canvas.width, canvas.height)
    var clip = Clip(x0: limit.0, y0: limit.1, x1: limit.2, y1: limit.3)
    for (i, q) in list.quads.enumerated() {
      while c < list.clips.count && list.clips[c].first <= i {
        let r = list.clips[c]
        func px(_ v: Float, _ limit: Int) -> Int { v <= 0 ? 0 : v >= Float(limit) ? limit : Int(v + 0.5) }
        clip = Clip(x0: max(px(r.x0, canvas.width), limit.0), y0: max(px(r.y0, canvas.height), limit.1),
                    x1: min(px(r.x1, canvas.width), limit.2), y1: min(px(r.y1, canvas.height), limit.3))
        c += 1
      }
      guard clip.x0 < clip.x1 && clip.y0 < clip.y1 else { continue }
      switch q.kind {
      case UIQuad.shape: shape(q, clip, &canvas)
      case UIQuad.coverageGlyph: coverageGlyph(q, cache, clip, &canvas)
      case UIQuad.fieldGlyph: fieldGlyph(q, cache, clip, &canvas)
      case UIQuad.image: image(q, images.atlas, clip, &canvas)
      default: break
      }
    }
  }

  /// Where drawing may land, in pixels: [x0, x1) by [y0, y1).
  struct Clip {
    var x0: Int, y0: Int, x1: Int, y1: Int
  }

  func shape(_ q: UIQuad, _ clip: Clip, _ canvas: inout Canvas) {
    let reach = Double(max(q.glow, 0)) + 1
    let x0 = max(clip.x0, Int(Double(q.x) - reach)), y0 = max(clip.y0, Int(Double(q.y) - reach))
    let x1 = min(clip.x1, Int(Double(q.x + q.width) + reach) + 1)
    let y1 = min(clip.y1, Int(Double(q.y + q.height) + reach) + 1)
    guard x0 < x1, y0 < y1 else { return }
    let glow = Double(q.glow), border = Double(q.border)
    for py in y0..<y1 {
      for px in x0..<x1 {
        let d = Shapes.distance(q, Double(px) + 0.5, Double(py) + 0.5)
        let outer = min(max(0.5 - d, 0), 1)
        // Within the border: its colour; inside it: the fill.
        let inner = border > 0 ? min(max(0.5 - (d + border), 0), 1) : 1
        let color = border > 0 ? mix(q.stroke, q.fill, inner) : q.fill
        // The glow, under the whole shape (as CSS's drop-shadow is): full
        // within it, fading past its edge; not drawn where the shape hides
        // it.
        if glow > 0 && d < glow && alpha(q.glowColor) > 0 && !(outer >= 1 && alpha(color) == 255) {
          let t = 1 - max(d, 0) / glow
          canvas.blend(px, py, q.glowColor & 0xFF_FFFF, Int(Double(alpha(q.glowColor)) * t * t + 0.5))
        }
        guard outer > 0 else { continue }
        let a = Double(alpha(color)) * outer
        canvas.blend(px, py, color & 0xFF_FFFF, Int(a + 0.5))
      }
    }
  }

  /// A region of the colour atlas, texel for pixel.
  func image(_ q: UIQuad, _ atlas: Atlas, _ clip: Clip, _ canvas: inout Canvas) {
    let a = alpha(q.fill)
    let gx = Int(q.x), gy = Int(q.y)
    // (A quad wholly outside the clip, as a scrolled box's, draws nothing.)
    let rows = max(0, clip.y0 - gy)..<max(max(0, clip.y0 - gy), min(Int(q.atlasHeight), clip.y1 - gy))
    let cols = max(0, clip.x0 - gx)..<max(max(0, clip.x0 - gx), min(Int(q.atlasWidth), clip.x1 - gx))
    for row in rows {
      for col in cols {
        let i = ((Int(q.atlasY) + row) * atlas.width + Int(q.atlasX) + col) * 4
        let c = UInt32(atlas.pixels[i]) << 16 | UInt32(atlas.pixels[i + 1]) << 8 | UInt32(atlas.pixels[i + 2])
        canvas.blend(gx + col, gy + row, c, (Int(atlas.pixels[i + 3]) * a + 127) / 255)
      }
    }
  }

  func coverageGlyph(_ q: UIQuad, _ cache: GlyphCache, _ clip: Clip, _ canvas: inout Canvas) {
    let atlas = cache.coverage
    let a = alpha(q.fill)
    let gx = Int(q.x), gy = Int(q.y)
    let rows = max(0, clip.y0 - gy)..<max(max(0, clip.y0 - gy), min(Int(q.atlasHeight), clip.y1 - gy))
    let cols = max(0, clip.x0 - gx)..<max(max(0, clip.x0 - gx), min(Int(q.atlasWidth), clip.x1 - gx))
    for row in rows {
      for col in cols {
        let c = Int(atlas.pixels[(Int(q.atlasY) + row) * atlas.width + Int(q.atlasX) + col])
        canvas.blend(gx + col, gy + row, q.fill & 0xFF_FFFF, (c * a + 127) / 255)
      }
    }
  }

  func fieldGlyph(_ q: UIQuad, _ cache: GlyphCache, _ clip: Clip, _ canvas: inout Canvas) {
    let atlas = cache.fields
    let texels = Double(q.scale)  // texels per pixel
    let range = cache.fieldRange
    let w = Int(q.atlasWidth), h = Int(q.atlasHeight)
    guard w > 1, h > 1 else { return }
    let x0 = Double(q.x), y0 = Double(q.y)
    let px0 = max(clip.x0, Int(x0)), py0 = max(clip.y0, Int(y0))
    let px1 = min(clip.x1, Int(x0 + Double(q.width)) + 1), py1 = min(clip.y1, Int(y0 + Double(q.height)) + 1)
    guard px0 < px1, py0 < py1 else { return }
    let a = Double(alpha(q.fill))
    for py in py0..<py1 {
      for px in px0..<px1 {
        let u = (Double(px) + 0.5 - x0) * texels - 0.5, v = (Double(py) + 0.5 - y0) * texels - 0.5
        let iu = Int(u + 1) - 1, iv = Int(v + 1) - 1
        let fu = u - Double(iu), fv = v - Double(iv)
        func texel(_ i: Int, _ j: Int, _ c: Int) -> Double {
          let ci = min(max(i, 0), w - 1), cj = min(max(j, 0), h - 1)
          return Double(atlas.pixels[((Int(q.atlasY) + cj) * atlas.width + Int(q.atlasX) + ci) * 4 + c])
        }
        func sample(_ c: Int) -> Double {
          (texel(iu, iv, c) * (1 - fu) + texel(iu + 1, iv, c) * fu) * (1 - fv)
            + (texel(iu, iv + 1, c) * (1 - fu) + texel(iu + 1, iv + 1, c) * fu) * fv
        }
        let r = sample(0), g = sample(1), b = sample(2)
        let median = max(min(r, g), min(max(r, g), b))
        let coverage = min(max((median / 255 - 0.5) * range / texels + 0.5, 0), 1)
        canvas.blend(px, py, q.fill & 0xFF_FFFF, Int(coverage * a + 0.5))
      }
    }
  }
}

extension DisplayList {
  /// A paragraph's glyphs as quads, `color` (ARGB): coverage below
  /// `fieldSize` pixels an em, distance fields from it up.
  public mutating func append(_ p: Paragraph, size: Double, color: UInt32, font: Font, fontID: UInt32,
                              cache: inout GlyphCache, fieldSize: Double = 32)
  {
    for g in p.glyphs {
      append(glyph: g.glyph, x: g.x, y: g.y, size: size, color: color, font: font, fontID: fontID, cache: &cache,
             fieldSize: fieldSize)
    }
  }

  /// One glyph, its origin at (x, y) in pixels (the pen and the baseline).
  public mutating func append(glyph: Int, x: Double, y: Double, size: Double, color: UInt32, font: Font, fontID: UInt32,
                              cache: inout GlyphCache, fieldSize: Double = 32)
  {
    if size >= fieldSize {
      guard let r = cache.field(font, fontID: fontID, glyph: glyph), r.width > 1 else { return }
      let texels = Double(cache.fieldSize) / size
      append(UIQuad(x: Float(x + Double(r.left) / texels), y: Float(y - Double(r.top) / texels),
                    width: Float(Double(r.width) / texels), height: Float(Double(r.height) / texels),
                    kind: UIQuad.fieldGlyph, fill: color, scale: Float(texels), atlasX: r.x, atlasY: r.y,
                    atlasWidth: r.width, atlasHeight: r.height))
    } else {
      let quarter = GlyphCache.quarter(x)
      let whole0 = Int(x + 1e6) - 1_000_000  // floor for any sane x
      let whole = quarter == 0 && x - Double(whole0) > 0.5 ? whole0 + 1 : whole0
      guard let r = cache.coverage(font, fontID: fontID, glyph: glyph, pixelsPerEm: size, quarter: quarter), r.width > 0
      else { return }
      let baseline = Int(y + 0.5)
      append(UIQuad(x: Float(whole + Int(r.left)), y: Float(baseline - Int(r.top)), width: Float(r.width),
                    height: Float(r.height), kind: UIQuad.coverageGlyph, fill: color, atlasX: r.x, atlasY: r.y,
                    atlasWidth: r.width, atlasHeight: r.height))
    }
  }

  /// A shape in a style: its fill, border, corners and glow.
  public mutating func append(shape x: Float, _ y: Float, _ width: Float, _ height: Float, style: Style) {
    append(UIQuad(x: x, y: y, width: width, height: height, kind: UIQuad.shape, fill: style.fill, corner: style.radius,
                  cuts: style.cuts, border: style.border, stroke: style.stroke, glow: style.glow,
                  glowColor: style.glowColor))
  }
}
