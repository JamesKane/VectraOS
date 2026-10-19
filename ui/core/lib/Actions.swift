// SPDX-License-Identifier: BSD-3-Clause

// Actions, declared once (M6i part 4, sdk.md §10): an action has a name,
// a label, an optional default key binding and its arguments' types, and
// from that one declaration the kit gives
//
// - a control (`button(action:)`) or a menu item (`menu`) for the
//   pointer, labelled with the action's label, the item showing its key;
// - its key binding, matched against the frame's keys (rebindable:
//   `rebind`);
// - keyboard focus for its control: Tab and Shift-Tab move focus through
//   every focusable box in the order built, and Enter or Space activates
//   the focused control;
// - an entry in the app's scripting schema (`actions`, `perform` with
//   typed arguments);
// - an action in the accessibility tree (Accessibility.swift).
//
// Every route ends in an invocation, taken once by whoever handles it
// (`take`; a control takes its own). One made during a frame's build (a
// click) after its handler already looked is kept for the next frame, and
// `pending` says to run one at once; one nobody takes in a whole frame is
// dropped.
//
// An action with neither a control nor a menu item is reported
// (`unreachable`, the SDK's debug builds print it) unless it names the
// pointer gesture that reaches the same result. A menu's items count as
// reached while it is closed: the menu is built with its items either
// way.

import AccessTree

/// An argument's type, in the scripting schema.
public enum ArgumentType: UInt8, Sendable {
  case bool, int, double, string
}

/// An argument's value.
public enum ActionValue: Equatable, Sendable {
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)

  public var type: ArgumentType {
    switch self {
    case .bool: .bool
    case .int: .int
    case .double: .double
    case .string: .string
    }
  }
}

public struct ActionArgument: Equatable, Sendable {
  public var name: String
  public var type: ArgumentType
  public init(_ name: String, _ type: ArgumentType) {
    self.name = name
    self.type = type
  }
}

public struct Action: Sendable {
  /// Its name in scripts and the accessibility tree ("file.save").
  public var name: String
  /// What its control and menu item say ("Save").
  public var label: String
  /// Its default key binding.
  public var key: KeyPress?
  public var arguments: [ActionArgument]
  /// The pointer gesture that reaches the same result, for an action with
  /// no control or menu item ("drag the tab to the screen's edge").
  public var gesture: String?

  public init(_ name: String, label: String, key: KeyPress? = nil, arguments: [ActionArgument] = [],
              gesture: String? = nil)
  {
    self.name = name
    self.label = label
    self.key = key
    self.arguments = arguments
    self.gesture = gesture
  }
}

/// Where an invocation came from.
public enum InvocationSource: UInt8, Sendable {
  case key, pointer, script, accessibility
}

public struct Invocation: Sendable {
  public var action: String
  public var arguments: [ActionValue]
  public var source: InvocationSource
  /// The frame it's for.
  var frame: UInt64
}

public enum PerformError: Error, Equatable, Sendable {
  case noSuchAction
  case arguments
}

extension KeyPress {
  /// As a menu shows it: "Ctrl+Shift+S", "F5".
  public var description: String {
    var s = ""
    if control { s += "Ctrl+" }
    if alt { s += "Alt+" }
    if shift { s += "Shift+" }
    switch key {
    case .left: s += "Left"
    case .right: s += "Right"
    case .up: s += "Up"
    case .down: s += "Down"
    case .home: s += "Home"
    case .end: s += "End"
    case .pageUp: s += "PgUp"
    case .pageDown: s += "PgDn"
    case .backspace: s += "Backspace"
    case .delete: s += "Del"
    case .enter: s += "Enter"
    case .tab: s += "Tab"
    case .escape: s += "Esc"
    case .space: s += "Space"
    case .function(let n): s += "F\(n)"
    case .character(let c):
      // Letters as the key's cap shows them.
      let u = c >= 0x61 && c <= 0x7A ? c - 0x20 : c
      if let scalar = Unicode.Scalar(u) { s.unicodeScalars.append(scalar) }
    }
    return s
  }
}

extension UI {
  // MARK: Declaring

  /// Declares an action (again: replaces it, keeping a rebinding).
  public mutating func declare(_ action: Action) {
    if let i = actionIndex(action.name) {
      actions[i] = action
    } else {
      actions.append(action)
      bindings.append(action.key)
      reached.append(false)
    }
  }

  /// The declared actions: the app's scripting schema.
  public var declared: [Action] { actions }

