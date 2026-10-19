// SPDX-License-Identifier: BSD-3-Clause

// Terminal's core (M6j part 2d). Against tmux (the host's: a VT emulator
// of xterm's behaviour, skipped without it): each stream, played into a
// tmux pane of the same size (as a program's output, through its pty: NL
// as CR NL) and into our screen, must leave the same text and cursor.
// Then what tmux can't show: SGR's colours, replies, the title,
// scrollback, resizing, and the keys' encodings.

import Glibc
import Testing
import TerminalCore

/// The pane's text and cursor after `bytes`, from tmux; nil without it.
func tmux(_ bytes: [UInt8], columns: Int, rows: Int, tag: Int) -> (lines: [String], x: Int, y: Int)? {
  guard access("/usr/bin/tmux", X_OK) == 0 else { return nil }
  // Each case its own server and directory: cases run at once.
  let dir = "/tmp/td-vt-\(getpid())-\(tag)"
  mkdir(dir, 0o755)
  let input = "\(dir)/in", socket = "td-vt-\(getpid())-\(tag)"
  guard let f = fopen(input, "wb") else { return nil }
  _ = bytes.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, f) }
  fclose(f)
  func sh(_ command: String) -> String {
    guard let p = popen(command, "r") else { return "" }
    var out = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = fread(&buffer, 1, buffer.count, p)
      if n <= 0 { break }
      out += buffer[0..<n]
    }
    pclose(p)
    return String(decoding: out, as: UTF8.self)
  }
  let t = "/usr/bin/tmux -L \(socket) -f /dev/null"
  _ = sh("\(t) new-session -d -x \(columns) -y \(rows) 'stty raw -echo onlcr opost; cat \(input); printf done > \(dir)/done; sleep 30' 2>&1")
  // Until cat has written it all.
  for _ in 0..<200 where access("\(dir)/done", F_OK) != 0 { usleep(10_000) }
  usleep(50_000)
  let text = sh("\(t) capture-pane -p -t 0")
  let cursor = sh("\(t) display-message -p -t 0 '#{cursor_x} #{cursor_y}'")
  _ = sh("\(t) kill-server 2>&1")
  _ = sh("rm -rf \(dir)")
  var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
    // capture-pane keeps tabs: to their 8-column stops.
    var s = ""
    for ch in line {
      if ch == "\t" {
        repeat { s.append(" ") } while s.count % 8 != 0
      } else {
        s.append(ch)
      }
    }
    while s.hasSuffix(" ") { s.removeLast() }
    return s
  }
  while lines.count > rows { lines.removeLast() }
  let xy = cursor.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
  return (lines, xy.first ?? -1, xy.count > 1 ? xy[1] : -1)
}

/// Ours, after `bytes` as a pty gives them (NL as CR NL).
func ours(_ bytes: [UInt8], columns: Int, rows: Int) -> (lines: [String], x: Int, y: Int, screen: Screen) {
  var s = Screen(columns: columns, rows: rows)
  var crlf: [UInt8] = []
  for b in bytes {
    if b == 0x0A { crlf.append(0x0D) }
    crlf.append(b)
  }
  s.feed(crlf)
  // With a wrap pending, tmux puts the cursor past the last column.
  return ((0..<rows).map { s.text(row: $0) }, s.cursorX + (s.wrapPending ? 1 : 0), s.cursorY, s)
}

let esc = "\u{1B}"

