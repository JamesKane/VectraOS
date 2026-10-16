// SPDX-License-Identifier: BSD-3-Clause

// The pty's line discipline alone (todhchai's PtyTests, its first two
// tests as they were there): a line typed, edited, echoed, sent with its
// newline; erase over UTF-8; kill and word erase; ^C and ^D; raw mode;
// output's newlines. The service itself, on rings, is launch-test's
// (boot-launch): a pty typed to and shown, and rc on one.

import Pty
import Testing

@Test func cookedModeEditsALine() {
  var d = LineDiscipline()
  var r = d.input(Array("lz".utf8))
  #expect(r.toProgram.isEmpty && r.echo == Array("lz".utf8))
  r = d.input([0x7F] + Array("s é".utf8))  // erase z; an é is two bytes
  #expect(r.echo == [0x08, 0x20, 0x08] + Array("s é".utf8))
  r = d.input([0x7F, 0x0D])  // erase é whole, then Enter
  #expect(r.toProgram == Array("ls \n".utf8) && r.echo.suffix(2) == [0x0D, 0x0A])
  // Kill and word erase.
  r = d.input(Array("cat file".utf8) + [0x17] + Array("doc".utf8) + [0x0A])
  #expect(r.toProgram == Array("cat doc\n".utf8))
  r = d.input(Array("oops".utf8) + [0x15] + Array("ok\r".utf8))
  #expect(r.toProgram == Array("ok\n".utf8))
}

@Test func controlCharactersAndRawMode() {
  var d = LineDiscipline()
  var r = d.input(Array("half".utf8) + [0x03])
  #expect(r.events == [.interrupt] && r.toProgram.isEmpty && r.echo.suffix(4) == Array("^C\r\n".utf8))
  r = d.input([0x04])
  #expect(r.events == [.endOfInput])
  r = d.input(Array("no newline".utf8) + [0x04])
  #expect(r.toProgram == Array("no newline".utf8) && r.events.isEmpty)
  // Raw: what's typed passes at once, unechoed; a line being edited goes too.
  _ = d.input(Array("ab".utf8))
  #expect(d.setMode(.raw) == Array("ab".utf8))
  r = d.input([0x03, 0x7F, 0x1B, 0x5B, 0x41])
  #expect(r.toProgram == [0x03, 0x7F, 0x1B, 0x5B, 0x41] && r.echo.isEmpty && r.events.isEmpty)
  // Output: NL as CR NL, unless output processing is off.
  #expect(LineDiscipline().output(Array("a\nb\n".utf8)) == Array("a\r\nb\r\n".utf8))
  #expect(d.output(Array("a\n".utf8)) == Array("a\n".utf8))
}
