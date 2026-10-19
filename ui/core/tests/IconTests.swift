// SPDX-License-Identifier: BSD-3-Clause

// Icons and pictures (M6i part 5): the committed icon table is what
// iconsgen reads from the storyboard now; every icon, at the sheet's 64,
// 32 and 16 px, matches librsvg's rendering of the same SVG (through
// ImageMagick, when the host has it: skipped otherwise) to within
// antialiasing, its shapes compared in white and its paints where flat,
// since librsvg blends sRGB's bytes and UICore light; pictures resample
// to any size; and both reach the screen through the colour atlas.

import FoundationEssentials
import GlyphAtlas
import IconGen
import Raster
import Testing
import TextLayout
import UICore

#if canImport(Glibc)
  import Glibc
#endif

private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()

@Test func theIconTableIsTheStoryboards() throws {
  let html = try String(contentsOf: root.appending(path: "docs/design/shell-storyboard.html"), encoding: .utf8)
  let committed = try String(contentsOf: root.appending(path: "ui/core/lib/generated/IconSheet.swift"), encoding: .utf8)
  #expect(swiftTable(try readIcons(storyboard: html)) == committed,
          "stale: run .build/debug/iconsgen ui/core/lib/generated/IconSheet.swift docs/design/shell-storyboard.html")
  #expect(IconData.all.count == 15 && IconData.index("trash") != nil)
}

/// The icon as one SVG, its colours resolved and its strokes 1 px.
private func svg(_ icon: IconShape, size: Int, _ colors: IconColors) -> String {
  func hex(_ c: UInt32) -> String {
    let s = String(c & 0xFF_FFFF, radix: 16)
    return "#" + String(repeating: "0", count: 6 - s.count) + s
  }
  let width = 32.0 / Double(size)
  var out = "<svg xmlns='http://www.w3.org/2000/svg' width='\(size)' height='\(size)' viewBox='0 0 32 32'>"
  out += "<defs>"
  for (k, e) in icon.elements.enumerated() where e.fill != e.fillTo {
    out += "<linearGradient id='g\(k)' x1='0' x2='1' y1='0' y2='0'><stop offset='0' stop-color='\(hex(colors.color(e.fill)))'/>"
    out += "<stop offset='1' stop-color='\(hex(colors.color(e.fillTo)))'/></linearGradient>"
  }
  out += "</defs>"
  for (k, e) in icon.elements.enumerated() {
    var d = ""
    var i = 0
    while i < e.path.count {
      let op = Int(e.path[i])
      let n = op == 0 || op == 1 ? 2 : op == 2 ? 6 : 0
      d += ["M", "L", "C", "Z"][op] + e.path[(i + 1)..<(i + 1 + n)].map { "\($0)" }.joined(separator: " ") + " "
      i += 1 + n
    }
    let fill = e.fill.role == .none ? "none" : e.fill != e.fillTo ? "url(#g\(k))" : hex(colors.color(e.fill))
    let stroke = e.stroke.role == .none ? "none" : hex(colors.color(e.stroke))
    out += "<path d='\(d)' fill='\(fill)' stroke='\(stroke)' stroke-width='\(width)' stroke-linejoin='miter'/>"
  }
  return out + "</svg>"
}

/// librsvg's rendering, as RGBA, or nil without ImageMagick.
private func librsvg(_ text: String, size: Int) throws -> [UInt8]? {
  guard FileManager.default.isExecutableFile(atPath: "/usr/bin/magick") else { return nil }
  let dir = FileManager.default.temporaryDirectory.appending(path: "icons-\(getpid())")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let input = dir.appending(path: "icon.svg"), output = dir.appending(path: "icon.rgba")
  try Data(text.utf8).write(to: input)
  let command = "/usr/bin/magick -background none 'RSVG:\(input.path)' -depth 8 'RGBA:\(output.path)' 2>/dev/null"
  guard system(command) == 0 else { return nil }
  let bytes = [UInt8](try Data(contentsOf: output))
  return bytes.count == size * size * 4 ? bytes : nil
}