/// Streams, each a behaviour, played in a 20x6 pane.
let cases: [(name: String, text: String)] = [
  ("plain and wrapping", "hello\nworld, this line is longer than twenty columns\nend"),
  ("CR BS HT", "abcdef\rXY\u{08}\u{08}Z\tT\tU"),
  ("CUP CUU CUD CUF CUB", "\(esc)[3;5Hmid\(esc)[2Aup\(esc)[3Bdown\(esc)[4Cright\(esc)[10Dleft"),
  ("CHA VPA CNL CPL", "\(esc)[3;1Habc\(esc)[10Gx\(esc)[5dy\(esc)[2Fz\(esc)[1Ew"),
  ("ED and EL", "aaaaaaaa\nbbbbbbbb\ncccccccc\(esc)[2;4H\(esc)[K\(esc)[3;2H\(esc)[1K\(esc)[1;1H\(esc)[1J"),
  ("ED 0 and 2", "line one\nline two\nline three\(esc)[2;3H\(esc)[J"),
  ("ICH DCH ECH", "abcdefghij\(esc)[1;3H\(esc)[2@\(esc)[1;8H\(esc)[3P\(esc)[1;1H\(esc)[2X"),
  ("IL DL in a region", "1\n2\n3\n4\n5\n6\(esc)[2;5r\(esc)[3;1H\(esc)[L\(esc)[4;1H\(esc)[2M\(esc)[r"),
  ("scrolling a region", "1\n2\n3\n4\n5\n6\(esc)[2;4r\(esc)[4;1H\nnew\(esc)[2;1H\(esc)M\(esc)[r"),
  ("SU SD", "a\nb\nc\nd\(esc)[2S\(esc)[1T"),
  ("DECSC DECRC", "\(esc)[2;3Hsave\(esc)7\(esc)[5;5Hthere\(esc)8back"),
  ("insert mode", "abcdef\(esc)[1;3H\(esc)[4hXY\(esc)[4lZ"),
  ("autowrap off", "\(esc)[?7l0123456789012345678901234\(esc)[?7h"),
  ("last column wrap", "01234567890123456789\(esc)[Kafter"),
  ("wide characters", "a日本語b\n0123456789012345678漢x"),
  ("combining marks", "e\u{301}a\u{308}o\u{302}x"),
  ("alternate screen", "primary\(esc)[?1049halt screen\(esc)[2;2Hhere\(esc)[?1049lback"),
  ("REP and tabs", "x\(esc)[4b\tT\tU"),
  ("origin mode", "\(esc)[3;5r\(esc)[?6h\(esc)[1;1Horigin\(esc)[?6l\(esc)[r"),
  ("reverse index at top", "top\(esc)[1;1H\(esc)Mabove"),
  ("long scroll", (1...20).map { "line \($0)" }.joined(separator: "\n")),
  ("SGR does not move", "\(esc)[1;31mred\(esc)[0m \(esc)[38;5;200mpink\(esc)[38;2;1;2;3mrgb\(esc)[m."),
  ("CAN aborts", "ab\(esc)[3\u{18}cd"),
]

@Test(arguments: cases.indices) func sameAsTmux(_ i: Int) {
  let c = cases[i]
  let bytes = Array(c.text.utf8)
  guard let theirs = tmux(bytes, columns: 20, rows: 6, tag: i) else { return }
  let mine = ours(bytes, columns: 20, rows: 6)
  #expect(mine.lines == theirs.lines, "\(c.name): ours \(mine.lines) tmux \(theirs.lines)")
  #expect(mine.x == theirs.x && mine.y == theirs.y,
          "\(c.name): cursor ours \(mine.x),\(mine.y) tmux \(theirs.x),\(theirs.y)")
}

/// Tab stops set and cleared (tmux's capture writes tabs as tabs, so these
/// are checked here).
@Test func tabStops() {
  var s = Screen(columns: 20, rows: 1)
  s.feed(Array("\(esc)[3g\(esc)[1;4H\(esc)H\(esc)[1;11H\(esc)H\r\tA\tB\tC".utf8))
  // Stops at 3 and 10; past the last, a tab goes to the last column.
  #expect(s.text(row: 0) == "   A      B        C")
}

@Test func colorsAndAttributes() {
  var s = Screen(columns: 20, rows: 2)
  s.feed(Array("\(esc)[1;4;31mA\(esc)[22;24;92;48;5;17mB\(esc)[38;2;255;128;0mC\(esc)[38:2::1:2:3mD\(esc)[7;39mE\(esc)[0mF".utf8))
  let l = s.lines[0]
  #expect(l[0].foreground == .indexed(1) && l[0].attributes == [.bold, .underline])
  #expect(l[1].foreground == .indexed(10) && l[1].background == .indexed(17) && l[1].attributes.isEmpty)
  #expect(l[2].foreground == .rgb(0xFF8000))
  #expect(l[3].foreground == .rgb(0x010203))
  #expect(l[4].foreground == .standard && l[4].attributes == [.inverse])
  #expect(l[5].foreground == .standard && l[5].background == .standard && l[5].attributes.isEmpty)
  // Erasing paints the pen's background.
  s.feed(Array("\(esc)[44m\(esc)[2K".utf8))
  #expect(s.lines[0][0].background == .indexed(4))
}

