// SPDX-License-Identifier: BSD-3-Clause

// Terminal's input parser (M6j part 2d): bytes from the program, through
// the DEC state machine (Paul Williams's "A parser for DEC's ANSI-compatible
// video terminals": ground, escape, CSI's parameters and intermediates, OSC
// strings, DCS and the other strings ignored), UTF-8 decoded in the ground
// state, onto the screen. What it does: ECMA-48's controls and sequences
// and xterm's ("XTerm Control Sequences") that programs use:
//
//   C0     BEL BS HT LF VT FF CR
//   ESC    7 8 (DECSC, DECRC) D E H M (IND NEL HTS RI) c (RIS)
//   CSI    @ A B C D E F G H I J K L M P S T X Z ` a b c d e f g h l m n r s u
//   modes  IRM (4), LNM (20); DEC 1 (cursor keys), 6 (origin), 7 (wrap),
//          25 (cursor), 47 1047 1049 (the alternate screen), 2004 (paste)
//   SGR    0-9, 21-29, 30-37 38 39, 40-47 48 49, 90-97, 100-107; 38 and 48
//          as 5;n or 2;r;g;b, with ; or :
//   DSR    5 and 6 (CPR); DA (an xterm's VT220-class answer)
//   OSC    0 and 2: the title; 7: the program's directory (file://HOST/PATH)
// Anything else is parsed and dropped.

/// The parser's state, kept in the screen.
struct ParseState: Sendable {
  enum Mode: Sendable {
    case ground, escape, escapeIntermediate, csi, osc, ignoreString
  }
  var mode = Mode.ground
  var params: [Int] = []
  /// Sub-parameters were joined with ':' (38:2::r:g:b, its colour space
  /// given, empty).
  var colon = false
  var privateMarker: UInt8 = 0
  var intermediate: UInt8 = 0
  var osc: [UInt8] = []
  /// A UTF-8 sequence being read: its value so far and bytes to come.
  var utf8Value: UInt32 = 0
  var utf8Left = 0
  /// ESC seen inside a string (the start of ST).
  var stringEscape = false
}

/// How many cells a character takes: 0 for a combining mark, 2 for an
/// East Asian wide character, else 1 (ranges after UAX #11's W and F, and
/// the combining blocks: Latin first).
public func cellWidth(_ c: UInt32) -> Int {
  if c < 0x300 { return 1 }
  if (0x300...0x36F).contains(c) || (0x1AB0...0x1AFF).contains(c) || (0x1DC0...0x1DFF).contains(c)
    || (0x20D0...0x20FF).contains(c) || (0xFE20...0xFE2F).contains(c) || (0xFE00...0xFE0F).contains(c)
    || c == 0x200B || c == 0x200C || c == 0x200D
  {
    return 0
  }
  if (0x1100...0x115F).contains(c) || (0x2E80...0x303E).contains(c) || (0x3041...0x33FF).contains(c)
    || (0x3400...0x4DBF).contains(c) || (0x4E00...0x9FFF).contains(c) || (0xA000...0xA4CF).contains(c)
    || (0xAC00...0xD7A3).contains(c) || (0xF900...0xFAFF).contains(c) || (0xFE30...0xFE4F).contains(c)
    || (0xFF00...0xFF60).contains(c) || (0xFFE0...0xFFE6).contains(c) || (0x1F300...0x1F64F).contains(c)
    || (0x1F900...0x1F9FF).contains(c) || (0x20000...0x3FFFD).contains(c)
  {
    return 2
  }
  return 1
}

extension Screen {
  /// The program's output.
  public mutating func feed(_ bytes: [UInt8]) {
    var i = 0
    let n = bytes.count
    while i < n {
      let b = bytes[i]
      // The common case: a run of printable ASCII in the ground state.
      if parse.mode == .ground && parse.utf8Left == 0 && b >= 0x20 && b < 0x7F {
        var end = i + 1
        while end < n && bytes[end] >= 0x20 && bytes[end] < 0x7F { end += 1 }
        if insertMode {
          for k in i..<end { put(UInt32(bytes[k]), width: 1) }
        } else {
          putASCII(bytes, i, end)
        }
        i = end
        continue
      }
      byte(b)
      i += 1
    }
  }

