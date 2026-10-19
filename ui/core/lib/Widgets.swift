// SPDX-License-Identifier: BSD-3-Clause

// The kit's widgets (M6i part 3): a scroll box, a list, and a single-line
// text field, over the immediate-mode core.
//
// - A scroll box clips its children and moves them up by an offset it
//   keeps by key; the wheel over it scrolls it, within its content.
// - A list builds only the rows in view (the rest are space), each a row
//   of the table's cells; a click selects one. Selection is the caller's.
// - A text field edits the caller's string: its caret and the selection's
//   other end are kept by key, and move between grapheme clusters
//   (UAX #29), by words with Control (UAX #29's word boundaries); typing
//   replaces the selection; Backspace and Delete remove a cluster; a click
//   places the caret at the nearest boundary, a drag selects; an IME's
//   preedit is shown, underlined, at the caret until it's committed. The
//   caret doesn't blink: a steady caret costs no wakeups.

import AccessTree
import TDUnicode

/// What a text field did this frame.
public struct FieldSignal: Sendable {
  /// The text changed.
  public var changed = false
  /// Enter was pressed in it.
  public var submitted = false
  public var focused = false
}

extension UI {
  // MARK: Scrolling

  /// Opens a scroll box (closed by `close()`): its children clipped to it
  /// and moved by its offsets, which the wheel over it changes (Shift and
  /// the wheel, or a horizontal wheel, across). Gives the offset and the
  /// height it showed last frame (0 before its first), for a view that
  /// builds only the rows in view.
  ///
  /// Be's scrollbars (M6l): where the content is taller (or wider) than
  /// the box, a bar at its right (or bottom), in room the box keeps for it:
  /// an arrow at each end (a line a click), the track (a page a click),
  /// and a thumb as long as the share shown, dragged.
  @discardableResult
  public mutating func openScroll(_ id: String, class name: String = "default", width: Size = .grow(),
                                  height: Size = .grow()) -> (offset: Float, view: Float)
  {
    let b = scrollBox(id, class: name, width: width, height: height)
    return (b.offset, b.view)
  }

  /// `openScroll`'s box, with more flags (`.clickable`: its ground is
  /// pressed), its signal and both offsets.
  mutating func scrollBox(_ id: String, class name: String, width: Size, height: Size, flags: BoxFlags = [])
    -> (signal: Signal, offset: Float, offsetX: Float, view: Float)
  {
    let key = UI.hash(parentKey, id)
    let bar = Theme.cqw(1), line = Theme.cqw(3)
    var offset: Float = 0, offsetX: Float = 0, view: Float = 0
    var bars: (vertical: Bool, horizontal: Bool) = (false, false)
    var last = Rect(x: 0, y: 0, width: 0, height: 0)
    var content: (height: Float, width: Float) = (0, 0)
    if let s = slot(key) {
      last = slots[s].rect
      content = (slots[s].content, slots[s].contentWidth)
      bars = UI.bars(rect: last, content: content)
      let viewH = last.height - (bars.horizontal ? bar : 0), viewW = last.width - (bars.vertical ? bar : 0)
      view = viewH
      offset = slots[s].scroll
      offsetX = slots[s].scrollX
      // The wheel, when this is where it goes (the innermost box under the
      // pointer that can move that way); Shift turns it across.
      let across = input.shift && input.scrollX == 0
      if key == wheelTarget.y && !across { offset += input.scroll }
      if key == wheelTarget.x { offsetX += across ? input.scroll : input.scrollX }
      // The bars' input, from last frame's places.
      let keys = (vthumb: UI.hash(parentKey, id + ".vthumb"), hthumb: UI.hash(parentKey, id + ".hthumb"))
      if bars.vertical {
        offset = scrollbar(key, ".v", along: false, at: ((last.x + last.width) - bar, last.y), length: viewH, bar: bar, line: line,
                           view: viewH, content: content.height, offset: offset, thumb: keys.vthumb)
      }
      if bars.horizontal {
        offsetX = scrollbar(key, ".h", along: true, at: (last.x, (last.y + last.height) - bar), length: viewW, bar: bar, line: line,
                            view: viewW, content: content.width, offset: offsetX, thumb: keys.hthumb)
      }
      offset = min(max(0, offset), max(0, content.height - viewH))
      offsetX = min(max(0, offsetX), max(0, content.width - viewW))
      // On whole pixels (M6m): a scroll moves the content by whole pixels,
      // so text keeps where it falls within a pixel and is drawn from the
      // text cache, not shaped again.
      let k = painter.scale
      offset = Float(Int(offset * k + 0.5)) / k
      offsetX = Float(Int(offsetX * k + 0.5)) / k
      slots[s].scroll = offset
      slots[s].scrollX = offsetX
    }
    // The bars first, floating beside the box (not in it: its content is
    // clipped short of them), at last frame's places.
    if bars.vertical {
      drawBar(id + ".v", along: false, at: ((last.x + last.width) - bar, last.y),
              length: last.height - (bars.horizontal ? bar : 0), bar: bar, view: view, content: content.height,
              offset: offset)
    }
    if bars.horizontal {
      drawBar(id + ".h", along: true, at: (last.x, (last.y + last.height) - bar), length: last.width - (bars.vertical ? bar : 0),
              bar: bar, view: last.width - (bars.vertical ? bar : 0), content: content.width, offset: offsetX)
    }
    let signal = open(id, class: name, width: width, height: height, axis: .vertical, flags: flags.union(.clip))
    let me = boxes.count - 1
    boxes[me].scrollY = offset
    boxes[me].scrollX = offsetX
    // Room for the bars.
    if bars.vertical { boxes[me].style.padding.right += bar }
    if bars.horizontal { boxes[me].style.padding.bottom += bar }
    boxes[me].barInset = (bars.vertical ? bar : 0, bars.horizontal ? bar : 0)
    boxes[me].scroller = true
    return (signal, offset, offsetX, view)
  }

