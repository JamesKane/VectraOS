// SPDX-License-Identifier: BSD-3-Clause

// The renderer blends stripes and checks a run of one colour at a time
// (CPURenderer.runs). Over random boxes, at fractional places and sizes,
// with corners from none to round, pitches from one pixel up and
// colours opaque and not, on a ground of every colour, these check that
// its pixels are those each pixel's distance, coverage and colour give,
// blended one at a time.

import Testing
import GlyphAtlas
import TextLayout
@testable import UICore

@Test func patternRunsArePixelsAtATime() {
  var rng = SystemRandomNumberGenerator()
  for n in 0..<200 {
    let x = Double.random(in: 0...8, using: &rng), y = Double.random(in: 0...8, using: &rng)
    let w = Double.random(in: 1...60, using: &rng), h = Double.random(in: 1...60, using: &rng)
    let corner = n % 4 == 0 ? 0 : Double.random(in: 0...min(w, h) / 2 + 2, using: &rng)
    func color() -> UInt32 { (n % 3 == 0 ? 0xFF00_0000 : UInt32.random(in: 0...255, using: &rng) << 24) | UInt32.random(in: 0...0xFF_FFFF, using: &rng) }
    let q = UIQuad(x: Float(x), y: Float(y), width: Float(w), height: Float(h),
                   kind: n % 2 == 0 ? UIQuad.stripes : UIQuad.checks, fill: color(), corner: Float(corner),
                   border: Float(Int.random(in: 0...12, using: &rng)), stroke: color())
    var ground = [UInt32](repeating: 0, count: 80 * 80)
    for i in ground.indices { ground[i] = i % 7 < 4 ? 0x30_6090 : UInt32.random(in: 0...0xFF_FFFF, using: &rng) }
    var drawn = Canvas(width: 80, height: 80, color: 0)
    drawn.pixels = ground
    CPURenderer().render(DisplayList(quads: [q]), cache: GlyphCache(coverageSize: 16, fieldSize: 16), into: &drawn)
    // Each pixel as material's ink finds it, from its distance.
    var reference = Canvas(width: 80, height: 80, color: 0)
    reference.pixels = ground
    let half = max(1, Int(q.border) / 2), ox = Int(q.x), oy = Int(q.y)
    func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
    for py in Int(q.y)..<Int(q.y + q.height) + 1 {
      for px in Int(q.x)..<Int(q.x + q.width) + 1 {
        let cover = min(max(0.5 - Shapes.distance(q, Double(px) + 0.5, Double(py) + 0.5), 0), 1)
        guard cover > 0 else { continue }
        let first = q.kind == UIQuad.stripes
          ? floorDiv((px - ox) - (py - oy), half) & 1 == 0
          : (floorDiv(px - ox, half) + floorDiv(py - oy, half)) & 1 == 0
        let c = first ? q.fill : q.stroke
        reference.blend(px, py, c & 0xFF_FFFF, Int(Double(c >> 24) * cover + 0.5))
      }
    }
    let wrong = (0..<drawn.pixels.count).filter { drawn.pixels[$0] != reference.pixels[$0] }
    #expect(wrong.isEmpty, "\(q): \(wrong.count) pixels, the first at \(wrong.first.map { ($0 % 80, $0 / 80) }!)")
  }
}
