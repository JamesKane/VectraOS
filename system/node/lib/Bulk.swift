// SPDX-License-Identifier: BSD-3-Clause

// Bulk reads and writes of a node (D67): an SQ/CQ pair of the one ring and
// a data area, in one VMO the client makes and attaches to a node with
// Node's `attach`, with a doorbell counter each way. An SQ entry asks for a
// read or a write of a range of the node and names a range of the data
// area; its CQ entry says how it went. Doorbells ring only when the other
// side has said it sleeps, so a busy pair costs no syscalls.
//
//     var file = try root.open("data/big")
//     var bulk = try NodeBulkChannel(file)
//     let bytes = try bulk.read(at: 0, count: 1 << 20)

import IPC
import Ring

/// The layout both sides agree on.
public enum NodeBulk {
  /// An SQ entry: operation (u32) and 4 reserved bytes, tag, the node's
  /// offset, the length, the data area's offset (u64 each).
  public static let sqEntry = 40
  /// A CQ entry: tag (u64), status (i32: 0, or a NodeError's code), bytes
  /// moved (u32).
  public static let cqEntry = 16
  /// The rings' format descriptors: "NBSQ" and "NBCQ", version 1.
  public static let sqFormat: UInt64 = 0x1_5153_424E
  public static let cqFormat: UInt64 = 0x1_5143_424E
  public static let read: UInt32 = 1
  public static let write: UInt32 = 2
}

/// Whether `bell` rang since it was last cleared, clearing it. A side
/// about to sleep asks this after saying so (`prepareSleep`): its
/// dispatcher or port hears a counter rise to positive, and a ring that
/// came between a read and the subtraction of what it read left the
/// counter positive, so no ring after rose it again, and that side slept
/// for good. Seen rung, it works on instead; seen at zero, the next ring
/// rises and wakes it.
func rungMeanwhile(_ bell: borrowing Handle) -> Bool {
  guard let rung = try? Counter.read(bell), rung > 0 else { return false }
  try? Counter.add(bell, -rung)
  return true
}

// MARK: The server's side

/// A ring pair attached to a session's node, drained on the dispatcher's
/// thread whenever its doorbell rings. `io` reads or writes the node; a
/// read of a stream with nothing there, or a write it has no room for, is
/// held, and answered when the stream is ready (`answerHeld`, D93, D94).
/// Or, made with `start` (a service whose reads and writes take a while,
/// as the 9P import's, D103), each entry is started and answered when
/// whoever did it says so (`finished`), from any thread, out of order.
@safe final class BulkServer: @unchecked Sendable {
  /// The bytes moved, or nil: a read with nothing there yet, or a write
  /// with no room yet, to hold.
  typealias IO = (_ op: UInt32, _ offset: UInt64, _ data: UnsafeMutableRawBufferPointer) throws(NodeIPC.NodeError)
    -> UInt32?

  let mapping: Mapping
  var sq: NativeRing
  var cq: NativeRing
  /// Ours, to clear (the dispatcher owns the one it watches).
  let serverBell: Handle
  let clientBell: Handle
  let data: UnsafeMutableRawPointer
  let dataSize: UInt64
  let io: IO
  let start: NodeRing.Start?
  /// Made with `start`.
  let startsEntries: Bool
  /// Entries started and not yet answered, and the answers come back,
  /// waiting for room in the CQ (`start`'s).
  var inFlight = 0
  let finishedAnswers = Locked<[(tag: UInt64, status: Int32, count: UInt32)]>([])
  /// The dispatcher's watch of the doorbell, once made.
  var watch: UInt64 = 0
  /// Reads and writes held, in the order they came: at most the SQ's
  /// slots.
  var held: [(op: UInt32, tag: UInt64, offset: UInt64, at: UInt64, length: UInt64)] = []
  let sqSlots: Int

