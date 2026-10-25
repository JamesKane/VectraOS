// SPDX-License-Identifier: BSD-3-Clause

// A frame's damage (M6m part m2): around what changed, nothing when
// nothing did.

import GlyphAtlas
import Testing
import TextLayout
@testable import UICore

@Test func damageIsWhatChanged() throws {
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts(),
                              cache: GlyphCache(coverageSize: 1024, fieldSize: 128)), width: 400, height: 300)
  var second = "two"
  func frame() {
    u.begin(FrameInput())
    u.box("a", class: "table.cell", text: "one", flags: [.text])
    u.box("b", class: "table.cell", text: second, flags: [.text])
    u.box("c", class: "table.cell", text: "three", flags: [.text])
    u.end()
  }
  frame()
  frame()
  #expect(u.damage == nil)
  second = "TWO"
  frame()
  let d = try #require(u.damage)
  let b = try #require(u.access.first { $0.label == "TWO" })
  // Around the second line only: not the first's, not the third's.
  #expect(d.y >= b.y - 2 && d.y + d.height <= b.y + b.height + 2 && d.width < 200)
}

// A menu over clipped content ends that clip; opening and closing it, or
// a clip that moves, damage what they change, and drawing only the damage
// over the last frame gives the frame drawn whole.
@Test func damageUnderClipsIsWhatChanged() throws {
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts(),
                              cache: GlyphCache(coverageSize: 1024, fieldSize: 128)), width: 640, height: 400)
  var shown = false, deskWidth: Float = 640
  func frame() {
    u.begin(FrameInput())
    u.open("desk", class: "table.cell", width: .pixels(deskWidth), height: .percent(1), flags: [.clip])
    for i in 0..<12 { _ = u.box("i\(i)", class: "table.cell", text: "item \(i) of the desk", flags: [.text]) }
    u.close()
    _ = u.menu("m", shown: shown, at: (300, 200), items: ["Open", "Close", "Rename"])
    u.end()
  }
  var drawn = Canvas(width: 640, height: 400, color: 0)
  frame()
  u.painter.render(into: &drawn)
  var areas: [Float] = []
  for step in 0..<6 {
    switch step {
    case 0, 2: shown = true
    case 1, 3: shown = false
    case 4: deskWidth = 100
    default: deskWidth = 640
    }
    frame()
    let d = u.damage
    areas.append(d.map { $0.width * $0.height } ?? 0)
    if let d {
      drawn.fill(x: Int(d.x), y: Int(d.y), width: Int(d.x + d.width) + 1 - Int(d.x),
                 height: Int(d.y + d.height) + 1 - Int(d.y), 0)
      u.painter.render(into: &drawn, region: d)
    }
    var whole = Canvas(width: 640, height: 400, color: 0)
    u.painter.render(into: &whole)
    #expect(drawn.pixels == whole.pixels, "step \(step)")
  }
  // The menu's opening and closing damage it, not the window.
  for a in areas.prefix(4) { #expect(a > 0 && a < 640 * 400 / 4) }
}

// The damage table takes a quad's hash's low bits: a desk's icons, at
// whole points, spread over it rather than probing one chain (a frame of
// three thousand quads matched in microseconds, not milliseconds).
@Test func quadHashesSpreadOverTheTable() {
  var buckets = [Bool](repeating: false, count: 2048)
  for y in 0..<32 {
    for x in 0..<32 {
      let q = UIQuad(x: Float(x * 16), y: Float(y * 16), width: 16, height: 16, kind: UIQuad.shape, fill: 0xFF33_6699)
      buckets[Int(truncatingIfNeeded: UI.hash(q)) & 2047] = true
    }
  }
  // 1024 quads at random would fill about 800 of 2048.
  #expect(buckets.filter { $0 }.count > 640)
}
