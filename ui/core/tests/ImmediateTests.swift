// SPDX-License-Identifier: BSD-3-Clause

// The immediate-mode core (M6i part 2): layout (pixels, text, percents,
// children's sums, growing, shrinking by strictness, positions), the
// pointer across frames (hover, press, hold, click; a release elsewhere
// isn't a click), slots kept by key and dropped when not built, and a
// frame that draws what the last did reporting no change.

import FoundationEssentials
import GlyphAtlas
import OpenType
import Testing
import TextLayout
import UICore

func ui(_ width: Float = 400, _ height: Float = 300) throws -> UI {
  UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts(), cache: GlyphCache(coverageSize: 512, fieldSize: 128)),
     width: width, height: height)
}

@Test func aRowSharesItsWidth() throws {
  var u = try ui()
  u.begin(FrameInput())
  u.open("row", width: .percent(1), height: .pixels(40), axis: .horizontal)
  u.box("a", width: .pixels(50), height: .percent(1))
  u.box("b", width: .grow(1), height: .percent(1))
  u.box("c", width: .grow(3), height: .pixels(10))
  u.box("d", width: .pixels(30), height: .percent(1))
  u.close()
  u.end()
  let row = UI.key("row", in: UI.key("#root"))
  func r(_ id: String) -> Rect? { u.rect(id, in: row) }
  // 400 less 80: 80 to b, 240 to c.
  #expect(r("a") == Rect(x: 0, y: 0, width: 50, height: 40))
  #expect(r("b") == Rect(x: 50, y: 0, width: 80, height: 40))
  #expect(r("c") == Rect(x: 130, y: 0, width: 240, height: 10))
  #expect(r("d") == Rect(x: 370, y: 0, width: 30, height: 40))
}

@Test func tooMuchShrinksByStrictness() throws {
  var u = try ui(100, 50)
  u.begin(FrameInput(), axis: .horizontal)
  u.box("loose", width: .pixels(80, strictness: 0.5), height: .pixels(10))
  u.box("firm", width: .pixels(80, strictness: 0.5), height: .pixels(10))
  u.box("rigid", width: .pixels(20), height: .pixels(10))
  u.end()
  let root = UI.key("#root")
  // 180 wanted of 100: the two give 80 of their 80 allowance (40 each).
  #expect(u.rect("loose", in: root)?.width == 40 && u.rect("firm", in: root)?.width == 40)
  #expect(u.rect("rigid", in: root) == Rect(x: 80, y: 0, width: 20, height: 10))
}

@Test func textAndChildrenSizeTheirBoxes() throws {
  var u = try ui()
  u.begin(FrameInput())
  u.open("panel", class: "panel", axis: .vertical)
  u.label("one", "Inspector")
  u.label("two", "A longer line of text")
  u.close()
  u.end()
  let panel = UI.key("panel", in: UI.key("#root"))
  let style = Theme.neonTab.style("label"), p = Theme.neonTab.style("panel")
  let two = try #require(u.rect("two", in: panel))
  let measured = u.painter.measure("A longer line of text", style)
  #expect(abs(two.width - measured) < 0.01 && abs(two.height - style.textSize * style.lineHeight) < 0.01)
  // The panel holds both lines, the widest across, plus its padding.
  let box = try #require(u.rect("panel", in: UI.key("#root")))
  #expect(abs(box.width - (measured + p.padding.left + p.padding.right)) < 0.01)
  #expect(abs(box.height - (2 * style.textSize * style.lineHeight + p.padding.top + p.padding.bottom)) < 0.01)
  #expect(two.x == p.padding.left && two.y > box.y + p.padding.top)
}

@Test func thePointerAcrossFrames() throws {
  var u = try ui()
  func frame(_ input: FrameInput) -> Bool {
    u.begin(input)
    let clicked = u.button("ok", "OK")
    u.end()
    return clicked
  }
  _ = frame(FrameInput())  // laid out once
  let r = try #require(u.rect("ok", in: UI.key("#root")))
  let (x, y) = (r.x + 5, r.y + 5)
  #expect(!frame(FrameInput(pointerX: x, pointerY: y)))  // hovered from now
  #expect(u.hot == UI.key("ok", in: UI.key("#root")))
  #expect(!frame(FrameInput(pointerX: x, pointerY: y, down: true, pressed: true)))
  #expect(u.active == u.hot)
  #expect(!frame(FrameInput(pointerX: x, pointerY: y, down: true)))  // held
  #expect(frame(FrameInput(pointerX: x, pointerY: y, released: true)))  // clicked, once
  #expect(!frame(FrameInput(pointerX: x, pointerY: y)))
  // Pressed on it, released elsewhere: no click.
  _ = frame(FrameInput(pointerX: x, pointerY: y, down: true, pressed: true))
  _ = frame(FrameInput(pointerX: 390, pointerY: 290, down: true))
  #expect(!frame(FrameInput(pointerX: 390, pointerY: 290, released: true)))
  #expect(u.active == 0)
}

