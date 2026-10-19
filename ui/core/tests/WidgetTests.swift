// SPDX-License-Identifier: BSD-3-Clause

// The widgets (M6i part 3): elision (the middle by default, keeping a
// file's extension; the end for prose; never wider than asked; cut
// between grapheme clusters), clipping, scrolling (the wheel, within the
// content), a list building only the rows in view and selecting by click,
// and the text field (typing, moving by grapheme cluster and by word,
// deleting a cluster, selecting with Shift, with Control-A and by
// dragging, replacing the selection, a click's caret, an IME's preedit,
// focus taken and lost).

import FoundationEssentials
import GlyphAtlas
import OpenType
import Testing
import TextLayout
import UICore

@Test func elisionKeepsBothEndsAndTheExtension() throws {
  let p = Painter(theme: .neonTab, fonts: try storyboardFonts())
  let s = Theme.neonTab.style("table.cell")
  let name = "Massive Attack - Unfinished Sympathy (2012 remaster).flac"
  for width in [120.0, 180, 240, 300] as [Float] {
    let e = p.elide(name, s, width: width)
    #expect(p.measure(e, s) <= width, "\(e) at \(width)")
    #expect(e.contains("…") && e.hasSuffix(".flac") && e.hasPrefix("Mass"), "\(e)")
  }
  #expect(p.elide("short.md", s, width: 300) == "short.md")
  let prose = p.elide("The quick brown fox jumps over the lazy dog", s, width: 150, .end)
  #expect(prose.hasSuffix("…") && prose.hasPrefix("The quick") && p.measure(prose, s) <= 150)
  // Never inside a grapheme cluster: e + combining acute stays together.
  let accents = String(repeating: "e\u{301}", count: 40)
  let cut = p.elide(accents, s, width: 100)
  for (i, u) in cut.unicodeScalars.enumerated() where u.value == 0x301 {
    #expect(i > 0 && Array(cut.unicodeScalars)[i - 1] == "e")
  }
}

@Test func clippingKeepsQuadsInside() {
  var list = DisplayList()
  list.clip((10, 10, 20, 20))
  list.append(UIQuad(x: 0, y: 0, width: 40, height: 40, kind: UIQuad.shape, fill: 0xFFFF_FFFF))
  list.clip(nil)
  list.append(UIQuad(x: 30, y: 30, width: 4, height: 4, kind: UIQuad.shape, fill: 0xFFFF_0000))
  var canvas = Canvas(width: 40, height: 40, color: 0)
  CPURenderer().render(list, cache: GlyphCache(coverageSize: 16, fieldSize: 16), into: &canvas)
  let white = canvas.pixels.enumerated().filter { $0.element == 0xFF_FFFF }.map { $0.offset }
  #expect(white.count == 100 && white.allSatisfy { ($0 % 40) >= 10 && ($0 % 40) < 20 && ($0 / 40) >= 10 && ($0 / 40) < 20 })
  #expect(canvas.pixels[31 * 40 + 31] == 0xFF_0000)
}

@Test func aListScrollsAndBuildsOnlyWhatsInView() throws {
  var u = try ui(400, 200)
  var selection: Int? = nil
  var built: [Int] = []
  func frame(_ input: FrameInput) {
    built = []
    u.begin(input)
    u.list("files", count: 1000, rowHeight: 20, widths: [200, 100], numeric: [false, true], selection: &selection) { r in
      built.append(r)
      return ["file \(r).txt", "\(r * 3) KiB"]
    }
    u.end()
  }
  frame(FrameInput())
  frame(FrameInput())  // laid out: now it knows its height
  #expect(built.count <= 12 && built.first == 0)
  // The wheel scrolls it; it stops at the content's end.
  frame(FrameInput(pointerX: 100, pointerY: 100, scroll: 400))
  #expect(built.first == 400 / 21)
  for _ in 0..<200 { frame(FrameInput(pointerX: 100, pointerY: 100, scroll: 1000)) }
  frame(FrameInput(pointerX: 100, pointerY: 100))
  #expect(built.last == 999 && u.scrollOffset("files", in: UI.key("#root")) == 1000 * 21 - 200)
  // A click selects the row under it.
  frame(FrameInput(pointerX: 100, pointerY: 50))
  frame(FrameInput(pointerX: 100, pointerY: 50, down: true, pressed: true))
  frame(FrameInput(pointerX: 100, pointerY: 50, released: true))
  // 20,800 is row 990 (and 10 px); 50 more is row 992.
  #expect(selection == 992)
}

