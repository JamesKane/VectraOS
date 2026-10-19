// SPDX-License-Identifier: BSD-3-Clause

// A rio window's text (rio(1), D75, D107): plain text in UICore's
// TextDocument with rio's output point. What programs write goes in
// before the output point, which moves past it; what is typed goes after
// it, where it is edited, and is the programs' input once sent. In cooked
// mode a newline sends the lines typed, each a read of cons; ^D sends what
// is typed without one, or the end of input if nothing is. Hold mode
// (Escape) keeps lines until it is released; raw mode sends each key as it
// is typed, unechoed. Delete moves the output point past what was typed
// and interrupts. After 9front's rio (wind.c's wkeyctl), but typing with
// the caret before the output point types at the end, so the text before
// it is never edited.

import Kbdfs
import UICore

/// What a key gave the window's programs.
public enum Sent: Equatable, Sendable {
  /// A read's bytes: a line, what ^D sent, or a raw key's character.
  case input([UInt8])
  /// ^D on nothing typed: a read of nothing.
  case end
  /// Delete: an `interrupt` note to the window's programs.
  case interrupt
}

public struct WindowText: Sendable {
  public var document = TextDocument()
  /// The output point: text before it is what was shown (programs'
  /// output and lines sent), text after it what is being typed.
  public private(set) var output = TextPosition(line: 0, column: 0)
  /// Hold mode: newlines don't send until it is released.
  public var holding = false
  /// Raw mode (consctl's `rawon`): each key is sent as typed.
  public var raw = false
  /// In raw mode, the keys that move the caret are sent too, as kbdfs's
  /// runes (the window's surface is lent: rio's `mouseopen`).
  public var keyRunes = false
  /// The most lines kept: past it, the oldest before the output point go.
  public var limit = 10000

  public init() {}

  /// The text after the output point (being typed).
  public var typed: [UInt32] { scalars(from: output, to: end) }

  /// The document's end.
  public var end: TextPosition {
    TextPosition(line: document.lines.count - 1, column: document.lines[document.lines.count - 1].count)
  }

  /// The scalars from `a` to `b`, lines joined by newlines.
  public func scalars(from a: TextPosition, to b: TextPosition) -> [UInt32] {
    guard a < b else { return [] }
    var out: [UInt32] = []
    for l in a.line...b.line {
      let line = document.lines[l]
      let from = l == a.line ? a.column : 0, to = l == b.line ? b.column : line.count
      if l > a.line { out.append(0x0A) }
      out += line[from..<to]
    }
    return out
  }

  /// A program's output, shown at the output point, which moves past it;
  /// what is typed stays after it, the caret with it.
  public mutating func write(_ text: [UInt32]) {
    guard !text.isEmpty else { return }
    let (caret, anchor, o) = (document.caret, document.anchor, output)
    document.caret = o
    document.anchor = o
    document.replaceSelection(text)
    output = document.caret
    // Where something after the output point went.
    func moved(_ p: TextPosition) -> TextPosition {
      guard p >= o else { return p }
      if p.line != o.line { return TextPosition(line: p.line + output.line - o.line, column: p.column) }
      return TextPosition(line: output.line, column: output.column + p.column - o.column)
    }
    document.caret = moved(caret)
    document.anchor = moved(anchor)
    trim()
  }

  /// Text typed (or pasted) at the caret, replacing the selection: at the
  /// end if the caret or the selection is before the output point. In raw
  /// mode it is sent, unshown.
  public mutating func type(_ text: String) -> [Sent] {
    let scalars = text.unicodeScalars.map { $0.value }
    if raw { return scalars.isEmpty ? [] : [.input(utf8(scalars))] }
    var sent: [Sent] = []
    var run: [UInt32] = []
    // A newline typed sends, as Enter does.
    for s in scalars {
      if s == 0x0A {
        insert(run)
        run = []
        sent += newline()
      } else {
        run.append(s)
      }
    }
    insert(run)
    return sent
  }