@Test func slotsLiveWhileBuilt() throws {
  var u = try ui()
  u.begin(FrameInput())
  u.label("a", "A")
  u.label("b", "B")
  u.end()
  let root = UI.key("#root")
  #expect(u.rect("b", in: root) != nil)
  u.begin(FrameInput())
  u.label("a", "A")
  u.end()
  #expect(u.rect("a", in: root) != nil && u.rect("b", in: root) == nil)
}

@Test func anUnchangedFrameChangesNothing() throws {
  var u = try ui()
  func frame(_ text: String) {
    u.begin(FrameInput())
    u.label("a", text)
    _ = u.button("b", "Go")
    u.end()
  }
  frame("Hello")
  #expect(u.changed)
  frame("Hello")
  #expect(!u.changed)
  frame("Hello, world")
  #expect(u.changed)
}

/// Board 09's Info window built with the immediate API inside Chrome's
/// window (TODHCHAI_UI_SAMPLE2 names a file to write it to): a heading,
/// attribute rows in columns, and its buttons in a row.
@Test func anInfoWindowFromTheStoryboard() throws {
  let scale: Float = 2
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts(), scale: scale,
                              cache: GlyphCache(coverageSize: 2048, fieldSize: 256)),
             width: 640, height: 360)
  func build() {
    u.begin(FrameInput())
    let content = Chrome.window(&u.painter, 20, 20, 560, 300, title: "virtio-v1.3-csd01.pdf · Info", focused: true)
    u.open("info", width: .pixels(content.width), height: .pixels(content.height), axis: .vertical,
           at: (content.x, content.y))
    u.box("pad", width: .pixels(0), height: .pixels(10))
    u.open("head", width: .percent(1), height: .children(), axis: .horizontal)
    u.box("indent", width: .pixels(10), height: .pixels(0))
    u.label("name", "virtio-v1.3-csd01.pdf", class: "attributes.heading")
    u.close()
    let rows: [(String, String, Bool)] = [("sys:type", "application/pdf", false), ("size", "3,248,113 bytes", false),
                                          ("mtime", "2026-10-09 14:22", false),
                                          ("sys:origin", "https://docs.oasis-open.org/virtio/…/virtio-v1.3-csd01.pdf", true),
                                          ("sys:origin-app", "browser", true), ("user:Project", "M5", false)]
    for (i, (name, value, origin)) in rows.enumerated() {
      u.open("row\(i)", width: .percent(1), height: .children(), axis: .horizontal)
      u.box("i", width: .pixels(10), height: .pixels(0))
      u.box("n", class: origin ? "attributes.origin" : "attributes.name", text: name, width: .pixels(120), flags: [.text])
      u.box("v", class: origin ? "attributes.origin" : "attributes.value", text: value, width: .grow(), flags: [.text])
      u.close()
    }
    u.spacer("gap")
    u.open("buttons", width: .percent(1), height: .children(), axis: .horizontal)
    u.box("i", width: .pixels(10), height: .pixels(0))
    _ = u.button("origin", "Show origin", class: "button.primary")
    u.box("between", width: .pixels(8), height: .pixels(0))
    _ = u.button("all", "Everything from here")
    u.close()
    u.box("pad2", width: .pixels(0), height: .pixels(10))
    u.close()
    u.end()
  }
  build()
  // The Info window's content sits where Chrome said, buttons at its foot.
  let info = UI.key("info", in: UI.key("#root"))
  let buttons = try #require(u.rect("buttons", in: info))
  let content = try #require(u.rect("info", in: UI.key("#root")))
  #expect(content.x > 20 && content.y > 40)
  #expect(buttons.y + buttons.height <= content.y + content.height && buttons.y > content.y + 150)
  guard let path = ProcessInfo.processInfo.environment["TODHCHAI_UI_SAMPLE2"] else { return }
  var canvas = Canvas(width: Int(640 * scale), height: Int(360 * scale), color: 0x0A0A12)
  u.painter.render(into: &canvas)
  var ppm = Array("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
  for p in canvas.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
  try Data(ppm).write(to: URL(filePath: path))
}
