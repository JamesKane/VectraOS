// SPDX-License-Identifier: BSD-3-Clause

// Materials and snapping (theming.md §2.2, §5.2): edges and hairlines on
// whole device pixels at every scale; a bevel's band lit from the top
// left, a groove inset outside and raised within; a gradient mixed in
// light from one end to the other; stripes of whole pixels; directions
// without libm.

import Glibc
import Testing
import TextLayout
import UICore

/// A style drawn at `scale` on grey, the canvas's pixels (0xRRGGBB).
func drawn(_ style: Style, _ x: Float, _ y: Float, _ w: Float, _ h: Float, scale: Float, size: Int = 64) -> Canvas {
  var p = Painter(theme: .base, fonts: Fonts(), scale: scale)
  p.shape(x, y, w, h, style)
  var canvas = Canvas(width: size, height: size, color: 0x808080)
  p.render(into: &canvas)
  return canvas
}

@Test func edgesAndHairlinesLandOnDevicePixels() {
  // A box at a fractional place, its border one logical pixel: at every
  // scale each pixel is the ground, the border or the fill, never a mix.
  let style = Style(fill: 0xFF00_00FF, stroke: 0xFFFF_0000, ink: 0, border: 1)
  for scale: Float in [1, 1.5, 2, 3] {
    let c = drawn(style, 3.3, 4.6, 10.4, 7.7, scale: scale)
    #expect(c.pixels.allSatisfy { [0x808080, 0xFF0000, 0x0000FF].contains($0) }, "at \(scale)")
    // The border is as many pixels wide on each side, a logical pixel
    // rounded: 1, 2, 2, 3.
    let row = (0..<c.width).map { c.pixels[Int(8 * scale) * c.width + $0] }
    let reds = row.filter { $0 == 0xFF0000 }.count
    #expect(reds == 2 * Int(Painter(theme: .base, fonts: Fonts(), scale: scale).hairline(1)), "at \(scale)")
  }
  #expect(Painter(theme: .base, fonts: Fonts(), scale: 1.5).hairline(1) == 2)
  #expect(Painter(theme: .base, fonts: Fonts(), scale: 3).hairline(1) == 3)
}

@Test func aBevelIsLitFromTheTopLeft() {
  let light = Theme.base.color("bevel.light") & 0xFF_FFFF, dark = Theme.base.color("bevel.dark") & 0xFF_FFFF
  let outline: UInt32 = 0x102030, face: UInt32 = 0xC0C0C0
  for scale: Float in [1, 2] {
    let k = Int(scale)
    var style = Style(fill: 0xFF00_0000 | face, stroke: 0xFF00_0000 | outline, ink: 0, border: 1)
    style.materials = [.bevel(.raised, width: 1)]
    let c = drawn(style, 4, 4, 20, 12, scale: scale)
    func at(_ x: Int, _ y: Int) -> UInt32 { c.pixels[y * c.width + x] }
    let x0 = 4 * k, y0 = 4 * k, x1 = 24 * k - 1, y1 = 16 * k - 1
    // The outline, then one band lit above and to the left, shaded below
    // and to the right, then the face.
    #expect(at(x0, y0 + 5 * k) == outline && at(x1, y0 + 5 * k) == outline)
    #expect(at(x0 + k, y0 + 5 * k) == light && at(x0 + 8 * k, y0 + k) == light)
    #expect(at(x1 - k, y0 + 5 * k) == dark && at(x0 + 8 * k, y1 - k) == dark)
    #expect(at(x0 + 2 * k, y0 + 5 * k) == face)
    // A corner's diagonal is lit: the top right's.
    #expect(at(x1 - k, y0 + k) == light)
    // Inset is the other way round.
    style.materials = [.bevel(.inset, width: 1)]
    let i = drawn(style, 4, 4, 20, 12, scale: scale)
    #expect(i.pixels[(y0 + k) * i.width + x0 + 8 * k] == dark && i.pixels[(y1 - k) * i.width + x0 + 8 * k] == light)
    // A groove: inset outside, raised within, so two bands each side.
    style.materials = [.bevel(.groove, width: 1)]
    let g = drawn(style, 4, 4, 20, 12, scale: scale)
    let mid = x0 + 8 * k
    #expect(g.pixels[(y0 + k) * g.width + mid] == dark && g.pixels[(y0 + 2 * k) * g.width + mid] == light)
    #expect(g.pixels[(y1 - k) * g.width + mid] == light && g.pixels[(y1 - 2 * k) * g.width + mid] == dark)
    #expect(g.pixels[(y0 + 3 * k) * g.width + mid] == face)
  }
}

@Test func aGradientRunsEndToEnd() {
  var style = Style(fill: 0xFFFF_FFFF, ink: 0)
  style.materials = [.gradient(0xFF00_0000, 0xFFFF_FFFF, angle: 90)]
  let c = drawn(style, 0, 0, 8, 32, scale: 1)
  let column = (0..<32).map { c.pixels[$0 * c.width + 3] & 0xFF }
  // Top to bottom, rising, from near black to near white (mixed in light,
  // the first row half a pixel in is already 34); a row is one
  // colour.
  #expect(column.first! < 0x30 && column.last! > 0xF8)
  #expect(zip(column, column.dropFirst()).allSatisfy { $0 <= $1 })
  #expect((0..<8).allSatisfy { c.pixels[10 * c.width + $0] == c.pixels[10 * c.width] })
  // Left to right at 0°.
  style.materials = [.gradient(0xFF00_0000, 0xFFFF_FFFF, angle: 0)]
  let h = drawn(style, 0, 0, 32, 8, scale: 1)
  #expect(h.pixels[3 * h.width] & 0xFF < 0x30 && h.pixels[3 * h.width + 31] & 0xFF > 0xF8)
}

@Test func stripesAreWholePixels() {
  var style = Style(fill: 0xFFFF_0000, ink: 0)
  style.materials = [.pattern(.stripes, 0xFFFF_0000, 0xFF00_00FF, pitch: 4)]
  // A period of 4 logical pixels: halves of 2, 3, 4 and 6 device pixels.
  for (scale, half): (Float, Int) in [(1, 2), (1.5, 3), (2, 4), (3, 6)] {
    let c = drawn(style, 2, 2, 16, 16, scale: scale)
    let row = Int(6 * scale), x0 = Int(2 * scale) + 1
    var runs: [Int] = []
    var last: UInt32 = 0
    for x in x0..<x0 + Int(13 * scale) {
      let p = c.pixels[row * c.width + x]
      #expect(p == 0xFF0000 || p == 0x0000FF)
      if p == last { runs[runs.count - 1] += 1 } else { runs.append(1) }
      last = p
    }
    #expect(runs.dropFirst().dropLast().allSatisfy { $0 == half }, "at \(scale): \(runs)")
  }
}

@Test func directionsNeedNoLibm() {
  for degrees in stride(from: -720.0, through: 720.0, by: 7.5) {
    let (x, y) = Shapes.direction(degrees)
    let r = degrees * Double.pi / 180
    #expect(abs(x - cos(r)) < 1e-9 && abs(y - sin(r)) < 1e-9, "at \(degrees)")
  }
  #expect(Shapes.direction(90) == (0, 1))
}
