// SPDX-License-Identifier: BSD-3-Clause

// vt's screen (vt(1)), as a Kit app: a program's output shown as a
// screen (TerminalCore), in the theme's `terminal` part. What it reads
// from the program's stdout (on a thread of vt's: `deliver`) is fed to the
// screen before each frame; the screen's replies go back. Keys go to the
// program as xterm sends them: from the Kit box, or as runes from rio's
// raw cons (`deliverKeys`, RuneKeys); the view's size makes the screen's
// columns and rows, and the link hears of it. The wheel scrolls back through the scrollback, and
// new output brings the view back down. A frame is built only when output
// came or input did: an idle terminal does nothing. A right-click opens
// the context menu on the word under the pointer, whose Route sends it to
// the router from the program's directory (its OSC 7): a compiler's
// `main.swift:42:7:` opens the editor at the line (M6k; Edit since M6m).

import Kit
import Synchronization
import TerminalCore

/// Where the terminal's bytes go: the program's stdin, and its size.
public protocol TerminalLink: AnyObject, Sendable {
  func write(_ bytes: [UInt8])
  func resize(columns: Int, rows: Int)
}

/// One character's place: the mono face's advance and the line's height.
public struct CellMetrics: Sendable {
  public var width: Float
  public var height: Float
  public init(width: Float, height: Float) {
    self.width = width
    self.height = height
  }
}

@MainActor public final class TerminalModel: App {
  public var screen: Screen
  let link: TerminalLink
  let palette: TerminalPalette
  public let cell: CellMetrics
  let style: Style
  /// Bytes from the pty, delivered on a reader's thread.
  let incoming = Mutex<[UInt8]>([])
  /// Keys from rio's raw cons, as runes in UTF-8, delivered on a reader's
  /// thread.
  let keysIn = Mutex<[UInt8]>([])
  /// Lines scrolled back into the scrollback (0: the live screen).
  public var scrolledBack = 0
  /// The program's gone: what it last showed stays.
  public var ended = false
  public var title: String { screen.title.isEmpty ? "vt" : screen.title }

  public init(link: TerminalLink, theme: Theme, cell: CellMetrics, columns: Int = 80, rows: Int = 24) {
    self.link = link
    palette = TerminalPalette(theme: theme)
    self.cell = cell
    style = theme.style("terminal")
    screen = Screen(columns: columns, rows: rows)
  }

  public var actions: [ActionHandler] { [] }

  /// Output from the program (any thread): seen at the next frame.
  public nonisolated func deliver(_ bytes: [UInt8]) {
    incoming.withLock { $0 += bytes }
  }

  /// Keys from rio's raw cons (any thread): sent at the next frame.
  public nonisolated func deliverKeys(_ bytes: [UInt8]) {
    keysIn.withLock { $0 += bytes }
  }

  public func prepare(width: Float, height: Float) {
    // The screen's size from the window's.
    let pad = style.padding
    // (Less the scrollbar's width: Be's Terminal always had one.)
    let columns = max(1, Int((width - pad.left - pad.right - Theme.cqw(1)) / cell.width))
    let rows = max(1, Int((height - pad.top - pad.bottom) / cell.height))
    if columns != screen.columns || rows != screen.rows {
      screen.resize(columns: columns, rows: rows)
      link.resize(columns: columns, rows: rows)
    }
    let keys = keysIn.withLock { b -> [UInt8] in
      defer { b.removeAll(keepingCapacity: true) }
      return b
    }
    let sent = RuneKeys.xterm(keys, applicationCursor: screen.applicationCursorKeys)
    if !sent.isEmpty {
      scrolledBack = 0
      link.write(sent)
      onSent?()
    }
    let bytes = incoming.withLock { b -> [UInt8] in
      defer { b.removeAll(keepingCapacity: true) }
      return b
    }
    if !bytes.isEmpty {
      screen.feed(bytes)
      scrolledBack = 0
      let replies = screen.takeReplies()
      if !replies.isEmpty { link.write(replies) }
    }
  }