  mutating func byte(_ b: UInt8) {
    // C0 controls act in every state but the strings' (CAN and SUB end any
    // sequence; ESC starts one).
    if parse.mode != .osc && parse.mode != .ignoreString {
      if b == 0x18 || b == 0x1A {
        parse.mode = .ground
        return
      }
      if b == 0x1B {
        enterEscape()
        return
      }
      if b < 0x20 {
        control(b)
        return
      }
    }
    switch parse.mode {
    case .ground: ground(b)
    case .escape:
      if b >= 0x20 && b <= 0x2F {
        parse.intermediate = b
        parse.mode = .escapeIntermediate
      } else if b == UInt8(ascii: "[") {
        parse.mode = .csi
        parse.params.removeAll(keepingCapacity: true)
        parse.colon = false
        parse.privateMarker = 0
        parse.intermediate = 0
      } else if b == UInt8(ascii: "]") {
        parse.mode = .osc
        parse.osc.removeAll(keepingCapacity: true)
        parse.stringEscape = false
      } else if b == UInt8(ascii: "P") || b == UInt8(ascii: "X") || b == UInt8(ascii: "^") || b == UInt8(ascii: "_") {
        parse.mode = .ignoreString
        parse.stringEscape = false
      } else {
        parse.mode = .ground
        escape(b)
      }
    case .escapeIntermediate:
      if b >= 0x20 && b <= 0x2F { return }
      parse.mode = .ground  // character sets and the like: dropped
    case .csi: csiByte(b)
    case .osc, .ignoreString:
      // Strings end at BEL (xterm) or ST (ESC \).
      if b == 0x07 || (parse.stringEscape && b == UInt8(ascii: "\\")) {
        if parse.mode == .osc { oscDispatch() }
        parse.mode = .ground
        return
      }
      if b == 0x1B {
        parse.stringEscape = true
        return
      }
      if parse.stringEscape {
        // ESC then something else: a new sequence.
        parse.mode = .ground
        enterEscape()
        byte(b)
        return
      }
      if parse.mode == .osc && parse.osc.count < 4096 { parse.osc.append(b) }
    }
  }

  mutating func enterEscape() {
    parse.mode = .escape
    parse.intermediate = 0
  }

  /// UTF-8 in the ground state; malformed sequences are U+FFFD.
  mutating func ground(_ b: UInt8) {
    if parse.utf8Left > 0 {
      if b & 0xC0 == 0x80 {
        parse.utf8Value = parse.utf8Value << 6 | UInt32(b & 0x3F)
        parse.utf8Left -= 1
        if parse.utf8Left == 0 { character(parse.utf8Value) }
        return
      }
      parse.utf8Left = 0
      character(0xFFFD)
    }
    switch b {
    case 0x20..<0x7F: character(UInt32(b))
    case 0xC2...0xDF:
      parse.utf8Value = UInt32(b & 0x1F)
      parse.utf8Left = 1
    case 0xE0...0xEF:
      parse.utf8Value = UInt32(b & 0x0F)
      parse.utf8Left = 2
    case 0xF0...0xF4:
      parse.utf8Value = UInt32(b & 0x07)
      parse.utf8Left = 3
    case 0x7F: break  // DEL: nothing
    default: character(0xFFFD)
    }
  }

  mutating func character(_ c: UInt32) {
    let valid = c <= 0x10FFFF && !(0xD800...0xDFFF).contains(c)
    let scalar = valid ? c : 0xFFFD
    put(scalar, width: cellWidth(scalar))
  }

  mutating func control(_ b: UInt8) {
    switch b {
    case 0x07: bell = true
    case 0x08:
      if cursorX > 0 { cursorX -= wrapPending ? 0 : 1 }
      wrapPending = false
    case 0x09: tab(1)
    case 0x0A, 0x0B, 0x0C:
      lineFeed()
      if newlineMode { cursorX = 0 }
      wrapPending = false
    case 0x0D:
      cursorX = 0
      wrapPending = false
    default: break
    }
  }

  mutating func tab(_ count: Int) {
    var left = count
    while left > 0 && cursorX < columns - 1 {
      cursorX += 1
      if tabs[cursorX] { left -= 1 }
    }
    wrapPending = false
  }

  mutating func escape(_ b: UInt8) {
    switch b {
    case UInt8(ascii: "7"): saveCursor()
    case UInt8(ascii: "8"): restoreCursor()
    case UInt8(ascii: "D"): lineFeed()
    case UInt8(ascii: "E"):
      lineFeed()
      cursorX = 0
    case UInt8(ascii: "H"): tabs[cursorX] = true
    case UInt8(ascii: "M"): reverseIndex()
    case UInt8(ascii: "c"): reset()
    default: break
    }
    wrapPending = false
  }

