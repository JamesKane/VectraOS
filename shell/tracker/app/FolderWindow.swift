// SPDX-License-Identifier: BSD-3-Clause

// A folder's window (M6j part 3c): Tracker's spatial window as a Kit app.
// Board 01's list view (Name, Size, Modified, sys:type: each column a
// field or an attribute, a header clicked to sort, folders first) or Be's
// icon view (each entry at its kept place, or the next free one in a
// grid; dragged to a new one); Be's menu bar in the window; a right-click
// on an entry opens its context menu, Route first (the plumber, M6k), then
// Open, Rename, Move to Trash; on the ground, New folder and the views.
// The keyboard: arrows (Shift extends), Enter opens, Delete trashes, F2
// renames in place (Enter keeps, Escape doesn't), typing finds a name,
// Control-Up opens the parent. The listing comes a batch a frame, so a
// large folder shows at once and fills in; the watch's changes come from
// a thread of the host's (`deliver`) and are applied before a frame;
// files without a type get theirs a few a frame. Its window state (frame,
// view, columns, sort) is kept in the folder's attributes as it changes.

import Kit
import Node
import Synchronization
import Tracker
import UICore

/// What a folder's window asks of Tracker (its program: the native host,
/// or a test's).
@MainActor public protocol TrackerHost: AnyObject {
  /// Opens `path`'s window, or brings it forward if it's open.
  func open(folder path: String)
  /// Opens a query file's window (3d).
  func open(query path: String)
  /// Runs a query window's text live (again, if it changed): its changes
  /// come through `deliver`, under the window's `generation`.
  func run(_ query: QueryWindow)
  /// Closes the window (its state is kept already).
  func close(_ window: any App)
  /// Control-Q: the host may end Tracker (a test's does).
  func quit()
  /// Sends what's opened or routed (M6k: a file, by its type; a folder,
  /// as text) to the plumber, its path from the volume's root: why it
  /// went nowhere, or nil.
  func route(_ path: String, type: String) -> String?
  /// The add-ons (M6l): apps whose manifests say `addon LABEL`.
  func addOns() -> [AddOn]
  /// Starts add-on `service` with `paths` (from the volume's root): why
  /// it couldn't, or nil.
  func run(addOn service: String, paths: [String]) -> String?
}

/// The files copied or cut (M6l, Be's Copy, Cut and Paste of files):
/// every window of Tracker's shares it; a paste of a cut moves them, and
/// empties it.
@MainActor public final class FileClipboard {
  public static let shared = FileClipboard()
  /// Paths from the volume's root.
  public var paths: [String] = []
  public var cut = false
  public init() {}
}

extension TrackerHost {
  /// Routes the entry at `path` (Open on a file, or Route on anything):
  /// a file by its `sys:type`, a folder as its path in text.
  func route(_ e: Entry, at path: String) -> String? {
    route(path, type: e.isDirectory ? "text" : e.type ?? "application/octet-stream")
  }
}

/// Route, the context menu's first item, handled by Tracker itself: its
/// subject is a path from the volume's root, sent with the entry's type.
@MainActor func routeAction(_ volume: Volume, _ host: @escaping @MainActor () -> TrackerHost?,
                            _ said: @escaping @MainActor (String?) -> Void) -> ActionHandler
{
  ActionHandler(Action("route.open", label: "Route", arguments: [ActionArgument("subject", .string)],
                       gesture: "a right-click's context menu")) { i in
    guard case .string(let path)? = i.arguments.first, let e = try? volume.stat(path) else { return }
    said(host()?.route(e, at: path))
  }
}

@MainActor public final class FolderWindow: App {
  public let path: String
  /// The desktop (3e): the folder's icons over the storyboard's grid,
  /// down the screen's left as Be's desktop had them; no menu bar or
  /// status line, and no frame of its own to keep.
  public let desktop: Bool
  public let volume: Volume
  public weak var host: TrackerHost?
  public var folder: Folder
  public var state: FolderState
  /// The listing still coming, a batch a frame.
  final class Pending {
    var listing: Volume.Listing
    init(_ l: consuming Volume.Listing) { listing = l }
  }
  var pending: Pending?
  /// Changes from the watch, delivered on the host's thread.
  let inbox = Mutex<[NodeIPC.Change]>([])
  /// Files still to type, by name.
  var untyped: [String] = []
  /// The volumes, the desktop's (M6l, Be's): shown before its icons; the
  /// host gives them.
  public var volumes: [VolumeInfo] = []
  /// A line for the status bar in place of the count (an open that has
  /// nowhere to go yet), until the next change of selection.
  public var message: String?
  /// The entry being renamed, and its text.
  public var renaming: UInt64?
  public var renameText = ""
  var reveal: Int?
  var typed = (text: "", time: Int64(0))
  /// The size the window was last drawn at.
  var size: (Float, Float)?

