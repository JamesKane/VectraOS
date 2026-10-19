// SPDX-License-Identifier: BSD-3-Clause

// Icons (M6i part 5): the storyboard's icon sheet, drawn as Be drew them
// (2:1 isometric, lit from the upper left; faces at 40, 22 and 9 percent
// of the edge colour over bg.0; a 1 px wireframe in the kind's colour; the
// emblem in the type's colour). Their geometry is data, `IconData.all`,
// which iconsgen reads from docs/design/shell-storyboard.html; here it
// becomes pixels at any size and in any colours: each element filled
// (through the glyph rasterizer: exact area coverage) and stroked, in
// order, over a transparent square.
//
// A stroke is a width in pixels at any size, as the sheet's
// `vector-effect: non-scaling-stroke` makes it (1 px; the accessible
// theme's 1.6): each segment a quad around it and each corner mitred, as
// SVG's default miter limit of 4 allows, else bevelled; open ends butt.
// Every piece is wound the same way, so the rasterizer's nonzero rule
// unites them. Only what is selected glows: CSS's `drop-shadow(0 0 r)`,
// a Gaussian of deviation r/2 of the icon's alpha in the glow colour
// under it, approximated by three box blurs (tier 0 has no exp).

import OpenType
import Raster

public enum IconRole: UInt8, Sendable {
  case none, edge, emblem, background
}

/// A paint: a role's colour, `percent` of it over the background.
public struct IconPaint: Equatable, Sendable {
  public var role: IconRole
  public var percent: UInt8
  public init(_ role: IconRole, _ percent: Int) {
    self.role = role
    self.percent = UInt8(percent)
  }
}

/// One element of an icon: a path (opcodes and points in the 32-unit
/// view box, y down: 0 move x y, 1 line x y, 2 cubic x1 y1 x2 y2 x y, 3
/// close), its fill (from `fill` at the left of its box to `fillTo` at
/// the right) and its stroke.
public struct IconElement: Sendable {
  public var fill: IconPaint
  public var fillTo: IconPaint
  public var stroke: IconPaint
  public var path: [Float]
  public init(fill: IconPaint, fillTo: IconPaint, stroke: IconPaint, path: [Float]) {
    self.fill = fill
    self.fillTo = fillTo
    self.stroke = stroke
    self.path = path
  }
}

public struct IconShape: Sendable {
  public var name: String
  public var elements: [IconElement]
  public init(name: String, elements: [IconElement]) {
    self.name = name
    self.elements = elements
  }
}

/// The icon sheet (its table is generated: generated/IconSheet.swift).
public enum IconData {
  public static func index(_ name: String) -> Int? { all.firstIndex { $0.name == name } }
}

/// An icon's colours: its kind's edge colour, its emblem's (0: the edge
/// colour's), and the background the faces are mixed over (0xRRGGBB).
public struct IconColors: Equatable, Sendable {
  public var edge: UInt32
  public var emblem: UInt32
  public var background: UInt32
  public init(edge: UInt32, emblem: UInt32 = 0, background: UInt32) {
    self.edge = edge
    self.emblem = emblem
    self.background = background
  }

  /// A paint's colour (0xRRGGBB): its role's, mixed over the background
  /// in sRGB, as CSS's color-mix(in srgb) does.
  public func color(_ p: IconPaint) -> UInt32 {
    let base: UInt32
    switch p.role {
    case .none: return 0
    case .edge: base = edge
    case .emblem: base = emblem != 0 ? emblem : edge
    case .background: base = background
    }
    let t = UInt32(p.percent)
    func ch(_ s: UInt32) -> UInt32 {
      ((base >> s & 0xFF) * t + (background >> s & 0xFF) * (100 - t) + 50) / 100
    }
    return ch(16) << 16 | ch(8) << 8 | ch(0)
  }
}

/// Straight-alpha RGBA pixels, rows from the top.
public struct RGBAImage: Sendable {
  public var width: Int
  public var height: Int
  /// `width * height * 4` bytes: R, G, B, A.
  public var pixels: [UInt8]
  public init(width: Int, height: Int, pixels: [UInt8]) {
    self.width = width
    self.height = height
    self.pixels = pixels
  }
  public init(width: Int, height: Int) {
    self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
  }

