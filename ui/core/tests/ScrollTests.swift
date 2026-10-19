// SPDX-License-Identifier: BSD-3-Clause

// Scrolling (M6l part l2): both axes, by the wheel (Shift and the wheel
// across, or a horizontal wheel), and Be's scrollbars: shown only where
// the content overflows, in room the box keeps, an arrow a line, the
// track a page, the thumb dragged. TODHCHAI_SCROLL_SAMPLE=FILE draws one.

import FoundationEssentials
import GlyphAtlas
import Testing
import TextLayout
import UICore

/// A 400 by 240 scroll box of 40 rows each 900 wide.
struct Grid {
  var u: UI
  var offset: (Float, Float) = (0, 0)

  init(scale: Float = 1) throws {
    u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts(), scale: scale,
                            cache: GlyphCache(coverageSize: 1024, fieldSize: 128)),
           width: 400, height: 240)
  }

  mutating func frame(_ input: FrameInput) {
    u.begin(input)
    u.openScroll("grid", width: .pixels(400), height: .pixels(240))
    for i in 0..<40 {
      u.box("row\(i)", class: "table.cell", text: "row \(i): " + String(repeating: "wide text ", count: 10),
            width: .pixels(900), height: .pixels(20), flags: [.text])
    }
    u.close()
    u.end()
  }

  /// The box's offsets now (from its rows' places).
  func offsets() -> (Float, Float) {
    let first = u.access.first { $0.label.hasPrefix("row 0:") }
    return (first.map { -$0.x } ?? 0, first.map { -$0.y } ?? 0)
  }
}

@Test func theWheelScrollsBothWays() throws {
  var g = try Grid()
  g.frame(FrameInput())
  g.frame(FrameInput())
  g.frame(FrameInput(pointerX: 100, pointerY: 100, scroll: 60))
  g.frame(FrameInput(pointerX: 100, pointerY: 100))
  #expect(g.offsets().1 == 60)
  var across = FrameInput(pointerX: 100, pointerY: 100, scroll: 50)
  across.shift = true
  g.frame(across)
  g.frame(FrameInput(pointerX: 100, pointerY: 100))
  #expect(g.offsets() == (50, 60))
  var tilt = FrameInput(pointerX: 100, pointerY: 100)
  tilt.scrollX = 30
  g.frame(tilt)
  g.frame(FrameInput(pointerX: 100, pointerY: 100))
  #expect(g.offsets().0 == 80)
  // Never past the content's end: 40 rows of 20 less the view (240 less
  // the horizontal bar's 12.8).
  g.frame(FrameInput(pointerX: 100, pointerY: 100, scroll: 10_000))
  g.frame(FrameInput(pointerX: 100, pointerY: 100))
  #expect(abs(g.offsets().1 - (800 - (240 - Theme.cqw(1)))) < 0.5)
}

@Test func theBarsAreBesArrowsTrackAndThumb() throws {
  var g = try Grid()
  g.frame(FrameInput())
  g.frame(FrameInput())
  #expect(g.u.access.contains { $0.label == "vertical scrollbar" } && g.u.access.contains { $0.label == "horizontal scrollbar" })
  let bar = Theme.cqw(1)
  // The down arrow: a line (3cqw).
  func click(_ x: Float, _ y: Float) {
    g.frame(FrameInput(pointerX: x, pointerY: y))
    g.frame(FrameInput(pointerX: x, pointerY: y, down: true, pressed: true))
    g.frame(FrameInput(pointerX: x, pointerY: y, released: true))
    g.frame(FrameInput(pointerX: x, pointerY: y))
  }
  // (Offsets land on whole pixels, M6m: within one of the exact sums.)
  click(400 - bar / 2, 240 - bar - bar / 2)
  #expect(abs(g.offsets().1 - Theme.cqw(3)) < 1)
  // The track below the thumb: a page.
  click(400 - bar / 2, 200)
  #expect(abs(g.offsets().1 - (Theme.cqw(3) + 240 - bar)) < 1)
  // The thumb, dragged to the top.
  let thumbY = g.u.access.first { $0.label == "vertical scroll thumb" }.map { $0.y + $0.height / 2 } ?? -1
  g.frame(FrameInput(pointerX: 400 - bar / 2, pointerY: thumbY))
  g.frame(FrameInput(pointerX: 400 - bar / 2, pointerY: thumbY, down: true, pressed: true))
  g.frame(FrameInput(pointerX: 400 - bar / 2, pointerY: thumbY - 500, down: true))
  g.frame(FrameInput(pointerX: 400 - bar / 2, pointerY: thumbY - 500, released: true))
  g.frame(FrameInput())
  #expect(g.offsets().1 == 0)
}

