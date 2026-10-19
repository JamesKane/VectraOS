// SPDX-License-Identifier: BSD-3-Clause

// The rasterizer (M6h) on Latin glyphs of the test fonts (Noto Sans, Source
// Code Pro) at text sizes and subpixel positions, against exact coverage
// (the same accumulation, curves flattened to 1/1000 pixel; the
// accumulation itself is checked against clipped polygons' areas) and
// against FreeType's rendering of FreeType's scaled outline, in the same
// frame. FreeType flattens curves coarser (1/16 pixel for quadratics, 1/8
// for cubics: a small dot becomes a diamond), so the check against it is
// that no pixel is further from FreeType's than FreeType's is from exact,
// plus the rasterizer's own bound. End to end, the reader's outline scaled
// here renders as FreeType's scaled outline does.

import CFreeType
import FoundationEssentials
import Glibc
import OpenType
import Raster
import Testing

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // text/raster/tests/RasterTests.swift
  return dir
}()

let testFonts = ["\(repository)/data/fonts/noto-sans/NotoSans-Regular.ttf",
                 "\(repository)/data/fonts/source-code-pro/SourceCodePro-Regular.otf"]

/// What's compared: ASCII, Latin-1, Latin Extended-A, and the
/// punctuation English prose uses (dashes, quotes, ellipsis, euro).
let scalars: [UInt32] = Array(0x21...0x7E) + Array(0xA1...0x17F) + Array(0x2010...0x2026) + [0x20AC]
let sizes = Array(8...24) + [28, 32, 40, 48, 64, 96]
let offsets = [0.0, 0.25, 0.5, 0.75]

func readFile(_ path: String) -> [UInt8]? {
  guard let d = try? Data(contentsOf: URL(filePath: path)) else { return nil }
  return [UInt8](d)
}

/// FreeType's outline of the glyph loaded in `face`, in pixels.
final class Sink {
  var outline = Outline()
}

func freetypeOutline(_ face: FT_Face) -> Outline {
  let sink = Sink()
  var funcs = FT_Outline_Funcs()
  funcs.move_to = { to, user in
    let s = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
    s.outline.contours.append(Contour(start: Point(Double(to!.pointee.x) / 64, Double(to!.pointee.y) / 64), segments: []))
    return 0
  }
  funcs.line_to = { to, user in
    let s = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
    s.outline.contours[s.outline.contours.count - 1].segments
      .append(.line(Point(Double(to!.pointee.x) / 64, Double(to!.pointee.y) / 64)))
    return 0
  }
  funcs.conic_to = { c, to, user in
    let s = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
    s.outline.contours[s.outline.contours.count - 1].segments
      .append(.quad(Point(Double(c!.pointee.x) / 64, Double(c!.pointee.y) / 64),
                    Point(Double(to!.pointee.x) / 64, Double(to!.pointee.y) / 64)))
    return 0
  }
  funcs.cubic_to = { c1, c2, to, user in
    let s = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
    s.outline.contours[s.outline.contours.count - 1].segments
      .append(.cubic(Point(Double(c1!.pointee.x) / 64, Double(c1!.pointee.y) / 64),
                     Point(Double(c2!.pointee.x) / 64, Double(c2!.pointee.y) / 64),
                     Point(Double(to!.pointee.x) / 64, Double(to!.pointee.y) / 64)))
    return 0
  }
  var outline = face.pointee.glyph.pointee.outline
  _ = FT_Outline_Decompose(&outline, &funcs, Unmanaged.passUnretained(sink).toOpaque())
  return sink.outline
}

/// FreeType's rendering of the glyph loaded in `face`, moved by `dx`
/// 64ths of a pixel, into the frame of `like`.
func freetypeBitmap(_ library: FT_Library, _ face: FT_Face, dx: Int, like frame: Bitmap) -> [UInt8] {
  var pixels = [UInt8](repeating: 0, count: frame.width * frame.height)
  guard !pixels.isEmpty else { return pixels }
  var outline = face.pointee.glyph.pointee.outline
  let bottom = frame.top - frame.height
  FT_Outline_Translate(&outline, FT_Pos(dx - frame.left * 64), FT_Pos(-bottom * 64))
  pixels.withUnsafeMutableBufferPointer { buffer in
    var bitmap = FT_Bitmap()
    bitmap.rows = UInt32(frame.height)
    bitmap.width = UInt32(frame.width)
    bitmap.pitch = Int32(frame.width)
    bitmap.buffer = buffer.baseAddress
    bitmap.num_grays = 256
    bitmap.pixel_mode = UInt8(FT_PIXEL_MODE_GRAY.rawValue)
    _ = FT_Outline_Get_Bitmap(library, &outline, &bitmap)
  }
  FT_Outline_Translate(&outline, FT_Pos(frame.left * 64 - dx), FT_Pos(bottom * 64))
  return pixels
}

