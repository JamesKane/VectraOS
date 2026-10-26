// SPDX-License-Identifier: BSD-3-Clause

// Conveniences for Node clients: paths, whole reads, text and listings,
// each one batch (D64). A path is relative to the client's node ("a/b/c";
// "" is the node itself), and a batch walks it first.

import IPC

extension NodeIPC.NodeClient {
  public typealias Failure = IPCError<NodeIPC.NodeError>

  /// What a batch did: every operation's result, and the channel `open`
  /// asked for.
  public struct Done: ~Copyable {
    public var results: [NodeIPC.Outcome]
    public var node: Handle?
  }

  /// The channel, for another protocol: what opening a service node gave.
  public consuming func takeChannel() -> Handle {
    connection.takeChannel()
  }

  /// A client of what a batch opened.
  public init(_ done: consuming Done) throws(Failure) {
    let node = done.node
    switch consume node {
    case .some(let h): self.init(channel: h)
    case .none: throw .wire(.unexpectedMessage)  // `open` was asked, so the server owed one
    }
  }

  /// Runs `ops`: their results, or the first failure thrown (what the
  /// operations before it did is dropped, and so is the channel).
  public mutating func run(_ ops: [NodeIPC.Op], open: Bool = false) throws(Failure) -> Done {
    let reply: NodeIPC.Reply
    do throws(IPCError<Never>) {
      reply = try batch(ops, open: open)
    } catch {
      switch error {
      case .transport(let s): throw .transport(s)
      case .wire(let w): throw .wire(w)
      default: throw .wire(.unexpectedMessage)
      }
    }
    if let failure = reply.failure { throw .remote(failure.error) }
    let node = reply.node
    guard reply.results.count == ops.count, !open || node != nil else { throw .wire(.unexpectedMessage) }
    return Done(results: reply.results, node: node)
  }

  /// The walks that lead to `path`, 16 names each.
  public static func walks(_ path: String) -> [NodeIPC.Op] {
    var names = NodeIPC.names(path)[...]
    var ops: [NodeIPC.Op] = []
    while !names.isEmpty {
      ops.append(.walk(names: Array(names.prefix(NodeIPC.maxWalk))))
      names = names.dropFirst(NodeIPC.maxWalk)
    }
    return ops
  }

  /// A channel to the node at `path`: for a service node, one that speaks
  /// its protocol (`takeChannel`).
  public mutating func open(_ path: String) throws(Failure) -> NodeIPC.NodeClient {
    try NodeIPC.NodeClient(try run(Self.walks(path), open: true))
  }

  /// A client of the node at `path` and its stat (`fields`), in one
  /// batch: an open that would otherwise ask again for the node's kind
  /// and size (FDIO's).
  public struct Opened: ~Copyable {
    public var client: NodeIPC.NodeClient
    public let stat: NodeIPC.Stat
    /// Its first bytes when it was opened, if `ahead` asked for them and
    /// its server gave them (`openAhead`).
    public let ahead: [UInt8]?

    /// Its client (outside this module, a field can't be taken alone).
    public consuming func takeClient() -> NodeIPC.NodeClient { client }
  }

  /// With `ahead`, up to that many of the node's first bytes too, from
  /// a server that gives them (`openAhead`).
  public mutating func open(_ path: String, stat fields: UInt32, ahead: UInt32 = 0) throws(Failure) -> Opened {
    let ops = Self.walks(path) + [.stat(fields: fields)]
    var data: [UInt8]? = nil
    let done: Done
    if ahead == 0 {
      done = try run(ops, open: true)
    } else {
      let reply: NodeIPC.Ahead
      do throws(IPCError<Never>) {
        reply = try openAhead(ops, max: ahead)
      } catch {
        switch error {
        case .transport(let s): throw .transport(s)
        case .wire(let w): throw .wire(w)
        default: throw .wire(.unexpectedMessage)
        }
      }
      if let failure = reply.failure { throw .remote(failure.error) }
      let node = reply.node
      guard reply.results.count == ops.count, node != nil else { throw .wire(.unexpectedMessage) }
      data = reply.data
      done = Done(results: reply.results, node: node)
    }
    guard case .stat(let s)? = done.results.last else { throw .wire(.unexpectedMessage) }
    return Opened(client: try NodeIPC.NodeClient(done), stat: s, ahead: data)
  }

  /// `open(_:stat:ahead:)`, the node kept as fid `fid` of this channel
  /// (`openFid`) instead of given a channel, the fids in `clunk` let go
  /// first: its stat, and its first bytes if `ahead` asked and its server
  /// gave them. A server that keeps no fids says `unsupported`.
  public mutating func open(_ path: String, stat fields: UInt32, fid: UInt32, ahead: UInt32, clunk: [UInt32])
    throws(Failure) -> (stat: NodeIPC.Stat, ahead: [UInt8]?)
  {
    let ops = Self.walks(path) + [.stat(fields: fields)]
    let reply = try openFid(ops, fid: fid, ahead: ahead, clunk: clunk)
    if let failure = reply.failure { throw .remote(failure.error) }
    guard reply.results.count == ops.count, case .stat(let s)? = reply.results.last else {
      throw .wire(.unexpectedMessage)
    }
    return (s, reply.data)
  }