  /// A window onto `path`, its state from its attributes; the listing
  /// starts.
  public init(path: String, volume: Volume, host: TrackerHost?, desktop: Bool = false) throws(TrackerError) {
    self.path = path
    self.desktop = desktop
    self.volume = volume
    self.host = host
    state = try volume.state(path)
    if desktop { state.view = .icons }
    folder = Folder(path: path, sort: state.sort)
    pending = Pending(try volume.list(path, columns: state.columns))
  }

  public var title: String { path.isEmpty ? "Taisce" : Path.name(path) }

  /// The watch's changes (any thread): applied before the next frame.
  public nonisolated func deliver(_ changes: [NodeIPC.Change]) { inbox.withLock { $0 += changes } }

  /// Whether the listing has come whole.
  public var loaded: Bool { pending == nil }

  public var busy: Bool { pending != nil || !untyped.isEmpty }

  public func prepare(width: Float, height: Float) {
    // The listing, a few batches a frame.
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
    // The watch's changes.
    let changes = inbox.withLock { c -> [NodeIPC.Change] in
      defer { c.removeAll() }
      return c
    }
    if !changes.isEmpty {
      try? volume.apply(changes, to: &folder, columns: state.columns)
      for c in changes where !c.name.isEmpty && c.kind != .removed {
        if let e = folder.entry(named: c.name), !e.isDirectory, e.type == nil, !untyped.contains(c.name) {
          untyped.append(c.name)
        }
      }
    }
    // Types, a few a frame (each reads a file's first bytes).
    for _ in 0..<8 where !untyped.isEmpty {
      let name = untyped.removeFirst()
      let p = Path.join(path, name)
      if (try? volume.type(p)) != nil, let e = try? volume.stat(p) { folder.update(e) }
    }
    // The window's size, kept (its place comes with `moved`).
    if !desktop && size.map({ $0 != (width, height) }) ?? true {
      size = (width, height)
      let x = state.frame?.x ?? 0, y = state.frame?.y ?? 0
      let f = (x: x, y: y, width: Int32(width), height: Int32(height))
      if state.frame.map({ $0.width != f.width || $0.height != f.height }) ?? true {
        state.frame = f
        save()
      }
    }
  }

  /// The window moved: kept.
  public func moved(x: Int32, y: Int32) {
    let w = state.frame?.width ?? Int32(size?.0 ?? 0), h = state.frame?.height ?? Int32(size?.1 ?? 0)
    state.frame = (x, y, w, h)
    save()
  }

  func save() { try? volume.save(state, path) }

  // MARK: Actions