  /// Validates and maps what the client attached. Nil if it doesn't hold
  /// together.
  init?(_ bulk: consuming NodeIPC.Bulk, io: @escaping IO, start: NodeRing.Start? = nil) {
    guard let size = try? VMO.size(bulk.memory) else { return nil }
    let sqSize = RingLayout.size(slotSize: NodeBulk.sqEntry, count: Int(bulk.sqSlots))
    let cqSize = RingLayout.size(slotSize: NodeBulk.cqEntry, count: Int(bulk.cqSlots))
    guard let sqSize, let cqSize, UInt64(sqSize) <= bulk.cqOffset, bulk.cqOffset <= bulk.dataOffset,
      UInt64(cqSize) <= bulk.dataOffset - bulk.cqOffset, bulk.dataOffset <= UInt64(size),
      bulk.dataSize <= UInt64(size) - bulk.dataOffset,
      let mapping = try? VMO.map(bulk.memory, length: size)
    else { return nil }
    let base = unsafe mapping.address
    guard let sq = unsafe NativeRing(attaching: base, size: Int(bulk.cqOffset), producer: false,
                                     slotSize: NodeBulk.sqEntry, format: NodeBulk.sqFormat),
      let cq = unsafe NativeRing(attaching: base + Int(bulk.cqOffset), size: Int(bulk.dataOffset - bulk.cqOffset),
                                 producer: true, slotSize: NodeBulk.cqEntry, format: NodeBulk.cqFormat)
    else { return nil }
    self.mapping = mapping
    self.sq = sq
    self.cq = cq
    serverBell = bulk.serverBell
    clientBell = bulk.clientBell
    unsafe data = base + Int(bulk.dataOffset)
    dataSize = bulk.dataSize
    sqSlots = Int(bulk.sqSlots)
    unsafe self.io = io
    unsafe self.start = start
    startsEntries = unsafe start != nil
  }

  /// An entry started is done: answered by the next `serve`, which its
  /// doorbell, rung here, makes the dispatcher run. Any thread.
  func finished(_ tag: UInt64, _ outcome: Result<UInt32, NodeIPC.NodeError>) {
    let answer: (UInt64, Int32, UInt32) = switch outcome {
    case .success(let n): (tag, 0, n)
    case .failure(let e): (tag, e.rawValue, 0)
    }
    finishedAnswers.withLock { $0.append(answer) }
    try? Counter.add(serverBell, 1)
  }

  /// Publishes the answers come back, as many as the CQ has room for.
  func publishFinished() {
    let answers = finishedAnswers.withLock { a -> [(tag: UInt64, status: Int32, count: UInt32)] in
      let n = Swift.min(a.count, Int(cq.space()))
      defer { a.removeFirst(n) }
      return Array(a[..<n])
    }
    guard !answers.isEmpty else { return }
    for (i, a) in answers.enumerated() { complete(UInt64(i), a.tag, a.status, a.count) }
    inFlight -= answers.count
    if cq.publish(UInt64(answers.count)) { try? Counter.add(clientBell, 1) }
  }

  /// Answers the reads and writes held, in order, while the stream can and
  /// the CQ has room; then serves what the SQ holds while the CQ has room,
  /// and sleeps on whichever stopped it. False once either ring is
  /// broken: the pair is done.
  func serve() -> Bool {
    if let rung = try? Counter.read(serverBell), rung > 0 { try? Counter.add(serverBell, -rung) }
    sq.endSleep()
    cq.endSleep()
    answerHeld()
    var entry = [UInt8](repeating: 0, count: NodeBulk.sqEntry)
    while true {
      if sq.broken || cq.broken { return false }
      if startsEntries { publishFinished() }
      // Each SQ entry taken is answered now (a CQ entry), held, or
      // started and answered later, so take no more than the CQ has room
      // for, less what the entries under way will need.
      let outstanding = UInt64(inFlight)
      let room = cq.space() > outstanding ? cq.space() - outstanding : 0
      let n = min(sq.ready(), room)
      if n > 0 {
        var answered: UInt64 = 0
        for i in 0..<n {
          unsafe entry.withUnsafeMutableBytes { unsafe sq.get(i, to: $0.baseAddress!) }
          guard let r = handle(entry) else { continue }
          complete(answered, r.0, r.1, r.2)
          answered += 1
        }
        let producerSleeps = sq.release(n)
        let consumerSleeps = answered > 0 && cq.publish(answered)
        if producerSleeps || consumerSleeps { try? Counter.add(clientBell, 1) }
        continue
      }
      // Nothing to do: sleep on what stopped us, unless it moved meanwhile
      // or the bell rang (an entry started finishing rings it too).
      if startsEntries, !finishedAnswers.withLock({ $0.isEmpty }), cq.space() > 0 { continue }
      if sq.ready() == 0 {
        if sq.prepareSleep() {
          if rungMeanwhile(serverBell) {
            sq.endSleep()
            continue
          }
          return !sq.broken
        }
      } else if cq.prepareSleep() {
        if rungMeanwhile(serverBell) {
          cq.endSleep()
          continue
        }
        return !cq.broken
      }
    }
  }

