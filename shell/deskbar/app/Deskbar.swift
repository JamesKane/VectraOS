// SPDX-License-Identifier: BSD-3-Clause

// Deskbar (deskbar(4), board 01): the VECTRAOS menu (Find, the Recent
// lists, the launcher's apps to start, the preference apps), the tray with
// the clock's place, which Radharc draws in (D114), and the workspaces'
// buttons (D116), the gauges, and the running apps (Radharc's windows grouped by the app each says it belongs
// to, with how many; the focused app's in cyan), in the storyboard's
// Deskbar styles, as a Kit app in a panel. A click on a running app opens
// Be's menu of its windows. Its host feeds it the window list, the apps
// and the gauges, and sizes the panel to what it shows (`height`), menus
// included.

import Kit
import UICore

/// An app the launcher can start.
public struct AppEntry: Equatable, Sendable {
  public var service: String
  public var name: String
  public var running: Bool
  /// A preference app (the Preferences submenu's, as Be's).
  public var preferences: Bool
  public init(service: String, name: String, running: Bool, preferences: Bool = false) {
    self.service = service
    self.name = name
    self.running = running
    self.preferences = preferences
  }

  /// The launcher's `apps` leaf: "SERVICE<TAB>NAME<TAB>running|stopped
  /// <TAB>app|preferences[<TAB>ADDON]" a line (an add-on's label, M6l:
  /// Tracker's; the app is listed here as any).
  public static func parse(_ text: String) -> [AppEntry] {
    text.split(separator: "\n").compactMap { line in
      let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard f.count >= 3 && f.count <= 5 else { return nil }
      return AppEntry(service: f[0], name: f[1], running: f[2] == "running", preferences: f.count >= 4 && f[3] == "preferences")
    }
  }
}

/// A window, as Deskbar needs it from Radharc's list.
public struct WindowItem: Equatable, Sendable {
  public var id: UInt32
  public var title: String
  public var app: String
  public var focused: Bool
  /// The desktop's, or a panel's: not a running app's window.
  public var furniture: Bool
  /// The desktop's (M6l): its app is listed even with no window open.
  public var desktop: Bool
  /// Hidden (M6l: Hide all; Radharc's `hidden`).
  public var hidden: Bool
  public init(id: UInt32, title: String, app: String, focused: Bool, furniture: Bool, desktop: Bool = false,
              hidden: Bool = false)
  {
    self.id = id
    self.title = title
    self.app = app
    self.focused = focused
    self.furniture = furniture
    self.desktop = desktop
    self.hidden = hidden
  }
}

/// A workspace, as Deskbar shows it: a button with its mode's letter.
public struct WorkspaceItem: Equatable, Sendable {
  public var number: Int
  public var tiled: Bool
  public var current: Bool
  public init(number: Int, tiled: Bool, current: Bool) {
    self.number = number
    self.tiled = tiled
    self.current = current
  }
}

/// A running app: its name and its windows, topmost last.
public struct RunningApp: Equatable, Sendable {
  public var name: String
  public var windows: [WindowItem]
  public var focused: Bool { windows.contains { $0.focused } }
}

/// What Deskbar asks of its host.
@MainActor public protocol DeskbarHost: AnyObject {
  /// Starts an app (the launcher's `start SERVICE`).
  func start(_ service: String)
  /// Raises and focuses a window (a hidden one shows again).
  func top(_ window: UInt32)
  /// Hides, shows or asks to close a window (M6l: an app's Hide all,
  /// Show all, Close all).
  func hide(_ window: UInt32)
  func show(_ window: UInt32)
  func close(_ window: UInt32)
  /// Be's leaf menu (M6l): Find (Tracker's query window), and a recent
  /// item opened (a document routed by its type, a folder by Tracker, an
  /// app started).
  func find()
  func open(recent item: String, kind: RecentKind)
  /// Shows workspace `n` (Radharc's).
  func workspace(_ n: Int)
  /// Opens or closes the drawer (notices').
  func drawer()
}

