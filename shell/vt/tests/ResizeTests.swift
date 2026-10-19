// SPDX-License-Identifier: BSD-3-Clause

// A resize while the alternate screen shows keeps the main screen's
// lines: blank ones below its cursor go first, as the screen's own do.

import Testing
import TerminalCore

@Test func aResizeUnderTheAlternateScreenKeepsTheMainOnesLines() {
  var s = Screen(columns: 40, rows: 20)
  s.feed(Array("one\r\ntwo\r\nthree\r\n\u{1B}[?1049halt".utf8))
  s.resize(columns: 30, rows: 10)
  s.feed(Array("\u{1B}[?1049l".utf8))
  #expect((0..<3).map { s.text(row: $0) } == ["one", "two", "three"])
  #expect(s.cursorY == 3)
  // Too few rows even so: the top lines go to scrollback.
  var t = Screen(columns: 40, rows: 6)
  t.feed(Array("1\r\n2\r\n3\r\n4\r\n5\u{1B}[?1049h".utf8))
  t.resize(columns: 40, rows: 3)
  t.feed(Array("\u{1B}[?1049l".utf8))
  #expect((0..<3).map { t.text(row: $0) } == ["3", "4", "5"])
  #expect(t.scrollback.count == 2)
}