@Test func noBarsWhereNothingOverflows() throws {
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts()), width: 400, height: 240)
  for _ in 0..<2 {
    u.begin(FrameInput())
    u.openScroll("small", width: .pixels(400), height: .pixels(240))
    u.box("one", class: "table.cell", text: "one", width: .pixels(100), height: .pixels(20), flags: [.text])
    u.close()
    u.end()
  }
  #expect(!u.access.contains { $0.label.hasSuffix("scrollbar") })
}

@Test func aScrolledSample() throws {
  var g = try Grid(scale: 2)
  g.frame(FrameInput())
  g.frame(FrameInput())
  g.frame(FrameInput(pointerX: 100, pointerY: 100, scroll: 140))
  g.frame(FrameInput())
  guard let path = ProcessInfo.processInfo.environment["TODHCHAI_SCROLL_SAMPLE"] else { return }
  var canvas = Canvas(width: 800, height: 480, color: 0x0A0A12)
  g.u.painter.render(into: &canvas)
  var ppm = Array("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
  for px in canvas.pixels { ppm += [UInt8(px >> 16 & 0xFF), UInt8(px >> 8 & 0xFF), UInt8(px & 0xFF)] }
  try Data(ppm).write(to: URL(filePath: path))
}

/// A window's scroll box holding a list's: the wheel moves the innermost
/// that can move, and passes over one that fits.
@Test func theWheelGoesToTheInnermostThatCanMove() throws {
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts()), width: 400, height: 240)
  var innerRows = 40
  func frame(_ input: FrameInput) {
    u.begin(input)
    u.openScroll("window", width: .pixels(400), height: .pixels(240))
    u.openScroll("inner", width: .pixels(300), height: .pixels(100))
    for i in 0..<innerRows {
      u.box("i\(i)", class: "table.cell", text: "inner \(i)", width: .pixels(200), height: .pixels(20), flags: [.text])
    }
    u.close()
    for i in 0..<20 {
      u.box("o\(i)", class: "table.cell", text: "outer \(i)", width: .pixels(200), height: .pixels(20), flags: [.text])
    }
    u.close()
    u.end()
  }
  func y(_ label: String) -> Float { u.access.first { $0.label == label }?.y ?? .nan }
  frame(FrameInput())
  frame(FrameInput(pointerX: 50, pointerY: 50))
  // Over the inner list: it moves, the window doesn't.
  frame(FrameInput(pointerX: 50, pointerY: 50, scroll: 40))
  frame(FrameInput(pointerX: 50, pointerY: 50))
  #expect(y("inner 0") == -40 && y("outer 0") == 100)
  // Below it: the window moves.
  frame(FrameInput(pointerX: 50, pointerY: 200, scroll: 30))
  frame(FrameInput(pointerX: 50, pointerY: 200))
  #expect(y("outer 0") == 70)
  // An inner list that fits passes the wheel to the window.
  innerRows = 2
  frame(FrameInput(pointerX: 50, pointerY: 20))
  frame(FrameInput(pointerX: 50, pointerY: 20))
  frame(FrameInput(pointerX: 50, pointerY: 20, scroll: 30))
  frame(FrameInput(pointerX: 50, pointerY: 20))
  #expect(y("outer 0") == 40)
}

