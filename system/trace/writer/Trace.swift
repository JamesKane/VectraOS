// SPDX-License-Identifier: BSD-3-Clause

// The SDK's Trace module (sdk.md §1): zones, flows, counters and marks,
// written into this process's trace region (docs/trace-format.md). A
// disabled trace point costs one load of the enabled mask and a branch.
// Where the region comes from is the platform's: hosted, a file under
// $TODHCHAI_TRACE, mapped shared (host/Region.swift); natively, a region
// the process was started with (native/Region.swift). Each thread writes a
// trace ring of its own, a one ring (D50) through Ring.swift.

import Ring
import TDTraceCPU
@_exported import TraceFormat

public enum Trace {
  /// The enabled categories. Zero until a region is started.
  @usableFromInline nonisolated(unsafe) static var mask: UInt64 = 0

  /// The region, once started.
  @usableFromInline nonisolated(unsafe) static var region: UnsafeMutableRawPointer?
  nonisolated(unsafe) static var startAttempted = false

  /// Whether points in `category` are being recorded: one load and a branch.
  @inlinable @inline(__always)
  public static func enabled(_ category: TraceCategory) -> Bool {
    unsafe mask & category.rawValue != 0
  }

  /// Stops recording: later trace points do nothing. The region stays
  /// mapped, so a thread mid-record finishes safely.
  public static func stop() { unsafe mask = 0 }

  // MARK: Names

  /// Appends `text` to the string table; its id, or 0 if there's no room.
  static func intern(_ text: StaticString) -> UInt64 {
    guard let p = unsafe region else { return 0 }
    let length = text.utf8CodeUnitCount
    let entry = 4 + (length + 3) & ~3
    let tableSize = unsafe Int(p.load(fromByteOffset: TraceFormat.stringsSize, as: UInt64.self))
    let offset = unsafe Int(td_trace_fetch_add_u64(p + TraceFormat.stringsUsed, UInt64(entry)))
    guard offset + entry <= tableSize else { return 0 }
    let at = unsafe p + TraceFormat.headerSize + offset
    unsafe at.storeBytes(of: UInt32(length).littleEndian, as: UInt32.self)
    text.withUTF8Buffer { unsafe (at + 4).copyMemory(from: $0.baseAddress!, byteCount: length) }
    return UInt64(offset)
  }

  // MARK: Writing

  /// A thread's ring: its trace header and its one ring's writer, on the
  /// heap for the thread's life (the thread-local pointer holds it).
  @unsafe struct ThreadRing: ~Copyable {
    let header: UnsafeMutableRawPointer
    var ring: NativeRing
  }

  /// Writes one record into the calling thread's ring.
  @usableFromInline
  static func write(_ kind: TraceKind, time: UInt64, a: UInt64, b: UInt64) {
    var raw = unsafe td_trace_thread_ring()
    if unsafe raw == nil { unsafe raw = unsafe claimRing() }
    guard let raw = unsafe raw, unsafe raw != UnsafeMutableRawPointer(bitPattern: 1) else { return }
    let thread = unsafe raw.assumingMemoryBound(to: ThreadRing.self)
    let header = unsafe thread.pointee.header
    if unsafe thread.pointee.ring.position >= thread.pointee.ring.slotCount,
      unsafe header.load(fromByteOffset: TraceFormat.ringMode, as: UInt32.self) == 0
    {
      let dropped = unsafe header.load(fromByteOffset: TraceFormat.ringDropped, as: UInt64.self)
      if dropped == 0 { unsafe header.storeBytes(of: time, toByteOffset: TraceFormat.ringFirstDrop, as: UInt64.self) }
      unsafe header.storeBytes(of: time, toByteOffset: TraceFormat.ringLastDrop, as: UInt64.self)
      unsafe header.storeBytes(of: dropped + 1, toByteOffset: TraceFormat.ringDropped, as: UInt64.self)
      return
    }
    // The slot: the ring's sequence, then the record (time; kind, CPU, which
    // isn't known in user space, and thread; a; b).
    let tid = unsafe header.load(fromByteOffset: TraceFormat.ringTid, as: UInt32.self)
    var slot: InlineArray<5, UInt64> = [0, time, UInt64(kind.rawValue) | 0xFFFF << 16 | UInt64(tid) << 32, a, b]
    unsafe withUnsafeBytes(of: &slot) { unsafe thread.pointee.ring.write(from: $0.baseAddress!) }
  }

