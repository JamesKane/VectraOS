// SPDX-License-Identifier: BSD-3-Clause

// The decorations come from the theme: the base theme's by default, and
// Neon Tab's are the focused colours todhchai's Radharc hardcoded (the
// desk, the cyan edge, the amber tab and its dark title).

import FoundationEssentials
import Radharc
import Testing
import Themes

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // services/radharc/tests/DecorationsTests.swift
  return dir
}()

func installed(_ name: String) -> [UInt8]? {
  (try? Data(contentsOf: URL(filePath: "\(repository)/ui/theme/themes/\(name)"))).map { [UInt8]($0) }
}

@Test func neonTabsDecorationsAreTodhchais() throws {
  let d = Decorations(try Theme.resolve(ThemeStack(theme: "neon-tab"), installed: installed))
  #expect(d.desk == 0x0A0A12)
  #expect(d.edgeFocused == 0x00E5FF)
  #expect(d.tabFocused == 0xFFB000)
  #expect(d.tabInkFocused == 0x0A0A12)
}

@Test func aNewThemeDamagesTheScreen() throws {
  let s = Scene(width: 320, height: 240)
  _ = s.takeDamage()
  #expect(s.decorations == Decorations.base)
  s.decorations = Decorations(try Theme.resolve(ThemeStack(theme: "neon-tab"), installed: installed))
  #expect(s.takeDamage() == Rect(x: 0, y: 0, width: 320, height: 240))
  let same = s.decorations
  s.decorations = same
  #expect(s.takeDamage().isEmpty)
}

// A window's frame drawn by UICore's Chrome (Frames.swift): the scene,
// composing it over the desk, shows what Chrome draws there itself, its
// matte giving the edges and the room beside the tab; and the frame's
// geometry is the theme's.

import GlyphAtlas
import OpenType
import TextLayout
import UICore

/// Every face in data/fonts.
func allFonts() -> [Font] {
  let dir = "\(repository)/data/fonts"
  var out: [Font] = []
  for family in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
    for face in (try? FileManager.default.contentsOfDirectory(atPath: dir + "/" + family)) ?? []
    where face.hasSuffix(".ttf") || face.hasSuffix(".otf") {
      if let d = try? Data(contentsOf: URL(filePath: "\(dir)/\(family)/\(face)")), let f = try? Font([UInt8](d)) {
        out.append(f)
      }
    }
  }
  return out
}

@Test(arguments: ["platinum-indigo", "neon-tab"])
func aFrameIsComposedAsChromeDrawsIt(_ name: String) throws {
  let theme = try Theme.resolve(ThemeStack(theme: name), installed: installed)
  let fonts = Fonts(theme: theme, from: allFonts())
  var painter = Painter(theme: theme, fonts: fonts, cache: GlyphCache(coverageSize: 512, fieldSize: 64))
  let s = Scene(width: 400, height: 300)
  s.decorations = Decorations(theme)
  let (w, _) = s.open(title: "Notes", width: 200, height: 100)
  _ = s.move(w.id, x: 60, y: 70)
  // Drawn small for its title, made at its size in nine slices.
  let c = WindowChrome(FrameTemplate(&painter, title: "Notes", focused: true), contentWidth: 200, contentHeight: 100)
  // Drawn again by the same painter: the same pixels (its glyphs kept).
  let again = WindowChrome(FrameTemplate(&painter, title: "Notes", focused: true), contentWidth: 200, contentHeight: 100)
  #expect((0..<(c.width * c.height)).allSatisfy { c.pixel($0) == again.pixel($0) })
  s.setChrome(w.id, c)
  // The geometry is the frame's.
  let f = s.window(w.id)!.frame
  #expect(f == Rect(x: 60 - c.border, y: 70 - c.tabHeight - c.border, width: c.width - 2 * c.margin,
                    height: c.height - 2 * c.margin))
  #expect(s.window(w.id)!.tab.width == c.tabWidth && c.tabWidth < c.width)
  #expect(s.window(w.id)!.closeBox.width > 0 && s.window(w.id)!.zoomBox.x > s.window(w.id)!.closeBox.x)
  // Composed, and drawn by Chrome over the desk.
  var screen = [UInt32](repeating: 0, count: 400 * 300)
  screen.withUnsafeMutableBufferPointer { b in
    unsafe s.compose(Rect(x: 0, y: 0, width: 400, height: 300), into: b.baseAddress!, stride: 400) { _, _ in 0 }
  }
  // (A painter of its own: one that drew already has its glyphs cached.)
  var p = Painter(theme: theme, fonts: fonts, cache: GlyphCache(coverageSize: 512, fieldSize: 64))
  Chrome.window(&p, Float(f.x), Float(f.y), Float(f.width), Float(f.height), title: "Notes", focused: true)
  var reference = Canvas(width: 400, height: 300, color: s.decorations.desk)
  p.render(into: &reference)
  var worst: UInt32 = 0, differing = 0
  for y in 0..<300 {
    for x in 0..<400 where !(x >= 200 && x < 220 && y >= 150 && y < 175) {  // (the cursor, the scene's alone)
      let a = screen[y * 400 + x], b = reference.pixels[y * 400 + x] & 0xFF_FFFF
      var d: UInt32 = 0
      for shift: UInt32 in [16, 8, 0] {
        let ca = a >> shift & 0xFF, cb = b >> shift & 0xFF
        d = max(d, ca > cb ? ca - cb : cb - ca)
      }
      worst = max(worst, d)
      if d > 0 { differing += 1 }
    }
  }
  #expect(worst <= 2, "\(name): the worst channel off by \(worst), \(differing) pixels differ")
}