/// Which Recent list (M6l).
public enum RecentKind: String, Sendable {
  case documents, folders, apps
}

@MainActor public final class Deskbar: App {
  public weak var host: DeskbarHost?
  public var apps: [AppEntry] = []
  public private(set) var running: [RunningApp] = []
  /// The gauges: CPU and PACING; none while they're off.
  public var gauges: [Gauge] = []
  /// Radharc's workspaces, a button each in the tray.
  public var workspaces: [WorkspaceItem] = []

  /// The clock's width: room for the longest time it shows, in its style.
  public static func clockWidth(_ painter: Painter) -> Float {
    painter.measure("12:00 PM", painter.theme.style("deskbar.clock")).rounded(.up)
  }
  /// The menu open: the apps', or a running app's windows'.
  public private(set) var open: Menu?
  public enum Menu: Equatable, Sendable {
    case apps
    /// The Preferences submenu (Be's): the preference apps.
    case preferences
    /// A Recent submenu (M6l). Deskbar's menus are drawn in its panel, so
    /// a submenu takes the menu's place rather than cascading beside it.
    case recent(RecentKind)
    case windows(String)
  }

  /// What was opened lately (Settings' `Recent`, read by the host):
  /// documents as "TYPE<TAB>PATH", folders as paths, apps as services.
  public var recent: [RecentKind: [String]] = [:]

  /// A recent item's label: a path's last name, an app's name.
  public func label(_ item: String, _ kind: RecentKind) -> String {
    switch kind {
    case .apps: return apps.first { $0.service == item }?.name ?? item
    case .documents, .folders:
      let path = item.split(separator: "\t").last.map(String.init) ?? item
      return path.split(separator: "/").last.map(String.init) ?? path
    }
  }

  /// The VECTRAOS menu (Be's leaf menu): Find, the drawer, the Recent
  /// lists, the apps and Preferences.
  public func leafMenu() -> [MenuItem] {
    var out = [MenuItem("deskbar.find"), MenuItem("deskbar.drawer")]
    for (n, (kind, label)) in [(RecentKind.documents, "Recent documents →"), (.folders, "Recent folders →"),
                               (.apps, "Recent applications →")].enumerated() {
      out.append(MenuItem("deskbar.recents", label: label, arguments: [.string(kind.rawValue)], ruleBefore: n == 0))
    }
    for (n, a) in ordinaryApps.enumerated() {
      out.append(MenuItem("deskbar.start", label: a.name, arguments: [.string(a.service)], ruleBefore: n == 0))
    }
    if !preferenceApps.isEmpty { out.append(MenuItem("deskbar.preferences", ruleBefore: ordinaryApps.isEmpty)) }
    return out
  }

  /// A Recent list's items, or "Nothing yet".
  public func recentMenu(_ kind: RecentKind) -> [MenuItem] {
    let items = recent[kind] ?? []
    if items.isEmpty { return [MenuItem("deskbar.recent", label: "Nothing yet", dimmed: true)] }
    return items.map { MenuItem("deskbar.recent", label: label($0, kind), arguments: [.string(kind.rawValue), .string($0)]) }
  }

  /// The menu's apps, and the Preferences submenu's.
  public var ordinaryApps: [AppEntry] { apps.filter { !$0.preferences } }
  public var preferenceApps: [AppEntry] { apps.filter { $0.preferences } }

  public init(host: DeskbarHost?) { self.host = host }

  public var title: String { "Deskbar" }