  public var actions: [ActionHandler] {
    func ctrl(_ c: Character) -> KeyPress { KeyPress(.character(c.unicodeScalars.first!.value), control: true) }
    return [
      ActionHandler(Action("tracker.open", label: "Open", key: ctrl("o"))) { [self] _ in openSelected() },
      ActionHandler(Action("tracker.parent", label: "Open parent", key: KeyPress(.up, control: true))) { [self] _ in
        if !path.isEmpty { host?.open(folder: Path.split(path).folder) }
      },
      ActionHandler(Action("tracker.newFolder", label: "New folder", key: ctrl("n"))) { [self] _ in newFolder() },
      ActionHandler(Action("tracker.newQuery", label: "New query",
                           key: KeyPress(.character(0x6E), shift: true, control: true))) { [self] _ in newQuery() },
      ActionHandler(Action("tracker.rename", label: "Rename", key: KeyPress(.function(2)))) { [self] _ in
        startRename()
      },
      ActionHandler(Action("tracker.trash", label: "Move to Trash", key: ctrl("t"))) { [self] _ in trashSelected() },
      ActionHandler(Action("tracker.selectAll", label: "Select all", key: ctrl("a"))) { [self] _ in folder.selectAll() },
      ActionHandler(Action("tracker.list", label: "As list", key: ctrl("1"))) { [self] _ in setView(.list) },
      ActionHandler(Action("tracker.icons", label: "As icons", key: ctrl("2"))) { [self] _ in setView(.icons) },
      // Be's (M6l): mini icons, Clean up, the Desktop menu's walk, New from
      // a template.
      ActionHandler(Action("tracker.mini", label: "As mini icons", key: ctrl("3"))) { [self] _ in setView(.mini) },
      ActionHandler(Action("tracker.cleanUp", label: "Clean up")) { [self] _ in cleanUp() },
      ActionHandler(Action("tracker.go", label: "Open", arguments: [ActionArgument("path", .string)],
                           gesture: "the Desktop menu")) { [self] i in
        if case .string(let p)? = i.arguments.first { go(p) }
      },
      ActionHandler(Action("tracker.newFrom", label: "New from template", arguments: [ActionArgument("template", .string)],
                           gesture: "the New menu")) { [self] i in
        if case .string(let t)? = i.arguments.first { newFrom(template: t) }
      },
      // Be's (M6l part l4b): files copied, cut and pasted; Select… by a
      // name pattern; add-ons.
      ActionHandler(Action("tracker.copy", label: "Copy", key: ctrl("c"))) { [self] _ in clip(cut: false) },
      ActionHandler(Action("tracker.cut", label: "Cut", key: ctrl("x"))) { [self] _ in clip(cut: true) },
      ActionHandler(Action("tracker.paste", label: "Paste", key: ctrl("v"))) { [self] _ in paste() },
      ActionHandler(Action("tracker.select", label: "Select…", key: KeyPress(.character(0x61), shift: true, control: true)))
      { [self] _ in
        selecting = selecting ?? ""
      },
      // Volumes (M6l part l5b): the boot volume opens; it stays mounted.
      ActionHandler(Action("tracker.volume", label: "Open", arguments: [ActionArgument("volume", .string)],
                           gesture: "a volume's icon or the Mount menu")) { [self] _ in host?.open(folder: "") },
      ActionHandler(Action("tracker.unmount", label: "Unmount", gesture: "a volume's menu")) { [self] _ in
        message = "The boot volume stays mounted"
      },
      ActionHandler(Action("tracker.addOn", label: "Add-on", arguments: [ActionArgument("service", .string)],
                           gesture: "the Add-ons menu")) { [self] i in
        if case .string(let s)? = i.arguments.first { runAddOn(s) }
      },
      ActionHandler(Action("window.close", label: "Close", key: ctrl("w"))) { [self] _ in
        if !desktop { host?.close(self) }
      },
      ActionHandler(Action("tracker.quit", label: "Quit Tracker", key: ctrl("q"))) { [self] _ in host?.quit() },
      routeAction(volume, { [weak self] in self?.host }) { [weak self] m in self?.message = m },
    ]
  }

  public func openSelected() {
    for e in folder.selected() { open(e) }
  }

  /// A folder opens its window, a query its window; a file goes to the
  /// plumber, which starts the app for its type.
  public func open(_ e: Entry) {
    if e.isDirectory {
      host?.open(folder: Path.join(path, e.name))
    } else if e.type == FileTypes.query {
      host?.open(query: Path.join(path, e.name))
    } else {
      message = host?.route(e, at: Path.join(path, e.name))
    }
  }

  public func newFolder() {
    guard let name = try? volume.makeFolder(in: path), let e = try? volume.stat(Path.join(path, name)) else { return }
    folder.update(e)
    folder.select(e.node)
    startRename()
  }

  /// A new query file here, opened.
  public func newQuery() {
    guard let p = try? volume.makeQuery(in: path, text: "name == \"*\"") else { return }
    if let e = try? volume.stat(p) { folder.update(e) }
    host?.open(query: p)
  }

  public func startRename() {
    guard let e = folder.selected().first else { return }
    renaming = e.node
    renameText = e.name
  }

  public func finishRename(keep: Bool) {
    defer { renaming = nil }
    guard keep, let node = renaming, let e = folder.entry(node: node), renameText != e.name else { return }
    do throws(TrackerError) {
      try volume.rename(Path.join(path, e.name), to: renameText)
      if let n = try? volume.stat(Path.join(path, renameText)) { folder.update(n) }
    } catch {
      message = error == .exists ? "\"\(renameText)\" is taken here" : "Can't rename \"\(e.name)\""
    }
  }

  public func trashSelected() {
    let names = folder.selected().map { $0.name }
    guard !names.isEmpty else { return }
    if (try? volume.trash(names.map { Path.join(path, $0) })) != nil {
      for n in names { folder.remove(named: n) }
    } else {
      message = "Can't move to the Trash"
    }
  }

  // MARK: Copy, Cut, Paste, Select…, add-ons (M6l part l4b)

  /// The selection to the clipboard: to copy, or to move when pasted.
  public func clip(cut: Bool) {
    let names = folder.selected().map { $0.name }
    guard !names.isEmpty else { return }
    FileClipboard.shared.paths = names.map { Path.join(path, $0) }
    FileClipboard.shared.cut = cut
    message = "\(names.count == 1 ? "1 item" : "\(names.count) items") \(cut ? "cut" : "copied")"
  }

