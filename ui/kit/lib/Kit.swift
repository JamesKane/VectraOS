// SPDX-License-Identifier: BSD-3-Clause

// The UI Kit's tier 1 layer (M6i part 7, decided 2026-10-12: the kit is
// split, a tier 0 core and this layer on top for apps): views written with
// result builders, values bound into the app's model, and actions whose
// handlers may be async. It is a way of writing UICore's immediate mode,
// not a second toolkit: each frame the app's `body` is evaluated again
// and its views build UICore's boxes, keyed by where they stand among
// their siblings (or by `.id`), so state underneath (scroll, carets,
// focus) lives in UICore's slots as before.
//
// An app declares its actions once, each with its handler; a handler runs
// on the main actor, as a task if it's async. While one runs, more
// invocations of the same action wait for it (a second Save isn't started
// over the first), and when it ends the runner asks for a frame.
// Everything here runs on the main actor: the app's model is the app's,
// and views read it as they're built.

@_exported import AccessTree
@_exported import UICore

/// What views build into: the frame's UI, and the invocations its
/// controls returned, for the runner to hand to their handlers.
public struct BuildContext {
  public var ui: UI
  var invoked: [Invocation] = []
}

/// A part of a window's content.
@MainActor
public protocol View {
  /// Builds its boxes, as the child `id` of the box open now.
  func build(_ c: inout BuildContext, id: String)
}

/// Views in order, each keyed by its place (or its own `.id`).
public struct Group: View {
  let parts: [any View]
  public init(_ parts: [any View]) { self.parts = parts }
  public func build(_ c: inout BuildContext, id: String) {
    for (n, p) in parts.enumerated() { p.build(&c, id: id + "." + String(n)) }
  }
}

@resultBuilder @MainActor
public enum ViewBuilder {
  public static func buildExpression(_ v: any View) -> [any View] { [v] }
  public static func buildBlock(_ parts: [any View]...) -> [any View] { parts.flatMap { $0 } }
  public static func buildOptional(_ v: [any View]?) -> [any View] { v ?? [] }
  public static func buildEither(first v: [any View]) -> [any View] { v }
  public static func buildEither(second v: [any View]) -> [any View] { v }
  public static func buildArray(_ v: [[any View]]) -> [any View] { v.flatMap { $0 } }
  public static func buildFinalResult(_ v: [any View]) -> Group { Group(v) }
}

/// A value the app owns, read and written by a view.
@MainActor
public struct Binding<Value> {
  public let get: () -> Value
  public let set: (Value) -> Void
  public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
    self.get = get
    self.set = set
  }
  /// A model's property.
  public init<Model: AnyObject>(_ model: Model, _ path: ReferenceWritableKeyPath<Model, Value>) {
    get = { model[keyPath: path] }
    set = { model[keyPath: path] = $0 }
  }
  /// A value that never changes (previews, tests).
  public static func constant(_ v: Value) -> Binding<Value> { Binding(get: { v }, set: { _ in }) }
}

// MARK: Views

/// A line of text in a class.
public struct Text: View {
  let text: String, style: String
  public init(_ text: String, class style: String = "label") {
    self.text = text
    self.style = style
  }
  public func build(_ c: inout BuildContext, id: String) { c.ui.label(id, text, class: style) }
}

/// Views stacked down (or across), in a class's box.
public struct Stack: View {
  let axis: Axis, style: String, width: Size, height: Size, flags: BoxFlags, content: Group
  /// `flags`: `.background` draws the class's fill and edge.
  public init(_ axis: Axis = .vertical, class style: String = "default", width: Size = .children(),
              height: Size = .children(), flags: BoxFlags = [], @ViewBuilder content: () -> Group)
  {
    self.axis = axis
    self.style = style
    self.width = width
    self.height = height
    self.flags = flags
    self.content = content()
  }
  public func build(_ c: inout BuildContext, id: String) {
    c.ui.open(id, class: style, width: width, height: height, axis: axis, flags: flags)
    content.build(&c, id: "")
    c.ui.close()
  }
}

