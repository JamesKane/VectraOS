// SPDX-License-Identifier: BSD-3-Clause

// A multi-line text area (M6m part m1: the text editor's): a document of
// lines, edited as the single-line field is (caret and selection by
// grapheme cluster, words with Control, IME preedit, its own undo stack
// with typing joined by word) plus what lines add: Up and Down keeping
// the column's x, Page Up and Down, Control-Home and End, Enter splitting
// a line and deletion joining two. It's a scroll box as tall and wide as
// the document, with Be's bars, and draws only the lines in view; the
// caret is kept in view as it moves.

import TDUnicode

/// A place in a document: its line, and its scalar there.
public struct TextPosition: Equatable, Comparable, Sendable {
  public var line: Int
  public var column: Int
  public init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }
  public static func < (a: TextPosition, b: TextPosition) -> Bool {
    a.line != b.line ? a.line < b.line : a.column < b.column
  }
}

/// A text area's document: its lines (scalars, no newlines), the caret
/// and the selection's other end. The program owns it; the area edits
/// it. Its lines share storage until one changes, so a copy (an undo
/// step's) is cheap.
public struct TextDocument: Sendable {
  public var lines: [[UInt32]]
  public var caret = TextPosition(line: 0, column: 0)
  public var anchor = TextPosition(line: 0, column: 0)
  /// Bumped by every change to the text (not the caret's): a program
  /// compares it to know its document changed (a modified mark).
  public internal(set) var version = 0

  public init(_ text: String = "") {
    var lines: [[UInt32]] = [[]]
    for u in text.unicodeScalars {
      if u.value == 0x0A {
        lines.append([])
      } else if u.value != 0x0D {
        lines[lines.count - 1].append(u.value)
      }
    }
    self.lines = lines
  }

  /// The whole text, its lines joined by newlines.
  public var text: String {
    var s = ""
    for (i, l) in lines.enumerated() {
      if i > 0 { s.unicodeScalars.append("\n") }
      s.unicodeScalars.append(contentsOf: l.compactMap { Unicode.Scalar($0) })
    }
    return s
  }

  public var hasSelection: Bool { caret != anchor }

  /// The selection's text.
  public var selectedText: String {
    let (lo, hi) = (min(caret, anchor), max(caret, anchor))
    var s = ""
    for l in lo.line...hi.line {
      let from = l == lo.line ? lo.column : 0, to = l == hi.line ? hi.column : lines[l].count
      if l > lo.line { s.unicodeScalars.append("\n") }
      s.unicodeScalars.append(contentsOf: lines[l][from..<to].compactMap { Unicode.Scalar($0) })
    }
    return s
  }

  /// Replaces the selection (or inserts at the caret) with `scalars`,
  /// newlines splitting lines; the caret after them.
  public mutating func replaceSelection(_ scalars: [UInt32]) {
    let (lo, hi) = (min(caret, anchor), max(caret, anchor))
    let head = Array(lines[lo.line][..<lo.column]), tail = Array(lines[hi.line][hi.column...])
    var pieces: [[UInt32]] = [[]]
    for s in scalars where s != 0x0D {
      if s == 0x0A { pieces.append([]) } else { pieces[pieces.count - 1].append(s) }
    }
    let end = TextPosition(line: lo.line + pieces.count - 1,
                           column: (pieces.count == 1 ? head.count : 0) + pieces[pieces.count - 1].count)
    pieces[0] = head + pieces[0]
    pieces[pieces.count - 1] += tail
    lines.replaceSubrange(lo.line...hi.line, with: pieces)
    caret = end
    anchor = end
    version += 1
  }

  /// Replaces the selection with `text`.
  public mutating func replaceSelection(_ text: String) { replaceSelection(text.unicodeScalars.map { $0.value }) }

  /// Selects everything.
  public mutating func selectAll() {
    anchor = TextPosition(line: 0, column: 0)
    caret = TextPosition(line: lines.count - 1, column: lines[lines.count - 1].count)
  }

  /// A position clamped into the document.
  public func clampedPosition(_ p: TextPosition) -> TextPosition { clamped(p) }

  func clamped(_ p: TextPosition) -> TextPosition {
    let line = min(max(p.line, 0), lines.count - 1)
    return TextPosition(line: line, column: min(max(p.column, 0), lines[line].count))
  }
}

