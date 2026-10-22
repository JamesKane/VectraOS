// SPDX-License-Identifier: BSD-3-Clause

// Tracker's way to the file system (M6j part 3b): a volume's root
// directory (the fs service's FsIPC.Directory), and paths from it. A
// folder is listed in batches with the attributes its columns name (one
// call a batch, no stat per entry: async listings of millions of entries
// come a batch at a time), watched for its entries' changes (Node's
// watch) and an entry stat'ed again when it changes. A folder's window
// state and its entries' places are attributes. Rename, a new folder,
// and the Trash: a folder `Trash` at the volume's root, an entry moved
// there keeping where it came from (`Tracker:Origin`) to go back.
// Files without a type get one (Types.swift).

import Fs
import IPC
import Node
import Sys

public enum TrackerError: Error, Equatable, Sendable {
  case notFound
  case exists
  case notEmpty
  case badName
  /// A query that doesn't parse.
  case badQuery
  /// The service failed, or refused for another reason.
  case failed
}

extension TrackerError {
  init(_ e: IPCError<NodeIPC.NodeError>) {
    guard case .remote(let r) = e else {
      self = .failed
      return
    }
    switch r {
    case .notFound: self = .notFound
    case .exists: self = .exists
    case .notEmpty: self = .notEmpty
    case .badName: self = .badName
    default: self = .failed
    }
  }

  init(_ e: IPCError<FsIPC.FsError>) {
    guard case .remote(let r) = e else {
      self = .failed
      return
    }
    switch r {
    case .notFound: self = .notFound
    case .exists: self = .exists
    case .notEmpty: self = .notEmpty
    case .badName: self = .badName
    default: self = .failed
    }
  }
}

/// Paths from the volume's root: "" is the root, names apart by "/".
public enum Path {
  public static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }

  /// The folder a path is in, and its last name.
  public static func split(_ path: String) -> (folder: String, name: String) {
    guard let slash = path.lastIndex(of: "/") else { return ("", path) }
    return (String(path[..<slash]), String(path[path.index(after: slash)...]))
  }

  /// Its last name ("" for the root, which Tracker calls by its volume's).
  public static func name(_ path: String) -> String { split(path).name }
}

/// A volume, through its root directory. Not for more than one thread at
/// a time: give each thread its own (`Volume(root:)` over its own channel).
public final class Volume {
  var root: FsIPC.DirectoryClient
  public static let trash = "Trash"
  public static let originAttribute = "Tracker:Origin"
  /// What a folder's listing asks of each entry besides its columns.
  public static let listed = [Column.type, FolderState.placeAttribute]

  public init(root: consuming FsIPC.DirectoryClient) { self.root = root }

  /// A Node client of `path`.
  func node(_ path: String) throws(TrackerError) -> NodeIPC.NodeClient {
    do throws(IPCError<NodeIPC.NodeError>) {
      return NodeIPC.NodeClient(channel: try root.walk(to: path))
    } catch {
      throw TrackerError(error)
    }
  }

  func directory(_ path: String) throws(TrackerError) -> FsIPC.DirectoryClient {
    FsIPC.DirectoryClient(channel: try node(path).takeChannel())
  }

  // MARK: Listing and watching

  /// A folder's listing, a batch at a time.
  public struct Listing: ~Copyable {
    var directory: FsIPC.DirectoryClient
    let attributes: [String]
    var cursor: UInt64 = 0
    public private(set) var done = false

    /// The next batch (empty once `done`). The first is the whole listing
    /// if the service gives it at once (M6m: wholeListing's VMO, one copy);
    /// batches follow if it can't.
    public mutating func next(max: Int = 256) throws(TrackerError) -> [Entry] {
      guard !done else { return [] }
      if cursor == 0, let all = whole() {
        done = true
        return all
      }
      do throws(IPCError<FsIPC.FsError>) {
        let batch = try directory.list(cursor: cursor, max: UInt32(max), attributes: attributes)
        cursor = batch.next
        done = batch.done
        return batch.entries.map { Entry($0) }
      } catch {
        throw TrackerError(error)
      }
    }
  }

