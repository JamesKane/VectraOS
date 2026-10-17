// SPDX-License-Identifier: BSD-3-Clause

// kbdfs's keys and console (D83), as kbdfs(8) describes them: kbd's `k`,
// `K` and `c` messages, cons's cooked lines and raw runes, kbmap's text,
// and kbdin's messages.

import Kbdfs
import Testing

func press(_ k: Keyboard, _ usages: UInt8...) { for u in usages { k.kbin([u, 1, u, 0]) } }

func messages(_ bytes: [UInt8]) -> [String] {
  bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
}

let shiftRune = String(Character(Unicode.Scalar(KeyRune.shift)!))

@Test func kbdSaysWhatIsHeldAndWhatWasTyped() {
  let k = Keyboard()
  k.kbdOpen = 1
  press(k, 0x04)  // a
  #expect(messages(k.takeKbd(256) ?? []) == ["ka", "ca", "K"])
  // Shift held: the button unshifted, the rune shifted.
  k.kbin([0xE1, 1, 0x04, 1, 0x04, 0, 0xE1, 0])
  #expect(messages(k.takeKbd(256) ?? []) == ["k" + shiftRune, "k" + shiftRune + "a", "cA", "K" + shiftRune, "K"])
  #expect(k.takeKbd(256) == nil)
  // A read too small for a message gets as many whole ones as fit.
  press(k, 0x05)
  #expect(messages(k.takeKbd(6) ?? []) == ["kb", "cb"])
  #expect(messages(k.takeKbd(6) ?? []) == ["K"])
}

@Test func consCooksLines() {
  var echoed: [UInt8] = []
  let k = Keyboard(echo: { echoed += $0 })
  press(k, 0x0B, 0x0C)  // h i
  #expect(k.takeCons(64) == nil)  // no line yet
  press(k, 0x28)  // Enter
  #expect(k.takeCons(64) == Array("hi\n".utf8))
  #expect(echoed == Array("hi\n".utf8))
  // ^H erases a character; reads take a line in parts.
  press(k, 0x0B, 0x1B, 0x2A, 0x0C, 0x28)  // h x Backspace i Enter
  #expect(k.takeCons(2) == Array("hi".utf8) && k.takeCons(64) == Array("\n".utf8))
  // ^U the line, ^W a word (Ctl held), ^D the input's end.
  k.kbin([0x04, 1, 0x04, 0, 0x2C, 1, 0x2C, 0, 0x05, 1, 0x05, 0])  // a, space, b
  k.kbin([0xE0, 1, 0x1A, 1, 0x1A, 0, 0xE0, 0])  // ^W
  press(k, 0x06, 0x28)  // c Enter
  #expect(k.takeCons(64) == Array("ac\n".utf8))  // ^W takes the space before the word too, as lineproc does
  k.kbin([0xE0, 1, 0x07, 1, 0x07, 0, 0xE0, 0])  // ^D on an empty line
  #expect(k.takeCons(64) == [])
  #expect(k.takeCons(64) == nil)
}

@Test func rawConsAndKbdTakeRunesAsTheyCome() {
  let k = Keyboard()
  #expect(k.control("rawon") && k.raw)
  press(k, 0x04, 0x2A)
  #expect(k.takeCons(64) == [0x61, 0x08])
  k.consctlOpen = 1
  k.consctlClosed()
  #expect(!k.raw)  // the last consctl closed: cooked again
  #expect(!k.control("bogus"))
  // While kbd is open, cons hears nothing.
  k.kbdOpen = 1
  press(k, 0x04, 0x28)
  #expect(k.takeCons(64) == nil)
}

@Test func theKeypadMovesWithoutNumLock() {
  let k = Keyboard()
  k.kbdOpen = 1
  press(k, 0x60)  // KP8
  #expect(messages(k.takeKbd(256) ?? []).last == "K")
  #expect(k.takeKbd(256) == nil)
  press(k, 0x53, 0x60)  // NumLock, KP8
  #expect(messages(k.takeKbd(256) ?? []).contains("c8"))
}

@Test func kbmapReadsAndWritesByUsage() {
  var m = Keymap.us
  let lines = m.text.split(separator: "\n")
  #expect(lines.count == 7 * 256)
  #expect(lines[4] == "       none           4          97")  // a
  #expect(lines[256 + 4] == "      shift           4          65")  // A
  let applied = m.apply("# a comment\n\nnone 4 'b\nshift 0x04 66\nctl 4 ^B\n")
  #expect(applied)
  #expect(m[.none, 4] == 0x62 && m[.shift, 4] == 0x42 && m[.ctl, 4] == 0x02)
  let bad = [m.apply("none 4\n"), m.apply("nowhere 4 5\n"), m.apply("none 300 5\n")]
  #expect(bad == [false, false, false])
  let byNumber = m.apply("3 4 0x7f\n")  // a layer by number
  #expect(byNumber && m[.ctl, 4] == 0x7F)
}

@Test func kbdinTypesForSomeoneElse() {
  let k = Keyboard()
  k.kbdin(Array("rh\0Rh\0ci\0".utf8) + Array("c\n\0".utf8))
  #expect(k.takeCons(64) == Array("hi\n".utf8))
  k.kbdOpen = 1
  k.kbdin(Array("kx\0".utf8))
  #expect(messages(k.takeKbd(64) ?? []) == ["kx"])
}
