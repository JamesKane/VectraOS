// SPDX-License-Identifier: BSD-3-Clause

// A folder as Tracker holds it (M6j part 3b): its entries with their
// stat fields and the attributes its columns name, kept current by the
// directory's watch (an entry at a time), sorted by any column, folders
// first; a selection; and the window's state, kept in the folder's own
// attributes (spatial, decided 2026-10-12: Be kept `_trk/windframe` on
// the folder and `_trk/pinfo` on each entry; here `Tracker:Frame`,
// `Tracker:View`, `Tracker:Columns` and `Tracker:Sort` on the folder,
// `Tracker:Place` on each entry). The values are text, so Terminal can
// read and change them.

import Fs
import Node

/// One entry of a folder.
public struct Entry: Equatable, Sendable {
  public var name: String
  /// Its inode number (unique in the volume, never reused).
  public var node: UInt64
  public var isDirectory: Bool
  public var size: UInt64
  /// Nanoseconds since the Unix epoch.
  public var modified: Int64
  public var attributes: [String: AttributeValue]

  public init(name: String, node: UInt64, isDirectory: Bool, size: UInt64, modified: Int64,
              attributes: [String: AttributeValue] = [:])
  {
    self.name = name
    self.node = node
    self.isDirectory = isDirectory
    self.size = size
    self.modified = modified
    self.attributes = attributes
  }

  public init(_ e: FsIPC.Entry) {
    var attributes: [String: AttributeValue] = [:]
    for a in e.attributes { attributes[a.name] = AttributeValue(a) }
    self.init(name: e.name, node: e.node, isDirectory: e.kind == 2, size: e.size, modified: e.modified,
              attributes: attributes)
  }

  public init(_ s: NodeIPC.Stat) {
    var attributes: [String: AttributeValue] = [:]
    for a in s.attributes { attributes[a.name] = AttributeValue(a) }
    self.init(name: s.name, node: s.qid.path, isDirectory: s.qid.kind == .directory, size: s.size,
              modified: s.modified, attributes: attributes)
  }

  /// Its MIME type, if it has one (`sys:type`).
  public var type: String? {
    switch attributes[Column.type] {
    case .type(let t)?, .string(let t)?: return t
    default: return nil
    }
  }

  /// Where it sits in its folder's icon view, if it was put somewhere.
  public var place: (x: Float, y: Float)? {
    guard case .string(let s)? = attributes[FolderState.placeAttribute] else { return nil }
    let v = FolderState.numbers(s)
    return v.count == 2 ? (v[0], v[1]) : nil
  }

  /// Its value in `column`, for sorting; nil if it has none.
  public func value(_ column: String) -> AttributeValue? {
    switch column {
    case Column.name: return .string(name)
    case Column.size: return isDirectory ? nil : .uint(size)
    case Column.modified: return .time(modified)
    case Column.type: return isDirectory ? .type("directory") : attributes[column]
    default: return attributes[column]
    }
  }

  /// Its text in `column` (board 01's: a folder's size "—", its type
  /// "directory").
  public func text(_ column: String) -> String {
    switch column {
    case Column.name: return name
    case Column.size: return isDirectory ? "—" : Format.size(size)
    case Column.modified: return Format.date(modified)
    case Column.type: return isDirectory ? "directory" : type ?? "—"
    default: return attributes[column]?.text ?? "—"
    }
  }
}

/// A column: a stat field or an attribute, by name.
public enum Column {
  public static let name = "name", size = "size", modified = "mtime", type = "sys:type"

  /// Its header (board 01's).
  public static func title(_ column: String) -> String {
    switch column {
    case name: return "Name"
    case size: return "Size"
    case modified: return "Modified"
    default: return column
    }
  }

  /// Whether its values are numbers (right-aligned).
  public static func numeric(_ column: String) -> Bool { column == size }
}

/// A sort: a column, up or down.
public struct SortOrder: Equatable, Sendable {
  public var column: String
  public var descending: Bool
  public init(_ column: String = Column.name, descending: Bool = false) {
    self.column = column
    self.descending = descending
  }