  /// Claims the next ring for this thread, or marks it as having none.
  static func claimRing() -> UnsafeMutableRawPointer? {
    guard let p = unsafe region else { return nil }
    let count = unsafe p.load(fromByteOffset: TraceFormat.ringCount, as: UInt32.self)
    let index = unsafe td_trace_fetch_add_u32(p + TraceFormat.ringsClaimed, 1)
    guard index < count else {
      unsafe td_trace_set_thread_ring(UnsafeMutableRawPointer(bitPattern: 1))
      return nil
    }
    let ringSize = unsafe Int(p.load(fromByteOffset: TraceFormat.ringSize, as: UInt64.self))
    let header = unsafe p + Int(p.load(fromByteOffset: TraceFormat.ringsOffset, as: UInt64.self)) + Int(index) * ringSize
    let pid = unsafe p.load(fromByteOffset: TraceFormat.processID, as: UInt32.self)
    unsafe header.storeBytes(of: p.load(fromByteOffset: TraceFormat.counterHz, as: UInt64.self),
                             toByteOffset: TraceFormat.ringFrequency, as: UInt64.self)
    unsafe header.storeBytes(of: p.load(fromByteOffset: TraceFormat.start, as: UInt64.self),
                             toByteOffset: TraceFormat.ringSession, as: UInt64.self)
    let circular = unsafe p.load(fromByteOffset: TraceFormat.flags, as: UInt32.self) & TraceFormat.flagCircular
    unsafe header.storeBytes(of: circular, toByteOffset: TraceFormat.ringMode, as: UInt32.self)
    unsafe header.storeBytes(of: UInt32.max, toByteOffset: TraceFormat.ringCPU, as: UInt32.self)
    unsafe header.storeBytes(of: TraceFormat.ringMagic, toByteOffset: TraceFormat.ringMagicOffset, as: UInt32.self)
    unsafe header.storeBytes(of: (pid & 0xfffff) << 12 | (index + 1), toByteOffset: TraceFormat.ringTid, as: UInt32.self)
    // The one ring after it, in the region's zeroed memory: as many slots
    // as fit, a power of two.
    let ring = unsafe header + TraceFormat.ringHeaderSize
    let bytes = ringSize - TraceFormat.ringHeaderSize
    var slots = 1
    while RingLayout.size(slotSize: TraceFormat.slotSize, count: slots * 2).map({ $0 <= bytes }) ?? false { slots *= 2 }
    guard unsafe NativeRing.create(ring, size: bytes, slotSize: TraceFormat.slotSize, count: slots,
                                   format: TraceFormat.ringFormat, flags: RingLayout.overwrite),
      let writer = unsafe NativeRing(attaching: ring, size: bytes, producer: true, slotSize: TraceFormat.slotSize,
                                     format: TraceFormat.ringFormat, flags: RingLayout.overwrite)
    else {
      unsafe td_trace_set_thread_ring(UnsafeMutableRawPointer(bitPattern: 1))
      return nil
    }
    let thread = UnsafeMutablePointer<ThreadRing>.allocate(capacity: 1)
    unsafe thread.initialize(to: ThreadRing(header: header, ring: writer))
    unsafe td_trace_set_thread_ring(UnsafeMutableRawPointer(thread))
    return unsafe UnsafeMutableRawPointer(thread)
  }

  /// The cycle counter, the time base of every record.
  @inlinable @inline(__always)
  public static func now() -> UInt64 { td_trace_ticks() }

  // MARK: Trace points

  /// Runs `body` as a zone named `name`, recorded when it ends.
  @inlinable
  public static func zone<R, E: Error>(_ name: TraceName, _ category: TraceCategory = .app,
                                       _ body: () throws(E) -> R) throws(E) -> R {
    guard enabled(category) else { return try body() }
    let start = td_trace_ticks()
    defer { write(.zone, time: start, a: td_trace_ticks(), b: name.id) }
    return try body()
  }

  /// Records a zone from `start` (from `now()`) to now.
  @inlinable
  public static func zone(_ name: TraceName, _ category: TraceCategory = .app, since start: UInt64) {
    guard enabled(category) else { return }
    write(.zone, time: start, a: td_trace_ticks(), b: name.id)
  }

  /// Records a step of flow `id`, which joins records across threads and
  /// processes.
  @inlinable
  public static func flow(_ id: UInt64, _ name: TraceName, _ category: TraceCategory = .app) {
    guard enabled(category) else { return }
    write(.flow, time: td_trace_ticks(), a: id, b: name.id)
  }

  /// Records a step of flow `id` that happened at `time` (from `now()`):
  /// for a step whose id is known only later, such as a call's write, whose
  /// txid comes with its reply.
  @inlinable
  public static func flow(_ id: UInt64, _ name: TraceName, _ category: TraceCategory = .app, at time: UInt64) {
    guard enabled(category) else { return }
    write(.flow, time: time, a: id, b: name.id)
  }

  /// Records a counter's value.
  @inlinable
  public static func counter(_ name: TraceName, _ value: Int64, _ category: TraceCategory = .app) {
    guard enabled(category) else { return }
    write(.counter, time: td_trace_ticks(), a: name.id, b: UInt64(bitPattern: value))
  }

  /// Records a mark: a label of at most 16 bytes of UTF-8 (longer ones are
  /// cut).
  public static func mark(_ label: StaticString) {
    if unsafe !startAttempted { startFromEnvironment() }
    guard enabled(.mark) else { return }
    var a: UInt64 = 0, b: UInt64 = 0
    label.withUTF8Buffer { utf8 in
      for unsafe (i, byte) in unsafe utf8.prefix(16).enumerated() {
        if i < 8 { a |= UInt64(byte) << (8 * i) } else { b |= UInt64(byte) << (8 * (i - 8)) }
      }
    }
    write(.mark, time: td_trace_ticks(), a: a, b: b)
  }
}

/// A name for zones, flows and counters, interned once in the region's
/// string table. Declare one per call site, as a `static let`:
///
///     static let frameName = TraceName("frame")
public struct TraceName: Sendable {
  public let id: UInt64

  public init(_ text: StaticString) {
    Trace.startFromEnvironment()
    id = Trace.intern(text)
  }
}
