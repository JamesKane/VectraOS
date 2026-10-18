// SPDX-License-Identifier: BSD-3-Clause

// A file's data (D103): what reads and writes a file's bytes, on messages
// until the caller shows it moves them in bulk, then on the channel's ring
// (D67). Its first reads and writes are batches, as a client's always
// were; a second that moves a whole `maxIO` in the same direction attaches
// a ring on the file's channel, if its length covers what moved (a
// stream has none), and every read and write after goes through it: reads asked for ahead,
// up to the ring's entries, on a file whose length it knows; writes sent
// without waiting, their failure said by the next call or by `finish`. A
// server that won't attach leaves it on messages for good.
//
//     var file = NodeFile(try root.open("data/big"))
//     while true {
//       let bytes = try file.read(offset: at, max: NodeFile.preferredIO)
//       ...
//     }
//     try out.finish()  // the writes behind, done

import IPC

/// A ring's reads ahead and writes behind for a file.
extension NodeBulkChannel {
  /// Up to `max` bytes at `offset`, at most an entry's: from the reads
  /// asked for ahead if it is where they are, else asked for now (those
  /// dropped). Then as many more asked for as the ring has entries free,
  /// up to `end`, the file's length (0: none ahead). Writes behind are
  /// waited for first, so a read sees them. Empty at the end.
  public mutating func readAhead(at offset: UInt64, max: Int, end: UInt64) throws(Failure) -> [UInt8] {
    if !behind.isEmpty { try drain() }
    if let first = ahead.first, first.offset + UInt64(aheadUsed) != offset { try dropAhead() }
    if ahead.isEmpty { aheadUsed = 0 }
    // More asked for, from the last asked; none past an entry that came
    // back short (the file's end).
    var next = ahead.last.map { $0.offset + UInt64($0.length) } ?? offset
    let ended = ahead.contains { e in e.done.map { Int($0) < e.length } ?? false }
    var asked = 0
    while !ended, ahead.isEmpty || next < end, let c = freeChunk(), sq.space() > UInt64(asked) {
      let tag = nextTag
      nextTag &+= 1
      let slot = unsafe sq.slot(UInt64(asked))
      unsafe slot.storeBytes(of: UInt64(NodeBulk.read).littleEndian, as: UInt64.self)
      unsafe slot.storeBytes(of: tag.littleEndian, toByteOffset: 8, as: UInt64.self)
      unsafe slot.storeBytes(of: next.littleEndian, toByteOffset: 16, as: UInt64.self)
      unsafe slot.storeBytes(of: UInt64(chunk).littleEndian, toByteOffset: 24, as: UInt64.self)
      unsafe slot.storeBytes(of: UInt64(c * chunk).littleEndian, toByteOffset: 32, as: UInt64.self)
      ahead.append((tag, c, next, chunk, nil, nil))
      next += UInt64(chunk)
      asked += 1
    }
    if asked > 0, sq.publish(UInt64(asked)) { try? Counter.add(serverBell, 1) }
    while ahead.first?.done == nil { try reapFile(wait: true) }
    let first = ahead[0]
    if let failed = first.failed {
      try dropAhead()
      throw .remote(failed)
    }
    let moved = Int(first.done!)
    let n = Swift.min(max, moved - aheadUsed)
    let out = unsafe Array(UnsafeRawBufferPointer(start: data + first.chunk * chunk + aheadUsed, count: Swift.max(n, 0)))
    aheadUsed += Swift.max(n, 0)
    if aheadUsed >= moved {
      if moved < first.length {
        try dropAhead()  // the end: what was asked past it is nothing
      } else {
        ahead.removeFirst()
        aheadUsed = 0
      }
    }
    return out
  }