  /// `path`'s entries with `columns`' attributes (and the type and place).
  public func list(_ path: String, columns: [String]) throws(TrackerError) -> Listing {
    var names = Self.listed
    for c in columns where ![Column.name, Column.size, Column.modified].contains(c) && !names.contains(c) {
      names.append(c)
    }
    return Listing(directory: try directory(path), attributes: names)
  }

  /// Every entry of `path`.
  public func entries(_ path: String, columns: [String] = FolderState.defaultColumns) throws(TrackerError) -> [Entry] {
    var listing = try list(path, columns: columns)
    var out: [Entry] = []
    while !listing.done { out += try listing.next() }
    return out
  }

  /// One entry, as a listing gives it (all its attributes).
  public func stat(_ path: String) throws(TrackerError) -> Entry {
    var n = try node(path)
    do throws(IPCError<NodeIPC.NodeError>) {
      var e = Entry(try n.stat(fields: NodeIPC.Fields.all))
      if e.name.isEmpty { e.name = Path.name(path) }
      return e
    } catch {
      throw TrackerError(error)
    }
  }

  /// A folder's entries' changes, from now on.
  public struct Watch: ~Copyable {
    var client: NodeIPC.NodeClient

    /// Its channel, to wait on (readable: changes to take).
    public func withChannel<R>(_ body: (borrowing Handle) -> R) -> R { body(client.connection.channel) }

    /// The changes that have come (none if none), waiting until
    /// `deadline` for the first.
    public mutating func changes(deadline: Int64 = 0) -> [NodeIPC.Change] {
      var out: [NodeIPC.Change] = []
      var until = deadline
      while let e = try? client.nextEvent(deadline: until) {
        if case .changed(let c) = e { out.append(c) }
        until = 0
      }
      return out
    }
  }

  /// A watch's changes to `folder`: each entry named stat'ed again (gone
  /// if it isn't there), changes to the folder itself passed over, and
  /// everything listed again if the watch missed some.
  public func apply(_ changes: [NodeIPC.Change], to folder: inout Folder, columns: [String]) throws(TrackerError) {
    if changes.contains(where: { $0.kind == .overflow }) {
      folder.replace(try entries(folder.path, columns: columns))
      return
    }
    for c in changes where !c.name.isEmpty {
      if c.kind == .removed {
        folder.remove(named: c.name)
      } else if let e = try? stat(Path.join(folder.path, c.name)) {
        folder.update(e)
      } else {
        folder.remove(named: c.name)
      }
    }
  }

  public func watch(_ path: String) throws(TrackerError) -> Watch {
    var n = try node(path)
    do throws(IPCError<NodeIPC.NodeError>) {
      _ = try n.watch(since: 0)
    } catch {
      throw TrackerError(error)
    }
    return Watch(client: n)
  }

  // MARK: Attributes

  public func attribute(_ path: String, _ name: String) throws(TrackerError) -> AttributeValue? {
    try stat(path).attributes[name]
  }

  public func setAttribute(_ path: String, _ name: String, _ value: AttributeValue) throws(TrackerError) {
    var d = try directory(path)
    let (kind, bytes) = value.encoded
    do throws(IPCError<FsIPC.FsError>) {
      try d.setAttribute(FsIPC.Attribute(name: name, kind: kind, value: bytes))
    } catch {
      throw TrackerError(error)
    }
  }

  public func removeAttribute(_ path: String, _ name: String) throws(TrackerError) {
    var d = try directory(path)
    do throws(IPCError<FsIPC.FsError>) {
      try d.removeAttribute(name)
    } catch {
      if case .remote(.notFound) = error { return }
      throw TrackerError(error)
    }
  }

  /// A folder's window state, from its attributes.
  public func state(_ path: String) throws(TrackerError) -> FolderState {
    FolderState(try stat(path).attributes)
  }

  /// Keeps a folder's window state in its attributes (only what changed).
  public func save(_ state: FolderState, _ path: String) throws(TrackerError) {
    let now = try stat(path).attributes
    for (name, value) in state.encoded where now[name] != value { try setAttribute(path, name, value) }
  }