  /// Answers held reads and writes, each oldest first, until one still
  /// can't go (those of its kind after it wait on the same stream) or the
  /// CQ is full. On the dispatcher's thread: the session's wake, when its
  /// stream is ready.
  func answerHeld() {
    guard !held.isEmpty, !cq.broken else { return }
    var answered: UInt64 = 0
    let room = cq.space()
    var readsWait = false, writesWait = false
    var i = 0
    while answered < room, i < held.count {
      let h = held[i]
      let isRead = h.op == NodeBulk.read
      if isRead ? readsWait : writesWait {
        i += 1
        continue
      }
      let buffer = unsafe UnsafeMutableRawBufferPointer(start: data + Int(h.at), count: Int(h.length))
      let status: Int32, count: UInt32
      do throws(NodeIPC.NodeError) {
        guard let n = unsafe try io(h.op, h.offset, buffer) else {
          if isRead { readsWait = true } else { writesWait = true }
          i += 1
          continue
        }
        (status, count) = (0, n)
      } catch {
        (status, count) = (error.rawValue, 0)
      }
      held.remove(at: i)
      complete(answered, h.tag, status, count)
      answered += 1
    }
    if answered > 0, cq.publish(answered) { try? Counter.add(clientBell, 1) }
  }

  /// CQ entry `i` past what is published: the tag, status and bytes moved.
  func complete(_ i: UInt64, _ tag: UInt64, _ status: Int32, _ count: UInt32) {
    let slot = unsafe cq.slot(i)
    unsafe slot.storeBytes(of: tag.littleEndian, as: UInt64.self)
    unsafe slot.storeBytes(of: status.littleEndian, toByteOffset: 8, as: Int32.self)
    unsafe slot.storeBytes(of: count.littleEndian, toByteOffset: 12, as: UInt32.self)
  }

  /// One SQ entry, checked against the data area: its tag, status and
  /// bytes moved, or nil for an entry held (a read with nothing there yet,
  /// a write with no room). One past the SQ's slots in held entries is
  /// refused.
  func handle(_ e: [UInt8]) -> (UInt64, Int32, UInt32)? {
    func u64(_ at: Int) -> UInt64 {
      var v: UInt64 = 0
      for i in 0..<8 { v |= UInt64(e[at + i]) << (8 * UInt64(i)) }
      return v
    }
    let op = UInt32(truncatingIfNeeded: u64(0)), tag = u64(8), offset = u64(16), length = u64(24), at = u64(32)
    guard op == NodeBulk.read || op == NodeBulk.write, length <= dataSize, at <= dataSize - length else {
      return (tag, NodeIPC.NodeError.invalid.rawValue, 0)
    }
    let buffer = unsafe UnsafeMutableRawBufferPointer(start: data + Int(at), count: Int(length))
    if let start = unsafe self.start {
      inFlight += 1
      unsafe start(op, offset, buffer) { [self] outcome in finished(tag, outcome) }
      return nil
    }
    do throws(NodeIPC.NodeError) {
      // Reads wait behind reads held, writes behind writes: a stream's
      // bytes come and go in order.
      if !held.contains(where: { $0.op == op }), let n = unsafe try io(op, offset, buffer) { return (tag, 0, n) }
      guard held.count < sqSlots else { return (tag, NodeIPC.NodeError.invalid.rawValue, 0) }
      held.append((op, tag, offset, at, length))
      return nil
    } catch {
      return (tag, error.rawValue, 0)
    }
  }
}