  /// A key: an editing key, Enter, Delete, Escape, or a control
  /// character. Characters typed come through `type`.
  public mutating func key(_ k: KeyPress) -> [Sent] {
    if raw, let c = rawCharacter(k) { return [.input(utf8([c]))] }
    switch k.key {
    case .enter: return newline()
    case .tab:
      insert([0x09])
    case .backspace: erase(.character)
    case .delete:
      // Interrupt: what was typed stays, unsent; holding ends.
      holding = false
      output = end
      collapse(at: end)
      return [.interrupt]
    case .escape:
      holding.toggle()
      if !holding { return sendLines() }
    case .left, .right, .up, .down, .home, .end, .pageUp, .pageDown:
      move(k)
    case .character(let c) where k.control:
      switch c | 0x20 {
      case 0x75: erase(.line)  // ^U
      case 0x77: erase(.word)  // ^W
      case 0x68: erase(.character)  // ^H
      case 0x64: return endOfInput()  // ^D
      case 0x61:  // ^A: the line's start, or the output point
        let p = document.caret
        collapse(at: p.line == output.line && p >= output ? output : TextPosition(line: p.line, column: 0))
      case 0x65:  // ^E: the line's end
        collapse(at: TextPosition(line: document.caret.line, column: document.lines[document.caret.line].count))
      case 0x62: collapse(at: output)  // ^B: the output point
      default: break
      }
    default: break
    }
    return []
  }

  /// Hold mode released (Escape, or consctl's `holdoff`): the lines typed
  /// are sent.
  public mutating func release() -> [Sent] {
    holding = false
    return sendLines()
  }

  /// Raw mode turned on: what was typed is sent as it is (kbdfs's rawon).
  public mutating func rawOn() -> [Sent] {
    raw = true
    holding = false
    let t = typed
    guard !t.isEmpty else { return [] }
    output = end
    return [.input(utf8(t))]
  }

  /// The word at the caret, for plumbing: the run of non-blank
  /// characters there, without the brackets, quotes and punctuation
  /// around it; the selection, if there is one.
  public var subject: String {
    if document.hasSelection { return document.selectedText }
    let p = document.caret, line = document.lines[p.line]
    func blank(_ i: Int) -> Bool { line[i] == 0x20 || line[i] == 0x09 }
    var first = min(p.column, line.count), last = first
    while first > 0 && !blank(first - 1) { first -= 1 }
    while last < line.count && !blank(last) { last += 1 }
    var w = Array(line[first..<last])
    let around: [UInt32] = Array("()[]<>{}\"'`,;:.".unicodeScalars.map { $0.value })
    while let c = w.first, around.contains(c) { w.removeFirst() }
    while let c = w.last, around.contains(c) { w.removeLast() }
    return String(String.UnicodeScalarView(w.compactMap { Unicode.Scalar($0) }))
  }

  // MARK: Snarf, as rio's menu has it

  /// The selection's text, for Snarf and Cut.
  public var selected: String { document.hasSelection ? document.selectedText : "" }

  /// Cut: the selection goes, if it is all after the output point (what
  /// was shown stays: it is only snarfed).
  public mutating func cut() {
    guard document.hasSelection, min(document.caret, document.anchor) >= output else { return }
    document.replaceSelection([UInt32]())
  }

  /// Paste: `text` typed at the caret, as if typed (a newline in it sends).
  public mutating func paste(_ text: String) -> [Sent] { type(text) }

  /// Send: `text` typed at the end, with a newline if it has none, so it
  /// is sent.
  public mutating func send(_ text: String) -> [Sent] {
    guard !text.isEmpty else { return [] }
    collapse(at: end)
    return type(text.unicodeScalars.last?.value == 0x0A ? text : text + "\n")
  }

  // MARK: Editing

  enum Erase { case character, word, line }

  /// The caret, collapsed at `p`.
  mutating func collapse(at p: TextPosition) {
    document.caret = document.clampedPosition(p)
    document.anchor = document.caret
  }

  /// The caret where typing goes: the selection, if it is all after the
  /// output point; else the end.
  mutating func typingPlace() {
    if min(document.caret, document.anchor) < output { collapse(at: end) }
  }

  mutating func insert(_ scalars: [UInt32]) {
    guard !scalars.isEmpty else { return }
    typingPlace()
    document.replaceSelection(scalars)
  }

  /// ^H, ^W or ^U before the caret, never before the output point (rio's
  /// wbswidth): a character, the word with the spaces after it, the
  /// line typed.
  mutating func erase(_ kind: Erase) {
    typingPlace()
    if document.hasSelection {
      document.replaceSelection([UInt32]())
      return
    }
    let p = document.caret
    guard p > output else { return }
    let floor = p.line == output.line ? output.column : 0
    let line = document.lines[p.line]
    var c = p.column
    switch kind {
    case .character:
      if c == 0 {
        // The newline before, typed after the output point.
        document.anchor = TextPosition(line: p.line - 1, column: document.lines[p.line - 1].count)
        document.replaceSelection([UInt32]())
        return
      }
      c -= 1
    case .word:
      func alnum(_ s: UInt32) -> Bool {
        (s >= 0x30 && s <= 0x39) || ((s | 0x20) >= 0x61 && (s | 0x20) <= 0x7A) || s >= 0x80 || s == 0x5F
      }
      while c > floor && !alnum(line[c - 1]) { c -= 1 }
      while c > floor && alnum(line[c - 1]) { c -= 1 }
    case .line:
      c = floor
    }
    document.anchor = TextPosition(line: p.line, column: max(c, floor))
    document.replaceSelection([UInt32]())
  }

