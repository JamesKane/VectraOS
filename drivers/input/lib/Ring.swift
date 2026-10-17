// SPDX-License-Identifier: BSD-3-Clause

// Input events on the one ring (D43; V2 item 7d): the reader makes a VMO
// holding a ring of 16-byte slots and gives it to the driver with
// `Device.open`. Each slot is one event: when it happened (monotonic ns,
// i64), its evdev type (u16), code (u16) and value (i32), little-endian.
// A batch ends at an EV_SYN SYN_REPORT (type 0, code 0), as evdev's do.
// The driver is the producer and never waits for its reader: what doesn't
// fit is dropped and counted, and a reader that sleeps is woken through
// its doorbell. Neither side trusts the other (the ring breaks for good on
// a cursor out of place).

import Ring
import Sys

public struct InputEvent: Equatable, Sendable {
  public var time: Int64
  public var type: UInt16
  public var code: UInt16
  public var value: Int32

  public init(time: Int64, type: UInt16, code: UInt16, value: Int32) {
    self.time = time
    self.type = type
    self.code = code
    self.value = value
  }

  /// EV_SYN SYN_REPORT: the end of a batch.
  public var endsBatch: Bool { type == 0 && code == 0 }
}

public enum InputRing {
  public static let slotSize = 16
  /// The ring's format descriptor: "INEV", version 1.
  public static let format: UInt64 = 0x1_5645_4E49

  /// The bytes a ring of `slots` (a power of two) takes.
  public static func size(slots: Int) -> Int? { RingLayout.size(slotSize: slotSize, count: slots) }

  @unsafe static func store(_ e: InputEvent, _ slot: UnsafeMutableRawPointer) {
    unsafe slot.storeBytes(of: e.time.littleEndian, as: Int64.self)
    unsafe slot.storeBytes(of: e.type.littleEndian, toByteOffset: 8, as: UInt16.self)
    unsafe slot.storeBytes(of: e.code.littleEndian, toByteOffset: 10, as: UInt16.self)
    unsafe slot.storeBytes(of: e.value.littleEndian, toByteOffset: 12, as: Int32.self)
  }

  @unsafe static func load(_ slot: UnsafeRawPointer) -> InputEvent {
    unsafe InputEvent(time: Int64(littleEndian: slot.loadUnaligned(as: Int64.self)),
                      type: UInt16(littleEndian: slot.loadUnaligned(fromByteOffset: 8, as: UInt16.self)),
                      code: UInt16(littleEndian: slot.loadUnaligned(fromByteOffset: 10, as: UInt16.self)),
                      value: Int32(littleEndian: slot.loadUnaligned(fromByteOffset: 12, as: Int32.self)))
  }
}

/// The driver's side of a reader's ring.
@safe public final class InputWriter: @unchecked Sendable {
  let mapping: Mapping
  var ring: NativeRing
  let bell: Handle
  /// Events that didn't fit.
  public private(set) var dropped = 0

  /// Maps what the reader gave and attaches as its producer; nil if it
  /// isn't a ring of InputRing's.
  public init?(_ events: consuming InputDeviceIPC.Events) {
    guard let need = InputRing.size(slots: Int(events.slots)), let size = try? VMO.size(events.memory),
      need <= size, let mapping = try? VMO.map(events.memory, length: need),
      let ring = unsafe NativeRing(attaching: mapping.address, size: need, producer: true,
                                   slotSize: InputRing.slotSize, format: InputRing.format)
    else { return nil }
    self.mapping = mapping
    self.ring = ring
    bell = events.readerBell
  }

  /// Puts `events` in the ring, as many as fit (the rest dropped), and
  /// wakes the reader if it sleeps. False once the ring is broken.
  @discardableResult
  public func post(_ events: [InputEvent]) -> Bool {
    let space = ring.space()
    if ring.broken { return false }
    let n = min(UInt64(events.count), space)
    for i in 0..<n { unsafe InputRing.store(events[Int(i)], ring.slot(i)) }
    dropped += events.count - Int(n)
    if n > 0, ring.publish(n) { try? Counter.add(bell, 1) }
    return true
  }
}

/// A reader of a device's events: its ring, which `events()` gives to the
/// device's `open`.
@safe public struct InputReader: ~Copyable {
  let memory: Handle
  let mapping: Mapping
  var ring: NativeRing
  let bell: Handle
  public let slots: Int

  /// A ring of `slots` (a power of two) events.
  public init(slots: Int) throws(Status) {
    guard let size = InputRing.size(slots: slots) else { throw .invalidArgs }
    let memory = try VMO.create(size: size)
    let mapping = try VMO.map(memory, length: size)
    guard unsafe NativeRing.create(mapping.address, size: size, slotSize: InputRing.slotSize, count: slots,
                                   format: InputRing.format),
      let ring = unsafe NativeRing(attaching: mapping.address, size: size, producer: false,
                                   slotSize: InputRing.slotSize, format: InputRing.format)
    else { throw .invalidArgs }
    self.bell = try Counter.create()
    self.memory = memory
    self.mapping = mapping
    self.ring = ring
    self.slots = slots
  }

  /// What a device's `open` takes: the ring's VMO and this reader's doorbell.
  public func events() throws(Status) -> InputDeviceIPC.Events {
    InputDeviceIPC.Events(memory: try memory.duplicate(), readerBell: try bell.duplicate(), slots: UInt32(slots))
  }

  /// The events ready, waiting until `deadline` for one (none then).
  /// Throws `badState` once the ring is broken.
  public mutating func read(deadline: Int64 = infiniteDeadline) throws(Status) -> [InputEvent] {
    while true {
      let n = ring.ready()
      if ring.broken { throw .badState }
      if n > 0 {
        var out: [InputEvent] = []
        for i in 0..<n {
          var slot = InlineArray<16, UInt8>(repeating: 0)
          var span = slot.mutableSpan
          span.withUnsafeMutableBytes { unsafe ring.get(i, to: $0.baseAddress!) }
          out.append(slot.span.withUnsafeBytes { unsafe InputRing.load($0.baseAddress!) })
        }
        _ = ring.release(n)  // the producer never waits
        return out
      }
      guard ring.prepareSleep() else { continue }
      let waited: Status?
      do throws(Status) {
        try Counter.wait(bell, until: 1, deadline: deadline)
        waited = nil
      } catch {
        waited = error
      }
      ring.endSleep()
      if let rung = try? Counter.read(bell), rung > 0 { try? Counter.add(bell, -rung) }
      if waited == .timedOut { return [] }
      if let waited { throw waited }
    }
  }
}
