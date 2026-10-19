// SPDX-License-Identifier: BSD-3-Clause

// The distance fields (M6h), checked against the geometry itself: each
// field of the test fonts' Latin glyphs, drawn eight times larger (bilinear
// samples, the median of RGB at 0.5), must say inside exactly where the
// outline's nonzero winding does, but within a sliver of the true edge;
// the same drawn from alpha alone (a plain distance field) shows what the
// three channels buy at corners. Alpha must be the true signed distance.
// The references are exact: the outline flattened to 1/1000 texel, its
// winding and distances computed directly.

import FoundationEssentials
import Glibc
import MSDF
import OpenType
import Testing

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // text/msdf/tests/MSDFTests.swift
  return dir
}()

let testFonts = ["\(repository)/data/fonts/noto-sans/NotoSans-Regular.ttf",
                 "\(repository)/data/fonts/source-code-pro/SourceCodePro-Regular.otf"]

func readFile(_ path: String) -> [UInt8]? {
  guard let d = try? Data(contentsOf: URL(filePath: path)) else { return nil }
  return [UInt8](d)
}

/// ASCII's and Latin-1's printable characters.
let scalars: [UInt32] = Array(0x21...0x7E) + Array(0xA1...0xFF)

/// The outline as fine polylines, in the field's texel space (y up).
struct Reference {
  var lines: [(Double, Double, Double, Double)] = []

  init(_ outline: Outline, scale: Double) {
    func p(_ q: Point) -> (Double, Double) { (q.x * scale, q.y * scale) }
    for c in outline.contours {
      var at = p(c.start)
      var segments = c.segments
      if case .line(let e)? = segments.last, e == c.start {} else { segments.append(.line(c.start)) }
      for s in segments {
        let n: Int
        let f: (Double) -> (Double, Double)
        switch s {
        case .line(let e):
          let a = at, b = p(e)
          n = 1
          f = { t in (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t) }
        case .quad(let c1, let e):
          let a = at, c = p(c1), b = p(e)
          n = 256
          f = { t in
            let u = 1 - t
            return (u * u * a.0 + 2 * u * t * c.0 + t * t * b.0, u * u * a.1 + 2 * u * t * c.1 + t * t * b.1)
          }
        case .cubic(let c1, let c2, let e):
          let a = at, c = p(c1), d = p(c2), b = p(e)
          n = 512
          f = { t in
            let u = 1 - t
            let k0 = u * u * u, k1 = 3 * u * u * t, k2 = 3 * u * t * t, k3 = t * t * t
            return (k0 * a.0 + k1 * c.0 + k2 * d.0 + k3 * b.0, k0 * a.1 + k1 * c.1 + k2 * d.1 + k3 * b.1)
          }
        }
        var prev = at
        for k in 1...n {
          let q = f(Double(k) / Double(n))
          lines.append((prev.0, prev.1, q.0, q.1))
          prev = q
        }
        at = prev
      }
    }
  }

  func inside(_ x: Double, _ y: Double) -> Bool {
    var w = 0
    for (ax, ay, bx, by) in lines {
      let cross = (bx - ax) * (y - ay) - (by - ay) * (x - ax)
      if ay <= y {
        if by > y && cross > 0 { w += 1 }
      } else if by <= y && cross < 0 {
        w -= 1
      }
    }
    return w != 0
  }

  func distance(_ x: Double, _ y: Double) -> Double {
    var best = Double.infinity
    for (ax, ay, bx, by) in lines {
      let dx = bx - ax, dy = by - ay
      let l2 = dx * dx + dy * dy
      var t = l2 > 0 ? ((x - ax) * dx + (y - ay) * dy) / l2 : 0
      t = min(max(t, 0), 1)
      let ex = ax + dx * t - x, ey = ay + dy * t - y
      best = min(best, ex * ex + ey * ey)
    }
    return best.squareRoot()
  }
}