  // MARK: CSI

  mutating func csiByte(_ b: UInt8) {
    switch b {
    case 0x30...0x39:
      if parse.params.isEmpty { parse.params.append(0) }
      let last = parse.params.count - 1
      parse.params[last] = min(parse.params[last] * 10 + Int(b - 0x30), 65_535)
    case UInt8(ascii: ";"), UInt8(ascii: ":"):
      // Each separator opens the next parameter; an absent one is 0, read
      // as its default.
      if parse.params.isEmpty { parse.params.append(0) }
      parse.params.append(0)
      if b == UInt8(ascii: ":") { parse.colon = true }
    case 0x3C...0x3F:
      if parse.params.isEmpty { parse.privateMarker = b }
    case 0x20...0x2F: parse.intermediate = b
    case 0x40...0x7E:
      parse.mode = .ground
      csiDispatch(b)
    default:
      parse.mode = .ground
    }
  }

  /// Parameter `i`, or `default` when absent or 0 (for counts).
  func count(_ i: Int, _ d: Int = 1) -> Int {
    i < parse.params.count && parse.params[i] != 0 ? parse.params[i] : d
  }

  func param(_ i: Int, _ d: Int = 0) -> Int { i < parse.params.count ? parse.params[i] : d }

  mutating func csiDispatch(_ final: UInt8) {
    let p = parse.privateMarker
    if p == UInt8(ascii: "?") {
      if final == UInt8(ascii: "h") || final == UInt8(ascii: "l") {
        for m in parse.params { decMode(m, final == UInt8(ascii: "h")) }
      }
      return
    }
    if p != 0 && final != UInt8(ascii: "c") { return }  // > = < queries and modes: dropped
    if parse.intermediate != 0 { return }  // DECSCUSR and the like: dropped
    switch final {
    case UInt8(ascii: "@"): insertCharacters(count(0))
    case UInt8(ascii: "A"): moveVertically(-count(0))
    case UInt8(ascii: "B"), UInt8(ascii: "e"): moveVertically(count(0))
    case UInt8(ascii: "C"), UInt8(ascii: "a"):
      cursorX = min(cursorX + count(0), columns - 1)
      wrapPending = false
    case UInt8(ascii: "D"):
      cursorX = max(cursorX - count(0), 0)
      wrapPending = false
    case UInt8(ascii: "E"):
      moveVertically(count(0))
      cursorX = 0
    case UInt8(ascii: "F"):
      moveVertically(-count(0))
      cursorX = 0
    case UInt8(ascii: "G"), UInt8(ascii: "`"):
      cursorX = min(max(count(0) - 1, 0), columns - 1)
      wrapPending = false
    case UInt8(ascii: "H"), UInt8(ascii: "f"): moveTo(x: count(1) - 1, y: count(0) - 1)
    case UInt8(ascii: "I"): tab(count(0))
    case UInt8(ascii: "J"): eraseDisplay(param(0))
    case UInt8(ascii: "K"): eraseLine(param(0))
    case UInt8(ascii: "L"): insertLines(count(0))
    case UInt8(ascii: "M"): deleteLines(count(0))
    case UInt8(ascii: "P"): deleteCharacters(count(0))
    case UInt8(ascii: "S"): scrollUp(count(0))
    case UInt8(ascii: "T"): scrollDown(count(0))
    case UInt8(ascii: "X"): erase(row: cursorY, from: cursorX, to: cursorX + count(0))
    case UInt8(ascii: "Z"):
      var left = count(0)
      while left > 0 && cursorX > 0 {
        cursorX -= 1
        if tabs[cursorX] { left -= 1 }
      }
      wrapPending = false
    case UInt8(ascii: "b"):
      // REP: the character before the cursor, again.
      let x = max(cursorX - (wrapPending ? 0 : 1), 0)
      let c = lines[cursorY][x]
      if c.scalar != 0 { for _ in 0..<min(count(0), 65_535) { put(c.scalar, width: Int(max(c.width, 1))) } }
    case UInt8(ascii: "c"):
      // DA: a VT220-class terminal (xterm's primary answer).
      if p == 0 { replies += Array("\u{1B}[?62;22c".utf8) }
    case UInt8(ascii: "d"): moveTo(x: cursorX, y: count(0) - 1)
    case UInt8(ascii: "g"):
      if param(0) == 3 { for i in tabs.indices { tabs[i] = false } } else if param(0) == 0 { tabs[cursorX] = false }
    case UInt8(ascii: "h"), UInt8(ascii: "l"):
      let on = final == UInt8(ascii: "h")
      for m in parse.params {
        if m == 4 { insertMode = on } else if m == 20 { newlineMode = on }
      }
    case UInt8(ascii: "m"): sgr()
    case UInt8(ascii: "n"):
      if param(0) == 5 { replies += Array("\u{1B}[0n".utf8) }
      if param(0) == 6 {
        let y = cursorY - (originMode ? scrollTop : 0)
        replies += Array("\u{1B}[\(y + 1);\(cursorX + 1)R".utf8)
      }
    case UInt8(ascii: "r"):
      let top = count(0) - 1, bottom = count(1, rows) - 1
      if top < bottom && bottom < rows {
        scrollTop = top
        scrollBottom = bottom
        moveTo(x: 0, y: 0)
      }
    case UInt8(ascii: "s"): saveCursor()
    case UInt8(ascii: "u"): restoreCursor()
    default: break
    }
  }