/// How one rendering differs from another: the largest difference of a
/// pixel (and where), how many pixels differ by more than 1, and the summed
/// coverage (ink) of each.
struct Difference: CustomStringConvertible {
  var largest = 0
  var overOne = 0
  var pixels = 0
  var ink = (0, 0)
  var worst = ""

  mutating func add(_ ours: [UInt8], _ theirs: [UInt8], what: @autoclosure () -> String) {
    var largestHere = 0
    for (a, b) in zip(ours, theirs) {
      let d = abs(Int(a) - Int(b))
      largestHere = max(largestHere, d)
      if d > 1 { overOne += 1 }
      ink.0 += Int(a)
      ink.1 += Int(b)
    }
    pixels += ours.count
    if largestHere > largest {
      largest = largestHere
      worst = what()
    }
  }

  var description: String {
    "\(pixels) pixels, largest difference \(largest) (\(worst)), \(overOne) over 1, ink \(ink.0) vs \(ink.1)"
  }
}

/// What `compare` found over a font's glyphs.
struct Comparison {
  /// The rasterizer against exact coverage (curves flattened to 1/1000
  /// pixel), on FreeType's scaled outline.
  var exact = Difference()
  /// FreeType's rendering against exact coverage: its own flattening.
  var freetypeExact = Difference()
  /// Pixels further from FreeType's than FreeType's is from exact, plus
  /// the rasterizer's own bound: none, if the two agree but for
  /// FreeType's flattening.
  var beyondFreeType = 0
  var beyondFreeTypeWhere = ""
  /// End to end, the reader's outline scaled here against FreeType's
  /// scaled outline, both rendered here.
  var scaling = Difference()
}

/// Two bitmaps' pixels in the smallest frame holding both.
func inOneFrame(_ a: Bitmap, _ b: Bitmap) -> ([UInt8], [UInt8]) {
  let left = min(a.left, b.left), top = max(a.top, b.top)
  let right = max(a.left + a.width, b.left + b.width), bottom = min(a.top - a.height, b.top - b.height)
  let w = right - left, h = top - bottom
  func place(_ m: Bitmap) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<m.height {
      for x in 0..<m.width { out[(top - m.top + y) * w + m.left - left + x] = m[x, y] }
    }
    return out
  }
  return (place(a), place(b))
}

/// The rasterizer's bound against exact coverage, in levels of 255.
let bound = 3

/// Every glyph of `scalars` at every size and offset.
func compare(_ path: String) throws -> Comparison {
  let bytes = try #require(readFile(path))
  let font = try Font(bytes)
  var library: FT_Library?
  #expect(FT_Init_FreeType(&library) == 0)
  defer { FT_Done_FreeType(library) }
  var face: FT_Face?
  #expect(FT_New_Face(library, path, 0, &face) == 0)
  defer { FT_Done_Face(face) }
  var rasterizer = Rasterizer()
  var exact = Rasterizer()
  exact.flatness = 0.001
  var ours = Bitmap(), truth = Bitmap(), scaled = Bitmap()
  var result = Comparison()
  let name = String(path[path.index(after: path.lastIndex(of: "/")!)...])
  for size in sizes {
    #expect(FT_Set_Pixel_Sizes(face, 0, UInt32(size)) == 0)
    let scale = Double(size) / Double(font.metrics.unitsPerEm)
    for scalar in scalars {
      let glyph = font.glyph(for: scalar)
      guard glyph != 0 else { continue }
      #expect(FT_Load_Glyph(face, UInt32(glyph), Int32(FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP)) == 0)
      let theirs = freetypeOutline(face!)
      let outline = try font.outline(glyph)
      for offset in offsets {
        let dx = Int(offset * 64)
        func what() -> String { "\(name) U+\(String(scalar, radix: 16, uppercase: true)) at \(size) px, +\(offset)" }
        // FreeType's outline, moved as FreeType's is moved.
        let moved = Outline(contours: theirs.contours.map { c in
          func m(_ p: Point) -> Point { Point(p.x + Double(dx) / 64, p.y) }
          return Contour(start: m(c.start), segments: c.segments.map { s in
            switch s {
            case .line(let p): .line(m(p))
            case .quad(let a, let p): .quad(m(a), m(p))
            case .cubic(let a, let b, let p): .cubic(m(a), m(b), m(p))
            }
          })
        })
        rasterizer.render(pixels: moved, into: &ours)
        exact.render(pixels: moved, into: &truth)
        let freetype = freetypeBitmap(library!, face!, dx: dx, like: ours)
        result.exact.add(ours.pixels, truth.pixels, what: what())
        result.freetypeExact.add(freetype, truth.pixels, what: what())
        for i in 0..<ours.pixels.count {
          let o = Int(ours.pixels[i]), f = Int(freetype[i]), t = Int(truth.pixels[i])
          if abs(o - f) > abs(f - t) + bound {
            result.beyondFreeType += 1
            result.beyondFreeTypeWhere = what()
          }
        }
        // End to end: the reader's outline, scaled here, in a frame that
        // holds both.
        rasterizer.render(outline, scale: scale, x: offset, into: &scaled)
        let (a, b) = inOneFrame(scaled, ours)
        result.scaling.add(a, b, what: what())
      }
    }
  }
  return result
}