  /// Radharc's windows, bottom to top: grouped into running apps, in the
  /// order each first appeared (Deskbar's own and the furniture apart;
  /// windows without an app go under their title). An app whose desktop
  /// is up is running with no window open (M6l: Tracker, "No windows").
  public func update(_ windows: [WindowItem]) {
    var out: [RunningApp] = []
    for w in windows where w.desktop && !w.app.isEmpty && !out.contains(where: { $0.name == w.app }) {
      out.append(RunningApp(name: w.app, windows: []))
    }
    for w in windows where !w.furniture {
      let name = w.app.isEmpty ? w.title : w.app
      if let i = out.firstIndex(where: { $0.name == name }) { out[i].windows.append(w) } else {
        out.append(RunningApp(name: name, windows: [w]))
      }
    }
    // Keep the order apps were first seen in.
    let known = running.map { $0.name }
    out.sort { a, b in
      let ia = known.firstIndex(of: a.name) ?? Int.max, ib = known.firstIndex(of: b.name) ?? Int.max
      return ia < ib
    }
    running = out
    if case .windows(let name)? = open, !running.contains(where: { $0.name == name }) { open = nil }
  }

  public var actions: [ActionHandler] {
    [
      ActionHandler(Action("deskbar.start", label: "Start", arguments: [ActionArgument("service", .string)],
                           gesture: "the VECTRAOS menu")) { [self] i in
        if case .string(let s)? = i.arguments.first { host?.start(s) }
      },
      ActionHandler(Action("deskbar.preferences", label: "Preferences →", gesture: "the VECTRAOS menu")) { [self] _ in
        open = .preferences
      },
      // Be's leaf menu (M6l).
      ActionHandler(Action("deskbar.find", label: "Find…", gesture: "the VECTRAOS menu")) { [self] _ in host?.find() },
      ActionHandler(Action("deskbar.drawer", label: "Drawer", gesture: "the VECTRAOS menu")) { [self] _ in host?.drawer() },
      ActionHandler(Action("deskbar.recents", label: "Recent", arguments: [ActionArgument("kind", .string)],
                           gesture: "the VECTRAOS menu")) { [self] i in
        if case .string(let k)? = i.arguments.first, let kind = RecentKind(rawValue: k) { open = .recent(kind) }
      },
      ActionHandler(Action("deskbar.recent", label: "Open", arguments: [ActionArgument("kind", .string),
                                                                         ActionArgument("item", .string)],
                           gesture: "a Recent menu")) { [self] i in
        guard i.arguments.count == 2, case .string(let k) = i.arguments[0], let kind = RecentKind(rawValue: k),
          case .string(let item) = i.arguments[1]
        else { return }
        host?.open(recent: item, kind: kind)
      },
      ActionHandler(Action("deskbar.top", label: "Show", arguments: [ActionArgument("window", .int)],
                           gesture: "a running app's menu")) { [self] i in
        if case .int(let w)? = i.arguments.first { host?.top(UInt32(w)) }
      },
      // Be's app menu (M6l): every window of the app at once.
      ActionHandler(Action("deskbar.hideAll", label: "Hide all", arguments: [ActionArgument("app", .string)],
                           gesture: "a running app's menu")) { [self] i in
        for w in windows(i) where !w.hidden { host?.hide(w.id) }
      },
      ActionHandler(Action("deskbar.showAll", label: "Show all", arguments: [ActionArgument("app", .string)],
                           gesture: "a running app's menu")) { [self] i in
        for w in windows(i) { host?.show(w.id) }
      },
      ActionHandler(Action("deskbar.closeAll", label: "Close all", arguments: [ActionArgument("app", .string)],
                           gesture: "a running app's menu")) { [self] i in
        for w in windows(i) { host?.close(w.id) }
      },
      ActionHandler(Action("deskbar.workspace", label: "Workspace", arguments: [ActionArgument("number", .int)],
                           gesture: "the tray's workspace buttons")) { [self] i in
        if case .int(let n)? = i.arguments.first { host?.workspace(Int(n)) }
      },
      // "No windows": shown, never chosen.
      ActionHandler(Action("deskbar.noWindows", label: "No windows", gesture: "a running app's menu")) { _ in },
    ]
  }

  /// The windows of the app an invocation names.
  func windows(_ i: Invocation) -> [WindowItem] {
    guard case .string(let name)? = i.arguments.first else { return [] }
    return running.first { $0.name == name }?.windows ?? []
  }