@Test func theTextField() throws {
  var u = try ui(400, 100)
  var text = "naïve café"
  func frame(_ input: FrameInput) -> FieldSignal {
    u.begin(input)
    let s = u.textField("name", text: &text)
    u.end()
    return s
  }
  _ = frame(FrameInput())
  let r = try #require(u.rect("name", in: UI.key("#root")))
  // A click at the end focuses it, the caret at the end.
  _ = frame(FrameInput(pointerX: r.x + r.width - 2, pointerY: r.y + 5, down: true, pressed: true))
  _ = frame(FrameInput(pointerX: r.x + r.width - 2, pointerY: r.y + 5, released: true))
  #expect(u.focus != 0)
  // Typing, then Backspace over a cluster (e + combining acute).
  var s = frame(FrameInput(text: "s e\u{301}"))
  #expect(s.changed && text == "naïve cafés e\u{301}")
  _ = frame(FrameInput(keys: [KeyPress(.backspace)]))
  #expect(text == "naïve cafés ")
  // Control-Left by words, Shift to select, typing replaces it.
  _ = frame(FrameInput(keys: [KeyPress(.left, control: true), KeyPress(.right, shift: true, control: true)]))
  _ = frame(FrameInput(text: "bar"))
  #expect(text == "naïve bar ")
  // Home, then Delete removes ï? No: removes n; Left and Right by clusters.
  _ = frame(FrameInput(keys: [KeyPress(.home), KeyPress(.delete)]))
  #expect(text == "aïve bar ")
  _ = frame(FrameInput(keys: [KeyPress(.right), KeyPress(.right), KeyPress(.backspace)]))
  #expect(text == "ave bar ")
  // Control-A and typing replaces everything; Enter submits.
  _ = frame(FrameInput(keys: [KeyPress(.character(0x61), control: true)], text: "Größe"))
  s = frame(FrameInput(keys: [KeyPress(.enter)]))
  #expect(text == "Größe" && s.submitted && !s.changed)
  // A preedit is shown, not added.
  let before = u.painter.list.quads.count
  s = frame(FrameInput(preedit: "nihao"))
  #expect(text == "Größe" && !s.changed && u.painter.list.quads.count > before)
  // A press elsewhere takes focus away; then keys do nothing.
  _ = frame(FrameInput(pointerX: 390, pointerY: 95, down: true, pressed: true))
  #expect(u.focus == 0)
  s = frame(FrameInput(text: "x"))
  #expect(text == "Größe" && !s.changed && !s.focused)
}