  /// The clipboard's files here: copied (a free name where one's taken),
  /// or moved if they were cut (the clipboard empties). Each pasted one
  /// is selected.
  public func paste() {
    let clip = FileClipboard.shared
    guard !clip.paths.isEmpty else { return }
    var pasted: [UInt64] = [], failed = 0
    for p in clip.paths {
      do throws(TrackerError) {
        let name: String
        if clip.cut {
          guard Path.split(p).folder != path else { continue }  // already here
          if (try? volume.stat(p))?.isDirectory == true && (path == p || path.hasPrefix(p + "/")) { throw .badName }
          name = volume.free(Path.name(p), in: path)
          try volume.move(p, to: Path.join(path, name))
        } else {
          name = try volume.copy(p, into: path)
        }
        if let e = try? volume.stat(Path.join(path, name)) {
          folder.update(e)
          pasted.append(e.node)
        }
      } catch {
        failed += 1
      }
    }
    if clip.cut {
      clip.paths = []
      clip.cut = false
    }
    folder.clearSelection()
    for n in pasted { folder.select(n, .toggle) }
    message = failed > 0 ? "Couldn't paste \(failed == 1 ? "1 item" : "\(failed) items") here" : nil
  }

  /// Select…'s pattern while its field is open.
  public var selecting: String?

  /// Selects every entry whose name matches `pattern` (Be's Select…).
  public func select(matching pattern: String) {
    folder.clearSelection()
    for e in folder.entries where NamePattern.matches(pattern, e.name) { folder.select(e.node, .toggle) }
    let n = folder.selection.count
    message = n == 0 ? "Nothing matches \(pattern)" : nil
  }

  /// Starts add-on `service` with the selection's paths, or the folder's
  /// when nothing's selected.
  public func runAddOn(_ service: String) {
    let chosen = folder.selected().map { Path.join(path, $0.name) }
    message = host?.run(addOn: service, paths: chosen.isEmpty ? [path] : chosen)
  }

  /// The Add-ons menu: each add-on, or none.
  public func addOnMenu() -> [MenuItem] {
    let all = host?.addOns() ?? []
    if all.isEmpty { return [MenuItem("tracker.addOn", label: "No add-ons", dimmed: true)] }
    return all.map { MenuItem("tracker.addOn", label: $0.label, arguments: [.string($0.service)]) }
  }

  // MARK: Be's menus (M6l)

  /// Where a template lives: a file there is a New item.
  public static let templates = "Templates"

  /// Opens what's at `path` (from the volume's root): a folder's window,
  /// a query's, or a file routed (the Desktop menu's walk).
  public func go(_ path: String) {
    if path.isEmpty {
      host?.open(folder: "")
      return
    }
    guard let e = try? volume.stat(path) else { return }
    if e.isDirectory {
      host?.open(folder: path)
    } else if e.type == FileTypes.query {
      host?.open(query: path)
    } else {
      message = host?.route(e, at: path)
    }
  }

  /// A new file here from template `name` (Templates' file, copied with
  /// its attributes), renamed in place.
  public func newFrom(template name: String) {
    guard let given = try? volume.copy(Path.join(Self.templates, name), into: path),
      let e = try? volume.stat(Path.join(path, given))
    else {
      message = "Can't make a \(name) here"
      return
    }
    folder.update(e)
    folder.select(e.node)
    startRename()
  }

  /// Every icon back on the grid, in the folder's order (Be's Clean up):
  /// their kept places forgotten.
  public func cleanUp() {
    for e in folder.entries where e.place != nil {
      let p = Path.join(path, e.name)
      try? volume.removeAttribute(p, FolderState.placeAttribute)
      if let n = try? volume.stat(p) { folder.update(n) }
    }
  }

  /// The last frame's time (the menus' listings are this old).
  var now: Int64 = 0

  /// Folders' entries for the menus, listed again after a few seconds.
  var listed: [String: (time: Int64, entries: [Entry])] = [:]
  func entries(of folder: String, now: Int64) -> [Entry] {
    if let l = listed[folder], now - l.time < 3_000_000_000 { return l.entries }
    var es = (try? volume.entries(folder)) ?? []
    es.sort { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.lowercased() < b.name.lowercased() }
    listed[folder] = (now, es)
    return es
  }

  /// The Desktop menu's walk (Be's): `folder`'s entries, a folder's with
  /// its own as a submenu; any chosen opens.
  func walk(_ folder: String, now: Int64) -> [MenuItem] {
    let es = entries(of: folder, now: now)
    if es.isEmpty { return [MenuItem("tracker.go", label: "Empty", dimmed: true)] }
    return es.map { e in
      let p = Path.join(folder, e.name)
      guard e.isDirectory else { return MenuItem("tracker.go", label: e.name, arguments: [.string(p)]) }
      return MenuItem("tracker.go", label: e.name, arguments: [.string(p)], holds: ["tracker.go"]) { [self] in
        walk(p, now: now)
      }
    }
  }