  /// As `Tracker:Sort` keeps it: the column, after "-" if descending.
  public init(text: String) {
    descending = text.hasPrefix("-")
    column = descending ? String(text.dropFirst()) : text
    if column.isEmpty { column = Column.name }
  }
  public var text: String { (descending ? "-" : "") + column }
}

/// How a folder's window shows it.
public enum ViewMode: String, Sendable {
  /// Be's three: a list, icons, and mini icons (M6l: small, names beside).
  case list, icons, mini
}

/// A folder's window, as its attributes keep it.
public struct FolderState: Equatable, Sendable {
  public static let frameAttribute = "Tracker:Frame", viewAttribute = "Tracker:View",
    columnsAttribute = "Tracker:Columns", sortAttribute = "Tracker:Sort", placeAttribute = "Tracker:Place"
  public static let attributes = [frameAttribute, viewAttribute, columnsAttribute, sortAttribute]
  public static let defaultColumns = [Column.name, Column.size, Column.modified, Column.type]

  /// Its window's content: x, y, width, height, in logical pixels.
  public var frame: (x: Int32, y: Int32, width: Int32, height: Int32)?
  public var view: ViewMode = .list
  public var columns: [String] = FolderState.defaultColumns
  public var sort = SortOrder()

  public init() {}

  /// From the folder's attributes; what's missing or unreadable is the
  /// default.
  public init(_ attributes: [String: AttributeValue]) {
    if case .string(let s)? = attributes[Self.frameAttribute] {
      let v = Self.numbers(s)
      if v.count == 4, v[2] >= 16, v[3] >= 16 { frame = (Int32(v[0]), Int32(v[1]), Int32(v[2]), Int32(v[3])) }
    }
    if case .string(let s)? = attributes[Self.viewAttribute], let v = ViewMode(rawValue: s) { view = v }
    if case .string(let s)? = attributes[Self.columnsAttribute] {
      let c = s.split(separator: " ").map(String.init)
      if !c.isEmpty { columns = c }
    }
    if case .string(let s)? = attributes[Self.sortAttribute] { sort = SortOrder(text: s) }
  }

  /// Its attributes, as text.
  public var encoded: [(name: String, value: AttributeValue)] {
    var out: [(String, AttributeValue)] = []
    if let f = frame { out.append((Self.frameAttribute, .string("\(f.x) \(f.y) \(f.width) \(f.height)"))) }
    out.append((Self.viewAttribute, .string(view.rawValue)))
    out.append((Self.columnsAttribute, .string(columns.joined(separator: " "))))
    out.append((Self.sortAttribute, .string(sort.text)))
    return out
  }

  public static func == (a: FolderState, b: FolderState) -> Bool {
    a.frame.map { [$0.x, $0.y, $0.width, $0.height] } == b.frame.map { [$0.x, $0.y, $0.width, $0.height] }
      && a.view == b.view && a.columns == b.columns && a.sort == b.sort
  }

  /// Numbers in `s`, apart by spaces.
  static func numbers(_ s: String) -> [Float] {
    s.split(separator: " ").compactMap { Float(String($0)) }
  }

  /// A place as `Tracker:Place` keeps it.
  public static func place(_ x: Float, _ y: Float) -> AttributeValue { .string("\(Int(x)) \(Int(y))") }
}

/// A folder: its entries, their order and the selection.
public struct Folder: Sendable {
  /// The folder's path from the volume's root ("" is the root).
  public var path: String
  public private(set) var entries: [Entry] = []
  public var sort: SortOrder {
    didSet { if sort != oldValue { sorted = false } }
  }
  /// Selected entries, by node.
  public private(set) var selection: Set<UInt64> = []
  /// Where a range selection starts.
  public private(set) var anchor: UInt64?
  /// The listing has come whole.
  public var complete = false
  var sorted = true

