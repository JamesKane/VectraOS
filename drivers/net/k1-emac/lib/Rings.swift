// SPDX-License-Identifier: BSD-3-Clause

// The K1 EMAC's receive and transmit rings (Emac.swift's Descriptor):
// 256 descriptors of 16 bytes each, each with a 2 KiB buffer of memory the
// MAC reaches through the BTI (a `DMAMemory`). The descriptors hold 32-bit
// addresses, so the memory is below 4 GiB (the driver's `dma-bits`).
//
// Receive: every descriptor is posted, and one the DMA hands back is read
// and posted again in place, as rge(3)'s are. Its status word holds the
// frame's length with the FCS; a frame that spans descriptors is dropped.
// Transmit: a frame a descriptor, copied into its buffer, given to the
// DMA, which is told by a poll demand and gives each back done.
//
// Two threads drive it, the dispatcher's (`transmit`) and the interrupt's
// (`service`), each ring under its own lock.

import CroiMMIO
import DriverHost
import Sys

@safe final class Rings: @unchecked Sendable {
  static let count = 256
  static let bufferSize = 2048
  /// What the MAC may write into a receive buffer.
  static let receiveSize = 1536
  /// The largest frame sent or received, its header included, no FCS.
  static let maxFrame = 1514

  let mac: Mac
  let receiveLock = Lock(), transmitLock = Lock()
  let receiveRing: UInt, receiveBuffers: UInt, receiveBuffersBus: UInt64
  let transmitRing: UInt, transmitBuffers: UInt, transmitBuffersBus: UInt64
  let receiveRingBus: UInt64, transmitRingBus: UInt64
  /// Kept: the rings and buffers live as long as it does.
  let memory: DMAMemory

  var receiveNext = 0
  var transmitNext = 0, transmitDone = 0, transmitBusy = 0
  private(set) var received = 0
  private(set) var transmitted = 0
  /// Frames received in error, spanning buffers, or too short or long;
  /// frames not sent for want of a descriptor.
  private(set) var dropped = 0
  private(set) var unsent = 0

  init(mac: Mac, memory: DMAMemory) throws(Status) {
    self.mac = mac
    self.memory = memory
    let ringBytes = Self.count * Descriptor.size
    let rr = try unsafe memory.allocate(bytes: ringBytes)
    let tr = try unsafe memory.allocate(bytes: ringBytes)
    let rb = try unsafe memory.allocate(bytes: Self.count * Self.bufferSize)
    let tb = try unsafe memory.allocate(bytes: Self.count * Self.bufferSize)
    // The descriptors' addresses are 32 bits.
    guard unsafe [rr.bus, tr.bus, rb.bus, tb.bus].allSatisfy({ $0 + UInt64(Self.count * Self.bufferSize) <= 1 << 32 })
    else { throw .outOfRange }
    receiveRing = unsafe UInt(bitPattern: rr.pointer)
    receiveRingBus = unsafe rr.bus
    transmitRing = unsafe UInt(bitPattern: tr.pointer)
    transmitRingBus = unsafe tr.bus
    receiveBuffers = unsafe UInt(bitPattern: rb.pointer)
    receiveBuffersBus = unsafe rb.bus
    transmitBuffers = unsafe UInt(bitPattern: tb.pointer)
    transmitBuffersBus = unsafe tb.bus
    for i in 0..<Self.count { post(i) }
    // Transmit descriptors are zero (ours), the last marked.
    store(transmitRing, Self.count - 1, 4, Descriptor.endOfRing)
    croi_dma_barrier()
  }

  func load(_ ring: UInt, _ i: Int, _ offset: Int) -> UInt32 {
    unsafe UInt32(littleEndian: UnsafeRawPointer(bitPattern: ring + UInt(i * Descriptor.size + offset))!
      .load(as: UInt32.self))
  }

  func store(_ ring: UInt, _ i: Int, _ offset: Int, _ value: UInt32) {
    unsafe UnsafeMutableRawPointer(bitPattern: ring + UInt(i * Descriptor.size + offset))!
      .storeBytes(of: value.littleEndian, as: UInt32.self)
  }

  /// Gives receive descriptor `i` and its buffer to the DMA: the size and
  /// address, then OWN, after a barrier.
  func post(_ i: Int) {
    store(receiveRing, i, 4, Descriptor.receive(size: Self.receiveSize, last: i == Self.count - 1))
    store(receiveRing, i, 8, UInt32(truncatingIfNeeded: receiveBuffersBus) + UInt32(i * Self.bufferSize))
    store(receiveRing, i, 12, 0)
    croi_dma_barrier()
    store(receiveRing, i, 0, Descriptor.own)
  }

  /// What the DMA did since the last call: the frames received given to
  /// `deliver` together (after the lock drops), their descriptors posted
  /// again; and transmit descriptors given back.
  func service(_ deliver: ([[UInt8]]) -> Void) {
    let frames = receiveLock.withLock { () -> [[UInt8]] in
      var frames: [[UInt8]] = []
      var posted = 0
      while posted < Self.count {
        let status = load(receiveRing, receiveNext, 0)
        guard status & Descriptor.own == 0 else { break }
        croi_dma_barrier()  // the frame after the status that covers it
        if let n = Descriptor.received(status, limit: Self.maxFrame) {
          let at = unsafe UnsafeRawPointer(bitPattern: receiveBuffers + UInt(receiveNext * Self.bufferSize))!
          frames.append(unsafe Array(UnsafeRawBufferPointer(start: at, count: n)))
        } else {
          dropped += 1
        }
        post(receiveNext)
        receiveNext = (receiveNext + 1) % Self.count
        posted += 1
      }
      received += frames.count
      // A DMA that found no descriptor of its own waits to be told.
      if posted > 0 { mac.kickReceive() }
      return frames
    }
    transmitLock.withLock { reclaim() }
    deliver(frames)
  }

  /// Transmit descriptors the DMA has given back, under `transmitLock`.
  func reclaim() {
    while transmitBusy > 0 {
      guard load(transmitRing, transmitDone, 0) & Descriptor.own == 0 else { break }
      transmitDone = (transmitDone + 1) % Self.count
      transmitBusy -= 1
    }
  }

  /// Sends `frame` (the dispatcher's thread, a write to a conversation's
  /// data); false if every descriptor is with the DMA.
  func transmit(_ frame: [UInt8]) -> Bool {
    guard frame.count <= Self.maxFrame else { return false }
    return transmitLock.withLock {
      reclaim()
      guard transmitBusy < Self.count else {
        unsent += 1
        return false
      }
      let i = transmitNext
      let at = unsafe UnsafeMutableRawPointer(bitPattern: transmitBuffers + UInt(i * Self.bufferSize))!
      frame.withUnsafeBytes { unsafe at.copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
      store(transmitRing, i, 4, Descriptor.transmit(length: frame.count, last: i == Self.count - 1))
      store(transmitRing, i, 8, UInt32(truncatingIfNeeded: transmitBuffersBus) + UInt32(i * Self.bufferSize))
      store(transmitRing, i, 12, 0)
      croi_dma_barrier()
      store(transmitRing, i, 0, Descriptor.own)
      croi_dma_barrier()  // the descriptor before the DMA is told
      mac.kickTransmit()
      transmitNext = (i + 1) % Self.count
      transmitBusy += 1
      transmitted += 1
      return true
    }
  }
}