  func actionIndex(_ name: String) -> Int? { actions.firstIndex { $0.name == name } }

  /// An action's key binding now (the user's, else its default).
  public func binding(_ name: String) -> KeyPress? { actionIndex(name).flatMap { bindings[$0] } }

  /// Binds an action to another key (nil: none).
  public mutating func rebind(_ name: String, to key: KeyPress?) {
    if let i = actionIndex(name) { bindings[i] = key }
  }

  /// Declared actions no pointer reaches: no control or menu item built
  /// for them yet, and no gesture named.
  public func unreachable() -> [String] {
    var out: [String] = []
    for (i, a) in actions.enumerated() where !reached[i] && a.gesture == nil { out.append(a.name) }
    return out
  }

  // MARK: Invoking

  /// Invokes an action from a script or an assistive client, with typed
  /// arguments (checked against its declaration); seen by the next frame.
  public mutating func perform(_ name: String, _ arguments: [ActionValue] = [],
                               from source: InvocationSource = .script) throws(PerformError)
  {
    guard let i = actionIndex(name) else { throw .noSuchAction }
    let want = actions[i].arguments
    guard want.count == arguments.count else { throw .arguments }
    for (a, v) in zip(want, arguments) where a.type != v.type { throw .arguments }
    requests.append(Invocation(action: name, arguments: arguments, source: source, frame: 0))
  }

  /// Takes this frame's invocation of an action, if there is one.
  public mutating func take(_ name: String) -> Invocation? {
    guard let i = invocations.firstIndex(where: { $0.action == name }) else { return nil }
    return invocations.remove(at: i)
  }

  /// An invocation is waiting for the next frame: run it now.
  public var pending: Bool { !requests.isEmpty || !invocations.isEmpty || settling }

  /// An invocation, for this frame and (made during its build) the next.
  mutating func invoke(_ name: String, _ arguments: [ActionValue], _ source: InvocationSource, building: Bool) {
    invocations.append(Invocation(action: name, arguments: arguments, source: source,
                                  frame: building ? frame + 1 : frame))
  }

  /// The keys the focused text field edits with, which bindings don't see.
  static func fieldTakes(_ k: KeyPress) -> Bool {
    if case .function = k.key { return false }
    if k.key == .tab || k.key == .escape { return false }
    if k.alt { return false }
    if !k.control { return true }
    switch k.key {
    case .left, .right, .home, .end, .backspace, .delete, .character(0x61): return true
    default: return false
    }
  }

  /// Routes a frame's keys, before it's built: Tab moves focus; Enter or
  /// Space activates the focused control; a binding invokes its action;
  /// the focused text field keeps its keys. What's left stays in the
  /// frame's input.
  mutating func routeKeys() {
    var kept: [KeyPress] = []
    // A focused box that takes keys raw gets them all, as they came.
    if focus != 0, let s = slot(focus), slots[s].flags.contains(.rawKeys) { return }
    for k in input.keys {
      // (Tab may have moved focus since the last key.)
      let focused = focus != 0 ? slot(focus) : nil
      let editing = focused.map { slots[$0].flags.contains(.editable) } ?? false
      if k.key == .tab && !k.control && !k.alt {
        moveFocus(back: k.shift)
        continue
      }
      if editing && UI.fieldTakes(k) {
        kept.append(k)
        continue
      }
      if !editing, k.key == .enter || k.key == .space, !k.control, !k.alt, let s = focused,
         slots[s].flags.contains(.clickable)
      {
        activate = focus
        continue
      }
      if let i = bindings.firstIndex(where: { $0 == k }) {
        invoke(actions[i].name, [], .key, building: false)
        continue
      }
      kept.append(k)
    }
    input.keys = kept
  }

  /// Moves focus to the next (or previous) focusable box of the last
  /// frame, wrapping; shows it.
  mutating func moveFocus(back: Bool) {
    guard !focusOrder.isEmpty else { return }
    let n = focusOrder.count
    if let i = focusOrder.firstIndex(of: focus) {
      focus = focusOrder[back ? (i + n - 1) % n : (i + 1) % n]
    } else {
      focus = back ? focusOrder[n - 1] : focusOrder[0]
    }
    focusVisible = true
  }

  // MARK: Controls

