// SPDX-License-Identifier: BSD-3-Clause

// TrueType outlines (OpenType 1.9, `loca` and `glyf`): simple glyphs'
// contours of on- and off-curve points (two off-curve points in a row
// imply an on-curve one between them), and composite glyphs, their
// components' points placed by offsets (or matched points) and 2x2
// transforms, rounded as FreeType rounds them, before the contours are
// made. A component's offset is not scaled unless its flags say so
// (FreeType's default, and Microsoft's). Instructions (hinting) are
// ignored: a stub.

struct Glyf: Sendable {
  typealias Points = (points: [(Int, Int, Bool)], ends: [Int])

  let loca: Bytes
  let glyf: Bytes
  let longOffsets: Bool
  let glyphCount: Int

  init(loca: Bytes, glyf: Bytes, longOffsets: Bool, glyphCount: Int) throws(FontError) {
    self.loca = loca
    self.glyf = glyf
    self.longOffsets = longOffsets
    self.glyphCount = glyphCount
    guard loca.count >= (longOffsets ? 4 : 2) * (glyphCount + 1) else { throw .malformed("loca is short") }
  }

  /// A glyph's bytes in `glyf` (empty for a glyph with no outline).
  func data(_ glyph: Int) throws(FontError) -> Bytes {
    let start: Int, end: Int
    if longOffsets {
      start = Int(try loca.u32(4 * glyph))
      end = Int(try loca.u32(4 * glyph + 4))
    } else {
      start = 2 * Int(try loca.u16(2 * glyph))
      end = 2 * Int(try loca.u16(2 * glyph + 2))
    }
    guard end >= start else { throw .malformed("loca goes backwards at glyph \(glyph)") }
    return try glyf.slice(start, end - start, "glyf for glyph \(glyph)")
  }

  /// A glyph's outline: its points (a composite's gathered from its
  /// components), then its contours from them.
  func outline(_ glyph: Int) throws(FontError) -> Outline {
    let (points, ends) = try self.points(glyph, depth: 0)
    var out = Outline()
    var first = 0
    for end in ends {
      guard end >= first, end < points.count else { continue }
      out.contours.append(Glyf.contour(Array(points[first...end])))
      first = end + 1
    }
    return out
  }

  /// The component whose metrics a composite glyph takes
  /// (USE_MY_METRICS), followed down to a glyph that has its own; nil for
  /// a glyph whose own `hmtx` entry stands.
  func metricsGlyph(_ glyph: Int, depth: Int = 0) throws(FontError) -> Int? {
    guard depth < 16 else { return nil }
    let g = try data(glyph)
    guard g.count >= 10, try g.i16(0) < 0 else { return nil }
    var at = 10
    while true {
      let flags = try g.u16(at)
      let component = Int(try g.u16(at + 2))
      if flags & 0x200 != 0, component < glyphCount {  // USE_MY_METRICS
        return try metricsGlyph(component, depth: depth + 1) ?? component
      }
      guard flags & 0x20 != 0 else { return nil }  // MORE_COMPONENTS
      at += 4 + (flags & 1 != 0 ? 4 : 2)
      at += flags & 0x08 != 0 ? 2 : flags & 0x40 != 0 ? 4 : flags & 0x80 != 0 ? 8 : 0
    }
  }

  /// The glyph's xMin, as its header says (nil for an empty glyph).
  func xMin(_ glyph: Int) throws(FontError) -> Int? {
    let g = try data(glyph)
    return g.count >= 10 ? Int(try g.i16(2)) : nil
  }

  /// A glyph's points (x, y, on curve) and where each contour ends.
  func points(_ glyph: Int, depth: Int) throws(FontError) -> Points {
    guard depth < 16 else { throw .malformed("composite glyphs nested too deep") }
    let g = try data(glyph)
    guard g.count > 0 else { return ([], []) }
    let contours = Int(try g.i16(0))
    return contours >= 0 ? try simplePoints(g, contours) : try compositePoints(g, depth)
  }

  /// A simple glyph's points, as stored.
  func simplePoints(_ g: Bytes, _ count: Int) throws(FontError) -> Points {
    var ends: [Int] = []
    for i in 0..<count { ends.append(Int(try g.u16(10 + 2 * i))) }
    for i in 1..<max(1, ends.count) where ends[i] <= ends[i - 1] { throw .malformed("glyf's contours out of order") }
    let n = (ends.last ?? -1) + 1
    var at = 10 + 2 * count
    let instructions = Int(try g.u16(at))
    at += 2 + instructions
    // Flags, with repeats.
    var flags: [UInt8] = []
    while flags.count < n {
      let f = try g.u8(at)
      at += 1
      flags.append(f)
      if f & 8 != 0 {
        let repeats = Int(try g.u8(at))
        at += 1
        for _ in 0..<repeats { flags.append(f) }
      }
    }
    guard flags.count == n else { throw .malformed("glyf's flags overrun") }
    func coordinates(short: UInt8, same: UInt8) throws(FontError) -> [Int] {
      var out: [Int] = [], v = 0
      for f in flags {
        if f & short != 0 {
          let d = Int(try g.u8(at))
          at += 1
          v += f & same != 0 ? d : -d
        } else if f & same == 0 {
          v += Int(try g.i16(at))
          at += 2
        }
        out.append(v)
      }
      return out
    }
    let xs = try coordinates(short: 2, same: 16)
    let ys = try coordinates(short: 4, same: 32)
    var points: [(Int, Int, Bool)] = []
    for i in 0..<n { points.append((xs[i], ys[i], flags[i] & 1 != 0)) }
    return (points, ends)
  }

