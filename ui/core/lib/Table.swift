// SPDX-License-Identifier: BSD-3-Clause

// A table and an icon field (M6j part 3c: Tracker's list and icon views,
// board 01). The table is the list's kind (only the rows in view built,
// in a scroll box) with what a file manager needs: the row's icon before
// its first cell, rows selected by the caller (any number), headers that
// can be clicked (to sort), one row's first cell a text field (renaming
// in place), and a row brought into view (the keyboard's). The icon field
// puts icons with their labels where the caller says, and reports a drag
// of one. Both report what the pointer did and leave the selection, the
// order and the places to the caller.

import AccessTree

/// A table's row, as the caller has it.
public struct TableRow: Sendable {
  public var cells: [String]
  /// Before the first cell (board 01's folder, document, PDF).
  public var icon: IconRef?
  /// Its class beyond "table.cell": "", "selected" or "new".
  public var state: String
  public init(cells: [String], icon: IconRef? = nil, state: String = "") {
    self.cells = cells
    self.icon = icon
    self.state = state
  }
}

/// What the pointer did to a table, or an icon field, this frame.
public struct TableEvents: Sendable {
  /// A header clicked.
  public var header: Int? = nil
  /// Rows (icons) the pointer did something to, and what.
  public var rows: [(row: Int, signal: Signal)] = []
  /// The space past the rows (the field's ground), pressed: a click
  /// there clears the selection.
  public var background = Signal()
  /// The rename field's.
  public var edit = FieldSignal()
  /// An icon dragged and let go: which, and by how much.
  public var dropped: (row: Int, dx: Float, dy: Float)? = nil
  public init() {}
}

extension UI {
  /// A table of `count` rows under `columns`' headers (`sort`'s column's
  /// header marked ↑ or ↓); `editing`'s first cell is a text field over
  /// `editText`; `reveal` is scrolled into view.
  public mutating func table(_ id: String, label: String = "", count: Int, rowHeight: Float, columns: [String],
                             widths: [Float], numeric: [Bool] = [], sort: (column: Int, descending: Bool)? = nil,
                             editing: Int? = nil, editText: inout String, reveal: Int? = nil,
                             row: (Int) -> TableRow) -> TableEvents
  {
    var events = TableEvents()
    open(id, width: .percent(1), height: .grow(), axis: .vertical)
    let scrollKey = UI.hash(parentKey, "rows")
    let rowWidth = columnsWidth(scrollKey, widths)
    // The headers, then the storyboard's rule under them; the headers
    // follow the rows across (M6l).
    openHeader(id + ".header", following: scrollKey)
    for (c, name) in columns.enumerated() {
      let w = c < widths.count ? widths[c] : 0
      let mark = sort.map { $0.column == c ? ($0.descending ? " ↓" : " ↑") : "" } ?? ""
      let s = box("h\(c)", class: "table.header", text: name + mark, width: .pixels(w), height: .text(),
                  flags: [.text, .clickable])
      accessible(.columnHeader, label: name)
      if s.clicked { events.header = c }
    }
    close()
    box(id + ".rule", class: "table.rule", width: .percent(1), height: .pixels(1), flags: [.background])
    let stride = rowHeight + 1  // a row and its rule
    // Bring `reveal` into view, before the box reads its offset.
    if let r = reveal, let s = slot(scrollKey) {
      let top = Float(r) * stride, view = slots[s].rect.height
      if top < slots[s].scroll { slots[s].scroll = top }
      if view > 0 && top + stride > slots[s].scroll + view { slots[s].scroll = top + stride - view }
    }
    openScroll("rows")
    accessible(.list, label: label.isEmpty ? id : label)
    let key = boxes[boxes.count - 1].key
    let offset = boxes[boxes.count - 1].scrollY
    let view = slot(key).map { slots[$0].rect.height } ?? 0
    let first = max(0, Int(offset / stride))
    let visible = view > 0 ? Int(view / stride) + 2 : count
    let last = min(count, first + visible)
    box("before", width: .pixels(0), height: .pixels(Float(first) * stride))
    for r in first..<last {
      let it = row(r)
      let cellClass = it.state.isEmpty ? "table.cell" : "table.cell." + it.state
      let rowClass = "table.row" + (it.state.isEmpty ? "" : "." + it.state)
      let s = open("r\(r)", class: rowClass, width: rowWidth, height: .pixels(rowHeight), axis: .horizontal,
                   flags: [.clickable, .background])
      if s.pressed || s.clicked || s.secondaryPressed || s.doubleClicked { events.rows.append((r, s)) }
      accessible(.row, states: it.state == "selected" ? .selected : [])
      let style = theme.style(cellClass)
      for (c, text) in it.cells.enumerated() {
        let w = c < widths.count ? widths[c] : 0
        if c == 0, let icon = it.icon {
          let size = Theme.cqw(1.35), lead = style.padding.left
          custom("icon", width: .pixels(lead + size + Theme.cqw(0.4)), height: .percent(1)) { p, rect in
            p.icon(icon.name, rect.x + lead, rect.y + (rect.height - size) / 2, size: size, color: icon.color,
                   emblem: icon.emblem)
          }
          let rest = max(0, w - lead - size - Theme.cqw(0.4))
          if editing == r {
            // The field has the keys while it's open.
            let field = UI.hash(parentKey, "edit")
            if focus != field { focus = field }
            events.edit = textField("edit", text: &editText, class: "field", label: "Name", width: .pixels(rest))
          } else {
            let shown = painter.elide(text, style, width: max(0, rest - style.padding.right))
            box("c0", class: cellClass, text: shown, width: .pixels(rest), height: .percent(1), flags: [.text])
          }
          accessible(.cell, label: text)
          continue
        }
        let right = c < numeric.count && numeric[c] && (text.unicodeScalars.first?.properties.numericType != nil)
        let shown = painter.elide(text, style, width: max(0, w - style.padding.left - style.padding.right))
        box("c\(c)", class: cellClass, text: shown, width: .pixels(w), height: .percent(1),
            flags: right ? [.text, .end] : [.text])
        // The reader hears the whole text, not what fits.
        accessible(.cell, label: text)
      }
      close()
      box("rule\(r)", class: "table.rule.row", width: rowWidth, height: .pixels(1), flags: [.background])
    }
    box("after", width: .pixels(0), height: .pixels(Float(count - last) * stride))
    // The space under the rows: a press there is the ground's.
    events.background = box("ground", width: .percent(1), height: .grow(), flags: [.clickable])
    close()
    close()
    return events
  }