/// A ring pair a service serves for a session of its own (D103), whose
/// reads and writes take a while (a remote file's, a disk's): each entry
/// is started on the dispatcher's thread, which must not wait, and its
/// `done` called once it is over, from any thread, with the bytes moved
/// or the failure. Answers go out in the order they come back; a client
/// matches them by tag (D93). `close` when the session ends.
public final class NodeRing: @unchecked Sendable {
  /// A read or write (`NodeBulk.read`, `.write`) of the node at `offset`,
  /// into or from `data`, part of the client's data area: valid until
  /// `done` is called, and only to be touched until then.
  public typealias Start = (_ op: UInt32, _ offset: UInt64, _ data: UnsafeMutableRawBufferPointer,
                            _ done: @escaping @Sendable (Result<UInt32, NodeIPC.NodeError>) -> Void) -> Void

  let server: BulkServer
  let dispatcher: IPCDispatcher

  /// Serves what the client attached, on `dispatcher`.
  public init(_ bulk: consuming NodeIPC.Bulk, dispatcher: IPCDispatcher, start: @escaping Start) throws(NodeIPC.NodeError) {
    guard let server = unsafe BulkServer(bulk, io: { _, _, _ throws(NodeIPC.NodeError) in nil }, start: start),
      let bell = try? server.serverBell.duplicate()
    else { throw .invalid }
    self.server = server
    self.dispatcher = dispatcher
    do throws(Status) {
      server.watch = try dispatcher.watch(bell, signals: Signals.positive) { _ in server.serve() }
    } catch {
      throw .io
    }
    _ = server.serve()  // what came before the attach
  }

  /// Stops serving it: entries still under way finish into nothing.
  public func close() { dispatcher.unwatch(server.watch) }
}

// MARK: The client's side

/// A client's ring pair on a node: reads and writes of any size, split
/// into entries of a chunk each (the data area over the slots), up to a
/// slot's worth in flight at once.
@safe public struct NodeBulkChannel: ~Copyable {
  public typealias Failure = IPCError<NodeIPC.NodeError>

  /// The node's client, if the pair holds it (nil: the caller's, D103).
  var node: NodeIPC.NodeClient?
  let mapping: Mapping
  var sq: NativeRing
  var cq: NativeRing
  let serverBell: Handle
  let clientBell: Handle
  /// Waits for the client's doorbell or the channel's end.
  let port: Handle
  let data: UnsafeMutableRawPointer
  let slots: Int
  public let chunk: Int
  var nextTag: UInt64 = 1
  /// How long a wait for completions may take; Int64.max: no limit.
  public var timeout: Int64 = 10_000_000_000
  /// `takeMany`'s reads in flight, in the order asked: each its tag, the
  /// chunk it fills and, once done, the bytes it moved; and whether the
  /// stream has ended.
  var streaming: [(tag: UInt64, chunk: Int, done: UInt32?)] = []
  var streamEnded = false
  /// `offer`'s writes in flight: each its tag and the chunk it holds.
  var offered: [(tag: UInt64, chunk: Int)] = []
  /// A file's reads asked for ahead (`readAhead`, File.swift), in order:
  /// each its tag, chunk, offset, length and, once done, the bytes it
  /// moved; how much of the first has been given; and its writes behind
  /// (`writeBehind`), each its tag, chunk and length. The first failure
  /// of a write behind waits for the next call to say it.
  var ahead: [(tag: UInt64, chunk: Int, offset: UInt64, length: Int, done: UInt32?, failed: NodeIPC.NodeError?)] = []
  var aheadUsed = 0
  var behind: [(tag: UInt64, chunk: Int, length: Int)] = []
  var behindFailure: NodeIPC.NodeError?

  /// Makes a ring pair of `slots` (a power of 2) and a data area of
  /// `dataSize` bytes, and attaches it to `node`'s node.
  public init(_ node: consuming NodeIPC.NodeClient, slots: Int = 16, dataSize: Int = 512 * 1024) throws(Failure) {
    var node = node
    try self.init(attachingTo: &node, slots: slots, dataSize: dataSize)
    self.node = consume node
  }

