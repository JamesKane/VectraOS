// SPDX-License-Identifier: BSD-3-Clause

// The windows of notices (notices(4), D117): the slips, a panel under the
// top edge left of Deskbar, the newest on top, each with its lamp in the
// theme's role for it, its app, title and body, dismissed by a click; and
// the drawer, a window with the clips, newest first (choosing one puts it
// on the clipboard again), and the notices posted. Its host feeds both
// and does what they ask.

import Kit
import Notices
import UICore

/// What the windows ask of their host.
@MainActor public protocol NoticesHost: AnyObject {
  /// Slip `id` clicked.
  func dismiss(_ id: Int)
  /// Clip `number` chosen: the clipboard's entry again.
  func paste(_ number: Int)
  /// Clip `number` forgotten.
  func forget(_ number: Int)
  /// Every clip forgotten.
  func clear()
}

/// A lamp's role in the theme.
public func lampRole(_ lamp: Lamp) -> String {
  switch lamp {
  case .info: return "selection"
  case .done: return "live"
  case .warn: return "warning"
  case .fail: return "alert"
  }
}

@MainActor public final class Slips: App {
  public weak var host: NoticesHost?
  /// The slips shown, newest first.
  public var notices: [Notice] = []

  public init(host: NoticesHost?) { self.host = host }

  public var title: String { "Notices" }
  public var actions: [ActionHandler] { [] }

  static let c = Theme.cqw
  /// The panel's width.
  public static var width: Float { c(18) }

  /// The panel's height for what it shows.
  public func height(_ painter: Painter) -> Float {
    let t = painter.theme
    let h = t.style("panel.heading"), l = t.style("label"), d = t.style("label.dim")
    let slip = h.padding.top + painter.lineHeight(h) + painter.lineHeight(l) + painter.lineHeight(d) + h.padding.bottom
    return Float(notices.count) * (slip + Self.c(0.6)) + Self.c(0.2)
  }

  public var body: Group { SlipsView(slips: self) }
}

struct SlipsView: View {
  let slips: Slips

  @MainActor func build(_ c: inout BuildContext, id: String) {
    let cq = Theme.cqw
    let theme = c.ui.theme
    c.ui.open("slips", width: .percent(1), height: .children(), axis: .vertical)
    for n in slips.notices {
      c.ui.box("gap.\(n.id)", width: .pixels(0), height: .pixels(cq(0.3)))
      let s = c.ui.open("slip.\(n.id)", class: "panel", width: .percent(1), height: .children(), axis: .horizontal,
                        flags: [.background, .clickable, .focusable])
      c.ui.accessible(.button, label: n.title, value: n.lamp.rawValue)
      let color = theme.color(lampRole(n.lamp))
      c.ui.custom("lamp", width: .pixels(cq(0.5)), height: .pixels(cq(3))) { p, r in
        p.fill(r.x, r.y, r.width, r.height, color)
      }
      c.ui.open("text", width: .grow(), height: .children(), axis: .vertical)
      c.ui.box("app", class: "panel.heading", text: n.app, flags: [.text])
      c.ui.box("title", class: "label", text: n.title, flags: [.text])
      if !n.body.isEmpty { c.ui.box("body", class: "label.dim", text: n.body, flags: [.text]) }
      c.ui.close()
      c.ui.close()
      if s.clicked { slips.host?.dismiss(n.id) }
    }
    c.ui.close()
  }
}

@MainActor public final class Drawer: App {
  public weak var host: NoticesHost?
  /// The clips, newest first, and the notices posted, newest first.
  public var clips: [Clip] = []
  public var notices: [Notice] = []

  public init(host: NoticesHost?) { self.host = host }

  public var title: String { "Drawer" }

  public var actions: [ActionHandler] {
    [
      ActionHandler(Action("drawer.paste", label: "Copy again", arguments: [ActionArgument("clip", .int)],
                           gesture: "a clip")) { [self] i in
        if case .int(let n)? = i.arguments.first { host?.paste(Int(n)) }
      },
      ActionHandler(Action("drawer.forget", label: "Forget", arguments: [ActionArgument("clip", .int)],
                           gesture: "a clip's Forget")) { [self] i in
        if case .int(let n)? = i.arguments.first { host?.forget(Int(n)) }
      },
      ActionHandler(Action("drawer.clear", label: "Forget all", gesture: "the drawer's Forget all")) { [self] _ in
        host?.clear()
      },
    ]
  }

  public var body: Group { DrawerView(drawer: self) }
}

struct DrawerView: View {
  let drawer: Drawer

  @MainActor func build(_ c: inout BuildContext, id: String) {
    let cq = Theme.cqw
    let theme = c.ui.theme
    let d = drawer
    c.ui.open("drawer", class: "pane", width: .percent(1), height: .percent(1), axis: .vertical, flags: [.background])
    c.ui.open("head", width: .percent(1), height: .children(), axis: .horizontal)
    c.ui.box("title", class: "heading", text: "DRAWER", flags: [.text])
    c.ui.box("count", class: "label.dim", text: d.clips.count == 1 ? "1 clip" : "\(d.clips.count) clips", flags: [.text])
    c.ui.spacer("gap")
    let clear = c.ui.box("clear", class: "button", text: "Forget all", flags: [.text, .clickable, .focusable])
    c.ui.accessible(.button, label: "Forget all")
    c.ui.close()
    if clear.clicked { d.host?.clear() }
    if d.clips.isEmpty { c.ui.box("none", class: "label.dim", text: "Nothing copied yet", flags: [.text]) }
    for clip in d.clips {
      let row = c.ui.open("clip.\(clip.number)", class: "pane.row", width: .percent(1), height: .children(),
                          axis: .horizontal, flags: [.clickable, .focusable])
      c.ui.accessible(.button, label: clip.preview, value: clip.source)
      c.ui.open("text", width: .grow(), height: .children(), axis: .vertical)
      c.ui.box("preview", class: "label", text: clip.preview, flags: [.text])
      let meta = "Clip:Source " + clip.source + (clip.origin.isEmpty ? "" : " · Clip:Origin " + clip.origin)
      c.ui.box("meta", class: "label.dim", text: meta, flags: [.text])
      c.ui.close()
      let forget = c.ui.box("forget", class: "button", text: "Forget", flags: [.text, .clickable, .focusable])
      c.ui.accessible(.button, label: "Forget", value: "\(clip.number)")
      c.ui.close()
      if forget.clicked {
        d.host?.forget(clip.number)
      } else if row.clicked {
        d.host?.paste(clip.number)
      }
    }
    c.ui.box("rule", class: "menu.rule", width: .percent(1), height: .pixels(1), flags: [.background])
    c.ui.box("noticesTitle", class: "heading", text: "NOTICES", flags: [.text])
    if d.notices.isEmpty { c.ui.box("noNotices", class: "label.dim", text: "None", flags: [.text]) }
    for n in d.notices {
      c.ui.open("notice.\(n.id)", class: "pane.row", width: .percent(1), height: .children(), axis: .horizontal)
      c.ui.accessible(.label, label: n.title, value: n.app)
      let color = theme.color(lampRole(n.lamp))
      c.ui.custom("lamp", width: .pixels(cq(0.4)), height: .pixels(cq(1.4))) { p, r in
        p.fill(r.x, r.y, r.width, r.height, color)
      }
      c.ui.box("app", class: "label.dim", text: n.app, flags: [.text])
      c.ui.box("title", class: "label", text: n.title, flags: [.text])
      c.ui.close()
    }
    c.ui.close()
  }
}
