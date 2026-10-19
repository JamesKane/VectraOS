// SPDX-License-Identifier: BSD-3-Clause

// The trusted prompt (D111): a question is an ndb entry, refused if it
// isn't one; questions queue, the oldest on screen; a click or a key
// lands only once it has been up half a second; a key's fields are typed
// into it, a secret drawn as bullets; and it is drawn over every window
// with the screen dimmed, in its own colours.

import Kbdfs
import Light
import Radharc
import Testing

func question(_ text: String, id: UInt64 = 1, asker: String = "factotum") throws -> PromptQuestion {
  try PromptQuestion(parsing: Array(text.utf8), id: id, asker: asker)
}

func refusal(_ text: String) -> String? {
  do throws(PromptRefusal) {
    _ = try PromptQuestion(parsing: Array(text.utf8), id: 1, asker: "factotum")
    return nil
  } catch {
    return error.reason
  }
}

@Test func aQuestionIsAnNdbEntry() throws {
  let q = try question("ask=confirm app=mail proto=pass server=mail user=jk\n")
  #expect(q.kind == .confirm && q.app == "mail" && q.asker == "factotum")
  #expect(q.shown == "proto=pass server=mail user=jk" && q.answers == [.deny, .once] && q.fields.isEmpty)
  #expect(q.reply(.once) == Array("once\n".utf8) && q.reply(.deny) == Array("deny\n".utf8))
  // Its own name if it names no app; the answers it offers, in order.
  let all = try question("ask=confirm answers=always,once,session verb=delete", asker: "ghost")
  #expect(all.app == "ghost" && all.answers == [.deny, .always, .session, .once])
  // A key's: its fields, a secret's marked; what was typed comes back.
  var key = try question("ask=key app=mail proto=pass server=mail user? !password?")
  #expect(key.kind == .key && key.shown == "proto=pass server=mail")
  #expect(key.fields == [PromptField(name: "user", secret: false), PromptField(name: "password", secret: true)])
  key.fields[0].value = Array("j k".unicodeScalars.map { $0.value })
  key.fields[1].value = Array("hi".unicodeScalars.map { $0.value })
  #expect(key.reply(.once) == Array("once user=\"j k\" !password=hi\n".utf8))
  #expect(key.reply(.deny) == Array("deny\n".utf8))

  #expect(refusal("app=mail proto=pass") == "no ask=")
  #expect(refusal("ask=maybe") == "ask= is confirm or key")
  #expect(refusal("ask=confirm ask=key user?") == "one ask= a question")
  #expect(refusal("ask=confirm !password=secret") == "a question holds no secret")
  #expect(refusal("ask=key proto=pass") == "a key's question has a field to type")
  #expect(refusal("ask=confirm user?") == "a confirm has nothing to type")
  #expect(refusal("ask=confirm answers=never") == "answers= are once, session and always")
  #expect(refusal("ask=confirm answers=deny") == "answers= offers none")
  #expect(refusal("ask=confirm note=" + String(repeating: "x", count: 300)) == "longer than 256 bytes")
}

@Test func questionsQueueTheOldestOnScreen() throws {
  let s = Scene(width: 800, height: 600)
  let a = try question("ask=confirm thing=a", id: s.newPromptID())
  let b = try question("ask=confirm thing=b", id: s.newPromptID())
  s.ask(a, now: 0)
  s.ask(b, now: 0)
  #expect(s.prompts.showing?.id == a.id && s.prompts.queue.count == 2)
  // Withdrawing one waiting changes nothing on screen; the one on screen
  // goes, and the next shows.
  _ = s.takeDamage()
  s.withdraw(b.id, now: 1)
  #expect(s.prompts.showing?.id == a.id && s.takeDamage().isEmpty)
  s.ask(b, now: 2)
  s.withdraw(a.id, now: 3)
  #expect(s.prompts.showing?.id == b.id && s.takeDamage() == Rect(x: 0, y: 0, width: 800, height: 600))
  s.withdraw(b.id, now: 4)
  #expect(s.prompts.showing == nil && s.promptLayout == nil)
}

@Test func aClickLandsOnlyOnceItHasBeenUpHalfASecond() throws {
  let s = Scene(width: 800, height: 600)
  let q = try question("ask=confirm answers=once,always thing=x", id: s.newPromptID())
  s.ask(q, now: 1_000)
  let l = try #require(s.promptLayout)
  #expect(l.buttons.count == 3 && l.buttons.allSatisfy { l.panel.intersection($0) == $0 })
  let once = l.buttons[2], deny = l.buttons[0]
  _ = s.moveTo(once.x + 4, once.y + 4)
  // Too soon: ignored, and its release answers nothing.
  #expect(s.promptButton(down: true, now: 1_000 + Prompts.arming - 1) == .none && s.prompts.ignored == 1)
  #expect(s.promptButton(down: false, now: 1_000 + Prompts.arming) == .none && s.prompts.showing != nil)
  // Pressed on Once and let go off it: nothing.
  let armed: Int64 = 1_000 + Prompts.arming
  #expect(s.promptButton(down: true, now: armed) == .redraw && s.prompts.pressed == 2)
  _ = s.moveTo(deny.x + 4, deny.y + 4)
  #expect(s.promptButton(down: false, now: armed) == .redraw && s.prompts.showing != nil)
  // On Once, down and up: once.
  _ = s.moveTo(once.x + 4, once.y + 4)
  _ = s.promptButton(down: true, now: armed)
  #expect(s.promptButton(down: false, now: armed) == .answered(id: q.id, reply: Array("once\n".utf8)))
  #expect(s.prompts.showing == nil)
}

