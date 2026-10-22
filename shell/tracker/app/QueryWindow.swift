// SPDX-License-Identifier: BSD-3-Clause

// A query's window (M6j part 3d, board 02: "A query is a folder, and it
// stays live"): the query bar (its text, editable; Enter runs it again
// and keeps it in the query file), the matches as the list's rows, their
// columns the query's (the name and the attributes it names, or what its
// file keeps), a match that arrived live shown as new, and the status
// line: "live · added "Teardrop" at journal seq 48213" and "7 matches ·
// 0.6 ms" (to the first matches' end). Its host runs the live query on a
// thread and delivers its changes, under the window's generation (the
// text it ran); what's selected opens, routes or goes to the Trash as in
// a folder.

import Fs
import Kit
import Synchronization
import Tracker
import UICore

@MainActor public final class QueryWindow: App {
  public let path: String
  public let volume: Volume
  public weak var host: TrackerHost?
  /// The query bar's text, and the text running.
  public var text: String
  public private(set) var running: String
  public var results: QueryResults
  public var state: FolderState
  /// Which run's changes are wanted (the host's are tagged with it).
  public private(set) var generation: UInt64 = 1
  let inbox = Mutex<[(UInt64, [FsIPC.QueryChange])]>([])
  /// A run that couldn't start (its text doesn't parse).
  let failure = Mutex<(UInt64, TrackerError)?>(nil)
  /// When the run began, and how long its first matches took (ns).
  var began: Int64 = 0
  public private(set) var elapsed: Int64?
  public var message: String?
  var reveal: Int?
  /// Matches still to type, by node.
  var untyped: [UInt64] = []
  let clock: () -> Int64

  public init(path: String, volume: Volume, host: TrackerHost?, clock: @escaping () -> Int64) throws(TrackerError) {
    self.path = path
    self.volume = volume
    self.host = host
    self.clock = clock
    text = try volume.queryText(path)
    running = text
    state = try volume.state(path)
    if state.columns == FolderState.defaultColumns { state.columns = QueryResults.columns(for: text) }
    results = QueryResults(path: path, sort: state.sort)
    began = clock()
  }

  public var title: String { Path.name(path) + " · query" }

  /// A run's changes (any thread); those of an older run are dropped.
  public nonisolated func deliver(_ changes: [FsIPC.QueryChange], generation: UInt64) {
    inbox.withLock { $0.append((generation, changes)) }
  }

  /// A run couldn't start (any thread).
  public nonisolated func failed(_ error: TrackerError, generation: UInt64) {
    failure.withLock { $0 = (generation, error) }
  }

  /// Runs the bar's text: kept in the file, then run anew.
  public func run() {
    guard text != running else { return }
    running = text
    try? volume.setQueryText(path, text)
    let columns = QueryResults.columns(for: text)
    if state.columns != columns {
      state.columns = columns
      try? volume.save(state, path)
    }
    results = QueryResults(path: path, sort: state.sort)
    untyped = []
    generation += 1
    elapsed = nil
    began = clock()
    message = nil
    host?.run(self)
  }

  public func prepare(width: Float, height: Float) {
    keepSize(width, height)
    if let (g, e) = failure.withLock({ f in defer { f = nil }; return f }), g == generation {
      message = e == .badQuery ? "The query doesn't parse" : "The query can't run"
    }
    let batches = inbox.withLock { b -> [(UInt64, [FsIPC.QueryChange])] in
      defer { b.removeAll() }
      return b
    }
    for (g, changes) in batches where g == generation {
      let wasCurrent = results.current
      let before = Set(results.folder.entries.map { $0.node })
      results.apply(changes, volume: volume)
      if !wasCurrent && results.current { elapsed = clock() - began }
      for e in results.folder.entries where !before.contains(e.node) && !e.isDirectory && e.type == nil {
        untyped.append(e.node)
      }
    }
    // Types, a few a frame, as a folder's.
    for _ in 0..<8 where !untyped.isEmpty {
      let node = untyped.removeFirst()
      guard let p = results.paths[node], (try? volume.type(p)) != nil, let e = try? volume.stat(p) else { continue }
      results.folder.update(e, byNode: true)
    }
  }

  public var busy: Bool { !untyped.isEmpty }

  /// The window moved, or was sized: kept, as a folder's.
  public func moved(x: Int32, y: Int32) {
    let f = state.frame
    state.frame = (x, y, f?.width ?? 0, f?.height ?? 0)
    if (f?.width ?? 0) > 0 { try? volume.save(state, path) }
  }

  /// Its size, kept with its place.
  func keepSize(_ width: Float, _ height: Float) {
    let f = state.frame
    guard f.map({ $0.width != Int32(width) || $0.height != Int32(height) }) ?? true else { return }
    state.frame = (f?.x ?? 0, f?.y ?? 0, Int32(width), Int32(height))
    try? volume.save(state, path)
  }

  public var actions: [ActionHandler] {
    func ctrl(_ c: Character) -> KeyPress { KeyPress(.character(c.unicodeScalars.first!.value), control: true) }
    return [
      ActionHandler(Action("query.run", label: "Run query", key: ctrl("r"))) { [self] _ in run() },
      ActionHandler(Action("tracker.open", label: "Open", key: ctrl("o"))) { [self] _ in openSelected() },
      ActionHandler(Action("tracker.trash", label: "Move to Trash", key: ctrl("t"))) { [self] _ in trashSelected() },
      ActionHandler(Action("tracker.selectAll", label: "Select all", key: ctrl("a"))) { [self] _ in
        results.folder.selectAll()
      },
      ActionHandler(Action("window.close", label: "Close", key: ctrl("w"))) { [self] _ in host?.close(self) },
      ActionHandler(Action("tracker.quit", label: "Quit Tracker", key: ctrl("q"))) { [self] _ in host?.quit() },
      routeAction(volume, { [weak self] in self?.host }) { [weak self] m in self?.message = m },
    ]
  }