  /// A scrollbar of its own, in the flow, for content that isn't boxes (a
  /// terminal's scrollback): `offset` (0 at the start) over `content`, of
  /// which `view` is shown, kept by the caller, and moved by the bar (an
  /// arrow a `line`, the track a page, the thumb dragged). A bar's width
  /// across (1cqw), the room it's given along. True if it moved `offset`.
  @discardableResult
  public mutating func scrollbar(_ id: String, vertical: Bool = true, view: Float, content: Float, offset: inout Float,
                                 line: Float = Theme.cqw(3)) -> Bool
  {
    let bar = Theme.cqw(1)
    let key = UI.hash(parentKey, id)
    let tag = id + (vertical ? ".v" : ".h")
    let before = offset
    // Last frame's place: where the parts go, and what the pointer meets.
    if let s = slot(key) {
      let r = slots[s].rect
      let length = vertical ? r.height : r.width
      offset = scrollbar(key, tag, along: !vertical, at: (r.x, r.y), length: length, bar: bar, line: line, view: view,
                         content: content, offset: offset, thumb: UI.hash(parentKey, tag + "thumb"))
      offset = min(max(0, offset), max(0, content - view))
    }
    // Its parts need its place: a frame more the first time.
    let placed = slot(key) != nil
    if !placed { settling = true }
    box(id, width: vertical ? .pixels(bar) : .grow(), height: vertical ? .grow() : .pixels(bar))
    if placed, let s = slot(key) {
      let r = slots[s].rect
      drawBar(tag, along: !vertical, at: (r.x, r.y), length: vertical ? r.height : r.width, bar: bar, view: view,
              content: content, offset: offset)
    }
    return offset != before
  }

  /// A row's width: its columns', when they're wider than the rows' box
  /// showed last frame (so it scrolls across, its background with it),
  /// else the box's.
  func columnsWidth(_ scrollKey: UInt64, _ widths: [Float]) -> Size {
    let total = widths.reduce(0, +)
    guard let s = slot(scrollKey) else { return .percent(1) }
    let tall = slots[s].content > slots[s].rect.height + 0.5
    let room = slots[s].rect.width - (tall ? Theme.cqw(1) : 0)
    return room > 0 && total > room ? .pixels(total) : .percent(1)
  }

  /// Opens a table's header row (closed by `close()`): clipped, and moved
  /// across with the rows' scroll box `following`.
  mutating func openHeader(_ id: String, following scrollKey: UInt64) {
    open(id, width: .percent(1), height: .children(), axis: .horizontal, flags: [.clip])
    if let s = slot(scrollKey) { boxes[boxes.count - 1].scrollX = slots[s].scrollX }
  }