@Test(arguments: testFonts) func rasterizesExactly(_ path: String) throws {
  let c = try compare(path)
  let name = path.split(separator: "/").last!
  print("\(name): against exact coverage, \(c.exact)")
  print("\(name): FreeType against exact coverage, \(c.freetypeExact)")
  print("\(name): scaled here against FreeType's scaling, \(c.scaling)")
  #expect(c.exact.largest <= bound, "\(c.exact)")
  #expect(c.beyondFreeType == 0, "\(c.beyondFreeType) pixels, the last \(c.beyondFreeTypeWhere)")
  // FreeType rounds its points to 1/64 pixel, a composite's twice (its
  // components' points, then their offsets): an edge moves up to 1/64
  // pixel, 4 levels; and the two outlines' curves are flattened apart,
  // each within the bound.
  #expect(c.scaling.largest <= 4 + 2 * bound, "\(c.scaling)")
}

@Test func aSquareIsExact() {
  // A 2x2 square at a quarter pixel: whole pixels, quarter and half ones.
  let square = Outline(contours: [Contour(start: Point(0.25, 0.5), segments: [
    .line(Point(0.25, 2.5)), .line(Point(2.25, 2.5)), .line(Point(2.25, 0.5)),
  ])])
  var r = Rasterizer()
  var b = Bitmap()
  r.render(pixels: square, into: &b)
  #expect(b.width == 3 && b.height == 3 && b.left == 0 && b.top == 3)
  let expected: [UInt8] = [96, 128, 32,
                           192, 255, 64,
                           96, 128, 32]
  #expect(b.pixels == expected)
  // Wound the other way, the same.
  let reversed = Outline(contours: [Contour(start: Point(0.25, 0.5), segments: [
    .line(Point(2.25, 0.5)), .line(Point(2.25, 2.5)), .line(Point(0.25, 2.5)),
  ])])
  r.render(pixels: reversed, into: &b)
  #expect(b.pixels == expected)
}

@Test func anEmptyOutlineIsAnEmptyBitmap() {
  var r = Rasterizer()
  var b = Bitmap()
  r.render(Outline(), scale: 1, into: &b)
  #expect(b.width == 0 && b.height == 0 && b.pixels.isEmpty)
}

/// TODHCHAI_RASTER_SHOW=FONT,HEX,SIZE,OFFSET prints both renderings.
@Test func show() throws {
  guard let spec = getenv("TODHCHAI_RASTER_SHOW").map({ String(cString: $0) }) else { return }
  let parts = spec.split(separator: ",").map(String.init)
  let path = testFonts[Int(parts[0])!]
  let font = try Font(try #require(readFile(path)))
  var library: FT_Library?
  _ = FT_Init_FreeType(&library)
  var face: FT_Face?
  _ = FT_New_Face(library, path, 0, &face)
  let size = Int(parts[2])!, offset = Double(parts[3])!
  _ = FT_Set_Pixel_Sizes(face, 0, UInt32(size))
  let glyph = font.glyph(for: UInt32(parts[1], radix: 16)!)
  _ = FT_Load_Glyph(face, UInt32(glyph), Int32(FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP))
  print(freetypeOutline(face!).contours.map { "\($0.start) \($0.segments)" }.joined(separator: "\n"))
  var r = Rasterizer(), b = Bitmap()
  r.render(try font.outline(glyph), scale: Double(size) / Double(font.metrics.unitsPerEm), x: offset, into: &b)
  let theirs = freetypeBitmap(library!, face!, dx: Int(offset * 64), like: b)
  print("frame \(b.width)x\(b.height) left \(b.left) top \(b.top)")
  if b.width > 12 {
    for y in 0..<b.height {
      for x in 0..<b.width where abs(Int(b[x, y]) - Int(theirs[y * b.width + x])) > 8 {
        print("  (\(x), \(y)) = (\(Double(b.left + x)), \(Double(b.top - y))): \(b[x, y]) vs \(theirs[y * b.width + x])")
      }
    }
    return
  }
  for y in 0..<b.height {
    var line = ""
    for x in 0..<b.width {
      let o = Int(b[x, y]), t = Int(theirs[y * b.width + x])
      line += String(repeating: " ", count: max(0, 4 - String(o).count)) + "\(o)/\(t)" + String(repeating: " ", count: max(0, 4 - String(t).count))
    }
    print(line)
  }
}

/// The exact area of a simple polygon inside the unit square at (px, py),
/// y down: the polygon clipped to it (Sutherland-Hodgman), then its area.
func exactCoverage(_ polygon: [(Double, Double)], _ px: Int, _ py: Int) -> Double {
  var poly = polygon
  func clip(_ inside: ((Double, Double)) -> Bool, _ cut: ((Double, Double), (Double, Double)) -> (Double, Double)) {
    var out: [(Double, Double)] = []
    for i in 0..<poly.count {
      let a = poly[i], b = poly[(i + 1) % poly.count]
      if inside(b) {
        if !inside(a) { out.append(cut(a, b)) }
        out.append(b)
      } else if inside(a) {
        out.append(cut(a, b))
      }
    }
    poly = out
  }
  let x0 = Double(px), x1 = Double(px + 1), y0 = Double(py), y1 = Double(py + 1)
  func atX(_ x: Double) -> ((Double, Double), (Double, Double)) -> (Double, Double) {
    { a, b in (x, a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)) }
  }
  func atY(_ y: Double) -> ((Double, Double), (Double, Double)) -> (Double, Double) {
    { a, b in (a.0 + (b.0 - a.0) * (y - a.1) / (b.1 - a.1), y) }
  }
  clip({ $0.0 >= x0 }, atX(x0))
  if poly.isEmpty { return 0 }
  clip({ $0.0 <= x1 }, atX(x1))
  if poly.isEmpty { return 0 }
  clip({ $0.1 >= y0 }, atY(y0))
  if poly.isEmpty { return 0 }
  clip({ $0.1 <= y1 }, atY(y1))
  var area = 0.0
  for i in 0..<poly.count {
    let a = poly[i], b = poly[(i + 1) % poly.count]
    area += a.0 * b.1 - b.0 * a.1
  }
  return abs(area) / 2
}

