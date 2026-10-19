// SPDX-License-Identifier: BSD-3-Clause

// Actions declared once (M6i part 4): each gives its control or menu
// item, its key binding, keyboard focus, a scripting entry and an
// accessibility entry; the accessibility tree is each frame's side
// output.

import AccessTree
import FoundationEssentials
import GlyphAtlas
import Testing
import TextLayout
import UICore

private let save = Action("file.save", label: "Save", key: KeyPress(.character(0x73), control: true))
private let route = Action("route.edit", label: "Route → edit", key: KeyPress(.enter, control: true))
private let copy = Action("edit.copy", label: "Copy", key: KeyPress(.character(0x63), control: true))
private let snap = Action("window.snap", label: "Snap left", key: KeyPress(.left, alt: true),
                          gesture: "drag the tab to the screen's left edge")
private let rename = Action("file.rename", label: "Rename", arguments: [ActionArgument("name", .string)])

/// Frames that click: over, down, up.
private func click(_ u: inout UI, at r: Rect, build: (inout UI) -> Void) {
  let (x, y) = (r.x + r.width / 2, r.y + r.height / 2)
  for input in [FrameInput(pointerX: x, pointerY: y),
                FrameInput(pointerX: x, pointerY: y, down: true, pressed: true),
                FrameInput(pointerX: x, pointerY: y, released: true)]
  {
    u.begin(input)
    build(&u)
    u.end()
  }
}

@Test func anActionGivesItsButtonAndItsKey() throws {
  var u = try ui()
  u.declare(save)
  var got: [InvocationSource] = []
  func build(_ u: inout UI, _ input: FrameInput = FrameInput()) {
    u.begin(input)
    if let i = u.button(action: "file.save") { got.append(i.source) }
    u.end()
  }
  build(&u)
  let r = try #require(u.rect("file.save", in: UI.key("#root")))
  // Labelled with the action's label.
  #expect(u.access.contains { $0.role == .button && $0.label == "Save" && $0.action == 0 })
  click(&u, at: r) { u in
    if let i = u.button(action: "file.save") { got.append(i.source) }
  }
  #expect(got == [.pointer])
  build(&u, FrameInput(keys: [KeyPress(.character(0x73), control: true)]))
  #expect(got == [.pointer, .key])
  // Rebound, the old key does nothing and the new one invokes it.
  u.rebind("file.save", to: KeyPress(.function(2)))
  build(&u, FrameInput(keys: [KeyPress(.character(0x73), control: true)]))
  build(&u, FrameInput(keys: [KeyPress(.function(2))]))
  #expect(got == [.pointer, .key, .key])
  #expect(KeyPress(.character(0x73), shift: true, control: true, alt: true).description == "Ctrl+Alt+Shift+S")
}

@Test func actionsNoPointerReachesAreReported() throws {
  var u = try ui()
  for a in [save, copy, snap, route] { u.declare(a) }
  u.begin(FrameInput())
  u.button(action: "file.save")
  // A closed menu's items are reached: it's built with them either way.
  _ = u.menu("context", shown: false, at: (0, 0), items: ["route.edit"])
  u.end()
  // Copy has no control or menu item; Snap names its gesture.
  #expect(u.unreachable() == ["edit.copy"])
}

@Test func tabMovesFocusAndEnterOrSpacePresses() throws {
  var u = try ui()
  var clicked: [String] = []
  func build(_ u: inout UI, _ input: FrameInput) {
    u.begin(input)
    for id in ["one", "two", "three"] where u.button(id, id) { clicked.append(id) }
    u.end()
  }
  build(&u, FrameInput())
  let root = UI.key("#root")
  build(&u, FrameInput(keys: [KeyPress(.tab)]))
  #expect(u.focus == UI.key("one", in: root) && u.focusVisible)
  // The focus ring: the storyboard's 2 px amber outline, 2 px out, on
  // whole pixels.
  let r = try #require(u.rect("one", in: root))
  let ring = u.painter.snapped(r.x - 4, r.y - 4, r.width + 8, r.height + 8)
  #expect(u.painter.list.quads.contains { q in
    q.stroke == Theme.neonTab.color("neon.amber") && q.border == 2 && q.x == ring.x && q.width == ring.width
  })
  build(&u, FrameInput(keys: [KeyPress(.tab), KeyPress(.tab)]))
  #expect(u.focus == UI.key("three", in: root))
  build(&u, FrameInput(keys: [KeyPress(.tab)]))  // wraps
  #expect(u.focus == UI.key("one", in: root))
  build(&u, FrameInput(keys: [KeyPress(.tab, shift: true)]))
  #expect(u.focus == UI.key("three", in: root))
  build(&u, FrameInput(keys: [KeyPress(.enter)]))
  build(&u, FrameInput(keys: [KeyPress(.tab, shift: true), KeyPress(.space)]))
  #expect(clicked == ["three", "two"])
  // The pointer hides the ring.
  build(&u, FrameInput(pointerX: 300, pointerY: 290, down: true, pressed: true))
  #expect(!u.focusVisible)
}