/// What a text area did this frame.
public struct TextAreaSignal: Sendable {
  public var changed = false
  public var focused = false
  public init() {}
}

/// A text area's undo history (its stack, and the run its last edit was
/// in, as a field's) and the column's x that Up and Down keep.
struct AreaHistory: Sendable {
  var key: UInt64
  var stack = UndoStack<TextDocument>()
  var kind = 0
  var caret = TextPosition(line: -1, column: -1)
  var wordEnded = false
  var group: UInt64 = 0
  var goalX: Float? = nil
  var frame: UInt64 = 0
  /// Where the caret was last frame: one the program moved is shown too.
  var lastCaret = TextPosition(line: -1, column: -1)
  /// Whether the caret has been shown since the area was laid out (a file
  /// opened at a route's line shows it at once).
  var shown = false
}

extension UI {
  /// A multi-line text area editing `document`, in class `name` (its
  /// lines' style; focused, `name.focused`), filling what it's given.
  @discardableResult
  public mutating func textArea(_ id: String, document: inout TextDocument, class name: String = "editor",
                                label: String = "", width: Size = .grow(), height: Size = .grow()) -> TextAreaSignal
  {
    let key = UI.hash(parentKey, id)
    let style = theme.style(name)
    let lh = painter.lineHeight(style)
    var result = TextAreaSignal()
    let last = slot(key).map { slots[$0].rect }
    let scroll = slot(key).map { (slots[$0].scrollX, slots[$0].scroll) } ?? (0, 0)
    // Where the pointer is in the document.
    func position(_ px: Float, _ py: Float) -> TextPosition {
      guard let r = last else { return document.caret }
      let line = min(max(Int((py - r.y - style.padding.top + scroll.1) / lh), 0), document.lines.count - 1)
      let x = px - r.x - style.padding.left + scroll.0
      let column = painter.carets(document.lines[line], style).min { abs($0.x - x) < abs($1.x - x) }?.index ?? 0
      return TextPosition(line: line, column: column)
    }
    let barRoom = Theme.cqw(1)
    let inside = last.map { input.pointerX < $0.x + $0.width - barRoom && input.pointerY < $0.y + $0.height - barRoom } ?? false
    if input.pressed, let r = last, r.contains(input.pointerX, input.pointerY), inside {
      focus = key
      document.caret = position(input.pointerX, input.pointerY)
      if !input.shift { document.anchor = document.caret }
      active = key
    } else if input.down && active == key {
      document.caret = position(input.pointerX, input.pointerY)
    }
    result.focused = focus == key
    declareUndo()
    let h = areaHistory(key)
    var undone = false
    if result.focused {
      for (action, back) in [("edit.undo", true), ("edit.redo", false)] {
        while take(action) != nil {
          guard let d = back ? areaHistories[h].stack.undo() : areaHistories[h].stack.redo() else { continue }
          document = d
          areaHistories[h].kind = 0
          result.changed = true
          undone = true
        }
      }
    }
    let before = document
    var moved = false, typed = false, deleted = false
    if result.focused {
      let lines = document.lines
      func line(_ p: TextPosition) -> [UInt32] { lines[p.line] }
      func previous(_ p: TextPosition, words: Bool) -> TextPosition {
        if p.column == 0 { return p.line == 0 ? p : TextPosition(line: p.line - 1, column: lines[p.line - 1].count) }
        let set = words ? Segmentation.wordBoundaries(line(p)) : Segmentation.graphemeBoundaries(line(p))
        var j = set.last { $0 < p.column } ?? 0
        if words { while j > 0 && line(p)[j] == 0x20 { j = set.last { $0 < j } ?? 0 } }
        return TextPosition(line: p.line, column: j)
      }
      func next(_ p: TextPosition, words: Bool) -> TextPosition {
        if p.column >= line(p).count {
          return p.line + 1 >= lines.count ? p : TextPosition(line: p.line + 1, column: 0)
        }
        let set = words ? Segmentation.wordBoundaries(line(p)) : Segmentation.graphemeBoundaries(line(p))
        var j = set.first { $0 > p.column } ?? line(p).count
        // A word's end: spaces crossed don't count as a word.
        if words { while j < line(p).count && line(p)[j - 1] == 0x20 { j = set.first { $0 > j } ?? line(p).count } }
        return TextPosition(line: p.line, column: j)
      }
      func x(_ p: TextPosition) -> Float { painter.carets(line(p), style).last { $0.index <= p.column }?.x ?? 0 }
      func column(at x: Float, line l: Int) -> Int {
        painter.carets(lines[l], style).min { abs($0.x - x) < abs($1.x - x) }?.index ?? 0
      }
      let page = max(1, Int(((last?.height ?? lh * 10) - barRoom) / lh) - 1)
      var goal = areaHistories[h].goalX
      for k in input.keys {
        var to: TextPosition? = nil
        var vertical = false
        switch k.key {
        case .left:
          to = document.hasSelection && !k.shift ? min(document.caret, document.anchor) : previous(document.caret, words: k.control)
        case .right:
          to = document.hasSelection && !k.shift ? max(document.caret, document.anchor) : next(document.caret, words: k.control)
        case .up, .down, .pageUp, .pageDown:
          let by = k.key == .up ? -1 : k.key == .down ? 1 : k.key == .pageUp ? -page : page
          let gx = goal ?? x(document.caret)
          goal = gx
          let l = min(max(document.caret.line + by, 0), lines.count - 1)
          to = l == document.caret.line && by < 0 ? TextPosition(line: 0, column: 0)
            : l == document.caret.line && by > 0 ? TextPosition(line: l, column: lines[l].count)
            : TextPosition(line: l, column: column(at: gx, line: l))
          vertical = true
        case .home:
          to = k.control ? TextPosition(line: 0, column: 0) : TextPosition(line: document.caret.line, column: 0)
        case .end:
          to = k.control ? TextPosition(line: lines.count - 1, column: lines[lines.count - 1].count)
            : TextPosition(line: document.caret.line, column: lines[document.caret.line].count)
        case .backspace, .delete:
          if !document.hasSelection {
            document.anchor = k.key == .backspace ? previous(document.caret, words: k.control)
              : next(document.caret, words: k.control)
          }
          if document.hasSelection {
            document.replaceSelection([UInt32]())
            deleted = true
          }
        case .enter:
          document.replaceSelection([UInt32(0x0A)])
          typed = true
        case .character(0x61) where k.control:
          document.selectAll()
        default:
          break
        }
        if let to {
          document.caret = to
          if !k.shift { document.anchor = to }
          moved = true
        }
        if !vertical { goal = nil }
      }
      if !input.text.isEmpty {
        document.replaceSelection(input.text)
        typed = true
        goal = nil
      }
      areaHistories[h].goalX = goal
    }
    let changedText = document.version != before.version
    if changedText { result.changed = true }
    // The edit, on its history: typing joins the run it continues, as a
    // field's does; deleting likewise.
    if changedText && !undone {
      let kind = typed && !deleted ? 1 : 2
      var f = areaHistories[h]
      let continues = f.kind == kind && f.caret == before.caret && !before.hasSelection && !(kind == 1 && f.wordEnded)
      if !continues {
        nextGroup += 1
        f.group = nextGroup
      }
      f.stack.record(kind == 1 ? "Typing" : "Deletion", before: before, after: document, group: f.group)
      f.kind = kind
      f.caret = document.caret
      f.wordEnded = typed && (input.text.unicodeScalars.last.map { $0.value == 0x20 || $0.value == 0x0A } ?? true)
      areaHistories[h] = f
    } else if moved && !undone {
      areaHistories[h].kind = 0
    }
    areaHistories[h].frame = frame
    // (The program moved the caret, as a route's line does: shown too.)
    let programMoved = areaHistories[h].lastCaret != before.caret && areaHistories[h].lastCaret.line >= 0
    areaHistories[h].lastCaret = document.caret

    // The box: a scroll box as big as the document.
    let classes = result.focused ? name + ".focused" : name
    let frameStyle = theme.style(classes)
    var widest: Float = 0
    for l in document.lines where l.count > 0 {
      // (An estimate a line, from its length: measuring every line each
      // frame would cost what drawing them does.)
      widest = max(widest, Float(l.count) * style.textSize * 0.62)
    }
    let contentHeight = Float(document.lines.count) * lh
    _ = scrollBox(id, class: classes, width: width, height: height, flags: [.clickable, .background, .focusable, .editable])
    accessible(.textField, label: label.isEmpty ? id : label, value: document.text)
    box("content", width: .pixels(widest + style.padding.left + style.padding.right + Theme.cqw(1)),
        height: .pixels(contentHeight + style.padding.top + style.padding.bottom))
    close()
    // Keep the caret in view after a key moved it or text came.
    if (result.focused && (moved || changedText) || programMoved || !areaHistories[h].shown), let r = last,
      let s = slot(key)
    {
      areaHistories[h].shown = true
      let caretY = Float(document.caret.line) * lh
      let viewH = r.height - style.padding.top - style.padding.bottom - barRoom
      if caretY < slots[s].scroll { slots[s].scroll = caretY }
      if caretY + lh > slots[s].scroll + viewH { slots[s].scroll = caretY + lh - viewH }
      let cx = painter.carets(document.lines[document.caret.line], style).last { $0.index <= document.caret.column }?.x ?? 0
      let viewW = r.width - style.padding.left - style.padding.right - barRoom
      if cx < slots[s].scrollX { slots[s].scrollX = max(0, cx - Theme.cqw(2)) }
      if cx > slots[s].scrollX + viewW { slots[s].scrollX = cx - viewW + Theme.cqw(2) }
      // On whole pixels, as a scroll box's (the text cache's lines keep
      // where they fall within a pixel).
      let k = painter.scale
      slots[s].scroll = Float(Int(slots[s].scroll * k + 0.5)) / k
      slots[s].scrollX = Float(Int(slots[s].scrollX * k + 0.5)) / k
      // Moved after this frame was built: a frame more shows it.
      if slots[s].scroll != scroll.1 || slots[s].scrollX != scroll.0 { settling = true }
    }
    // The lines in view, the selection, the preedit and the caret, drawn
    // over the box after layout.
    guard let r = last else { return result }
    let first = max(0, Int(scroll.1 / lh)), count = Int(r.height / lh) + 2
    let shownLines = Array(document.lines[first..<min(document.lines.count, first + count)])
    let (caret, anchor, focused) = (document.caret, document.anchor, result.focused)
    let preedit = focused ? input.preedit : ""
    let selection = theme.style(name + ".selection"), caretStyle = theme.style(name + ".caret")
    let offset = scroll
    let caretXs = painter.carets(document.lines[caret.line], style)
    drawers.append((key, { p, rect in
      // Each line on whole pixels (M6m): wherever it's scrolled, it falls
      // the same within a pixel, so it's drawn from the text cache.
      let k = p.scale
      func whole(_ v: Float) -> Float { Float(Int(v * k + (v >= 0 ? 0.5 : -0.5))) / k }
      let tx = whole(rect.x + style.padding.left - offset.0), top = rect.y + style.padding.top - offset.1
      let (lo, hi) = (min(caret, anchor), max(caret, anchor))
      for (i, l) in shownLines.enumerated() {
        let n = first + i
        let y = whole(top + Float(n) * lh)
        if lo != hi && n >= lo.line && n <= hi.line {
          let xs = p.carets(l, style)
          func x(_ c: Int) -> Float { xs.last { $0.index <= c }?.x ?? 0 }
          let x0 = n == lo.line ? x(lo.column) : 0
          let x1 = n == hi.line ? x(hi.column) : x(l.count) + style.textSize * 0.3
          p.fill(tx + x0, y, max(x1 - x0, 1), lh, selection.fill)
        }
        if n == caret.line && !preedit.isEmpty {
          let cx = caretXs.last { $0.index <= caret.column }?.x ?? 0
          p.text(scalars: Array(l[..<caret.column]), tx, y, style)
          let pw = p.text(preedit, tx + cx, y, style)
          p.fill(tx + cx, y + lh - 1.5, pw, 1, style.ink)
          p.text(scalars: Array(l[caret.column...]), tx + cx + pw, y, style)
        } else if !l.isEmpty {
          // (The line's own scalars: drawn from the text cache, no String.)
          p.text(scalars: l, tx, y, style)
        }
      }
      if focused {
        let cx = caretXs.last { $0.index <= caret.column }?.x ?? 0
        p.fill(tx + cx - 0.75, whole(top + Float(caret.line) * lh), 1.5, lh, caretStyle.fill)
      }
    }))
    return result
  }

  mutating func areaHistory(_ key: UInt64) -> Int {
    if let i = areaHistories.firstIndex(where: { $0.key == key }) { return i }
    areaHistories.append(AreaHistory(key: key))
    return areaHistories.count - 1
  }
}
