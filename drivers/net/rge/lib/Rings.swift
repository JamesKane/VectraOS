// SPDX-License-Identifier: BSD-3-Clause

// The RTL8126's receive and transmit rings (rge(4)'s descriptor formats):
// 256 descriptors of 32 bytes each, each with a 2 KiB buffer of memory the
// chip reaches through the BTI (a `DMAMemory`). A descriptor is the
// chip's while its OWN bit is set; the last has EOR, which sends the chip
// back to the first.
//
// Receive: every descriptor is posted, and one the chip hands back is read
// and posted again in place, so the ring stays full and the chip's next
// is always ours to read next. Its status word holds the frame's length,
// with the FCS. A frame larger than a buffer spans descriptors: dropped.
// Transmit: a frame a descriptor, copied into its buffer; the chip is told
// by TXSTART and gives each back done.
//
// Two threads drive it, as virtio-net's backend: the dispatcher's
// (`transmit`) and the interrupt's (`service`). Each ring has its own
// lock, so a send doesn't wait for the frames received to be read; those
// are given to the class together, after the lock drops.

import CroiMMIO
import DriverHost
import Sys

@safe final class Rings: @unchecked Sendable {
  static let count = 256
  static let bufferSize = 2048
  static let descriptorSize = 32
  /// The largest frame sent or received, its header included, no FCS.
  static let maxFrame = 1514

  enum Desc {
    static let own: UInt32 = 0x8000_0000
    static let endOfRing: UInt32 = 0x4000_0000
    // Transmit.
    static let firstSegment: UInt32 = 0x2000_0000
    static let lastSegment: UInt32 = 0x1000_0000
    static let transmitError: UInt32 = 0x0080_0000
    // Receive.
    static let receiveFirst: UInt32 = 0x0200_0000
    static let receiveLast: UInt32 = 0x0100_0000
    static let receiveError: UInt32 = 0x0010_0000
    static let length: UInt32 = 0x3FFF
  }

  let chip: Chip
  let receiveLock = Lock(), transmitLock = Lock()
  /// The rings and buffers: where they are mapped, and their device
  /// addresses.
  let receiveRing: UInt, receiveBuffers: UInt, receiveBuffersBus: UInt64
  let transmitRing: UInt, transmitBuffers: UInt, transmitBuffersBus: UInt64
  let receiveRingBus: UInt64, transmitRingBus: UInt64
  /// Kept: the rings and buffers live as long as it does.
  let memory: DMAMemory

  /// The receive descriptor read next, and the transmit descriptors
  /// filled next and given back next.
  var receiveNext = 0
  var transmitNext = 0, transmitDone = 0, transmitBusy = 0

  private(set) var received = 0
  private(set) var transmitted = 0
  /// Frames received in error, spanning buffers, or too short; frames
  /// sent that the chip failed; frames not sent for want of a descriptor.
  private(set) var dropped = 0
  private(set) var errors = 0
  private(set) var unsent = 0

  init(chip: Chip, memory: DMAMemory) throws(Status) {
    self.chip = chip
    self.memory = memory
    let ringBytes = Self.count * Self.descriptorSize
    let rr = try unsafe memory.allocate(bytes: ringBytes)
    let tr = try unsafe memory.allocate(bytes: ringBytes)
    let rb = try unsafe memory.allocate(bytes: Self.count * Self.bufferSize)
    let tb = try unsafe memory.allocate(bytes: Self.count * Self.bufferSize)
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
    store(transmitRing, Self.count - 1, 0, Desc.endOfRing)
    croi_dma_barrier()
  }

  func load(_ ring: UInt, _ i: Int, _ offset: Int) -> UInt32 {
    unsafe UInt32(littleEndian: UnsafeRawPointer(bitPattern: ring + UInt(i * Self.descriptorSize + offset))!
      .load(as: UInt32.self))
  }

  func store(_ ring: UInt, _ i: Int, _ offset: Int, _ value: UInt32) {
    unsafe UnsafeMutableRawPointer(bitPattern: ring + UInt(i * Self.descriptorSize + offset))!
      .storeBytes(of: value.littleEndian, as: UInt32.self)
  }

  func store64(_ ring: UInt, _ i: Int, _ offset: Int, _ value: UInt64) {
    unsafe UnsafeMutableRawPointer(bitPattern: ring + UInt(i * Self.descriptorSize + offset))!
      .storeBytes(of: value.littleEndian, as: UInt64.self)
  }

  /// Gives receive descriptor `i` and its buffer to the chip: the
  /// address (offset 16), then the status (28), its length and OWN, after
  /// a barrier.
  func post(_ i: Int) {
    store64(receiveRing, i, 16, receiveBuffersBus + UInt64(i * Self.bufferSize))
    store(receiveRing, i, 24, 0)
    croi_dma_barrier()
    let end = i == Self.count - 1 ? Desc.endOfRing : 0
    store(receiveRing, i, 28, Desc.own | end | UInt32(Self.bufferSize))
  }

  /// What the chip did since the last call: the frames received given to
  /// `deliver` together (after the lock drops), their descriptors posted
  /// again; and transmit descriptors given back.
  func service(_ deliver: ([[UInt8]]) -> Void) {
    let frames = receiveLock.withLock { () -> [[UInt8]] in
      var frames: [[UInt8]] = []
      var posted = 0
      while posted < Self.count {
        let status = load(receiveRing, receiveNext, 28)
        guard status & Desc.own == 0 else { break }
        croi_dma_barrier()  // the frame after the status that covers it
        let n = Int(status & Desc.length) - 4  // without its FCS
        let whole = status & (Desc.receiveFirst | Desc.receiveLast) == Desc.receiveFirst | Desc.receiveLast
        if whole, status & Desc.receiveError == 0, n >= 14, n <= Self.maxFrame {
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
      return frames
    }
    transmitLock.withLock { reclaim() }
    deliver(frames)
  }

  /// Transmit descriptors the chip has given back, under `transmitLock`.
  func reclaim() {
    while transmitBusy > 0 {
      let status = load(transmitRing, transmitDone, 0)
      guard status & Desc.own == 0 else { break }
      if status & Desc.transmitError != 0 { errors += 1 }
      transmitDone = (transmitDone + 1) % Self.count
      transmitBusy -= 1
    }
  }

  /// Sends `frame` (the dispatcher's thread, a write to a conversation's
  /// data); false if every descriptor is with the chip.
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
      store64(transmitRing, i, 8, transmitBuffersBus + UInt64(i * Self.bufferSize))
      store(transmitRing, i, 4, 0)
      croi_dma_barrier()
      let end = i == Self.count - 1 ? Desc.endOfRing : 0
      store(transmitRing, i, 0, Desc.own | Desc.firstSegment | Desc.lastSegment | end | UInt32(frame.count))
      croi_dma_barrier()  // the descriptor before the chip is told
      chip.kickTransmit()
      transmitNext = (i + 1) % Self.count
      transmitBusy += 1
      transmitted += 1
      return true
    }
  }
}