@Test func aFocusedFieldKeepsItsKeysFromBindings() throws {
  var u = try ui()
  u.declare(save)
  u.declare(Action("select.all", label: "Select all", key: KeyPress(.character(0x61), control: true)))
  u.declare(Action("search", label: "Search", key: KeyPress(.character(0x73))))
  var text = "Teardrop"
  var saved = 0, searched = 0
  func build(_ u: inout UI, _ input: FrameInput) {
    u.begin(input)
    u.textField("q", text: &text, label: "Query", width: .pixels(200))
    if u.button(action: "file.save") != nil { saved += 1 }
    if u.take("search") != nil { searched += 1 }
    _ = u.take("select.all")
    u.end()
  }
  build(&u, FrameInput())
  build(&u, FrameInput(keys: [KeyPress(.tab)]))
  #expect(u.focus == UI.key("q", in: UI.key("#root")))
  // A plain key types; Control-A selects the field's text; Control-S
  // still saves.
  build(&u, FrameInput(keys: [KeyPress(.character(0x73))], text: "s"))
  build(&u, FrameInput(keys: [KeyPress(.character(0x61), control: true), KeyPress(.character(0x73), control: true)]))
  build(&u, FrameInput(keys: [KeyPress(.backspace)]))
  #expect(text == "" && saved == 1 && searched == 0)
  // Unfocused, the plain key is the binding.
  build(&u, FrameInput(keys: [KeyPress(.tab), KeyPress(.character(0x73))]))
  #expect(searched == 1)
}

@Test func scriptsPerformActionsWithTypedArguments() throws {
  var u = try ui()
  u.declare(rename)
  #expect(throws: PerformError.noSuchAction) { try u.perform("file.delete") }
  #expect(throws: PerformError.arguments) { try u.perform("file.rename", [.int(3)]) }
  #expect(throws: PerformError.arguments) { try u.perform("file.rename") }
  try u.perform("file.rename", [.string("Teardrop.flac")])
  #expect(u.pending)
  u.begin(FrameInput())
  let i = u.take("file.rename")
  u.end()
  #expect(i?.arguments == [.string("Teardrop.flac")] && i?.source == .script && !u.pending)
  // One nobody takes in a whole frame is dropped.
  try u.perform("file.rename", [.string("x")])
  u.begin(FrameInput())
  u.end()
  u.begin(FrameInput())
  #expect(u.take("file.rename") == nil)
  u.end()
  #expect(u.declared.map { $0.name } == ["file.rename"])
}

@Test func aMenuOffersItsActions() throws {
  var u = try ui()
  for a in [route, copy] { u.declare(a) }
  var shown = true
  var routed = 0
  func build(_ u: inout UI, _ input: FrameInput) {
    u.begin(input)
    if u.take("route.edit") != nil { routed += 1 }
    if u.menu("context", shown: shown, at: (40, 30), items: ["route.edit", "edit.copy"]) { shown = false }
    u.end()
  }
  build(&u, FrameInput())
  let menu = UI.key("context", in: UI.key("#root"))
  let item = try #require(u.rect("route.edit", in: menu))
  #expect(u.rect("context", in: UI.key("#root"))?.width ?? 0 >= Theme.cqw(12))
  #expect(u.access.contains { $0.role == .menu } && u.access.contains { $0.role == .menuItem && $0.label == "Copy" })
  click(&u, at: item) { u in
    if u.take("route.edit") != nil { routed += 1 }
    if u.menu("context", shown: shown, at: (40, 30), items: ["route.edit", "edit.copy"]) { shown = false }
  }
  // Chosen during the build after its handler looked: taken next frame.
  #expect(!shown && routed == 0 && u.pending)
  build(&u, FrameInput())
  #expect(routed == 1)
  shown = true
  build(&u, FrameInput())
  build(&u, FrameInput(keys: [KeyPress(.escape)]))
  #expect(!shown && u.pending)  // it asks for the frame that shows it gone
}

