// SPDX-License-Identifier: BSD-3-Clause

// The renderer finds a shape's distance once for a row's level pixels
// and once a column down its sides (Shapes.level, Shapes.Sides), and
// takes it for the rest. Over random boxes, at fractional places and
// sizes, with corners from none to round, these check that each pixel
// it is taken for has that distance to the bit, at its centre and a
// bevel's quarter pixel to either side, so its pixels are those a
// pixel at a time gives.

import Testing
@testable import UICore

@Test func levelAndSidesKeepTheDistance() {
  var rng = SystemRandomNumberGenerator()
  var levelPixels = 0, sidePixels = 0
  for n in 0..<300 {
    let x = Double.random(in: 0...8, using: &rng), y = Double.random(in: 0...8, using: &rng)
    let w = Double.random(in: 1...60, using: &rng), h = Double.random(in: 1...60, using: &rng)
    let corner = n % 4 == 0 ? 0 : Double.random(in: 0...min(w, h) / 2 + 2, using: &rng)
    let q = UIQuad(x: Float(x), y: Float(y), width: Float(w), height: Float(h), kind: UIQuad.shape,
                   fill: 0xFFFF_FFFF, corner: Float(corner))
    func d(_ sx: Double, _ sy: Double) -> UInt64 { Shapes.distance(q, sx, sy).bitPattern }
    let x0 = Int(x) - 3, x1 = Int(x + w) + 4, y0 = Int(y) - 3, y1 = Int(y + h) + 4
    for m in [0, 0.25] {
      let sides = Shapes.Sides(q, x0, x1, margin: m)
      var column = [Int: (Double, Double, Double)]()
      for py in y0..<y1 {
        let sy = Double(py) + 0.5
        let level = Shapes.level(q, row: py, margin: m).clamped(to: x0..<x1)
        if let first = level.first {
          let at = Double(first) + 0.5
          for px in level {
            let sx = Double(px) + 0.5
            levelPixels += 1
            #expect(d(sx, sy) == d(at, sy), "level, \(q), row \(py), pixel \(px)")
            if m > 0 {
              #expect(d(sx - m, sy) == d(at, sy) && d(sx + m, sy) == d(at, sy), "level's x ±e, \(q), \(px), \(py)")
              #expect(d(sx, sy - m) == d(at, sy - m) && d(sx, sy + m) == d(at, sy + m), "level's y ±e, \(q), \(px), \(py)")
            }
          }
        }
        for px in x0..<x1 where !level.contains(px) {
          guard sides.slot(px, py) != nil else { continue }
          sidePixels += 1
          let sx = Double(px) + 0.5
          let here = (Shapes.distance(q, sx, sy), Shapes.distance(q, sx - m, sy), Shapes.distance(q, sx + m, sy))
          if let kept = column[px] {
            #expect(here.0.bitPattern == kept.0.bitPattern, "side, \(q), column \(px), row \(py)")
            #expect(here.1.bitPattern == kept.1.bitPattern && here.2.bitPattern == kept.2.bitPattern,
                    "side's x ±e, \(q), \(px), \(py)")
          } else {
            column[px] = here
          }
          if m > 0 { #expect(d(sx, sy - m) == d(sx, sy + m), "side's y ±e, \(q), \(px), \(py)") }
        }
      }
    }
  }
  // Both are met often enough to mean something.
  #expect(levelPixels > 10_000 && sidePixels > 10_000, "level \(levelPixels), sides \(sidePixels)")
  print("level and sides: \(levelPixels) and \(sidePixels) pixels, each the distance it is given")
}