  public init(path: String, sort: SortOrder = SortOrder()) {
    self.path = path
    self.sort = sort
  }

  /// Entries in order: folders first, then by the sort's column (entries
  /// without a value last), then by name.
  public mutating func ordered() -> [Entry] {
    if !sorted {
      let s = sort
      if let keys = SortKey.keys(entries, s) {
        // Keys made once (M6m: a 100k folder sorted warm in its share of
        // 100 ms): the comparison allocates nothing; ties of them (names
        // differing only in case) go to the full comparison.
        let all = entries
        let order = keys.indices.sorted { i, j in
          SortKey.before(keys[i], keys[j], descending: s.descending) ?? Folder.before(all[i], all[j], s)
        }
        entries = order.map { all[$0] }
      } else {
        entries.sort { a, b in Folder.before(a, b, s) }
      }
      sorted = true
    }
    return entries
  }

  /// The order in full: folders first, then by the sort's column (entries
  /// without a value last), then by name.
  static func before(_ a: Entry, _ b: Entry, _ s: SortOrder) -> Bool {
    if a.isDirectory != b.isDirectory { return a.isDirectory }
    let va = a.value(s.column), vb = b.value(s.column)
    switch (va, vb) {
    case (let x?, let y?):
      if AttributeValue.ascending(x, y) { return !s.descending }
      if AttributeValue.ascending(y, x) { return s.descending }
    case (_?, nil): return true
    case (nil, _?): return false
    case (nil, nil): break
    }
    return Format.caseless(a.name, b.name)
  }

  /// The system's folders at the volume's top (the router's rules, the
  /// settings): not shown there (M6m, decided 2026-10-13); a path still
  /// reaches them.
  public static let systemFolders = ["Router", "Settings"]

  /// Whether `e` is shown in this folder.
  func shows(_ e: Entry) -> Bool { !(path.isEmpty && e.isDirectory && Folder.systemFolders.contains(e.name)) }

  /// A batch of the listing.
  public mutating func add(_ batch: [Entry]) {
    entries += batch.filter { shows($0) }
    sorted = false
  }

  /// An entry, new or changed: the same node renamed replaces its old
  /// name (a rename in the folder is one change, under the new name).
  /// `byNode`: matched by its node alone (a query's matches, from many
  /// folders, may share a name).
  public mutating func update(_ e: Entry, byNode: Bool = false) {
    guard shows(e) else { return }
    if let i = entries.firstIndex(where: { $0.node == e.node })
      ?? (byNode ? nil : entries.firstIndex(where: { $0.name == e.name }))
    {
      if entries[i] == e { return }
      if entries[i].node != e.node { selection.remove(entries[i].node) }
      entries[i] = e
    } else {
      entries.append(e)
    }
    sorted = false
  }

  /// Everything again (the watch missed changes).
  public mutating func replace(_ all: [Entry]) {
    let kept = Set(all.map { $0.node })
    selection.formIntersection(kept)
    if let a = anchor, !kept.contains(a) { anchor = nil }
    entries = all.filter { shows($0) }
    sorted = false
  }

  /// An entry gone.
  public mutating func remove(named name: String) {
    guard let i = entries.firstIndex(where: { $0.name == name }) else { return }
    selection.remove(entries[i].node)
    if anchor == entries[i].node { anchor = nil }
    entries.remove(at: i)
  }

  /// An entry gone, by its node.
  public mutating func remove(node: UInt64) {
    guard let i = entries.firstIndex(where: { $0.node == node }) else { return }
    selection.remove(node)
    if anchor == node { anchor = nil }
    entries.remove(at: i)
  }

