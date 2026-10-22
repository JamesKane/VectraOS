// SPDX-License-Identifier: BSD-3-Clause

// The file chooser's view (D111): Tracker's listing embedded by a view
// token in Radharc's trusted prompt when an app calls `choose`. It browses
// `/data` under Tracker's namespace, filters files by `types` when
// opening, provides a name field and New folder when saving, and opens a
// confined channel (`Volume.choose`) to the chosen file when confirmed.

import Kit
import Node
import Synchronization
import Sys
import Tracker
import UICore

@frozen public struct ChosenFile: ~Copyable, Sendable {
  public let path: String
  public var handle: Handle
  public init(path: String, handle: consuming Handle) {
    self.path = path
    self.handle = handle
  }
  public consuming func takeHandle() -> Handle { handle }
}

@MainActor public final class ChooserView: App {
  public private(set) var path: String
  public let volume: Volume
  public let save: Bool
  public let types: [String]
  public var fileName: String
  public var folder: Folder
  public var sort = SortOrder()
  final class Pending {
    var listing: Volume.Listing
    init(_ l: consuming Volume.Listing) { listing = l }
  }
  var pending: Pending?
  let inbox = Mutex<[NodeIPC.Change]>([])
  var untyped: [String] = []
  public var message: String?
  var reveal: Int?

  public init(path: String = "", volume: Volume, save: Bool, types: [String] = [], name: String = "")
    throws(TrackerError)
  {
    self.path = path
    self.volume = volume
    self.save = save
    self.types = types
    self.fileName = name
    self.folder = Folder(path: path, sort: sort)
    self.pending = Pending(try volume.list(path, columns: FolderState.defaultColumns))
  }

  public var title: String { save ? "Save File" : "Open File" }

  public var loaded: Bool { pending == nil }

  public var busy: Bool { pending != nil || !untyped.isEmpty }

  public nonisolated func deliver(_ changes: [NodeIPC.Change]) { inbox.withLock { $0 += changes } }

  public func navigate(to next: String) {
    guard let l = try? volume.list(next, columns: FolderState.defaultColumns) else {
      message = "Can't open folder"
      return
    }
    path = next
    folder = Folder(path: next, sort: sort)
    pending = Pending(l)
    untyped = []
    message = nil
  }

  public func prepare(width: Float, height: Float) {
    if let p = pending {
      for _ in 0..<4 where !p.listing.done {
        guard let batch = try? p.listing.next() else {
          message = "Can't list this folder"
          pending = nil
          break
        }
        folder.add(batch)
        untyped += batch.filter { !$0.isDirectory && $0.type == nil }.map { $0.name }
      }
      if pending != nil && p.listing.done {
        pending = nil
        folder.complete = true
      }
    }
    let changes = inbox.withLock { c -> [NodeIPC.Change] in
      defer { c.removeAll() }
      return c
    }
    if !changes.isEmpty {
      try? volume.apply(changes, to: &folder, columns: FolderState.defaultColumns)
      for c in changes where !c.name.isEmpty && c.kind != .removed {
        if let e = folder.entry(named: c.name), !e.isDirectory, e.type == nil, !untyped.contains(c.name) {
          untyped.append(c.name)
        }
      }
    }
    for _ in 0..<8 where !untyped.isEmpty {
      let name = untyped.removeFirst()
      let p = Path.join(path, name)
      if (try? volume.type(p)) != nil, let e = try? volume.stat(p) { folder.update(e) }
    }
  }

  /// Entries shown in the chooser: folders always (for navigation), and
  /// files matching `types`.
  public func visibleEntries() -> [Entry] {
    let all = folder.ordered()
    guard !types.isEmpty else { return all }
    return all.filter { e in
      if e.isDirectory { return true }
      let t = e.type ?? FileTypes.sniff([], name: e.name) ?? "application/octet-stream"
      return FileTypes.matches(t, allowed: types)
    }
  }

  public var actions: [ActionHandler] {
    [
      ActionHandler(Action("chooser.parent", label: "Up", key: KeyPress(.up, control: true))) { [self] _ in
        if !path.isEmpty { navigate(to: Path.split(path).folder) }
      },
      ActionHandler(Action("chooser.newFolder", label: "New folder")) { [self] _ in
        guard let name = try? volume.makeFolder(in: path), let e = try? volume.stat(Path.join(path, name)) else {
          return
        }
        folder.update(e)
        folder.select(e.node)
      },
    ]
  }