/// Views down.
@MainActor public func VStack(class style: String = "default", width: Size = .children(), height: Size = .children(),
                   flags: BoxFlags = [], @ViewBuilder content: () -> Group) -> Stack
{
  Stack(.vertical, class: style, width: width, height: height, flags: flags, content: content)
}

/// Views across.
@MainActor public func HStack(class style: String = "default", width: Size = .children(), height: Size = .children(),
                   flags: BoxFlags = [], @ViewBuilder content: () -> Group) -> Stack
{
  Stack(.horizontal, class: style, width: width, height: height, flags: flags, content: content)
}

/// A floating box at a place (logical pixels), its content down it: a
/// window's content inside its chrome.
public struct Window: View {
  let x: Float, y: Float, width: Float, height: Float, style: String, content: Group
  public init(x: Float, y: Float, width: Float, height: Float, class style: String = "default",
              @ViewBuilder content: () -> Group)
  {
    (self.x, self.y, self.width, self.height, self.style) = (x, y, width, height, style)
    self.content = content()
  }
  public func build(_ c: inout BuildContext, id: String) {
    c.ui.open(id, class: style, width: .pixels(width), height: .pixels(height), axis: .vertical, at: (x, y))
    content.build(&c, id: "")
    c.ui.close()
  }
}

/// Space that takes what its siblings leave (or a fixed gap).
public struct Spacer: View {
  let size: Float?
  public init(_ size: Float? = nil) { self.size = size }
  public func build(_ c: inout BuildContext, id: String) {
    if let size { c.ui.box(id, width: .pixels(size), height: .pixels(size)) } else { c.ui.spacer(id) }
  }
}

/// A button: for a declared action (its control: labelled with the
/// action's label, its invocation handed to the action's handler), or with
/// a label and a closure run when it's clicked.
public struct Button: View {
  let action: String?, label: String, style: String, arguments: [ActionValue]
  let run: (@MainActor () -> Void)?
  public init(action: String, class style: String = "button", arguments: [ActionValue] = []) {
    self.action = action
    label = ""
    self.style = style
    self.arguments = arguments
    run = nil
  }
  public init(_ label: String, class style: String = "button", run: @escaping @MainActor () -> Void) {
    action = nil
    self.label = label
    self.style = style
    arguments = []
    self.run = run
  }
  public func build(_ c: inout BuildContext, id: String) {
    if let action {
      // Keyed by its action, as UICore keys an action's control.
      if let i = c.ui.button(action: action, class: style, arguments: arguments) { c.invoked.append(i) }
    } else if c.ui.button(id, label, class: style) {
      run?()
    }
  }
}

/// A single-line text field editing a bound string.
public struct TextField: View {
  let text: Binding<String>, label: String, style: String, width: Size, secure: Bool
  let submit: (@MainActor (String) -> Void)?
  public init(_ label: String, text: Binding<String>, class style: String = "field", width: Size = .grow(),
              secure: Bool = false, onSubmit submit: (@MainActor (String) -> Void)? = nil)
  {
    self.label = label
    self.text = text
    self.style = style
    self.width = width
    self.secure = secure
    self.submit = submit
  }
  public func build(_ c: inout BuildContext, id: String) {
    var s = text.get()
    let signal = c.ui.textField(id, text: &s, class: style, label: label, width: width, secure: secure)
    if signal.changed { text.set(s) }
    if signal.submitted { submit?(s) }
  }
}