  /// Sends `bytes` to be written at `offset`, an entry a chunk, without
  /// waiting for them: it waits only for a chunk to put them in. A write
  /// that failed or went short (the file's end, a full disk) is said as
  /// `io` or its error by this call or a later one, or by `drain`.
  public mutating func writeBehind(at offset: UInt64, _ bytes: [UInt8]) throws(Failure) {
    if let f = behindFailure {
      behindFailure = nil
      throw .remote(f)
    }
    if !ahead.isEmpty { try dropAhead() }
    var done = 0
    while done < bytes.count {
      try reapFile(wait: false)
      var c = freeChunk()
      while c == nil || sq.space() == 0 {
        try reapFile(wait: true)
        c = freeChunk()
      }
      if let f = behindFailure {
        behindFailure = nil
        throw .remote(f)
      }
      let length = Swift.min(chunk, bytes.count - done)
      unsafe bytes.withUnsafeBytes { b in
        unsafe (data + c! * chunk).copyMemory(from: b.baseAddress! + done, byteCount: length)
      }
      let tag = nextTag
      nextTag &+= 1
      let slot = unsafe sq.slot(0)
      unsafe slot.storeBytes(of: UInt64(NodeBulk.write).littleEndian, as: UInt64.self)
      unsafe slot.storeBytes(of: tag.littleEndian, toByteOffset: 8, as: UInt64.self)
      unsafe slot.storeBytes(of: (offset + UInt64(done)).littleEndian, toByteOffset: 16, as: UInt64.self)
      unsafe slot.storeBytes(of: UInt64(length).littleEndian, toByteOffset: 24, as: UInt64.self)
      unsafe slot.storeBytes(of: UInt64(c! * chunk).littleEndian, toByteOffset: 32, as: UInt64.self)
      behind.append((tag, c!, length))
      if sq.publish(1) { try? Counter.add(serverBell, 1) }
      done += length
    }
  }

  /// Waits for every read ahead and write behind; the first write's
  /// failure, if one failed.
  public mutating func drain() throws(Failure) {
    while true {
      ahead.removeAll { $0.done != nil }  // done: nothing more to wait for
      if behind.isEmpty && ahead.isEmpty { break }
      try reapFile(wait: true)
    }
    aheadUsed = 0
    if let f = behindFailure {
      behindFailure = nil
      throw .remote(f)
    }
  }

  /// The reads ahead, waited for and dropped.
  mutating func dropAhead() throws(Failure) {
    while ahead.contains(where: { $0.done == nil }) { try reapFile(wait: true) }
    ahead = []
    aheadUsed = 0
  }

  /// A chunk no read ahead or write behind holds.
  func freeChunk() -> Int? {
    var used = [Bool](repeating: false, count: slots)
    for e in ahead { used[e.chunk] = true }
    for e in behind { used[e.chunk] = true }
    return used.firstIndex(of: false)
  }

  /// Takes the completions there are, each to its read ahead or write
  /// behind; with `wait`, waits for one first.
  mutating func reapFile(wait: Bool) throws(Failure) {
    let now = Clock.monotonic()
    let deadline = timeout > Int64.max - now ? Int64.max : now + timeout
    while true {
      let ready = cq.ready()
      if cq.broken { throw .wire(.invalidValue) }
      if ready == 0 {
        guard wait else { return }
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
        let failed = status == 0 ? nil : NodeIPC.NodeError(rawValue: status) ?? .io
        if let k = ahead.firstIndex(where: { $0.tag == tag }), ahead[k].done == nil, Int(count) <= ahead[k].length {
          ahead[k].done = failed == nil ? count : 0
          ahead[k].failed = failed
        } else if let k = behind.firstIndex(where: { $0.tag == tag }), Int(count) <= behind[k].length {
          let short = Int(count) < behind[k].length
          behind.remove(at: k)
          if behindFailure == nil, failed != nil || short { behindFailure = failed ?? .io }
        } else {
          throw .wire(.invalidValue)  // not one of ours, or out of range
        }
      }
      if cq.release(ready) { try? Counter.add(serverBell, 1) }
      return
    }
  }
}

/// A file's reads and writes: messages, then its ring once it moves bulk.
public struct NodeFile: ~Copyable {
  public typealias Failure = IPCError<NodeIPC.NodeError>

  /// The ring it attaches: entries, and the data area they share.
  public static let ringSlots = 16
  public static let ringData = 2 << 20
  /// A read or write's best size: a ring entry's, four messages' worth.
  public static var preferredIO: Int { ringData / ringSlots }

  /// The file's channel, for what isn't its data (stat, wstat): call
  /// `finish` first if it has written, so its writes are done.
  public var client: NodeIPC.NodeClient
  var io = NodeFileIO()

