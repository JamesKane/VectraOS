// SPDX-License-Identifier: BSD-3-Clause

// Menus (M6i part 6, decided 2026-10-12): Be's menu bar in each window,
// not one bar at the screen's top, and a right-click's context menu,
// whose first item routes what was clicked through the router (plumb:
// "Route → edit", board 06), the same in every app.
//
// A bar's menus hold declared actions; a menu opens on the press of its
// title (Be's), and with one open, the pointer slides across the bar to
// open the others. A menu is built closed too, so its actions are
// reachable (Actions.swift's report). The drop-down and the context menu
// are overlays: drawn over the whole frame, taking the pointer first.

import AccessTree

/// A menu of a bar: its title and its actions' names, or its entries
/// (with submenus, M6l).
public struct MenuSpec {
  public var title: String
  public var entries: [MenuItem]
  public var items: [String] { entries.map { $0.action } }
  public init(_ title: String, _ items: [String]) {
    self.title = title
    entries = items.map { MenuItem($0) }
  }
  public init(_ title: String, entries: [MenuItem]) {
    self.title = title
    self.entries = entries
  }
}

/// A menu's entry (M6l): a declared action (with the caller's label and
/// arguments, dimmed, a rule before it), and or a submenu, built only
/// while it's open; `holds` names the actions a submenu would hold, so
/// they count as reachable while it's shut.
public struct MenuItem {
  public var action: String
  public var label: String?
  public var arguments: [ActionValue]
  public var dimmed: Bool
  public var ruleBefore: Bool
  public var submenu: (() -> [MenuItem])?
  public var holds: [String]
  public init(_ action: String, label: String? = nil, arguments: [ActionValue] = [], dimmed: Bool = false,
              ruleBefore: Bool = false, holds: [String] = [], submenu: (() -> [MenuItem])? = nil)
  {
    self.action = action
    self.label = label
    self.arguments = arguments
    self.dimmed = dimmed
    self.ruleBefore = ruleBefore
    self.holds = holds
    self.submenu = submenu
  }

  /// A submenu with no action of its own.
  public static func submenu(_ label: String, ruleBefore: Bool = false, holds: [String] = [],
                             _ children: @escaping () -> [MenuItem]) -> MenuItem
  {
    MenuItem("", label: label, ruleBefore: ruleBefore, holds: holds, submenu: children)
  }

  /// Its id among `entries`: its action's name, by its place too when
  /// the action is several items (Deskbar's apps) or none (a submenu).
  func itemID(_ n: Int, in entries: [MenuItem]) -> String {
    if action.isEmpty { return "sub#\(n)" }
    return entries.filter { $0.action == action }.count > 1 ? action + "#\(n)" : action
  }
}

extension UI {
  /// Be's menu bar, across the open box (a window's content, at its top).
  public mutating func menuBar(_ id: String, _ menus: [MenuSpec]) {
    open(id, class: "menubar", width: .percent(1), height: .children(), axis: .horizontal, flags: [.background])
    accessible(.group, label: "Menu bar")
    let bar = boxes[boxes.count - 1].key
    // The titles first, so the menu that's open is settled before any
    // drop-down is built.
    var titles: [UInt64] = []
    for (i, m) in menus.enumerated() {
      let title = UI.hash(bar, "t\(i)")
      titles.append(title)
      let isOpen = openMenu == title
      let s = box("t\(i)", class: isOpen ? "menubar.title.open" : "menubar.title", text: m.title,
                  flags: [.clickable, .background, .text, .focusable])
      accessible(.menu, label: m.title)
      if s.pressed {
        openMenu = isOpen ? 0 : title
      } else if openMenu != 0 && openMenu != title && s.hovered && openMenuBar == bar {
        openMenu = title  // sliding across the bar
      } else if s.clicked && !input.released && !isOpen {
        openMenu = title  // Enter or Space on it
      }
      if openMenu == title { openMenuBar = bar }
    }
    for (i, m) in menus.enumerated() {
      let r = slot(titles[i]).map { slots[$0].rect }
      let shown = openMenu == titles[i] && r != nil
      let at = (r?.x ?? 0, (r?.y ?? 0) + (r?.height ?? 0))
      if menu("m\(i)", shown: shown, at: at, entries: m.entries, hasDefault: false) && openMenu == titles[i] { openMenu = 0 }
    }
    close()
    box(id + ".rule", class: "menubar.rule", width: .percent(1), height: .pixels(1), flags: [.background])
  }

  /// Opens context menu `id` at the pointer, about `subject` (what was
  /// right-clicked, as text the router can route).
  public mutating func openContextMenu(_ id: String, subject: String) {
    context = (UI.hash(0, id), input.pointerX, input.pointerY, subject)
  }

  /// Context menu `id`, if it's open: first an item routing its subject
  /// (`route.open`, its argument the subject: the router, M6k, takes it),
  /// labelled for where it would go ("Route → edit"), then `items`.
  /// Whether it closed this frame.
  @discardableResult
  public mutating func contextMenu(_ id: String, route destination: String? = nil, items: [String]) -> Bool {
    contextMenu(id, route: destination, entries: items.map { MenuItem($0) })
  }

  /// A context menu of entries (submenus too, M6l).
  @discardableResult
  public mutating func contextMenu(_ id: String, route destination: String? = nil, entries: [MenuItem]) -> Bool {
    if actionIndex("route.open") == nil {
      declare(Action("route.open", label: "Route", arguments: [ActionArgument("subject", .string)],
                     gesture: "a right-click's context menu"))
    }
    guard let c = context, c.key == UI.hash(0, id) else {
      _ = menu(id, shown: false, at: (0, 0), entries: entries)
      return false
    }
    let label = destination.map { "Route → " + $0 } ?? "Route"
    let closed = menu(id, shown: true, at: (c.x, c.y),
                      entries: [MenuItem("route.open", label: label, arguments: [.string(c.subject)])] + entries,
                      hasDefault: true)
    if closed { context = nil }
    return closed
  }
}