  public var body: Group {
    let snapshot = takeSnapshot()
    let cell = cell, style = style, palette = palette
    let lines = Float(screen.scrollback.count + screen.rows) * cell.height
    HStack(width: .percent(1), height: .percent(1)) {
    Drawing(width: .grow(), height: .percent(1), class: "terminal",
            flags: [.background, .clickable, .focusable, .rawKeys, .clip],
            draw: { p, r in TerminalView.draw(snapshot, in: r, cell: cell, style: style, palette: palette, into: &p) },
            signal: { [self] s, key, ui in
              if s.secondaryPressed, let r = ui.lastRect(key: key) {
                let f = ui.frameInput
                ui.openContextMenu("screen", subject: word(atX: f.pointerX - r.x, y: f.pointerY - r.y))
              }
              ui.contextMenu("screen", items: [])
              if ui.focus == 0 || s.pressed { ui.focus(on: key) }
              hasFocus = ui.focus == key
              guard hasFocus else { return }
              // (Keys and text came first, in takeInput; the wheel's here.)
              input(ui.frameInput)
            })
    // The scrollback's bar (M6l): the live screen at its end.
    ScrollBar(view: Float(screen.rows) * cell.height, content: lines, line: cell.height,
              offset: Binding(get: { [self] in Float(screen.scrollback.count - min(scrolledBack, screen.scrollback.count)) * cell.height },
                              set: { [self] in
                                let top = Int(($0 / cell.height).rounded())
                                scrolledBack = min(max(screen.scrollback.count - top, 0), screen.scrollback.count)
                              }))
    }
  }

  /// Whether the screen had the keys last frame.
  var hasFocus = true
  /// The last frame's snapshot: its unchanged rows' runs are kept.
  var lastSnapshot = TerminalSnapshot()

  func takeSnapshot() -> TerminalSnapshot {
    lastSnapshot = TerminalView.snapshot(of: screen, scrolledBack: scrolledBack, palette: palette, reusing: lastSnapshot)
    return lastSnapshot
  }
  /// Keys were written to the pty (M6m's bench: key press to glyph).
  public var onSent: (() -> Void)?

  /// Keys and text go to the pty before the frame is built (M6m: key
  /// press to glyph), while the screen has the keys.
  public func takeInput(_ f: FrameInput) -> Bool {
    guard hasFocus else { return false }
    var keys = f
    keys.scroll = 0
    input(keys)
    return true
  }

  /// Keys, typed text and the wheel, as the program and the view take them:
  /// in the order they came (`sequence`), or keys then text without it.
  func input(_ f: FrameInput) {
    var out: [UInt8] = []
    let items = f.sequence.isEmpty ? f.keys.map { InputItem.key($0) } + (f.text.isEmpty ? [] : [.text(f.text)]) : f.sequence
    for item in items {
      guard case .key(let k) = item else {
        if case .text(let t) = item { out += Array(t.utf8) }
        continue
      }
      var m: KeyModifiers = []
      if k.shift { m.insert(.shift) }
      if k.alt { m.insert(.alt) }
      if k.control { m.insert(.control) }
      switch k.key {
      case .left: out += KeyEncoder.encode(.left, m, applicationCursor: screen.applicationCursorKeys)
      case .right: out += KeyEncoder.encode(.right, m, applicationCursor: screen.applicationCursorKeys)
      case .up: out += KeyEncoder.encode(.up, m, applicationCursor: screen.applicationCursorKeys)
      case .down: out += KeyEncoder.encode(.down, m, applicationCursor: screen.applicationCursorKeys)
      case .home: out += KeyEncoder.encode(.home, m, applicationCursor: screen.applicationCursorKeys)
      case .end: out += KeyEncoder.encode(.end, m, applicationCursor: screen.applicationCursorKeys)
      case .pageUp: out += KeyEncoder.encode(.pageUp, m)
      case .pageDown: out += KeyEncoder.encode(.pageDown, m)
      case .delete: out += KeyEncoder.encode(.delete, m)
      case .backspace: out += KeyEncoder.encode(.backspace, m)
      case .enter: out += KeyEncoder.encode(.enter, m)
      case .tab: out += KeyEncoder.encode(.tab, m)
      case .escape: out += KeyEncoder.encode(.escape, m)
      case .function(let n): out += KeyEncoder.encode(.function(n), m)
      case .character(let c):
        // Typed characters come as text; with Control or Alt, as codes.
        if k.control || k.alt { out += KeyEncoder.encode(character: k.shift ? upper(c) : c, m) }
      case .space:
        if k.control { out += KeyEncoder.encode(character: 0x20, m) }
      }
    }
    if !out.isEmpty {
      scrolledBack = 0
      link.write(out)
      onSent?()
    }
    if f.scroll != 0 {
      let lines = Int(f.scroll / cell.height)
      scrolledBack = min(max(scrolledBack - lines, 0), screen.scrollback.count)
    }
  }