  /// Runs `ops` from fid `fid`'s node (`fidBatch`), as `run` does from
  /// the channel's; the fids in `clunk` let go first. A fid the server
  /// hasn't (its channel was made again since) fails as a closed channel
  /// does.
  public mutating func run(fid: UInt32, _ ops: [NodeIPC.Op], open: Bool = false, clunk: [UInt32] = [])
    throws(Failure) -> Done
  {
    let reply: NodeIPC.Reply
    do throws(Failure) {
      reply = try fidBatch(fid, ops, open: open, clunk: clunk)
    } catch .remote(.notFound) {
      throw .transport(.peerClosed)
    }
    if let failure = reply.failure { throw .remote(failure.error) }
    let node = reply.node
    guard reply.results.count == ops.count, !open || node != nil else { throw .wire(.unexpectedMessage) }
    return Done(results: reply.results, node: node)
  }

  /// The qids of the nodes `path` walks through.
  public mutating func walk(_ path: String) throws(Failure) -> [NodeIPC.Qid] {
    var qids: [NodeIPC.Qid] = []
    for r in try run(Self.walks(path)).results { if case .walked(let q) = r { qids += q } }
    return qids
  }

  /// The node's stat.
  public mutating func stat(_ path: String = "", fields: UInt32 = NodeIPC.Fields.all) throws(Failure) -> NodeIPC.Stat {
    guard case .stat(let s)? = try run(Self.walks(path) + [.stat(fields: fields)]).results.last else {
      throw .wire(.unexpectedMessage)
    }
    return s
  }

  /// Up to `max` bytes at `offset`.
  public mutating func read(_ path: String = "", offset: UInt64, max: UInt32) throws(Failure) -> [UInt8] {
    guard case .data(let d)? = try run(Self.walks(path) + [.read(offset: offset, max: max)]).results.last else {
      throw .wire(.unexpectedMessage)
    }
    return d
  }

  /// Writes `data` at `offset`; how many bytes went.
  @discardableResult
  public mutating func write(_ path: String = "", offset: UInt64, _ data: [UInt8]) throws(Failure) -> UInt32 {
    guard case .wrote(let n)? = try run(Self.walks(path) + [.write(offset: offset, data: data)]).results.last else {
      throw .wire(.unexpectedMessage)
    }
    return n
  }

  /// The whole contents: one batch for anything up to `maxIO`, a second
  /// for up to twice it, and past that the rest through a NodeFile of its
  /// own (D103), on the file's ring if it will.
  public mutating func readAll(_ path: String = "") throws(Failure) -> [UInt8] {
    var out: [UInt8] = []
    while out.count < 2 * NodeIPC.maxIO {
      let chunk = try read(path, offset: UInt64(out.count), max: UInt32(NodeIPC.maxIO))
      out += chunk
      if chunk.count < NodeIPC.maxIO { return out }
    }
    var file = NodeFile(try open(path), movedBulk: true)
    while true {
      let chunk = try file.read(offset: UInt64(out.count), max: NodeFile.preferredIO)
      if chunk.isEmpty { return out }
      out += chunk
    }
  }

  /// The contents as text (invalid UTF-8 repaired).
  public mutating func readText(_ path: String = "") throws(Failure) -> String {
    String(decoding: try readAll(path), as: UTF8.self)
  }

  /// Writes `text` at offset 0: for a `ctl` leaf, one command.
  public mutating func writeText(_ text: String, _ path: String = "") throws(Failure) {
    _ = try write(path, offset: 0, Array(text.utf8))
  }

  /// A page of a directory's entries.
  public mutating func readdir(_ path: String = "", cursor: UInt64, max: UInt32, fields: UInt32 = NodeIPC.Fields.all)
    throws(Failure) -> NodeIPC.DirBatch
  {
    let done = try run(Self.walks(path) + [.readdir(cursor: cursor, max: max, fields: fields)])
    guard case .dir(let d)? = done.results.last else { throw .wire(.unexpectedMessage) }
    return d
  }

  /// Every entry of a directory.
  public mutating func list(_ path: String = "", fields: UInt32 = NodeIPC.Fields.all) throws(Failure) -> [NodeIPC.Stat] {
    var out: [NodeIPC.Stat] = []
    var cursor: UInt64 = 0
    while true {
      let page = try readdir(path, cursor: cursor, max: 256, fields: fields)
      out += page.entries
      if page.done { return out }
      cursor = page.next
    }
  }

  /// Watches the node: `changed` events on this channel from now on, after
  /// those since `since` (0: none). The current sequence number.
  public mutating func watch(_ path: String = "", since: UInt64 = 0) throws(Failure) -> UInt64 {
    guard case .watching(let seq)? = try run(Self.walks(path) + [.watch(since: since)]).results.last else {
      throw .wire(.unexpectedMessage)
    }
    return seq
  }

  /// Makes `name` in the directory at `path`, and a client of it.
  public mutating func create(_ name: String, kind: NodeIPC.NodeKind, in path: String = "") throws(Failure)
    -> NodeIPC.NodeClient
  {
    try NodeIPC.NodeClient(try run(Self.walks(path) + [.create(name: name, kind: kind)], open: true))
  }

  /// Removes the node at `path`.
  public mutating func remove(_ path: String = "") throws(Failure) {
    _ = try run(Self.walks(path) + [.remove])
  }
}
