// SPDX-License-Identifier: BSD-3-Clause

// The Node protocol (architecture §4): every service is a browsable tree.
// A channel to a node is like a 9P fid. Shaped like 9P, but channels
// already give what 9P's fids, tags, version and attach exist for, and a
// message is a batch (D18, D64): operations run in order on a current
// node, as NFSv4's COMPOUND does, so walking to a file, stat-ing it and
// reading it is one call.

import IPC

@IPCLibrary(id: "todhchai.node", version: 6)
public enum NodeIPC {
  public enum NodeError: Int32, IPCErrorCode, Sendable {
    case notFound = 1
    case notDirectory
    case isDirectory
    case exists
    case denied
    /// A name that is empty, ".", longer than 255 bytes, or holds "/" or NUL.
    case badName
    /// More than 16 names in one walk.
    case tooManyNames
    case notEmpty
    /// The node doesn't do that (writing a read-only leaf, creating in a
    /// directory that doesn't allow it).
    case unsupported
    /// What was written isn't valid for the node (a ctl leaf's command).
    case invalid
    case io
    /// More than 32 operations in one batch.
    case tooManyOps
  }

  public enum NodeKind: UInt8, Sendable {
    case file = 1
    case directory
    /// A service's typed protocol: opening it gives a channel that speaks
    /// that protocol, not Node (architecture §4).
    case service
  }

  /// A node's identity: `path` is unique in its tree and never reused;
  /// `version` changes when its contents do. For cache validation.
  public struct Qid: Equatable, Sendable {
    public var path: UInt64
    public var version: UInt32
    public var kind: NodeKind

    public init(path: UInt64, version: UInt32, kind: NodeKind) {
      self.path = path
      self.version = version
      self.kind = kind
    }
  }

  /// A typed attribute, Taisce's way: `kind` is Taisce's AttributeKind
  /// (string 1, int64, uint64, double, time, bool, bytes, ref, type), and
  /// `value` its encoding (integers little-endian).
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

  /// What stat and readdir report. Fields not asked for are zero or empty.
  public struct Stat: Equatable, Sendable {
    public var qid: Qid
    public var name: String
    public var size: UInt64
    /// Nanoseconds since the Unix epoch; 0 if unknown.
    public var modified: Int64
    public var attributes: [Attribute]

    public init(qid: Qid, name: String, size: UInt64, modified: Int64, attributes: [Attribute]) {
      self.qid = qid
      self.name = name
      self.size = size
      self.modified = modified
      self.attributes = attributes
    }
  }

  public struct DirBatch: Equatable, Sendable {
    public var entries: [Stat]
    /// The cursor to continue from.
    public var next: UInt64
    public var done: Bool

    public init(entries: [Stat], next: UInt64, done: Bool) {
      self.entries = entries
      self.next = next
      self.done = done
    }
  }

  public enum ChangeKind: UInt8, Sendable {
    case created = 1
    case removed
    case modified
    /// Changes were missed: look again.
    case overflow
  }

  /// A change to a watched node (`node`, its qid's path): to a directory's
  /// entry `name`, or to the file itself.
  public struct Change: Equatable, Sendable {
    public var seq: UInt64
    public var node: UInt64
    public var kind: ChangeKind
    public var name: String

    public init(seq: UInt64, node: UInt64, kind: ChangeKind, name: String) {
      self.seq = seq
      self.node = node
      self.kind = kind
      self.name = name
    }
  }

  /// One operation of a batch, on the current node.
  public enum Op: Equatable, Sendable {
    /// Moves the current node down `names` (at most 16; "..": the parent).
    /// Every name must be there. No names: stays.
    case walk(names: [String])
    case stat(fields: UInt32)
    case readdir(cursor: UInt64, max: UInt32, fields: UInt32)
    /// At a stream, a read that begins a batch on a channel opened there
    /// waits until the stream has bytes; a write, until it has room.
    case read(offset: UInt64, max: UInt32)
    case write(offset: UInt64, data: [UInt8])
    /// Sends `changed` events for the current node on this channel from
    /// now on, first replaying those after `since` (0: none).
    case watch(since: UInt64)
    /// Makes `name` in the current directory, and moves there.
    case create(name: String, kind: NodeKind)
    /// Removes the current node; operations after it on it fail.
    case remove
  }

