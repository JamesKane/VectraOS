// SPDX-License-Identifier: BSD-3-Clause

// Drawing a display list on the CPU (M6i): the reference the GPU's shader
// (part 5) is held to, and what a program without a GPU shows. A shape is
// drawn from its signed distance at each pixel's centre (negative inside):
// coverage is 1/2 - d, clamped, which is exact along a straight edge and
// close at a corner; the border is the band within `border` of the edge;
// the glow, drawn under the whole shape, fades as (1 - d/glow)^2 past it. Glyphs
// come from the glyph cache's atlases. Text set by TextLayout becomes
// glyph quads here: coverage at text sizes, distance fields from
// `fieldSize` pixels an em up. A material takes its colour from its own
// rule at each pixel and its coverage from the shape's distance.

import GlyphAtlas
import Light
import MSDF
import OpenType
import PixelKernels
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

  /// The unit vector at `degrees` (0 along x, 90 along y, which points
  /// down): exact at each multiple of 45°, and within 1e-9 between, with
  /// no libm (tier 0 links without it).
  public static func direction(_ degrees: Double) -> (Double, Double) {
    var a = degrees - 360 * Double(Int(degrees / 360))
    if a < 0 { a += 360 }
    let octant = Int(a / 45)
    let r = (a - Double(octant) * 45) * 3.141592653589793 / 180  // 0 ..< π/4
    if r == 0 {
      let h = 1 / sqrt2
      switch octant % 8 {
      case 0: return (1, 0)
      case 1: return (h, h)
      case 2: return (0, 1)
      case 3: return (-h, h)
      case 4: return (-1, 0)
      case 5: return (-h, -h)
      case 6: return (0, -1)
      default: return (h, -h)
      }
    }
    let r2 = r * r
    let s = r * (1 - r2 / 6 * (1 - r2 / 20 * (1 - r2 / 42 * (1 - r2 / 72 * (1 - r2 / 110)))))
    let c = 1 - r2 / 2 * (1 - r2 / 12 * (1 - r2 / 30 * (1 - r2 / 56 * (1 - r2 / 90))))
    // Rotate (c, s) by the octant's angle.
    let (bx, by) = direction(Double(octant) * 45)
    return (c * bx - s * by, c * by + s * bx)
  }

  /// The pixels of row `py` whose distance is below -1/2 - `inset`,
  /// fully inside the shape and its band of `inset`: those whose centres
  /// lie `s` or more from each side, `s` twice past the band and beyond
  /// the corners' radius and cuts, where the distance is at most -s/√2.
  /// That leaves most of a pixel to spare, so no rounding moves one
  /// across; the pixels it leaves out are judged by their distance.
  static func interior(_ q: UIQuad, row py: Int, inset: Double) -> Range<Int> {
    var corner = max(Double(q.corner), 0)
    if q.cuts != 0 { for i in 0..<4 { corner = max(corner, Double(q.cut(i))) } }
    let s = corner + 2 * (inset + 1)
    let x = Double(q.x), y = Double(q.y), cy = Double(py) + 0.5
    guard cy >= y + s, cy <= y + Double(q.height) - s else { return 0..<0 }
    // The first pixel whose centre is s past the left, and one past the
    // last s before the right.
    let lo = -floor(-(x + s - 0.5)), hi = floor(x + Double(q.width) - s - 0.5) + 1
    return lo < hi ? lo..<hi : 0..<0
  }

  /// The pixels of row `py` where the distance, anywhere within `margin`
  /// of their centres, depends on y alone: those nearer the top or bottom
  /// than a side or a corner. There `rounded`'s qx is at most qy and 0,
  /// so each of them takes the same steps from the same qy to the same
  /// distance; 1/64 of a pixel to spare keeps rounding from moving one
  /// across. None for a shape with cuts.
  static func level(_ q: UIQuad, row py: Int, margin m: Double) -> Range<Int> {
    guard q.cuts == 0 else { return 0..<0 }
    let hx = Double(q.width) / 2, hy = Double(q.height) / 2
    let r = max(0, min(Double(q.corner), min(hx, hy)))
    let cx = Double(q.x) + hx, cy = Double(q.y) + hy
    // The least qy within the margin, and how far from the centre qx
    // stays below it and 0.
    let qy = abs(Double(py) + 0.5 - cy) - m - hy + r
    let reach = hx - r - m - 1.0 / 64 + min(qy, 0)
    guard reach >= 0 else { return 0..<0 }
    let lo = -floor(-(cx - reach - 0.5)), hi = floor(cx + reach - 0.5) + 1
    return lo < hi ? lo..<hi : 0..<0
  }

  /// A shape's distances down its sides, kept by column. Where a pixel,
  /// and all within `margin` of it, is nearer a side than the top, the
  /// bottom or a corner, `rounded`'s qy is at most qx and 0 and the
  /// distance depends on x alone (`level` turned on its side), so one
  /// found in a column serves the rest of it there. The 32 columns at
  /// each end of [x0, x1) are kept. None for a shape with cuts.
  struct Sides {
    let cx: Double, cy: Double, hx: Double, hy: Double, r: Double, margin: Double
    let x0: Int, x1: Int, on: Bool
    /// Each column's distance, and a bevel's nx; NaN until found.
    var kept = InlineArray<64, (d: Double, nx: Double)>(repeating: (.nan, 0))

    init(_ q: UIQuad, _ x0: Int, _ x1: Int, margin: Double) {
      hx = Double(q.width) / 2
      hy = Double(q.height) / 2
      r = max(0, min(Double(q.corner), min(hx, hy)))
      cx = Double(q.x) + hx
      cy = Double(q.y) + hy
      self.margin = margin
      self.x0 = x0
      self.x1 = x1
      on = q.cuts == 0
    }

    /// Where pixel (px, py)'s column is kept, if it is down a side.
    func slot(_ px: Int, _ py: Int) -> Int? {
      guard on else { return nil }
      // The least qx and the greatest qy within the margin.
      let qx = abs(Double(px) + 0.5 - cx) - margin - hx + r
      guard abs(Double(py) + 0.5 - cy) + margin - hy + r + 1.0 / 64 <= min(qx, 0) else { return nil }
      let i = px - x0, j = x1 - 1 - px
      return i < 32 ? i : j < 32 ? 32 + j : nil
    }
  }

  static func floor(_ v: Double) -> Int {
    let i = Int(v)
    return Double(i) > v ? i - 1 : i
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

/// Two ARGB colours mixed, `t` (0-1) of the second, in light.
func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
  t <= 0 ? a : t >= 1 ? b : Light.mix(a, b, UInt32(t * 255 + 0.5))
}

