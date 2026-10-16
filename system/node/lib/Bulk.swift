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

// MARK: The server's side

/// A ring pair attached to a session's node, drained on the dispatcher's
/// thread whenever its doorbell rings. `io` reads or writes the node.
@safe final class BulkServer: @unchecked Sendable {
  typealias IO = (_ op: UInt32, _ offset: UInt64, _ data: UnsafeMutableRawBufferPointer) throws(NodeIPC.NodeError)
    -> UInt32

  let mapping: Mapping
  var sq: NativeRing
  var cq: NativeRing
  /// Ours, to clear (the dispatcher owns the one it watches).
  let serverBell: Handle
  let clientBell: Handle
  let data: UnsafeMutableRawPointer
  let dataSize: UInt64
  let io: IO
  /// The dispatcher's watch of the doorbell, once made.
  var watch: UInt64 = 0

  /// Validates and maps what the client attached. Nil if it doesn't hold
  /// together.
  init?(_ bulk: consuming NodeIPC.Bulk, io: @escaping IO) {
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
    unsafe self.io = io
  }

  /// Serves what the SQ holds while the CQ has room, then sleeps on
  /// whichever stopped it. False once either ring is broken: the pair is
  /// done.
  func serve() -> Bool {
    if let rung = try? Counter.read(serverBell), rung > 0 { try? Counter.add(serverBell, -rung) }
    sq.endSleep()
    cq.endSleep()
    var entry = [UInt8](repeating: 0, count: NodeBulk.sqEntry)
    while true {
      let n = min(sq.ready(), cq.space())
      if sq.broken || cq.broken { return false }
      if n > 0 {
        for i in 0..<n {
          unsafe entry.withUnsafeMutableBytes { unsafe sq.get(i, to: $0.baseAddress!) }
          let (tag, status, count) = handle(entry)
          let slot = unsafe cq.slot(i)
          unsafe slot.storeBytes(of: tag.littleEndian, as: UInt64.self)
          unsafe slot.storeBytes(of: status.littleEndian, toByteOffset: 8, as: Int32.self)
          unsafe slot.storeBytes(of: count.littleEndian, toByteOffset: 12, as: UInt32.self)
        }
        let producerSleeps = sq.release(n)
        let consumerSleeps = cq.publish(n)
        if producerSleeps || consumerSleeps { try? Counter.add(clientBell, 1) }
        continue
      }
      // Nothing to do: sleep on what stopped us, unless it moved meanwhile.
      if sq.ready() == 0 {
        if sq.prepareSleep() { return !sq.broken }
      } else if cq.prepareSleep() {
        return !cq.broken
      }
    }
  }

  /// One SQ entry, checked against the data area: its tag, status and
  /// bytes moved.
  func handle(_ e: [UInt8]) -> (UInt64, Int32, UInt32) {
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
    do throws(NodeIPC.NodeError) {
      return unsafe (tag, 0, try io(op, offset, buffer))
    } catch {
      return (tag, error.rawValue, 0)
    }
  }
}

// MARK: The client's side

/// A client's ring pair on a node: reads and writes of any size, split
/// into entries of a chunk each (the data area over the slots), up to a
/// slot's worth in flight at once.
@safe public struct NodeBulkChannel: ~Copyable {
  public typealias Failure = IPCError<NodeIPC.NodeError>

  var node: NodeIPC.NodeClient
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
  /// How long a wait for completions may take.
  public var timeout: Int64 = 10_000_000_000

  /// Makes a ring pair of `slots` (a power of 2) and a data area of
  /// `dataSize` bytes, and attaches it to `node`'s node.
  public init(_ node: consuming NodeIPC.NodeClient, slots: Int = 16, dataSize: Int = 512 * 1024) throws(Failure) {
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
    var node = node
    try sys { () throws(Status) in
      try Port.bind(port, Binding.signals(clientBell.raw, Signals.positive, key: 1, persistent: true))
      try Port.bind(port, Binding.signals(node.connection.channel.raw, Signals.peerClosed, key: 2))
    }
    let bulk = NodeIPC.Bulk(memory: memory, serverBell: try sys { () throws(Status) in try serverBell.duplicate() },
                            clientBell: try sys { () throws(Status) in try clientBell.duplicate() },
                            sqSlots: UInt32(slots), cqSlots: UInt32(slots), cqOffset: UInt64(cqOffset),
                            dataOffset: UInt64(dataOffset), dataSize: UInt64(dataSize))
    try node.attach(bulk)
    self.node = node
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
    let deadline = Clock.monotonic() + timeout
    while left > 0 {
      let n = cq.ready()
      if cq.broken { throw .wire(.invalidValue) }
      if n == 0 {
        if cq.prepareSleep() {
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