  /// What an operation gave, in the order of the batch.
  public enum Outcome: Equatable, Sendable {
    /// A qid for each name walked.
    case walked([Qid])
    case stat(Stat)
    case dir(DirBatch)
    case data([UInt8])
    case wrote(UInt32)
    /// The current sequence number.
    case watching(UInt64)
    case created(Qid)
    case removed
  }

  /// Which operation failed (from 0; the count of operations: the open
  /// itself), and its NodeError's code.
  public struct Failure: Equatable, Sendable {
    public var index: UInt32
    public var code: Int32

    public init(index: UInt32, code: Int32) {
      self.index = index
      self.code = code
    }
  }

  /// A batch's reply: the results of the operations done, which stop at
  /// the first that fails, and with `open`, if all were done, a channel to
  /// the current node (for a service node, one that speaks its protocol).
  public struct Reply: ~Copyable {
    public var results: [Outcome]
    public var failure: Failure?
    public var node: Handle?

    public init(results: [Outcome], failure: Failure?, node: consuming Handle?) {
      self.results = results
      self.failure = failure
      self.node = node
    }
  }

  /// What `openAhead` gave: a batch's reply, as `batch` with `open` gives
  /// it, and the opened node's first bytes, nil when its server gave none.
  /// `openFid` gives the same, with no channel.
  public struct Ahead: ~Copyable {
    public var results: [Outcome]
    public var failure: Failure?
    public var node: Handle?
    public var data: [UInt8]?

    public init(results: [Outcome], failure: Failure?, node: consuming Handle?, data: [UInt8]?) {
      self.results = results
      self.failure = failure
      self.node = node
      self.data = data
    }
  }

  /// A ring pair for bulk reads and writes of a node (D67), made by the
  /// client: in `memory`, an SQ ring at 0 (`sqSlots` entries of
  /// `NodeBulk.sqEntry` bytes), a CQ ring at `cqOffset` (`cqSlots` of
  /// `NodeBulk.cqEntry`) and `dataSize` bytes of data at `dataOffset`. The
  /// client rings `serverBell` (a counter) when the server sleeps, and the
  /// server rings `clientBell`.
  public struct Bulk: ~Copyable {
    public var memory: Handle
    public var serverBell: Handle
    public var clientBell: Handle
    public var sqSlots: UInt32
    public var cqSlots: UInt32
    public var cqOffset: UInt64
    public var dataOffset: UInt64
    public var dataSize: UInt64

    public init(memory: consuming Handle, serverBell: consuming Handle, clientBell: consuming Handle,
                sqSlots: UInt32, cqSlots: UInt32, cqOffset: UInt64, dataOffset: UInt64, dataSize: UInt64) {
      self.memory = memory
      self.serverBell = serverBell
      self.clientBell = clientBell
      self.sqSlots = sqSlots
      self.cqSlots = cqSlots
      self.cqOffset = cqOffset
      self.dataOffset = dataOffset
      self.dataSize = dataSize
    }
  }

  /// A file's contents as memory (Fuchsia's GetBackingMemory): a VMO to
  /// read or map, never to write, its first `size` bytes the file's.
  public struct Memory: ~Copyable {
    public var vmo: Handle
    public var size: UInt64

    public init(vmo: consuming Handle, size: UInt64) {
      self.vmo = vmo
      self.size = size
    }
  }

  /// What wstat changes, Plan 9's: each field given, nil left as it is
  /// (nulldir's "don't touch").
  public struct Wstat: Equatable, Sendable {
    /// A new name in its directory (no other there of that name).
    public var name: String?
    /// Nanoseconds since the Unix epoch.
    public var modified: Int64?
    /// A file's new length: cut, or grown with zeros.
    public var size: UInt64?

    public init(name: String? = nil, modified: Int64? = nil, size: UInt64? = nil) {
      self.name = name
      self.modified = modified
      self.size = size
    }
  }