  /// A running app clicked: its menu (Be's: its windows, then Hide all,
  /// Show all, Close all).
  public func pick(_ app: RunningApp) {
    open = open == .windows(app.name) ? nil : .windows(app.name)
  }

  /// A running app's menu: each window (a hidden one marked), or "No
  /// windows", then Hide all, Show all and Close all; the items, their
  /// labels and arguments, and where the rule goes.
  public func appMenu(_ name: String)
    -> (items: [String], labels: [String], arguments: [[ActionValue]], rule: Int, dimmed: [Int])
  {
    let ws = running.first { $0.name == name }?.windows ?? []
    var items = ws.isEmpty ? ["deskbar.noWindows"] : Array(repeating: "deskbar.top", count: ws.count)
    var labels = ws.isEmpty ? ["No windows"] : ws.map { $0.hidden ? $0.title + " (hidden)" : $0.title }
    var arguments: [[ActionValue]] = ws.isEmpty ? [[]] : ws.map { [.int(Int64($0.id))] }
    let rule = items.count
    items += ["deskbar.hideAll", "deskbar.showAll", "deskbar.closeAll"]
    labels += ["Hide all", "Show all", "Close all"]
    arguments += Array(repeating: [.string(name)], count: 3)
    return (items, labels, arguments, rule, ws.isEmpty ? [0] : [])
  }

  public func toggleApps() { open = open == .apps ? nil : .apps }
  public func closeMenu() { open = nil }

  // MARK: Sizes

  static let c = Theme.cqw

  /// The bar's height, and with an open menu below it, the panel's.
  public func height(_ painter: Painter) -> Float {
    let t = painter.theme
    let menu = t.style("deskbar.menu"), tray = t.style("deskbar.tray"), a = t.style("deskbar.app")
    let menuH = menu.padding.top + painter.lineHeight(menu) + menu.padding.bottom
    let trayH = tray.padding.top + Self.c(1.6) + tray.padding.bottom
    let rowH = a.padding.top + painter.lineHeight(a) + a.padding.bottom
    var h = 2 + menuH + 1 + trayH
    if !gauges.isEmpty { h += 1 + DeskbarView.gaugesHeight(gauges.count, painter) }
    if !running.isEmpty { h += 1 + Float(running.count) * rowH + 2 * Self.c(0.3) }
    // An open menu hangs below the bar's top row.
    let items: Int
    switch open {
    case .apps?: items = leafMenu().count
    case .preferences?: items = max(preferenceApps.count, 1)
    case .recent(let k)?: items = max(recent[k]?.count ?? 0, 1)
    case .windows(let n)?: items = max(running.first { $0.name == n }?.windows.count ?? 0, 1) + 3
    case nil: items = 0
    }
    if items > 0 {
      let item = t.style("menu.item")
      let itemH = item.padding.top + painter.lineHeight(item) + item.padding.bottom
      let rules: Float = open == .apps ? Float(leafMenu().filter { $0.ruleBefore }.count) : 0
      h = max(h, menuH + 4 + Float(items) * itemH + 1 + rules + Self.c(0.5))
    }
    return h
  }

  public var body: Group { DeskbarView(bar: self) }
}

struct DeskbarView: View {
  let bar: Deskbar

