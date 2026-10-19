// SPDX-License-Identifier: BSD-3-Clause

// rio (rio(1), rio(4)): a window's text with its output point, cooked,
// held and raw; its files' reads and writes; wctl's verbs as 9front's rio
// parses them; the window as a Kit app, typed into and plumbing from wdir.

import GlyphAtlas
import Kit
import Rio
import Testing

func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map { $0.value } }
func line(_ s: String) -> Sent { .input(Array(s.utf8)) }

extension WindowText {
  var all: String { document.text }
  mutating func show(_ s: String) { write(RioTests.scalars(s)) }
}

@Test func outputGoesBeforeWhatIsTyped() {
  var t = WindowText()
  t.show("% ")
  #expect(t.type("echo hi").isEmpty)
  #expect(t.key(KeyPress(.enter)) == [line("echo hi\n")])
  t.show("hi\n% ")
  #expect(t.all == "% echo hi\nhi\n% ")
  // Typed before output came: the output goes in before it.
  _ = t.type("ls")
  t.show("late\n")
  #expect(t.all == "% echo hi\nhi\n% late\nls")
  #expect(t.typed == scalars("ls"))
  #expect(t.document.caret == t.end)
}

@Test func typingBeforeTheOutputPointTypesAtTheEnd() {
  var t = WindowText()
  t.show("hello\n% ")
  _ = t.type("ab")
  t.document.caret = TextPosition(line: 0, column: 2)
  t.document.anchor = TextPosition(line: 0, column: 0)
  _ = t.type("c")
  #expect(t.all == "hello\n% abc")
  // A selection after the output point is replaced.
  t.document.anchor = TextPosition(line: 1, column: 2)
  t.document.caret = TextPosition(line: 1, column: 3)
  _ = t.type("X")
  #expect(t.all == "hello\n% Xbc")
}

@Test func erasingStopsAtTheOutputPoint() {
  var t = WindowText()
  t.show("% ")
  _ = t.key(KeyPress(.backspace))
  #expect(t.all == "% ")
  _ = t.type("cat foo.c")
  _ = t.key(KeyPress(.character(0x77), control: true))  // ^W
  #expect(t.all == "% cat foo.")
  _ = t.key(KeyPress(.character(0x77), control: true))
  #expect(t.all == "% cat ")
  _ = t.key(KeyPress(.backspace))
  #expect(t.all == "% cat")
  _ = t.key(KeyPress(.character(0x75), control: true))  // ^U
  #expect(t.all == "% ")
  _ = t.key(KeyPress(.character(0x75), control: true))
  #expect(t.all == "% ")
}

@Test func controlDSendsWhatIsTypedOrTheEnd() {
  var t = WindowText()
  _ = t.type("ab")
  #expect(t.key(KeyPress(.character(0x64), control: true)) == [line("ab")])
  #expect(t.typed.isEmpty)
  #expect(t.key(KeyPress(.character(0x64), control: true)) == [.end])
}

@Test func deleteInterruptsAndDropsWhatWasTyped() {
  var t = WindowText()
  t.show("% ")
  _ = t.type("sleep 100")
  #expect(t.key(KeyPress(.delete)) == [.interrupt])
  #expect(t.typed.isEmpty)
  t.show("\n% ")
  _ = t.type("date")
  #expect(t.key(KeyPress(.enter)) == [line("date\n")])
  #expect(t.all == "% sleep 100\n% date\n")
}

@Test func holdModeKeepsLinesUntilReleased() {
  var t = WindowText()
  _ = t.key(KeyPress(.escape))
  #expect(t.holding)
  _ = t.type("a")
  #expect(t.key(KeyPress(.enter)).isEmpty)
  _ = t.type("b")
  #expect(t.key(KeyPress(.enter)).isEmpty)
  _ = t.type("c")
  #expect(t.key(KeyPress(.escape)) == [line("a\n"), line("b\n")])
  #expect(t.typed == scalars("c"))
  // consctl's holdoff releases it too.
  t.holding = true
  _ = t.key(KeyPress(.enter))
  #expect(t.release() == [line("c\n")])
}

