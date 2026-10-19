// SPDX-License-Identifier: BSD-3-Clause

// The glyph rasterizer (M6h): an outline to a coverage bitmap, each pixel
// the area of it the outline covers (nonzero winding, clamped to one), as
// 0-255. Lines are accumulated exactly as signed areas and covers, a cell
// per pixel (the accumulation in Raph Levien's font-rs, after libart and
// FreeType's "gray" rasterizer); a row's running sum is then the coverage.
// Curves are flattened into lines first, by FreeType's gray rasterizer's
// tests made finer: a quadratic arc is cut in 2^n equal steps until its
// second difference is at most twice `flatness`, and a cubic halved until
// each piece's control points are within 4/3 `flatness` of where a line
// would put them. At the default, 1/128 pixel, every pixel of the test
// fonts' Latin glyphs is within 3 levels of its exact coverage; FreeType
// flattens to about 1/16 pixel (quadratics) and 1/8 (cubics), where a
// small dot becomes a diamond. Points aren't snapped to 1/64 pixel, as
// FreeType's are.
//
// The bitmap is the smallest box of whole pixels holding the outline's
// control box; `left` and `top` place it against the pen position and the
// baseline. Tier 0 links no libm: floors and roundings are done here.

import OpenType

/// A coverage bitmap: rows from the top, a byte a pixel.
public struct Bitmap: Sendable {
  public var width = 0
  public var height = 0
  /// From the pen position to the bitmap's left edge, in pixels.
  public var left = 0
  /// From the baseline up to the bitmap's top edge, in pixels.
  public var top = 0
  /// `width * height` bytes, rows from the top.
  public var pixels: [UInt8] = []

  public init() {}

  public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
}

/// Renders outlines into bitmaps, keeping its working storage (and the
/// caller's bitmap's) from one glyph to the next.
public struct Rasterizer: Sendable {
  /// Each pixel's signed area and cover; a row's running sum is coverage.
  var cells: [Float] = []
  var width = 0
  var height = 0
  /// How far a curve's lines may stray from it, in pixels (about): a
  /// quadratic's are within a quarter of this, as FreeType's are within
  /// 1/16 pixel, and a cubic's within this, as FreeType's within 1/8.
  public var flatness: Float = 1.0 / 128

  public init() {}

  /// Renders an outline in font units, scaled by `scale` (pixels per
  /// unit) and moved by `x`, `y` pixels (a subpixel pen position).
  public mutating func render(_ outline: Outline, scale: Double, x: Double = 0, y: Double = 0,
                              into bitmap: inout Bitmap) {
    func place(_ p: Point) -> Point { Point(p.x * scale + x, p.y * scale + y) }
    let pixels = Outline(contours: outline.contours.map { c in
      Contour(start: place(c.start), segments: c.segments.map { s in
        switch s {
        case .line(let p): .line(place(p))
        case .quad(let c1, let p): .quad(place(c1), place(p))
        case .cubic(let c1, let c2, let p): .cubic(place(c1), place(c2), place(p))
        }
      })
    })
    render(pixels: pixels, into: &bitmap)
  }

  /// Renders an outline already in pixels (y up from the baseline).
  public mutating func render(pixels outline: Outline, into bitmap: inout Bitmap) {
    guard let box = outline.controlBox else {
      bitmap.width = 0
      bitmap.height = 0
      bitmap.left = 0
      bitmap.top = 0
      bitmap.pixels.removeAll(keepingCapacity: true)
      return
    }
    let left = Rasterizer.floor(box.xMin), right = Rasterizer.ceil(box.xMax)
    let bottom = Rasterizer.floor(box.yMin), top = Rasterizer.ceil(box.yMax)
    width = max(1, right - left)
    height = max(1, top - bottom)
    // A spare cell past the last: a line's cover may land just right of
    // the box (the running sum through it is zero).
    let count = width * height + 1
    if cells.count < count {
      cells = [Float](repeating: 0, count: count)
    } else {
      for i in 0..<count { cells[i] = 0 }
    }
    // Into the bitmap's frame: x from its left edge, y down from its top.
    let ox = Double(left), oy = Double(top)
    func frame(_ p: Point) -> (Float, Float) { (Float(p.x - ox), Float(oy - p.y)) }
    for contour in outline.contours {
      var at = frame(contour.start)
      let start = at
      for segment in contour.segments {
        switch segment {
        case .line(let p):
          let to = frame(p)
          line(at, to)
          at = to
        case .quad(let c, let p):
          let c1 = frame(c), to = frame(p)
          quad(at, c1, to)
          at = to
        case .cubic(let c1, let c2, let p):
          let a = frame(c1), b = frame(c2), to = frame(p)
          cubic(at, a, b, to)
          at = to
        }
      }
      line(at, start)
    }
    // The running sum, as 0-255: full coverage is 256, clamped.
    bitmap.width = width
    bitmap.height = height
    bitmap.left = left
    bitmap.top = top
    let n = width * height
    if bitmap.pixels.count != n { bitmap.pixels = [UInt8](repeating: 0, count: n) }
    var sum: Float = 0
    for i in 0..<n {
      sum += cells[i]
      let v = Int(min(abs(sum) * 256, 255))
      bitmap.pixels[i] = UInt8(v)
    }
  }

