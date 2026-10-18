// SPDX-License-Identifier: BSD-3-Clause

// A remote 9P2000 tree served as Node, to mount in a namespace, as Plan
// 9's import mounts one: each channel a fid on the server. A batch runs
// on a thread of its own, its reply held (D84) until the server has
// answered, since a remote read may wait as long as the file it reads,
// and the dispatcher serves every other channel meanwhile. A channel's
// own fid stays unopened, for walks; reads and writes go through a
// second fid opened on first use, and a directory's listing through a
// third. Files a batch walks to are fids of their own, clunked after.
// A channel's reads read ahead: after a full read of a file whose length
// goes on past it, the next blocks, up to `readAhead` of them, are asked
// for meanwhile, each on a thread of its own, so a sequential reader's
// reads overlap the link's round trips (a device, with no length, such as
// a terminal's cons, is never read ahead: what it gave would be lost).

import IPC
import IPCWire
import NineP
import Node
import Sys

public final class Import: @unchecked Sendable {
  let client: NinePClient
  let dispatcher: IPCDispatcher

  /// Serves `client`'s files as Node, on `dispatcher`.
  public init(_ client: NinePClient, dispatcher: IPCDispatcher) {
    self.client = client
    self.dispatcher = dispatcher
  }

  /// A channel to the server's tree `aname`, attached as `uname`: Node
  /// served at its root, to mount.
  public func attach(aname: String = "", uname: String = "none") throws(GateError) -> Handle {
    let fid = client.fid()
    do throws(GateError) {
      _ = try client.attach(fid, uname: uname, aname: aname)
    } catch {
      client.release(fid)
      throw error
    }
    do throws(Status) { return try channel(fid) } catch {
      client.clunk(fid)
      throw .closed
    }
  }

  /// A channel served at `fid`, which it holds from now on.
  func channel(_ fid: UInt32) throws(Status) -> Handle {
    let ends = try Channel.create()
    let state = ImportState(self, fid)
    var server = NodeIPC.NodeServer(channel: ends.b, impl: ImportSession(gate: self, state: state, end: ImportEnd(state)))
    server.connection.deferral = state.deferral
    let id = try dispatcher.add(server) { (s: inout NodeIPC.NodeServer<ImportSession>) throws(IPCError<Never>) in
      for r in state.takeReady() {
        guard let header = r.header else { continue }
        let reply: NodeIPC.Reply
        if let n = r.node {
          reply = NodeIPC.Reply(results: r.results, failure: r.failure, node: Handle(raw: n))
        } else {
          reply = NodeIPC.Reply(results: r.results, failure: r.failure, node: nil)
        }
        try s.connection.send(try NodeIPC._reply_Node_batch(reply, to: header))
      }
    }
    // A batch may have come before the id did: its reply waits for it.
    let waiting = state.lock.withLock { () -> Bool in
      state.id = id
      return !state.ready.isEmpty
    }
    if waiting { dispatcher.wake(id) }
    return ends.a
  }

  /// Clunks fids off the dispatcher's thread, which mustn't wait on the
  /// network.
  func clunkLater(_ fids: [UInt32]) {
    guard !fids.isEmpty else { return }
    let client = self.client
    do throws(Status) {
      _ = try Thread.spawn { for f in fids { client.clunk(f) } }.release()
    } catch {}
  }

  // MARK: A batch