  /// `movedBulk`: its caller has already read a file's worth by messages
  /// (readAll), so its first full read attaches.
  public init(_ client: consuming NodeIPC.NodeClient, movedBulk: Bool = false) {
    self.client = client
    if movedBulk { io.fullReads = 1 }
  }

  /// Whether its reads and writes go through a ring now.
  public var onRing: Bool { io.onRing }

  /// Up to `max` bytes at `offset`; empty at the end.
  public mutating func read(offset: UInt64, max: Int) throws(Failure) -> [UInt8] {
    try io.read(&client, offset: offset, max: max)
  }

  /// Writes all of `bytes` at `offset`: on the ring, without waiting for
  /// them (`finish` does). A write that goes short is an `io` failure.
  public mutating func write(offset: UInt64, _ bytes: [UInt8]) throws(Failure) {
    try io.write(&client, offset: offset, bytes)
  }

  /// Waits for its writes behind: the first failure, if one failed.
  public mutating func finish() throws(Failure) { try io.finish() }
}

/// NodeFile's reads and writes over a client its caller holds (FDIO's
/// descriptions, whose client speaks a protocol over Node): the same
/// client each call, which must outlive it.
public struct NodeFileIO: ~Copyable {
  public typealias Failure = IPCError<NodeIPC.NodeError>

  var ring: NodeBulkChannel?
  /// The server wouldn't attach one: messages for good.
  var refused = false
  var fullReads = 0, fullWrites = 0
  /// Its length when the ring was attached: how far to read ahead.
  var length: UInt64 = 0

  public init() {}

  public var onRing: Bool { ring != nil }

  /// Up to `max` bytes at `offset`; empty at the end.
  public mutating func read(_ client: inout NodeIPC.NodeClient, offset: UInt64, max: Int) throws(Failure) -> [UInt8] {
    if ring != nil { return try ring!.readAhead(at: offset, max: max, end: length) }
    let bytes = try client.read(offset: offset, max: UInt32(Swift.min(max, NodeIPC.maxIO)))
    if bytes.count == NodeIPC.maxIO {
      fullReads += 1
      if fullReads >= 2 { attach(&client, moved: offset + UInt64(bytes.count)) }
    }
    return bytes
  }

  /// Writes all of `bytes` at `offset`, as NodeFile's `write`.
  public mutating func write(_ client: inout NodeIPC.NodeClient, offset: UInt64, _ bytes: [UInt8]) throws(Failure) {
    if ring != nil { return try ring!.writeBehind(at: offset, bytes) }
    var done = 0
    repeat {
      let piece = Array(bytes[done..<Swift.min(bytes.count, done + NodeIPC.maxIO)])
      let n = Int(try client.write(offset: offset + UInt64(done), piece))
      if n < piece.count { throw .remote(.io) }
      done += n
      if n == NodeIPC.maxIO {
        fullWrites += 1
        if fullWrites >= 2 {
          attach(&client, moved: offset + UInt64(done))
          if ring != nil, done < bytes.count {
            return try ring!.writeBehind(at: offset + UInt64(done), Array(bytes[done...]))
          }
        }
      }
    } while done < bytes.count
  }

  /// Waits for its writes behind: the first failure, if one failed.
  public mutating func finish() throws(Failure) {
    if ring != nil { try ring!.drain() }
  }

  /// A ring on the client's channel, if the server will and the file's
  /// length covers the `moved` bytes it has read or written to: a stream
  /// (a pipe, `cons`, a conversation's `data`) has no length, and stays on
  /// messages, whose reads take what there is in the order asked. Else
  /// messages for good.
  mutating func attach(_ client: inout NodeIPC.NodeClient, moved: UInt64) {
    guard ring == nil, !refused else { return }
    do throws(Failure) {
      length = (try? client.stat(fields: NodeIPC.Fields.size).size) ?? 0
      guard length >= moved else {
        refused = true
        return
      }
      ring = try NodeBulkChannel(attachingTo: &client, slots: NodeFile.ringSlots, dataSize: NodeFile.ringData)
    } catch {
      refused = true
    }
  }
}
