// SPDX-License-Identifier: BSD-3-Clause

// A page for a terminal (man(1)): refilled to a width, indented as Plan 9's
// pages are, NAME made from the header and SOURCE from `src`. Links print
// as written, so `rc(1)` in the output is still what the plumber knows;
// `{label|target}` prints as `label (target)`.

import Directives

public enum Render {
  static let indent = 5, sub = 3, hang = 10

  /// The page, or its node `node` alone, refilled to `width` columns.
  public static func text(_ page: Page, node: [UInt8]? = nil, width: Int = 80) throws(GuideError) -> [UInt8] {
    var f = Fill(width: width)
    let h = page.header
    var on = node == nil, found = false
    var source = node == nil && !h.sources.isEmpty
    if on {
      title(&f, h)
      f.newline()
      f.put(Array("NAME".utf8))
      f.newline()
      name(&f, h)
    }
    // NAME ends as a paragraph does: whatever follows it is set apart.
    var previous: Block.Kind? = on ? .paragraph : nil
    var widths: [Int] = []
    for (i, b) in page.blocks.enumerated() {
      if b.kind == .node, let node {
        if on { break }  // the next node: the one asked for has ended
        on = b.node == node
        found = on
        previous = nil
      }
      guard on else { continue }
      if b.kind == .heading && source && isLate(b.text) {
        f.newline()
        sourceSection(&f, h)
        source = false
      }
      let heading = b.kind == .node || b.kind == .heading || b.kind == .subheading
      let afterHeading = previous == .heading || previous == .subheading || previous == .node
      let rowRun = b.kind == .row && i > 0 && page.blocks[i - 1].kind == .row && page.blocks[i - 1].line + 1 == b.line
      let joined = (afterHeading && !heading) || (b.kind == .item && previous == .item) || rowRun
      if !joined && previous != nil { f.newline() }
      switch b.kind {
      case .node: f.heading(0, b.title, upper: true)
      case .heading: f.heading(0, b.text, upper: false)
      case .subheading: f.heading(sub, b.text, upper: false)
      case .paragraph: f.paragraph(indent, b.text)
      case .item:
        f.spaces(indent)
        f.put(Array("- ".utf8))
        f.bol = true
        f.paragraph(indent + 2, b.text)
      case .definition:
        f.lead = indent
        f.inline(b.text)
        f.flush()
        if b.body.isEmpty {
          f.newline()
        } else {
          if f.col + 2 <= hang {  // a short term: its description on its line
            f.spaces(hang - f.col)
            f.bol = true
          } else {
            f.newline()
          }
          f.paragraph(hang, b.body)
        }
      case .row:
        if !rowRun { widths = columnWidths(page.blocks, from: i) }
        f.row(b.text, widths)
      case .fence:
        for line in Directives.lines(b.text) {
          if !line.isEmpty {
            f.spaces(indent)
            f.put(line)
          }
          f.newline()
        }
      }
      previous = b.kind
    }
    if let node, !found {
      throw GuideError("\(h.page)(\(h.section)): no node '\(String(decoding: node, as: UTF8.self))'")
    }
    if source {
      f.newline()
      sourceSection(&f, h)
    }
    return f.out
  }

  /// What Plan 9's order puts after SOURCE.
  static func isLate(_ heading: [UInt8]) -> Bool {
    heading == Array("SEE ALSO".utf8) || heading == Array("DIAGNOSTICS".utf8) || heading == Array("BUGS".utf8)
  }

  /// `LS(1)` at each end of the line.
  static func title(_ f: inout Fill, _ h: Header) {
    let t = h.page.utf8.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 } + Array("(\(h.section))".utf8)
    f.put(t)
    if 2 * t.count + 1 <= f.width {
      f.spaces(f.width - 2 * t.count)
      f.put(t)
    }
    f.newline()
  }

  static func name(_ f: inout Fill, _ h: Header) {
    f.lead = indent
    for (i, n) in h.names.enumerated() {
      if i > 0 { f.add([0x2C]) }  // ,
      f.flush()
      f.add(Array(n.utf8))
    }
    f.flush()
    f.add(Array("—".utf8))
    f.words(Array(h.summary.utf8), joinFirst: false)
    f.flush()
    f.newline()
  }

  static func sourceSection(_ f: inout Fill, _ h: Header) {
    f.put(Array("SOURCE".utf8))
    f.newline()
    for s in h.sources {
      f.spaces(indent)
      f.put(Array(s.utf8))
      f.newline()
    }
  }

  /// The widths of the run of rows starting at `blocks[from]`.
  static func columnWidths(_ blocks: [Block], from: Int) -> [Int] {
    var w: [Int] = []
    var i = from
    while i < blocks.count && blocks[i].kind == .row && (i == from || blocks[i - 1].line + 1 == blocks[i].line) {
      for (k, cell) in Inline.cells(blocks[i].text).enumerated() {
        let c = columns(Fill.cell(cell))
        if k == w.count { w.append(c) } else if c > w[k] { w[k] = c }
      }
      i += 1
    }
    return w
  }
}