  /// A button for a declared action, labelled with its label: the
  /// invocation it was given this frame (clicked, its key, Enter or Space
  /// on it focused, a script), taken.
  @discardableResult
  public mutating func button(action name: String, class style: String = "button",
                              arguments: [ActionValue] = []) -> Invocation?
  {
    let i = actionIndex(name)
    if let i { reached[i] = true }
    let key = UI.hash(parentKey, name)
    let s = box(name, class: pressing(key) ? style + ".held" : style, text: i.map { actions[$0].label } ?? name,
                flags: [.clickable, .background, .text, .centred, .focusable])
    boxes[boxes.count - 1].role = .button
    boxes[boxes.count - 1].action = i.map { Int32($0) } ?? -1
    if s.clicked { invoke(name, arguments, .pointer, building: true) }
    return take(name)
  }

  /// A popup menu of declared actions at a point (logical pixels), drawn
  /// over what was built before it; the first item is its default. Its
  /// items count as reachable whether it's open or not. Whether it closed
  /// this frame: an item chosen (its invocation waits in `take`), Escape,
  /// or a press outside it. `rules` puts a rule before those items (M6l);
  /// `dimmed` items are shown but can't be chosen (Deskbar's "No
  /// windows").
  public mutating func menu(_ id: String, shown: Bool, at position: (Float, Float), items: [String],
                            hasDefault: Bool = true, labels: [String] = [], arguments: [[ActionValue]] = [],
                            rules: [Int] = [], dimmed: [Int] = []) -> Bool
  {
    let entries = items.enumerated().map { n, name in
      MenuItem(name, label: n < labels.count ? labels[n] : nil, arguments: n < arguments.count ? arguments[n] : [],
               dimmed: dimmed.contains(n), ruleBefore: rules.contains(n))
    }
    return menu(id, shown: shown, at: position, entries: entries, hasDefault: hasDefault)
  }

  /// A menu of entries (M6l): actions, and submenus Be's way, opened by
  /// the pointer resting on their item (or a press on it) beside it, each
  /// built only while it's open. Whether it closed this frame.
  public mutating func menu(_ id: String, shown: Bool, at position: (Float, Float), entries: [MenuItem],
                            hasDefault: Bool = true) -> Bool
  {
    let key = UI.hash(parentKey, id)
    // Every action it holds is reachable, open or not.
    func reach(_ es: [MenuItem]) {
      for e in es {
        if let i = actionIndex(e.action) { reached[i] = true }
        for h in e.holds { if let i = actionIndex(h) { reached[i] = true } }
      }
    }
    reach(entries)
    guard shown else {
      if submenus.menu == key { submenus = (0, []) }
      return false
    }
    if submenus.menu != key { submenus = (key, []) }
    var closed = false
    var rects: [Rect] = []
    var level = entries
    var at = position
    var depth = 0
    // A cascade keeps going the way it turned (Be's): once a level opens
    // to the left, the deeper ones do too.
    var leftward = false
    while true {
      let (opened, rect) = menuLevel(depth == 0 ? id : id + ".sub\(depth)", level, depth: depth, at: at,
                                     hasDefault: hasDefault && depth == 0, closed: &closed)
      rects.append(rect)
      guard let n = opened, depth < submenus.path.count, n < level.count, let children = level[n].submenu?() else { break }
      reach(children)
      // Beside the item that opened it: right, or left where there's no room.
      let item = slot(UI.hash(UI.hash(parentKey, depth == 0 ? id : id + ".sub\(depth)"), level[n].itemID(n, in: level)))
        .map { slots[$0].rect }
      let width = menuWidth(children)
      let right = rect.x + rect.width - 2, left = rect.x - width + 2
      if leftward ? left >= 0 : right + width > self.width {
        leftward = left >= 0 || leftward
      }
      let x = leftward && left >= 0 ? left : right + width <= self.width ? right : max(0, left)
      at = (x, (item?.y ?? rect.y) - theme.style("menu").padding.top)
      level = children
      depth += 1
    }
    if input.keys.contains(where: { $0.key == .escape }) { closed = true }
    // A press outside it (once it's been laid out: the press that opened
    // it isn't).
    let placed = rects.filter { $0.width > 0 }
    if input.pressed && !placed.isEmpty && !placed.contains(where: { $0.contains(input.pointerX, input.pointerY) }) {
      closed = true
    }
    // (Drawn this frame; gone from the next, which it asks for: Escape
    // left it on screen until other input came, M6m.)
    if closed {
      submenus = (0, [])
      settling = true
    }
    return closed
  }