@Test func rawModeSendsEachKeyUnshown() {
  var t = WindowText()
  t.show("> ")
  _ = t.type("ab")
  #expect(t.rawOn() == [line("ab")])
  #expect(t.type("x") == [line("x")])
  #expect(t.key(KeyPress(.enter)) == [line("\n")])
  #expect(t.key(KeyPress(.backspace)) == [.input([8])])
  #expect(t.key(KeyPress(.character(0x63), control: true)) == [.input([3])])
  #expect(t.key(KeyPress(.delete)) == [.input([0x7F])])
  #expect(t.all == "> ab")
}

@Test func theOldestLinesGo() {
  var t = WindowText()
  t.limit = 10
  for i in 0..<30 { t.show("line \(i)\n") }
  #expect(t.document.lines.count <= 11)
  #expect(t.all.hasSuffix("line 29\n"))
  _ = t.type("x")
  #expect(t.typed == scalars("x"))
}

@Test func theSubjectIsTheSelectionOrTheWordAtTheCaret() {
  var t = WindowText()
  t.show("error at (main.swift:42:7): oops\n")
  t.document.caret = TextPosition(line: 0, column: 12)
  t.document.anchor = t.document.caret
  #expect(t.subject == "main.swift:42:7")
  t.document.anchor = TextPosition(line: 0, column: 0)
  t.document.caret = TextPosition(line: 0, column: 5)
  #expect(t.subject == "error")
}

// MARK: Files

@Test func consReadsTakeWhatWasSentInTurn() {
  let f = WindowFiles(id: 1, label: "rc", wdir: "/")
  #expect(f.readCons(100) == nil)
  f.send([line("hello\n"), .end, line("x")])
  #expect(f.readCons(3) == Array("hel".utf8))
  #expect(f.readCons(100) == Array("lo\n".utf8))
  #expect(f.readCons(100) == [])
  #expect(f.readCons(100) == Array("x".utf8))
  #expect(f.readCons(100) == nil)
  f.delete()
  #expect(f.readCons(100) == [])
}

@Test func writesAreShownAWholeCharacterAtATime() {
  let f = WindowFiles(id: 1, label: "rc", wdir: "/")
  let e = Array("é€".utf8)
  f.write(Array(e[0..<3]))
  #expect(f.take().output == scalars("é"))
  f.write(Array(e[3...]))
  #expect(f.take().output == scalars("€"))
}

@Test func kbdTakesTheKeysFromCons() {
  let f = WindowFiles(id: 1, label: "rc", wdir: "/")
  f.key("cx")
  f.kbdOpened()
  #expect(f.kbdOpen)
  #expect(f.readKbd(100) == nil)
  f.send([line("a\n")])
  #expect(f.readCons(100) == nil)
  f.key("ka")
  f.key("ca")
  #expect(f.readKbd(4) == Array("ka".utf8) + [0])
  #expect(f.readKbd(100) == Array("ca".utf8) + [0])
  f.kbdClosed()
  #expect(f.readCons(100) == Array("a\n".utf8))
}

@Test func consctlsModesEndWithItsLastClose() {
  let f = WindowFiles(id: 1, label: "rc", wdir: "/")
  f.consctlOpened()
  #expect(f.control("holdon"))
  #expect(f.take().modes! == (false, true))
  #expect(f.control("rawon"))
  #expect(f.take().modes! == (true, false))
  #expect(!f.control("bogus"))
  f.consctlClosed()
  #expect(f.take().modes! == (false, false))
}

@Test func wdirIsCleaned() {
  let f = WindowFiles(id: 1, label: "rc", wdir: "/usr")
  f.setWdir("lib\n")
  #expect(f.wdir == "/usr/lib")
  f.setWdir("../../bin/./x/..")
  #expect(f.wdir == "/bin")
  f.setWdir("/data//notes/")
  #expect(f.wdir == "/data/notes")
  #expect(f.winid == "          1 ")
}

