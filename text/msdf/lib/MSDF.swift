// SPDX-License-Identifier: BSD-3-Clause

// Multi-channel signed distance fields (M6h), after Viktor Chlumský's
// "Shape Decomposition for Multi-channel Distance Fields" (2015): a
// glyph as a small texture from which any size of it can be drawn, its
// corners sharp, with a glow from the same sample.
//
// - Each contour's edges are coloured with two or three of the channels
//   (red, green, blue), the colour changing at each corner (where the
//   direction turns by more than `cornerAngle`), so that at a corner the
//   two edges meeting there share only one channel. A contour with no
//   corner is white; one with a single corner (a teardrop) gets three
//   colours, split if it has fewer than three edges.
// - Each texel stores, per channel, the signed pseudo-distance to the
//   nearest edge of that channel: the distance to the edge, or past its
//   ends, to the line extending it. The median of the three is the shape,
//   corners included; alpha stores the true signed distance (for glows,
//   shadows, outlines).
// - Edges are measured as fine polylines (`flatness`), so no equation is
//   solved and tier 0 needs no libm (square roots by Newton's method).
// - Errors are corrected: a texel whose median puts it on the wrong side
//   (the side is decided exactly, by the outline's nonzero winding: which
//   also makes overlapping contours come out right) takes the true
//   distance in all three channels, as do the four texels around any
//   point between them where the interpolated median would be on the
//   wrong side (by the outline, past a hundredth of a texel), or would put
//   an edge (within an eighth of a texel of zero) more than half a texel
//   from the true one: the generator has the geometry, so it checks the
//   field against it (on an eighth-texel grid, which the margin makes
//   enough) rather than guessing at clashes.
//
// Distances are in texels, positive inside, mapped from [-range/2,
// range/2] to [0, 255]: 128 is the edge.

import OpenType

/// A field: four bytes a texel (median of RGB the shape, A the true
/// distance), rows from the top, placed like a `Bitmap`.
public struct DistanceField: Sendable {
  public var width = 0
  public var height = 0
  /// From the pen position to the field's left edge, in texels.
  public var left = 0
  /// From the baseline up to the field's top edge, in texels.
  public var top = 0
  /// The distance, in texels, from one end of a channel's values to the
  /// other.
  public var range = 4.0
  public var pixels: [UInt8] = []

  public init() {}

  public subscript(x: Int, y: Int, channel: Int) -> UInt8 { pixels[(y * width + x) * 4 + channel] }
}

/// The channels as bits: an edge's colour is the channels it counts in.
public enum EdgeColor {
  public static let red: UInt8 = 1, green: UInt8 = 2, blue: UInt8 = 4
  public static let cyan: UInt8 = 6, magenta: UInt8 = 5, yellow: UInt8 = 3, white: UInt8 = 7
}

public struct DistanceFieldGenerator: Sendable {
  /// The distance, in texels, the values span (what's farther is clamped).
  public var range = 4.0
  /// How sharp a turn makes a corner: the sine of the angle between two
  /// edges' directions where they meet (or any turn past a right angle).
  public var cornerSine = 0.141  // sin 3 radians, msdfgen's default
  /// How closely the polylines measuring the edges follow them, in texels.
  public var flatness = 1.0 / 64
  /// Whether to correct errors (on: the tests turn it off to see why).
  public var correctErrors = true

  // Working storage, kept between glyphs.
  var edges: [Edge] = []
  var points: [Vec] = []
  var ring: [Vec] = []
  var distances: [Float] = []
  var best = [Best](repeating: Best(), count: 4)

  /// The nearest edge so far: its distance, how far from perpendicular,
  /// and the value it gives (a signed distance or pseudo-distance).
  struct Best {
    var distance = Double.infinity
    var dot = Double.infinity
    var value = 0.0

