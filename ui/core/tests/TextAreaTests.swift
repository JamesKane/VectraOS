// SPDX-License-Identifier: BSD-3-Clause

// The text area (M6m part m1): a document of lines edited as a person
// does. TODHCHAI_EDITOR_SAMPLE=FILE draws one.

import FoundationEssentials
import GlyphAtlas
import Testing
import TextLayout
import UICore

struct Area {
  var u: UI
  var doc: TextDocument
  var changes = 0

  init(_ text: String, width: Float = 400, height: Float = 240, scale: Float = 1) throws {
    u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts(), scale: scale,
                            cache: GlyphCache(coverageSize: 1024, fieldSize: 128)),
           width: width, height: height)
    doc = TextDocument(text)
    frame(FrameInput())
    frame(FrameInput())
    // Focused by a click at its start.
    frame(FrameInput(pointerX: 12, pointerY: 12, down: true, pressed: true))
    frame(FrameInput(pointerX: 12, pointerY: 12, released: true))
  }

  mutating func frame(_ input: FrameInput) {
    u.begin(input)
    if u.textArea("text", document: &doc, label: "Text", width: .pixels(u.width), height: .pixels(u.height)).changed {
      changes += 1
    }
    u.end()
  }

  mutating func keys(_ ks: KeyPress...) { frame(FrameInput(keys: ks)) }
  mutating func type(_ s: String) { frame(FrameInput(text: s)) }
}

@Test func typingEnterAndDeletingAcrossLines() throws {
  var a = try Area("hello\nworld")
  #expect(a.doc.caret == TextPosition(line: 0, column: 0))
  a.keys(KeyPress(.end))
  a.type(" there")
  a.keys(KeyPress(.enter))
  a.type("new")
  #expect(a.doc.text == "hello there\nnew\nworld")
  // Backspace at a line's start joins it to the one above.
  a.keys(KeyPress(.down), KeyPress(.home), KeyPress(.backspace))
  #expect(a.doc.text == "hello there\nnewworld" && a.doc.caret == TextPosition(line: 1, column: 3))
  // Delete at a line's end joins the next.
  a.keys(KeyPress(.up), KeyPress(.end), KeyPress(.delete))
  #expect(a.doc.text == "hello therenewworld")
}

@Test func motionsSelectionAndUndoByWord() throws {
  var a = try Area("one two three\nfour")
  // Control-Right: each word's end, spaces skipped.
  a.keys(KeyPress(.right, control: true), KeyPress(.right, control: true))
  #expect(a.doc.caret.column == 7)
  a.keys(KeyPress(.right))
  // Down keeps the column's x, clamped to the line; Up comes back to it.
  a.keys(KeyPress(.down))
  #expect(a.doc.caret == TextPosition(line: 1, column: 4))
  a.keys(KeyPress(.up))
  #expect(a.doc.caret == TextPosition(line: 0, column: 8))
  // Shift extends; typing replaces the selection.
  a.keys(KeyPress(.end, shift: true))
  #expect(a.doc.selectedText == "three")
  a.type("3")
  #expect(a.doc.text == "one two 3\nfour")
  // Typing, a key at a time, joins by word (a space ends one): Undo takes
  // back a word at a time.
  for c in " more words" { a.type(String(c)) }
  #expect(a.doc.text == "one two 3 more words\nfour")
  let undo = FrameInput(keys: [KeyPress(.character(0x7A), control: true)])
  a.frame(undo)
  #expect(a.doc.text == "one two 3 more \nfour")
  a.frame(undo)
  #expect(a.doc.text == "one two 3 \nfour")
  a.frame(undo)
  #expect(a.doc.text == "one two three\nfour")
  a.frame(FrameInput(keys: [KeyPress(.character(0x7A), shift: true, control: true)]))
  #expect(a.doc.text == "one two 3 \nfour")
  // Select all, and a replacement with lines.
  a.keys(KeyPress(.character(0x61), control: true))
  a.type("a\nb")
  #expect(a.doc.lines.count == 2 && a.doc.text == "a\nb")
}

@Test func aClickPlacesTheCaretAndTheCaretStaysInView() throws {
  var a = try Area((0..<200).map { "line \($0)" }.joined(separator: "\n"))
  // A click on the third line, after its text.
  let lh = Theme.cqw(1) * 1.4
  a.frame(FrameInput(pointerX: 300, pointerY: Theme.cqw(0.5) + lh * 2.5, down: true, pressed: true))
  a.frame(FrameInput(pointerX: 300, pointerY: Theme.cqw(0.5) + lh * 2.5, released: true))
  #expect(a.doc.caret == TextPosition(line: 2, column: 6))
  // Control-End: the last line, and the view follows it there.
  a.keys(KeyPress(.end, control: true))
  a.frame(FrameInput())
  #expect(a.doc.caret.line == 199)
  #expect(a.u.access.contains { $0.label == "vertical scrollbar" })
  let thumb = try #require(a.u.access.first { $0.label == "vertical scroll thumb" })
  let track = try #require(a.u.access.first { $0.label == "vertical scrollbar" })
  #expect(thumb.y + thumb.height > track.y + track.height - Theme.cqw(1) - 1)
}

@Test func anEditorSample() throws {
  var a = try Area("""
    Todhchai's editor, as StyledEdit was:
    a document of lines, a caret, a selection.

    Typing joins into words for Undo; Up and Down
    keep the column's x; the view follows the caret.
    """, width: 400, height: 240, scale: 2)
  a.keys(KeyPress(.down), KeyPress(.right, control: true), KeyPress(.right, shift: true, control: true))
  a.frame(FrameInput())
  guard let path = ProcessInfo.processInfo.environment["TODHCHAI_EDITOR_SAMPLE"] else { return }
  var canvas = Canvas(width: 800, height: 480, color: 0x0A0A12)
  a.u.painter.render(into: &canvas)
  var ppm = Array("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
  for px in canvas.pixels { ppm += [UInt8(px >> 16 & 0xFF), UInt8(px >> 8 & 0xFF), UInt8(px & 0xFF)] }
  try Data(ppm).write(to: URL(filePath: path))
}