  /// An icon field: `count` icons at the places `item` gives (the top left
  /// of each one's column, in the field's logical pixels), each with its
  /// label; a selected one glows. An icon pressed and dragged follows the
  /// pointer, and its drop is reported (`dropped`), not kept: the caller
  /// moves it.
  /// `mini`: Be's mini icons (M6l), each a small icon with its name
  /// beside it, `IconField.mini` big.
  public mutating func iconField(_ id: String, label: String = "", count: Int, mini: Bool = false,
                                 item: (Int) -> (icon: IconRef, label: String, x: Float, y: Float, selected: Bool))
    -> TableEvents
  {
    var events = TableEvents()
    // A scroll box (M6l): icons placed past its edges are reached by its
    // bars and the wheels.
    let b = scrollBox(id, class: "icons", width: .percent(1), height: .grow(), flags: [.clickable])
    events.background = b.signal
    accessible(.list, label: label.isEmpty ? id : label)
    let field = boxes[boxes.count - 1].key
    let origin = slot(field).map { (slots[$0].rect.x - b.offsetX, slots[$0].rect.y - b.offset) } ?? (0, 0)
    let column = mini ? IconField.mini.width : Theme.cqw(7)
    let height = mini ? IconField.mini.height : Theme.cqw(3.8) + Theme.cqw(0.3) + Theme.cqw(1.6)
    for i in 0..<count {
      let it = item(i)
      let key = UI.hash(field, "i\(i)")
      // Dragged: drawn where the pointer has taken it.
      var (x, y) = (it.x, it.y)
      if active == key && input.down, let p = dragFrom {
        x += input.pointerX - p.x
        y += input.pointerY - p.y
      }
      let (icon, text, selected) = (it.icon, it.label, it.selected)
      let sig = custom("i\(i)", width: .pixels(column), height: .pixels(height), flags: [.clickable],
                       at: (origin.0 + x, origin.1 + y)) { p, r in
        if mini {
          IconField.drawMini(&p, r, icon, text, selected: selected)
        } else {
          Chrome.desktopIcon(&p, r.x, r.y, icon, label: p.elide(text, p.theme.style("desktop.icon"), width: r.width),
                             selected: selected)
        }
      }
      accessible(.row, label: text, states: selected ? .selected : [])
      if sig.pressed { dragFrom = (input.pointerX, input.pointerY) }
      if sig.pressed || sig.clicked || sig.secondaryPressed || sig.doubleClicked { events.rows.append((i, sig)) }
      if input.released && releasedFrom == key, let p = dragFrom {
        let dx = input.pointerX - p.x, dy = input.pointerY - p.y
        if abs(dx) > 2 || abs(dy) > 2 { events.dropped = (i, dx, dy) }
        dragFrom = nil
      }
    }
    close()
    return events
  }
}

/// The icon field's sizes and its mini icons (M6l).
public enum IconField {
  /// A mini icon's cell: its icon and its name beside it.
  public static let mini = (width: Theme.cqw(12), height: Theme.cqw(1.9))

  /// A mini icon: the icon at its cell's left, its name after it, a
  /// selected one in the table's selected row's colours.
  static func drawMini(_ p: inout Painter, _ r: Rect, _ icon: IconRef, _ text: String, selected: Bool) {
    let style = p.theme.style(selected ? "table.cell.selected" : "table.cell")
    if selected { p.shape(r.x, r.y, r.width, r.height, p.theme.style("table.row.selected")) }
    let size = Theme.cqw(1.35), lead = Theme.cqw(0.3)
    p.icon(icon.name, r.x + lead, r.y + (r.height - size) / 2, size: size, color: icon.color, emblem: icon.emblem)
    let x = r.x + lead + size + Theme.cqw(0.4)
    let shown = p.elide(text, style, width: max(0, r.x + r.width - x - lead))
    _ = p.text(shown, x, r.y + (r.height - p.lineHeight(style)) / 2, style)
  }
}