/// A list of rows (only those in view are built), a row selected.
public struct List: View {
  let label: String, count: Int, rowHeight: Float, columns: [String], widths: [Float], numeric: [Bool]
  let selection: Binding<Int?>, state: (Int) -> String, row: (Int) -> [String]
  public init(_ label: String, count: Int, rowHeight: Float = 22, columns: [String] = [], widths: [Float],
              numeric: [Bool] = [], selection: Binding<Int?>, state: @escaping (Int) -> String = { _ in "" },
              row: @escaping (Int) -> [String])
  {
    self.label = label
    self.count = count
    self.rowHeight = rowHeight
    self.columns = columns
    self.widths = widths
    self.numeric = numeric
    self.selection = selection
    self.state = state
    self.row = row
  }
  public func build(_ c: inout BuildContext, id: String) {
    var s = selection.get()
    let before = s
    c.ui.list(id, label: label, count: count, rowHeight: rowHeight, columns: columns, widths: widths, numeric: numeric,
              selection: &s, state: state, row: row)
    if s != before { selection.set(s) }
  }
}

/// A box drawn by the app (after layout, in its rectangle), with the flags
/// it asks for (a terminal's: focusable, taking keys raw); `signal` is
/// what the pointer did, in the frame it's built.
public struct Drawing: View {
  let width: Size, height: Size, flags: BoxFlags, style: String
  let draw: @Sendable (inout Painter, Rect) -> Void
  let signal: (@MainActor (Signal, UInt64, inout UI) -> Void)?
  public init(width: Size, height: Size, class style: String = "default", flags: BoxFlags = [],
              draw: @escaping @Sendable (inout Painter, Rect) -> Void,
              signal: (@MainActor (Signal, UInt64, inout UI) -> Void)? = nil)
  {
    self.width = width
    self.height = height
    self.style = style
    self.flags = flags
    self.draw = draw
    self.signal = signal
  }
  public func build(_ c: inout BuildContext, id: String) {
    let key = UI.key(id, in: c.ui.openKey)
    let s = c.ui.custom(id, class: style, width: width, height: height, flags: flags, draw: draw)
    signal?(s, key, &c.ui)
  }
}

/// A scrollbar over content that isn't views (a terminal's scrollback;
/// M6l): `offset` (0 at the start) of `content`, `view` of it shown, kept
/// by the app. Views that don't fit a window scroll without one: the
/// window has its own bars.
public struct ScrollBar: View {
  let vertical: Bool, view: Float, content: Float, line: Float, offset: Binding<Float>
  public init(vertical: Bool = true, view: Float, content: Float, line: Float = Theme.cqw(3), offset: Binding<Float>) {
    (self.vertical, self.view, self.content, self.line, self.offset) = (vertical, view, content, line, offset)
  }
  public func build(_ c: inout BuildContext, id: String) {
    var o = offset.get()
    if c.ui.scrollbar(id, vertical: vertical, view: view, content: content, offset: &o, line: line) { offset.set(o) }
  }
}

/// Be's menu bar: menus of declared actions.
public struct MenuBar: View {
  let menus: [MenuSpec]
  public init(_ menus: [MenuSpec]) { self.menus = menus }
  public func build(_ c: inout BuildContext, id: String) { c.ui.menuBar(id, menus) }
}

/// An icon of the sheet, `size` logical pixels square.
public struct Icon: View {
  let name: String, size: Float, color: UInt32, emblem: UInt32, selected: Bool
  public init(_ name: String, size: Float, color: UInt32, emblem: UInt32 = 0, selected: Bool = false) {
    self.name = name
    self.size = size
    self.color = color
    self.emblem = emblem
    self.selected = selected
  }
  public func build(_ c: inout BuildContext, id: String) {
    let (name, size, color, emblem, selected) = (name, size, color, emblem, selected)
    c.ui.custom(id, width: .pixels(size), height: .pixels(size)) { p, r in
      p.icon(name, r.x, r.y, size: size, color: color, emblem: emblem, selected: selected)
    }
  }
}

/// Views made from a collection's elements, each keyed by its id.
public struct ForEach<Element, ID: Hashable>: View {
  let items: [Element], key: (Element) -> ID, content: (Element) -> Group
  public init(_ items: [Element], id key: @escaping (Element) -> ID, @ViewBuilder content: @escaping (Element) -> Group) {
    self.items = items
    self.key = key
    self.content = content
  }
  public func build(_ c: inout BuildContext, id: String) {
    for item in items { content(item).build(&c, id: id + "#" + String(describing: key(item))) }
  }
}