  /// A quadratic arc, cut into 2^n lines until its second difference is a
  /// quarter pixel or less.
  mutating func quad(_ p0: (Float, Float), _ p1: (Float, Float), _ p2: (Float, Float)) {
    var deviation = max(abs(p0.0 - 2 * p1.0 + p2.0), abs(p0.1 - 2 * p1.1 + p2.1))
    var steps = 1
    while deviation > 2 * flatness && steps < 1 << 16 {
      deviation /= 4
      steps *= 2
    }
    var at = p0
    for i in 1...steps {
      let t = Float(i) / Float(steps), u = 1 - t
      let to = i == steps ? p2 : (u * u * p0.0 + 2 * u * t * p1.0 + t * t * p2.0,
                                  u * u * p0.1 + 2 * u * t * p1.1 + t * t * p2.1)
      line(at, to)
      at = to
    }
  }

  /// A cubic arc, halved (de Casteljau) until each piece's control points
  /// are near enough its chord: |2 p0 - 3 p1 + p3| and |p0 - 3 p2 + 2 p3|
  /// (three times each one's distance from where a straight line would put
  /// it) at most half a pixel, as FreeType's gray rasterizer decides; then
  /// each piece is a line. Halving a cubic's control polygon doesn't make
  /// it fourfold flatter, as it does a quadratic's, so each piece decides.
  mutating func cubic(_ p0: (Float, Float), _ p1: (Float, Float), _ p2: (Float, Float), _ p3: (Float, Float)) {
    typealias P = (Float, Float)
    func mid(_ a: P, _ b: P) -> P { ((a.0 + b.0) * 0.5, (a.1 + b.1) * 0.5) }
    func flat(_ a: P, _ b: P, _ c: P, _ d: P) -> Bool {
      let limit = 4 * flatness
      return abs(2 * a.0 - 3 * b.0 + d.0) <= limit && abs(2 * a.1 - 3 * b.1 + d.1) <= limit
        && abs(a.0 - 3 * c.0 + 2 * d.0) <= limit && abs(a.1 - 3 * c.1 + 2 * d.1) <= limit
    }
    // Pieces still to draw, the next one last; at most 16 halvings deep.
    var stack: [(P, P, P, P, Int)] = [(p0, p1, p2, p3, 0)]
    while let (a, b, c, d, depth) = stack.popLast() {
      if depth >= 24 || flat(a, b, c, d) {
        line(a, d)
        continue
      }
      let ab = mid(a, b), bc = mid(b, c), cd = mid(c, d)
      let abc = mid(ab, bc), bcd = mid(bc, cd), m = mid(abc, bcd)
      stack.append((m, bcd, cd, d, depth + 1))
      stack.append((a, ab, abc, m, depth + 1))
    }
  }

  /// A line's signed area and cover, into the cells of each row it
  /// crosses: going down adds coverage, going up takes it away.
  mutating func line(_ from: (Float, Float), _ to: (Float, Float)) {
    if from.1 == to.1 { return }
    let direction: Float = from.1 < to.1 ? 1 : -1
    let (a, b) = from.1 < to.1 ? (from, to) : (to, from)
    let w = Float(width)
    func clampX(_ v: Float) -> Float { min(max(v, 0), w) }
    let dxdy = (b.0 - a.0) / (b.1 - a.1)
    let firstRow = max(0, Rasterizer.floor(a.1))
    let lastRow = min(height, Rasterizer.ceil(b.1))
    guard firstRow < lastRow else { return }
    var x = a.0 + (Float(firstRow) > a.1 ? (Float(firstRow) - a.1) * dxdy : 0)
    for row in firstRow..<lastRow {
      let base = row * width
      let dy = min(Float(row + 1), b.1) - max(Float(row), a.1)
      let next = x + dxdy * dy
      let d = dy * direction
      let x0 = clampX(min(x, next)), x1 = clampX(max(x, next))
      let x0i = Rasterizer.floor(x0)
      let x1i = Rasterizer.ceil(x1)
      let x0f = x0 - Float(x0i)
      if x1i <= x0i + 1 {
        // Within one pixel: the cover splits at the line's mean x.
        let mean = (x + next) * 0.5 - Float(x0i)
        let m = min(max(mean, 0), 1)
        add(base + x0i, d - d * m)
        add(base + x0i + 1, d * m)
      } else {
        // Across pixels: a triangle in the first, a trapezoid's share in
        // each one between, a triangle's complement in the last.
        let s = 1 / (x1 - x0)
        let first = 0.5 * s * (1 - x0f) * (1 - x0f)
        let x1f = x1 - Float(x1i) + 1
        let last = 0.5 * s * x1f * x1f
        add(base + x0i, d * first)
        if x1i == x0i + 2 {
          add(base + x0i + 1, d * (1 - first - last))
        } else {
          let second = s * (1.5 - x0f)
          add(base + x0i + 1, d * (second - first))
          var i = x0i + 2
          while i < x1i - 1 {
            add(base + i, d * s)
            i += 1
          }
          let before = second + Float(x1i - x0i - 3) * s
          add(base + x1i - 1, d * (1 - before - last))
        }
        add(base + x1i, d * last)
      }
      x = next
    }
  }

  mutating func add(_ i: Int, _ v: Float) {
    if i >= 0 && i < cells.count { cells[i] += v }
  }

  static func floor(_ v: Float) -> Int {
    let i = Int(v)
    return Float(i) > v ? i - 1 : i
  }

  static func ceil(_ v: Float) -> Int {
    let i = Int(v)
    return Float(i) < v ? i + 1 : i
  }

  static func floor(_ v: Double) -> Int {
    let i = Int(v)
    return Double(i) > v ? i - 1 : i
  }

  static func ceil(_ v: Double) -> Int {
    let i = Int(v)
    return Double(i) < v ? i + 1 : i
  }
}
