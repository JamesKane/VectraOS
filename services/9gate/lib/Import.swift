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
// A channel may attach Node's ring (D103): each of its entries then runs
// on a thread of its own, 9P reads or writes of up to `iounit` of the
// channel's io fid: reads as many under way on the link as the ring has
// entries, writes one after another in the order they came (a server may
// refuse a write past a file's end, which one gone ahead would be).

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
        if r.ahead {
          try s.connection.send(try NodeIPC._reply_Node_openAhead(NodeIPC.Ahead(reply), to: header))
        } else {
          try s.connection.send(try NodeIPC._reply_Node_batch(reply, to: header))
        }
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
      // One opening at a time: a ring's entries ask on threads of their
      // own, and two openings would clunk the fid the other reads with.
      state.opening.lock()
      defer { state.opening.unlock() }
      let kept = state.lock.withLock { () -> UInt32? in
        guard let f = state.ioFid, write ? state.ioWrites : state.ioReads else { return nil }
        return f
      }
      if let kept { return kept }
      return try open(state, at, &temporary, write: write)
    }
    return try open(state, at, &temporary, write: write)
  }

  /// A fid opened at `at`, as `io` says.
  func open(_ state: ImportState, _ at: UInt32, _ temporary: inout [UInt32], write: Bool) throws(NodeError) -> UInt32 {
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

  /// A ring entry of the channel's own file (D103), on a thread of its
  /// own: a read or write of `data` at `offset`, in pieces of at most an
  /// iounit, then `done` with the bytes moved or the failure.
  func ringEntry(_ state: ImportState, _ op: UInt32, _ offset: UInt64, _ data: RingData,
                 _ done: @escaping @Sendable (Result<UInt32, NodeError>) -> Void) {
    let client = self.client
    // A write waits for the one before it (they are started in the SQ's
    // order, here on the dispatcher's thread).
    var after: Lock?
    var mine: Lock?
    if op == NodeBulk.write {
      let m = Lock()
      m.lock()
      after = state.lock.withLock { () -> Lock? in
        defer { state.lastWrite = m }
        return state.lastWrite
      }
      mine = m
    }
    let (before, own) = (after, mine)
    do throws(Status) {
      _ = try Thread.spawn { [self] in
        if let before {
          before.lock()
          before.unlock()
        }
        defer { own?.unlock() }
        do throws(NodeError) {
          var temporary: [UInt32] = []
          let write = op == NodeBulk.write
          let f = try io(state, state.fid, &temporary, write: write)
          if write { state.lock.withLock { state.ahead = [] } }  // what was read ahead may be what this changes
          var moved = 0
          while moved < data.count {
            let want = Swift.min(data.count - moved, Int(client.iounit))
            if write {
              let piece = unsafe data.bytes(moved, want)
              let n = try call { () throws(GateError) in try client.write(f, offset: offset + UInt64(moved), piece) }
              moved += Int(n)
              if Int(n) < want { break }
            } else {
              let got = try call { () throws(GateError) in
                try client.read(f, offset: offset + UInt64(moved), count: UInt32(want))
              }
              unsafe data.put(got, at: moved)
              moved += got.count
              if got.count < want { break }  // the end of the file
            }
          }
          done(.success(UInt32(moved)))
        } catch {
          done(.failure(error))
        }
      }.release()
    } catch {
      mine?.unlock()
      done(.failure(.io))
    }
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
  /// Whether it answers `openAhead`, not `batch`.
  var ahead = false
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
  /// Held while its io fid is opened (`Import.io`).
  let opening = Lock()
  /// Its ring, if one is attached (D103), and its last write entry's
  /// lock, held until that write is done: the next waits for it.
  var ring: NodeRing?
  var lastWrite: Lock?
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
    // Taken from the state, not only closed: its entries' closure holds
    // the state, which held the import, its 9P link and the link's stream
    // for good.
    state.lock.withLock { () -> NodeRing? in
      defer { state.ring = nil }
      return state.ring
    }?.close()
    let fids = state.lock.withLock { [state.fid] + [state.ioFid, state.dirFid].compactMap { $0 } }
    state.gate.clunkLater(fids)
  }
}