extension View {
  /// Keyed by `id` rather than by its place among its siblings, so it
  /// keeps its state when views before it come and go.
  public func id(_ id: String) -> some View { Keyed(base: self, key: id) }
}

struct Keyed<Base: View>: View {
  let base: Base, key: String
  func build(_ c: inout BuildContext, id: String) { base.build(&c, id: key) }
}

// MARK: Apps

/// An action, declared once, and what it does.
public struct ActionHandler {
  public let action: Action
  public let run: @MainActor (Invocation) async -> Void
  public init(_ action: Action, run: @escaping @MainActor (Invocation) async -> Void) {
    self.action = action
    self.run = run
  }
}

/// An app's window: its title, its actions and its content.
@MainActor
public protocol App: AnyObject {
  var title: String { get }
  var actions: [ActionHandler] { get }
  @ViewBuilder var body: Group { get }
  /// Before each frame is built: the window's size now (logical pixels),
  /// for what depends on it (a terminal's rows and columns).
  func prepare(width: Float, height: Float)
  /// Work still to do a frame at a time (a listing still coming): draw
  /// again without waiting for input.
  var busy: Bool { get }
  /// What a context menu's Route (`route.open`) sends to the plumber for
  /// `subject`, what was right-clicked: by default, as text from the
  /// root. nil sends nothing.
  func route(subject: String) -> Route?
  /// A frame's keys and text before it's built (M6m: a terminal sends them
  /// to its pty at once, so the echo is on its way while the frame is
  /// built): true takes them, and the frame is built without them.
  func takeInput(_ input: FrameInput) -> Bool
}

extension App {
  public func prepare(width: Float, height: Float) {}
  public func takeInput(_ input: FrameInput) -> Bool { false }
  public var busy: Bool { false }
  public func route(subject: String) -> Route? { Route(data: subject) }
}

/// A message for the plumber (plumber(4)): the sender's directory, its
/// type ("text", or a file's `sys:type`), the data, and attributes. The
/// platform sends it (the SDK's `Loop.route`).
public struct Route: Equatable, Sendable {
  public var wdir: String
  public var type: String
  public var data: String
  public var attributes: [(name: String, value: String)]
  public init(wdir: String = "/", type: String = "text", data: String,
              attributes: [(name: String, value: String)] = [])
  {
    self.wdir = wdir
    self.type = type
    self.data = data
    self.attributes = attributes
  }
  public static func == (a: Route, b: Route) -> Bool {
    a.wdir == b.wdir && a.type == b.type && a.data == b.data
      && a.attributes.map { $0.name } == b.attributes.map { $0.name }
      && a.attributes.map { $0.value } == b.attributes.map { $0.value }
  }
}

/// Runs an app's frames over UICore: builds its body, hands invocations
/// to its actions' handlers, and says when to draw again. A platform
/// (the SDK's loop, Radharc natively) feeds it input and presents what
/// it drew.
@MainActor
public final class Runner {
  public var ui: UI
  public let app: any App
  /// Actions whose handlers are running.
  public private(set) var running: [String] = []
  /// Tasks running handlers, by action.
  var tasks: [(action: String, task: Task<Void, Never>)] = []
  var waiting: [Invocation] = []
  /// Something happened outside a frame (a handler ended): draw again.
  public private(set) var wantsFrame = true
  /// Called when a handler ends, so a platform waiting for input wakes.
  public var wake: (@MainActor () -> Void)?
  /// Hears each invocation as it's dispatched (the app's intent stream,
  /// M6k k5b: the platform's).
  public var observe: (@MainActor (Invocation) -> Void)?
  /// May take an invocation before its handler (a claim): true, and the
  /// handler doesn't run (the claimer handled it); false, it does.
  public var intercept: (@MainActor (Invocation) async -> Bool)?
  /// Sends a route to the router (the platform's; none: routes go
  /// nowhere). A context menu's Route comes here through the app's
  /// `route(subject:)`.
  public var router: (@MainActor (Route) -> Void)?