  /// The New menu: a folder, a query, then each template.
  func newMenu(now: Int64) -> [MenuItem] {
    var out = [MenuItem("tracker.newFolder"), MenuItem("tracker.newQuery")]
    let ts = entries(of: Self.templates, now: now).filter { !$0.isDirectory }
    for (n, t) in ts.enumerated() {
      out.append(MenuItem("tracker.newFrom", label: t.name, arguments: [.string(t.name)], ruleBefore: n == 0))
    }
    return out
  }

  /// Mount (Be's, the desktop's): the volumes (the boot volume mounted;
  /// mounting others waits for more than one fs service).
  func mountMenu() -> [MenuItem] {
    volumes.map { MenuItem("tracker.volume", label: $0.name + ($0.boot ? " (mounted)" : ""), arguments: [.string($0.name)]) }
      + [MenuItem("tracker.volume", label: "No other volumes", dimmed: true, ruleBefore: !volumes.isEmpty)]
  }

  /// A volume's context menu: Open, and Unmount (not the boot volume's).
  func volumeMenu(_ v: VolumeInfo) -> [MenuItem] {
    [MenuItem("tracker.volume", label: "Open", arguments: [.string(v.name)]), MenuItem("tracker.unmount", dimmed: v.boot)]
  }

  /// The ground's context menu (Be's desktop's): Desktop, New, the views,
  /// Clean up, Select all; on the desktop, Mount.
  func groundMenu(now: Int64) -> [MenuItem] {
    var out = groundItems(now: now)
    if desktop {
      out.insert(.submenu("Mount", holds: ["tracker.volume"]) { [self] in mountMenu() }, at: 2)
    }
    return out
  }

  func groundItems(now: Int64) -> [MenuItem] {
    [MenuItem("tracker.go", label: "Desktop", arguments: [.string("")], holds: ["tracker.go"]) { [self] in
       walk("", now: now)
     },
     .submenu("New", holds: ["tracker.newFolder", "tracker.newQuery", "tracker.newFrom"]) { [self] in newMenu(now: now) },
     MenuItem("tracker.paste", dimmed: FileClipboard.shared.paths.isEmpty, ruleBefore: true),
     MenuItem("tracker.icons", ruleBefore: true), MenuItem("tracker.mini"), MenuItem("tracker.list"),
     MenuItem("tracker.cleanUp", dimmed: state.view == .list, ruleBefore: true), MenuItem("tracker.select"),
     MenuItem("tracker.selectAll"),
     .submenu("Add-ons", ruleBefore: true, holds: ["tracker.addOn"]) { [self] in addOnMenu() }]
  }

  /// An entry's context menu: Open, Rename, Copy, Cut, Move to Trash,
  /// Add-ons (after Route).
  func entryMenu() -> [MenuItem] {
    [MenuItem("tracker.open"), MenuItem("tracker.rename"), MenuItem("tracker.copy", ruleBefore: true),
     MenuItem("tracker.cut"), MenuItem("tracker.trash", ruleBefore: true),
     .submenu("Add-ons", ruleBefore: true, holds: ["tracker.addOn"]) { [self] in addOnMenu() }]
  }

  public func setView(_ v: ViewMode) {
    guard state.view != v else { return }
    state.view = v
    save()
  }

  public func sort(by column: String) {
    var s = state.sort
    if s.column == column { s.descending.toggle() } else { s = SortOrder(column) }
    state.sort = s
    folder.sort = s
    save()
  }

  // MARK: Views

  public var body: Group {
    if desktop {
      Desktop(window: self)
    } else {
      window
    }
  }

  @ViewBuilder var window: Group {
    VStack(width: .percent(1), height: .percent(1)) {
      MenuBar([MenuSpec("File", entries: [
                  MenuItem.submenu("New", holds: ["tracker.newFolder", "tracker.newQuery", "tracker.newFrom"]) { [self] in
                    newMenu(now: now)
                  },
                  MenuItem("tracker.open", ruleBefore: true), MenuItem("tracker.parent"), MenuItem("tracker.rename"),
                  MenuItem("tracker.trash"), MenuItem("window.close", ruleBefore: true),
                ]),
               MenuSpec("Edit", entries: [MenuItem("tracker.copy"), MenuItem("tracker.cut"),
                                          MenuItem("tracker.paste", dimmed: FileClipboard.shared.paths.isEmpty),
                                          MenuItem("tracker.select", ruleBefore: true), MenuItem("tracker.selectAll"),
                                          MenuItem.submenu("Add-ons", ruleBefore: true, holds: ["tracker.addOn"]) { [self] in
                                            addOnMenu()
                                          }]),
               MenuSpec("View", entries: [MenuItem("tracker.icons"), MenuItem("tracker.mini"), MenuItem("tracker.list"),
                                          MenuItem("tracker.cleanUp", dimmed: state.view == .list, ruleBefore: true)])])
      FolderContent(window: self)
      HStack(class: "status", width: .percent(1)) {
        Text(statusLeft, class: "status")
        Spacer()
        Text("Taisce · \(path.isEmpty ? "/" : path)", class: "status")
      }
    }
  }