@Test func wctlReadsWaitForAChange() {
  let f = WindowFiles(id: 1, label: "rc", wdir: "/")
  let screen = WctlRect(minX: 0, minY: 0, maxX: 1280, maxY: 800)
  f.place(WctlRect(minX: 32, minY: 32, maxX: 632, maxY: 432), screen: screen, current: true, visible: true)
  let read = f.wctlReader()
  #expect(read(100).map { String(decoding: $0, as: UTF8.self) }
    == "         32          32         632         432     current     visible ")
  #expect(read(100) == nil)
  f.place(WctlRect(minX: 32, minY: 32, maxX: 632, maxY: 432), screen: screen, current: true, visible: true)
  #expect(read(100) == nil)
  f.place(WctlRect(minX: 32, minY: 32, maxX: 632, maxY: 432), screen: screen, current: false, visible: true)
  #expect(read(100).map { String(decoding: $0, as: UTF8.self).hasSuffix("  notcurrent     visible ") } == true)
  // A verb for the window's next frame, or why not.
  #expect(f.command("move -minx 100") == nil)
  #expect(f.takeCommands().map { $0.rect } == [WctlRect(minX: 100, minY: 32, maxX: 700, maxY: 432)])
  #expect(f.command("bogus") == "unrecognized wctl command")
}

// MARK: wctl

let screen = WctlRect(minX: 0, minY: 0, maxX: 1280, maxY: 800)
let here = WctlRect(minX: 100, minY: 100, maxX: 500, maxY: 400)

func parse(_ s: String, _ r: WctlRect? = here) throws(WctlError) -> WctlCommand {
  try Wctl.parse(s, rect: r, screen: screen)
}

@Test func wctlParsesRiosVerbs() throws {
  #expect(try parse("move -minx 50 -miny 60").rect == WctlRect(minX: 50, minY: 60, maxX: 450, maxY: 360))
  #expect(try parse("move -minx +10 -miny -20").rect == WctlRect(minX: 110, minY: 80, maxX: 510, maxY: 380))
  #expect(try parse("resize -dx 300 -dy 200").rect == WctlRect(minX: 100, minY: 100, maxX: 400, maxY: 300))
  #expect(try parse("resize -r 10 20 [310 220]").rect == WctlRect(minX: 10, minY: 20, maxX: 310, maxY: 220))
  // Kept on the screen.
  #expect(try parse("move -minx 1200").rect == WctlRect(minX: 880, minY: 100, maxX: 1280, maxY: 400))
  #expect(try parse("current").verb == .current)
  #expect(try parse("hide").verb == .hide)
  #expect(try parse("top -id 3").id == 3)
  let n = try parse("new -cd /lib -dx 300 -dy 200 echo hi", nil)
  #expect(n.verb == .new && n.command == "echo hi" && n.directory == "/lib")
  #expect(n.rect == WctlRect(minX: 32, minY: 32, maxX: 332, maxY: 232))
  #expect(try parse("new -hide", nil).hidden)
  #expect(try parse("new", nil).command == "")
}

@Test func wctlRefusesWhatRioRefuses() {
  func error(_ s: String, _ r: WctlRect? = here) -> String? {
    do throws(WctlError) {
      _ = try parse(s, r)
      return nil
    } catch { return error.message }
  }
  #expect(error("bogus") == "unrecognized wctl command")
  #expect(error("move -minx") == "missing or bad wctl parameter")
  #expect(error("top now") == "extraneous text in wctl message")
  #expect(error("resize -dx 20") == "bad rectangle in wctl request")
  #expect(error("hide", nil) == "command needs to be run within a window")
  #expect(error("bottom")?.hasPrefix("bottom:") == true)
}

@Test func namesAreCleanedAsPlan9s() {
  #expect(cleanName("/a/b/../c/./d//") == "/a/c/d")
  #expect(cleanName("/..") == "/")
  #expect(cleanName("a/..") == ".")
  #expect(cleanName("../x") == "../x")
}

// MARK: The window

@MainActor @Test func theWindowShowsOutputAndSendsWhatIsTyped() {
  let files = WindowFiles(id: 1, label: "rc", wdir: "/lib")
  let w = RioWindow(files: files)
  var changes = 0
  w.changed = { changes += 1 }
  var interrupts = 0
  w.interrupt = { interrupts += 1 }
  let r = Runner(app: w, painter: Painter(theme: .base, fonts: Fonts(), cache: GlyphCache(coverageSize: 64, fieldSize: 64)),
                 width: 400, height: 300)
  files.write(Array("% ".utf8))
  r.frame(FrameInput())
  #expect(files.text == Array("% ".utf8))
  #expect(r.ui.title == "rc")
  r.frame(FrameInput(text: "echo hi"))
  r.frame(FrameInput(keys: [KeyPress(.enter)]))
  #expect(changes == 2)
  #expect(files.readCons(100) == Array("echo hi\n".utf8))
  files.write(Array("hi\n% ".utf8))
  r.frame(FrameInput())
  #expect(String(decoding: files.text, as: UTF8.self) == "% echo hi\nhi\n% ")
  r.frame(FrameInput(keys: [KeyPress(.delete)]))
  #expect(interrupts == 1)
  // Its route goes from its directory.
  #expect(w.route(subject: "notes.md") == Route(wdir: "/lib", data: "notes.md"))
  // consctl's hold, shown in the theme's held text.
  #expect(files.control("holdon"))
  r.frame(FrameInput())
  #expect(w.text.holding)
  files.label = "test"
  r.frame(FrameInput())
  #expect(r.ui.title == "test")
}