@Test func everyIconMatchesLibrsvg() throws {
  // librsvg blends in sRGB's bytes and UICore in light (D110), so the
  // shapes are compared in white, where the two rules agree, and the
  // paints only where both are opaque, away from any edge.
  let white = IconColors(edge: 0xFF_FFFF, emblem: 0xFF_FFFF, background: 0xFF_FFFF)
  let colors = IconColors(edge: 0x00E5FF, emblem: 0xFF2BD6, background: 0x0A0A12)
  var rasterizer = Rasterizer()
  var bitmap = Bitmap()
  var checked = 0
  for icon in IconData.all {
    for size in [64, 32, 16] {
      guard let theirShape = try librsvg(svg(icon, size: size, white), size: size),
        let theirs = try librsvg(svg(icon, size: size, colors), size: size)
      else { continue }
      let shape = icon.render(size: size, colors: white, rasterizer: &rasterizer, bitmap: &bitmap)
      let ours = icon.render(size: size, colors: colors, rasterizer: &rasterizer, bitmap: &bitmap)
      // Coverage: the mean difference small, and few pixels far apart
      // (antialiasing differs along edges).
      var total = 0, far = 0
      for i in stride(from: 3, to: size * size * 4, by: 4) {
        let d = abs(Int(shape.pixels[i]) - Int(theirShape[i]))
        total += d
        if d > 48 { far += 1 }
      }
      let mean = Double(total) / Double(size * size)
      // Paint: where both are opaque and librsvg's is flat (no edge or
      // gradient beside it).
      var paint = 0, opaque = 0
      func flat(_ x: Int, _ y: Int) -> Bool {
        let i = (y * size + x) * 4
        guard ours.pixels[i + 3] == 255 && theirs[i + 3] == 255 else { return false }
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
          let j = ((y + dy) * size + x + dx) * 4
          for c in 0..<4 where abs(Int(theirs[i + c]) - Int(theirs[j + c])) > 2 { return false }
        }
        return true
      }
      for y in 1..<(size - 1) {
        for x in 1..<(size - 1) where flat(x, y) {
          let i = (y * size + x) * 4
          for c in 0..<3 { paint += abs(Int(ours.pixels[i + c]) - Int(theirs[i + c])) }
          opaque += 1
        }
      }
      let paintMean = opaque > 0 ? Double(paint) / Double(opaque * 3) : 0
      if ProcessInfo.processInfo.environment["TODHCHAI_ICON_VERBOSE"] != nil {
        print("\(icon.name) \(size): mean \(mean) far \(far) paint \(paintMean)")
      }
      #expect(mean < 2 && Double(far) <= Double(size * size) * 0.01 && paintMean < 4,
              "\(icon.name) at \(size): mean \(mean), far \(far), paint \(paintMean)")
      checked += 1
    }
  }
  if checked == 0 { print("everyIconMatchesLibrsvg: skipped (no ImageMagick with librsvg)") }
}

@Test func picturesResample() {
  // A 4x4 picture: left half opaque red, right half transparent.
  var source = RGBAImage(width: 4, height: 4)
  for y in 0..<4 {
    for x in 0..<2 { source.pixels.replaceSubrange((y * 4 + x) * 4..<(y * 4 + x) * 4 + 4, with: [255, 0, 0, 255]) }
  }
  let half = ImageCache.resample(source, width: 2, height: 2)
  #expect(Array(half.pixels[0..<4]) == [255, 0, 0, 255] && half.pixels[7] == 0)
  // A column straddling the edge: half covered, still red (premultiplied).
  let three = ImageCache.resample(source, width: 3, height: 1)
  #expect(three.pixels[4] == 255 && (127...128).contains(three.pixels[7]))
  let double = ImageCache.resample(source, width: 8, height: 8)
  #expect(double.width == 8 && double.pixels[3] == 255 && double.pixels[(8 * 8 - 1) * 4 + 3] == 0)
}

@Test func iconsAndPicturesReachTheScreen() throws {
  var p = Painter(theme: .neonTab, fonts: try storyboardFonts(), scale: 2, cache: GlyphCache(coverageSize: 256, fieldSize: 64))
  var picture = RGBAImage(width: 2, height: 2)
  for i in 0..<4 { picture.pixels.replaceSubrange(i * 4..<i * 4 + 4, with: [0, 255, 0, 255]) }
  p.images.add(id: 7, picture)
  p.image(7, 10, 10, 20, 20)
  p.icon("cube", 50, 10, size: 32, color: 0x00E5FF)
  p.icon("cube", 50, 50, size: 32, color: 0x00E5FF, selected: true)
  var canvas = Canvas(width: 200, height: 200, color: 0x0A0A12)
  p.render(into: &canvas)
  #expect(canvas.pixels[40 * 200 + 40] == 0x00FF00)  // the picture, at twice the size
  // The cube's top face: 40% cyan over bg.0; its edge cyan.
  #expect(canvas.pixels.contains(0x00E5FF) && canvas.pixels.contains(IconColors(edge: 0x00E5FF, background: 0x0A0A12)
    .color(IconPaint(.edge, 40))))
  // Selected, it glows: 5 px above its top vertex (16.5, 6.5 of 32) is
  // lit, where the plain cube's is not.
  #expect(canvas.pixels[108 * 200 + 133] != 0x0A0A12 && canvas.pixels[28 * 200 + 133] == 0x0A0A12)
}