  func upper(_ c: UInt32) -> UInt32 { c >= 0x61 && c <= 0x7A ? c - 0x20 : c }

  /// The word shown at (x, y) in the view: the run of non-blank
  /// characters there, without the brackets, quotes and punctuation
  /// around it (a compiler's `main.swift:42:7:` keeps its numbers, drops
  /// the last colon). "" over a blank.
  public func word(atX x: Float, y: Float) -> String {
    let column = Int((x - style.padding.left) / cell.width), row = Int((y - style.padding.top) / cell.height)
    let back = min(scrolledBack, screen.scrollback.count)
    guard x >= style.padding.left, y >= style.padding.top, row < screen.rows, column < screen.columns else { return "" }
    let line = row < back ? screen.scrollback[screen.scrollback.count - back + row] : screen.lines[row - back]
    guard column < line.count, line[column].text != " ", !line[column].text.isEmpty else { return "" }
    var first = column, last = column
    func blank(_ i: Int) -> Bool { line[i].width != 0 && (line[i].text == " " || line[i].text.isEmpty) }
    while first > 0 && !blank(first - 1) { first -= 1 }
    while last + 1 < line.count && !blank(last + 1) { last += 1 }
    var w = line[first...last].map { $0.text }.joined()
    let around: Set<Character> = ["(", ")", "[", "]", "<", ">", "{", "}", "\"", "'", "`", ",", ";", ":", "."]
    while let c = w.first, around.contains(c) { w.removeFirst() }
    while let c = w.last, around.contains(c) { w.removeLast() }
    return w
  }

  /// Route sends the word from the program's directory.
  public func route(subject: String) -> Route? {
    subject.isEmpty ? nil : Route(wdir: screen.workingDirectory.isEmpty ? "/" : screen.workingDirectory, data: subject)
  }
}

/// What a frame draws of the screen: runs of one style, row by row.
public struct TerminalSnapshot: Sendable {
  /// A run of cells in one look, on a row (M6m: no text: the cells are
  /// drawn from `lines`).
  public struct Run: Sendable, Equatable {
    public var column: Int
    /// The cells it covers (a wide character's two).
    public var cells: Int
    public var foreground: UInt32
    public var background: UInt32
    public var underline: Bool
    /// Only spaces: its background, nothing drawn on it.
    public var blank: Bool
  }
  public var rows: [[Run]] = []
  /// The lines shown (the screen's, or some of the scrollback's above).
  public var lines: [[Cell]] = []
  public var cursor: (x: Int, y: Int)?
  public init() {}
}