  /// Selects an entry by index in `visibleEntries()`.
  public func select(_ e: Entry) {
    folder.select(e.node)
    if !e.isDirectory && save { fileName = e.name }
    message = nil
  }

  /// The path from `/data`'s root that confirming now would open or save;
  /// nil if none is selected (`open`) or the name is blank/invalid (`save`).
  public func chosenPath() -> String? {
    if save {
      var trimmed = Substring(fileName)
      while trimmed.first == " " { trimmed = trimmed.dropFirst() }
      while trimmed.last == " " { trimmed = trimmed.dropLast() }
      let name = String(trimmed)
      guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
      return Path.join(path, name)
    }
    guard let e = folder.selected().first, !e.isDirectory else { return nil }
    return Path.join(path, e.name)
  }

  /// Opens the chosen file channel (`writable: save`) and returns its path
  /// in `/data` and the confined file `Handle`, or navigates into a selected
  /// directory and returns `nil`.
  public func confirm() throws(TrackerError) -> ChosenFile? {
    if !save, let e = folder.selected().first, e.isDirectory {
      navigate(to: Path.join(path, e.name))
      return nil
    }
    guard let p = chosenPath() else { throw .badName }
    let h = try volume.choose(p, writable: save, types: types)
    return ChosenFile(path: p, handle: h)
  }

  public var body: Group {
    let c = Theme.cqw
    VStack(width: .percent(1), height: .percent(1)) {
      HStack(class: "query", width: .percent(1)) {
        Text("Taisce · \(path.isEmpty ? "/" : "/" + path)", class: "query.label")
        Spacer()
        if !path.isEmpty {
          Button(action: "chooser.parent")
        }
        if save {
          Spacer(c(0.4))
          Button(action: "chooser.newFolder")
        }
      }
      ChooserContent(view: self)
      if save {
        HStack(class: "query", width: .percent(1)) {
          Text("Name", class: "query.label")
          Spacer(c(0.5))
          TextField("File name", text: Binding(self, \.fileName)).id("name")
        }
      }
    }
  }
}

struct ChooserContent: View {
  let view: ChooserView

  @MainActor func build(_ c: inout BuildContext, id: String) {
    let v = view
    let input = c.ui.frameInput
    let visible = v.visibleEntries()
    if c.ui.focus == 0 {
      for k in input.keys where !k.control && !k.alt {
        switch k.key {
        case .down, .up:
          guard !visible.isEmpty else { continue }
          let delta = k.key == .down ? 1 : -1
          let current = visible.firstIndex { v.folder.selection.contains($0.node) }
          let next = current.map { min(max($0 + delta, 0), visible.count - 1) } ?? (delta < 0 ? visible.count - 1 : 0)
          v.select(visible[next])
          v.reveal = next
        case .enter:
          if let e = visible.first(where: { v.folder.selection.contains($0.node) }), e.isDirectory {
            v.navigate(to: Path.join(v.path, e.name))
          }
        default: break
        }
      }
    }
    let theme = c.ui.theme
    let cq = Theme.cqw
    let columns = [Column.name, Column.size, Column.type]
    let sizeW = cq(6), typeW = cq(10)
    let nameW = max(cq(10), c.ui.width - sizeW - typeW)
    let widths = [nameW, sizeW, typeW]
    let reveal = v.reveal
    v.reveal = nil
    var none = ""
    let events = c.ui.table(id, label: v.title, count: visible.count, rowHeight: cq(1.9),
                            columns: columns.map(Column.title), widths: widths, numeric: columns.map(Column.numeric),
                            sort: nil, editText: &none, reveal: reveal) { r in
      let e = visible[r]
      return TableRow(cells: columns.map { e.text($0) }, icon: FolderWindow.icon(e, in: v.path, theme: theme),
                      state: v.folder.selection.contains(e.node) ? "selected" : "")
    }
    for (r, s) in events.rows where r < visible.count {
      let e = visible[r]
      if s.pressed { v.select(e) }
      if s.doubleClicked && e.isDirectory { v.navigate(to: Path.join(v.path, e.name)) }
    }
  }
}