@Test func repliesTitleAndBell() {
  var s = Screen(columns: 20, rows: 5)
  s.feed(Array("\(esc)[3;7H\(esc)[6n\(esc)[5n\(esc)[c\(esc)]0;a title\u{07}\u{07}\(esc)]2;other\(esc)\\".utf8))
  #expect(s.takeReplies() == Array("\(esc)[3;7R\(esc)[0n\(esc)[?62;22c".utf8))
  #expect(s.title == "other" && s.takeBell())
}

@Test func theProgramsDirectory() {
  var s = Screen(columns: 20, rows: 5)
  #expect(s.workingDirectory == "")
  s.feed(Array("\(esc)]7;file:///data/My%20Music\u{07}".utf8))
  #expect(s.workingDirectory == "/data/My Music")
  s.feed(Array("\(esc)]7;file://todhchai/data\(esc)\\".utf8))
  #expect(s.workingDirectory == "/data")
  // Not a file URL: kept as it was.
  s.feed(Array("\(esc)]7;/elsewhere\u{07}".utf8))
  #expect(s.workingDirectory == "/data" && s.text(row: 0) == "")
}

@Test func scrollbackAndResize() {
  var s = Screen(columns: 10, rows: 3)
  s.feed(Array("1\r\n2\r\n3\r\n4\r\n5".utf8))
  #expect(s.scrollback.count == 2 && s.text(row: 0) == "3" && s.text(row: 2) == "5")
  // Taller: lines come back from scrollback; shorter: they go again.
  s.resize(columns: 10, rows: 5)
  #expect(s.text(row: 0) == "1" && s.text(row: 4) == "5" && s.cursorY == 4 && s.scrollback.isEmpty)
  s.resize(columns: 4, rows: 2)
  #expect(s.text(row: 0) == "4" && s.text(row: 1) == "5" && s.scrollback.count == 3)
  // The alternate screen keeps no scrollback.
  s.feed(Array("\(esc)[?1049h\r\nx\r\ny\r\nz".utf8))
  #expect(s.scrollback.count == 3)
  // Damage: what changed since the last look.
  _ = s.takeDamage()
  s.feed(Array("\(esc)[1;1Hq".utf8))
  #expect(s.takeDamage() == [0])
}

@Test func keysAsXtermSendsThem() {
  #expect(KeyEncoder.encode(.up) == Array("\(esc)[A".utf8))
  #expect(KeyEncoder.encode(.up, applicationCursor: true) == Array("\(esc)OA".utf8))
  #expect(KeyEncoder.encode(.left, [.control]) == Array("\(esc)[1;5D".utf8))
  #expect(KeyEncoder.encode(.home, [.shift]) == Array("\(esc)[1;2H".utf8))
  #expect(KeyEncoder.encode(.delete) == Array("\(esc)[3~".utf8))
  #expect(KeyEncoder.encode(.pageDown, [.alt]) == Array("\(esc)[6;3~".utf8))
  #expect(KeyEncoder.encode(.function(1)) == Array("\(esc)OP".utf8))
  #expect(KeyEncoder.encode(.function(5)) == Array("\(esc)[15~".utf8))
  #expect(KeyEncoder.encode(.function(12), [.control]) == Array("\(esc)[24;5~".utf8))
  #expect(KeyEncoder.encode(.tab, [.shift]) == Array("\(esc)[Z".utf8))
  #expect(KeyEncoder.encode(.backspace) == [0x7F] && KeyEncoder.encode(.backspace, [.control]) == [0x08])
  #expect(KeyEncoder.encode(character: 0x63, [.control]) == [0x03])
  #expect(KeyEncoder.encode(character: 0x78, [.alt]) == [0x1B, 0x78])
  #expect(KeyEncoder.encode(character: 0xE9) == Array("é".utf8))
  #expect(KeyEncoder.paste("hi", bracketed: true) == Array("\(esc)[200~hi\(esc)[201~".utf8))
}