public enum TerminalView {
  /// The rows shown (the screen's, or some of the scrollback's above),
  /// as runs of one look; rows whose cells are as last time keep their
  /// runs (M6m: a frame's snapshot costs only what changed).
  public static func snapshot(of s: Screen, scrolledBack: Int, palette: TerminalPalette,
                              reusing last: TerminalSnapshot = TerminalSnapshot()) -> TerminalSnapshot
  {
    var shown: [[Cell]] = []
    let back = min(scrolledBack, s.scrollback.count)
    if back > 0 { shown += s.scrollback.suffix(back) }
    shown += s.lines.prefix(s.rows - min(back, s.rows))
    if shown.count > s.rows { shown = Array(shown.prefix(s.rows)) }
    var out = TerminalSnapshot()
    out.rows.reserveCapacity(shown.count)
    for (i, line) in shown.enumerated() {
      // (Unchanged lines share their storage: compared at once.)
      if i < last.lines.count && i < last.rows.count && last.lines[i] == line {
        out.rows.append(last.rows[i])
        continue
      }
      var runs: [TerminalSnapshot.Run] = []
      for (x, c) in line.enumerated() where c.width != 0 {
        var fg = palette.rgb(c.foreground, foreground: true), bg = palette.rgb(c.background, foreground: false)
        if c.attributes.contains(.inverse) { swap(&fg, &bg) }
        if c.attributes.contains(.hidden) { fg = bg }
        let blank = c.scalar == 0 || c.scalar == 0x20
        let underline = c.attributes.contains(.underline)
        if var last = runs.last, last.foreground == fg, last.background == bg, last.underline == underline,
          last.column + last.cells == x
        {
          last.cells += Int(c.width)
          last.blank = last.blank && blank
          runs[runs.count - 1] = last
        } else {
          runs.append(.init(column: x, cells: Int(c.width), foreground: fg, background: bg, underline: underline, blank: blank))
        }
      }
      out.rows.append(runs)
    }
    out.lines = shown
    out.cursor = back == 0 && s.cursorVisible ? (s.cursorX, s.cursorY) : nil
    return out
  }

  /// The runs' backgrounds, each cell's character (and its combining mark)
  /// in its own place from the glyph cache (no shaping: a grid), the
  /// underlines, and the cursor.
  public static func draw(_ snap: TerminalSnapshot, in r: Rect, cell: CellMetrics, style: Style,
                          palette: TerminalPalette, into p: inout Painter)
  {
    let x0 = r.x + style.padding.left, y0 = r.y + style.padding.top
    // The face resolved once for every cell (M6m).
    guard let grid = p.gridFace(style) else { return }
    for (y, runs) in snap.rows.enumerated() {
      let top = y0 + Float(y) * cell.height
      let line = snap.lines[y]
      for run in runs {
        let x = x0 + Float(run.column) * cell.width
        let w = Float(run.cells) * cell.width
        if run.background != palette.background { p.fill(x, top, w, cell.height, 0xFF00_0000 | run.background) }
        if !run.blank {
          var column = run.column
          while column < run.column + run.cells && column < line.count {
            let c = line[column]
            // On a whole pixel (M6m): a letter is rasterized once, whatever
            // its column (a cell's width isn't whole pixels).
            let cx = Float(Int((x0 + Float(column) * cell.width) * p.scale + 0.5)) / p.scale
            if c.scalar > 0x20 {
              p.glyph(c.scalar, cx, top, grid, style, color: 0xFF00_0000 | run.foreground)
              if c.mark != 0 { p.glyph(c.mark, cx, top, grid, style, color: 0xFF00_0000 | run.foreground) }
            }
            column += max(Int(c.width), 1)
          }
        }
        if run.underline { p.fill(x, top + cell.height - 2, w, 1, 0xFF00_0000 | run.foreground) }
      }
    }
    if let c = snap.cursor {
      // A block, the character under it drawn in the background's colour.
      let x = x0 + Float(c.x) * cell.width, top = y0 + Float(c.y) * cell.height
      p.fill(x, top, cell.width, cell.height, 0xFF00_0000 | palette.cursor)
      if c.y < snap.lines.count && c.x < snap.lines[c.y].count {
        let under = snap.lines[c.y][c.x]
        if under.scalar > 0x20 { p.glyph(under.scalar, x, top, grid, style, color: 0xFF00_0000 | palette.background) }
      }
    }
  }
}
