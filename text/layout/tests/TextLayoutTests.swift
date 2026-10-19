// SPDX-License-Identifier: BSD-3-Clause

// The typesetter and canvas (M6h): lines never wider than asked (but for a
// word that can't fit alone), breaks only at UAX #14's opportunities, a
// mandatory break always taken, every character of the text drawn; and
// the specimen page renders (td text-specimen writes it; TODHCHAI_SPECIMEN
// names a file to write it to here, as a binary PPM).

import FoundationEssentials
import GlyphAtlas
import OpenType
import Testing
import TextLayout
import TDUnicode

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // text/layout/tests/TextLayoutTests.swift
  return dir
}()

func noto() throws -> Font {
  let path = "\(repository)/data/fonts/noto-sans/NotoSans-Regular.ttf"
  return try Font([UInt8](try #require(try? Data(contentsOf: URL(filePath: path)))))
}

@Test func linesFitAndBreakWhereUnicodeAllows() throws {
  let setter = Typesetter(try noto())
  let text = Array("The quick brown fox jumps over the lazy dog, and then a hyphenated-word, “quoted text” and an ellipsis… 3–4 times.\nA new paragraph after a mandatory break.".unicodeScalars.map(\.value))
  let breaks = Segmentation.lineBreaks(text).map { $0.index }
  for width in [80.0, 120, 200, 333, 600, 2000] {
    let p = setter.set(text, size: 16, width: width)
    #expect(!p.lines.isEmpty)
    for (n, line) in p.lines.enumerated() {
      // No wider than asked, unless one unbreakable piece is wider.
      let glyphs = p.glyphs[line.glyphs]
      if line.width > width + 1e-9 {
        let clusters = Set(glyphs.map(\.cluster))
        let inner = breaks.filter { b in clusters.contains(where: { $0 < b }) && clusters.contains(where: { $0 >= b }) }
        #expect(inner.isEmpty, "line \(n) at \(width): \(line.width) wide, breakable")
      }
      // Each line after the first starts at a break opportunity.
      if n > 0, let first = glyphs.first {
        #expect(breaks.contains { b in b <= first.cluster && !glyphs.contains(where: { g in g.cluster < b }) })
      }
    }
    // The mandatory break: "A new paragraph" starts a line.
    let a = text.firstIndex(of: 0x0A)! + 1
    #expect(p.lines.contains { $0.glyphs.first.map { p.glyphs[$0].cluster == a } ?? false })
  }
  // Every non-space character drawn, once all fits on a line.
  let wide = setter.set(text, size: 16, width: 1e9)
  let drawn = Set(wide.glyphs.map(\.cluster))
  for (i, c) in text.enumerated() where c != 0x20 && c != 0x0A {
    #expect(drawn.contains(i) || wide.glyphs.contains { $0.cluster < i && text[$0.cluster] == 0x66 }, "character \(i)")
  }
}

@Test func theSpecimenRenders() throws {
  let font = try noto()
  var cache = GlyphCache(coverageSize: 1024, fieldSize: 512)
  let page = Specimen.render(width: 1280, height: 800, font: font, cache: &cache)
  // Ink on the page, in the ink's colour and the accent's, on the background.
  #expect(page.pixels.contains(Specimen.ink) && page.pixels.contains(Specimen.accent))
  #expect(page.pixels.filter { $0 != Specimen.background }.count > 20_000)
  if let path = ProcessInfo.processInfo.environment["TODHCHAI_SPECIMEN"] {
    var ppm = Array("P6\n1280 800\n255\n".utf8)
    for p in page.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
    try Data(ppm).write(to: URL(filePath: path))
  }
}