/// Board 02 ("A query is a folder, and it stays live") built with the
/// widgets (TODHCHAI_UI_SAMPLE3 names a file to write it to).
@Test func aLiveQueryFromTheStoryboard() throws {
  let scale: Float = 2
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts(), scale: scale,
                              cache: GlyphCache(coverageSize: 2048, fieldSize: 256)),
             width: 900, height: 420)
  var selection: Int? = 3
  var query = "Audio:Genre ~= \"trip-hop\" && Audio:Year in 1990..<2000 order by Audio:Year"
  let rows: [(String, String, String, String, String)] = [
    ("Massive Attack - Unfinished Sympathy.flac", "Massive Attack", "1991", "5:08", "ripper"),
    ("Portishead - Glory Box.flac", "Portishead", "1994", "5:06", "ripper"),
    ("Tricky - Overcome.flac", "Tricky", "1995", "4:55", "ripper"),
    ("Sneaker Pimps - 6 Underground.flac", "Sneaker Pimps", "1996", "3:48", "ripper"),
    ("Morcheeba - Trigger Hippie.flac", "Morcheeba", "1996", "4:42", "ripper"),
    ("Massive Attack - Teardrop.flac", "Massive Attack", "1998", "5:30", "browser"),
    ("Portishead - Only You.flac", "Portishead", "1997", "4:58", "ripper"),
  ]
  func build(_ input: FrameInput) {
    u.begin(input)
    let c = Theme.cqw
    let content = Chrome.window(&u.painter, 20, 20, 620, 380, title: "Trip-hop, 90s · query", focused: true)
    u.open("win", width: .pixels(content.width), height: .pixels(content.height), axis: .vertical, at: (content.x, content.y))
    // The query bar: its label, then the query, editable.
    u.open("qbar", class: "query", width: .percent(1), height: .children(), axis: .horizontal)
    u.label("lbl", "Query", class: "query.label")
    u.box("gap", width: .pixels(c(0.6)), height: .pixels(0))
    u.textField("q", text: &query, class: "field", width: .grow())
    u.close()
    u.list("rows", count: rows.count, rowHeight: 22, columns: ["Name", "Audio:Artist", "Audio:Year", "Length", "sys:origin-app"],
           widths: [c(18), c(9), c(6), c(5), c(9)], numeric: [false, false, true, true, false], selection: &selection,
           state: { rows[$0].4 == "browser" ? "new" : "" }) { r in
      [rows[r].0, rows[r].1, rows[r].2, rows[r].3, rows[r].4]
    }
    u.close()
    Chrome.status(&u.painter, content, left: "live · added \"Teardrop\" at journal seq 48213",
                  right: "7 of 41,906 files · 0.6 ms", live: true)
    u.end()
  }
  build(FrameInput())
  build(FrameInput())
  #expect(selection == 3)
  guard let path = ProcessInfo.processInfo.environment["TODHCHAI_UI_SAMPLE3"] else { return }
  var canvas = Canvas(width: Int(900 * scale), height: Int(420 * scale), color: 0x0A0A12)
  u.painter.render(into: &canvas)
  var ppm = Array("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
  for p in canvas.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
  try Data(ppm).write(to: URL(filePath: path))
}

/// A clipboard for the tests: one string.
final class Board: @unchecked Sendable {
  var text: String?
  var clipboard: Clipboard { Clipboard(read: { self.text }, write: { self.text = $0 }) }
}

@Test func aFieldCutsCopiesAndPastes() throws {
  var u = try ui(400, 100)
  let board = Board()
  u.clipboard = board.clipboard
  var text = "hello world"
  var secret = "hunter2"
  func frame(_ input: FrameInput) {
    u.begin(input)
    u.textField("name", text: &text)
    u.textField("pin", text: &secret, secure: true)
    u.end()
  }
  frame(FrameInput())
  let r = try #require(u.rect("name", in: UI.key("#root")))
  frame(FrameInput(pointerX: r.x + 4, pointerY: r.y + 5, down: true, pressed: true))
  frame(FrameInput(pointerX: r.x + 4, pointerY: r.y + 5, released: true))
  let ctl = { (c: UInt8) in KeyPress(.character(UInt32(c)), control: true) }
  // Select all, copy: the text on the clipboard; paste at the end.
  frame(FrameInput(keys: [ctl(0x61), ctl(0x63)]))
  #expect(board.text == "hello world")
  frame(FrameInput(keys: [KeyPress(.end), ctl(0x76)]))
  #expect(text == "hello worldhello world")
  // Cut: the selection goes there, and from the field.
  frame(FrameInput(keys: [ctl(0x61), ctl(0x78)]))
  #expect(text == "" && board.text == "hello worldhello world")
  // A pasted newline is a space; the edit undoes.
  board.text = "a\nb"
  frame(FrameInput(keys: [ctl(0x76)]))
  #expect(text == "a b")
  // A secure field's text never reaches the clipboard.
  let p = try #require(u.rect("pin", in: UI.key("#root")))
  frame(FrameInput(pointerX: p.x + 4, pointerY: p.y + 5, down: true, pressed: true))
  frame(FrameInput(pointerX: p.x + 4, pointerY: p.y + 5, released: true))
  frame(FrameInput(keys: [ctl(0x61), ctl(0x63), ctl(0x78)]))
  #expect(board.text == "a\nb" && secret == "hunter2")
}
