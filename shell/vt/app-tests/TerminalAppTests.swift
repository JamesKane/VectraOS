// SPDX-License-Identifier: BSD-3-Clause

// vt's screen as a Kit app (vt(1)), hosted, its program a recording: the
// view's size makes the screen's and the link hears it; output is fed
// before a frame, and a status query's reply goes back; keys go as xterm
// sends them, from the box and as rio's raw runes; the wheel scrolls back,
// output brings it down; the colours are the theme's.

import FoundationEssentials
import GlyphAtlas
import Kit
import OpenType
import Synchronization
import TerminalApp
import Kbdfs
import TerminalCore
import Testing

final class Recording: TerminalLink, @unchecked Sendable {
  let written = Mutex<[UInt8]>([])
  let size = Mutex<(Int, Int)>((0, 0))
  func write(_ bytes: [UInt8]) { written.withLock { $0 += bytes } }
  func resize(columns: Int, rows: Int) { size.withLock { $0 = (columns, rows) } }
  func take() -> [UInt8] { written.withLock { w in defer { w.removeAll() }; return w } }
}

let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().path

func monoFonts() throws -> Fonts {
  var fonts = Fonts()
  for (path, role, weight) in [("ibm-plex-mono/IBMPlexMono-Regular.ttf", FontRole.mono, 400),
                               ("barlow-condensed/BarlowCondensed-SemiBold.ttf", .ui, 600)] {
    let data = try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/\(path)")))
    fonts.add(try Font([UInt8](data)), role: role, weight: weight)
  }
  return fonts
}

/// A shipped theme, resolved from its file in ui/theme/themes.
func shipped(_ name: String) throws -> Theme {
  try Theme.resolve(ThemeStack(theme: name, variant: nil)) { n in
    (try? Data(contentsOf: URL(filePath: "\(repository)/ui/theme/themes/\(n)"))).map { [UInt8]($0) }
  }
}

@MainActor func terminal(width: Float = 400, height: Float = 200) throws -> (TerminalModel, Runner, Recording) {
  let link = Recording()
  let fonts = try monoFonts()
  let theme = try shipped("neon-tab")
  let painter = Painter(theme: theme, fonts: fonts, cache: GlyphCache(coverageSize: 512, fieldSize: 64))
  let style = theme.style("terminal")
  let cell = CellMetrics(width: painter.measure("M", style), height: painter.lineHeight(style))
  let model = TerminalModel(link: link, theme: theme, cell: cell)
  let runner = Runner(app: model, painter: painter, width: width, height: height)
  return (model, runner, link)
}

@MainActor @Test func theWindowSizesTheScreenAndOutputIsFed() throws {
  let (model, runner, link) = try terminal()
  runner.frame(FrameInput())
  let size = link.size.withLock { $0 }
  #expect(size.0 == model.screen.columns && size.1 == model.screen.rows && size.0 > 20 && size.1 > 5)
  model.deliver(Array("hello\r\n\u{1B}[6n".utf8))
  runner.frame(FrameInput())
  #expect(model.screen.text(row: 0) == "hello" && link.take() == Array("\u{1B}[2;1R".utf8))
}

@MainActor @Test func keysGoAsXtermSendsThem() throws {
  let (_, runner, link) = try terminal()
  runner.frame(FrameInput())
  runner.frame(FrameInput(keys: [KeyPress(.tab), KeyPress(.escape), KeyPress(.up), KeyPress(.character(0x63), control: true),
                                 KeyPress(.left, control: true), KeyPress(.function(5))], text: "ls"))
  #expect(link.take() == [0x09, 0x1B] + Array("\u{1B}[A".utf8) + [0x03] + Array("\u{1B}[1;5D\u{1B}[15~ls".utf8))
}

@MainActor @Test func theWheelScrollsBack() throws {
  let (model, runner, _) = try terminal(height: 120)
  runner.frame(FrameInput())
  model.deliver(Array((1...40).map { "line \($0)" }.joined(separator: "\r\n").utf8))
  runner.frame(FrameInput())
  #expect(model.screen.scrollback.count > 0)
  runner.frame(FrameInput(scroll: -100))
  #expect(model.scrolledBack > 0)
  model.deliver(Array("\r\nmore".utf8))
  runner.frame(FrameInput())
  #expect(model.scrolledBack == 0)
}