  func matchPath(_ e: Entry) -> String? { results.paths[e.node] }

  public func openSelected() {
    for e in results.folder.selected() { open(e) }
  }

  public func open(_ e: Entry) {
    guard let p = matchPath(e) else { return }
    if e.isDirectory {
      host?.open(folder: p)
    } else if e.type == FileTypes.query {
      host?.open(query: p)
    } else {
      message = host?.route(e, at: p)
    }
  }

  public func trashSelected() {
    let paths = results.folder.selected().compactMap { matchPath($0) }
    guard !paths.isEmpty else { return }
    if (try? volume.trash(paths)) == nil { message = "Can't move to the Trash" }
    // The live query says they're gone.
  }

  public func sort(by column: String) {
    var s = state.sort
    if s.column == column { s.descending.toggle() } else { s = SortOrder(column) }
    state.sort = s
    results.folder.sort = s
    try? volume.save(state, path)
  }

  public var body: Group {
    let c = Theme.cqw
    VStack(width: .percent(1), height: .percent(1)) {
      MenuBar([MenuSpec("Query", ["query.run", "tracker.open", "tracker.trash", "window.close"]),
               MenuSpec("Edit", ["edit.undo", "edit.redo", "tracker.selectAll"])])
      HStack(class: "query", width: .percent(1)) {
        Text("Query", class: "query.label")
        Spacer(c(0.6))
        TextField("Query", text: Binding(self, \.text)) { [self] _ in run() }.id("query")
      }
      QueryContent(window: self)
      HStack(class: "status", width: .percent(1)) {
        if let m = message {
          Text(m, class: "status")
        } else if let a = results.lastAdded {
          Text("live · added \"\(a.name)\" at journal seq \(a.seq)", class: "status.live")
        } else {
          Text(results.current ? "live" : "running…", class: results.current ? "status.live" : "status")
        }
        Spacer()
        Text(countLine, class: "status")
      }
    }
  }

  var countLine: String {
    let n = results.folder.entries.count
    let matches = n == 1 ? "1 match" : "\(n) matches"
    guard let ns = elapsed else { return matches }
    let tenths = (ns + 50_000) / 100_000
    return "\(matches) · \(tenths / 10).\(tenths % 10) ms"
  }
}

/// A query's matches as the list's rows.
struct QueryContent: View {
  let window: QueryWindow

  @MainActor func build(_ c: inout BuildContext, id: String) {
    let w = window
    let input = c.ui.frameInput
    if c.ui.focus == 0 {
      for k in input.keys where !k.control && !k.alt {
        switch k.key {
        case .down, .up:
          guard let next = w.results.folder.neighbour(k.key == .down ? 1 : -1) else { continue }
          w.results.folder.select(next.node, k.shift ? .range : .only)
          w.reveal = w.results.folder.ordered().firstIndex { $0.node == next.node }
        case .enter: w.openSelected()
        case .delete: w.trashSelected()
        case .escape: w.results.folder.clearSelection()
        default: break
        }
      }
    }
    let theme = c.ui.theme
    let order = w.results.folder.ordered()
    let columns = w.state.columns
    let cq = Theme.cqw
    var widths = columns.map { col -> Float in
      col == Column.size ? cq(6) : col == Column.modified ? cq(8) : col.hasSuffix(":Year") ? cq(7) : cq(12)
    }
    if let n = columns.firstIndex(of: Column.name) {
      widths[n] = max(cq(12), c.ui.width - widths.enumerated().filter { $0.offset != n }.reduce(0) { $0 + $1.element })
    }
    let sortIndex = w.state.sort == SortOrder() ? nil : columns.firstIndex(of: w.state.sort.column)
    let reveal = w.reveal
    w.reveal = nil
    var none = ""
    let events = c.ui.table(id, label: w.title, count: order.count, rowHeight: cq(1.9), columns: columns.map(Column.title),
                            widths: widths, numeric: columns.map { Column.numeric($0) || $0.hasSuffix(":Year") },
                            sort: sortIndex.map { ($0, w.state.sort.descending) }, editText: &none, reveal: reveal) { r in
      let e = order[r]
      let selected = w.results.folder.selection.contains(e.node)
      return TableRow(cells: columns.map { e.text($0) }, icon: FolderWindow.icon(e, in: "-", theme: theme),
                      state: selected ? "selected" : w.results.arrived.contains(e.node) ? "new" : "")
    }
    if let h = events.header { w.sort(by: columns[h]) }
    for (r, s) in events.rows where r < order.count {
      let e = order[r]
      if s.secondaryPressed {
        if !w.results.folder.selection.contains(e.node) { w.results.folder.select(e.node) }
        c.ui.openContextMenu("match", subject: w.matchPath(e) ?? e.name)
        continue
      }
      if s.pressed {
        w.message = nil
        w.results.folder.select(e.node, input.shift ? .range : input.control ? .toggle : .only)
      }
      if s.doubleClicked { w.open(e) }
    }
    if events.background.pressed { w.results.folder.clearSelection() }
    c.ui.contextMenu("match", items: ["tracker.open", "tracker.trash"])
  }
}