  var statusLeft: String {
    if let m = message { return m }
    let n = folder.entries.count
    let entries = n == 1 ? "1 entry" : "\(n) entries"
    if !loaded { return entries + "…" }
    let s = folder.selection.count
    return s > 0 ? "\(s) of \(entries) selected" : entries
  }

  /// An entry's icon, by its kind (the storyboard's: places focus, queries
  /// realtime, the Trash ink.dim, documents ink with their type's emblem).
  public static func icon(_ e: Entry, in path: String, theme t: Theme) -> IconRef {
    let ink = t.color("ink"), dim = t.color("ink.dim"), focus = t.color("focus"),
      realtime = t.color("realtime"), live = t.color("live"), warning = t.color("warning")
    if e.isDirectory {
      if path.isEmpty && e.name == Volume.trash { return IconRef("trash", color: dim) }
      if path.isEmpty && e.name == "home" { return IconRef("home", color: focus, emblem: focus) }
      return IconRef("folder", color: focus)
    }
    let ty = e.type ?? ""
    if ty == FileTypes.query { return IconRef("query", color: realtime) }
    if ty == "application/pdf" { return IconRef("pdf", color: ink, emblem: realtime) }
    if ty.hasPrefix("image/") { return IconRef("image", color: ink, emblem: focus) }
    if ty.hasPrefix("audio/") { return IconRef("audio", color: ink, emblem: live) }
    if ty.hasPrefix("text/x-") || ty == "application/x-sh" || ty == "application/json" {
      return IconRef("source", color: ink, emblem: warning)
    }
    return IconRef("doc", color: ink)
  }

  /// A row (an icon) the pointer did something to.
  func pointed(_ e: Entry, _ s: Signal, input: FrameInput, ui: inout UI) {
    if s.secondaryPressed {
      if !folder.selection.contains(e.node) { folder.select(e.node) }
      ui.openContextMenu("entry", subject: Path.join(path, e.name))
      return
    }
    if s.pressed {
      message = nil
      if renaming != nil && renaming != e.node { finishRename(keep: true) }
      folder.select(e.node, input.shift ? .range : input.control ? .toggle : .only)
    }
    if s.doubleClicked { open(e) }
  }

  /// Keys the folder takes when no field has them: arrows, Enter, Delete,
  /// Escape, and typing to find a name.
  func keys(_ input: FrameInput, ui: inout UI) {
    guard renaming == nil else {
      for k in input.keys where k.key == .escape { finishRename(keep: false) }
      return
    }
    for k in input.keys where !k.control && !k.alt {
      switch k.key {
      case .down, .up, .right, .left:
        let by = k.key == .down || k.key == .right ? 1 : -1
        guard let next = folder.neighbour(by) else { continue }
        folder.select(next.node, k.shift ? .range : .only)
        reveal = folder.ordered().firstIndex { $0.node == next.node }
        message = nil
      case .enter: openSelected()
      case .delete: trashSelected()
      case .escape: folder.clearSelection()
      default: break
      }
    }
    // Typing finds the first name starting with what was typed lately.
    guard !input.text.isEmpty else { return }
    if input.time - typed.time > 1_000_000_000 { typed.text = "" }
    typed = (typed.text + input.text.lowercased(), input.time)
    let order = folder.ordered()
    if let i = order.firstIndex(where: { $0.name.lowercased().hasPrefix(typed.text) }) {
      folder.select(order[i].node)
      reveal = i
    }
  }
}

/// The folder's list or icons, its context menus, and its keys.
struct FolderContent: View {
  let window: FolderWindow

