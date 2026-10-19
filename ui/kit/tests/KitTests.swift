// SPDX-License-Identifier: BSD-3-Clause

// Kit (kit(2)): an app's body built each frame from its model; bindings
// writing back; a closure button; actions declared once with async
// handlers (one at a time, a frame asked for when one ends); views keyed
// by place or by `.id`; the sample drawn as recorded.

import FoundationEssentials
import GlyphAtlas
import Kit
import KitSample
import OpenType
import Testing
import TextLayout

@MainActor final class Songs: App {
  var query = ""
  var selection: Int? = nil
  var names = ["Teardrop", "Glory Box", "Overcome"]
  var added = 0
  var saves = 0
  var showBanner = false
  var gate: CheckedContinuation<Void, Never>?

  var title: String { "Songs" }
  var actions: [ActionHandler] {
    [ActionHandler(Action("file.save", label: "Save", key: KeyPress(.character(0x73), control: true))) { [self] _ in
       // Held open until the test lets it finish.
       await withCheckedContinuation { gate = $0 }
       saves += 1
     }]
  }
  var body: Group {
    MenuBar([MenuSpec("File", ["file.save"])])
    if showBanner { Text("Saved", class: "note") }
    TextField("Query", text: Binding(self, \.query), width: .pixels(200)).id("query")
    List("Results", count: names.count, widths: [200], selection: Binding(self, \.selection)) { [names] in [names[$0]] }
    HStack {
      Button(action: "file.save")
      Button("Add") { [self] in
        added += 1
        names.append("New \(added)")
      }
    }
  }
}

let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().path

/// A shipped theme, resolved from its file in ui/theme/themes.
func shipped(_ name: String) throws -> Theme {
  try Theme.resolve(ThemeStack(theme: name, variant: nil)) { n in
    (try? Data(contentsOf: URL(filePath: "\(repository)/ui/theme/themes/\(n)"))).map { [UInt8]($0) }
  }
}

@MainActor func kit(_ app: any App) -> Runner {
  Runner(app: app, painter: Painter(theme: .base, fonts: Fonts(), cache: GlyphCache(coverageSize: 64, fieldSize: 64)),
         width: 400, height: 300)
}

@MainActor @Test func theBodyIsBuiltFromTheModel() {
  let app = Songs()
  let r = kit(app)
  r.frame(FrameInput())
  #expect(r.ui.access[0].label == "Songs")
  #expect(r.ui.access.filter { $0.role == .row }.count == 3)
  #expect(r.ui.access.contains { $0.role == .button && $0.label == "Save" && $0.action >= 0 })
  app.names.append("Unfinished Sympathy")
  r.frame(FrameInput())
  #expect(r.ui.access.filter { $0.role == .row }.count == 4)
}

@MainActor @Test func bindingsAndClosuresWriteToTheModel() throws {
  let app = Songs()
  let r = kit(app)
  r.frame(FrameInput())
  r.frame(FrameInput(keys: [KeyPress(.tab), KeyPress(.tab)]))  // past the menu's title, to the field
  r.frame(FrameInput(text: "trip"))
  #expect(app.query == "trip")
  // A click on Add.
  let add = try #require(r.ui.access.first { $0.label == "Add" })
  for input in [FrameInput(pointerX: add.x + 2, pointerY: add.y + 2),
                FrameInput(pointerX: add.x + 2, pointerY: add.y + 2, down: true, pressed: true),
                FrameInput(pointerX: add.x + 2, pointerY: add.y + 2, released: true)]
  {
    r.frame(input)
  }
  #expect(app.added == 1 && app.names.last == "New 1")
}

@MainActor @Test func anAsyncActionRunsOneAtATime() async {
  let app = Songs()
  let r = kit(app)
  var woken = 0
  r.wake = { woken += 1 }
  r.frame(FrameInput())
  let save = KeyPress(.character(0x73), control: true)
  r.frame(FrameInput(keys: [save]))
  await Task.yield()
  #expect(r.running == ["file.save"] && app.saves == 0)
  // A second Save waits for the first.
  r.frame(FrameInput(keys: [save]))
  // (Until the handler holding the gate has reached it.)
  func held() async -> CheckedContinuation<Void, Never>? {
    for _ in 0..<1000 where app.gate == nil { await Task.yield() }
    defer { app.gate = nil }
    return app.gate
  }
  let first = await held()
  #expect(first != nil)
  first?.resume()
  let second = await held()
  #expect(app.saves == 1 && r.running == ["file.save"] && r.wantsFrame && woken == 1 && second != nil)
  second?.resume()
  await r.settle()
  #expect(app.saves == 2 && r.running.isEmpty)
}

@MainActor @Test func anIdKeepsAViewsStateWhenOthersComeAndGo() {
  let app = Songs()
  let r = kit(app)
  r.frame(FrameInput())
  r.frame(FrameInput(keys: [KeyPress(.tab), KeyPress(.tab)]))
  r.frame(FrameInput(text: "abc"))
  // A view appears before the field: the field, keyed by its id, keeps
  // its focus and caret.
  app.showBanner = true
  r.frame(FrameInput())
  r.frame(FrameInput(text: "d"))
  #expect(app.query == "abcd" && r.ui.editingText)
}

/// Every face in data/fonts, as the device has them in /lib/fonts.
func allFonts() throws -> [Font] {
  var out: [Font] = []
  let dir = "\(repository)/data/fonts"
  for family in try FileManager.default.contentsOfDirectory(atPath: dir).sorted() {
    for file in try FileManager.default.contentsOfDirectory(atPath: "\(dir)/\(family)").sorted()
    where file.hasSuffix(".ttf") || file.hasSuffix(".otf") {
      let data = try #require(try? Data(contentsOf: URL(filePath: "\(dir)/\(family)/\(file)")))
      out.append(try Font([UInt8](data)))
    }
  }
  return out
}