  /// The same, attached to `node`'s node, which stays the caller's and
  /// must outlive the pair: a file's messages and its ring on one channel
  /// (NodeFile, D103).
  public init(attachingTo node: inout NodeIPC.NodeClient, slots: Int = 16, dataSize: Int = 512 * 1024)
    throws(Failure)
  {
    func sys<R: ~Copyable>(_ body: () throws(Status) -> R) throws(Failure) -> R {
      do throws(Status) { return try body() } catch { throw .transport(error) }
    }
    guard let sqSize = RingLayout.size(slotSize: NodeBulk.sqEntry, count: slots),
      let cqSize = RingLayout.size(slotSize: NodeBulk.cqEntry, count: slots), dataSize >= slots, dataSize % slots == 0
    else { throw .transport(.invalidArgs) }
    let page = 4096
    let cqOffset = (sqSize + page - 1) & ~(page - 1)
    let dataOffset = (cqOffset + cqSize + page - 1) & ~(page - 1)
    let size = dataOffset + dataSize
    let memory = try sys { () throws(Status) in try VMO.create(size: size) }
    let mapping = try sys { () throws(Status) in try VMO.map(memory, length: size) }
    let base = unsafe mapping.address
    guard unsafe NativeRing.create(base, size: cqOffset, slotSize: NodeBulk.sqEntry, count: slots,
                                   format: NodeBulk.sqFormat),
      unsafe NativeRing.create(base + cqOffset, size: dataOffset - cqOffset, slotSize: NodeBulk.cqEntry,
                               count: slots, format: NodeBulk.cqFormat),
      let sq = unsafe NativeRing(attaching: base, size: cqOffset, producer: true, slotSize: NodeBulk.sqEntry,
                                 format: NodeBulk.sqFormat),
      let cq = unsafe NativeRing(attaching: base + cqOffset, size: dataOffset - cqOffset, producer: false,
                                 slotSize: NodeBulk.cqEntry, format: NodeBulk.cqFormat)
    else { throw .transport(.internal) }
    let serverBell = try sys { () throws(Status) in try Counter.create() }
    let clientBell = try sys { () throws(Status) in try Counter.create() }
    let port = try sys { () throws(Status) in try Port.create() }
    try sys { () throws(Status) in
      try Port.bind(port, Binding.signals(clientBell.raw, Signals.positive, key: 1, persistent: true))
      try Port.bind(port, Binding.signals(node.connection.channel.raw, Signals.peerClosed, key: 2))
    }
    let bulk = NodeIPC.Bulk(memory: memory, serverBell: try sys { () throws(Status) in try serverBell.duplicate() },
                            clientBell: try sys { () throws(Status) in try clientBell.duplicate() },
                            sqSlots: UInt32(slots), cqSlots: UInt32(slots), cqOffset: UInt64(cqOffset),
                            dataOffset: UInt64(dataOffset), dataSize: UInt64(dataSize))
    try node.attach(bulk)
    self.node = nil
    self.mapping = mapping
    self.sq = sq
    self.cq = cq
    self.serverBell = serverBell
    self.clientBell = clientBell
    self.port = port
    unsafe data = base + dataOffset
    self.slots = slots
    chunk = dataSize / slots
  }

  /// Reads `count` bytes from `offset`: fewer at the end of the node.
  public mutating func read(at offset: UInt64, count: Int) throws(Failure) -> [UInt8] {
    var out: [UInt8] = []
    while out.count < count {
      let wave = submitWave(NodeBulk.read, at: offset + UInt64(out.count), remaining: count - out.count)
      let done = try complete(wave)
      for (i, (length, moved)) in zip(wave.indices, done) {
        let start = unsafe data + i * chunk
        unsafe out.append(contentsOf: UnsafeRawBufferPointer(start: start, count: Int(moved)))
        if Int(moved) < length { return out }  // the end of the node
      }
    }
    return out
  }