  @MainActor func build(_ c: inout BuildContext, id: String) {
    let w = window
    let input = c.ui.frameInput
    w.now = input.time
    // Select…'s field (M6l): Enter selects what matches, Escape doesn't.
    if var pattern = w.selecting {
      c.ui.open("select", class: "query", width: .percent(1), height: .children(), axis: .horizontal)
      c.ui.box("label", class: "query.label", text: "Select", flags: [.text])
      let key = UI.key("pattern", in: c.ui.openKey)
      if c.ui.focus != key { c.ui.focus(on: key) }
      let f = c.ui.textField("pattern", text: &pattern, class: "field", label: "Select names matching")
      c.ui.close()
      w.selecting = pattern
      if f.submitted {
        w.select(matching: pattern)
        w.selecting = nil
      } else if input.keys.contains(where: { $0.key == .escape }) {
        w.selecting = nil
      }
    }
    if c.ui.focus == 0 || w.renaming != nil { w.keys(input, ui: &c.ui) }
    let theme = c.ui.theme
    let order = w.folder.ordered()
    let events: TableEvents
    switch w.state.view {
    case .list:
      let columns = w.state.columns
      let cq = Theme.cqw
      // Name takes what the others leave.
      var widths = columns.map { col -> Float in
        col == Column.size ? cq(6) : col == Column.modified ? cq(8) : col == Column.type ? cq(12) : cq(10)
      }
      if let n = columns.firstIndex(of: Column.name) {
        widths[n] = max(cq(10), c.ui.width - widths.enumerated().filter { $0.offset != n }.reduce(0) { $0 + $1.element })
      }
      // The usual order (by name, up) goes unmarked, as board 01 shows it.
      let sortIndex = w.state.sort == SortOrder() ? nil : columns.firstIndex(of: w.state.sort.column)
      let reveal = w.reveal
      w.reveal = nil
      let editing = w.renaming.flatMap { node in order.firstIndex { $0.node == node } }
      var text = w.renameText
      events = c.ui.table(id, label: w.title, count: order.count, rowHeight: cq(1.9), columns: columns.map(Column.title),
                          widths: widths, numeric: columns.map(Column.numeric),
                          sort: sortIndex.map { ($0, w.state.sort.descending) }, editing: editing, editText: &text,
                          reveal: reveal) { r in
        let e = order[r]
        return TableRow(cells: columns.map { e.text($0) }, icon: FolderWindow.icon(e, in: w.path, theme: theme),
                        state: w.folder.selection.contains(e.node) ? "selected" : "")
      }
      w.renameText = text
      if editing != nil && events.edit.submitted { w.finishRename(keep: true) }
      if let h = events.header { w.sort(by: columns[h]) }
    case .mini:
      let places = IconGrid.mini(order, width: c.ui.width)
      events = c.ui.iconField(id, label: w.title, count: order.count, mini: true) { i in
        let e = order[i]
        return (FolderWindow.icon(e, in: w.path, theme: theme), e.name, places[i].x, places[i].y,
                w.folder.selection.contains(e.node))
      }
    case .icons:
      // The desktop's volumes first (M6l), each in the next cell.
      let vols = w.desktop ? w.volumes : []
      let places = w.desktop ? IconGrid.desktop(order, height: c.ui.height, reserved: vols.count)
        : IconGrid.places(order, width: c.ui.width)
      let volumePlaces = IconGrid.desktopCells(vols.count, height: c.ui.height)
      let raw = c.ui.iconField(id, label: w.title, count: vols.count + order.count) { i in
        if i < vols.count {
          return (IconRef("cube", color: theme.color("focus")), vols[i].name, volumePlaces[i].x, volumePlaces[i].y, false)
        }
        let e = order[i - vols.count]
        return (FolderWindow.icon(e, in: w.path, theme: theme), e.name, places[i - vols.count].x, places[i - vols.count].y,
                w.folder.selection.contains(e.node))
      }
      // A volume double-clicked opens; right-clicked, its menu.
      for (r, s) in raw.rows where r < vols.count {
        if s.doubleClicked { w.host?.open(folder: "") }
        if s.secondaryPressed { c.ui.openContextMenu("volume", subject: vols[r].name) }
      }
      var shifted = raw
      shifted.rows = raw.rows.filter { $0.row >= vols.count }.map { ($0.row - vols.count, $0.1) }
      shifted.dropped = raw.dropped.flatMap { $0.row >= vols.count ? ($0.row - vols.count, $0.dx, $0.dy) : nil }
      events = shifted
      if let d = events.dropped, w.state.view == .icons {
        let e = order[d.row]
        let x = max(0, places[d.row].x + d.dx), y = max(0, places[d.row].y + d.dy)
        try? w.volume.place(Path.join(w.path, e.name), x: x, y: y)
        if let n = try? w.volume.stat(Path.join(w.path, e.name)) { w.folder.update(n) }
      }
    }
    for (r, s) in events.rows where r < order.count { w.pointed(order[r], s, input: input, ui: &c.ui) }
    if events.background.pressed {
      if w.renaming != nil { w.finishRename(keep: true) }
      w.folder.clearSelection()
      w.message = nil
    }
    if events.background.secondaryPressed { c.ui.openContextMenu("ground", subject: w.path) }
    c.ui.contextMenu("entry", entries: w.entryMenu())
    c.ui.contextMenu("volume", entries: w.volumes.first.map { w.volumeMenu($0) } ?? [])
    c.ui.contextMenu("ground", entries: w.groundMenu(now: input.time))
  }
}