  @MainActor func build(_ c: inout BuildContext, id: String) {
    let b = bar
    let theme = c.ui.theme
    let cq = Theme.cqw
    c.ui.open("bar", class: "deskbar.body", width: .percent(1), height: .children(), axis: .vertical, flags: [.background])
    // VECTRAOS: the apps' menu.
    let m = c.ui.open("menu", class: "deskbar.menu", width: .percent(1), height: .children(), axis: .horizontal,
                      flags: [.clickable, .focusable])
    c.ui.accessible(.menu, label: "VECTRAOS")
    let icon = cq(1.6)
    c.ui.custom("cube", width: .pixels(icon + cq(0.6)), height: .pixels(icon)) { p, r in
      p.icon("cube", r.x, r.y, size: icon, color: theme.color("focus"))
    }
    c.ui.box("name", class: "deskbar.menu.text", text: "VECTRAOS", flags: [.text])
    c.ui.close()
    if m.pressed || (m.clicked && !c.ui.frameInput.released) { b.toggleApps() }
    c.ui.box("rule1", class: "deskbar.rule", width: .percent(1), height: .pixels(1), flags: [.background])
    // The tray: the clock's place, which Radharc draws in (D114): its host
    // gives Radharc where it was laid out (the "Clock" node's place).
    c.ui.open("tray", class: "deskbar.tray", width: .percent(1), height: .children(), axis: .horizontal)
    // The workspaces (D116): a button each, T for tile, S for space, the
    // one shown in the focused app's style.
    for w in b.workspaces {
      let style = w.current ? "deskbar.app.on.text" : "deskbar.app.text"
      let k = c.ui.box("workspace.\(w.number)", class: style, text: w.tiled ? "T" : "S", width: .pixels(cq(1.3)),
                       height: .pixels(icon), flags: [.text, .clickable, .focusable])
      c.ui.accessible(.button, label: "Workspace \(w.number)", value: w.tiled ? "tile" : "space")
      if k.clicked { b.host?.workspace(w.number) }
    }
    c.ui.spacer("gap")
    c.ui.box("clock", width: .pixels(Deskbar.clockWidth(c.ui.painter)), height: .pixels(icon))
    c.ui.accessible(.label, label: "Clock")
    c.ui.close()
    // The gauges, as Chrome draws board 01's.
    if !b.gauges.isEmpty {
      c.ui.box("rule3", class: "deskbar.rule", width: .percent(1), height: .pixels(1), flags: [.background])
      let gauges = b.gauges
      c.ui.custom("gauges", width: .percent(1), height: .pixels(DeskbarView.gaugesHeight(gauges.count, c.ui.painter))) {
        p, r in DeskbarView.drawGauges(gauges, r, &p)
      }
      for g in gauges { c.ui.accessible(.label, label: g.name, value: g.reading) }
    }
    // The running apps.
    if !b.running.isEmpty {
      c.ui.box("rule2", class: "deskbar.rule", width: .percent(1), height: .pixels(1), flags: [.background])
      c.ui.open("apps", width: .percent(1), height: .children(), axis: .vertical)
      c.ui.box("top", width: .pixels(0), height: .pixels(cq(0.3)))
      for app in b.running {
        let style = app.focused ? "deskbar.app.on" : "deskbar.app"
        let s = c.ui.open("app." + app.name, class: style, width: .percent(1), height: .children(), axis: .horizontal,
                          flags: [.clickable, .focusable])
        c.ui.accessible(.button, label: app.name, value: "\(app.windows.count)")
        // Each part as tall as the row's line, its text centred in it.
        let line = c.ui.painter.lineHeight(c.ui.theme.style(style))
        let ref = DeskbarView.icon(app.name, theme)
        let size = cq(1.35)
        c.ui.custom("icon", width: .pixels(size + cq(0.4)), height: .pixels(line)) { p, r in
          p.icon(ref.name, r.x, r.y + (r.height - size) / 2, size: size, color: ref.color, emblem: ref.emblem)
        }
        c.ui.box("name", class: style + ".text", text: app.name, height: .pixels(line), flags: [.text])
        c.ui.spacer("gap")
        c.ui.box("count", class: "deskbar.app.count", text: "\(app.windows.count)", height: .pixels(line), flags: [.text])
        c.ui.close()
        if s.clicked { b.pick(app) }
      }
      c.ui.box("bottom", width: .pixels(0), height: .pixels(cq(0.3)))
      c.ui.close()
    }
    c.ui.close()
    // The open menu, under the VECTRAOS row.
    let t = c.ui.theme.style("deskbar.menu")
    let below = t.padding.top + c.ui.painter.lineHeight(t) + t.padding.bottom + 2
    switch b.open {
    case .apps?:
      let closed = c.ui.menu("appsMenu", shown: true, at: (cq(0.4), below), entries: b.leafMenu(), hasDefault: false)
      // (Choosing Preferences or a Recent list opens it: not a close.)
      if closed && b.open == .apps { b.closeMenu() }
    case .recent(let kind)?:
      let closed = c.ui.menu("recentMenu", shown: true, at: (cq(0.4), below), entries: b.recentMenu(kind), hasDefault: false)
      if closed && b.open == .recent(kind) { b.closeMenu() }
    case .preferences?:
      let prefs = b.preferenceApps
      let closed = c.ui.menu("preferencesMenu", shown: true, at: (cq(0.4), below),
                             items: Array(repeating: "deskbar.start", count: prefs.count), hasDefault: false,
                             labels: prefs.map { $0.name }, arguments: prefs.map { [.string($0.service)] })
      if closed { b.closeMenu() }
    case .windows(let name)?:
      let m = b.appMenu(name)
      let closed = c.ui.menu("windowsMenu", shown: true, at: (cq(0.4), below), items: m.items, hasDefault: false,
                             labels: m.labels, arguments: m.arguments, rules: [m.rule], dimmed: m.dimmed)
      if closed { b.closeMenu() }
    case nil:
      _ = c.ui.menu("appsMenu", shown: false, at: (0, 0),
                    items: ["deskbar.start", "deskbar.preferences", "deskbar.find", "deskbar.drawer", "deskbar.recents"])
      _ = c.ui.menu("recentMenu", shown: false, at: (0, 0), items: ["deskbar.recent"])
      _ = c.ui.menu("windowsMenu", shown: false, at: (0, 0),
                    items: ["deskbar.top", "deskbar.hideAll", "deskbar.showAll", "deskbar.closeAll", "deskbar.noWindows"])
    }
  }