  /// Runs `ops` from `state`'s file: what Node's batch replies.
  func run(_ state: ImportState, _ ops: [NodeIPC.Op], open: Bool) -> Ready {
    var results: [NodeIPC.Outcome] = []
    guard ops.count <= NodeIPC.maxOps else { return Ready(results, NodeIPC.Failure(index: 0, code: NodeError.tooManyOps.rawValue)) }
    // The file the batch is at: the channel's own fid until a walk.
    var at = state.fid
    var temporary: [UInt32] = []
    defer { for f in temporary { client.clunk(f) } }
    for i in ops.indices {
      do throws(NodeError) {
        switch ops[i] {
        case .walk(let names):
          guard names.count <= NodeIPC.maxWalk else { throw .tooManyNames }
          let to = client.fid()
          let qids: [Qid]
          do throws(GateError) { qids = try client.walk(at, to, names) } catch {
            client.release(to)
            throw Self.code(error)
          }
          guard qids.count == names.count else {
            client.release(to)
            throw .notFound
          }
          temporary.append(to)
          at = to
          results.append(.walked(qids.map(Self.qid)))
        case .stat:
          results.append(.stat(Self.stat(try call { () throws(GateError) in try client.stat(at) })))
        case .readdir(let cursor, let max, _):
          results.append(.dir(try readdir(state, at, cursor: cursor, max: max)))
        case .read(let offset, let max):
          let f = try io(state, at, &temporary, write: false)
          let count = min(max, client.iounit)
          if at == state.fid {
            results.append(.data(try readAhead(state, f, offset: offset, count: count)))
          } else {
            results.append(.data(try call { () throws(GateError) in try client.read(f, offset: offset, count: count) }))
          }
        case .write(let offset, let data):
          let f = try io(state, at, &temporary, write: true)
          // What was read ahead may be what this changes.
          if at == state.fid { state.lock.withLock { state.ahead = [] } }
          var done = 0
          while done < data.count {
            let piece = Array(data[done..<done + min(data.count - done, Int(client.iounit))])
            let n = try call { () throws(GateError) in try client.write(f, offset: offset + UInt64(done), piece) }
            guard n > 0 else { break }
            done += Int(n)
          }
          results.append(.wrote(UInt32(done)))
        case .watch:
          throw .unsupported
        case .create(let name, let kind):
          guard NodeIPC.isValidName(name) else { throw .badName }
          // Tcreate turns a fid into the file, open; the batch then walks
          // to it with one unopened.
          let made = try clone(at)
          let perm: UInt32 = kind == .directory ? DirMode.dir | 0o775 : 0o664
          let mode = kind == .directory ? OpenMode.read : OpenMode.rdwr
          do throws(GateError) {
            _ = try client.create(made, name: name, perm: perm, mode: mode)
          } catch {
            client.release(made)
            throw Self.code(error)
          }
          client.clunk(made)
          let to = client.fid()
          let qids: [Qid]
          do throws(GateError) { qids = try client.walk(at, to, [name]) } catch {
            client.release(to)
            throw Self.code(error)
          }
          guard let qid = qids.first else {
            client.release(to)
            throw .notFound
          }
          temporary.append(to)
          at = to
          results.append(.created(Self.qid(qid)))
        case .remove:
          let doomed = try clone(at)
          try call { () throws(GateError) in try client.remove(doomed) }
          results.append(.removed)
        }
      } catch {
        return Ready(results, NodeIPC.Failure(index: UInt32(i), code: error.rawValue))
      }
    }
    guard open else { return Ready(results, nil) }
    // A channel of its own: a fid cloned from where the batch is.
    do throws(NodeError) {
      let f = try clone(at)
      do throws(Status) { return Ready(results, nil, node: try channel(f).release()) } catch {
        client.clunk(f)
        throw .io
      }
    } catch {
      return Ready(results, NodeIPC.Failure(index: UInt32(ops.count), code: error.rawValue))
    }
  }

  /// A new fid at `fid`'s file, unopened.
  func clone(_ fid: UInt32) throws(NodeError) -> UInt32 {
    let f = client.fid()
    do throws(GateError) { _ = try client.walk(fid, f, []) } catch {
      client.release(f)
      throw Self.code(error)
    }
    return f
  }

  /// A fid opened for reading or writing at `at`: the channel's own, kept
  /// open, if the batch is at its file; else one for this batch.
  /// How many blocks a sequential read keeps asked for ahead.
  static let readAhead = 4

  /// A read of the channel's own read fid `f`: the first block read ahead
  /// if it is this one (the others then still to come), else read now and
  /// those dropped; then blocks asked for until `readAhead` are, if this
  /// one was full and the file goes on past them.
  func readAhead(_ state: ImportState, _ f: UInt32, offset: UInt64, count: UInt32) throws(NodeError) -> [UInt8] {
    let taken = state.lock.withLock { () -> ReadAhead? in
      guard let first = state.ahead.first, first.fid == f, first.offset == offset, first.count == count else {
        state.ahead = []
        return nil
      }
      state.ahead.removeFirst()
      return first
    }
    let data: [UInt8]
    if let taken {
      data = try taken.result()
    } else {
      data = try call { () throws(GateError) in try client.read(f, offset: offset, count: count) }
    }
    guard data.count == Int(count), count > 0 else { return data }
    // Its length once (a device's is 0: never read ahead).
    let known = state.lock.withLock { state.ioFid == f ? state.ioLength : nil }
    let length: UInt64
    if let known {
      length = known
    } else {
      length = (try? client.stat(f))?.length ?? 0
      state.lock.withLock { if state.ioFid == f { state.ioLength = length } }
    }
    var next = state.lock.withLock { state.ahead.last.map { $0.offset + UInt64($0.count) } } ?? offset + UInt64(count)
    while next < length, state.lock.withLock({ state.ahead.count }) < Self.readAhead,
      let ahead = ReadAhead(client, f, offset: next, count: count)
    {
      state.lock.withLock { state.ahead.append(ahead) }
      next += UInt64(count)
    }
    return data
  }

