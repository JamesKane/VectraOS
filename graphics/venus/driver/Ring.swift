// SPDX-License-Identifier: BSD-3-Clause

// The context's Venus ring (docs/research/venus-protocol.md Part C): a
// buffer in shared memory the renderer's ring thread polls, so commands go
// without a transport round trip. Mesa's layout: head, tail and status a
// cache line each, then the buffer, then 4 bytes of extra. A command larger
// than a sixteenth of the buffer goes in a shared-memory staging area that
// the ring runs with vkExecuteCommandStreamsMESA (§7.3).

import TDVenus
import Venus

@safe final class VenusRing {
  static let id: UInt64 = 1  // non-zero, unique in the context (§9)
  static let bufferSize = 128 * 1024
  static let headOffset = 0, tailOffset = 64, statusOffset = 128, bufferOffset = 192
  static var extraOffset: Int { bufferOffset + bufferSize }
  static var totalSize: Int { (extraOffset + 4 + 4095) & ~4095 }
  /// The renderer's ring thread sleeps after this long with nothing to do.
  static let idleTimeout: UInt64 = 1_000_000

  let transport: any VenusTransport
  let resource: UInt32
  let memory: UnsafeMutableRawPointer
  /// Our tail: bytes published so far (u32, wrapping).
  private(set) var tail: UInt32 = 0
  var staging: (resource: UInt32, address: UnsafeMutableRawPointer, size: Int)?
  /// The seqno of the last stream run from staging: it's free once head passes.
  var stagingSeqno: UInt32 = 0

  /// The ring's memory and its creation, sent directly (§12.2).
  init(_ transport: any VenusTransport) throws(VenusLost) {
    self.transport = transport
    let m = try unsafe transport.createSharedMemory(size: Self.totalSize)
    resource = unsafe m.resource
    unsafe memory = m.address
    unsafe memory.initializeMemory(as: UInt8.self, repeating: 0, count: Self.totalSize)
    var info = unsafe VkRingCreateInfoMESA(
      sType: VK_STRUCTURE_TYPE_RING_CREATE_INFO_MESA, pNext: nil, flags: 0, resourceId: resource, offset: 0,
      size: Self.totalSize, idleTimeout: Self.idleTimeout, headOffset: Self.headOffset, tailOffset: Self.tailOffset,
      statusOffset: Self.statusOffset, bufferOffset: Self.bufferOffset, bufferSize: Self.bufferSize,
      extraOffset: Self.extraOffset, extraSize: 4)
    var e = VenusEncoder()
    unsafe Venus.vkCreateRingMESA(&e, reply: false, Self.id, &info)
    try transport.submit(e.bytes, timeline: 0, syncs: [])
  }

  /// Stops the renderer's ring thread, then frees the memory (§12.7).
  func destroy(cpuSync: UInt32, value: UInt64) {
    var e = VenusEncoder()
    Venus.vkDestroyRingMESA(&e, reply: false, Self.id)
    if (try? transport.submit(e.bytes, timeline: 0, syncs: [(cpuSync, value)])) != nil {
      _ = try? transport.wait([(cpuSync, value)], any: false, timeoutNanoseconds: 10_000_000_000)
    }
    unsafe transport.release(resource: resource, address: memory, size: Self.totalSize)
    if let s = unsafe staging { unsafe transport.release(resource: s.resource, address: s.address, size: s.size) }
  }

  var head: UInt32 { unsafe td_venus_load_acquire(memory + Self.headOffset) }
  var status: UInt32 { unsafe td_venus_load_seq_cst(memory + Self.statusOffset) }

  /// Whether the renderer has run everything up to `seqno` (§12.5).
  func reached(_ seqno: UInt32) -> Bool { Int32(bitPattern: head &- seqno) >= 0 }

  /// Until head reaches `seqno`: polled, with a growing pause; false if the
  /// ring went fatal or a minute passed.
  func wait(_ seqno: UInt32) -> Bool {
    var pause: UInt64 = 10_000
    var waited: UInt64 = 0
    var spins = 0
    while !reached(seqno) {
      if status & 2 != 0 { return false }  // VK_RING_STATUS_FATAL_BIT_MESA
      if spins < 200 {
        spins += 1
        continue
      }
      transport.pause(nanoseconds: pause)
      waited += pause
      if waited > 60_000_000_000 { return false }
      pause = min(pause * 2, 1_000_000)
    }
    return true
  }

  /// Publishes a stream of whole commands; its seqno, which head reaches
  /// once it has run.
  func write(_ stream: [UInt8]) throws(VenusLost) -> UInt32 {
    guard stream.count > Self.bufferSize / 16 else { return try publish(stream) }
    // Indirect: the stream in staging, and one command in the ring.
    guard wait(stagingSeqno) else { throw VenusLost() }
    if (unsafe staging?.size ?? 0) < stream.count {
      if let s = unsafe staging { unsafe transport.release(resource: s.resource, address: s.address, size: s.size) }
      var size = 1 << 20
      while size < stream.count { size *= 2 }
      let m = try unsafe transport.createSharedMemory(size: size)
      unsafe staging = (m.resource, m.address, size)
    }
    guard let s = unsafe staging else { throw VenusLost() }
    stream.withUnsafeBytes { b in unsafe s.address.copyMemory(from: b.baseAddress!, byteCount: b.count) }
    var description = unsafe VkCommandStreamDescriptionMESA(resourceId: s.resource, offset: 0, size: stream.count)
    var e = VenusEncoder()
    unsafe Venus.vkExecuteCommandStreamsMESA(&e, reply: false, 1, &description, nil, 0, nil, 0)
    stagingSeqno = try publish(e.bytes)
    return stagingSeqno
  }

  /// Copies into the buffer (wrapping), stores the tail and wakes an idle
  /// ring thread (§12.3, §12.4).
  func publish(_ stream: [UInt8]) throws(VenusLost) -> UInt32 {
    let n = UInt32(stream.count)
    let size = UInt32(Self.bufferSize)
    // Room: what is unread may not exceed the buffer.
    guard wait(tail &+ n &- size) else { throw VenusLost() }
    let start = Int(tail % size)
    let first = min(stream.count, Self.bufferSize - start)
    let buffer = unsafe memory + Self.bufferOffset
    stream.withUnsafeBytes { b in
      unsafe (buffer + start).copyMemory(from: b.baseAddress!, byteCount: first)
      if first < b.count { unsafe buffer.copyMemory(from: b.baseAddress! + first, byteCount: b.count - first) }
    }
    tail = tail &+ n
    unsafe td_venus_store_seq_cst(memory + Self.tailOffset, tail)
    let s = status
    if s & 2 != 0 { throw VenusLost() }
    if s & 1 != 0 {  // idle: notify, directly
      var e = VenusEncoder()
      Venus.vkNotifyRingMESA(&e, reply: false, Self.id, tail, 0)
      try transport.submit(e.bytes, timeline: 0, syncs: [])
    }
    return tail
  }
}
