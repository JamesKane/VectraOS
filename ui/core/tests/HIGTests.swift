// SPDX-License-Identifier: BSD-3-Clause

// The 1990s HIGs' decisions in the kit (M6i part 6, 2026-10-12): controls'
// edges at 3:1 against what they sit on, a pressed state that rolls off
// with the pointer, undo (the stack, and a text field's runs of typing),
// Be's menu bar in each window, and a right-click's context menu routing
// first.

import AccessTree
import FoundationEssentials
import Glibc
import GlyphAtlas
import Testing
import TextLayout
import UICore

/// WCAG's contrast ratio between two 0xRRGGBB colours.
func contrast(_ a: UInt32, _ b: UInt32) -> Double {
  func luminance(_ c: UInt32) -> Double {
    func ch(_ s: UInt32) -> Double {
      let v = Double(c >> s & 0xFF) / 255
      return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * ch(16) + 0.7152 * ch(8) + 0.0722 * ch(0)
  }
  let (x, y) = (luminance(a), luminance(b))
  return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

@Test func controlsEdgesAreThreeToOne() {
  for theme in [Theme.neonTab, .accessible] {
    for name in ["button", "button.primary", "button.danger", "toggle", "toggle.on", "field", "field.focused"] {
      let s = theme.style(name)
      for bg in [theme.color("desk"), theme.color("chrome")] {
        #expect(contrast(s.stroke & 0xFF_FFFF, bg & 0xFF_FFFF) >= 3, "\(theme.name) \(name)")
      }
    }
  }
  // The storyboard's plain edge isn't (why controls have their own).
  #expect(contrast(Theme.neonTab.color("outline"), Theme.neonTab.color("desk")) < 1.5)
}

@Test func aButtonShowsItsPressAndLetsGoWhenThePointerLeaves() throws {
  var u = try ui()
  func frame(_ input: FrameInput) -> UIQuad? {
    u.begin(input)
    u.button("go", "Go")
    u.end()
    // The button's background: the first shape.
    return u.painter.list.quads.first { $0.kind == UIQuad.shape }
  }
  _ = frame(FrameInput())
  let r = try #require(u.rect("go", in: UI.key("#root")))
  let (x, y) = (r.x + 4, r.y + 4)
  let resting = try #require(frame(FrameInput(pointerX: x, pointerY: y)))
  let held = try #require(frame(FrameInput(pointerX: x, pointerY: y, down: true, pressed: true)))
  #expect(held.fill != resting.fill && held.fill == u.theme.style("button.held").fill)
  // Rolled off, still down: not pressed any more; back over it: pressed.
  _ = frame(FrameInput(pointerX: 390, pointerY: 290, down: true))
  let off = try #require(frame(FrameInput(pointerX: 390, pointerY: 290, down: true)))
  #expect(off.fill == resting.fill)
  _ = frame(FrameInput(pointerX: x, pointerY: y, down: true))
  let back = try #require(frame(FrameInput(pointerX: x, pointerY: y, down: true)))
  #expect(back.fill == held.fill)
}

@Test func anUndoStackTakesChangesBackAndJoinsGroups() {
  var s = UndoStack<String>()
  s.record("Typing", before: "", after: "h", group: 1)
  s.record("Typing", before: "h", after: "hi", group: 1)
  s.record("Deletion", before: "hi", after: "h", group: 2)
  #expect(s.undoLabel == "Deletion")
  #expect(s.undo() == "hi" && s.undo() == "" && s.undo() == nil)
  #expect(s.redo() == "hi" && s.redoLabel == "Deletion")
  // A new change after undoing drops what could be redone.
  s.record("Typing", before: "hi", after: "hi!", group: 3)
  #expect(!s.canRedo && s.undo() == "hi")
  var small = UndoStack<Int>()
  small.limit = 3
  for k in 0..<5 { small.record("n", before: k, after: k + 1) }
  #expect(small.undo() == 4 && small.undo() == 3 && small.undo() == 2 && small.undo() == nil)
}

@Test func aFieldUndoesByWordsAndDeletions() throws {
  var u = try ui()
  var text = ""
  func frame(_ input: FrameInput) {
    u.begin(input)
    u.textField("q", text: &text, width: .pixels(300))
    u.end()
  }
  frame(FrameInput())
  frame(FrameInput(keys: [KeyPress(.tab)]))
  for ch in "trip hop" { frame(FrameInput(text: String(ch))) }
  frame(FrameInput(keys: [KeyPress(.backspace)]))
  frame(FrameInput(keys: [KeyPress(.backspace)]))
  #expect(text == "trip h")
  let undo = KeyPress(.character(0x7A), control: true), redo = KeyPress(.character(0x7A), shift: true, control: true)
  frame(FrameInput(keys: [undo]))
  #expect(text == "trip hop")  // the two deletions, as one
  frame(FrameInput(keys: [undo]))
  #expect(text == "trip ")  // "hop"
  frame(FrameInput(keys: [undo]))
  #expect(text == "")  // "trip ", the space ending its word
  frame(FrameInput(keys: [redo]))
  #expect(text == "trip ")
  // Moving the caret ends a run: typing after it is undone alone.
  frame(FrameInput(text: "x"))
  frame(FrameInput(keys: [KeyPress(.home)]))
  frame(FrameInput(text: "y"))
  frame(FrameInput(keys: [undo]))
  #expect(text == "trip x")
  #expect(u.declared.contains { $0.name == "edit.undo" } && u.editingText)
}

@Test func aMenuBarOpensOnThePressAndSlidesAcross() throws {
  var u = try ui(500, 300)
  for a in [Action("file.open", label: "Open"), Action("file.save", label: "Save"), Action("edit.copy", label: "Copy")] {
    u.declare(a)
  }
  var saved = 0
  func frame(_ input: FrameInput) {
    u.begin(input)
    u.menuBar("bar", [MenuSpec("File", ["file.open", "file.save"]), MenuSpec("Edit", ["edit.copy"])])
    // Built after the bar: the drop-down is drawn over it, and wins the
    // pointer.
    u.box("below", class: "panel", width: .percent(1), height: .pixels(200), flags: [.clickable, .background])
    if u.take("file.save") != nil { saved += 1 }
    u.end()
  }
  frame(FrameInput())
  let bar = UI.key("bar", in: UI.key("#root"))
  let file = try #require(u.rect("t0", in: bar)), edit = try #require(u.rect("t1", in: bar))
  #expect(u.unreachable().isEmpty)  // closed menus' items count
  frame(FrameInput(pointerX: file.x + 4, pointerY: file.y + 4))
  frame(FrameInput(pointerX: file.x + 4, pointerY: file.y + 4, down: true, pressed: true))
  frame(FrameInput(pointerX: file.x + 4, pointerY: file.y + 4, released: true))
  let fileMenu = UI.key("m0", in: bar)
  let save = try #require(u.rect("file.save", in: fileMenu))
  // The drop-down's quads come after the box built after it.
  #expect(u.access.contains { $0.role == .menuItem && $0.label == "Save" })
  // Sliding to Edit opens it; back to File, then a click on Save.
  frame(FrameInput(pointerX: edit.x + 4, pointerY: edit.y + 4))
  frame(FrameInput(pointerX: edit.x + 4, pointerY: edit.y + 4))
  #expect(u.rect("edit.copy", in: UI.key("m1", in: bar)) != nil && u.rect("file.save", in: fileMenu) == nil)
  frame(FrameInput(pointerX: file.x + 4, pointerY: file.y + 4))
  frame(FrameInput(pointerX: file.x + 4, pointerY: file.y + 4))
  let (sx, sy) = (save.x + 8, save.y + save.height / 2)
  frame(FrameInput(pointerX: sx, pointerY: sy))
  #expect(u.hot == UI.key("file.save", in: fileMenu))  // over "below", the menu wins
  frame(FrameInput(pointerX: sx, pointerY: sy, down: true, pressed: true))
  frame(FrameInput(pointerX: sx, pointerY: sy, released: true))
  frame(FrameInput())
  #expect(saved == 1 && u.rect("file.save", in: fileMenu) == nil)
}

@Test func aRightClickRoutesFirst() throws {
  var u = try ui(500, 300)
  u.declare(Action("edit.copy", label: "Copy"))
  var routed: [ActionValue] = []
  func frame(_ input: FrameInput) {
    u.begin(input)
    let s = u.box("line", class: "text", text: "Driver.swift:212:9", flags: [.clickable, .text])
    if s.secondaryPressed { u.openContextMenu("ctx", subject: "Driver.swift:212:9") }
    u.contextMenu("ctx", route: "edit", items: ["edit.copy"])
    if let i = u.take("route.open") { routed = i.arguments }
    u.end()
  }
  frame(FrameInput())
  let line = try #require(u.rect("line", in: UI.key("#root")))
  frame(FrameInput(pointerX: line.x + 4, pointerY: line.y + 4))
  frame(FrameInput(pointerX: line.x + 4, pointerY: line.y + 4, secondaryPressed: true))
  frame(FrameInput(pointerX: line.x + 4, pointerY: line.y + 4))
  let items = u.access.filter { $0.role == .menuItem }.map { $0.label }
  #expect(items == ["Route → edit", "Copy"])
  let ctx = UI.key("ctx", in: UI.key("#root"))
  let route = try #require(u.rect("route.open", in: ctx))
  let (x, y) = (route.x + 6, route.y + route.height / 2)
  frame(FrameInput(pointerX: x, pointerY: y))
  frame(FrameInput(pointerX: x, pointerY: y, down: true, pressed: true))
  frame(FrameInput(pointerX: x, pointerY: y, released: true))
  frame(FrameInput())
  #expect(routed == [.string("Driver.swift:212:9")])
}

/// A window with Be's menu bar (File open), a held button beside two at
/// rest, a field, and a right-click's context menu, at scale 2
/// (TODHCHAI_UI_SAMPLE5 names a file to write it to).
@Test func theDecisionsDrawn() throws {
  let scale: Float = 2
  var u = UI(painter: Painter(theme: .neonTab, fonts: try storyboardFonts(), scale: scale,
                              cache: GlyphCache(coverageSize: 2048, fieldSize: 256)),
             width: 640, height: 300)
  for a in [Action("file.open", label: "Open…", key: KeyPress(.character(0x6F), control: true)),
            Action("file.save", label: "Save", key: KeyPress(.character(0x73), control: true)),
            Action("file.close", label: "Close", key: KeyPress(.character(0x77), control: true)),
            Action("edit.copy", label: "Copy", key: KeyPress(.character(0x63), control: true))] {
    u.declare(a)
  }
  var query = "Driver.swift"
  var pointer: (Float, Float) = (-1, -1)
  func frame(_ input: FrameInput) {
    u.begin(input)
    let content = Chrome.window(&u.painter, 10, 10, 420, 200, title: "Driver.swift · Editor", focused: true)
    u.open("win", width: .pixels(content.width), height: .pixels(content.height), axis: .vertical,
           at: (content.x, content.y))
    u.menuBar("menus", [MenuSpec("File", ["file.open", "file.save", "file.close"]), MenuSpec("Edit", ["edit.undo", "edit.redo", "edit.copy"])])
    u.open("row", width: .percent(1), height: .children(), axis: .horizontal)
    u.box("pad", width: .pixels(12), height: .pixels(60))
    u.button("ok", "Save", class: "button.primary")
    u.box("gap", width: .pixels(8), height: .pixels(0))
    u.button("cancel", "Don't Save")
    u.box("gap2", width: .pixels(8), height: .pixels(0))
    u.button("del", "Delete", class: "button.danger")
    u.close()
    u.open("frow", width: .percent(1), height: .children(), axis: .horizontal)
    u.box("pad", width: .pixels(12), height: .pixels(0))
    u.textField("q", text: &query, width: .pixels(220))
    u.close()
    u.close()
    let s = u.box("line", class: "text", text: "Driver.swift:212:9", flags: [.clickable, .text], at: (460, 40))
    if s.secondaryPressed { u.openContextMenu("ctx", subject: "Driver.swift:212:9") }
    u.contextMenu("ctx", route: "edit", items: ["edit.copy"])
    u.end()
  }
  frame(FrameInput())
  let root = UI.key("#root"), win = UI.key("win", in: root)
  let bar = UI.key("menus", in: win)
  let file = try #require(u.rect("t0", in: bar))
  func write(_ path: String) throws {
    var canvas = Canvas(width: Int(640 * scale), height: Int(300 * scale), color: 0x0A0A12)
    u.painter.render(into: &canvas)
    var ppm = Array("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
    for p in canvas.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
    try Data(ppm).write(to: URL(filePath: path))
  }
  let sample = ProcessInfo.processInfo.environment["TODHCHAI_UI_SAMPLE5"]
  // Save held down.
  let ok = try #require(u.rect("ok", in: UI.key("row", in: win)))
  frame(FrameInput(pointerX: ok.x + 6, pointerY: ok.y + 6))
  frame(FrameInput(pointerX: ok.x + 6, pointerY: ok.y + 6, down: true, pressed: true))
  if let sample { try write(sample) }
  frame(FrameInput(pointerX: 600, pointerY: 280, released: true))
  // File open, and the line right-clicked (a right-click leaves the open
  // menu be).
  frame(FrameInput(pointerX: file.x + 4, pointerY: file.y + 4))
  frame(FrameInput(pointerX: file.x + 4, pointerY: file.y + 4, down: true, pressed: true))
  frame(FrameInput(pointerX: file.x + 4, pointerY: file.y + 4, released: true))
  let line = try #require(u.rect("line", in: root))
  pointer = (line.x + 6, line.y + 6)
  frame(FrameInput(pointerX: pointer.0, pointerY: pointer.1))
  frame(FrameInput(pointerX: pointer.0, pointerY: pointer.1, secondaryPressed: true))
  frame(FrameInput(pointerX: pointer.0, pointerY: pointer.1))
  #expect(u.access.filter { $0.role == .menuItem }.count == 5)
  if let sample { try write(sample + "-menus.ppm") }
}

/// Be's cascading menus (M6l): a submenu opens beside its item when the
/// pointer rests on it, is built only while open, closes when the pointer
/// rests on another item, and its items are chosen as any; an item with a
/// submenu may be an action too.
@Test func submenusCascade() throws {
  var u = try ui(500, 300)
  u.declare(Action("go", label: "Go", arguments: [ActionArgument("to", .string)]))
  u.declare(Action("new.folder", label: "New folder"))
  u.declare(Action("trash", label: "Trash"))
  var built = 0
  var went: [ActionValue] = []
  var trashed = false
  func frame(_ input: FrameInput) {
    u.begin(input)
    let entries = [
      MenuItem("new.folder"),
      MenuItem("go", label: "Desktop", arguments: [.string("")], holds: ["go"]) {
        built += 1
        return [MenuItem("go", label: "home", arguments: [.string("home")]),
                MenuItem("go", label: "music", arguments: [.string("music")])]
      },
      MenuItem("trash", dimmed: true),
    ]
    _ = u.menu("m", shown: true, at: (10, 10), entries: entries, hasDefault: false)
    if let i = u.take("go") { went = i.arguments }
    if u.take("trash") != nil { trashed = true }
    u.end()
  }
  frame(FrameInput())
  frame(FrameInput())
  #expect(built == 0 && u.unreachable().isEmpty)
  let menu = UI.key("m", in: UI.key("#root"))
  let desktop = try #require(u.rect("go", in: menu))
  #expect(u.access.contains { $0.label == "Desktop" })
  // The pointer moved once, then the frames it asks for, as a platform
  // builds them: how many there were.
  func rest(_ x: Float, _ y: Float) -> Int {
    frame(FrameInput(pointerX: x, pointerY: y))
    var n = 1
    while u.pending && n < 5 {
      frame(FrameInput(pointerX: x, pointerY: y))
      n += 1
    }
    return n
  }
  // Resting on Desktop opens its submenu beside it, in the frames it asks
  // for: the pointer needn't move again.
  #expect(rest(desktop.x + 8, desktop.y + 4) <= 3 && !u.pending)
  #expect(built > 0 && u.access.contains { $0.label == "music" })
  let sub = UI.key("m.sub1", in: UI.key("#root"))
  let music = try #require(u.rect("go#1", in: sub))
  #expect(music.x >= desktop.x + desktop.width - 4)
  // Choosing music.
  let (x, y) = (music.x + 8, music.y + music.height / 2)
  frame(FrameInput(pointerX: x, pointerY: y))
  frame(FrameInput(pointerX: x, pointerY: y, down: true, pressed: true))
  frame(FrameInput(pointerX: x, pointerY: y, released: true))
  frame(FrameInput())
  #expect(went == [.string("music")])
  // Opened again, then resting on New folder closes the submenu.
  frame(FrameInput(pointerX: desktop.x + 8, pointerY: desktop.y + 4))
  frame(FrameInput(pointerX: desktop.x + 8, pointerY: desktop.y + 4))
  #expect(u.access.contains { $0.label == "music" })
  let folder = try #require(u.rect("new.folder", in: menu))
  #expect(rest(folder.x + 8, folder.y + 4) <= 3 && !u.pending)
  #expect(!u.access.contains { $0.label == "music" })
  // Resting on a dimmed item closes it too, and a click there chooses
  // nothing.
  _ = rest(desktop.x + 8, desktop.y + 4)
  #expect(u.access.contains { $0.label == "music" })
  let trash = try #require(u.access.first { $0.label == "Trash" })
  let (tx, ty) = (trash.x + 8, trash.y + trash.height / 2)
  #expect(rest(tx, ty) <= 3 && !u.pending)
  #expect(!u.access.contains { $0.label == "music" })
  frame(FrameInput(pointerX: tx, pointerY: ty, down: true, pressed: true))
  frame(FrameInput(pointerX: tx, pointerY: ty, released: true))
  frame(FrameInput())
  #expect(!trashed)
  // Desktop itself is an action: a click on it goes there.
  frame(FrameInput(pointerX: desktop.x + 8, pointerY: desktop.y + 4))
  frame(FrameInput(pointerX: desktop.x + 8, pointerY: desktop.y + 4, down: true, pressed: true))
  frame(FrameInput(pointerX: desktop.x + 8, pointerY: desktop.y + 4, released: true))
  #expect(went == [.string("")])
}
