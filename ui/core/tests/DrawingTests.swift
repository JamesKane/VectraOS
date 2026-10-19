// SPDX-License-Identifier: BSD-3-Clause

// The UI Kit's drawing (M6i, part 1): the quad's layout (the GPU shader's,
// 64 bytes); shapes' coverage against their exact area (32×32 samples a
// pixel): exact along straight edges, within a measured bound at corners;
// borders and glow; the theme's dot fallback; text through the display
// list exactly as TextLayout's canvas draws it; and text.contrast's
// default, the setting that keeps the base theme's body text at the
// weight blending the bytes gave it (D110). TODHCHAI_UI_SAMPLE
// names a file to write a sample of Neon Tab's chrome to (binary PPM).

import FoundationEssentials
import GlyphAtlas
import Light
import OpenType
import Testing
import TextLayout
import UICore

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // ui/core/tests/DrawingTests.swift
  return dir
}()

func noto() throws -> Font {
  try Font([UInt8](try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/noto-sans/NotoSans-Regular.ttf")))))
}

@Test func theQuadIsTheShadersLayout() {
  #expect(MemoryLayout<UIQuad>.size == 64 && MemoryLayout<UIQuad>.stride == 64)
}

/// A shape drawn opaque white on black: each pixel's red, decoded to
/// light, is its coverage.
func coverage(_ q: UIQuad, _ w: Int, _ h: Int) -> [Int] {
  var canvas = Canvas(width: w, height: h, color: 0)
  CPURenderer().render(DisplayList(quads: [q]), cache: GlyphCache(coverageSize: 16, fieldSize: 16), into: &canvas)
  return canvas.pixels.map { Int((Double(Light.decode($0 >> 16)) * 255 / 65535).rounded()) }
}

extension DisplayList {
  init(quads: [UIQuad]) {
    self.init()
    for q in quads { append(q) }
  }
}

@Test func shapesCoverTheirArea() {
  var rng = SystemRandomNumberGenerator()
  var straightWorst = 0, cornerWorst = 0
  for n in 0..<120 {
    let chamfered = n % 2 == 1
    let x = Double.random(in: 2...6, using: &rng), y = Double.random(in: 2...6, using: &rng)
    let w = Double.random(in: 8...30, using: &rng), h = Double.random(in: 8...30, using: &rng)
    let corner = Double.random(in: 0...min(w, h) / 2, using: &rng)
    let cut = Float(Int(corner))
    let q = chamfered
      ? UIQuad(x: Float(x), y: Float(y), width: Float(w), height: Float(h), kind: UIQuad.shape, fill: 0xFFFF_FFFF,
               cuts: UIQuad.cuts(topLeft: cut, topRight: cut, bottomRight: cut, bottomLeft: cut))
      : UIQuad(x: Float(x), y: Float(y), width: Float(w), height: Float(h), kind: UIQuad.shape, fill: 0xFFFF_FFFF,
               corner: Float(corner))
    // The quad's own (float) geometry, for the exact area.
    let (fx, fy, fw, fh) = (Double(q.x), Double(q.y), Double(q.width), Double(q.height))
    let fc = chamfered ? Double(cut) : Double(q.corner)
    let size = 40
    let drawn = coverage(q, size, size)
    for py in 0..<size {
      for px in 0..<size {
        // The exact area: 64×64 samples (an edge placed within 1/128 of a
        // pixel), unless the centre's distance (never more than the true
        // one) puts the edge past the pixel's half-diagonal.
        func area(_ n: Int) -> Double {
          var inside = 0
          for sy in 0..<n {
            for sx in 0..<n {
              let sxp = Double(px) + (Double(sx) + 0.5) / Double(n), syp = Double(py) + (Double(sy) + 0.5) / Double(n)
              let d = chamfered ? Shapes.chamfered(sxp, syp, x: fx, y: fy, width: fw, height: fh, cut: fc)
                                : Shapes.rounded(sxp, syp, x: fx, y: fy, width: fw, height: fh, radius: fc)
              if d < 0 { inside += 1 }
            }
          }
          return Double(inside) / Double(n * n)
        }
        let centre = chamfered
          ? Shapes.chamfered(Double(px) + 0.5, Double(py) + 0.5, x: fx, y: fy, width: fw, height: fh, cut: fc)
          : Shapes.rounded(Double(px) + 0.5, Double(py) + 0.5, x: fx, y: fy, width: fw, height: fh, radius: fc)
        let exact = Int((abs(centre) > 0.71 ? (centre < 0 ? 1 : 0) : area(64)) * 255 + 0.5)
        let error = abs(exact - drawn[py * size + px])
        // Near a corner (within the corner's reach and two pixels), or not.
        let cx = Double(px) + 0.5, cy = Double(py) + 0.5
        let nearX = cx < fx + fc + 2 || cx > fx + fw - fc - 2, nearY = cy < fy + fc + 2 || cy > fy + fh - fc - 2
        if nearX && nearY { cornerWorst = max(cornerWorst, error) } else { straightWorst = max(straightWorst, error) }
      }
    }
  }
  print("shapes against their exact area: along edges within \(straightWorst) levels, at corners \(cornerWorst)")
  // Along a straight edge, 1/2 - d is the exact area (the samples place
  // the edge within 1/128 pixel: 2 levels, and a level's rounding). At a
  // corner it's an estimate, as every SDF renderer's is (the GPU's too):
  // within a quarter of a pixel's coverage at a sharp vertex.
  #expect(straightWorst <= 3)
  #expect(cornerWorst <= 64)
}

@Test func bordersAndGlow() {
  // A 20x20 square at (10, 10), a 2-pixel cyan border, white inside, a
  // 6-pixel glow.
  let q = UIQuad(x: 10, y: 10, width: 20, height: 20, kind: UIQuad.shape, fill: 0xFFFF_FFFF, border: 2,
                 stroke: 0xFF00_E5FF, glow: 6, glowColor: 0xFFFF_0000)
  var canvas = Canvas(width: 40, height: 40, color: 0)
  CPURenderer().render(DisplayList(quads: [q]), cache: GlyphCache(coverageSize: 16, fieldSize: 16), into: &canvas)
  func at(_ x: Int, _ y: Int) -> UInt32 { canvas.pixels[y * 40 + x] }
  #expect(at(20, 20) == 0xFF_FFFF)  // inside
  #expect(at(11, 20) == 0x00_E5FF)  // in the border
  // Past the edge, the glow fades out.
  let g1 = at(8, 20) >> 16, g2 = at(6, 20) >> 16, g3 = at(4, 20) >> 16
  #expect(g1 > g2 && g2 > g3 && at(2, 20) == 0)
}

@Test func theThemeFallsBackByDots() {
  let t = Theme.neonTab
  #expect(t.style("window.tab.focused.wide") == t.style("window.tab.focused"))
  #expect(t.style("button.ghost") == t.style("button"))
  #expect(t.style("nothing.like.it") == t.style("default"))
  #expect(t.color("neon.cyan") == 0xFF00_E5FF && t.color("no.such.token") == 0xFFFF_00FF)
  // The storyboard's values, from cqw (12.8 px): the focused body's glow
  // .45cqw in cyan at 55%; the tab's cut .7cqw at its top right only.
  let body = t.style("window.body.focused")
  #expect(abs(body.glow - 5.76) < 0.01 && body.glowColor == 0x8C00_E5FF)
  let cuts = UIQuad(x: 0, y: 0, width: 0, height: 0, kind: 0, fill: 0, cuts: t.style("window.tab").cuts)
  #expect(cuts.cut(0) == 0 && cuts.cut(1) == 9 && cuts.cut(2) == 0 && cuts.cut(3) == 0)
  #expect(t.style("table.header").uppercase && t.style("table.header").font == .ui)
  // The accessibility theme: no glow, larger type, white edges.
  #expect(Theme.accessible.style("window.body.focused").glowColor == 0)
  #expect(Theme.accessible.style("label").textSize > t.style("label").textSize)
  #expect(Theme.accessible.color("outline") == 0xFFFF_FFFF)
}

@Test func textThroughTheListIsTheCanvassText() throws {
  let font = try noto()
  let setter = Typesetter(font)
  let text = "Neon Tab: “office” AV Ta naïve Q\u{303} 1,234.50".unicodeScalars.map(\.value)
  var cacheA = GlyphCache(coverageSize: 512, fieldSize: 256), cacheB = cacheA
  for size in [13.0, 17, 24, 48] {
    let p = setter.set(text, size: size, width: 600, x: 10.25, y: 5)
    // Without the contrast curve, whose slope would magnify a level.
    var direct = Canvas(width: 640, height: 120, color: 0x0A0A12)
    direct.contrast = TextContrast(step: 0)
    if size >= 32 {
      direct.drawFields(p, size: size, color: 0xD8E1FF, font: font, fontID: 1, cache: &cacheA)
    } else {
      direct.draw(p, size: size, color: 0xD8E1FF, font: font, fontID: 1, cache: &cacheA)
    }
    var list = DisplayList()
    list.append(p, size: size, color: 0xFFD8_E1FF, font: font, fontID: 1, cache: &cacheB)
    var listed = Canvas(width: 640, height: 120, color: 0x0A0A12)
    listed.contrast = TextContrast(step: 0)
    CPURenderer().render(list, cache: cacheB, into: &listed)
    // Coverage glyphs exactly; field glyphs within two levels of light (a
    // quad holds its place and scale as Float, as the GPU reads them).
    var worst = 0
    func light(_ p: UInt32, _ shift: UInt32) -> Int { Int((Double(Light.decode(p >> shift)) * 255 / 65535).rounded()) }
    for (a, b) in zip(direct.pixels, listed.pixels) {
      for shift in [UInt32(16), 8, 0] { worst = max(worst, abs(light(a, shift) - light(b, shift))) }
    }
    #expect(worst <= (size >= 32 ? 2 : 0), "up to \(worst) levels apart at \(size) px")
  }
}

/// The storyboard's typefaces, from data/fonts.
func storyboardFonts() throws -> Fonts {
  var fonts = Fonts()
  for (path, role, weight) in [("chakra-petch/ChakraPetch-Medium.ttf", FontRole.display, 500),
                               ("chakra-petch/ChakraPetch-Bold.ttf", .display, 700),
                               ("ibm-plex-sans/IBMPlexSans-Regular.ttf", .body, 400),
                               ("ibm-plex-sans/IBMPlexSans-Medium.ttf", .body, 500),
                               ("ibm-plex-sans/IBMPlexSans-SemiBold.ttf", .body, 600),
                               ("ibm-plex-mono/IBMPlexMono-Regular.ttf", .mono, 400),
                               ("ibm-plex-mono/IBMPlexMono-Medium.ttf", .mono, 500),
                               ("barlow-condensed/BarlowCondensed-Medium.ttf", .ui, 500),
                               ("barlow-condensed/BarlowCondensed-SemiBold.ttf", .ui, 600)] {
    let data = try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/\(path)")))
    fonts.add(try Font([UInt8](data)), role: role, weight: weight)
  }
  return fonts
}

/// The storyboard's board 01 ("The desktop at rest"), drawn by the kit at
/// `scale` pixels a logical pixel on a 1280×720 logical screen.
func boardOne(scale: Float, theme: Theme = .neonTab) throws -> Canvas {
  let c = Theme.cqw
  var p = Painter(theme: theme, fonts: try storyboardFonts(), scale: scale,
                  cache: GlyphCache(coverageSize: 2048, fieldSize: 256))
  let w = Int(1280 * scale), h = Int(720 * scale)
  // The desktop and its grid (every 4cqw, cyan at 3.5%).
  let grid = theme.style("desktop.grid")
  var gx: Float = 0
  while gx < 1280 {
    p.fill(gx, 0, 1 / scale, 720, grid.fill)
    gx += grid.padding.left
  }
  var gy: Float = 0
  while gy < 720 {
    p.fill(0, gy, 1280, 1 / scale, grid.fill)
    gy += grid.padding.top
  }
  // The desktop's icons: home (a place, cyan), two queries (magenta), the
  // Trash (dim).
  let k = theme.neon
  let icons = [IconRef("home", color: k.cyan, emblem: k.cyan), IconRef("query", color: k.magenta),
               IconRef("query", color: k.magenta), IconRef("trash", color: k.dim)]
  for (i, label) in ["home", "New mail", "Trip-hop, 90s", "Trash"].enumerated() {
    Chrome.desktopIcon(&p, c(1.5), c(2 + 6.5 * Float(i)), icons[i], label: label)
  }
  Chrome.deskbar(&p, right: 1280 - c(1.2), top: c(1.2), clock: "09:00",
                 gauges: [("CPU", 0.03, "3%"), ("GPU", 0.01, "1%"), ("AUDIO", 0.18, "2.7 ms"), ("PACING", 0.08, "p99 0.4")],
                 apps: [("Tracker", 2, true), ("Terminal", 1, false), ("Mail", 1, false)],
                 tray: [IconRef("mail", color: k.amber), IconRef("speaker", color: k.amber),
                        IconRef("workspaces", color: k.amber)],
                 appIcons: [IconRef("folder", color: k.cyan), IconRef("terminal", color: k.ink, emblem: k.phosphor),
                            IconRef("mail", color: k.amber)])
  // Tracker's home: unfocused.
  let home = Chrome.window(&p, c(12), c(6), c(40), c(24), title: "home", focused: false)
  Chrome.table(&p, home.x, home.y, width: home.width, columns: ["Name", "Size", "Modified", "sys:type"],
               widths: [c(14), c(6), c(8), c(12)], numeric: [false, true, false, false],
               rows: [(["Music", "—", "2026-10-10", "directory"], ""), (["Projects", "—", "2026-10-11", "directory"], ""),
                      (["People", "—", "2026-09-30", "directory"], ""),
                      (["render-notes.md", "14 KiB", "2026-10-10", "text/markdown"], ""),
                      (["virtio-v1.3…csd01.pdf", "3.1 MiB", "2026-10-09", "application/pdf"], "")],
               icons: [IconRef("folder", color: k.cyan), IconRef("folder", color: k.cyan),
                       IconRef("folder", color: k.cyan), IconRef("doc", color: k.ink),
                       IconRef("pdf", color: k.ink, emblem: k.magenta)])
  Chrome.status(&p, home, left: "5 entries", right: "Taisce · home")
  // Terminal: focused.
  let term = Chrome.window(&p, c(30), c(20), c(38), c(22), title: "Terminal", focused: true)
  let ts = theme.style("terminal"), prompt = theme.style("terminal.prompt")
  var ty = term.y + ts.padding.top
  let lh = p.lineHeight(ts)
  let px = term.x + ts.padding.left
  let pw = p.text("~ $", px, ty, prompt)
  p.text(" cat /svc/radharc/status", px + pw, ty, ts)
  ty += lh
  p.text("windows 3   damage none   idle", px, ty, ts)
  ty += lh
  p.text("output virtio-gpu-0 2560x1440@60 composited", px, ty, ts)
  ty += lh
  let pw2 = p.text("~ $ ", px, ty, prompt)
  p.fill(px + pw2, ty + (lh - ts.textSize) / 2, ts.textSize * 0.6, ts.textSize, ts.ink)
  var canvas = Canvas(width: w, height: h, color: theme.color("desk") & 0xFF_FFFF)
  p.render(into: &canvas)
  return canvas
}

/// Board 01, for looking at beside the storyboard (TODHCHAI_UI_SAMPLE).
@Test func theStoryboardsFirstBoard() throws {
  let page = try boardOne(scale: 2)
  // The focused window's frame is cyan; the unfocused tab's text amber.
  #expect(page.pixels.contains(0x00E5FF) && page.pixels.contains(0xFFB000))
  guard let path = ProcessInfo.processInfo.environment["TODHCHAI_UI_SAMPLE"] else { return }
  var ppm = Array("P6\n\(page.width) \(page.height)\n255\n".utf8)
  for p in page.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
  try Data(ppm).write(to: URL(filePath: path))
}

/// Each pixel's coverage (0-255) of a paragraph drawn as Canvas.draw draws
/// it, before any curve.
func coverages(_ p: Paragraph, size: Double, font: Font, cache: inout GlyphCache) -> [Int] {
  var out: [Int] = []
  for g in p.glyphs {
    let quarter = GlyphCache.quarter(g.x)
    guard let r = cache.coverage(font, fontID: 1, glyph: g.glyph, pixelsPerEm: size, quarter: quarter) else { continue }
    for row in 0..<Int(r.height) {
      for col in 0..<Int(r.width) {
        out.append(Int(cache.coverage.pixels[(Int(r.y) + row) * cache.coverage.width + Int(r.x) + col]))
      }
    }
  }
  return out.filter { $0 > 0 }
}

@Test func theBaseThemesTextKeepsItsWeight() throws {
  // text.contrast's default (D110): the base theme's body text at 100%,
  // blended in light through the curve, takes as much light from its
  // ground as blending the bytes did (todhchai's weight); no setting, in
  // twentieths, comes closer.
  let t = Theme.base
  let style = t.style("text")
  let data = try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/ibm-plex-sans/IBMPlexSans-Regular.ttf")))
  let font = try Font([UInt8](data))
  let text = "Sphinx of black quartz, judge my vow. The quick brown fox jumps over the lazy dog: 0123456789."
  let p = Typesetter(font).set(text.unicodeScalars.map(\.value), size: Double(style.textSize), width: 2000, x: 4, y: 20)
  var cache = GlyphCache(coverageSize: 512, fieldSize: 256)
  let cs = coverages(p, size: Double(style.textSize), font: font, cache: &cache)
  let ink = t.color("ink") & 0xFF_FFFF, ground = t.color("well") & 0xFF_FFFF
  func light(_ c: UInt32) -> Int { Int(Light.decode(c >> 16) + Light.decode(c >> 8) + Light.decode(c)) }
  func bytes(_ c: Int) -> UInt32 {
    let a = UInt32(c), na = 255 - a
    func ch(_ s: UInt32) -> UInt32 { ((((ink >> s) & 0xFF) * a + ((ground >> s) & 0xFF) * na + 127) / 255) << s }
    return ch(16) | ch(8) | ch(0)
  }
  let then = cs.reduce(0) { $0 + light(ground) - light(bytes($1)) }
  func now(_ k: TextContrast) -> Int {
    cs.reduce(0) { $0 + light(ground) - light(Light.overText(ink, ground, coverage: $1, contrast: k)) }
  }
  let settings = (0...20).map { TextContrast(step: $0) }
  let best = settings.min { abs(now($0) - then) < abs(now($1) - then) }!
  print("text.contrast: \(best.step) twentieths keep the weight (\(now(best)) of \(then)); none: \(now(settings[0]))")
  #expect(TextContrast.standard == best)
  #expect(Painter(theme: t, fonts: Fonts()).contrast == .standard)
}