    /// Whether an edge at signed distance `d` is nearer (or as near, and
    /// more nearly perpendicular).
    func loses(to d: Double, _ dot: Double) -> Bool {
      abs(d) < distance - 1e-12 || (abs(d) <= distance + 1e-12 && dot < self.dot)
    }
  }

  public init() {}

  struct Vec {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) {
      self.x = x
      self.y = y
    }
    static func - (a: Vec, b: Vec) -> Vec { Vec(a.x - b.x, a.y - b.y) }
    static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y) }
    static func * (a: Vec, k: Double) -> Vec { Vec(a.x * k, a.y * k) }
    func dot(_ b: Vec) -> Double { x * b.x + y * b.y }
    func cross(_ b: Vec) -> Double { x * b.y - y * b.x }
    var length: Double { DistanceFieldGenerator.squareRoot(x * x + y * y) }
    var normalized: Vec {
      let l = length
      return l > 0 ? Vec(x / l, y / l) : Vec(0, 0)
    }
  }

  /// An edge: its colour, its polyline (`points[first...first+count]`),
  /// its directions where it starts and ends, and its bounds.
  struct Edge {
    var color: UInt8
    var first: Int
    var count: Int  // pieces
    var startDirection: Vec
    var endDirection: Vec
    var minX, minY, maxX, maxY: Double
  }

  /// A square root without libm: Newton's method from a guess that halves
  /// the exponent (four steps reach double precision).
  public static func squareRoot(_ v: Double) -> Double {
    guard v > 0, v.isFinite else { return v.isFinite ? 0 : v }
    var x = Double(bitPattern: (v.bitPattern >> 1) &+ (1023 << 51))
    for _ in 0..<5 { x = 0.5 * (x + v / x) }
    return x
  }

  /// A segment of an outline, its points in texels.
  enum Piece {
    case line(Vec, Vec)
    case quad(Vec, Vec, Vec)
    case cubic(Vec, Vec, Vec, Vec)

    var start: Vec {
      switch self {
      case .line(let a, _), .quad(let a, _, _), .cubic(let a, _, _, _): a
      }
    }

    var end: Vec {
      switch self {
      case .line(_, let b), .quad(_, _, let b), .cubic(_, _, _, let b): b
      }
    }

    /// The direction it leaves its start in (the first control point that
    /// isn't the start), and arrives at its end in.
    var startDirection: Vec {
      switch self {
      case .line(let a, let b): b - a
      case .quad(let a, let c, let b): (c - a).x == 0 && (c - a).y == 0 ? b - a : c - a
      case .cubic(let a, let c, let d, let b):
        (c - a).x != 0 || (c - a).y != 0 ? c - a : ((d - a).x != 0 || (d - a).y != 0 ? d - a : b - a)
      }
    }

    var endDirection: Vec {
      switch self {
      case .line(let a, let b): b - a
      case .quad(let a, let c, let b): (b - c).x == 0 && (b - c).y == 0 ? b - a : b - c
      case .cubic(let a, let c, let d, let b):
        (b - d).x != 0 || (b - d).y != 0 ? b - d : ((b - c).x != 0 || (b - c).y != 0 ? b - c : b - a)
      }
    }

    func point(_ t: Double) -> Vec {
      let u = 1 - t
      switch self {
      case .line(let a, let b): return a * u + b * t
      case .quad(let a, let c, let b): return a * (u * u) + c * (2 * u * t) + b * (t * t)
      case .cubic(let a, let c, let d, let b):
        return a * (u * u * u) + c * (3 * u * u * t) + d * (3 * u * t * t) + b * (t * t * t)
      }
    }

    /// Its two halves at `t` (de Casteljau).
    func split(_ t: Double) -> (Piece, Piece) {
      func lerp(_ p: Vec, _ q: Vec) -> Vec { p * (1 - t) + q * t }
      switch self {
      case .line(let a, let b):
        let m = lerp(a, b)
        return (.line(a, m), .line(m, b))
      case .quad(let a, let c, let b):
        let ac = lerp(a, c), cb = lerp(c, b), m = lerp(ac, cb)
        return (.quad(a, ac, m), .quad(m, cb, b))
      case .cubic(let a, let c, let d, let b):
        let ac = lerp(a, c), cd = lerp(c, d), db = lerp(d, b)
        let acd = lerp(ac, cd), cdb = lerp(cd, db), m = lerp(acd, cdb)
        return (.cubic(a, ac, acd, m), .cubic(m, cdb, db, b))
      }
    }

    /// How many lines follow it within `flatness`.
    func steps(_ flatness: Double) -> Int {
      var deviation: Double
      switch self {
      case .line: return 1
      case .quad(let a, let c, let b):
        let d = a - c * 2 + b
        deviation = max(abs(d.x), abs(d.y)) / 4
      case .cubic(let a, let c, let d, let b):
        let e1 = a - c * 2 + d, e2 = c - d * 2 + b
        deviation = max(max(abs(e1.x), abs(e1.y)), max(abs(e2.x), abs(e2.y))) * 0.75
      }
      var n = 1
      while deviation > flatness && n < 4096 {
        deviation /= 4
        n *= 2
      }
      return n
    }
  }

  /// The field of an outline in font units, scaled by `scale` (texels per
  /// unit) and moved by `x`, `y` texels.
  public mutating func generate(_ outline: Outline, scale: Double, x: Double = 0, y: Double = 0,
                                into field: inout DistanceField)
  {
    func t(_ p: Point) -> Vec { Vec(p.x * scale + x, p.y * scale + y) }
    var contours: [[Piece]] = []
    for c in outline.contours {
      var pieces: [Piece] = []
      var at = t(c.start)
      for s in c.segments {
        let piece: Piece
        switch s {
        case .line(let p): piece = .line(at, t(p))
        case .quad(let a, let p): piece = .quad(at, t(a), t(p))
        case .cubic(let a, let b, let p): piece = .cubic(at, t(a), t(b), t(p))
        }
        at = piece.end
        pieces.append(piece)
      }
      let start = t(c.start)
      if at.x != start.x || at.y != start.y { pieces.append(.line(at, start)) }
      // Edges that go nowhere have no direction: dropped.
      pieces = pieces.filter { p in
        let d = p.startDirection
        return d.x != 0 || d.y != 0
      }
      if !pieces.isEmpty { contours.append(pieces) }
    }
    generate(contours, into: &field)
  }

  mutating func generate(_ contours: [[Piece]], into field: inout DistanceField) {
    field.range = range
    // The frame: the control box, with room for the range.
    var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
    for c in contours {
      for p in c {
        let pts: [Vec]
        switch p {
        case .line(let a, let b): pts = [a, b]
        case .quad(let a, let c, let b): pts = [a, c, b]
        case .cubic(let a, let c, let d, let b): pts = [a, c, d, b]
        }
        for v in pts {
          minX = min(minX, v.x)
          minY = min(minY, v.y)
          maxX = max(maxX, v.x)
          maxY = max(maxY, v.y)
        }
      }
    }
    guard minX <= maxX else {
      field.width = 0
      field.height = 0
      field.left = 0
      field.top = 0
      field.pixels.removeAll(keepingCapacity: true)
      return
    }
    let pad = range / 2 + 1
    let left = DistanceFieldGenerator.floor(minX - pad), right = DistanceFieldGenerator.ceil(maxX + pad)
    let bottom = DistanceFieldGenerator.floor(minY - pad), top = DistanceFieldGenerator.ceil(maxY + pad)
    let w = right - left, h = top - bottom
    field.width = w
    field.height = h
    field.left = left
    field.top = top

    // Edges, coloured, as polylines.
    edges.removeAll(keepingCapacity: true)
    points.removeAll(keepingCapacity: true)
    var area = 0.0
    for contour in contours {
      let colored = color(contour)
      for (piece, c) in colored {
        let first = points.count
        let n = piece.steps(flatness)
        var bx0 = Double.infinity, by0 = Double.infinity, bx1 = -Double.infinity, by1 = -Double.infinity
        for k in 0...n {
          let v = k == n ? piece.end : piece.point(Double(k) / Double(n))
          points.append(v)
          bx0 = min(bx0, v.x)
          by0 = min(by0, v.y)
          bx1 = max(bx1, v.x)
          by1 = max(by1, v.y)
          if k > 0 { area += points[points.count - 2].cross(v) }
        }
        edges.append(Edge(color: c, first: first, count: n, startDirection: piece.startDirection.normalized,
                          endDirection: piece.endDirection.normalized, minX: bx0, minY: by0, maxX: bx1, maxY: by1))
      }
    }
    // Inside is to the right of a clockwise contour (where a direction's
    // cross product with the way to a point is negative), the left of a
    // counterclockwise one: the outline's overall turn (its shoelace sum,
    // positive counterclockwise) says which. `inside` is the sign a
    // negative cross product means.
    let inside: Double = area > 0 ? -1 : 1

    // Each texel's distances.
    let count = w * h
    if distances.count < count * 4 { distances = [Float](repeating: 0, count: count * 4) }
    for j in 0..<h {
      for i in 0..<w {
        let p = Vec(Double(left) + Double(i) + 0.5, Double(top) - Double(j) - 0.5)
        // best[0] is the true distance over all edges; 1-3 per channel.
        for c in 0..<4 { best[c] = Best() }
        for e in edges {
          // An edge farther than every channel's best so far can't win.
          let dx = max(e.minX - p.x, 0, p.x - e.maxX), dy = max(e.minY - p.y, 0, p.y - e.maxY)
          let boxDistance = DistanceFieldGenerator.squareRoot(dx * dx + dy * dy)
          if boxDistance > best[0].distance + 1e-9
            && (e.color & 1 == 0 || boxDistance > best[1].distance + 1e-9)
            && (e.color & 2 == 0 || boxDistance > best[2].distance + 1e-9)
            && (e.color & 4 == 0 || boxDistance > best[3].distance + 1e-9)
          { continue }
          let (d, dot, pseudo) = measure(e, p, inside)
          if best[0].loses(to: d, dot) { best[0] = Best(distance: abs(d), dot: dot, value: d) }
          for c in 0..<3 where e.color & (1 << c) != 0 && best[c + 1].loses(to: d, dot) {
            best[c + 1] = Best(distance: abs(d), dot: dot, value: pseudo)
          }
        }
        let at = (j * w + i) * 4
        for c in 0..<3 { distances[at + c] = Float(best[c + 1].distance.isFinite ? best[c + 1].value : best[0].value) }
        distances[at + 3] = Float(best[0].value)
      }
    }

    if correctErrors { correct(w, h, left, top) }

    // Into bytes.
    if field.pixels.count != count * 4 { field.pixels = [UInt8](repeating: 0, count: count * 4) }
    for k in 0..<count * 4 {
      let v = Double(distances[k]) / range + 0.5
      let byte = v <= 0 ? 0 : v >= 1 ? 255 : Int(v * 255 + 0.5)
      field.pixels[k] = UInt8(byte)
    }
  }

  /// An edge's signed distance from `p` (positive inside), how far from
  /// perpendicular the line to it is (for ties at a shared end), and its
  /// signed pseudo-distance (past its ends, to the line extending it).
  func measure(_ e: Edge, _ p: Vec, _ inside: Double) -> (Double, Double, Double) {
    var bestD2 = Double.infinity
    var bestPoint = Vec(0, 0), bestDirection = Vec(0, 0)
    var bestK = 0, bestS = 0.0
    for k in 0..<e.count {
      let a = points[e.first + k], b = points[e.first + k + 1]
      let ab = b - a
      let l2 = ab.dot(ab)
      var s = l2 > 0 ? (p - a).dot(ab) / l2 : 0
      s = min(max(s, 0), 1)
      let q = a + ab * s
      let v = p - q
      let d2 = v.dot(v)
      if d2 < bestD2 {
        bestD2 = d2
        bestPoint = q
        bestDirection = ab
        bestK = k
        bestS = s
      }
    }
    let toPoint = p - bestPoint
    let distance = DistanceFieldGenerator.squareRoot(bestD2)
    // The direction at the closest point: the edge's own at its ends.
    var direction = bestDirection.normalized
    let atStart = bestK == 0 && bestS == 0, atEnd = bestK == e.count - 1 && bestS == 1
    if atStart { direction = e.startDirection }
    if atEnd { direction = e.endDirection }
    let side = direction.cross(toPoint) < 0 ? inside : -inside
    let signed = distance * side
    let dot = distance > 0 ? abs(direction.dot(toPoint)) / distance : 0
    var pseudo = signed
    if atStart, toPoint.dot(e.startDirection) < 0 {
      let start = points[e.first]
      let c = e.startDirection.cross(p - start)
      pseudo = abs(c) * (c < 0 ? inside : -inside)
    } else if atEnd, toPoint.dot(e.endDirection) > 0 {
      let end = points[e.first + e.count]
      let c = e.endDirection.cross(p - end)
      pseudo = abs(c) * (c < 0 ? inside : -inside)
    }
    return (signed, dot, pseudo)
  }

  // MARK: Colouring

  /// A contour's edges with their colours (split where a teardrop has
  /// fewer than three).
  func color(_ contour: [Piece]) -> [(Piece, UInt8)] {
    let n = contour.count
    var corners: [Int] = []
    for i in 0..<n {
      let a = contour[(i + n - 1) % n].endDirection.normalized, b = contour[i].startDirection.normalized
      if a.dot(b) <= 0 || abs(a.cross(b)) > cornerSine { corners.append(i) }
    }
    if corners.isEmpty { return contour.map { ($0, EdgeColor.white) } }
    // Start at a corner.
    let first = corners[0]
    var pieces = (0..<n).map { contour[(first + $0) % n] }
    if corners.count == 1 {
      // A teardrop: three colours, the middle white, over at least three
      // edges.
      if pieces.count == 1 {
        let (a, rest) = pieces[0].split(1.0 / 3)
        let (b, c) = rest.split(0.5)
        pieces = [a, b, c]
      } else if pieces.count == 2 {
        let (a, b) = pieces[0].split(0.5)
        let (c, d) = pieces[1].split(0.5)
        pieces = [a, b, c, d]
      }
      let m = pieces.count
      return pieces.enumerated().map { k, p in
        // The first third, the middle third, the last third.
        let third = 3 * k / m
        return (p, third == 0 ? EdgeColor.magenta : third == 1 ? EdgeColor.white : EdgeColor.yellow)
      }
    }
    // Several corners: a colour from the cycle for each run between two,
    // the last different from the first as well as from the one before.
    let cycle = [EdgeColor.cyan, EdgeColor.magenta, EdgeColor.yellow]
    let starts = corners.map { ($0 - first + n) % n }
    var colors = (0..<starts.count).map { cycle[$0 % 3] }
    if starts.count > 1 && colors[starts.count - 1] == colors[0] {
      colors[starts.count - 1] = cycle.first { $0 != colors[0] && $0 != colors[starts.count - 2] }!
    }
    var out: [(Piece, UInt8)] = []
    var run = 0
    for (k, p) in pieces.enumerated() {
      while run + 1 < starts.count && k >= starts[run + 1] { run += 1 }
      out.append((p, colors[run]))
    }
    return out
  }

  // MARK: Errors

  /// The nonzero winding of the outline's polylines around `p`.
  func winding(_ p: Vec) -> Int {
    var w = 0
    for e in edges {
      if p.y < e.minY || p.y > e.maxY { continue }
      for k in 0..<e.count {
        let a = points[e.first + k], b = points[e.first + k + 1]
        if a.y <= p.y {
          if b.y > p.y && (b - a).cross(p - a) > 0 { w += 1 }
        } else if b.y <= p.y && (b - a).cross(p - a) < 0 {
          w -= 1
        }
      }
    }
    return w
  }

  /// The distance from `p` to the outline.
  func nearest(_ p: Vec) -> Double {
    var best = Double.infinity
    for e in edges {
      let dx = max(e.minX - p.x, 0, p.x - e.maxX), dy = max(e.minY - p.y, 0, p.y - e.maxY)
      if dx * dx + dy * dy >= best * best { continue }
      best = min(best, abs(measure(e, p, 1).0))
    }
    return best
  }

  static func median(_ a: Float, _ b: Float, _ c: Float) -> Float { max(min(a, b), min(max(a, b), c)) }

  /// Texels whose median is on the wrong side, and the cells whose
  /// interpolation would be, take the true distance in every channel.
  mutating func correct(_ w: Int, _ h: Int, _ left: Int, _ top: Int) {
    var flagged = [Bool](repeating: false, count: w * h)
    for j in 0..<h {
      for i in 0..<w {
        let at = (j * w + i) * 4
        let m = DistanceFieldGenerator.median(distances[at], distances[at + 1], distances[at + 2])
        let p = Vec(Double(left) + Double(i) + 0.5, Double(top) - Double(j) - 0.5)
        let isInside = winding(p) != 0
        // The true distance's sign, from the winding.
        let truth = abs(distances[at + 3]) * (isInside ? 1 : -1)
        distances[at + 3] = truth
        if (m > 0) != isInside && m != 0 { flagged[j * w + i] = true }
      }
    }
    // Between texels: across each cell of four, where the interpolated
    // median and the interpolated true distance disagree about the side,
    // the outline decides; where the median is wrong (by more than a
    // sliver), the cell's texels are equalized. Corners, where the median
    // is right and the true distance rounds them, keep their channels.
    let steps = 8
    for j in 0..<max(0, h - 1) {
      for i in 0..<max(0, w - 1) {
        let a = (j * w + i) * 4, b = a + 4, c = a + 4 * w, d = c + 4
        var wrong = false
        for sy in 0..<steps where !wrong {
          for sx in 0..<steps where !wrong {
            let fx = Float(sx) / Float(steps), fy = Float(sy) / Float(steps)
            func mix(_ k: Int) -> Float {
              (distances[a + k] * (1 - fx) + distances[b + k] * fx) * (1 - fy)
                + (distances[c + k] * (1 - fx) + distances[d + k] * fx) * fy
            }
            let m = DistanceFieldGenerator.median(mix(0), mix(1), mix(2)), t = mix(3)
            // Suspect: the median on the other side from the true distance,
            // or putting an edge (within an eighth of a texel) where the
            // true distance says there's none near.
            let flips = (m > 0) != (t > 0), phantom = abs(m) < 0.125 && abs(t) > 0.5
            if !flips && !phantom { continue }
            let p = Vec(Double(left) + Double(i) + 0.5 + Double(fx), Double(top) - Double(j) - 0.5 - Double(fy))
            let d = nearest(p)
            if ((m > 0) != (winding(p) != 0) && d > 0.01) || (phantom && d > 0.5) { wrong = true }
          }
        }
        if wrong {
          flagged[j * w + i] = true
          flagged[j * w + i + 1] = true
          flagged[(j + 1) * w + i] = true
          flagged[(j + 1) * w + i + 1] = true
        }
      }
    }
    for k in 0..<w * h where flagged[k] {
      let t = distances[k * 4 + 3]
      distances[k * 4] = t
      distances[k * 4 + 1] = t
      distances[k * 4 + 2] = t
    }
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