  /// `color` (0xRRGGBB) over the pixel at (x, y), `alpha` of it (0-1).
  mutating func over(_ x: Int, _ y: Int, _ color: UInt32, _ alpha: Float) {
    guard alpha > 0, x >= 0, y >= 0, x < width, y < height else { return }
    let i = (y * width + x) * 4
    let da = Float(pixels[i + 3]) / 255
    let oa = alpha + da * (1 - alpha)
    guard oa > 0 else { return }
    for (k, s) in [(0, 16), (1, 8), (2, 0)] {
      let src = Float(color >> UInt32(s) & 0xFF), dst = Float(pixels[i + k])
      pixels[i + k] = UInt8(min(255, (src * alpha + dst * da * (1 - alpha)) / oa + 0.5))
    }
    pixels[i + 3] = UInt8(min(255, oa * 255 + 0.5))
  }
}

extension IconShape {
  /// The icon at `size` pixels square, its strokes `stroke` pixels wide;
  /// glowing (selected) with `glow` pixels' reach in `glowColor` (ARGB),
  /// the image then padded by the glow's reach on every side.
  public func render(size: Int, colors: IconColors, stroke: Float = 1, glow: Float = 0, glowColor: UInt32 = 0,
                     rasterizer: inout Rasterizer, bitmap: inout Bitmap) -> RGBAImage
  {
    let pad = glow > 0 ? Int(glow * 1.5 + 1) : 0
    var image = RGBAImage(width: size + 2 * pad, height: size + 2 * pad)
    let s = Float(size) / 32
    for e in elements {
      // The fill: its coverage, coloured across its box.
      if e.fill.role != .none {
        rasterizer.render(pixels: Icons.outline(e.path, scale: s, pad: Float(pad)), into: &bitmap)
        let from = colors.color(e.fill), to = colors.color(e.fillTo)
        let box = Icons.box(e.path, scale: s, pad: Float(pad))
        composite(bitmap, &image) { x in
          from == to ? from : Icons.lerp(from, to, (Float(x) + 0.5 - box.x0) / max(box.x1 - box.x0, 1))
        }
      }
      if e.stroke.role != .none && stroke > 0 {
        rasterizer.render(pixels: Icons.strokeOutline(e.path, scale: s, pad: Float(pad), width: stroke), into: &bitmap)
        let c = colors.color(e.stroke)
        composite(bitmap, &image) { _ in c }
      }
    }
    if glow > 0 && glowColor >> 24 != 0 { Icons.addGlow(&image, reach: glow, color: glowColor) }
    return image
  }

  /// A coverage bitmap (y up from row 0's top, as the rasterizer gives
  /// it) over the image, coloured by column.
  func composite(_ b: Bitmap, _ image: inout RGBAImage, _ color: (Int) -> UInt32) {
    for row in 0..<b.height {
      let y = -b.top + row
      for col in 0..<b.width {
        let c = b.pixels[row * b.width + col]
        guard c > 0 else { continue }
        let x = b.left + col
        image.over(x, y, color(x), Float(c) / 255)
      }
    }
  }
}

enum Icons {
  static func sqrt(_ v: Float) -> Float {
    guard v > 0 else { return 0 }
    var r = v > 1 ? v : 1
    for _ in 0..<24 { r = 0.5 * (r + v / r) }
    return r
  }

  static func lerp(_ a: UInt32, _ b: UInt32, _ t0: Float) -> UInt32 {
    let t = min(max(t0, 0), 1)
    func ch(_ s: UInt32) -> UInt32 { UInt32(Float(a >> s & 0xFF) * (1 - t) + Float(b >> s & 0xFF) * t + 0.5) }
    return ch(16) << 16 | ch(8) << 8 | ch(0)
  }

