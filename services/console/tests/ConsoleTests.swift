// SPDX-License-Identifier: BSD-3-Clause

// The framebuffer console's text grid and renderer (M3j), and the font
// table: generated from data/fonts/spleen, it must match fontgen's output.

import Console
import FontGen
import Foundation
import Testing

let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized.path

@Test func committedFontsMatchTheData() throws {
  let fonts = try [("spleen8x16", "spleen-8x16.bdf"), ("spleen16x32", "spleen-16x32.bdf")].map { name, file in
    (name: name, font: try BDFFont(bdf: String(contentsOfFile: "\(root)/data/fonts/spleen/\(file)", encoding: .utf8)))
  }
  let committed = try String(contentsOfFile: "\(root)/services/console/lib/generated/Spleen.swift", encoding: .utf8)
  #expect(committed == swiftTable(fonts, spdx: "BSD-2-Clause", notice: spleenNotice),
          "regenerate: .build/debug/fontgen services/console/lib/generated/Spleen.swift data/fonts/spleen")
}

@Test func fontHasWhatTheConsoleShows() {
  let f = Font.spleen8x16
  #expect(f.width == 8 && f.height == 16 && Font.spleen16x32.width == 16)
  for c in [0x20, 0x41, 0x7E, 0x3F, 0x2500, 0x2502, 0x250C] as [UInt32] { #expect(f.glyph(c) != nil) }
  #expect(f.glyph(0x4E00) == nil)
  // A space is blank; 'A' isn't, and its top row is blank (it sits on the baseline).
  let space = f.glyph(0x20)!, a = f.glyph(0x41)!
  #expect((0..<16).allSatisfy { f.row(space, $0) == 0 })
  #expect((0..<16).contains { f.row(a, $0) != 0 })
  #expect(f.row(a, 0) == 0)
}

func rows(_ g: TextGrid) -> [String] { (0..<g.rows).map { g.text($0) } }

@Test func gridWritesWrapsAndScrolls() {
  var g = TextGrid(columns: 6, rows: 3)
  g.write(Array("dia\tx\r\nwörld!!".utf8))
  // The tab stops at the last column, where the x then goes.
  #expect(rows(g) == ["dia  x", "wörld!", "!"])
  g.clean()
  g.write(Array("\nscroll".utf8))
  #expect(rows(g) == ["wörld!", "!", "scroll"])
  // Past the last column a tab does nothing, and the next character wraps.
  g.write(Array("\t\tz".utf8))
  #expect(rows(g) == ["!", "scroll", "z"])
  #expect(g.dirty.allSatisfy { $0 })
}

@Test func gridDropsEscapesAndReplacesBadUTF8() {
  var g = TextGrid(columns: 20, rows: 2)
  g.write(Array("\u{1B}[1;32mok\u{1B}[0m".utf8))
  g.write([0xE2, 0x94])  // the first two bytes of U+2500, then the last
  g.write([0x80, 0xFF, 0x41, 0xC3])  // ─, then a bad byte, A, and a sequence cut short
  g.write([0x41])
  #expect(rows(g)[0] == "ok─\u{FFFD}A\u{FFFD}A")
}

@Test func rendererDrawsGlyphsAndMargins() {
  let font = Font.spleen8x16
  // 2 columns and 1 row of 8x16 cells, with a 4-pixel margin right and below.
  let (w, h, stride) = (20, 20, 24)
  let buffer = UnsafeMutableRawPointer.allocate(byteCount: stride * h * 4, alignment: 16)
  defer { buffer.deallocate() }
  buffer.initializeMemory(as: UInt32.self, repeating: 0xDEAD_BEEF, count: stride * h)
  let r = Renderer(unsafe: buffer, width: w, height: h, stride: stride, format: .bgr888x, font: font)
  var g = r.grid()
  #expect(g.columns == 2 && g.rows == 1)
  g.color = 3  // amber
  g.write(Array("A".utf8))
  #expect(r.render(&g) == 1)
  #expect(r.render(&g) == 0)  // nothing changed
  let px = { (x: Int, y: Int) in buffer.load(fromByteOffset: (y * stride + x) * 4, as: UInt32.self) }
  let amber = PixelFormat.bgr888x.pixel(Palette.amber), bg = PixelFormat.bgr888x.pixel(Palette.background)
  #expect(amber == 0x00_00B0FF)
  let a = font.glyph(0x41)!
  for y in 0..<16 {
    for x in 0..<8 { #expect(px(x, y) == (font.pixel(a, x: x, y: y) ? amber : bg)) }
    for x in 8..<20 { #expect(px(x, y) == bg) }  // the blank cell and the margin
  }
  for y in 16..<20 { #expect(px(0, y) == bg && px(19, y) == bg) }
  #expect(px(20, 0) == 0xDEAD_BEEF)  // past the width, inside the stride: untouched
}

@Test func aGridMovesIntoASmallerOne() {
  var big = TextGrid(columns: 20, rows: 4)
  big.write(Array("one\n".utf8))
  big.color = 3
  big.write(Array("two is longer\nthree\n".utf8))
  let small = TextGrid(columns: 6, rows: 3, from: big)
  // The last rows that fit, cut to the width; colors kept; the cursor below.
  #expect(small.text(0) == "two is")
  #expect(small.text(1) == "three")
  #expect(small.cell(1, 0).color == 3)
  #expect(small.row == 2 && small.column == 0)
}
