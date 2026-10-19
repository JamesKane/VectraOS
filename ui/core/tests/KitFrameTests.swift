// SPDX-License-Identifier: BSD-3-Clause

// The kit frame's pixel tests (theming.md §7): each shipped theme's kit
// frame drawn by the CPU renderer at 100%, 150%, 200% and 300%.
// - Probes: across a raised button's edge, an inset field's, a grooved
//   group's and the scrollbar's, each band (outline, bevel) is whole
//   device pixels of one colour, as wide as `hairline` says.
// - The drawing: its pixels' digest against kit-frame.tsv, so a change
//   to the renderer or a theme that alters a drawing is seen. A
//   mismatch writes the drawing (binary PPM) to .build/kit-frame/ to look
//   at; VX_KIT_RECORD=1 records the digests anew.

import FoundationEssentials
import GlyphAtlas
import OpenType
import Testing
import TextLayout
import UICore

extension Theme {
  static let platinumIndigo = Theme.tree("platinum-indigo")
}

/// Platinum Indigo's type: Archivo, and IBM Plex Mono.
func archivoFonts() throws -> Fonts {
  var fonts = Fonts()
  for (path, role, weight) in [("archivo/ArchivoExpanded-ExtraBold.ttf", FontRole.display, 800),
                               ("archivo/Archivo-Regular.ttf", .body, 400),
                               ("archivo/ArchivoSemiCondensed-SemiBold.ttf", .ui, 600),
                               ("archivo/ArchivoSemiCondensed-Bold.ttf", .ui, 700),
                               ("archivo/ArchivoSemiCondensed-ExtraBold.ttf", .ui, 800),
                               ("ibm-plex-mono/IBMPlexMono-Regular.ttf", .mono, 400),
                               ("ibm-plex-mono/IBMPlexMono-Medium.ttf", .mono, 500)] {
    let data = try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/\(path)")))
    fonts.add(try Font([UInt8](data)), role: role, weight: weight)
  }
  return fonts
}

let kitScales: [Float] = [1, 1.5, 2, 3]

func kitThemes() throws -> [(name: String, theme: Theme, fonts: Fonts)] {
  [("platinum-indigo", .platinumIndigo, try archivoFonts()), ("neon-tab", .neonTab, try storyboardFonts())]
}

func kitFrame(_ theme: Theme, _ fonts: Fonts, scale: Float) -> Canvas {
  var p = Painter(theme: theme, fonts: fonts, scale: scale, cache: GlyphCache(coverageSize: 2048, fieldSize: 256))
  KitFrame.draw(&p)
  var canvas = Canvas(width: Int(KitFrame.width * scale + 0.5), height: Int(KitFrame.height * scale + 0.5), color: 0)
  p.render(into: &canvas)
  return canvas
}

/// FNV-1a over each pixel's three bytes, with the size first.
func digest(_ c: Canvas) -> String {
  var h: UInt64 = 0xCBF2_9CE4_8422_2325
  func eat(_ b: UInt8) {
    h ^= UInt64(b)
    h = h &* 0x0000_0100_0000_01B3
  }
  for v in [c.width, c.height] { for s in stride(from: 0, to: 32, by: 8) { eat(UInt8(truncatingIfNeeded: v >> s)) } }
  for p in c.pixels { eat(UInt8(p >> 16 & 0xFF)); eat(UInt8(p >> 8 & 0xFF)); eat(UInt8(p & 0xFF)) }
  return String(h, radix: 16)
}