/// The clock (D114): its text; drawn in a window's area in the scene's
/// glyphs until a face for the time shown is set, then from the face,
/// right-aligned in the theme's style; a new minute damages only it.
@Test func aClockIsDrawnInItsAreaAndChangesAtTheMinute() throws {
  #expect(ClockText.text(minuteOfDay: 9 * 60 + 5, hours24: true) == "09:05")
  #expect(ClockText.text(minuteOfDay: 0, hours24: false) == "12:00 AM")
  #expect(ClockText.text(minuteOfDay: 13 * 60 + 30, hours24: false) == "1:30 PM")
  #expect(ClockText.minuteOfDay(86_400_000_000_000 + 61_000_000_000) == 1)
  let theme = try Theme.resolve(ThemeStack(theme: "platinum-indigo"), installed: installed)
  var painter = Painter(theme: theme, fonts: Fonts(theme: theme, from: allFonts()),
                        cache: GlyphCache(coverageSize: 512, fieldSize: 64))
  let s = Scene(width: 400, height: 300)
  let (w, _) = s.open(title: "Deskbar", width: 200, height: 60)
  _ = s.setPanel(w.id, true)
  let area = Rect(x: 120, y: 20, width: 70, height: 24)
  s.setClock(w.id, area: area, hours24: true)
  s.clockText = (9 * 60, true)
  let at = Rect(x: w.content.x + 120, y: w.content.y + 20, width: 70, height: 24)
  var list = DrawList()
  s.displayList(Rect(x: 0, y: 0, width: 400, height: 300), into: &list)
  // "09:00" in five glyphs, ending at the area's right.
  let glyphs = list.quads.filter { $0.kind == Quad.glyph && at.contains(Int($0.x), Int($0.y)) }
  #expect(glyphs.count == 5 && glyphs.map { $0.texture } == Array("09:00".unicodeScalars.map { $0.value }))
  #expect(Int(glyphs.last!.x) + 8 == at.maxX)
  // Its face: an image over the area, its ink right-aligned.
  let face = ClockFace(&painter, text: "09:00", width: 70, height: 24)
  #expect((0..<(70 * 24)).contains { face.pixel($0) >> 24 != 0 })
  #expect((0..<24).allSatisfy { face.pixel($0 * 70) >> 24 == 0 })  // nothing at the left edge
  s.setClockFace(w.id, face)
  s.displayList(Rect(x: 0, y: 0, width: 400, height: 300), into: &list)
  #expect(list.quads.contains { $0.kind == Quad.image && $0.rect == at })
  #expect(!list.quads.contains { $0.kind == Quad.glyph && at.contains(Int($0.x), Int($0.y)) })
  // A minute on: its area damaged, and the scene's glyphs until the next
  // face is set.
  _ = s.takeDamage()
  s.clockText = (9 * 60 + 1, true)
  #expect(s.takeDamage() == at)
  s.displayList(Rect(x: 0, y: 0, width: 400, height: 300), into: &list)
  #expect(list.quads.filter { $0.kind == Quad.glyph && at.contains(Int($0.x), Int($0.y)) }.count == 5)
  // Taken away: nothing there.
  s.setClock(w.id, area: nil, hours24: true)
  s.displayList(Rect(x: 0, y: 0, width: 400, height: 300), into: &list)
  #expect(!list.quads.contains { at.contains(Int($0.x), Int($0.y)) && ($0.kind == Quad.glyph || $0.kind == Quad.image) })
}