public struct CPURenderer: Sendable {
  public init() {}

  /// The list drawn onto `canvas`, its glyphs from `cache`, each quad
  /// within its clip.
  public func render(_ list: DisplayList, cache: GlyphCache, images: ImageCache = ImageCache(size: 16),
                     into canvas: inout Canvas, region: (x0: Int, y0: Int, x1: Int, y1: Int)? = nil)
  {
    draw(list, cache, images, &canvas, region)
  }

  /// The same, drawn in place: a window's buffer (Kit's frames).
  public func render(_ list: DisplayList, cache: GlyphCache, images: ImageCache = ImageCache(size: 16),
                     into view: inout PixelView, region: (x0: Int, y0: Int, x1: Int, y1: Int)? = nil)
  {
    draw(list, cache, images, &view, region)
  }

  /// Both renders, specialized here for each target.
  func draw<C: PixelTarget>(_ list: DisplayList, _ cache: GlyphCache, _ images: ImageCache, _ canvas: inout C,
                            _ region: (x0: Int, y0: Int, x1: Int, y1: Int)?)
  {
    var c = 0
    // Nothing outside `region` is drawn (M6m: a frame's damage).
    let limit = region.map { (max($0.x0, 0), max($0.y0, 0), min($0.x1, canvas.width), min($0.y1, canvas.height)) }
      ?? (0, 0, canvas.width, canvas.height)
    var clip = Clip(x0: limit.0, y0: limit.1, x1: limit.2, y1: limit.3)
    // Kept through the frame: text on one ground blends each coverage once.
    var ink = PixelKernels.TextInk()
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
      case UIQuad.coverageGlyph: coverageGlyph(q, cache, clip, &canvas, &ink)
      case UIQuad.fieldGlyph: fieldGlyph(q, cache, clip, &canvas)
      case UIQuad.image: image(q, images.atlas, clip, &canvas)
      case UIQuad.gradient, UIQuad.bevel, UIQuad.stripes, UIQuad.checks, UIQuad.dots: material(q, clip, &canvas)
      default: break
      }
    }
  }

  /// Where drawing may land, in pixels: [x0, x1) by [y0, y1).
  struct Clip {
    var x0: Int, y0: Int, x1: Int, y1: Int
  }

  func shape<C: PixelTarget>(_ q: UIQuad, _ clip: Clip, _ canvas: inout C) {
    let reach = Double(max(q.glow, 0)) + 1
    let x0 = max(clip.x0, Int(Double(q.x) - reach)), y0 = max(clip.y0, Int(Double(q.y) - reach))
    let x1 = min(clip.x1, Int(Double(q.x + q.width) + reach) + 1)
    let y1 = min(clip.y1, Int(Double(q.y + q.height) + reach) + 1)
    guard x0 < x1, y0 < y1 else { return }
    let glow = Double(q.glow), border = Double(q.border)
    // Inside the border the fill is the same at every pixel, a span, but
    // for a glow under a fill it shows through.
    let spans = alpha(q.fill) == 255 || glow <= 0 || alpha(q.glowColor) == 0
    func blend(_ px0: Int, _ px1: Int, _ py: Int, _ color: UInt32, _ coverage: Int) {
      if px1 - px0 == 1 { canvas.blend(px0, py, color, coverage) } else { canvas.blend(row: py, px0, px1, color, coverage) }
    }
    // Pixels px0 to px1 of row py, at distance d.
    func pixels(_ px0: Int, _ px1: Int, _ py: Int, _ d: Double) {
      let outer = min(max(0.5 - d, 0), 1)
      // Within the border: its colour; inside it: the fill.
      let inner = border > 0 ? min(max(0.5 - (d + border), 0), 1) : 1
      let color = border > 0 ? mix(q.stroke, q.fill, inner) : q.fill
      // The glow, under the whole shape (as CSS's drop-shadow is): full
      // within it, fading past its edge; not drawn where the shape hides
      // it.
      if glow > 0 && d < glow && alpha(q.glowColor) > 0 && !(outer >= 1 && alpha(color) == 255) {
        let t = 1 - max(d, 0) / glow
        blend(px0, px1, py, q.glowColor & 0xFF_FFFF, Int(Double(alpha(q.glowColor)) * t * t + 0.5))
      }
      guard outer > 0 else { return }
      let a = Double(alpha(color)) * outer
      blend(px0, px1, py, color & 0xFF_FFFF, Int(a + 0.5))
    }
    var sides = Shapes.Sides(q, x0, x1, margin: 0)
    for py in y0..<y1 {
      let inside = spans ? Shapes.interior(q, row: py, inset: border).clamped(to: x0..<x1) : x1..<x1
      // Where the distance is the row's, it is found once; down the
      // sides, once a column.
      let level = Shapes.level(q, row: py, margin: 0).clamped(to: x0..<x1)
      let sy = Double(py) + 0.5
      var px = x0
      while px < x1 {
        if inside.contains(px) {
          canvas.blend(row: py, px, inside.upperBound, q.fill & 0xFF_FFFF, alpha(q.fill))
          px = inside.upperBound
        } else if level.contains(px) {
          let end = px < inside.lowerBound ? min(level.upperBound, inside.lowerBound) : level.upperBound
          pixels(px, end, py, Shapes.distance(q, Double(px) + 0.5, sy))
          px = end
        } else if let i = sides.slot(px, py) {
          if sides.kept[i].d.isNaN { sides.kept[i].d = Shapes.distance(q, Double(px) + 0.5, sy) }
          pixels(px, px + 1, py, sides.kept[i].d)
          px += 1
        } else {
          pixels(px, px + 1, py, Shapes.distance(q, Double(px) + 0.5, sy))
          px += 1
        }
      }
    }
  }

  /// A material over a shape's area: each pixel's colour from the
  /// material, its coverage the shape's (for a bevel, the band's).
  func material<C: PixelTarget>(_ q: UIQuad, _ clip: Clip, _ canvas: inout C) {
    let x0 = max(clip.x0, Int(q.x)), y0 = max(clip.y0, Int(q.y))
    let x1 = min(clip.x1, Int(q.x + q.width) + 1), y1 = min(clip.y1, Int(q.y + q.height) + 1)
    guard x0 < x1, y0 < y1 else { return }
    let (dx, dy) = Shapes.direction(Double(q.scale))
    let cx = Double(q.x) + Double(q.width) / 2, cy = Double(q.y) + Double(q.height) / 2
    let span = abs(Double(q.width) * dx) + abs(Double(q.height) * dy)
    let band = Double(q.border)
    // A pattern's half period, in whole pixels, from the box's corner.
    let half = max(1, Int(q.border) / 2), ox = Int(q.x), oy = Int(q.y)
    func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
    // A gradient's step at a pixel's centre: its mix (0-255), or -1 and
    // 256 at and past its ends, where it is its two colours as they are.
    func step(_ sx: Double, _ sy: Double) -> Int {
      let t = span > 0 ? 0.5 + ((sx - cx) * dx + (sy - cy) * dy) / span : 0
      return t <= 0 ? -1 : t >= 1 ? 256 : Int(t * 255 + 0.5)
    }
    // Each step's colour kept once mixed (bit 32 set), as a gradient across
    // a box meets its steps again in each row.
    var shaded = InlineArray<256, UInt64>(repeating: 0)
    func shade(_ step: Int) -> UInt32 {
      guard step >= 0 else { return q.fill }
      guard step <= 255 else { return q.stroke }
      if shaded[step] == 0 { shaded[step] = 1 << 32 | UInt64(Light.mix(q.fill, q.stroke, UInt32(step))) }
      return UInt32(truncatingIfNeeded: shaded[step])
    }
    // Along a row's level pixels (Shapes.level) the distance is the
    // row's, found once, and down the sides (Shapes.Sides) the column's;
    // a bevel's edge there faces up or down, or left or right, the same
    // a quarter pixel to either side as at the centre, so nx or ny is 0.
    let e = 0.25
    typealias Known = (d: Double, nx: Double, ny: Double)
    // The colour and coverage of pixel (px, py), or nil for none.
    // `inside`: within the shape's interior (and a bevel's band), where
    // the coverage is whole and the distance isn't needed; `known`: its
    // distance and a bevel's nx and ny, found once for its row or column.
    func ink(_ px: Int, _ py: Int, inside: Bool, _ known: Known?) -> (UInt32, Int)? {
      let sx = Double(px) + 0.5, sy = Double(py) + 0.5
      let d = inside ? -Double.infinity : known?.d ?? Shapes.distance(q, sx, sy)
      var cover = inside ? 1 : min(max(0.5 - d, 0), 1)
      guard cover > 0 else { return nil }
      let color: UInt32
      switch q.kind {
      case UIQuad.gradient:
        color = shade(step(sx, sy))
      case UIQuad.bevel:
        // Inside the band only; lit where the edge's outward normal
        // points up or left (a corner's diagonal is lit, as CSS draws
        // the first of two inset shadows over the second).
        guard !inside else { return nil }
        cover -= min(max(0.5 - (d + band), 0), 1)
        guard cover > 0 else { return nil }
        let nx = known?.nx ?? Shapes.distance(q, sx + e, sy) - Shapes.distance(q, sx - e, sy)
        let ny = known?.ny ?? Shapes.distance(q, sx, sy + e) - Shapes.distance(q, sx, sy - e)
        color = nx + ny <= 0 ? q.fill : q.stroke
      case UIQuad.stripes:
        color = floorDiv((px - ox) - (py - oy), half) & 1 == 0 ? q.fill : q.stroke
      case UIQuad.checks:
        color = (floorDiv(px - ox, half) + floorDiv(py - oy, half)) & 1 == 0 ? q.fill : q.stroke
      default:
        // Dots: a disc half the period across at each cell's centre.
        let period = Double(2 * half)
        let ux = Double(px - ox) + 0.5, uy = Double(py - oy) + 0.5
        let fx = ux - period * Double(floorDiv(Int(ux), 2 * half)) - period / 2
        let fy = uy - period * Double(floorDiv(Int(uy), 2 * half)) - period / 2
        let r = Shapes.length(fx, fy) - period / 4
        color = mix(q.stroke, q.fill, min(max(0.5 + r, 0), 1))
      }
      return (color & 0xFF_FFFF, Int(Double(alpha(color)) * cover + 0.5))
    }
    // A gradient's inside changes colour only where its step does: each
    // run of one step is mixed once and blended as a row.
    func gradient(_ py: Int, _ inside: Range<Int>) {
      let sy = Double(py) + 0.5
      var px = inside.lowerBound
      while px < inside.upperBound {
        let s = step(Double(px) + 0.5, sy)
        var end = px + 1
        while end < inside.upperBound && step(Double(end) + 0.5, sy) == s { end += 1 }
        let color = shade(s)
        canvas.blend(row: py, px, end, color & 0xFF_FFFF, alpha(color))
        px = end
      }
    }
    func pixel(_ px: Int, _ py: Int, inside: Bool, _ known: Known? = nil) {
      if let (color, coverage) = ink(px, py, inside: inside, known) { canvas.blend(px, py, color, coverage) }
    }
    let bevel = q.kind == UIQuad.bevel
    // A bevel's colour, and a gradient's down the box, are the same along
    // a level run: one pixel's, blended as a row.
    let uniform = bevel || (q.kind == UIQuad.gradient && dx == 0)
    var sides = Shapes.Sides(q, x0, x1, margin: bevel ? e : 0)
    for py in y0..<y1 {
      let inside = Shapes.interior(q, row: py, inset: bevel ? band : 0).clamped(to: x0..<x1)
      let level = Shapes.level(q, row: py, margin: bevel ? e : 0).clamped(to: x0..<x1)
      let sy = Double(py) + 0.5
      var row: Known? = nil
      if !level.isEmpty {
        let sx = Double(level.lowerBound) + 0.5
        row = (Shapes.distance(q, sx, sy), 0, bevel ? Shapes.distance(q, sx, sy + e) - Shapes.distance(q, sx, sy - e) : 0)
      }
      var px = x0
      while px < x1 {
        if inside.contains(px) {
          // A bevel draws nothing inside its band.
          if q.kind == UIQuad.gradient { gradient(py, inside) } else if !bevel { for px in inside { pixel(px, py, inside: true) } }
          px = inside.upperBound
        } else if uniform && level.contains(px) {
          let end = px < inside.lowerBound ? min(level.upperBound, inside.lowerBound) : level.upperBound
          if let (color, coverage) = ink(px, py, inside: false, row) { canvas.blend(row: py, px, end, color, coverage) }
          px = end
        } else if level.contains(px) {
          pixel(px, py, inside: false, row)
          px += 1
        } else if let i = sides.slot(px, py) {
          if sides.kept[i].d.isNaN {
            let sx = Double(px) + 0.5
            sides.kept[i] = (Shapes.distance(q, sx, sy),
                             bevel ? Shapes.distance(q, sx + e, sy) - Shapes.distance(q, sx - e, sy) : 0)
          }
          pixel(px, py, inside: false, (sides.kept[i].d, sides.kept[i].nx, 0))
          px += 1
        } else {
          pixel(px, py, inside: false)
          px += 1
        }
      }
    }
  }

  /// A region of the colour atlas, texel for pixel.
  func image<C: PixelTarget>(_ q: UIQuad, _ atlas: Atlas, _ clip: Clip, _ canvas: inout C) {
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

  func coverageGlyph<C: PixelTarget>(_ q: UIQuad, _ cache: GlyphCache, _ clip: Clip, _ canvas: inout C,
                                     _ ink: inout PixelKernels.TextInk)
  {
    let atlas = cache.coverage
    let gx = Int(q.x), gy = Int(q.y)
    let rows = max(0, clip.y0 - gy)..<max(max(0, clip.y0 - gy), min(Int(q.atlasHeight), clip.y1 - gy))
    let cols = max(0, clip.x0 - gx)..<max(max(0, clip.x0 - gx), min(Int(q.atlasWidth), clip.x1 - gx))
    guard !cols.isEmpty else { return }
    ink.set(q.fill, alpha: UInt32(alpha(q.fill)), contrast: canvas.contrast)
    atlas.pixels.withUnsafeBufferPointer { pixels in
      for row in rows {
        let coverage = unsafe pixels.baseAddress! + (Int(q.atlasY) + row) * atlas.width + Int(q.atlasX) + cols.lowerBound
        unsafe canvas.blendText(row: gy + row, gx + cols.lowerBound, gx + cols.upperBound, coverage: coverage,
                                ink: &ink)
      }
    }
  }

  func fieldGlyph<C: PixelTarget>(_ q: UIQuad, _ cache: GlyphCache, _ clip: Clip, _ canvas: inout C) {
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
        canvas.blendText(px, py, q.fill & 0xFF_FFFF, Int(coverage * 255 + 0.5), alpha: UInt32(a))
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
