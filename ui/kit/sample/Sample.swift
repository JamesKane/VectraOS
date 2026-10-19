// SPDX-License-Identifier: BSD-3-Clause

// The UI Kit's sample app (kit(2)): board 02's live query ("A query is
// a folder, and it stays live") written with Kit. `render` draws one
// deterministic frame of it in a focused window's chrome on the desk, in
// a theme and its faces: KitTests on the host and bin/kit-test on the
// device each compare its digest with ui/kit/tests/kit-sample.tsv.

import GlyphAtlas
import Kit
import TextLayout

@MainActor public final class SampleApp: App {
  public var query = "Audio:Genre ~= \"trip-hop\" && Audio:Year in 1990..<2000"
  public var selection: Int? = 3
  public var saved = 0
  public let rows: [(String, String, String, String, String)] = [
    ("Massive Attack - Unfinished Sympathy.flac", "Massive Attack", "1991", "5:08", "ripper"),
    ("Portishead - Glory Box.flac", "Portishead", "1994", "5:06", "ripper"),
    ("Tricky - Overcome.flac", "Tricky", "1995", "4:55", "ripper"),
    ("Sneaker Pimps - 6 Underground.flac", "Sneaker Pimps", "1996", "3:48", "ripper"),
    ("Morcheeba - Trigger Hippie.flac", "Morcheeba", "1996", "4:42", "ripper"),
    ("Massive Attack - Teardrop.flac", "Massive Attack", "1998", "5:30", "browser"),
    ("Portishead - Only You.flac", "Portishead", "1997", "4:58", "ripper"),
  ]
  /// Where the window's content goes (its chrome is drawn around it).
  public let content: (x: Float, y: Float, width: Float, height: Float)

  public init(content: (x: Float, y: Float, width: Float, height: Float)) { self.content = content }

  public var title: String { "Trip-hop, 90s · query" }
  public var actions: [ActionHandler] {
    [ActionHandler(Action("query.save", label: "Save query", key: KeyPress(.character(0x73), control: true))) {
       [self] _ in saved += 1
     },
     ActionHandler(Action("window.close", label: "Close", key: KeyPress(.character(0x77), control: true))) { _ in }]
  }

  public var body: Group {
    let c = Theme.cqw
    let rows = rows
    Window(x: content.x, y: content.y, width: content.width, height: content.height) {
      MenuBar([MenuSpec("Query", ["query.save", "window.close"]), MenuSpec("Edit", ["edit.undo", "edit.redo"])])
      HStack(class: "query", width: .percent(1)) {
        Text("Query", class: "query.label")
        Spacer(c(0.6))
        TextField("Query", text: Binding(self, \.query)).id("query")
      }
      List("Results", count: rows.count, columns: ["Name", "Audio:Artist", "Audio:Year", "Length", "sys:origin-app"],
           widths: [c(26), c(12), c(7), c(6), c(10)], numeric: [false, false, true, true, false],
           selection: Binding(self, \.selection), state: { rows[$0].4 == "browser" ? "new" : "" }) { r in
        [rows[r].0, rows[r].1, rows[r].2, rows[r].3, rows[r].4]
      }
      HStack(class: "status", width: .percent(1)) {
        Text("live · added \"Teardrop\" at journal seq 48213", class: "status.live")
        Spacer()
        Button(action: "query.save", class: "button.primary")
      }
    }
  }
}

public enum KitSample {
  /// The sample at `width` by `height` pixels (one logical pixel each),
  /// in `theme` and `fonts`: the desk, the window's chrome, and the app's
  /// frame after a few frames of input (Tab to the query, the end of it, a
  /// word typed).
  @MainActor public static func render(width: Int, height: Int, theme: Theme, fonts: Fonts) -> Canvas {
    var chrome = Painter(theme: theme, fonts: fonts, cache: GlyphCache(coverageSize: 1024, fieldSize: 256))
    let w = Float(width), h = Float(height)
    let (ww, wh) = (min(w - 80, 1000), min(h - 120, 520))
    let content = Chrome.window(&chrome, (w - ww) / 2, (h - wh) / 2, ww, wh, title: "Trip-hop, 90s · query",
                                focused: true)
    let app = SampleApp(content: content)
    let runner = Runner(app: app, painter: Painter(theme: theme, fonts: fonts,
                                                   cache: GlyphCache(coverageSize: 1024, fieldSize: 256)),
                        width: w, height: h)
    runner.frame(FrameInput())
    runner.frame(FrameInput(keys: [KeyPress(.tab), KeyPress(.tab), KeyPress(.tab)]))
    runner.frame(FrameInput(keys: [KeyPress(.end)]))
    runner.frame(FrameInput(text: " order"))
    runner.frame(FrameInput())
    var canvas = Canvas(width: width, height: height, color: theme.color("desk") & 0xFF_FFFF)
    chrome.render(into: &canvas)
    runner.ui.painter.render(into: &canvas)
    return canvas
  }
}

extension KitSample {
  /// FNV-1a over a drawing: its width and height (32 bits each, low byte
  /// first), then each pixel's red, green and blue, in hex.
  public static func digest(_ c: Canvas) -> String {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    func eat(_ b: UInt8) {
      h ^= UInt64(b)
      h = h &* 0x0000_0100_0000_01B3
    }
    for v in [c.width, c.height] { for s in stride(from: 0, to: 32, by: 8) { eat(UInt8(truncatingIfNeeded: v >> s)) } }
    for p in c.pixels {
      eat(UInt8(p >> 16 & 0xFF))
      eat(UInt8(p >> 8 & 0xFF))
      eat(UInt8(p & 0xFF))
    }
    return String(h, radix: 16)
  }
}