  /// A path's points in pixels: (x, y) down from the image's top left.
  static func walk(_ path: [Float], scale s: Float, pad: Float,
                   _ visit: (Int, [(Float, Float)]) -> Void)
  {
    var i = 0
    while i < path.count {
      let op = Int(path[i])
      let n = op == 0 || op == 1 ? 1 : op == 2 ? 3 : 0
      var pts: [(Float, Float)] = []
      for k in 0..<n { pts.append((path[i + 1 + 2 * k] * s + pad, path[i + 2 + 2 * k] * s + pad)) }
      visit(op, pts)
      i += 1 + 2 * n
    }
  }

  /// The path's box in pixels.
  static func box(_ path: [Float], scale: Float, pad: Float) -> (x0: Float, x1: Float) {
    var x0 = Float.infinity, x1 = -Float.infinity
    walk(path, scale: scale, pad: pad) { _, pts in
      for p in pts {
        x0 = min(x0, p.0)
        x1 = max(x1, p.0)
      }
    }
    return (x0, x1)
  }

  /// The rasterizer's outline (y up: the image's rows count down from 0).
  static func point(_ p: (Float, Float)) -> Point { Point(Double(p.0), Double(-p.1)) }

  static func outline(_ path: [Float], scale: Float, pad: Float) -> Outline {
    var contours: [Contour] = []
    walk(path, scale: scale, pad: pad) { op, pts in
      switch op {
      case 0: contours.append(Contour(start: point(pts[0]), segments: []))
      case 1: contours[contours.count - 1].segments.append(.line(point(pts[0])))
      case 2: contours[contours.count - 1].segments.append(.cubic(point(pts[0]), point(pts[1]), point(pts[2])))
      default: break  // a contour is closed by the rasterizer
      }
    }
    return Outline(contours: contours)
  }

  /// The path flattened: polylines in pixels, and whether each is closed.
  static func polylines(_ path: [Float], scale: Float, pad: Float) -> [(points: [(Float, Float)], closed: Bool)] {
    var out: [(points: [(Float, Float)], closed: Bool)] = []
    walk(path, scale: scale, pad: pad) { op, pts in
      switch op {
      case 0: out.append(([pts[0]], false))
      case 1: out[out.count - 1].points.append(pts[0])
      case 2:
        let p0 = out[out.count - 1].points[out[out.count - 1].points.count - 1]
        let (p1, p2, p3) = (pts[0], pts[1], pts[2])
        func d(_ a: (Float, Float), _ b: (Float, Float)) -> Float { sqrt((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)) }
        let n = max(2, min(64, Int((d(p0, p1) + d(p1, p2) + d(p2, p3)) / 0.75) + 1))
        for k in 1...n {
          let t = Float(k) / Float(n), u = 1 - t
          let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, e = t * t * t
          out[out.count - 1].points.append((a * p0.0 + b * p1.0 + c * p2.0 + e * p3.0,
                                            a * p0.1 + b * p1.1 + c * p2.1 + e * p3.1))
        }
      case 3:
        out[out.count - 1].closed = true
        // Further drawing after a close starts where the contour began.
        let start = out[out.count - 1].points[0]
        out.append(([start], false))
      default: break
      }
    }
    return out.filter { $0.points.count > 1 }
  }