  nonisolated static func gaugesHeight(_ n: Int, _ p: Painter) -> Float {
    let g = p.theme.style("gauge")
    return g.padding.top + Float(n) * p.lineHeight(g) + Float(max(n - 1, 0)) * Theme.cqw(0.35) + g.padding.bottom
  }

  /// Each gauge's name, bar and reading (Chrome.deskbar's).
  nonisolated static func drawGauges(_ gauges: [Gauge], _ r: Rect, _ p: inout Painter) {
    let t = p.theme
    let g = t.style("gauge"), barStyle = t.style("gauge.bar"), value = t.style("gauge.value")
    let rowH = p.lineHeight(g), gap = Theme.cqw(0.35)
    var y = r.y + g.padding.top
    for gauge in gauges {
      p.text(gauge.name, r.x + g.padding.left, y, g)
      let w = p.measure(gauge.reading, value)
      p.text(gauge.reading, r.x + r.width - g.padding.right - w, y, value)
      let bx = r.x + g.padding.left + barStyle.padding.left + Theme.cqw(0.4)
      let bw = r.x + r.width - g.padding.right - w - Theme.cqw(0.4) - bx
      let by = y + (rowH - barStyle.padding.top) / 2
      p.fill(bx, by, bw, barStyle.padding.top, barStyle.fill)
      p.fill(bx, by, bw * min(max(gauge.fraction, 0), 1), barStyle.padding.top, barStyle.ink)
      y += rowH + gap
    }
  }

  /// An app's icon (board 01's: Tracker a folder in focus, Terminal its
  /// own, Mail in warning); others a document, in the theme's roles.
  static func icon(_ app: String, _ t: Theme) -> IconRef {
    switch app {
    case "Tracker": return IconRef("folder", color: t.color("focus"))
    case "Terminal": return IconRef("terminal", color: t.color("ink"), emblem: t.color("live"))
    case "Mail": return IconRef("mail", color: t.color("warning"))
    default: return IconRef("doc", color: t.color("ink"))
    }
  }
}