@Test func eachFrameGivesItsAccessibilityTree() throws {
  var u = try ui(600, 300)
  u.declare(save)
  u.title = "Trip-hop, 90s · query"
  var query = "Audio:Year in 1990..<2000"
  var selection: Int? = 1
  let names = ["Massive Attack - Unfinished Sympathy.flac", "Portishead - Glory Box.flac"]
  func build(_ u: inout UI, _ input: FrameInput) {
    u.begin(input)
    u.label("heading", "Songs")
    u.textField("q", text: &query, label: "Query", width: .pixels(300))
    u.button(action: "file.save")
    u.button("plain", "Plain")
    u.list("rows", label: "Results", count: names.count, rowHeight: 22, columns: ["Name"], widths: [120],
           selection: &selection) { [names[$0]] }
    u.end()
  }
  build(&u, FrameInput())
  build(&u, FrameInput(keys: [KeyPress(.tab)]))
  let t = u.access
  #expect(t[0].role == .window && t[0].label == "Trip-hop, 90s · query" && t[0].parent == -1)
  #expect(t.contains { $0.role == .label && $0.label == "Songs" && $0.parent == 0 })
  let field = try #require(t.first { $0.role == .textField })
  #expect(field.label == "Query" && field.value == query && field.states.contains([.focused, .editable]))
  let list = try #require(t.firstIndex { $0.role == .list })
  #expect(t[list].label == "Results")
  let rows = t.indices.filter { t[$0].role == .row }
  #expect(rows.count == 2 && rows.allSatisfy { t[$0].parent == Int32(list) })
  #expect(t[rows[1]].states.contains(.selected) && !t[rows[0]].states.contains(.selected))
  // A cell says its whole text, though the list shows it elided.
  #expect(t.contains { $0.role == .cell && $0.label == names[0] && Int($0.parent) == rows[0] })
  #expect(t.contains { $0.role == .columnHeader && $0.label == "Name" })
  // Pressed by an assistive client: the action through its declaration,
  // a plain button as a click.
  let saveNode = try #require(t.first { $0.label == "Save" })
  let plainNode = try #require(t.first { $0.label == "Plain" })
  try u.press(saveNode.key)
  try u.press(plainNode.key)
  u.begin(FrameInput())
  let invoked = u.take("file.save")
  let plain = u.button("plain", "Plain")
  u.end()
  #expect(invoked?.source == .accessibility && plain)
  // Unchanged frames give the same tree.
  build(&u, FrameInput())
  let a = u.access
  build(&u, FrameInput())
  #expect(a == u.access)
}

/// Board 06's menu ("Route → edit", "Copy") over its terminal, built with
/// the kit (TODHCHAI_UI_SAMPLE4 names a file to write it to), and a
/// button with the keyboard's focus ring.
@Test func aMenuFromTheStoryboard() throws {
  let scale: Float = 2
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts(), scale: scale,
                              cache: GlyphCache(coverageSize: 2048, fieldSize: 256)),
             width: 420, height: 220)
  for a in [route, copy, save] { u.declare(a) }
  func build(_ input: FrameInput) {
    u.begin(input)
    let content = Chrome.window(&u.painter, 10, 10, 300, 160, title: "Terminal", focused: false)
    u.open("win", width: .pixels(content.width), height: .pixels(content.height), axis: .vertical,
           at: (content.x, content.y))
    u.box("pad", width: .pixels(0), height: .pixels(90))
    u.button(action: "file.save")
    u.close()
    _ = u.menu("context", shown: true, at: (140, 60), items: ["route.edit", "edit.copy"])
    u.end()
  }
  build(FrameInput())
  build(FrameInput(keys: [KeyPress(.tab)]))
  #expect(u.focusVisible)
  guard let path = ProcessInfo.processInfo.environment["TODHCHAI_UI_SAMPLE4"] else { return }
  var canvas = Canvas(width: Int(420 * scale), height: Int(220 * scale), color: 0x0A0A12)
  u.painter.render(into: &canvas)
  var ppm = Array("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
  for p in canvas.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
  try Data(ppm).write(to: URL(filePath: path))
}

/// A character the style's face lacks comes from the next face of its
/// stack (Barlow Condensed has no arrows; IBM Plex Sans does), on the same
/// baseline, its spaces kept.
@Test func aMissingCharacterFallsBack() throws {
  var u = try ui()
  let item = u.theme.style("menu.item")
  u.painter.list.reset()
  u.painter.text("a → b", 0, 0, item)
  let glyphs = u.painter.list.quads.filter { $0.kind != UIQuad.shape }
  #expect(glyphs.count == 3)
  #expect(u.painter.measure("a → b", item) > u.painter.measure("a  b", item))
}