@Test func trianglesAreExact() {
  var rng = SystemRandomNumberGenerator()
  var r = Rasterizer(), b = Bitmap()
  var worst = 0
  for _ in 0..<3000 {
    let scale = [1.0, 3.0, 12.0].randomElement(using: &rng)!
    let pts = (0..<3).map { _ in (Double.random(in: 0...scale, using: &rng), Double.random(in: 0...scale, using: &rng)) }
    let outline = Outline(contours: [Contour(start: Point(pts[0].0, pts[0].1),
                                             segments: [.line(Point(pts[1].0, pts[1].1)), .line(Point(pts[2].0, pts[2].1))])])
    r.render(pixels: outline, into: &b)
    // Into the bitmap's frame, y down.
    let poly = pts.map { ($0.0 - Double(b.left), Double(b.top) - $0.1) }
    for y in 0..<b.height {
      for x in 0..<b.width {
        let want = min(255, Int(exactCoverage(poly, x, y) * 256))
        let d = abs(want - Int(b[x, y]))
        if d > worst {
          worst = d
          print("triangle \(pts) pixel \(x),\(y): \(b[x, y]) want \(want)")
        }
      }
    }
  }
  #expect(worst <= 1)
}

@Test func curvesCoverTheirArea() {
  var r = Rasterizer(), b = Bitmap()
  // A circle of radius 4 (four cubics, the usual 0.5523 handles), whose
  // area is 16 pi (the cubics stray by 0.027% of the radius). Full
  // coverage is 255, and each partly covered pixel loses a fraction of a
  // level, so the ink is the area times 255, less up to a level an edge
  // pixel.
  let k = 4 * 0.5522847498
  let circle = Outline(contours: [Contour(start: Point(4, 0), segments: [
    .cubic(Point(4, k), Point(k, 4), Point(0, 4)), .cubic(Point(-k, 4), Point(-4, k), Point(-4, 0)),
    .cubic(Point(-4, -k), Point(-k, -4), Point(0, -4)), .cubic(Point(k, -4), Point(4, -k), Point(4, 0)),
  ])])
  r.render(pixels: circle, into: &b)
  let ink = b.pixels.reduce(0) { $0 + Int($1) }
  let area = 16 * Double.pi * 255
  #expect(b.width == 8 && b.height == 8 && Double(ink) <= area && Double(ink) > area - 28)
  // A quadratic hump over [0, 4] peaking at 1 covers 8/3.
  r.render(pixels: Outline(contours: [Contour(start: Point(0, 0), segments: [.quad(Point(2, 2), Point(4, 0))])]), into: &b)
  let hump = b.pixels.reduce(0) { $0 + Int($1) }
  #expect(Double(hump) <= 8.0 / 3 * 255 && Double(hump) > 8.0 / 3 * 255 - 8)
}