  func io(_ state: ImportState, _ at: UInt32, _ temporary: inout [UInt32], write: Bool) throws(NodeError) -> UInt32 {
    if at == state.fid {
      let kept = state.lock.withLock { () -> UInt32? in
        guard let f = state.ioFid, write ? state.ioWrites : state.ioReads else { return nil }
        return f
      }
      if let kept { return kept }
    }
    let f = try clone(at)
    // Both ways if it may; else the way asked.
    var mode = OpenMode.rdwr
    do throws(GateError) {
      _ = try client.open(f, mode: mode)
    } catch {
      mode = write ? OpenMode.write : OpenMode.read
      do throws(GateError) { _ = try client.open(f, mode: mode) } catch {
        client.clunk(f)
        throw Self.code(error)
      }
    }
    if at == state.fid {
      let old = state.lock.withLock { () -> UInt32? in
        defer {
          state.ioFid = f
          state.ioReads = mode != OpenMode.write
          state.ioWrites = mode != OpenMode.read
        }
        return state.ioFid
      }
      if let old { client.clunk(old) }
    } else {
      temporary.append(f)
    }
    return f
  }

  /// A directory's entries from `cursor`, the byte offset its listing
  /// reached: 0 starts again.
  func readdir(_ state: ImportState, _ at: UInt32, cursor: UInt64, max: UInt32) throws(NodeError) -> NodeIPC.DirBatch {
    let listing: UInt32
    let mine = at == state.fid
    let kept = mine ? state.lock.withLock { () -> UInt32? in
      guard let f = state.dirFid, cursor != 0, cursor == state.dirOffset else { return nil }
      return f
    } : nil
    var skip: UInt64 = 0
    if let kept {
      listing = kept
    } else {
      // From the start: 9P reads a directory in order from 0, so a
      // listing resumed on a fid of its own reads its way to the cursor.
      let f = try clone(at)
      do throws(GateError) { _ = try client.open(f, mode: OpenMode.read) } catch {
        client.clunk(f)
        throw Self.code(error)
      }
      listing = f
      skip = cursor
      if mine {
        let old = state.lock.withLock { () -> UInt32? in
          defer {
            state.dirFid = f
            state.dirOffset = 0
          }
          return state.dirFid
        }
        if let old { client.clunk(old) }
      }
    }
    defer { if !mine { client.clunk(listing) } }
    var at: UInt64 = 0
    while at < skip {
      let passed = try call { () throws(GateError) in try client.read(listing, offset: at, count: client.iounit) }
      guard !passed.isEmpty else { throw .invalid }  // past the end
      at += UInt64(passed.count)
    }
    guard at == skip else { throw .invalid }  // not where a read ended
    let data = try call { () throws(GateError) in try client.read(listing, offset: cursor, count: client.iounit) }
    guard let dirs = Dir.decodeAll(data) else { throw .io }
    let next = cursor + UInt64(data.count)
    if mine { state.lock.withLock { state.dirOffset = next } }
    // Each read's stats, even past `max`: Node's listing takes what comes.
    _ = max
    return NodeIPC.DirBatch(entries: dirs.map(Self.stat), next: next, done: data.isEmpty)
  }

  func call<R>(_ body: () throws(GateError) -> R) throws(NodeError) -> R {
    do throws(GateError) { return try body() } catch { throw Self.code(error) }
  }

  /// A failure as Node says it: the server's text read back (Export's
  /// strings), and a broken connection `io`.
  static func code(_ e: GateError) -> NodeError {
    if case .error(let text) = e { return Errors.code(text) }
    return .io
  }

  static func qid(_ q: Qid) -> NodeIPC.Qid {
    NodeIPC.Qid(path: q.path, version: q.version, kind: q.type & QidType.dir != 0 ? .directory : .file)
  }

  static func stat(_ d: Dir) -> NodeIPC.Stat {
    NodeIPC.Stat(qid: qid(d.qid), name: d.name, size: d.length, modified: Int64(d.mtime) * 1_000_000_000,
                 attributes: [])
  }

  /// Changes `fid`'s file, as Twstat: only what's given.
  func wstat(_ fid: UInt32, _ change: NodeIPC.Wstat) throws(NodeError) {
    var d = Dir.unchanged
    if let n = change.name { d.name = n }
    if let m = change.modified { d.mtime = UInt32(truncatingIfNeeded: m / 1_000_000_000) }
    if let s = change.size { d.length = s }
    try call { () throws(GateError) in try client.wstat(fid, d) }
  }
}