  public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }
  public func entry(node: UInt64) -> Entry? { entries.first { $0.node == node } }

  /// How a click selects.
  public enum Pick: Sendable {
    /// Only this.
    case only
    /// This in or out of the selection (Control).
    case toggle
    /// From the anchor to this, in order (Shift).
    case range
  }

  public mutating func select(_ node: UInt64, _ pick: Pick = .only) {
    switch pick {
    case .only:
      selection = [node]
      anchor = node
    case .toggle:
      if selection.contains(node) { selection.remove(node) } else { selection.insert(node) }
      anchor = node
    case .range:
      let order = ordered().map { $0.node }
      guard let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: node) else {
        select(node)
        return
      }
      selection = Set(order[min(i, j)...max(i, j)])
    }
  }

  public mutating func selectAll() { selection = Set(entries.map { $0.node }) }
  public mutating func clearSelection() {
    selection = []
    anchor = nil
  }

  /// The selected entries, in order.
  public mutating func selected() -> [Entry] { ordered().filter { selection.contains($0.node) } }

  /// The entry `by` places after the anchor, in order (the keyboard's
  /// Up and Down: -1, 1), or the first.
  public mutating func neighbour(_ by: Int) -> Entry? {
    let order = ordered()
    guard !order.isEmpty else { return nil }
    guard let a = anchor, let i = order.firstIndex(where: { $0.node == a }) else {
      return by < 0 ? order.last : order.first
    }
    return order[min(max(i + by, 0), order.count - 1)]
  }
}

/// An entry's place in a sort, made once: its column's value as a number
/// or as caseless bytes (Format.caseless's order: lowercased, then as
/// written), and its name's for ties.
struct SortKey {
  var directory: Bool
  /// 0 a number, 1 text, 2 no value.
  var rank: UInt8
  var number: Double
  var text: [UInt8]
  /// The value as written (another column's text: case breaks its ties).
  var written: [UInt8]
  var name: [UInt8]

  /// The keys, or nil if the column mixes kinds of value (or has some
  /// keys don't order): then the full comparison sorts.
  static func keys(_ entries: [Entry], _ sort: SortOrder) -> [SortKey]? {
    var keys: [SortKey] = []
    keys.reserveCapacity(entries.count)
    var kind: UInt8? = nil
    for e in entries {
      let name = lowered(e.name)
      var k = SortKey(directory: e.isDirectory, rank: 2, number: 0, text: [], written: [], name: name)
      switch e.value(sort.column) {
      case nil: break
      case .string(let t)?, .type(let t)?:
        k.rank = 1
        if sort.column == Column.name {
          k.text = name
        } else {
          k.text = lowered(t)
          k.written = Array(t.utf8)
        }
      case let v?:
        guard let n = v.number else { return nil }
        k.rank = 0
        k.number = n
      }
      if k.rank < 2 {
        if let have = kind, have != k.rank { return nil }
        kind = k.rank
      }
      keys.append(k)
    }
    return keys
  }

  /// Lowercased UTF-8 (ASCII by hand; the rest by String's).
  static func lowered(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count)
    for b in s.utf8 {
      if b >= 0x80 { return Array(s.lowercased().utf8) }
      out.append(b >= 0x41 && b <= 0x5A ? b | 0x20 : b)
    }
    return out
  }

  /// -1, 0 or 1, as `a` sorts before, with or after `b`.
  static func less(_ a: [UInt8], _ b: [UInt8]) -> Int {
    let n = min(a.count, b.count)
    var i = 0
    while i < n {
      if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
      i += 1
    }
    return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
  }

  /// Folder.before's order by the keys: folders first, then by value
  /// (descending if asked; none last), then by name caseless; nil if
  /// they're the same that far.
  static func before(_ a: SortKey, _ b: SortKey, descending: Bool) -> Bool? {
    if a.directory != b.directory { return a.directory }
    if a.rank != b.rank { return a.rank < b.rank }
    var c = 0
    if a.rank == 0 {
      c = a.number < b.number ? -1 : (a.number > b.number ? 1 : 0)
    } else if a.rank == 1 {
      c = less(a.text, b.text)
      if c == 0 { c = less(a.written, b.written) }
    }
    if c != 0 { return descending ? c > 0 : c < 0 }
    c = less(a.name, b.name)
    return c == 0 ? nil : c < 0
  }
}
