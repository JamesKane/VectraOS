// SPDX-License-Identifier: BSD-3-Clause

// Terminal's screen (M6j part 2d): what ECMA-48's and xterm's control
// sequences (Parser.swift) do to a grid of cells. A cell holds one
// character (a base scalar and, Latin first, one combining mark), its
// colours and attributes; a wide character takes two cells, the second a
// continuation. The screen keeps a cursor with a pending wrap (the last
// column's deferred wrap, as VT100s do), a scroll region, tab stops,
// modes, a saved cursor, the alternate screen (xterm's 1049, without
// scrollback), and the primary screen's scrollback, lines that scrolled
// off its top, up to a limit.

public enum TerminalColor: Equatable, Sendable {
  case standard
  /// The 256-colour palette's index (0-15 the ANSI colours).
  case indexed(UInt8)
  /// 0xRRGGBB.
  case rgb(UInt32)
}

public struct CellAttributes: OptionSet, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let bold = CellAttributes(rawValue: 1)
  public static let dim = CellAttributes(rawValue: 2)
  public static let italic = CellAttributes(rawValue: 4)
  public static let underline = CellAttributes(rawValue: 8)
  public static let blink = CellAttributes(rawValue: 16)
  public static let inverse = CellAttributes(rawValue: 32)
  public static let hidden = CellAttributes(rawValue: 64)
  public static let strike = CellAttributes(rawValue: 128)
}

public struct Cell: Equatable, Sendable {
  /// The character's scalar (0: blank).
  public var scalar: UInt32 = 0
  /// A combining mark on it (0: none).
  public var mark: UInt32 = 0
  /// 1, 2 for a wide character's first cell, 0 for its second.
  public var width: UInt8 = 1
  public var foreground: TerminalColor = .standard
  public var background: TerminalColor = .standard
  public var attributes: CellAttributes = []

  public init() {}
  public static let blank = Cell()

  /// The cell's text.
  public var text: String {
    var s = ""
    if scalar != 0, let u = Unicode.Scalar(scalar) { s.unicodeScalars.append(u) } else if width != 0 { s = " " }
    if mark != 0, let m = Unicode.Scalar(mark) { s.unicodeScalars.append(m) }
    return s
  }
}

public struct Pen: Equatable, Sendable {
  public var foreground: TerminalColor = .standard
  public var background: TerminalColor = .standard
  public var attributes: CellAttributes = []
}

public struct Screen: Sendable {
  public private(set) var columns: Int
  public private(set) var rows: Int
  /// The visible lines, top first.
  public internal(set) var lines: [[Cell]]
  /// Lines scrolled off the primary screen's top, oldest first.
  public internal(set) var scrollback: [[Cell]] = []
  public var scrollbackLimit = 10_000
  public internal(set) var cursorX = 0
  public internal(set) var cursorY = 0
  /// At the last column, a character was written: the next one wraps.
  public internal(set) var wrapPending = false
  public internal(set) var pen = Pen()
  var scrollTop = 0
  var scrollBottom: Int
  var tabs: [Bool]
  /// DECAWM, DECTCEM, DECCKM, DECOM, IRM, xterm's bracketed paste, LNM.
  public internal(set) var autowrap = true
  public internal(set) var cursorVisible = true
  public internal(set) var applicationCursorKeys = false
  var originMode = false
  var insertMode = false
  public internal(set) var bracketedPaste = false
  var newlineMode = false
  var saved: (x: Int, y: Int, pen: Pen, originMode: Bool, autowrap: Bool)? = nil
  /// The primary screen while the alternate one shows.
  var primary: (lines: [[Cell]], x: Int, y: Int, saved: (x: Int, y: Int, pen: Pen, originMode: Bool, autowrap: Bool)?)? = nil
  public var alternate: Bool { primary != nil }
  /// OSC 0 or 2's.
  public internal(set) var title = ""
  /// The program's directory, as it said with OSC 7 ("" until it does):
  /// where a word routed from the screen is relative to.
  public internal(set) var workingDirectory = ""
  /// Replies to queries (DSR, DA), for the terminal to send back.
  public internal(set) var replies: [UInt8] = []
  /// BEL rang since the last `takeBell`.
  public internal(set) var bell = false
  /// Lines changed since `takeDamage` (indices into `lines`), and
  /// whether everything did.
  var damaged: [Bool]
  /// The parser's state (Parser.swift), part of the value.
  var parse = ParseState()