@Test func theKitFramesHairlinesAreWholePixels() throws {
  for (name, theme, fonts) in try kitThemes() {
    for scale in kitScales {
      let c = kitFrame(theme, fonts, scale: scale)
      let p = Painter(theme: theme, fonts: fonts, scale: scale)
      func at(_ x: Int, _ y: Int) -> UInt32 { c.pixels[y * c.width + x] }
      /// The pixels going in from a logical edge, `n` of them.
      func inward(_ x: Float, _ y: Float, down: Bool, _ n: Int) -> [UInt32] {
        let b = p.snapped(x, y, 1, 1)
        return (0..<n).map { down ? at(Int(b.x), Int(b.y) + $0) : at(Int(b.x) + $0, Int(b.y)) }
      }
      let light = theme.color("bevel.light") & 0xFF_FFFF, dark = theme.color("bevel.dark") & 0xFF_FFFF
      func expect(_ what: String, _ got: [UInt32], _ bands: [(UInt32, Float)]) {
        var want: [UInt32] = []
        for (color, width) in bands { want += Array(repeating: color, count: Int(p.hairline(width))) }
        #expect(Array(got.prefix(want.count)) == want, "\(name) at \(scale): \(what)")
      }
      // Cancel's top edge, a third of the way along (16, 102): the
      // outline, then the raised bevel's light, if the theme has one.
      let button = theme.style("button")
      let bevelled = { (s: Style) -> BevelKind? in
        for case .bevel(let k, _) in s.materials { return k }
        return nil
      }
      var bands: [(UInt32, Float)] = [(button.stroke & 0xFF_FFFF, button.border)]
      if bevelled(button) == .raised { bands.append((light, 1)) }
      expect("the button's edge", inward(30, 102, down: true, 4 * Int(scale)), bands)
      // The field's top edge (146, 174): its edge, then inset's dark.
      let field = theme.style("field")
      bands = [(field.stroke & 0xFF_FFFF, field.border)]
      if bevelled(field) == .inset { bands.append((dark, 1)) }
      expect("the field's edge", inward(200, 174, down: true, 4 * Int(scale)), bands)
      // The group's left edge (16, 286 + 7): a groove is dark then light.
      let group = theme.style("group")
      if bevelled(group) == .groove && group.border == 0 {
        expect("the group's groove", inward(16, 330, down: false, 4 * Int(scale)), [(dark, 1), (light, 1)])
      }
      // The scrollbar track's left edge, between its arrows.
      let track = theme.style("scrollbar")
      if track.border > 0 {
        let tabs = theme.style("tabs.tab")
        var x: Float = 16
        for (i, title) in ["Threads", "Rings", "Budgets"].enumerated() {
          let s = i == 0 ? theme.style("tabs.tab.on") : tabs
          x += tabs.padding.left + p.measure(title, s) + tabs.padding.right - 1
        }
        x += 1 + 14
        expect("the scrollbar's left edge", inward(x, 430, down: false, 2 * Int(scale)),
               [(track.stroke & 0xFF_FFFF, track.border)])
      }
    }
  }
}

@Test func theKitFrameIsDrawnAsRecorded() throws {
  let path = "\(repository)/ui/core/tests/kit-frame.tsv"
  let text = (try? String(contentsOf: URL(filePath: path), encoding: .utf8)) ?? ""
  var recorded: [String: String] = [:]
  for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
    let f = line.split(separator: "\t").map(String.init)
    if f.count == 3 { recorded["\(f[0]) \(f[1])"] = f[2] }
  }
  let record = ProcessInfo.processInfo.environment["VX_KIT_RECORD"] == "1"
  var out = "# The kit frame's digests (KitFrameTests): theme, scale, FNV-1a of its pixels.\n"
  for (name, theme, fonts) in try kitThemes() {
    for scale in kitScales {
      let c = kitFrame(theme, fonts, scale: scale)
      let key = "\(name) \(Int(scale * 100))%", d = digest(c)
      out += "\(name)\t\(Int(scale * 100))%\t\(d)\n"
      if record || recorded[key] == d { continue }
      let dir = "\(repository)/.build/kit-frame"
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      let file = "\(dir)/\(name)-\(Int(scale * 100)).ppm"
      var ppm = Array("P6\n\(c.width) \(c.height)\n255\n".utf8)
      for p in c.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
      try Data(ppm).write(to: URL(filePath: file))
      Issue.record("\(key): drawn \(d), recorded \(recorded[key] ?? "nothing"); the drawing is \(file)")
    }
  }
  if record { try Data(out.utf8).write(to: URL(filePath: path)) }
}