  mutating func move(_ k: KeyPress) {
    let p = document.caret, lines = document.lines
    var to = p
    switch k.key {
    case .left:
      to = p.column > 0 ? TextPosition(line: p.line, column: p.column - 1)
        : p.line > 0 ? TextPosition(line: p.line - 1, column: lines[p.line - 1].count) : p
    case .right:
      to = p.column < lines[p.line].count ? TextPosition(line: p.line, column: p.column + 1)
        : p.line + 1 < lines.count ? TextPosition(line: p.line + 1, column: 0) : p
    case .up, .pageUp:
      let by = k.key == .up ? 1 : 20
      to = TextPosition(line: max(p.line - by, 0), column: p.column)
    case .down, .pageDown:
      let by = k.key == .down ? 1 : 20
      to = TextPosition(line: min(p.line + by, lines.count - 1), column: p.column)
    case .home: to = TextPosition(line: 0, column: 0)
    case .end: to = end
    default: break
    }
    collapse(at: to)
  }

  // MARK: Sending

  /// Enter: a newline typed at the caret (at the end if the caret is
  /// before the output point), then the lines typed sent.
  mutating func newline() -> [Sent] {
    insert([0x0A])
    return sendLines()
  }

  /// The whole lines after the output point, each a read's, unless held.
  mutating func sendLines() -> [Sent] {
    guard !holding else { return [] }
    var sent: [Sent] = []
    var line: [UInt32] = []
    var through = output
    let t = typed
    var at = output
    for s in t {
      line.append(s)
      if s == 0x0A {
        at = TextPosition(line: at.line + 1, column: 0)
        sent.append(.input(utf8(line)))
        line = []
        through = at
      } else {
        at.column += 1
      }
    }
    output = through
    return sent
  }

  /// ^D: what was typed, without a newline, or the end of input.
  mutating func endOfInput() -> [Sent] {
    let t = typed
    output = end
    return t.isEmpty ? [.end] : [.input(utf8(t))]
  }

  /// The character a key sends in raw mode, as rio's waddraw has it:
  /// Enter's newline, Backspace's ^H, Delete's DEL, Escape, Tab, a
  /// control character; nil for an arrow, which moves the caret still,
  /// unless `keyRunes`, when it is its rune, as a function key is.
  func rawCharacter(_ k: KeyPress) -> UInt32? {
    if keyRunes {
      switch k.key {
      case .up: return KeyRune.up
      case .down: return KeyRune.down
      case .left: return KeyRune.left
      case .right: return KeyRune.right
      case .home: return KeyRune.home
      case .end: return KeyRune.end
      case .pageUp: return KeyRune.pgup
      case .pageDown: return KeyRune.pgdown
      case .function(let n): return KeyRune.f(UInt32(n))
      default: break
      }
    }
    switch k.key {
    case .enter: return 0x0A
    case .backspace: return 0x08
    case .delete: return 0x7F
    case .escape: return 0x1B
    case .tab: return 0x09
    case .space where k.control: return 0
    case .character(let c) where k.control:
      return (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A ? (c | 0x20) - 0x60 : nil
    default: return nil
    }
  }

  /// The oldest lines, once there are more than `limit`, if they are
  /// before the output point and the selection.
  mutating func trim() {
    guard document.lines.count > limit else { return }
    let cut = min(document.lines.count - limit * 4 / 5, output.line, min(document.caret, document.anchor).line)
    guard cut > 0 else { return }
    document.lines.removeFirst(cut)
    func up(_ p: TextPosition) -> TextPosition { TextPosition(line: p.line - cut, column: p.column) }
    output = up(output)
    document.caret = up(document.caret)
    document.anchor = up(document.anchor)
  }
}

/// UTF-8 for scalars.
func utf8(_ scalars: [UInt32]) -> [UInt8] {
  var s = String.UnicodeScalarView()
  s.append(contentsOf: scalars.compactMap { Unicode.Scalar($0) })
  return Array(String(s).utf8)
}