/// The scrollback has Be's bar (M6l): its up arrow goes back a line,
/// its thumb dragged to the top goes back to the start.
@MainActor @Test func theScrollbackHasABar() throws {
  let (model, runner, _) = try terminal(height: 120)
  runner.frame(FrameInput())
  model.deliver(Array((1...40).map { "line \($0)" }.joined(separator: "\r\n").utf8))
  runner.frame(FrameInput())
  runner.frame(FrameInput())
  guard let thumb = runner.ui.access.first(where: { $0.label == "vertical scroll thumb" }),
    let track = runner.ui.access.first(where: { $0.label == "vertical scrollbar" })
  else {
    Issue.record("no scrollbar")
    return
  }
  let x = track.x + track.width / 2
  func click(_ y: Float) {
    runner.frame(FrameInput(pointerX: x, pointerY: y))
    runner.frame(FrameInput(pointerX: x, pointerY: y, down: true, pressed: true))
    runner.frame(FrameInput(pointerX: x, pointerY: y, released: true))
  }
  click(track.y + 2)
  #expect(model.scrolledBack == 1)
  let y = thumb.y + thumb.height / 2
  runner.frame(FrameInput(pointerX: x, pointerY: y))
  runner.frame(FrameInput(pointerX: x, pointerY: y, down: true, pressed: true))
  runner.frame(FrameInput(pointerX: x, pointerY: y - 500, down: true))
  runner.frame(FrameInput(pointerX: x, pointerY: y - 500, released: true))
  #expect(model.scrolledBack == model.screen.scrollback.count)
}

/// Keys and text in one frame go in the order typed: the text, then Enter.
@MainActor @Test func typedOrderIsKept() throws {
  let (_, runner, link) = try terminal()
  runner.frame(FrameInput())
  var f = FrameInput(keys: [KeyPress(.enter)], text: "echo hi")
  f.sequence = [.text("echo hi"), .key(KeyPress(.enter))]
  runner.frame(f)
  #expect(link.take() == Array("echo hi\r".utf8))
}

@MainActor @Test func aRightClickRoutesTheWordFromTheProgramsDirectory() throws {
  let (model, runner, _) = try terminal()
  var routed: [Route] = []
  runner.router = { routed.append($0) }
  runner.frame(FrameInput())
  model.deliver(Array("\u{1B}]7;file:///data/src\u{1B}\\error: (main.swift:42:7:) here\r\n".utf8))
  runner.frame(FrameInput())
  // The cell under the word's third character, in the view.
  let pad = try shipped("neon-tab").style("terminal").padding
  let x = pad.left + model.cell.width * 10.5, y = pad.top + model.cell.height * 0.5
  #expect(model.word(atX: x, y: y) == "main.swift:42:7")
  #expect(model.word(atX: pad.left + model.cell.width * 6.5, y: y) == "")
  runner.frame(FrameInput(pointerX: x, pointerY: y))
  runner.frame(FrameInput(pointerX: x, pointerY: y, secondaryPressed: true))
  runner.frame(FrameInput(pointerX: x, pointerY: y))
  let route = try #require(runner.ui.access.first { $0.role == .menuItem && $0.label == "Route" })
  let at = (route.x + route.width / 2, route.y + route.height / 2)
  runner.frame(FrameInput(pointerX: at.0, pointerY: at.1))
  runner.frame(FrameInput(pointerX: at.0, pointerY: at.1, down: true, pressed: true))
  runner.frame(FrameInput(pointerX: at.0, pointerY: at.1, released: true))
  runner.frame(FrameInput())
  #expect(routed == [Route(wdir: "/data/src", data: "main.swift:42:7")])
}

/// Keys from rio's raw cons, as runes: what xterm sends for each.
@MainActor @Test func runesFromRioGoAsXtermSendsThem() throws {
  let (model, runner, link) = try terminal()
  runner.frame(FrameInput())
  let runes = [0x6C, 0x0A, 0x08, 0x7F, 0x03, KeyRune.up, KeyRune.left, KeyRune.pgdown, KeyRune.f(5), KeyRune.shift]
  model.deliverKeys(Array(String(String.UnicodeScalarView(runes.compactMap { Unicode.Scalar($0) })).utf8))
  runner.frame(FrameInput())
  #expect(link.take() == Array("l\r".utf8) + [0x7F] + Array("\u{1B}[3~".utf8) + [0x03]
    + Array("\u{1B}[A\u{1B}[D\u{1B}[6~\u{1B}[15~".utf8))
  // In application cursor mode (DECCKM), the arrows' other form.
  model.deliver(Array("\u{1B}[?1h".utf8))
  runner.frame(FrameInput())
  model.deliverKeys(Array(String(Character(Unicode.Scalar(KeyRune.up)!)).utf8))
  runner.frame(FrameInput())
  #expect(link.take() == Array("\u{1B}OA".utf8))
}

/// The colours are the theme's: the terminal part's ink and fill, and
/// term.0 to term.15.
@Test func thePaletteIsTheThemes() throws {
  let theme = try shipped("platinum-indigo")
  let p = TerminalPalette(theme: theme)
  #expect(p.foreground == theme.style("terminal").ink & 0xFF_FFFF)
  #expect(p.background == theme.style("terminal").fill & 0xFF_FFFF)
  #expect(p.rgb(.indexed(1), foreground: true) == theme.color("term.1") & 0xFF_FFFF)
  #expect(p.rgb(.indexed(196), foreground: true) == 0xFF0000)
}