@Test func aLentSurfaceSendsTheCaretKeysAsRunes() {
  var t = WindowText()
  _ = t.rawOn()
  #expect(t.key(KeyPress(.up)).isEmpty)
  t.keyRunes = true
  #expect(t.key(KeyPress(.up)) == [.input(utf8Rune(0xF00E))])
  #expect(t.key(KeyPress(.function(5))) == [.input(utf8Rune(0xF005))])
  #expect(t.key(KeyPress(.pageDown)) == [.input(utf8Rune(0xF013))])
}

func utf8Rune(_ r: UInt32) -> [UInt8] { Array(String(Character(Unicode.Scalar(r)!)).utf8) }

@Test func theSurfaceIsLentToOneViewAtATime() {
  let f = WindowFiles(id: 1, label: "rc", wdir: "/")
  #expect(f.lend(7))
  #expect(!f.lend(8))
  #expect(f.takeLent() == 7)
  #expect(f.takeLent() == nil)
  f.returned()
  #expect(f.lend(9))
}

/// A clipboard for the tests: one string.
final class Board: @unchecked Sendable {
  var text: String?
  var clipboard: Clipboard { Clipboard(read: { self.text }, write: { self.text = $0 }) }
}

@Test func cutTakesOnlyWhatWasTyped() {
  var t = WindowText()
  t.show("shown\n% ")
  _ = t.type("typed")
  t.document.anchor = TextPosition(line: 0, column: 0)
  t.document.caret = TextPosition(line: 0, column: 5)
  #expect(t.selected == "shown")
  t.cut()
  #expect(t.all == "shown\n% typed")
  t.document.anchor = TextPosition(line: 1, column: 2)
  t.document.caret = t.end
  t.cut()
  #expect(t.all == "shown\n% ")
  // Send types at the end, with a newline, so it is sent.
  #expect(t.send("ls") == [line("ls\n")])
}

@MainActor @Test func theMenuCutsPastesSnarfsAndSends() async throws {
  let files = WindowFiles(id: 1, label: "rc", wdir: "/")
  let w = RioWindow(files: files)
  let board = Board()
  w.clipboard = board.clipboard
  let r = Runner(app: w, painter: Painter(theme: .base, fonts: Fonts(), cache: GlyphCache(coverageSize: 64, fieldSize: 64)),
                 width: 400, height: 300)
  files.write(Array("% ".utf8))
  r.frame(FrameInput())
  r.frame(FrameInput(text: "echo hi"))
  w.text.document.anchor = TextPosition(line: 0, column: 2)
  w.text.document.caret = w.text.end
  func menu(_ name: String) async throws {
    try r.ui.perform(name)
    r.frame(FrameInput())
    await r.settle()
  }
  try await menu("rio.snarf")
  #expect(board.text == "echo hi")
  try await menu("rio.cut")
  #expect(w.text.typed.isEmpty)
  try await menu("rio.paste")
  #expect(w.text.typed == scalars("echo hi"))
  board.text = "date"
  w.text.document.anchor = w.text.document.caret
  try await menu("rio.send")
  #expect(files.readCons(100) == Array("echo hidate\n".utf8))
}

@Test func theClipboardIsReadOnlyAfterInputWhileFocused() {
  let f = WindowFiles(id: 1, label: "rc", wdir: "/")
  let screen = WctlRect(minX: 0, minY: 0, maxX: 1280, maxY: 800)
  let r = WctlRect(minX: 32, minY: 32, maxX: 632, maxY: 432)
  #expect(!f.mayRead)
  f.gave()
  #expect(f.mayRead)
  f.place(r, screen: screen, current: false, visible: true)
  #expect(!f.mayRead)
}