  mutating func decMode(_ m: Int, _ on: Bool) {
    switch m {
    case 1: applicationCursorKeys = on
    case 6:
      originMode = on
      moveTo(x: 0, y: 0)
    case 7: autowrap = on
    case 25: cursorVisible = on
    case 47, 1047:
      if on { enterAlternate() } else { leaveAlternate() }
    case 1049:
      if on {
        saveCursor()
        enterAlternate()
      } else {
        leaveAlternate()
      }
    case 2004: bracketedPaste = on
    default: break
    }
  }

  // MARK: SGR

  mutating func sgr() {
    let ps = parse.params.isEmpty ? [0] : parse.params
    var i = 0
    func color(_ at: inout Int) -> TerminalColor? {
      // 5;n or 2;r;g;b after 38 or 48.
      guard at + 1 < ps.count else { return nil }
      if ps[at + 1] == 5, at + 2 < ps.count {
        at += 2
        return .indexed(UInt8(min(ps[at], 255)))
      }
      if ps[at + 1] == 2, at + 4 < ps.count {
        // With colons, a colour-space field may come first (38:2::r:g:b).
        let skip = parse.colon && at + 5 < ps.count ? 1 : 0
        let r = min(ps[at + 2 + skip], 255), g = min(ps[at + 3 + skip], 255), b = min(ps[at + 4 + skip], 255)
        at += 4 + skip
        return .rgb(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
      }
      return nil
    }
    while i < ps.count {
      let v = ps[i]
      switch v {
      case 0: pen = Pen()
      case 1: pen.attributes.insert(.bold)
      case 2: pen.attributes.insert(.dim)
      case 3: pen.attributes.insert(.italic)
      case 4: pen.attributes.insert(.underline)
      case 5, 6: pen.attributes.insert(.blink)
      case 7: pen.attributes.insert(.inverse)
      case 8: pen.attributes.insert(.hidden)
      case 9: pen.attributes.insert(.strike)
      case 21, 22: pen.attributes.subtract([.bold, .dim])
      case 23: pen.attributes.remove(.italic)
      case 24: pen.attributes.remove(.underline)
      case 25: pen.attributes.remove(.blink)
      case 27: pen.attributes.remove(.inverse)
      case 28: pen.attributes.remove(.hidden)
      case 29: pen.attributes.remove(.strike)
      case 30...37: pen.foreground = .indexed(UInt8(v - 30))
      case 38: if let c = color(&i) { pen.foreground = c }
      case 39: pen.foreground = .standard
      case 40...47: pen.background = .indexed(UInt8(v - 40))
      case 48: if let c = color(&i) { pen.background = c }
      case 49: pen.background = .standard
      case 90...97: pen.foreground = .indexed(UInt8(v - 90 + 8))
      case 100...107: pen.background = .indexed(UInt8(v - 100 + 8))
      default: break
      }
      i += 1
    }
  }

  // MARK: OSC

  mutating func oscDispatch() {
    guard let semi = parse.osc.firstIndex(of: UInt8(ascii: ";")) else { return }
    let code = String(decoding: parse.osc[..<semi], as: UTF8.self)
    if code == "0" || code == "2" { title = String(decoding: parse.osc[(semi + 1)...], as: UTF8.self) }
    if code == "7", let path = Screen.fileURLPath(Array(parse.osc[(semi + 1)...])) { workingDirectory = path }
  }
}