  /// FreeType's FT_MulFix: a * b / 65536, b being 16.16, rounded to the
  /// nearest (halves away from zero).
  static func mulFix(_ a: Int, _ b: Int) -> Int {
    let p = a * b
    return p >= 0 ? (p + 0x8000) >> 16 : -((-p + 0x8000) >> 16)
  }

  /// A composite glyph's points: each component's, transformed as FreeType
  /// transforms them (16.16 products, each rounded), then moved by its
  /// offset (scaled by the transform only if SCALED_COMPONENT_OFFSET says
  /// so) or by matching a point of what came before with one of its own
  /// (points as stored, never implied ones).
  func compositePoints(_ g: Bytes, _ depth: Int) throws(FontError) -> Points {
    var points: [(Int, Int, Bool)] = []
    var ends: [Int] = []
    var at = 10
    var more = true
    while more {
      let flags = try g.u16(at)
      let glyph = Int(try g.u16(at + 2))
      at += 4
      let xy = flags & 2 != 0  // ARGS_ARE_XY_VALUES: signed offsets, else point numbers
      var arg1: Int, arg2: Int
      if flags & 1 != 0 {  // ARG_1_AND_2_ARE_WORDS
        arg1 = xy ? Int(try g.i16(at)) : Int(try g.u16(at))
        arg2 = xy ? Int(try g.i16(at + 2)) : Int(try g.u16(at + 2))
        at += 4
      } else {
        arg1 = xy ? Int(Int8(bitPattern: try g.u8(at))) : Int(try g.u8(at))
        arg2 = xy ? Int(Int8(bitPattern: try g.u8(at + 1))) : Int(try g.u8(at + 1))
        at += 2
      }
      // The transform, 16.16 (F2Dot14 shifted by 2).
      var a = 0x10000, b = 0, c = 0, d = 0x10000
      var transformed = false
      if flags & 0x08 != 0 {  // WE_HAVE_A_SCALE
        a = Int(try g.i16(at)) << 2
        d = a
        at += 2
        transformed = true
      } else if flags & 0x40 != 0 {  // WE_HAVE_AN_X_AND_Y_SCALE
        a = Int(try g.i16(at)) << 2
        d = Int(try g.i16(at + 2)) << 2
        at += 4
        transformed = true
      } else if flags & 0x80 != 0 {  // WE_HAVE_A_TWO_BY_TWO
        a = Int(try g.i16(at)) << 2
        b = Int(try g.i16(at + 2)) << 2
        c = Int(try g.i16(at + 4)) << 2
        d = Int(try g.i16(at + 6)) << 2
        at += 8
        transformed = true
      }
      guard glyph < glyphCount else { throw .malformed("a component past the glyphs") }
      var (child, childEnds) = try self.points(glyph, depth: depth + 1)
      if transformed {
        child = child.map { p in
          (Glyf.mulFix(p.0, a) + Glyf.mulFix(p.1, c), Glyf.mulFix(p.0, b) + Glyf.mulFix(p.1, d), p.2)
        }
      }
      var dx = 0, dy = 0
      if xy {
        dx = arg1
        dy = arg2
        if transformed && flags & 0x800 != 0 && flags & 0x1000 == 0 {  // SCALED_COMPONENT_OFFSET
          dx = Glyf.mulFix(arg1, a) + Glyf.mulFix(arg2, c)
          dy = Glyf.mulFix(arg1, b) + Glyf.mulFix(arg2, d)
        }
      } else {
        guard arg1 < points.count, arg2 < child.count else { throw .malformed("a matched point past the outline") }
        dx = points[arg1].0 - child[arg2].0
        dy = points[arg1].1 - child[arg2].1
      }
      let base = points.count
      points += child.map { ($0.0 + dx, $0.1 + dy, $0.2) }
      ends += childEnds.map { $0 + base }
      more = flags & 0x20 != 0  // MORE_COMPONENTS
    }
    return (points, ends)
  }

  /// A contour from its points, as FreeType decomposes it: it starts at its
  /// first on-curve point (or its last, or, if there's none, between its
  /// first and last), and two off-curve points in a row imply an on-curve
  /// one between them.
  static func contour(_ c: [(Int, Int, Bool)]) -> Contour {
    func p(_ q: (Int, Int, Bool)) -> Point { Point(Double(q.0), Double(q.1)) }
    func mid(_ a: Point, _ b: Point) -> Point { Point((a.x + b.x) / 2, (a.y + b.y) / 2) }
    let n = c.count
    let start: Point
    let order: [(Int, Int, Bool)]
    if c[0].2 {
      start = p(c[0])
      order = Array(c[1...]) + [c[0]]
    } else if c[n - 1].2 {
      start = p(c[n - 1])
      order = c
    } else {
      start = mid(p(c[0]), p(c[n - 1]))
      order = c
    }
    var segments: [Segment] = []
    var control: Point?
    for q in order {
      if q.2 {
        if let ctrl = control {
          segments.append(.quad(ctrl, p(q)))
          control = nil
        } else {
          segments.append(.line(p(q)))
        }
      } else {
        if let ctrl = control { segments.append(.quad(ctrl, mid(ctrl, p(q)))) }
        control = p(q)
      }
    }
    if let ctrl = control { segments.append(.quad(ctrl, start)) }
    // The closing line to the start is implicit.
    if case .line(let e) = segments.last, e == start { segments.removeLast() }
    return Contour(start: start, segments: segments)
  }
}