@Test func escapeDeniesAndAKeyIsTyped() throws {
  let s = Scene(width: 800, height: 600)
  let c = try question("ask=confirm thing=x", id: s.newPromptID())
  s.ask(c, now: 0)
  // Escape too soon is ignored; return answers no confirm, nor does text.
  #expect(s.promptTyped(0x1B, now: Prompts.arming - 1) == .none && s.prompts.ignored == 1)
  #expect(s.promptTyped(0x0A, now: Prompts.arming) == .none && s.promptTyped(0x61, now: Prompts.arming) == .none)
  #expect(s.promptTyped(0x1B, now: Prompts.arming) == .answered(id: c.id, reply: Array("deny\n".utf8)))

  let k = try question("ask=key proto=pass server=news user? !password?", id: s.newPromptID())
  s.ask(k, now: 0)
  let t = Prompts.arming
  for r in "jx".unicodeScalars { #expect(s.promptTyped(r.value, now: 0) == .redraw) }  // text needs no arming
  _ = s.promptTyped(0x08, now: t)  // backspace
  _ = s.promptTyped(0x6B, now: t)
  _ = s.promptTyped(0x09, now: t)  // tab: the password
  #expect(s.prompts.field == 1)
  for r in "Hi!".unicodeScalars { _ = s.promptTyped(r.value, now: t) }
  // A secret is drawn as bullets: none of what was typed is on screen.
  var list = DrawList()
  s.displayList(Rect(x: 0, y: 0, width: 800, height: 600), into: &list)
  let glyphs = list.quads.filter { $0.kind == Quad.glyph }.map { $0.texture }
  #expect(glyphs.filter { $0 == 0x2022 }.count == 3 && !glyphs.contains(0x48) && glyphs.contains(0x6A))
  #expect(s.promptTyped(0x0D, now: t) == .answered(id: k.id, reply: Array("once user=jk !password=Hi!\n".utf8)))
}

@Test func itIsDrawnOverEveryWindowTheScreenDimmed() throws {
  let s = Scene(width: 640, height: 480)
  let (w, _) = s.open(title: "w", width: 600, height: 440)
  s.present(w.id, seq: 1, size: (600, 440), layers: [Layer(image: 0, color: 0x33_6699, rect: Rect(x: 0, y: 0, width: 600, height: 440))],
            damage: nil)
  var before = [UInt32](repeating: 0, count: 640 * 480)
  before.withUnsafeMutableBufferPointer { t in s.compose(s.takeDamage(), into: t.baseAddress!, stride: 640) { _, _ in 0 } }
  s.ask(try question("ask=confirm thing=x", id: s.newPromptID()), now: 0)
  let l = try #require(s.promptLayout)
  var after = before
  after.withUnsafeMutableBufferPointer { t in s.compose(s.takeDamage(), into: t.baseAddress!, stride: 640) { _, _ in 0 } }
  func dim(_ c: UInt32) -> UInt32 {
    func d(_ v: UInt32) -> UInt32 { Light.encode(Light.decode(v) / 4) }
    return d(c >> 16 & 0xFF) << 16 | d(c >> 8 & 0xFF) << 8 | d(c & 0xFF)
  }
  // Outside the panel, the screen dimmed: the window's colour and the desk's.
  let inWindow = (w.content.x + 2) + (w.content.y + 2) * 640
  #expect(before[inWindow] == 0x33_6699 && after[inWindow] == dim(0x33_6699))
  #expect(after[639 + 479 * 640] == dim(before[639 + 479 * 640]))
  // The panel: its black edge and strip, a gunmetal seal, its face; no
  // theme's colour.
  #expect(after[l.panel.x + l.panel.y * 640] == 0 && after[l.panel.x + 300 + (l.panel.y + 12) * 640] == 0)
  #expect(after[l.seal.x + l.seal.y * 640] == 0x54_5A60)
  let face = after[l.panel.x + 40 + (l.panel.maxY - 30) * 640]
  #expect(face == 0xC8_CCD0)
  // Gone, the screen is as it was.
  s.withdraw(s.prompts.showing!.id, now: 1)
  after.withUnsafeMutableBufferPointer { t in s.compose(s.takeDamage(), into: t.baseAddress!, stride: 640) { _, _ in 0 } }
  #expect(after == before)
}

@Test func whileItIsUpNoWindowMoves() throws {
  let s = Scene(width: 800, height: 600)
  let (w, _) = s.open(title: "w", width: 200, height: 100)
  let at = w.content
  _ = s.moveTo(w.tab.x + 30, w.tab.y + 5)
  _ = s.button(down: true)
  s.ask(try question("ask=confirm thing=x", id: s.newPromptID()), now: 0)
  _ = s.moveBy(100, 100)
  #expect(w.content == at)
}

@Test func whatWasTypedComesFromKbdsCMessages() {
  var bytes: [UInt8] = []
  for m in ["kA", "cA", "K", "c\u{1B}", "c\u{E9}"] { bytes += Array(m.utf8) + [0] }
  #expect(KeyboardDecoder.typed(bytes) == [0x41, 0x1B, 0xE9])
}