  /// Where an entry sits in its folder's icon view.
  public func place(_ path: String, x: Float, y: Float) throws(TrackerError) {
    try setAttribute(path, FolderState.placeAttribute, FolderState.place(x, y))
  }

  // MARK: Changes

  func exists(_ path: String) -> Bool { (try? stat(path)) != nil }

  /// `name` in `folder`, or with " 2", " 3"... before its extension if
  /// it's taken.
  public func free(_ name: String, in folder: String) -> String {
    guard exists(Path.join(folder, name)) else { return name }
    var stem = name, ext = ""
    if let dot = name.lastIndex(of: "."), dot != name.startIndex {
      stem = String(name[..<dot])
      ext = String(name[dot...])
    }
    var n = 2
    while exists(Path.join(folder, "\(stem) \(n)\(ext)")) { n += 1 }
    return "\(stem) \(n)\(ext)"
  }

  /// Renames an entry in its folder; its new path.
  @discardableResult
  public func rename(_ path: String, to name: String) throws(TrackerError) -> String {
    guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw .badName }
    let target = Path.join(Path.split(path).folder, name)
    guard target != path else { return path }
    guard !exists(target) else { throw .exists }
    try move(path, to: target)
    return target
  }

  /// Moves an entry to `target` (a path), anywhere on the volume.
  public func move(_ path: String, to target: String) throws(TrackerError) {
    do throws(IPCError<FsIPC.FsError>) {
      try root.rename(path, to: target)
    } catch {
      throw TrackerError(error)
    }
  }

  /// A new folder in `folder` ("New folder", or " 2"...); its name.
  public func makeFolder(in folder: String, named base: String = "New folder") throws(TrackerError) -> String {
    let name = free(base, in: folder)
    var d = try directory(folder)
    do throws(IPCError<NodeIPC.NodeError>) {
      _ = try d.makeDirectory(name)
    } catch {
      throw TrackerError(error)
    }
    return name
  }

  /// A new file `name` in `folder` holding `contents`; its path.
  @discardableResult
  public func makeFile(in folder: String, named name: String, contents: [UInt8] = []) throws(TrackerError) -> String {
    var d = try directory(folder)
    do throws(IPCError<NodeIPC.NodeError>) {
      var f = try d.makeFile(name)
      if !contents.isEmpty { try f.write(contents) }
    } catch {
      throw TrackerError(error)
    }
    return Path.join(folder, name)
  }

  /// Copies an entry (a folder with all it holds) into `folder` under a
  /// free name there (`name`, or its own: " 2", " 3"... if taken), its
  /// attributes with it but its place and Trash origin (M6l: New from a
  /// template, Paste); its name there. A folder can't go into itself.
  @discardableResult
  public func copy(_ path: String, into folder: String, named name: String? = nil) throws(TrackerError) -> String {
    let e = try stat(path)
    if e.isDirectory && (folder == path || folder.hasPrefix(path + "/")) { throw .badName }
    let given = free(name ?? e.name, in: folder)
    let target = Path.join(folder, given)
    if e.isDirectory {
      _ = try makeFolder(in: folder, named: given)
      for child in try entries(path) { try copy(Path.join(path, child.name), into: target) }
    } else {
      var n = try node(path)
      let data: [UInt8]
      do throws(NodeIPC.NodeClient.Failure) {
        data = try n.readAll()
      } catch {
        throw .failed
      }
      try makeFile(in: folder, named: given, contents: data)
    }
    for (k, v) in e.attributes where k != FolderState.placeAttribute && k != Self.originAttribute {
      try setAttribute(target, k, v)
    }
    return given
  }

  /// Moves entries to the Trash (made if it isn't there), each keeping
  /// where it came from; their paths there.
  public func trash(_ paths: [String]) throws(TrackerError) -> [String] {
    if !exists(Self.trash) { _ = try makeFolder(in: "", named: Self.trash) }
    var out: [String] = []
    for p in paths where p != Self.trash && Path.split(p).folder != Self.trash {
      let target = Path.join(Self.trash, free(Path.name(p), in: Self.trash))
      try move(p, to: target)
      try setAttribute(target, Self.originAttribute, .string(p))
      out.append(target)
    }
    return out
  }

  /// An entry of the Trash back where it came from (a free name there if
  /// it's taken); its path.
  public func restore(_ path: String) throws(TrackerError) -> String {
    guard case .string(let origin)? = try attribute(path, Self.originAttribute) else { throw .notFound }
    let (folder, name) = Path.split(origin)
    guard folder.isEmpty || exists(folder) else { throw .notFound }
    let target = Path.join(folder, free(name, in: folder))
    try move(path, to: target)
    try removeAttribute(target, Self.originAttribute)
    return target
  }

  /// Gives a file without a type its type (Types.swift); the type it has
  /// now, nil for a folder or an empty file.
  @discardableResult
  public func type(_ path: String) throws(TrackerError) -> String? {
    let e = try stat(path)
    if e.isDirectory { return nil }
    if let t = e.type { return t }
    var n = try node(path)
    let head: [UInt8]
    do throws(IPCError<NodeIPC.NodeError>) {
      head = try n.read(offset: 0, max: UInt32(FileTypes.headLength))
    } catch {
      throw TrackerError(error)
    }
    guard let t = FileTypes.sniff(head, name: e.name) else { return nil }
    try setAttribute(path, Column.type, .type(t))
    return t
  }

  /// Opens a file channel for the file chooser (D111): read-only when
  /// `!writable` (`open`, checking `types` if given), or created/truncated
  /// and writable when `writable` (`save`).
  public func choose(_ path: String, writable: Bool, types: [String] = []) throws(TrackerError) -> Handle {
    let name = Path.name(path)
    guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw .badName }
    if !writable {
      let e = try stat(path)
      guard !e.isDirectory else { throw .badName }
      if !types.isEmpty {
        let t = (try? type(path)) ?? e.type ?? "application/octet-stream"
        guard FileTypes.matches(t, allowed: types) else { throw .badName }
      }
      var f: FsIPC.FileClient
      do throws(IPCError<NodeIPC.NodeError>) {
        f = try root.file(path)
      } catch {
        throw TrackerError(error)
      }
      do throws(IPCError<FsIPC.FsError>) {
        return try f.capability(writable: false)
      } catch {
        throw TrackerError(error)
      }
    }
    if let e = try? stat(path) {
      guard !e.isDirectory else { throw .badName }
    } else {
      _ = try makeFile(in: Path.split(path).folder, named: name)
    }
    var f: FsIPC.FileClient
    do throws(IPCError<NodeIPC.NodeError>) {
      f = try root.file(path)
    } catch {
      throw TrackerError(error)
    }
    // As it is: the app resizes it through the channel if it replaces it,
    // so a save that never reaches the app loses nothing.
    do throws(IPCError<FsIPC.FsError>) {
      return try f.capability(writable: true)
    } catch {
      throw TrackerError(error)
    }
  }
}

extension Volume.Listing {
  /// What `next` reads first: the whole listing from wholeListing's VMO, or
  /// nil (an older service, or no memory for it).
  mutating func whole() -> [Entry]? {
    guard let vmo = try? directory.wholeListing(attributes: attributes), let size = try? VMO.size(vmo),
      size > 0, let m = try? VMO.map(vmo, length: (size + 4095) & ~4095, writable: false),
      let r = ListingVMO.Reader(m.read(at: 0, count: size))
    else { return nil }
    let names = r.names
    var out: [Entry] = []
    out.reserveCapacity(r.count)
    for i in 0..<r.count {
      let e = r.entry(i)
      var attributes: [String: AttributeValue] = [:]
      for a in e.attributes {
        let (n, kind, value) = r.attribute(a)
        if let v = AttributeValue(kind: kind, value: Array(r.bytes[value])) { attributes[names[n]] = v }
      }
      out.append(Entry(name: String(decoding: r.bytes[e.name], as: UTF8.self), node: e.node, isDirectory: e.kind == 2,
                       size: e.size, modified: e.modified, attributes: attributes))
    }
    return out
  }
}