  /// Which bars a scroll box of `rect` shows: one where the content
  /// overflows; one bar may make room for the other.
  static func bars(rect: Rect, content: (height: Float, width: Float)) -> (vertical: Bool, horizontal: Bool) {
    let bar = Theme.cqw(1)
    var vertical = content.height > rect.height + 0.5
    let horizontal = content.width > rect.width - (vertical ? bar : 0) + 0.5
    if horizontal && !vertical { vertical = content.height > rect.height - bar + 0.5 }
    return (vertical, horizontal)
  }

  /// A bar's thumb: where it starts along the track and how long it is.
  func thumb(length: Float, bar: Float, view: Float, content: Float, offset: Float) -> (start: Float, size: Float) {
    let track = max(length - 2 * bar, 1)
    let size = max(min(track * view / max(content, 1), track), min(Theme.cqw(2), track))
    let range = max(content - view, 1)
    return (bar + (track - size) * min(max(offset / range, 0), 1), size)
  }

  /// A bar's input (last frame's boxes): the arrows a line, the track a
  /// page toward the pointer, the thumb dragged. The offset now.
  mutating func scrollbar(_ owner: UInt64, _ tag: String, along x: Bool, at origin: (Float, Float), length: Float,
                          bar: Float, line: Float, view: Float, content: Float, offset: Float, thumb key: UInt64) -> Float
  {
    var offset = offset
    let pointer = x ? input.pointerX : input.pointerY
    let start = x ? origin.0 : origin.1
    let t = thumb(length: length, bar: bar, view: view, content: content, offset: offset)
    let inBar = x ? input.pointerY >= origin.1 && input.pointerY < origin.1 + bar && pointer >= start && pointer < start + length
      : input.pointerX >= origin.0 && input.pointerX < origin.0 + bar && pointer >= start && pointer < start + length
    if input.pressed && inBar {
      let at = pointer - start
      if at < bar {
        offset -= line
      } else if at >= length - bar {
        offset += line
      } else if at >= t.start && at < t.start + t.size {
        // The thumb: a drag from here.
        active = key
        if let s = slot(key) {
          slots[s].scroll = pointer
          slots[s].content = offset
        }
      } else {
        offset += at < t.start ? -view : view
      }
    } else if active == key && input.down, let s = slot(key) {
      let track = max(length - 2 * bar - t.size, 1)
      offset = slots[s].content + (pointer - slots[s].scroll) * max(content - view, 0) / track
    }
    return offset
  }

  /// A bar's boxes, floating: its track, its arrows (drawn triangles) and
  /// its thumb.
  mutating func drawBar(_ tag: String, along x: Bool, at origin: (Float, Float), length: Float, bar: Float, view: Float,
                        content: Float, offset: Float)
  {
    let t = thumb(length: length, bar: bar, view: view, content: content, offset: offset)
    func at(_ along: Float) -> (Float, Float) { x ? (origin.0 + along, origin.1) : (origin.0, origin.1 + along) }
    func size(_ along: Float) -> (Size, Size) { x ? (.pixels(along), .pixels(bar)) : (.pixels(bar), .pixels(along)) }
    let (tw, th) = size(length)
    box(tag + "track", class: "scrollbar", width: tw, height: th, flags: [.background], at: at(0))
    accessible(.group, label: x ? "horizontal scrollbar" : "vertical scrollbar")
    let (aw, ah) = size(bar)
    let ink = theme.style("scrollbar.arrow").ink
    for (name, along, forward) in [("less", Float(0), false), ("more", length - bar, true)] {
      box(tag + name, class: "scrollbar.arrow", width: aw, height: ah, flags: [.background], at: at(along))
      custom(tag + name + ".glyph", width: aw, height: ah, at: at(along)) { p, r in
        // A triangle pointing along the bar, a third of the bar across.
        let n = Int(r.width / 3), cx = r.x + r.width / 2, cy = r.y + r.height / 2
        for k in 0..<max(n, 1) {
          let half = Float(k) + 0.5, d = Float(k) - Float(n) / 2
          if x {
            let colX = forward ? cx - d - 1 : cx + d
            p.fill(colX, cy - half, 1, 2 * half, ink)
          } else {
            let rowY = forward ? cy - d - 1 : cy + d
            p.fill(cx - half, rowY, 2 * half, 1, ink)
          }
        }
      }
    }
    let held = active == UI.hash(parentKey, tag + "thumb")
    let (mw, mh) = size(t.size)
    box(tag + "thumb", class: held ? "scrollbar.thumb.held" : "scrollbar.thumb", width: mw, height: mh,
        flags: [.background, .clickable], at: at(t.start))
    accessible(.button, label: x ? "horizontal scroll thumb" : "vertical scroll thumb")
  }