/// A field's channels sampled bilinearly at texel coordinates (x right, y
/// down), as a GPU samples it.
func sample(_ f: DistanceField, _ x: Double, _ y: Double, _ channel: Int) -> Double {
  let u = x - 0.5, v = y - 0.5
  let i0 = Int(u.rounded(.down)), j0 = Int(v.rounded(.down))
  let fu = u - Double(i0), fv = v - Double(j0)
  func at(_ i: Int, _ j: Int) -> Double {
    let ci = min(max(i, 0), f.width - 1), cj = min(max(j, 0), f.height - 1)
    return Double(f[ci, cj, channel]) / 255
  }
  return (at(i0, j0) * (1 - fu) + at(i0 + 1, j0) * fu) * (1 - fv) + (at(i0, j0 + 1) * (1 - fu) + at(i0 + 1, j0 + 1) * fu) * fv
}

struct Errors {
  var pixels = 0
  /// Pixels on the wrong side, and the farthest of them from the edge (in
  /// texels).
  var wrong = 0
  var farthest = 0.0
  var farthestWhere = ""
}

/// The field of each glyph drawn `k` times larger, against the outline.
func check(_ path: String, texelsPerEm: Double, k: Int = 8, tolerance: Double,
           configure: (inout DistanceFieldGenerator) -> Void = { _ in }) throws -> (msdf: Errors, sdf: Errors, alpha: Double) {
  let font = try Font(try #require(readFile(path)))
  var generator = DistanceFieldGenerator()
  configure(&generator)
  var field = DistanceField()
  var msdf = Errors(), sdf = Errors()
  var alphaError = 0.0
  let scale = texelsPerEm / Double(font.metrics.unitsPerEm)
  for scalar in scalars {
    let glyph = font.glyph(for: scalar)
    guard glyph != 0 else { continue }
    let outline = try font.outline(glyph)
    generator.generate(outline, scale: scale, into: &field)
    guard field.width > 0 else { continue }
    let reference = Reference(outline, scale: scale)
    // Alpha against the true distance, where it isn't clamped.
    for j in 0..<field.height {
      for i in 0..<field.width {
        let x = Double(field.left) + Double(i) + 0.5, y = Double(field.top) - Double(j) - 0.5
        let d = reference.distance(x, y) * (reference.inside(x, y) ? 1 : -1)
        guard abs(d) < field.range / 2 - 0.05 else { continue }
        let decoded = (Double(field[i, j, 3]) / 255 - 0.5) * field.range
        alphaError = max(alphaError, abs(decoded - d))
      }
    }
    // Drawn larger.
    for y in 0..<field.height * k {
      for x in 0..<field.width * k {
        let fx = (Double(x) + 0.5) / Double(k), fy = (Double(y) + 0.5) / Double(k)
        let ox = Double(field.left) + fx, oy = Double(field.top) - fy
        let truth = reference.inside(ox, oy)
        let m = [sample(field, fx, fy, 0), sample(field, fx, fy, 1), sample(field, fx, fy, 2)].sorted()[1]
        let a = sample(field, fx, fy, 3)
        msdf.pixels += 1
        sdf.pixels += 1
        for (inside, errors) in [(m >= 0.5, 0), (a >= 0.5, 1)] where inside != truth {
          let d = reference.distance(ox, oy)
          let what = "U+\(String(scalar, radix: 16, uppercase: true)) at (\(ox), \(oy))"
          if errors == 0 {
            if d > tolerance { msdf.wrong += 1 }
            if d > msdf.farthest { (msdf.farthest, msdf.farthestWhere) = (d, what) }
          } else {
            if d > tolerance { sdf.wrong += 1 }
            if d > sdf.farthest { (sdf.farthest, sdf.farthestWhere) = (d, what) }
          }
        }
      }
    }
  }
  return (msdf, sdf, alphaError)
}

@Test(arguments: testFonts) func fieldsDrawTheirGlyphs(_ path: String) throws {
  let name = path.split(separator: "/").last!
  for size in [24.0, 32.0] {
    let (msdf, sdf, alpha) = try check(path, texelsPerEm: size, tolerance: 0.05)
    print("\(name) at \(Int(size)) texels/em: MSDF \(msdf.wrong) of \(msdf.pixels) pixels wrong past 0.05 texel, the farthest \(msdf.farthest) (\(msdf.farthestWhere)); "
      + "alpha alone \(sdf.wrong), the farthest \(sdf.farthest) (\(sdf.farthestWhere)); alpha's error \(alpha)")
    // No artifacts: nothing drawn wrong farther from the edge than a plain
    // distance field's rounded corners reach (half a texel), and far fewer
    // pixels wrong than a plain field draws (corners kept sharp).
    #expect(msdf.farthest < 0.55)
    #expect(msdf.wrong * 3 < sdf.wrong)
    // Alpha: the true distance, within its byte's step and the polylines.
    #expect(alpha < 0.035)
  }
}

@Test func generatingIsQuick() throws {
  let font = try Font(try #require(readFile(testFonts[0])))
  var generator = DistanceFieldGenerator()
  var field = DistanceField()
  let outlines = try scalars.map { try font.outline(font.glyph(for: $0)) }
  let scale = 32.0 / Double(font.metrics.unitsPerEm)
  let start = ContinuousClock.now
  for o in outlines { generator.generate(o, scale: scale, into: &field) }
  let each = (ContinuousClock.now - start) / outlines.count
  print("a glyph's field at 32 texels/em: \(each)")
}

/// TODHCHAI_MSDF_EXPERIMENT=1: the same at 32 texels/em, uncorrected.
@Test func experiment() throws {
  guard getenv("TODHCHAI_MSDF_EXPERIMENT") != nil else { return }
  for path in testFonts {
    let (msdf, sdf, _) = try check(path, texelsPerEm: 32, tolerance: 0.05) { $0.correctErrors = false }
    print("uncorrected \(path.split(separator: "/").last!): MSDF \(msdf.wrong), farthest \(msdf.farthest) (\(msdf.farthestWhere)); SDF \(sdf.wrong) farthest \(sdf.farthest)")
  }
}

/// TODHCHAI_MSDF_POINT=FONT,HEX,TEXELS_PER_EM,X,Y: the four texels around a
/// point of the outline (y up), and what's there.
@Test func probe() throws {
  guard let spec = getenv("TODHCHAI_MSDF_POINT").map({ String(cString: $0) }) else { return }
  let p = spec.split(separator: ",").map(String.init)
  let font = try Font(try #require(readFile(testFonts[Int(p[0])!])))
  let outline = try font.outline(font.glyph(for: UInt32(p[1], radix: 16)!))
  let scale = Double(p[2])! / Double(font.metrics.unitsPerEm)
  var g = DistanceFieldGenerator()
  var f = DistanceField()
  g.generate(outline, scale: scale, into: &f)
  let x = Double(p[3])!, y = Double(p[4])!
  let fx = x - Double(f.left), fy = Double(f.top) - y
  let i = Int((fx - 0.5).rounded(.down)), j = Int((fy - 0.5).rounded(.down))
  let r = Reference(outline, scale: scale)
  for (di, dj) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
    let ti = i + di, tj = j + dj
    let ox = Double(f.left) + Double(ti) + 0.5, oy = Double(f.top) - Double(tj) - 0.5
    let ch = (0..<4).map { (Double(f[ti, tj, $0]) / 255 - 0.5) * f.range }
    print("texel (\(ox), \(oy)): rgb \(Array(ch[0..<3])) a \(ch[3]) exact \(r.distance(ox, oy) * (r.inside(ox, oy) ? 1 : -1))")
  }
  let m = [sample(f, fx, fy, 0), sample(f, fx, fy, 1), sample(f, fx, fy, 2)].sorted()[1]
  print("at (\(x), \(y)): median \((m - 0.5) * f.range) alpha \((sample(f, fx, fy, 3) - 0.5) * f.range) exact \(r.distance(x, y) * (r.inside(x, y) ? 1 : -1))")
}