/// Columns: one per character (each byte that doesn't continue one).
func columns(_ s: [UInt8]) -> Int { s.count { $0 & 0xC0 != 0x80 } }

/// Text filled into lines.
struct Fill {
  let width: Int
  var out: [UInt8] = []
  /// Where a new line's first word starts.
  var lead = 0
  var col = 0
  /// Nothing written on this line since its start (or its marker).
  var bol = true
  var word: [UInt8] = []

  init(width: Int) { self.width = width }

  mutating func put(_ s: [UInt8]) {
    out += s
    col += columns(s)
  }

  mutating func spaces(_ n: Int) {
    guard n > 0 else { return }
    put([UInt8](repeating: 0x20, count: n))
  }

  mutating func newline() {
    out.append(0x0A)
    col = 0
    bol = true
  }

  /// Writes the word being built, on a new line if it doesn't fit.
  mutating func flush() {
    guard !word.isEmpty else { return }
    let n = columns(word)
    if !bol && col + 1 + n > width { newline() }
    if bol && col < lead { spaces(lead - col) }
    if !bol { put([0x20]) }
    put(word)
    bol = false
    word = []
  }

  mutating func add(_ s: [UInt8]) { word += s }

  /// Text with its whitespace runs as single spaces, each a place to break.
  mutating func words(_ s: [UInt8], joinFirst: Bool) {
    var join = joinFirst
    var i = 0
    while i < s.count {
      if isSpace(s[i]) {
        while i < s.count && isSpace(s[i]) { i += 1 }
        if i < s.count { flush() }
        continue
      }
      if !join { flush() }
      join = true
      var j = i
      while j < s.count && !isSpace(s[j]) { j += 1 }
      add(Array(s[i..<j]))
      i = j
    }
  }

  /// A block's inline text, filled. Page has checked its spans.
  mutating func inline(_ s: [UInt8]) {
    for sp in (try? Inline.spans(s)) ?? [] {
      switch sp.kind {
      case .space: flush()
      case .literal:  // one word that never breaks, its whitespace runs single spaces
        for (i, c) in sp.text.enumerated() where !(isSpace(c) && i > 0 && isSpace(sp.text[i - 1])) {
          add([isSpace(c) ? 0x20 : c])
        }
      case .link:
        words(sp.label, joinFirst: true)
        if sp.labelled {
          flush()
          add([0x28] + sp.target + [0x29])
        }
      case .text, .parameter, .reference: add(sp.text)
      }
    }
  }

  mutating func paragraph(_ lead: Int, _ s: [UInt8]) {
    self.lead = lead
    inline(s)
    flush()
    if col > 0 { newline() }
  }

  /// A heading at `lead`: as written, or (a node's title) in capitals.
  mutating func heading(_ lead: Int, _ s: [UInt8], upper: Bool) {
    guard upper else { return paragraph(lead, s) }
    self.lead = lead
    words(s.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }, joinFirst: false)
    flush()
    newline()
  }

  mutating func row(_ row: [UInt8], _ widths: [Int]) {
    spaces(Render.indent)
    var pad = 0
    for (k, cell) in Inline.cells(row).enumerated() {
      let text = Fill.cell(cell)
      if k > 0 { spaces(pad + 2) }
      put(text)
      let c = columns(text)
      pad = k < widths.count && widths[k] > c ? widths[k] - c : 0
    }
    newline()
  }

  /// A table cell on one line.
  static func cell(_ cell: [UInt8]) -> [UInt8] {
    var f = Fill(width: Int.max)
    f.inline(cell)
    f.flush()
    return f.out
  }
}
