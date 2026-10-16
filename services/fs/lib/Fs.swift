// SPDX-License-Identifier: BSD-3-Clause

// The fs service's protocols (filesystem.md §7): Taisce's directories and
// files, which compose Node (architecture §6), so `ls` and `cat` work on
// them through any Node client, and add what a file system has beyond
// Node: typed attributes, batched listings with attributes, renames,
// queries and live queries, indices, and durability.
//
// A live query's changes come on a channel of their own (LiveQuery), as
// fuchsia.io's directory watchers do, so a Node client on a directory
// channel never sees an event it doesn't know.

import IPC
import Node

@IPCLibrary(id: "todhchai.fs", version: 3)
public enum FsIPC {
  public enum FsError: Int32, IPCErrorCode, Sendable {
    case notFound = 1
    case exists
    case notDirectory
    case isDirectory
    case notEmpty
    /// A name that is empty, ".", "..", longer than 255 bytes, or holds "/" or NUL.
    case badName
    /// A directory moved into itself, a value that doesn't fit its kind.
    case invalid
    case noSpace
    /// The volume stopped writing after a failed commit.
    case readOnly
    case io
    /// A query that doesn't parse.
    case badQuery
    /// A query no index can serve: declare one, or ask for a scan.
    case needsIndex
    case tooLarge
    /// No whole listing is kept for it (wholeListing): list it in batches,
    /// which keep one.
    case cold
  }

  /// A typed attribute: `kind` is Taisce's AttributeKind (string 1, int64,
  /// uint64, double, time, bool, bytes, ref, type), `value` its encoding
  /// (integers little-endian, bool one byte).
  public struct Attribute: Equatable, Sendable {
    public var name: String
    public var kind: UInt8
    public var value: [UInt8]

    public init(name: String, kind: UInt8, value: [UInt8]) {
      self.name = name
      self.kind = kind
      self.value = value
    }
  }

  /// A directory entry with its stat fields and the attributes asked for.
  public struct Entry: Equatable, Sendable {
    public var name: String
    /// Its inode number: Node qids' `path`.
    public var node: UInt64
    /// Taisce's NodeType: file 1, directory 2, symlink 3.
    public var kind: UInt8
    public var size: UInt64
    /// Nanoseconds since the Unix epoch.
    public var modified: Int64
    public var attributes: [Attribute]
  }

  public struct Listing: Equatable, Sendable {
    public var entries: [Entry]
    /// The cursor to continue from.
    public var next: UInt64
    public var done: Bool
  }

  /// A node a query matched, and a path to it from the volume's root.
  public struct Match: Equatable, Sendable {
    public var node: UInt64
    public var path: String
  }

  public enum QueryChangeKind: UInt8, Sendable {
    case added = 1
    case removed
    case changed
    /// The matches so far have all been sent: changes follow.
    case current
    /// The journal no longer reaches the query's place: forget the
    /// matches; they come again, then `current`.
    case reset
  }

  /// A live query's change. `seq` is the change journal's.
  public struct QueryChange: Equatable, Sendable {
    public var kind: QueryChangeKind
    public var node: UInt64
    public var path: String
    public var seq: UInt64

    public init(kind: QueryChangeKind, node: UInt64, path: String, seq: UInt64) {
      self.kind = kind
      self.node = node
      self.path = path
      self.seq = seq
    }
  }

  public struct IndexInfo: Equatable, Sendable {
    public var name: String
    public var kind: UInt8
    public var caseless: Bool
    /// Still filling in what was there before it was declared.
    public var building: Bool
  }

  /// A node's typed attributes. Node's `stat` with the attributes field
  /// lists them with their values.
  public protocol Attributes {
    func getAttribute(_ name: String) throws(FsError) -> Attribute
    func setAttribute(_ attribute: Attribute) throws(FsError)
    func removeAttribute(_ name: String) throws(FsError)
  }

  /// A file: Node's read and write move its bytes.
  public protocol File: NodeIPC.Node, Attributes {
    func resize(_ size: UInt64) throws(FsError)
    /// Makes everything so far durable, through the intent log.
    func sync() throws(FsError)
    /// The file's data, mapped (Mapped.swift): a read-only VMO the service
    /// keeps current. Files over 64 MiB aren't mapped (noSpace).
    @since(2) func map() throws(FsError) -> Handle
  }

  /// A directory: Node's walk, create and remove work in it.
  public protocol Directory: NodeIPC.Node, Attributes {
    /// Entries from `cursor` with their stat fields and the attributes
    /// named (File Pilot style: one batch, no stat per entry).
    func list(cursor: UInt64, max: UInt32, attributes: [String]) throws(FsError) -> Listing
    /// The whole listing at once, with the attributes named, in a VMO
    /// (ListingVMO's format, Listing.swift): read-only, the service's own
    /// while the directory is unchanged, so a warm listing is a handle
    /// (M6m: the file browser's criterion). `cold` if no listing is kept:
    /// batches show their first entries at once, and keep it.
    @since(3) func wholeListing(attributes: [String]) throws(FsError) -> Handle
    /// Moves `from` to `to`, both paths below this directory.
    func rename(_ from: String, to: String) throws(FsError)
    /// The nodes matching `text` (filesystem.md §6); `scan` allows a query
    /// no index serves.
    func query(_ text: String, scan: Bool) throws(FsError) -> [Match]
    /// A live query: a channel whose LiveQuery events are the matches now,
    /// then `current`, then each change as the volume commits it in memory.
    func live(_ text: String, scan: Bool) throws(FsError) -> Handle
    func declareIndex(_ name: String, kind: UInt8, caseless: Bool) throws(FsError)
    func indices() -> [IndexInfo]
    /// Commits a transaction group: everything so far is durable.
    func sync() throws(FsError)
  }

  /// A live query's channel: events only. Close it to end the query.
  public protocol LiveQuery {
    @event func changed(_ change: QueryChange)
  }
}