  /// Scrolls scroll box `id` (a child of the box open now, before it's
  /// opened) to `offset`, clamped when it opens; false if it hasn't been
  /// laid out yet (ask again next frame).
  @discardableResult
  public mutating func scroll(_ id: String, to offset: Float) -> Bool {
    guard let s = slot(UI.hash(parentKey, id)), slots[s].rect.height > 0 else { return false }
    slots[s].scroll = max(0, offset)
    return true
  }

  /// A scroll box's offset (its key's), as of now.
  public func scrollOffset(_ id: String, in parent: UInt64) -> Float {
    slot(UI.hash(parent, id)).map { slots[$0].scroll } ?? 0
  }

  // MARK: Lists

  /// A list of `count` rows, `rowHeight` each, under its column headers
  /// (if any), in a scroll box: only the rows in view are built (`row`
  /// gives each row's cells; `state` a row's class beyond selection, as
  /// "new" for one that just arrived); clicking a row selects it.
  public mutating func list(_ id: String, label: String = "", count: Int, rowHeight: Float, columns: [String] = [],
                            widths: [Float], numeric: [Bool] = [], selection: inout Int?,
                            state: (Int) -> String = { _ in "" }, row: (Int) -> [String])
  {
    let scrollKey = UI.hash(parentKey, id)
    let rowWidth = columnsWidth(scrollKey, widths)
    if !columns.isEmpty {
      // The headers, then the storyboard's rule under them; the headers
      // follow the rows across (M6l).
      openHeader(id + ".header", following: scrollKey)
      for (c, name) in columns.enumerated() {
        let w = c < widths.count ? widths[c] : 0
        box("h\(c)", class: "table.header", text: name, width: .pixels(w), height: .text(), flags: [.text])
        accessible(.columnHeader)
      }
      close()
      box(id + ".rule", class: "table.rule", width: .percent(1), height: .pixels(1), flags: [.background])
    }
    openScroll(id)
    accessible(.list, label: label.isEmpty ? id : label)
    let key = boxes[boxes.count - 1].key
    let offset = boxes[boxes.count - 1].scrollY
    let view = slot(key).map { slots[$0].rect.height } ?? 0
    let stride = rowHeight + 1  // a row and its rule
    let first = max(0, Int(offset / stride))
    let visible = view > 0 ? Int(view / stride) + 2 : count  // (no libm in tier 0: a row more, not ceil)
    let last = min(count, first + visible)
    box("before", width: .pixels(0), height: .pixels(Float(first) * stride))
    for r in first..<last {
      let extra = state(r)
      let state = selection == r ? "table.cell.selected" : extra.isEmpty ? "table.cell" : "table.cell." + extra
      let rowClass = "table.row" + state.dropFirst("table.cell".count)
      let s = open("r\(r)", class: rowClass, width: rowWidth, height: .pixels(rowHeight), axis: .horizontal,
                   flags: [.clickable, .background])
      if s.clicked || s.pressed { selection = r }
      accessible(.row, states: selection == r ? .selected : [])
      for (c, text) in row(r).enumerated() {
        let w = c < widths.count ? widths[c] : 0
        let right = c < numeric.count && numeric[c] && (text.unicodeScalars.first?.properties.numericType != nil)
        let style = theme.style(state)
        let shown = painter.elide(text, style, width: max(0, w - style.padding.left - style.padding.right))
        box("c\(c)", class: state, text: shown, width: .pixels(w), height: .percent(1),
            flags: right ? [.text, .end] : [.text])
        // The reader hears the whole text, not what fits.
        accessible(.cell, label: text)
      }
      close()
      box("rule\(r)", class: "table.rule.row", width: rowWidth, height: .pixels(1), flags: [.background])
    }
    box("after", width: .pixels(0), height: .pixels(Float(count - last) * (rowHeight + 1)))
    close()
  }

  // MARK: Text fields