  /// A stroke `width` pixels wide around the path, as pieces wound alike.
  static func strokeOutline(_ path: [Float], scale: Float, pad: Float, width: Float) -> Outline {
    let h = width / 2
    var contours: [Contour] = []
    func piece(_ ps: [(Float, Float)]) {
      // Wound one way: positive area in the rasterizer's y-up coordinates.
      var area: Float = 0
      for i in ps.indices {
        let a = ps[i], b = ps[(i + 1) % ps.count]
        area += a.0 * (-b.1) - b.0 * (-a.1)
      }
      guard area != 0 else { return }
      let ordered = area > 0 ? ps : ps.reversed()
      contours.append(Contour(start: point(ordered[0]), segments: ordered.dropFirst().map { .line(point($0)) }))
    }
    for line in polylines(path, scale: scale, pad: pad) {
      var pts = line.points
      // Coincident points make no direction.
      var k = 1
      while k < pts.count {
        if pts[k].0 == pts[k - 1].0 && pts[k].1 == pts[k - 1].1 { pts.remove(at: k) } else { k += 1 }
      }
      if line.closed, pts.count > 2, pts[0].0 == pts[pts.count - 1].0 && pts[0].1 == pts[pts.count - 1].1 {
        pts.removeLast()
      }
      guard pts.count > 1 else { continue }
      let segs = line.closed ? pts.count : pts.count - 1
      func normal(_ i: Int) -> (Float, Float) {
        let a = pts[i], b = pts[(i + 1) % pts.count]
        let dx = b.0 - a.0, dy = b.1 - a.1, l = sqrt(dx * dx + dy * dy)
        return (-dy / l * h, dx / l * h)
      }
      for i in 0..<segs {
        let a = pts[i], b = pts[(i + 1) % pts.count], n = normal(i)
        piece([(a.0 + n.0, a.1 + n.1), (b.0 + n.0, b.1 + n.1), (b.0 - n.0, b.1 - n.1), (a.0 - n.0, a.1 - n.1)])
      }
      // Joins: at every inner vertex, and all of a closed line's.
      let joins = line.closed ? Array(0..<pts.count) : Array(1..<max(1, pts.count - 1))
      for j in joins {
        let prev = (j - 1 + segs) % segs, next = j % segs
        guard line.closed || (j >= 1 && j < pts.count - 1) else { continue }
        let v = pts[j], n0 = normal(prev), n1 = normal(next)
        let u = (n0.0 + n1.0, n0.1 + n1.1)
        let ul = sqrt(u.0 * u.0 + u.1 * u.1)
        // The outer side: away from where the line turns.
        let a = pts[prev], b = pts[(next + 1) % pts.count]
        let turn = ((b.0 - v.0) - (v.0 - a.0), (b.1 - v.1) - (v.1 - a.1))
        let side: Float = u.0 * turn.0 + u.1 * turn.1 > 0 ? -1 : 1
        let o0 = (v.0 + side * n0.0, v.1 + side * n0.1), o1 = (v.0 + side * n1.0, v.1 + side * n1.1)
        if ul > 1e-4 && 2 * h / ul <= 4 {
          let m = side * 2 * h * h / (ul * ul)
          piece([v, o0, (v.0 + u.0 * m, v.1 + u.1 * m), o1])
        } else {
          piece([v, o0, o1])
        }
      }
    }
    return Outline(contours: contours)
  }

  /// A glow under the image: its alpha blurred (three box blurs, about a
  /// Gaussian of deviation reach / 2), in `color`, beneath what's there.
  static func addGlow(_ image: inout RGBAImage, reach: Float, color: UInt32) {
    let w = image.width, h = image.height
    var a = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { a[i] = Float(image.pixels[i * 4 + 3]) / 255 }
    let sigma = reach / 2
    // Three boxes of this radius blur as a Gaussian of deviation sigma.
    let r = max(1, Int(sqrt(sigma * sigma + 1) + 0.5))
    var tmp = a
    for _ in 0..<3 {
      for y in 0..<h {
        for x in 0..<w {
          var sum: Float = 0
          for k in -r...r where x + k >= 0 && x + k < w { sum += a[y * w + x + k] }
          tmp[y * w + x] = sum / Float(2 * r + 1)
        }
      }
      for y in 0..<h {
        for x in 0..<w {
          var sum: Float = 0
          for k in -r...r where y + k >= 0 && y + k < h { sum += tmp[(y + k) * w + x] }
          a[y * w + x] = sum / Float(2 * r + 1)
        }
      }
    }
    // The glow under: what's there over it.
    let ga = Float(color >> 24) / 255
    var out = RGBAImage(width: w, height: h)
    for y in 0..<h {
      for x in 0..<w {
        out.over(x, y, color & 0xFF_FFFF, a[y * w + x] * ga)
        let i = (y * w + x) * 4
        let c = UInt32(image.pixels[i]) << 16 | UInt32(image.pixels[i + 1]) << 8 | UInt32(image.pixels[i + 2])
        out.over(x, y, c, Float(image.pixels[i + 3]) / 255)
      }
    }
    image = out
  }
}
