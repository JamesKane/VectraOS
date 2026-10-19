// SPDX-License-Identifier: BSD-3-Clause

// A window's input ring (architecture §13: reading input costs no IPC): the
// one ring (D43), one InputEvent a 40-byte slot, Radharc the producer and
// the window's client the consumer, and a counter for the doorbell. A
// client about to sleep says so on the ring (`prepareSleep`) and waits for
// the counter to pass what it has seen; Radharc, after publishing, adds to
// the counter only if it was told. A full ring drops new events and counts
// them, as todhchai's did: a client that stops reading loses its input,
// not Radharc its time.

import Ring

public enum WindowInput {
  /// The ring's format: "RDIN".
  public static let format: UInt64 = 0x4E49_4452
  public static let slots = 256
  public static var size: Int { RingLayout.size(slotSize: InputEvent.size, count: slots)! }

  /// Radharc's side: lays the ring out in `size` zeroed bytes at `base`.
  @unsafe
  public static func create(_ base: UnsafeMutableRawPointer) -> Bool {
    unsafe NativeRing.create(base, size: size, slotSize: InputEvent.size, count: slots, format: format)
  }
}

/// Radharc's end of a window's ring.
public struct InputProducer: ~Copyable {
  var ring: NativeRing
  public private(set) var dropped = 0

  @unsafe
  public init?(attaching base: UnsafeMutableRawPointer) {
    guard let r = unsafe NativeRing(attaching: base, size: WindowInput.size, producer: true,
                                    slotSize: InputEvent.size, format: WindowInput.format)
    else { return nil }
    ring = r
  }

  /// Appends `event`. True if the client sleeps and its doorbell must be
  /// rung; a full ring drops the event and counts it.
  public mutating func push(_ event: InputEvent) -> Bool {
    guard ring.space() > 0 else {
      dropped += 1
      return false
    }
    unsafe event.encode(into: ring.slot(0))
    return ring.publish(1)
  }
}

/// A client's end.
public struct InputConsumer: ~Copyable {
  var ring: NativeRing

  @unsafe
  public init?(attaching base: UnsafeMutableRawPointer, size: Int) {
    guard size >= WindowInput.size,
      let r = unsafe NativeRing(attaching: base, size: size, producer: false, slotSize: InputEvent.size,
                                format: WindowInput.format)
    else { return nil }
    ring = r
  }

  /// The next event, if there is one (an event of a kind it doesn't know
  /// is skipped).
  public mutating func pop() -> InputEvent? {
    while ring.ready() > 0 {
      var bytes = InlineArray<40, UInt8>(repeating: 0)
      var span = bytes.mutableSpan
      let event = span.withUnsafeMutableBytes { b in
        unsafe ring.get(0, to: b.baseAddress!)
        return unsafe InputEvent(decoding: UnsafeRawPointer(b.baseAddress!))
      }
      _ = ring.release(1)
      if let event { return event }
    }
    return nil
  }

  /// About to wait on the doorbell: true if the ring is still empty, so
  /// the client may wait; false if an event came meanwhile.
  public mutating func prepareSleep() -> Bool { ring.prepareSleep() }

  /// Woken.
  public func endSleep() { ring.endSleep() }
}