  /// A single-line text field editing `text`, in class `name` (focused:
  /// `name.focused`); `secure`, a password's: bullets shown, no value
  /// for readers.
  @discardableResult
  public mutating func textField(_ id: String, text: inout String, class name: String = "field",
                                 label: String = "", width: Size = .grow(), secure: Bool = false) -> FieldSignal
  {
    let key = UI.hash(parentKey, id)
    var result = FieldSignal()
    var scalars = text.unicodeScalars.map { $0.value }
    let style = theme.style(name)
    // The pointer: a press focuses and places the caret; a drag selects.
    let lastRect = slot(key).map { slots[$0].rect }
    var caret = slot(key).map { min(slots[$0].caret, scalars.count) } ?? scalars.count
    var anchor = slot(key).map { min(slots[$0].anchor, scalars.count) } ?? caret
    func boundary(at px: Float) -> Int {
      guard let r = lastRect else { return scalars.count }
      let local = px - r.x - style.padding.left
      let shown = secure ? scalars.map { _ in UInt32(0x2022) } : scalars
      return painter.carets(shown, style).min { abs($0.x - local) < abs($1.x - local) }?.index ?? scalars.count
    }
    if input.pressed, let r = lastRect, r.contains(input.pointerX, input.pointerY) {
      focus = key
      caret = boundary(at: input.pointerX)
      anchor = caret
    } else if input.down && active == key, lastRect != nil {
      caret = boundary(at: input.pointerX)
    }
    result.focused = focus == key
    declareUndo()
    declareEditing()
    // Undo and Redo, while it has focus: its own history's.
    var undone = false
    var deleted = false
    if result.focused {
      let h = history(key)
      for (name, back) in [("edit.undo", true), ("edit.redo", false)] {
        while take(name) != nil {
          guard let s = back ? fieldHistories[h].stack.undo() : fieldHistories[h].stack.redo() else { continue }
          (scalars, caret, anchor) = (s.text, s.caret, s.anchor)
          fieldHistories[h].kind = 0
          result.changed = true
          undone = true
        }
      }
    }
    let before = FieldState(text: scalars, caret: caret, anchor: anchor)
    if result.focused {
      let bounds = Segmentation.graphemeBoundaries(scalars)
      let words = Segmentation.wordBoundaries(scalars)
      func previous(_ i: Int, _ set: [Int]) -> Int { set.last { $0 < i } ?? 0 }
      func next(_ i: Int, _ set: [Int]) -> Int { set.first { $0 > i } ?? scalars.count }
      // A word's start: a word boundary that isn't followed by a space.
      func previousWord(_ i: Int) -> Int {
        var j = previous(i, words)
        while j > 0 && j < scalars.count && scalars[j] == 0x20 { j = previous(j, words) }
        return j
      }
      func nextWord(_ i: Int) -> Int {
        var j = next(i, words)
        while j < scalars.count && scalars[j - 1] == 0x20 && j > i + 1 { j = next(j, words) }
        return j
      }
      func deleteSelection() -> Bool {
        guard caret != anchor else { return false }
        let lo = min(caret, anchor), hi = max(caret, anchor)
        scalars.removeSubrange(lo..<hi)
        caret = lo
        anchor = lo
        result.changed = true
        deleted = true
        return true
      }
      for k in input.keys {
        switch k.key {
        case .left:
          caret = k.control ? previousWord(caret) : (caret != anchor && !k.shift ? min(caret, anchor) : previous(caret, bounds))
          if !k.shift { anchor = caret }
        case .right:
          caret = k.control ? nextWord(caret) : (caret != anchor && !k.shift ? max(caret, anchor) : next(caret, bounds))
          if !k.shift { anchor = caret }
        case .home:
          caret = 0
          if !k.shift { anchor = caret }
        case .end:
          caret = scalars.count
          if !k.shift { anchor = caret }
        case .backspace:
          if !deleteSelection() && caret > 0 {
            let p = k.control ? previousWord(caret) : previous(caret, Segmentation.graphemeBoundaries(scalars))
            scalars.removeSubrange(p..<caret)
            caret = p
            anchor = p
            result.changed = true
            deleted = true
          }
        case .delete:
          if !deleteSelection() && caret < scalars.count {
            let n = k.control ? nextWord(caret) : next(caret, Segmentation.graphemeBoundaries(scalars))
            scalars.removeSubrange(caret..<n)
            anchor = caret
            result.changed = true
            deleted = true
          }
        case .character(0x61) where k.control:
          anchor = 0
          caret = scalars.count
        case .enter:
          result.submitted = true
        default:
          break
        }
      }
      // Cut, Copy and Paste: a secure field's text never leaves it, and a
      // paste's newlines are spaces in one line.
      var pasted = ""
      if let board = clipboard {
        let lo = min(caret, anchor), hi = max(caret, anchor)
        let selected = String(String.UnicodeScalarView(scalars[lo..<hi].compactMap { Unicode.Scalar($0) }))
        while take("edit.copy") != nil { if lo < hi && !secure { board.write(selected) } }
        while take("edit.cut") != nil {
          if lo < hi && !secure {
            board.write(selected)
            _ = deleteSelection()
          }
        }
        while take("edit.paste") != nil {
          pasted += String(String.UnicodeScalarView((board.read() ?? "").unicodeScalars.map {
            $0.value == 0x0A || $0.value == 0x0D ? " " : $0
          }))
        }
      }
      if !input.text.isEmpty || !pasted.isEmpty {
        _ = deleteSelection()
        let typed = (input.text + pasted).unicodeScalars.map { $0.value }
        scalars.insert(contentsOf: typed, at: caret)
        caret += typed.count
        anchor = caret
        result.changed = true
      }
    }
    // The edit, on its history: typing joins the run it continues (the
    // caret where the last edit left it, the same kind, no word ended),
    // as deleting does.
    if result.changed && !undone && result.focused {
      let h = history(key)
      let typed = !input.text.isEmpty
      let kind = typed ? 1 : 2
      var f = fieldHistories[h]
      let continues = f.kind == kind && f.caret == before.caret && before.caret == before.anchor
        && !(kind == 1 && f.wordEnded) && !(typed && deleted)
      if !continues {
        nextGroup += 1
        f.group = nextGroup
      }
      f.stack.record(kind == 1 ? "Typing" : "Deletion", before: before,
                     after: FieldState(text: scalars, caret: caret, anchor: anchor), group: f.group)
      f.kind = kind
      f.caret = caret
      f.wordEnded = typed && (input.text.unicodeScalars.last.map { $0.value == 0x20 } ?? false)
      fieldHistories[h] = f
    } else if result.focused && !undone, let h = fieldHistories.firstIndex(where: { $0.key == key }),
      fieldHistories[h].caret != caret
    {
      // The caret moved: the next edit starts a run of its own.
      fieldHistories[h].kind = 0
    }
    if result.changed {
      var s = ""
      s.unicodeScalars.append(contentsOf: scalars.compactMap { Unicode.Scalar($0) })
      text = s
    }
    // The box: the field's frame, and its content drawn over it after
    // layout (the selection, the text, the preedit, the caret).
    let classes = result.focused ? name + ".focused" : name
    let frame = theme.style(classes)
    open(id, class: classes, width: width, height: .pixels(frame.padding.top + painter.lineHeight(frame) + frame.padding.bottom),
         axis: .horizontal, flags: [.clickable, .background, .focusable, .clip, .editable])
    // A secure field's value is no reader's.
    accessible(.textField, label: label.isEmpty ? id : label, value: secure ? "" : text)
    close()
    if let s = slot(key) {
      slots[s].caret = caret
      slots[s].anchor = anchor
    }
    // A secure field (a password) shows a bullet a character.
    let shown = secure ? scalars.map { _ in UInt32(0x2022) } : scalars, preedit = result.focused ? input.preedit : ""
    let carets = painter.carets(shown, frame)
    let selection = theme.style(name + ".selection"), caretStyle = theme.style(name + ".caret")
    let (c, a, focused) = (caret, anchor, result.focused)
    func x(_ i: Int) -> Float { carets.last { $0.index <= i }?.x ?? 0 }
    let (cx, ax) = (x(c), x(a))
    drawers.append((key, { p, r in
      let tx = r.x + frame.padding.left, ty = r.y + frame.padding.top, lh = p.lineHeight(frame)
      if c != a { p.fill(tx + min(cx, ax), ty, abs(cx - ax), lh, selection.fill) }
      var line = ""
      line.unicodeScalars.append(contentsOf: shown.compactMap { Unicode.Scalar($0) })
      // The text before the caret, the preedit (underlined), the rest.
      if preedit.isEmpty {
        p.text(line, tx, ty, frame)
      } else {
        let before = String(line.unicodeScalars.prefix(c)), after = String(line.unicodeScalars.dropFirst(c))
        p.text(before, tx, ty, frame)
        let pw = p.text(preedit, tx + cx, ty, frame)
        p.fill(tx + cx, ty + lh - 1.5, pw, 1, frame.ink)
        p.text(after, tx + cx + pw, ty, frame)
      }
      if focused { p.fill(tx + cx - 0.75, ty, 1.5, lh, caretStyle.fill) }
    }))
    return result
  }
}