/// A batch's reply, waiting for the dispatcher's thread to send it; its
/// channel, if it opened one, as a raw handle.
struct Ready {
  var header: MessageHeader?
  var results: [NodeIPC.Outcome]
  var failure: NodeIPC.Failure?
  var node: UInt32?

  init(_ results: [NodeIPC.Outcome], _ failure: NodeIPC.Failure?, node: UInt32? = nil) {
    self.results = results
    self.failure = failure
    self.node = node
  }
}

/// One channel's fids and its held replies.
/// A block asked for before it was read: a thread's read, its result
/// kept for the read that wants it (or dropped with it).
final class ReadAhead: @unchecked Sendable {
  let fid: UInt32
  let offset: UInt64
  let count: UInt32
  let thread: Handle
  let outcome = Locked<Result<[UInt8], GateError>?>(nil)

  init?(_ client: NinePClient, _ fid: UInt32, offset: UInt64, count: UInt32) {
    self.fid = fid
    self.offset = offset
    self.count = count
    let outcome = self.outcome
    do throws(Status) {
      thread = try Thread.spawn {
        let r: Result<[UInt8], GateError>
        do throws(GateError) { r = .success(try client.read(fid, offset: offset, count: count)) } catch { r = .failure(error) }
        outcome.withLock { $0 = r }
      }
    } catch {
      return nil
    }
  }

  /// Waits for it.
  func result() throws(NodeError) -> [UInt8] {
    try? Thread.join(thread)
    switch outcome.withLock({ $0 }) {
    case .success(let data)?: return data
    case .failure(let e)?: throw Import.code(e)
    case nil: throw .io
    }
  }
}

final class ImportState: @unchecked Sendable {
  let gate: Import
  let fid: UInt32
  let lock = Lock()
  let deferral = IPCDeferral()
  var id: UInt64 = 0
  var ready: [Ready] = []
  /// Its fid opened for reading and writing, and which ways it opened.
  var ioFid: UInt32? {
    didSet {
      ioLength = nil
      ahead = []
    }
  }
  var ioReads = false, ioWrites = false
  /// The io fid's length, once stat'd, and the blocks read ahead, in order.
  var ioLength: UInt64?
  var ahead: [ReadAhead] = []
  /// Its directory listing's fid, and how far it has read.
  var dirFid: UInt32?
  var dirOffset: UInt64 = 0

  init(_ gate: Import, _ fid: UInt32) {
    self.gate = gate
    self.fid = fid
  }

  /// Queues a reply and wakes the dispatcher to send it, once the
  /// channel has its id (until then, `channel` wakes it).
  func push(_ r: Ready) {
    let id = lock.withLock { () -> UInt64 in
      ready.append(r)
      return self.id
    }
    if id != 0 { gate.dispatcher.wake(id) }
  }

  func takeReady() -> [Ready] {
    lock.withLock {
      defer { ready = [] }
      return ready
    }
  }
}

/// Held only by a channel's server: when the dispatcher drops it (the
/// channel closed), its fids are clunked.
final class ImportEnd: @unchecked Sendable {
  let state: ImportState

  init(_ state: ImportState) { self.state = state }

  deinit {
    let fids = state.lock.withLock { [state.fid] + [state.ioFid, state.dirFid].compactMap { $0 } }
    state.gate.clunkLater(fids)
  }
}

struct ImportSession: NodeIPC.NodeHandler {
  let gate: Import
  let state: ImportState
  let end: ImportEnd

  mutating func batch(_ ops: [NodeIPC.Op], open: Bool) -> NodeIPC.Reply {
    guard let header = state.deferral.hold() else {
      return NodeIPC.Reply(results: [], failure: NodeIPC.Failure(index: 0, code: NodeError.io.rawValue), node: nil)
    }
    let gate = self.gate, state = self.state
    let held = Held(header)
    do throws(Status) {
      _ = try Thread.spawn {
        var r = gate.run(state, ops, open: open)
        r.header = held.header
        state.push(r)
      }.release()
    } catch {
      var r = Ready([], NodeIPC.Failure(index: 0, code: NodeError.io.rawValue))
      r.header = header
      state.push(r)
    }
    return NodeIPC.Reply(results: [], failure: nil, node: nil)
  }

  mutating func attach(_ bulk: consuming NodeIPC.Bulk) throws(NodeError) { throw .unsupported }

  func memory(executable: Bool) throws(NodeError) -> NodeIPC.Memory { throw .unsupported }

  func wstat(_ change: NodeIPC.Wstat) throws(NodeError) { try gate.wstat(state.fid, change) }
}

/// A held call's header, carried to the thread that answers it (only
/// that thread reads it).
final class Held: @unchecked Sendable {
  let header: MessageHeader
  init(_ header: MessageHeader) { self.header = header }
}