  /// One read of a stream (D93): what it gives, up to `max` bytes and a
  /// chunk, waiting until it has something; empty once it has ended. A
  /// stream reads one entry at a time, where a file reads a wave.
  public mutating func take(max: Int) throws(Failure) -> [UInt8] {
    let wave = submitWave(NodeBulk.read, at: 0, remaining: min(max, chunk))
    let done = try complete(wave)
    return unsafe Array(UnsafeRawBufferPointer(start: data, count: Int(done.first?.1 ?? 0)))
  }

  /// Reads of a stream kept in flight, one on every free slot, each into
  /// a chunk of its own: waits until one has something, then gives every
  /// read done by then, in the order asked, and asks again for as many.
  /// One read at a time (`take`) waits a round trip through the server
  /// per message; a stream of frames needs them under way together, and
  /// its reader then takes a burst at once. Empty once the stream has
  /// ended. Not to be mixed with the other calls on the same channel.
  public mutating func takeMany(max: Int) throws(Failure) -> [[UInt8]] {
    guard !streamEnded else { return [] }
    // Every free chunk asked for.
    var free = Array(0..<slots)
    free.removeAll { c in streaming.contains { $0.chunk == c } }
    let n = min(free.count, Int(sq.space()))
    for i in 0..<n {
      let tag = nextTag
      nextTag &+= 1
      let slot = unsafe sq.slot(UInt64(i))
      unsafe slot.storeBytes(of: UInt64(NodeBulk.read).littleEndian, as: UInt64.self)
      unsafe slot.storeBytes(of: tag.littleEndian, toByteOffset: 8, as: UInt64.self)
      unsafe slot.storeBytes(of: UInt64(0).littleEndian, toByteOffset: 16, as: UInt64.self)
      unsafe slot.storeBytes(of: UInt64(min(max, chunk)).littleEndian, toByteOffset: 24, as: UInt64.self)
      unsafe slot.storeBytes(of: UInt64(free[i] * chunk).littleEndian, toByteOffset: 32, as: UInt64.self)
      streaming.append((tag, free[i], nil))
    }
    if n > 0, sq.publish(UInt64(n)) { try? Counter.add(serverBell, 1) }
    // At least the first done, and all that are.
    var failure: NodeIPC.NodeError?
    let now = Clock.monotonic()
    let deadline = timeout > Int64.max - now ? Int64.max : now + timeout
    while streaming.first?.done == nil {
      let ready = cq.ready()
      if cq.broken { throw .wire(.invalidValue) }
      if ready == 0 {
        if cq.prepareSleep() {
          if rungMeanwhile(clientBell) {
            cq.endSleep()
            continue
          }
          let packet: Packet
          do throws(Status) { packet = try Port.wait(port, deadline: deadline) } catch { throw .transport(error) }
          if packet.key == 2 { throw .transport(.peerClosed) }
          if let rung = try? Counter.read(clientBell), rung > 0 { try? Counter.add(clientBell, -rung) }
          cq.endSleep()
        }
        continue
      }
      for i in 0..<ready {
        let slot = unsafe cq.slot(i)
        let tag = UInt64(littleEndian: unsafe slot.loadUnaligned(as: UInt64.self))
        let status = Int32(littleEndian: unsafe slot.loadUnaligned(fromByteOffset: 8, as: Int32.self))
        let count = UInt32(littleEndian: unsafe slot.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        guard let k = streaming.firstIndex(where: { $0.tag == tag }), streaming[k].done == nil,
          Int(count) <= min(max, chunk)
        else { throw .wire(.invalidValue) }
        streaming[k].done = count
        if status != 0, failure == nil { failure = NodeIPC.NodeError(rawValue: status) ?? .io }
      }
      if cq.release(ready) { try? Counter.add(serverBell, 1) }
    }
    if let failure { throw .remote(failure) }
    // The done ones from the first, in order; an empty one is the end.
    var out: [[UInt8]] = []
    var taken = 0
    while taken < streaming.count, let count = streaming[taken].done {
      if count == 0 {
        streamEnded = true
        break
      }
      let start = unsafe data + streaming[taken].chunk * chunk
      out.append(unsafe Array(UnsafeRawBufferPointer(start: start, count: Int(count))))
      taken += 1
    }
    streaming.removeFirst(streamEnded ? streaming.count : taken)
    return out
  }

  /// Writes `message`, at most a chunk, to a stream as one entry, without
  /// waiting for it: writes done are taken back first, and only with every
  /// chunk in flight does it wait, for the oldest. A stream of frames
  /// sends a burst without a round trip through the server for each. A
  /// write refused, or short, shows as the failure of a later call.
  public mutating func offer(_ message: [UInt8]) throws(Failure) {
    guard message.count <= chunk else { throw .remote(.invalid) }
    try reapOffered(wait: offered.count == slots || sq.space() == 0)
    var chunkFree = 0
    while offered.contains(where: { $0.chunk == chunkFree }) { chunkFree += 1 }
    unsafe message.withUnsafeBytes { unsafe (data + chunkFree * chunk).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    let tag = nextTag
    nextTag &+= 1
    let slot = unsafe sq.slot(0)
    unsafe slot.storeBytes(of: UInt64(NodeBulk.write).littleEndian, as: UInt64.self)
    unsafe slot.storeBytes(of: tag.littleEndian, toByteOffset: 8, as: UInt64.self)
    unsafe slot.storeBytes(of: UInt64(0).littleEndian, toByteOffset: 16, as: UInt64.self)
    unsafe slot.storeBytes(of: UInt64(message.count).littleEndian, toByteOffset: 24, as: UInt64.self)
    unsafe slot.storeBytes(of: UInt64(chunkFree * chunk).littleEndian, toByteOffset: 32, as: UInt64.self)
    offered.append((tag, chunkFree))
    if sq.publish(1) { try? Counter.add(serverBell, 1) }
  }

  /// Takes back `offer`'s writes done; with `wait`, waits for one first.
  mutating func reapOffered(wait: Bool) throws(Failure) {
    var failure: NodeIPC.NodeError?
    var mustWait = wait
    let now = Clock.monotonic()
    let deadline = timeout > Int64.max - now ? Int64.max : now + timeout
    while true {
      let ready = cq.ready()
      if cq.broken { throw .wire(.invalidValue) }
      if ready == 0 {
        guard mustWait else { break }
        if cq.prepareSleep() {
          if rungMeanwhile(clientBell) {
            cq.endSleep()
            continue
          }
          let packet: Packet
          do throws(Status) { packet = try Port.wait(port, deadline: deadline) } catch { throw .transport(error) }
          if packet.key == 2 { throw .transport(.peerClosed) }
          if let rung = try? Counter.read(clientBell), rung > 0 { try? Counter.add(clientBell, -rung) }
          cq.endSleep()
        }
        continue
      }
      for i in 0..<ready {
        let slot = unsafe cq.slot(i)
        let tag = UInt64(littleEndian: unsafe slot.loadUnaligned(as: UInt64.self))
        let status = Int32(littleEndian: unsafe slot.loadUnaligned(fromByteOffset: 8, as: Int32.self))
        guard let k = offered.firstIndex(where: { $0.tag == tag }) else { throw .wire(.invalidValue) }
        offered.remove(at: k)
        if status != 0, failure == nil { failure = NodeIPC.NodeError(rawValue: status) ?? .io }
      }
      if cq.release(ready) { try? Counter.add(serverBell, 1) }
      mustWait = false
    }
    if let failure { throw .remote(failure) }
  }

  /// Writes all of `bytes` to a stream (D94), a chunk an entry, one entry
  /// at a time: a stream takes what it has room for, and waits while it
  /// has none, so a second entry in flight could go before the rest of
  /// the first.
  public mutating func put(_ bytes: [UInt8]) throws(Failure) {
    var sent = 0
    while sent < bytes.count {
      let length = min(chunk, bytes.count - sent)
      unsafe bytes.withUnsafeBytes { unsafe data.copyMemory(from: $0.baseAddress! + sent, byteCount: length) }
      let wave = submitWave(NodeBulk.write, at: 0, remaining: length)
      sent += Int(try complete(wave).first?.1 ?? 0)
    }
  }

  /// Writes `bytes` at `offset`; how many went.
  @discardableResult
  public mutating func write(at offset: UInt64, _ bytes: [UInt8]) throws(Failure) -> Int {
    var sent = 0
    while sent < bytes.count {
      let n = min(slots, (bytes.count - sent + chunk - 1) / chunk)
      for i in 0..<n {
        let from = sent + i * chunk, length = min(chunk, bytes.count - from)
        unsafe bytes.withUnsafeBytes { unsafe (data + i * chunk).copyMemory(from: $0.baseAddress! + from, byteCount: length) }
      }
      let wave = submitWave(NodeBulk.write, at: offset + UInt64(sent), remaining: bytes.count - sent)
      for (length, moved) in try complete(wave) {
        sent += Int(moved)
        if Int(moved) < length { return sent }
      }
    }
    return sent
  }

  /// Puts up to a slot's worth of entries, a chunk each (entry i using
  /// chunk i), and rings the server if it sleeps. Their tags and lengths.
  mutating func submitWave(_ op: UInt32, at offset: UInt64, remaining: Int) -> [(tag: UInt64, length: Int)] {
    let n = min(slots, (remaining + chunk - 1) / chunk, Int(sq.space()))
    var wave: [(tag: UInt64, length: Int)] = []
    for i in 0..<n {
      let length = min(chunk, remaining - i * chunk)
      let tag = nextTag
      nextTag &+= 1
      let slot = unsafe sq.slot(UInt64(i))
      unsafe slot.storeBytes(of: UInt64(op).littleEndian, as: UInt64.self)
      unsafe slot.storeBytes(of: tag.littleEndian, toByteOffset: 8, as: UInt64.self)
      unsafe slot.storeBytes(of: (offset + UInt64(i * chunk)).littleEndian, toByteOffset: 16, as: UInt64.self)
      unsafe slot.storeBytes(of: UInt64(length).littleEndian, toByteOffset: 24, as: UInt64.self)
      unsafe slot.storeBytes(of: UInt64(i * chunk).littleEndian, toByteOffset: 32, as: UInt64.self)
      wave.append((tag, length))
    }
    if sq.publish(UInt64(n)) { try? Counter.add(serverBell, 1) }
    return wave
  }

  /// Waits for `wave`'s completions: each entry's length and bytes moved,
  /// in the wave's order. The first failure is thrown.
  mutating func complete(_ wave: [(tag: UInt64, length: Int)]) throws(Failure) -> [(Int, UInt32)] {
    var moved = [UInt32?](repeating: nil, count: wave.count)
    var left = wave.count
    var failure: NodeIPC.NodeError?
    let now = Clock.monotonic()
    let deadline = timeout > Int64.max - now ? Int64.max : now + timeout
    while left > 0 {
      let n = cq.ready()
      if cq.broken { throw .wire(.invalidValue) }
      if n == 0 {
        if cq.prepareSleep() {
          if rungMeanwhile(clientBell) {
            cq.endSleep()
            continue
          }
          let packet: Packet
          do throws(Status) { packet = try Port.wait(port, deadline: deadline) } catch { throw .transport(error) }
          if packet.key == 2 { throw .transport(.peerClosed) }
          if let rung = try? Counter.read(clientBell), rung > 0 { try? Counter.add(clientBell, -rung) }
          cq.endSleep()
        }
        continue
      }
      for i in 0..<n {
        let slot = unsafe cq.slot(i)
        let tag = UInt64(littleEndian: unsafe slot.loadUnaligned(as: UInt64.self))
        let status = Int32(littleEndian: unsafe slot.loadUnaligned(fromByteOffset: 8, as: Int32.self))
        let count = UInt32(littleEndian: unsafe slot.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        // A server's answer is checked: its tag one of ours, its count in range.
        guard let k = wave.firstIndex(where: { $0.tag == tag }), moved[k] == nil, Int(count) <= wave[k].length else {
          throw .wire(.invalidValue)
        }
        moved[k] = count
        left -= 1
        if status != 0, failure == nil { failure = NodeIPC.NodeError(rawValue: status) ?? .io }
      }
      if cq.release(n) { try? Counter.add(serverBell, 1) }
    }
    if let failure { throw .remote(failure) }
    return zip(wave, moved).map { ($0.length, $1!) }
  }
}