  /// Whether the window scrolls, with bars, where its content doesn't fit
  /// (M6l). A panel, the desktop and an embedded view are sized to what
  /// they show, or fixed: they don't.
  public var scrolls = true

  /// The UI that stands in for `ui` while a frame is built (see frame).
  var spare: UI

  public init(app: any App, painter: Painter, width: Float, height: Float) {
    self.app = app
    ui = UI(painter: painter, width: width, height: height)
    spare = UI(painter: painter, width: 0, height: 0)
    ui.title = app.title
    for h in app.actions { ui.declare(h.action) }
  }

  /// One frame: whether it drew anything new (else present nothing).
  @discardableResult
  public func frame(_ input: FrameInput) -> Bool {
    wantsFrame = false
    app.prepare(width: ui.width, height: ui.height)
    ui.title = app.title
    var input = input
    if (!input.keys.isEmpty || !input.text.isEmpty) && app.takeInput(input) {
      input.keys = []
      input.text = ""
      input.sequence = []
    }
    ui.begin(input)
    // The UI is moved into the build's context and back, never copied: a
    // copy shares its arrays, and writing to shared arrays copies them
    // (M6m: a frame allocating nothing). A spare UI takes its place.
    var c = BuildContext(ui: spare)
    swap(&c.ui, &ui)
    // The window scrolls, with Be's bars, wherever its content doesn't fit
    // (M6l): nothing is out of reach without a resize.
    if scrolls {
      c.ui.openScroll("window", width: .percent(1), height: .percent(1))
      app.body.build(&c, id: "body")
      c.ui.close()
    } else {
      app.body.build(&c, id: "body")
    }
    swap(&c.ui, &ui)
    var invoked = c.invoked
    // Invocations no control took: keys, scripts, assistive clients.
    for h in app.actions {
      while let i = ui.take(h.action.name) { invoked.append(i) }
    }
    // A context menu's Route, unless the app handles it itself.
    if !app.actions.contains(where: { $0.action.name == "route.open" }) {
      while let i = ui.take("route.open") {
        if case .string(let subject)? = i.arguments.first, let r = app.route(subject: subject) { router?(r) }
      }
    }
    ui.end()
    for i in invoked { dispatch(i) }
    // An action ran after this frame was built (its title, its texts):
    // a frame more shows what it changed.
    // So did the title (typing marks a document modified).
    if ui.pending || app.busy || !invoked.isEmpty || app.title != ui.title { wantsFrame = true }
    return ui.changed
  }

  func dispatch(_ i: Invocation) {
    guard let h = app.actions.first(where: { $0.action.name == i.action }) else { return }
    if running.contains(i.action) {
      // One at a time: it waits for the one running.
      if !waiting.contains(where: { $0.action == i.action }) { waiting.append(i) }
      return
    }
    waiting.removeAll { $0.action == i.action }
    running.append(i.action)
    observe?(i)
    let intercept = intercept
    let task = Task { @MainActor [weak self] in
      if let intercept, await intercept(i) {
        self?.finished(i.action)
        return
      }
      await h.run(i)
      self?.finished(i.action)
    }
    tasks.append((i.action, task))
  }

  func finished(_ action: String) {
    running.removeAll { $0 == action }
    tasks.removeAll { $0.action == action }
    if let next = waiting.first(where: { $0.action == action }) { dispatch(next) }
    wantsFrame = true
    wake?()
  }

  /// Waits for every running handler (tests; quitting).
  public func settle() async {
    while let t = tasks.first {
      await t.task.value
    }
  }

  /// The frame's drawing.
  public var list: DisplayList { ui.painter.list }
}