/// A press on a scrollbar doesn't reach the control under it.
@Test func aBarTakesPressesFromWhatsUnderIt() throws {
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts()), width: 400, height: 240)
  var clicked = false
  func frame(_ input: FrameInput) {
    u.begin(input)
    u.openScroll("grid", width: .pixels(400), height: .pixels(240))
    for i in 0..<40 {
      if u.box("b\(i)", class: "button", text: "row \(i)", width: .pixels(400), height: .pixels(20),
               flags: [.text, .clickable]).clicked
      {
        clicked = true
      }
    }
    u.close()
    u.end()
  }
  frame(FrameInput())
  frame(FrameInput())
  let x = 400 - Theme.cqw(1) / 2
  frame(FrameInput(pointerX: x, pointerY: 100))
  frame(FrameInput(pointerX: x, pointerY: 100, down: true, pressed: true))
  frame(FrameInput(pointerX: x, pointerY: 100, released: true))
  #expect(!clicked)
}

/// Columns wider than a list scroll across, their header with them.
@Test func aWideListsHeaderFollowsItsRows() throws {
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts()), width: 400, height: 240)
  var selection: Int? = nil
  func frame(_ input: FrameInput) {
    u.begin(input)
    u.open("pane", width: .pixels(400), height: .pixels(240), axis: .vertical)
    u.list("files", count: 30, rowHeight: 20, columns: ["Name", "Kind", "Size"], widths: [300, 200, 100],
           selection: &selection) { r in ["file \(r)", "text", "\(r) KiB"] }
    u.close()
    u.end()
  }
  func x(_ label: String) -> Float { u.access.first { $0.label == label }?.x ?? .nan }
  frame(FrameInput())
  frame(FrameInput(pointerX: 100, pointerY: 100))
  #expect(u.access.contains { $0.label == "horizontal scrollbar" })
  let before = (x("Size"), x("1 KiB"))
  frame(FrameInput(pointerX: 100, pointerY: 100, scrollX: 120))
  frame(FrameInput(pointerX: 100, pointerY: 100))
  #expect(x("1 KiB") == before.1 - 120)
  #expect(x("Size") == before.0 - 120)
}

/// A list's rows past its box are the list's to scroll, not the window's
/// around it; an icon field scrolls to icons placed past its edges.
@Test func innerContentIsTheInnerBoxs() throws {
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts()), width: 400, height: 240)
  var selection: Int? = nil
  func frame(_ input: FrameInput) {
    u.begin(input)
    u.openScroll("window", width: .pixels(400), height: .pixels(240))
    u.list("files", count: 50, rowHeight: 20, widths: [200], selection: &selection) { ["file \($0)"] }
    u.close()
    u.end()
  }
  frame(FrameInput())
  frame(FrameInput())
  frame(FrameInput())
  #expect(u.access.filter { $0.label == "vertical scrollbar" }.count == 1)
  #expect(!u.access.contains { $0.label == "horizontal scrollbar" })

  var v = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts()), width: 400, height: 240)
  func icons(_ input: FrameInput) {
    v.begin(input)
    v.open("pane", width: .pixels(400), height: .pixels(240), axis: .vertical)
    _ = v.iconField("desk", count: 2) { i in
      (IconRef("folder", color: 0xFFFFFF), "icon \(i)", i == 0 ? 10 : 600, 10, false)
    }
    v.close()
    v.end()
  }
  icons(FrameInput())
  icons(FrameInput())
  #expect(v.access.contains { $0.label == "horizontal scrollbar" })
  let x0 = v.access.first { $0.label == "icon 1" }?.x ?? .nan
  icons(FrameInput(pointerX: 100, pointerY: 100, scrollX: 100))
  icons(FrameInput(pointerX: 100, pointerY: 100))
  #expect(v.access.first { $0.label == "icon 1" }?.x == x0 - 100)
}