/// The sample, in each shipped theme and the faces its typefaces name,
/// draws the same frame each time, and the frame kit-sample.tsv records,
/// which bin/kit-test draws on the device too. A mismatch writes the
/// drawing (binary PPM) to .build/kit-sample/; VX_KIT_RECORD=1 records
/// the digests anew.
@MainActor @Test func theSampleIsDrawnAsRecorded() throws {
  let path = "\(repository)/ui/kit/tests/kit-sample.tsv"
  let text = (try? String(contentsOf: URL(filePath: path), encoding: .utf8)) ?? ""
  var recorded: [String: String] = [:]
  for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
    let f = line.split(separator: "\t").map(String.init)
    if f.count == 3 { recorded["\(f[0]) \(f[1])"] = f[2] }
  }
  let record = ProcessInfo.processInfo.environment["VX_KIT_RECORD"] == "1"
  var out = "# The Kit sample's digests (KitTests, bin/kit-test): theme, size, FNV-1a of its pixels.\n"
  let candidates = try allFonts()
  for name in ["platinum-indigo", "neon-tab"] {
    let theme = try shipped(name)
    let fonts = Fonts(theme: theme, from: candidates)
    let a = KitSample.render(width: 640, height: 400, theme: theme, fonts: fonts)
    let b = KitSample.render(width: 640, height: 400, theme: theme, fonts: fonts)
    #expect(a.pixels == b.pixels, "\(name)")
    let d = KitSample.digest(a), key = "\(name) 640x400"
    out += "\(name)\t640x400\t\(d)\n"
    if record || recorded[key] == d { continue }
    let dir = "\(repository)/.build/kit-sample"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = "\(dir)/\(name).ppm"
    var ppm = Array("P6\n\(a.width) \(a.height)\n255\n".utf8)
    for p in a.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
    try Data(ppm).write(to: URL(filePath: file))
    Issue.record("\(key): drawn \(d), recorded \(recorded[key] ?? "nothing"); the drawing is \(file)")
  }
  if record { try Data(out.utf8).write(to: URL(filePath: path)) }
}

/// A context menu on everything (M6k): its Route goes to the platform's
/// router as the app's `route(subject:)` says.
struct Routable: View {
  func build(_ c: inout BuildContext, id: String) { c.ui.contextMenu("any", items: []) }
}

@MainActor final class Notes: App {
  var title: String { "Notes" }
  var actions: [ActionHandler] { [] }
  var body: Group { Routable() }
  func route(subject: String) -> Route? { Route(wdir: "/data/notes", data: subject, attributes: [("line", "3")]) }
}

@MainActor @Test func aContextMenusRouteGoesToTheRouter() throws {
  let app = Notes()
  let r = kit(app)
  var sent: [Route] = []
  r.router = { sent.append($0) }
  r.frame(FrameInput())
  try r.ui.perform("route.open", [.string("todo.md")])
  r.frame(FrameInput())
  #expect(sent == [Route(wdir: "/data/notes", data: "todo.md", attributes: [("line", "3")])])
  // The default: the subject as text.
  let songs = kit(Songs())
  songs.router = { sent.append($0) }
  songs.frame(FrameInput())
  songs.ui.declare(Action("route.open", label: "Route", arguments: [ActionArgument("subject", .string)]))
  try songs.ui.perform("route.open", [.string("http://example.org")])
  songs.frame(FrameInput())
  #expect(sent.last == Route(data: "http://example.org"))
}

/// A window whose content doesn't fit scrolls, with bars (M6l): nothing is
/// out of reach without a resize; one whose content fits shows none.
@MainActor final class Tall: App {
  var rows = 40
  var title: String { "Tall" }
  var actions: [ActionHandler] { [] }
  var body: Group {
    VStack {
      ForEach(Array(0..<rows), id: { $0 }) { i in Button("Item \(i)") {} }
    }
  }
}

@MainActor @Test func aWindowScrollsWhatDoesntFit() {
  let app = Tall()
  let r = kit(app)
  r.frame(FrameInput())
  // The bars need the content measured: the window asks for a frame more
  // itself, with no input.
  #expect(r.wantsFrame)
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.label == "vertical scrollbar" })
  r.frame(FrameInput())
  #expect(!r.wantsFrame)
  let y0 = r.ui.access.first { $0.label == "Item 0" }?.y ?? .nan
  r.frame(FrameInput(pointerX: 50, pointerY: 50, scroll: 100))
  r.frame(FrameInput(pointerX: 50, pointerY: 50))
  #expect(r.ui.access.first { $0.label == "Item 0" }?.y == y0 - 100)
  app.rows = 2
  r.frame(FrameInput())
  r.frame(FrameInput())
  #expect(!r.ui.access.contains { $0.label.hasSuffix("scrollbar") })
}

/// A panel, the desktop or a view doesn't scroll as a whole (M6l: Deskbar
/// sizes its panel to what it shows): no bars, whatever overflows.
@MainActor @Test func aWindowThatDoesntScrollHasNoBars() {
  let r = kit(Tall())
  r.scrolls = false
  r.frame(FrameInput())
  r.frame(FrameInput())
  r.frame(FrameInput())
  #expect(!r.ui.access.contains { $0.label.hasSuffix("scrollbar") })
}