  public protocol Node {
    /// Runs `ops` (at most 32) in order on a current node, which starts at
    /// this channel's; `walk` and `create` move it. A single operation is a
    /// batch of one. A walk into another service's tree mounted in this one
    /// hands it the rest of the batch; the server answers its other
    /// channels meanwhile, so a service slow to answer holds up only the
    /// batches that reach it, and replies on different channels may come
    /// out of order.
    func batch(_ ops: [Op], open: Bool) -> Reply
    /// Attaches a ring pair for bulk reads and writes of this channel's
    /// node: one a channel, gone when the channel closes. A read of a
    /// stream waits until it has bytes, and a write until it has room, as
    /// plain ones do, so completions may come out of order; each says
    /// which entry it ends.
    @since(2) func attach(_ bulk: consuming Bulk) throws(NodeError)
    /// This channel's node's contents as memory (a file's); `executable`, a
    /// VMO a process can be started from or a library loaded from, which
    /// only a service whose files may run gives (`denied` otherwise).
    @since(3) func memory(executable: Bool) throws(NodeError) -> Memory
    /// Changes this channel's node, as Plan 9's wstat: all of `change` or
    /// none of it. Renaming and setting the time need a node a client may
    /// remove; the size, a file it may write.
    @since(4) func wstat(_ change: Wstat) throws(NodeError)
    /// Runs `ops` and opens the current node, as `batch` with `open`
    /// does, and gives up to `max` bytes of the node from its start when
    /// its server says reading them changes nothing and waits for nothing
    /// (a file's, never a stream's or a device's): the first read, without
    /// asking for it. They are the node's bytes when it was opened.
    @since(5) func openAhead(_ ops: [Op], max: UInt32) -> Ahead
    /// Runs `ops` as `openAhead` does, but keeps the node they reach open
    /// as fid `fid` on this channel (Plan 9's fid, numbered by the client)
    /// instead of giving a channel to it (`node` is nil): until a clunk
    /// lets it go or this channel closes. The fids in `clunk` are let go
    /// first, so a client's closes go with its next request. A server
    /// that keeps no fids says `unsupported` and runs nothing; `exists`,
    /// a fid open already.
    @since(6) func openFid(_ ops: [Op], fid: UInt32, ahead: UInt32, clunk: [UInt32]) throws(NodeError) -> Ahead
    /// Runs `ops` on a current node that starts at fid `fid`'s, as `batch`
    /// does at a channel's, but for `watch` (`unsupported`); with `open`, a
    /// channel to where they end, for what only a channel does (a ring,
    /// memory, wstat). The fids in `clunk` are let go first; `notFound`, a
    /// fid not open.
    @since(6) func fidBatch(_ fid: UInt32, _ ops: [Op], open: Bool, clunk: [UInt32]) throws(NodeError) -> Reply
    /// Lets the fids go (those not open, ignored).
    @since(6) func clunk(_ fids: [UInt32]) throws(NodeError)
    @event func changed(_ change: Change)
  }
}

extension NodeIPC.Ahead {
  /// `reply`, with `data` (none by default).
  public init(_ reply: consuming NodeIPC.Reply, data: [UInt8]? = nil) {
    let node = reply.node
    self.init(results: reply.results, failure: reply.failure, node: node, data: data)
  }
}

extension NodeIPC {
  /// What stat and readdir fill in beyond the qid and name.
  public enum Fields {
    public static let size: UInt32 = 1 << 0
    public static let modified: UInt32 = 1 << 1
    public static let attributes: UInt32 = 1 << 2
    public static let all: UInt32 = 0b111
  }

  /// The most names one walk takes.
  public static let maxWalk = 16
  /// The most operations one batch takes.
  public static let maxOps = 32
  /// The most bytes one read or write moves.
  public static let maxIO = 32_768

  /// Whether `name` may name a node. (Bytes compared: String's `==`
  /// needs Unicode tables tier 0 doesn't link.)
  public static func isValidName(_ name: String) -> Bool {
    let utf8 = name.utf8
    return !utf8.isEmpty && utf8.count <= 255 && !(utf8.count == 1 && utf8.first == 0x2E) && !utf8.contains(0x2F)
      && !utf8.contains(0)
  }

  /// The names of a path ("a/b/c"), split at its "/" bytes, empty ones
  /// dropped. (String's `split` breaks Characters, which needs the Unicode
  /// tables tier 0 doesn't link.)
  public static func names(_ path: String) -> [String] {
    path.utf8.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
  }

  /// Whether two names are the same bytes.
  public static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
}

extension NodeIPC.Failure {
  /// The error, as NodeError (`io` for a code it doesn't know).
  public var error: NodeIPC.NodeError { NodeIPC.NodeError(rawValue: code) ?? .io }
}
