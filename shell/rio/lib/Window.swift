// SPDX-License-Identifier: BSD-3-Clause

// A rio window as a Kit app (rio(1)): its text in UICore's text area, in
// the theme's `terminal` part (`terminal.holding` in hold mode). Keys and
// typed text go to the window's text (WindowText), never to the area,
// which keeps the pointer's: the caret, the selection, the wheel. What the
// keys send goes to the window's files; their output comes from them before
// each frame. A right-click's Route plumbs the selection, or the word at
// the caret, from the window's directory. While kbd is open, keys go there
// (bin/rio's), and none reaches the text.

import Kit

@MainActor public final class RioWindow: App {
  public var text = WindowText()
  public let files: WindowFiles
  /// The window's keys changed its text: it needs a frame (the session's).
  public var changed: (() -> Void)?
  /// Delete was typed: its programs are interrupted (bin/rio's note).
  public var interrupt: (() -> Void)?
  /// Its text's version when `text` last read it.
  var shownVersion = -1

  public init(files: WindowFiles) { self.files = files }

  public var title: String { files.label }
  public var actions: [ActionHandler] { [] }

  /// What the window's programs wrote, at the output point; raw and hold
  /// mode as consctl set them.
  public func prepare(width: Float, height: Float) {
    let (output, modes) = files.take()
    if let m = modes {
      if m.raw && !text.raw { deliver(text.rawOn()) } else { text.raw = m.raw }
      if !m.holding && text.holding { deliver(text.release()) } else { text.holding = m.holding }
    }
    text.write(output)
    if text.document.version != shownVersion {
      shownVersion = text.document.version
      files.show(utf8(text.scalars(from: TextPosition(line: 0, column: 0), to: text.end)))
    }
  }

  public var body: Group { Group([TextView(window: self)]) }

  /// Keys and text in the order they came: the window's text takes them all.
  public func takeInput(_ f: FrameInput) -> Bool {
    if files.kbdOpen { return true }
    let items = f.sequence.isEmpty ? f.keys.map { InputItem.key($0) } + (f.text.isEmpty ? [] : [.text(f.text)]) : f.sequence
    var sent: [Sent] = []
    let before = (text.document.version, text.document.caret, text.document.anchor, text.holding)
    for item in items {
      switch item {
      case .key(let k):
        // Characters typed come as text too; with Control or Alt, only here.
        switch k.key {
        case .character where !k.control && !k.alt: continue
        case .space where !k.control: continue
        default: sent += text.key(k)
        }
      case .text(let t): sent += text.type(t)
      }
    }
    deliver(sent)
    if before != (text.document.version, text.document.caret, text.document.anchor, text.holding) { changed?() }
    return true
  }

  func deliver(_ sent: [Sent]) {
    guard !sent.isEmpty else { return }
    files.send(sent)
    if sent.contains(.interrupt) { interrupt?() }
  }

  /// Route sends the selection, or the word at the caret, from wdir.
  public func route(subject: String) -> Route? {
    subject.isEmpty ? nil : Route(wdir: files.wdir, data: subject)
  }
}

/// The window's text, in the text area, with its context menu.
struct TextView: View {
  let window: RioWindow

  func build(_ c: inout BuildContext, id: String) {
    let key = UI.key(id, in: c.ui.openKey)
    if c.ui.focus == 0 { c.ui.focus(on: key) }
    var d = window.text.document
    c.ui.textArea(id, document: &d, class: window.text.holding ? "terminal.holding" : "terminal", label: "Text",
                  width: .percent(1), height: .percent(1))
    // Only the pointer's changes: the caret and the selection.
    window.text.document.caret = window.text.document.clampedPosition(d.caret)
    window.text.document.anchor = window.text.document.clampedPosition(d.anchor)
    let f = c.ui.frameInput
    if f.secondaryPressed, let r = c.ui.lastRect(key: key), r.contains(f.pointerX, f.pointerY) {
      c.ui.openContextMenu("text", subject: window.text.subject)
    }
    c.ui.contextMenu("text", items: [])
  }
}