struct ImportSession: NodeIPC.NodeHandler {
  let gate: Import
  let state: ImportState
  let end: ImportEnd

  mutating func batch(_ ops: [NodeIPC.Op], open: Bool) -> NodeIPC.Reply { hold(ops, open: open, ahead: false) }

  /// Runs a batch on a thread of its own, its reply held until then:
  /// `batch`'s, or (`ahead`) `openAhead`'s.
  func hold(_ ops: [NodeIPC.Op], open: Bool, ahead: Bool) -> NodeIPC.Reply {
    guard let header = state.deferral.hold() else {
      return NodeIPC.Reply(results: [], failure: NodeIPC.Failure(index: 0, code: NodeError.io.rawValue), node: nil)
    }
    let gate = self.gate, state = self.state
    let held = Held(header)
    do throws(Status) {
      _ = try Thread.spawn {
        var r = gate.run(state, ops, open: open)
        r.header = held.header
        r.ahead = ahead
        state.push(r)
      }.release()
    } catch {
      var r = Ready([], NodeIPC.Failure(index: 0, code: NodeError.io.rawValue))
      r.header = header
      r.ahead = ahead
      state.push(r)
    }
    return NodeIPC.Reply(results: [], failure: nil, node: nil)
  }

  /// A ring for the channel's own file (D103): each entry a thread's 9P
  /// reads or writes (`Import.ringEntry`).
  mutating func attach(_ bulk: consuming NodeIPC.Bulk) throws(NodeError) {
    guard state.lock.withLock({ state.ring == nil }) else { throw .exists }
    let gate = self.gate, state = self.state
    let ring = unsafe try NodeRing(bulk, dispatcher: gate.dispatcher) { op, offset, data, done in
      gate.ringEntry(state, op, offset, unsafe RingData(data), done)
    }
    state.lock.withLock { state.ring = ring }
  }

  func memory(executable: Bool) throws(NodeError) -> NodeIPC.Memory { throw .unsupported }

  func wstat(_ change: NodeIPC.Wstat) throws(NodeError) { try gate.wstat(state.fid, change) }

  /// No bytes ahead: a 9P server's reads may wait or change what they
  /// read.
  mutating func openAhead(_ ops: [NodeIPC.Op], max: UInt32) -> NodeIPC.Ahead {
    NodeIPC.Ahead(hold(ops, open: true, ahead: true))
  }

  /// No fids of ours: each node opened is a 9P fid of its own already,
  /// behind its channel.
  func openFid(_ ops: [NodeIPC.Op], fid: UInt32, ahead: UInt32, clunk: [UInt32]) throws(NodeError) -> NodeIPC.Ahead {
    throw .unsupported
  }

  func fidBatch(_ fid: UInt32, _ ops: [NodeIPC.Op], open: Bool, clunk: [UInt32]) throws(NodeError) -> NodeIPC.Reply {
    throw .unsupported
  }

  func clunk(_ fids: [UInt32]) throws(NodeError) { throw .unsupported }
}

/// A ring entry's part of the client's data area, carried to the thread
/// that fills or reads it: valid until its `done`, and only that thread
/// touches it until then (NodeRing.Start).
@safe struct RingData: @unchecked Sendable {
  let buffer: UnsafeMutableRawBufferPointer
  @unsafe init(_ buffer: UnsafeMutableRawBufferPointer) { unsafe self.buffer = buffer }
  var count: Int { unsafe buffer.count }
  /// `count` bytes from `at`.
  @unsafe func bytes(_ at: Int, _ count: Int) -> [UInt8] {
    unsafe Array(UnsafeRawBufferPointer(rebasing: buffer[at..<(at + count)]))
  }
  /// `bytes` put at `at`.
  @unsafe func put(_ bytes: [UInt8], at: Int) {
    unsafe bytes.withUnsafeBytes { b in unsafe (buffer.baseAddress! + at).copyMemory(from: b.baseAddress!, byteCount: b.count) }
  }
}

/// A held call's header, carried to the thread that answers it (only
/// that thread reads it).
final class Held: @unchecked Sendable {
  let header: MessageHeader
  init(_ header: MessageHeader) { self.header = header }
}