  /// A menu's width: the widest item's label and key, at least 12cqw.
  func menuWidth(_ entries: [MenuItem]) -> Float {
    let item = theme.style("menu.item"), keyStyle = theme.style("menu.key")
    var width = Theme.cqw(12)
    for e in entries {
      let i = actionIndex(e.action)
      let label = e.label ?? i.map { actions[$0].label } ?? e.action
      let k = i.flatMap { bindings[$0] }.map { painter.measure($0.description, keyStyle) + keyStyle.padding.right } ?? 0
      let arrow = e.submenu != nil ? painter.measure(" ▸", keyStyle) + keyStyle.padding.right : 0
      width = max(width, item.padding.left + painter.measure(label, item) + max(k, arrow) + item.padding.right + 2)
    }
    return width
  }

  /// One level of a menu: its box, at `at`, and its items; the item whose
  /// submenu is open (after this frame's pointer), and the level's
  /// rectangle (last frame's).
  mutating func menuLevel(_ id: String, _ entries: [MenuItem], depth: Int, at position: (Float, Float),
                          hasDefault: Bool, closed: inout Bool) -> (Int?, Rect)
  {
    // Kept inside the window (its size from last frame): moved up and left
    // as far as it must.
    let levelKey = UI.hash(parentKey, id)
    var at = position
    if let s = slot(levelKey) {
      let r = slots[s].rect
      at.0 = max(0, min(at.0, width - r.width))
      at.1 = max(0, min(at.1, height - r.height))
    }
    open(id, class: "menu", width: .pixels(menuWidth(entries)), height: .children(), axis: .vertical,
         flags: [.background, .overlay], at: at)
    boxes[boxes.count - 1].role = .menu
    let menuKey = boxes[boxes.count - 1].key
    let rect = slot(menuKey).map { slots[$0].rect } ?? Rect(x: 0, y: 0, width: 0, height: 0)
    for (n, e) in entries.enumerated() {
      let i = actionIndex(e.action)
      let itemID = e.itemID(n, in: entries)
      let key = UI.hash(menuKey, itemID)
      if e.ruleBefore {
        box("rule.\(n)", class: "menu.rule", width: .percent(1), height: .pixels(1), flags: [.background])
      }
      let open = depth < submenus.path.count && submenus.path[depth] == n
      let dim = e.dimmed || (i == nil && e.submenu == nil)
      let lit = (hot == key || open) && !dim
      let cls = dim ? "menu.item.dimmed" : lit ? "menu.item.hot" : n == 0 && hasDefault ? "menu.item.default" : "menu.item"
      let s = self.open(itemID, class: lit ? "menu.row.hot" : "menu.row", width: .percent(1), height: .children(),
                        axis: .horizontal, flags: dim ? [.background] : [.clickable, .background, .focusable])
      boxes[boxes.count - 1].role = .menuItem
      // (A dimmed item has no action: a reader sees it can't be chosen.)
      boxes[boxes.count - 1].action = dim ? -1 : i.map { Int32($0) } ?? -1
      let label = e.label ?? i.map { actions[$0].label } ?? e.action
      boxes[boxes.count - 1].label = label
      box("label", class: cls, text: label, width: .grow(), flags: [.text])
      if e.submenu != nil {
        // A small triangle pointing right (the type has no ▸).
        let ink = theme.style(cls).ink, size = Theme.cqw(0.7)
        custom("arrow", width: .pixels(size + theme.style("menu.key").padding.right), height: .percent(1)) { p, r in
          let n = Int(size / 2), cy = r.y + r.height / 2
          for k in 0..<max(n, 1) {
            let half = Float(n - k)
            p.fill(r.x + Float(k), cy - half, 1, 2 * half, ink)
          }
        }
      } else if let i, let k = bindings[i] {
        box("key", class: "menu.key", text: k.description, flags: [.text, .end])
      }
      close()
      // The pointer resting on an item opens its submenu, or closes a
      // deeper one; a press on a submenu's item does too.
      if (s.hovered || s.pressed) && !dim {
        let path = Array(submenus.path.prefix(depth)) + (e.submenu != nil ? [n] : [])
        if path != submenus.path { submenus.path = path }
      }
      if s.clicked, let i {
        invoke(actions[i].name, e.arguments, .pointer, building: true)
        closed = true
      }
      if n == 0 && hasDefault && entries.count > 1 {
        box("rule", class: "menu.rule", width: .percent(1), height: .pixels(1), flags: [.background])
      }
    }
    close()
    let opened = depth < submenus.path.count ? submenus.path[depth] : nil
    return (opened, rect)
  }
}
