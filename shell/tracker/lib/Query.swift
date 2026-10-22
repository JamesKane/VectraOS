// SPDX-License-Identifier: BSD-3-Clause

// Queries as folders (M6j part 3d, board 02): a query is a file whose type
// is `FileTypes.query` and whose `Query:Text` is Taisce's query language
// (filesystem.md §6). Opened, it's a live query over the volume: its
// matches, then `current`, then each change as the volume commits it,
// each with its journal sequence. `QueryResults` keeps the matches as
// entries (stat'ed by their paths) and marks those that arrived after
// `current` as new. A query's window state is the folder's kind
// (FolderState's attributes, on the query file); its columns default to
// the name and the attributes its text names.

import Fs
import IPC
import Node

extension Volume {
  public static let queryTextAttribute = "Query:Text"

  /// A new query file in `folder` (`name`, or " 2"...), its columns the
  /// name and what the text names; its path.
  public func makeQuery(in folder: String, named base: String = "New query", text: String) throws(TrackerError) -> String {
    let name = free(base, in: folder)
    var d = try directory(folder)
    do throws(IPCError<NodeIPC.NodeError>) {
      _ = try d.makeFile(name)
    } catch {
      throw TrackerError(error)
    }
    let path = Path.join(folder, name)
    try setAttribute(path, Column.type, .type(FileTypes.query))
    try setAttribute(path, Self.queryTextAttribute, .string(text))
    var state = FolderState()
    state.columns = QueryResults.columns(for: text)
    try save(state, path)
    return path
  }

  /// A query file's text.
  public func queryText(_ path: String) throws(TrackerError) -> String {
    guard case .string(let t)? = try attribute(path, Self.queryTextAttribute) else { return "" }
    return t
  }

  public func setQueryText(_ path: String, _ text: String) throws(TrackerError) {
    try setAttribute(path, Self.queryTextAttribute, .string(text))
  }

  /// A live query's changes, from its matches now on.
  public struct LiveQuery: ~Copyable {
    var client: FsIPC.LiveQueryClient

    /// Its channel, to wait on (readable: changes to take).
    public func withChannel<R>(_ body: (borrowing Handle) -> R) -> R { body(client.connection.channel) }

    /// The changes that have come (none if none), waiting until
    /// `deadline` for the first.
    public mutating func changes(deadline: Int64 = 0) -> [FsIPC.QueryChange] {
      var out: [FsIPC.QueryChange] = []
      var until = deadline
      while let e = try? client.nextEvent(deadline: until) {
        if case .changed(let c) = e { out.append(c) }
        until = 0
      }
      return out
    }
  }

  /// Runs `text` live over the volume (a scan where no index serves it).
  public func live(_ text: String) throws(TrackerError) -> LiveQuery {
    do throws(IPCError<FsIPC.FsError>) {
      return LiveQuery(client: FsIPC.LiveQueryClient(channel: try root.live(text, scan: true)))
    } catch {
      if case .remote(.badQuery) = error { throw .badQuery }
      throw TrackerError(error)
    }
  }
}

/// A live query's matches, as rows.
public struct QueryResults: Sendable {
  public var folder: Folder
  /// Each match's path from the root, by node.
  public private(set) var paths: [UInt64: String] = [:]
  /// Matches that came after `current`: shown as new.
  public private(set) var arrived: Set<UInt64> = []
  /// The first matches have all come.
  public private(set) var current = false
  /// The last match added live: its name and journal sequence.
  public private(set) var lastAdded: (name: String, seq: UInt64)?

  public init(path: String, sort: SortOrder) { folder = Folder(path: path, sort: sort) }

  /// The columns for a query: the name, then the attributes its text
  /// names, in order (board 02's: Name, Audio:Artist, Audio:Year...).
  public static func columns(for text: String) -> [String] {
    var out = [Column.name]
    // Up to "order by", whose attribute only orders.
    var body = Substring(text)
    var i = text.startIndex
    while i < text.endIndex {
      if text[i...].hasPrefix(" order by ") {
        body = text[..<i]
        break
      }
      i = text.index(after: i)
    }
    var word = ""
    var quoted = false
    for ch in body + " " {
      if ch == "\"" { quoted.toggle() }
      if quoted { continue }
      if ch.isLetter || ch.isNumber || ch == ":" || ch == "-" || ch == "_" {
        word.append(ch)
        continue
      }
      if word.contains(":") && !out.contains(word) && !(word.first?.isNumber ?? true) { out.append(word) }
      word = ""
    }
    return out
  }

  /// Applies a live query's changes, each match stat'ed by its path.
  public mutating func apply(_ changes: [FsIPC.QueryChange], volume: Volume) {
    for c in changes {
      switch c.kind {
      case .current:
        current = true
      case .reset:
        folder.replace([])
        paths = [:]
        arrived = []
        current = false
      case .removed:
        if paths[c.node] != nil { folder.remove(node: c.node) }
        paths[c.node] = nil
        arrived.remove(c.node)
      case .added, .changed:
        let path = c.path.hasPrefix("/") ? String(c.path.dropFirst()) : c.path
        guard let e = try? volume.stat(path) else { continue }
        paths[c.node] = path
        folder.update(e, byNode: true)
        if c.kind == .added && current {
          arrived.insert(c.node)
          lastAdded = (e.name, c.seq)
        }
      }
    }
  }
}