/// The desktop: the storyboard's grid (every 4cqw, cyan at 3.5%) in a
/// theme that has one, and the folder's icons over it.
struct Desktop: View {
  let window: FolderWindow
  @MainActor func build(_ c: inout BuildContext, id: String) {
    let (width, height) = (c.ui.width, c.ui.height)
    c.ui.open("desktop", class: "desktop", width: .percent(1), height: .percent(1), axis: .vertical, flags: [.background])
    c.ui.custom("grid", width: .pixels(0), height: .pixels(0), at: (0, 0)) { p, _ in
      // (Without one, the style is the desk's own, opaque and a pixel
      // apart: a line at every pixel, none of them seen.)
      guard p.theme.defines("desktop.grid") else { return }
      let grid = p.theme.style("desktop.grid")
      let stepX = max(1, grid.padding.left), stepY = max(1, grid.padding.top)
      var x: Float = 0
      while x < width {
        p.fill(x, 0, 1 / p.scale, height, grid.fill)
        x += stepX
      }
      var y: Float = 0
      while y < height {
        p.fill(0, y, width, 1 / p.scale, grid.fill)
        y += stepY
      }
    }
    FolderContent(window: window).build(&c, id: "icons")
    c.ui.close()
  }
}

/// Be's icon view's places: an entry's own (`Tracker:Place`), else the
/// next free cell of a grid, left to right and down.
public enum IconGrid {
  /// The desktop's: down the left from (1.5cqw, 2cqw), 6.5cqw apart (board
  /// 01's), then the next column.
  public static func desktop(_ entries: [Entry], height: Float, reserved: Int = 0) -> [(x: Float, y: Float)] {
    let left = Theme.cqw(1.5), top = Theme.cqw(2), step = Theme.cqw(6.5), column = Theme.cqw(8)
    let rows = max(1, Int((height - top) / step))
    func index(_ x: Float, _ y: Float) -> Int {
      Int(((x - left) / column).rounded()) * rows + min(rows - 1, max(0, Int(((y - top) / step).rounded())))
    }
    // The first `reserved` cells are the volumes' (M6l).
    var taken = Array(0..<reserved) + entries.compactMap { $0.place.map { index($0.x, $0.y) } }
    var next = 0
    return entries.map { e in
      if let p = e.place { return (p.x, p.y) }
      while taken.contains(next) { next += 1 }
      taken.append(next)
      return (left + Float(next / rows) * column, top + Float(next % rows) * step)
    }
  }

  /// Mini icons' places (M6l): across in rows, as Be's mini icon view;
  /// kept places are the big icons'.
  public static func mini(_ entries: [Entry], width: Float) -> [(x: Float, y: Float)] {
    let margin = Theme.cqw(1), gap = Theme.cqw(0.5)
    let cell = (w: IconField.mini.width + gap, h: IconField.mini.height + Theme.cqw(0.2))
    let columns = max(1, Int((width - margin) / cell.w))
    return entries.indices.map { i in (margin + Float(i % columns) * cell.w, margin + Float(i / columns) * cell.h) }
  }

  /// The desktop's first `n` cells (its volumes', M6l).
  public static func desktopCells(_ n: Int, height: Float) -> [(x: Float, y: Float)] {
    let left = Theme.cqw(1.5), top = Theme.cqw(2), step = Theme.cqw(6.5), column = Theme.cqw(8)
    let rows = max(1, Int((height - top) / step))
    return (0..<n).map { (left + Float($0 / rows) * column, top + Float($0 % rows) * step) }
  }

  public static func places(_ entries: [Entry], width: Float) -> [(x: Float, y: Float)] {
    let cell = (w: Theme.cqw(7.5), h: Theme.cqw(6.5)), margin = Theme.cqw(1)
    let columns = max(1, Int((width - margin) / cell.w))
    var taken: [Int] = []
    func index(_ x: Float, _ y: Float) -> Int {
      Int(((y - margin) / cell.h).rounded()) * columns + min(columns - 1, max(0, Int(((x - margin) / cell.w).rounded())))
    }
    for e in entries { if let p = e.place { taken.append(index(p.x, p.y)) } }
    var next = 0
    return entries.map { e in
      if let p = e.place { return (p.x, p.y) }
      while taken.contains(next) { next += 1 }
      taken.append(next)
      return (margin + Float(next % columns) * cell.w, margin + Float(next / columns) * cell.h)
    }
  }
}