  public init(columns: Int, rows: Int) {
    self.columns = max(1, columns)
    self.rows = max(1, rows)
    lines = Array(repeating: Array(repeating: .blank, count: self.columns), count: self.rows)
    scrollBottom = self.rows - 1
    tabs = (0..<self.columns).map { $0 % 8 == 0 && $0 > 0 }
    damaged = Array(repeating: true, count: self.rows)
  }

  /// Which lines changed since the last call (and clears that).
  public mutating func takeDamage() -> [Int] {
    var out: [Int] = []
    for (i, d) in damaged.enumerated() where d { out.append(i) }
    for i in damaged.indices { damaged[i] = false }
    return out
  }

  public mutating func takeReplies() -> [UInt8] {
    defer { replies.removeAll() }
    return replies
  }

  public mutating func takeBell() -> Bool {
    defer { bell = false }
    return bell
  }

  /// The path of a `file://HOST/PATH` URL (OSC 7's), percent-decoded;
  /// nil if it isn't one.
  static func fileURLPath(_ url: [UInt8]) -> String? {
    let scheme = Array("file://".utf8)
    guard url.starts(with: scheme), let slash = url[scheme.count...].firstIndex(of: UInt8(ascii: "/")) else {
      return nil
    }
    func hex(_ b: UInt8) -> UInt8? {
      switch b {
      case 0x30...0x39: b - 0x30
      case 0x41...0x46: b - 0x37
      case 0x61...0x66: b - 0x57
      default: nil
      }
    }
    var out: [UInt8] = []
    var i = slash
    while i < url.count {
      if url[i] == UInt8(ascii: "%"), i + 2 < url.count, let h = hex(url[i + 1]), let l = hex(url[i + 2]) {
        out.append(h << 4 | l)
        i += 3
      } else {
        out.append(url[i])
        i += 1
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// A row's text, trailing blanks dropped (tests; copying).
  public func text(row: Int) -> String {
    var s = lines[row].map { $0.text }.joined()
    while s.hasSuffix(" ") { s.removeLast() }
    return s
  }

  func blankCell() -> Cell {
    var c = Cell.blank
    c.background = pen.background  // erasing paints the pen's background (bce)
    return c
  }

  mutating func touch(_ y: Int) { if y >= 0 && y < rows { damaged[y] = true } }
  mutating func touchAll() { for i in damaged.indices { damaged[i] = true } }

  // MARK: Writing

  /// A printable character at the cursor (`width` 0: a combining mark).
  mutating func put(_ scalar: UInt32, width w: Int) {
    if w == 0 {
      // A mark joins the character before the cursor (at the cursor, if a
      // wrap is pending: the last column's), its first cell if wide.
      var x = wrapPending ? cursorX : cursorX - 1
      if x > 0 && lines[cursorY][x].width == 0 { x -= 1 }
      if x >= 0 {
        lines[cursorY][x].mark = scalar
        touch(cursorY)
      }
      return
    }
    if wrapPending {
      if autowrap {
        cursorX = 0
        lineFeed()
      }
      wrapPending = false
    }
    if w == 2 && cursorX == columns - 1 {
      // A wide character doesn't fit: the line's end stays blank.
      if autowrap {
        lines[cursorY][cursorX] = blankCell()
        cursorX = 0
        lineFeed()
      } else {
        return
      }
    }
    if insertMode {
      let n = w
      var line = lines[cursorY]
      line.insert(contentsOf: Array(repeating: blankCell(), count: n), at: cursorX)
      line.removeLast(n)
      lines[cursorY] = line
    }
    // Overwriting half of a wide character blanks its other half.
    clearWideAt(cursorX)
    if w == 2 { clearWideAt(cursorX + 1) }
    var c = Cell()
    c.scalar = scalar
    c.width = UInt8(w)
    c.foreground = pen.foreground
    c.background = pen.background
    c.attributes = pen.attributes
    lines[cursorY][cursorX] = c
    if w == 2 {
      var cont = c
      cont.scalar = 0
      cont.width = 0
      lines[cursorY][cursorX + 1] = cont
    }
    touch(cursorY)
    if cursorX + w >= columns {
      // The last column: the next character wraps (autowrap), or writes
      // over this one.
      cursorX = columns - 1
      wrapPending = autowrap
    } else {
      cursorX += w
    }
  }

  /// Printable ASCII, `bytes[from..<to]`, as `put` would write it one by
  /// one: as many as fit on the line at a time, in plain cells of the pen.
  mutating func putASCII(_ bytes: [UInt8], _ from: Int, _ to: Int) {
    var c = Cell()
    c.foreground = pen.foreground
    c.background = pen.background
    c.attributes = pen.attributes
    var i = from
    while i < to {
      if wrapPending {
        if autowrap {
          cursorX = 0
          lineFeed()
        }
        wrapPending = false
      }
      let n = min(columns - cursorX, to - i)
      // A wide character cut by the run's ends goes whole.
      clearWideAt(cursorX)
      clearWideAt(cursorX + n - 1)
      let x0 = cursorX, y = cursorY
      lines[y].withUnsafeMutableBufferPointer { line in
        for k in 0..<n {
          c.scalar = UInt32(bytes[i + k])
          line[x0 + k] = c
        }
      }
      touch(y)
      i += n
      if x0 + n >= columns {
        cursorX = columns - 1
        wrapPending = autowrap
        if !autowrap && i < to {
          // Without autowrap, the rest writes over the last column.
          lines[y][columns - 1].scalar = UInt32(bytes[to - 1])
          i = to
        }
      } else {
        cursorX = x0 + n
      }
    }
  }

  mutating func clearWideAt(_ x: Int) {
    guard x >= 0 && x < columns else { return }
    let c = lines[cursorY][x]
    if c.width == 0 && x > 0 { lines[cursorY][x - 1] = blankCell() }
    if c.width == 2 && x + 1 < columns { lines[cursorY][x + 1] = blankCell() }
  }

  // MARK: Moving

  mutating func lineFeed() {
    if cursorY == scrollBottom {
      scrollUp(1)
    } else if cursorY < rows - 1 {
      cursorY += 1
    }
  }

  mutating func reverseIndex() {
    if cursorY == scrollTop { scrollDown(1) } else if cursorY > 0 { cursorY -= 1 }
  }

  /// The region's lines up by `n`: the top ones into scrollback (the
  /// whole primary screen's), blanks at the bottom.
  mutating func scrollUp(_ n: Int) {
    let n = min(n, scrollBottom - scrollTop + 1)
    guard n > 0 else { return }
    for i in 0..<n {
      let gone = lines[scrollTop + i]
      if scrollTop == 0 && !alternate {
        scrollback.append(gone)
        // Trimmed at twice the limit, by half: O(1) a line, as a ring.
        if scrollback.count >= 2 * scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
      }
    }
    lines.removeSubrange(scrollTop..<(scrollTop + n))
    lines.insert(contentsOf: Array(repeating: Array(repeating: blankCell(), count: columns), count: n), at: scrollBottom - n + 1)
    for y in scrollTop...scrollBottom { touch(y) }
  }

  mutating func scrollDown(_ n: Int) {
    let n = min(n, scrollBottom - scrollTop + 1)
    guard n > 0 else { return }
    lines.removeSubrange((scrollBottom - n + 1)...scrollBottom)
    lines.insert(contentsOf: Array(repeating: Array(repeating: blankCell(), count: columns), count: n), at: scrollTop)
    for y in scrollTop...scrollBottom { touch(y) }
  }

  /// Within the screen (or the region, in origin mode).
  mutating func moveTo(x: Int, y: Int) {
    let top = originMode ? scrollTop : 0, bottom = originMode ? scrollBottom : rows - 1
    cursorX = min(max(x, 0), columns - 1)
    cursorY = min(max(y + top, top), bottom)
    wrapPending = false
  }

  /// Cursor up or down, stopping at the region's edge if inside it.
  mutating func moveVertically(_ dy: Int) {
    var y = cursorY + dy
    if cursorY >= scrollTop && cursorY <= scrollBottom { y = min(max(y, scrollTop), scrollBottom) }
    cursorY = min(max(y, 0), rows - 1)
    wrapPending = false
  }

  // MARK: Erasing and editing

  mutating func erase(row y: Int, from x0: Int, to x1: Int) {
    guard y >= 0 && y < rows else { return }
    let a = max(0, x0), b = min(columns, x1)
    guard a < b else { return }
    for x in a..<b { lines[y][x] = blankCell() }
    touch(y)
  }

  /// ED: 0 cursor to end, 1 start to cursor, 2 all, 3 scrollback too.
  mutating func eraseDisplay(_ mode: Int) {
    // With a wrap pending, the cursor is past the last column (as tmux and
    // xterm keep it): erasing to the end leaves that column.
    let from = cursorX + (wrapPending ? 1 : 0)
    switch mode {
    case 0:
      erase(row: cursorY, from: from, to: columns)
      for y in (cursorY + 1)..<max(cursorY + 1, rows) { erase(row: y, from: 0, to: columns) }
    case 1:
      for y in 0..<cursorY { erase(row: y, from: 0, to: columns) }
      erase(row: cursorY, from: 0, to: cursorX + 1)
    case 2, 3:
      for y in 0..<rows { erase(row: y, from: 0, to: columns) }
      if mode == 3 { scrollback.removeAll() }
    default: break
    }
  }

  /// EL: 0 cursor to end, 1 start to cursor, 2 the line.
  mutating func eraseLine(_ mode: Int) {
    switch mode {
    case 0: erase(row: cursorY, from: cursorX + (wrapPending ? 1 : 0), to: columns)
    case 1: erase(row: cursorY, from: 0, to: cursorX + 1)
    case 2: erase(row: cursorY, from: 0, to: columns)
    default: break
    }
  }

  /// IL and DL: lines at the cursor, within the region.
  mutating func insertLines(_ n: Int) {
    guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
    let top = scrollTop
    scrollTop = cursorY
    scrollDown(n)
    scrollTop = top
    cursorX = 0
  }

  mutating func deleteLines(_ n: Int) {
    guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
    let top = scrollTop
    scrollTop = cursorY
    // Scrolling within the region from here: not into scrollback.
    let n = min(n, scrollBottom - cursorY + 1)
    lines.removeSubrange(cursorY..<(cursorY + n))
    lines.insert(contentsOf: Array(repeating: Array(repeating: blankCell(), count: columns), count: n),
                 at: scrollBottom - n + 1)
    for y in cursorY...scrollBottom { touch(y) }
    scrollTop = top
    cursorX = 0
  }

  /// ICH, DCH, ECH: characters at the cursor.
  mutating func insertCharacters(_ n: Int) {
    let n = min(n, columns - cursorX)
    var line = lines[cursorY]
    line.insert(contentsOf: Array(repeating: blankCell(), count: n), at: cursorX)
    line.removeLast(n)
    lines[cursorY] = line
    touch(cursorY)
  }

  mutating func deleteCharacters(_ n: Int) {
    let n = min(n, columns - cursorX)
    var line = lines[cursorY]
    line.removeSubrange(cursorX..<(cursorX + n))
    line.append(contentsOf: Array(repeating: blankCell(), count: n))
    lines[cursorY] = line
    touch(cursorY)
  }

  // MARK: Modes, the alternate screen, resizing

  mutating func saveCursor() { saved = (cursorX, cursorY, pen, originMode, autowrap) }

  mutating func restoreCursor() {
    guard let s = saved else {
      moveTo(x: 0, y: 0)
      return
    }
    pen = s.pen
    originMode = s.originMode
    autowrap = s.autowrap
    cursorX = min(s.x, columns - 1)
    cursorY = min(s.y, rows - 1)
    wrapPending = false
  }

  mutating func enterAlternate() {
    guard primary == nil else { return }
    saveCursor()
    primary = (lines, cursorX, cursorY, saved)
    lines = Array(repeating: Array(repeating: blankCell(), count: columns), count: rows)
    touchAll()
  }

  mutating func leaveAlternate() {
    guard let p = primary else { return }
    primary = nil
    lines = p.lines
    saved = p.saved
    restoreCursor()
    touchAll()
  }

  /// RIS: as new, the size kept.
  mutating func reset() {
    let keep = scrollback
    self = Screen(columns: columns, rows: rows)
    scrollback = keep
  }

  /// A new size: lines cut or padded at the right, rows taken from (or
  /// given back to) the top through scrollback, the cursor kept on its
  /// line. (No reflow of wrapped lines yet.)
  public mutating func resize(columns c: Int, rows r: Int) {
    let c = max(1, c), r = max(1, r)
    func fit(_ line: [Cell]) -> [Cell] {
      line.count >= c ? Array(line.prefix(c)) : line + Array(repeating: Cell.blank, count: c - line.count)
    }
    lines = lines.map(fit)
    scrollback = scrollback.map(fit)
    if r < rows {
      // Lines below the cursor go first, then the top ones to scrollback.
      var drop = rows - r
      while drop > 0 && lines.count - 1 > cursorY && lines.last!.allSatisfy({ $0 == .blank }) {
        lines.removeLast()
        drop -= 1
      }
      if drop > 0 {
        if !alternate { scrollback += lines.prefix(drop) }
        lines.removeFirst(drop)
        cursorY -= drop
      }
      if lines.count > r { lines.removeLast(lines.count - r) }
    } else if r > rows {
      var add = r - rows
      while add > 0, !alternate, let back = scrollback.popLast() {
        lines.insert(back, at: 0)
        cursorY += 1
        add -= 1
      }
      lines += Array(repeating: Array(repeating: Cell.blank, count: c), count: add)
    }
    columns = c
    rows = r
    cursorX = min(cursorX, c - 1)
    cursorY = min(max(cursorY, 0), r - 1)
    scrollTop = 0
    scrollBottom = r - 1
    tabs = (0..<c).map { $0 % 8 == 0 && $0 > 0 }
    wrapPending = false
    damaged = Array(repeating: true, count: r)
    if var p = primary {
      // As the screen's own: blank lines below its cursor go first, then
      // the top ones, to scrollback (its cursor and saved one moved up).
      p.lines = p.lines.map(fit)
      while p.lines.count > r && p.lines.count - 1 > max(p.y, p.saved?.y ?? 0) && p.lines.last!.allSatisfy({ $0 == .blank }) {
        p.lines.removeLast()
      }
      if p.lines.count > r {
        let drop = p.lines.count - r
        scrollback += p.lines.prefix(drop)
        p.lines.removeFirst(drop)
        p.y = max(p.y - drop, 0)
        if var sv = p.saved {
          sv.y = max(sv.y - drop, 0)
          p.saved = sv
        }
      }
      while p.lines.count < r { p.lines.append(Array(repeating: .blank, count: c)) }
      p.x = min(p.x, c - 1)
      primary = p
    }
  }
}
