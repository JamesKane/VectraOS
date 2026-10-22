// SPDX-License-Identifier: BSD-3-Clause

// guide's window (guide(4)): AmigaGuide's buttons, Contents, Index,
// Retrace and Browse's ◀ and ▶, over the place the viewer is at: the
// sections and their pages, the Index's words, or a page rendered as
// man(1) prints it, each `name(N)` in it a link. A link, a page in the
// Contents or a word in the Index only moves the viewer: nothing runs.

import Guide
import GuideViewer
import Kit
import UICore

/// What the window asks of its host: a page's bytes.
@MainActor public protocol GuideHost: AnyObject {
  func read(_ entry: ManualEntry) -> [UInt8]?
}

@MainActor public final class GuideApp: App {
  public weak var host: GuideHost?
  public let library: ManualLibrary
  public var viewer = ManualViewer()
  /// The page shown, rendered: its lines, kept until the place changes.
  var rendered: (place: ManualViewer.Place, lines: [[UInt8]])?
  /// The text's width, in columns.
  public var columns = 72

  public init(library: ManualLibrary, host: GuideHost?) {
    self.library = library
    self.host = host
  }

  public var title: String {
    switch viewer.place {
    case .contents: "Guide: Contents"
    case .index: "Guide: Index"
    case .page(let e): "Guide: " + e.title
    }
  }

  public var actions: [ActionHandler] { [] }

  /// Goes to the page a link names, if the manual has it; whether it did.
  @discardableResult
  public func follow(_ name: String, section: Int?) -> Bool {
    guard let e = library.find(name, section: section) else { return false }
    viewer.go(.page(e))
    return true
  }

  /// The page's lines, rendered for `columns`; a page that can't be read
  /// says so.
  public func lines(_ e: ManualEntry) -> [[UInt8]] {
    if let r = rendered, r.place == .page(e) { return r.lines }
    var text = Array("\(e.title): can't be read\n".utf8)
    if let bytes = host?.read(e), let page = try? Page(bytes, file: e.path),
      let out = try? Render.text(page, width: columns)
    {
      text = out
    }
    let lines = text.split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
    rendered = (.page(e), lines)
    return lines
  }

  public var body: Group { GuideView(app: self) }
}

struct GuideView: View {
  let app: GuideApp

  @MainActor func build(_ c: inout BuildContext, id: String) {
    let a = app
    let cq = Theme.cqw
    c.ui.open("guide", class: "pane", width: .percent(1), height: .children(), axis: .vertical, flags: [.background])
    // AmigaGuide's buttons.
    c.ui.open("buttons", width: .percent(1), height: .children(), axis: .horizontal)
    if c.ui.button("contents", "Contents") { a.viewer.go(.contents) }
    c.ui.box("g1", width: .pixels(cq(0.4)), height: .pixels(0))
    if c.ui.button("index", "Index") { a.viewer.go(.index) }
    c.ui.box("g2", width: .pixels(cq(0.4)), height: .pixels(0))
    if c.ui.button("retrace", "Retrace") { a.viewer.retrace() }
    c.ui.box("g3", width: .pixels(cq(0.4)), height: .pixels(0))
    if c.ui.button("previous", "◀ Browse") { a.viewer.browse(forward: false, in: a.library) }
    c.ui.box("g4", width: .pixels(cq(0.2)), height: .pixels(0))
    if c.ui.button("next", "Browse ▶") { a.viewer.browse(forward: true, in: a.library) }
    c.ui.close()
    c.ui.box("rule", class: "menu.rule", width: .percent(1), height: .pixels(1), flags: [.background])
    switch a.viewer.place {
    case .contents:
      for s in a.library.sections {
        c.ui.box("section.\(s)", class: "heading", text: "Section \(s)", flags: [.text])
        for e in a.library.pages(in: s) {
          c.ui.open("entry.\(e.path)", width: .percent(1), height: .children(), axis: .horizontal)
          let link = c.ui.box("name", class: "label.link", text: e.title, flags: [.text, .clickable, .focusable])
          c.ui.accessible(.button, label: e.title)
          c.ui.box("summary", class: "label.dim", text: "  " + e.summary, flags: [.text])
          c.ui.close()
          if link.clicked { a.viewer.go(.page(e)) }
        }
      }
    case .index:
      for (i, w) in a.library.index.enumerated() {
        c.ui.open("word.\(i)", width: .percent(1), height: .children(), axis: .horizontal)
        c.ui.box("word", class: "label", text: w.word + "  ", flags: [.text])
        let link = c.ui.box("page", class: "label.link", text: w.entry.title, flags: [.text, .clickable, .focusable])
        c.ui.accessible(.button, label: w.word + " " + w.entry.title)
        c.ui.close()
        if link.clicked { a.viewer.go(.page(w.entry)) }
      }
    case .page(let e):
      for (n, line) in a.lines(e).enumerated() {
        c.ui.open("line.\(n)", width: .percent(1), height: .children(), axis: .horizontal)
        var at = 0
        let links = ManualLinks.find(in: line)
        for (k, l) in links.enumerated() {
          if l.range.lowerBound > at {
            c.ui.box("t\(k)", class: "code.text", text: String(decoding: line[at..<l.range.lowerBound], as: UTF8.self),
                     flags: [.text])
          }
          let title = String(decoding: line[l.range], as: UTF8.self)
          let link = c.ui.box("l\(k)", class: "label.link", text: title, flags: [.text, .clickable, .focusable])
          c.ui.accessible(.button, label: title)
          if link.clicked { a.follow(l.name, section: l.section) }
          at = l.range.upperBound
        }
        let rest = at < line.count ? String(decoding: line[at...], as: UTF8.self) : " "
        c.ui.box("rest", class: "code.text", text: rest, flags: [.text])
        c.ui.close()
      }
    }
    c.ui.close()
  }
}
