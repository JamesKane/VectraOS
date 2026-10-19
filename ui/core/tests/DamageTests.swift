// SPDX-License-Identifier: BSD-3-Clause

// A frame's damage (M6m part m2): around what changed, nothing when
// nothing did.

import GlyphAtlas
import Testing
import TextLayout
import UICore

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
