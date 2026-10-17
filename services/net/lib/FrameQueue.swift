// SPDX-License-Identifier: BSD-3-Clause

// Frames waiting to leave (N1b): fixed slots in one byte array, reused,
// a frame built in its slot where it will be sent from (the directives'
// batches). The stack fills it; whoever owns the device drains it, in
// order, and clears it. A full queue drops the newest frame, as a full
// device ring would.

public struct FrameQueue {
  /// A slot holds the largest frame: 1514 bytes of Ethernet without the
  /// FCS, rounded up.
  public static let slotSize = 1536

  public let capacity: Int
  /// The slots, `slotSize` bytes each.
  public internal(set) var bytes: [UInt8]
  /// Each queued frame's length, in order.
  public internal(set) var lengths: [Int]
  /// Frames dropped because the queue was full.
  public internal(set) var dropped = 0

  public init(capacity: Int) {
    self.capacity = capacity
    bytes = [UInt8](repeating: 0, count: capacity * FrameQueue.slotSize)
    lengths = []
    lengths.reserveCapacity(capacity)
  }

  public var count: Int { lengths.count }
  public var isEmpty: Bool { lengths.isEmpty }

  /// The offset of frame `i` in `bytes`.
  public func offset(_ i: Int) -> Int { i * FrameQueue.slotSize }

  /// Frame `i`'s bytes, copied (for tests and slow paths; a device copies
  /// from `bytes` at `offset(i)`).
  public func frame(_ i: Int) -> [UInt8] { Array(bytes[offset(i)..<offset(i) + lengths[i]]) }

  /// The next slot's offset, or nil if the queue is full (counted as a
  /// drop). The frame is queued only by `commit`.
  mutating func reserve() -> Int? {
    guard lengths.count < capacity else {
      dropped += 1
      return nil
    }
    return offset(lengths.count)
  }

  /// Queues the frame built at the reserved slot.
  mutating func commit(_ length: Int) {
    precondition(length <= FrameQueue.slotSize)
    lengths.append(length)
  }

  /// Forgets every queued frame; the slots are reused.
  public mutating func removeAll() { lengths.removeAll(keepingCapacity: true) }
}
