// SPDX-License-Identifier: BSD-3-Clause

// A child's descriptors, its parent's side (D46, td_stdio.h): each one a
// byte-stream ring in a VMO of its own, one way (the child reads it and
// this side writes, or the other way), with a doorbell each way and a
// channel whose closing is its end. Made for a child's Startup, whose
// floor attaches the other side (stdio.c). One writer per ring: whoever
// shares a terminal relays (rc, the pty).

import Ring
import TDNative

/// One of a child's descriptors.
@safe public final class ChildStream: @unchecked Sendable {
  public let fd: Int32
  /// The child reads it: this side writes.
  public let childReads: Bool
  let mapping: Mapping
  var ring: NativeRing
  let childBell: Handle
  let parentBell: Handle
  var channel: Handle?
  /// Waits for this side's doorbell or the child's end of it.
  let port: Handle
  /// The child has gone (its end of the channel closed).
  public private(set) var gone = false

  static let bellKey: UInt64 = 1, goneKey: UInt64 = 2

  /// Makes the ring, doorbells and channel, and adds the child's parts to
  /// `startup` (CROI_PA_STDIO, td_stdio_arg(fd, part)).
  init(fd: Int32, childReads: Bool, for startup: Startup) throws(Status) {
    self.fd = fd
    self.childReads = childReads
    let size = Int(TD_STDIO_RING_SIZE), slotSize = Int(TD_STDIO_SLOT_SIZE), slots = Int(TD_STDIO_SLOTS)
    let vmo = try VMO.create(size: size)
    mapping = try VMO.map(vmo, length: size)
    let base = unsafe mapping.address
    guard unsafe NativeRing.create(base, size: size, slotSize: slotSize, count: slots, format: TD_STDIO_FORMAT,
                                   flags: RingLayout.byteStream),
      let ring = unsafe NativeRing(attaching: base, size: size, producer: childReads, slotSize: slotSize,
                                   format: TD_STDIO_FORMAT, flags: RingLayout.byteStream)
    else { throw .internal }
    self.ring = ring
    childBell = try Counter.create()
    parentBell = try Counter.create()
    let ends = try Channel.create()
    let mine = ends.a
    port = try Port.create()
    var bindings = [Binding.changes(parentBell.raw, key: Self.bellKey),
                    Binding.signals(mine.raw, Signals.peerClosed, key: Self.goneKey)]
    guard try Port.bind(port, &bindings) == 2 else { throw .internal }
    channel = consume mine
    func part(_ p: UInt32) -> UInt32 { HandleType.info(CROI_PA_STDIO, td_stdio_arg(UInt32(fd), p)) }
    startup.add(vmo, info: part(childReads ? TD_STDIO_VMO_IN : TD_STDIO_VMO_OUT))
    startup.add(try childBell.duplicate(), info: part(TD_STDIO_CHILD_BELL))
    startup.add(try parentBell.duplicate(), info: part(TD_STDIO_PARENT_BELL))
    startup.add(ends.b, info: part(TD_STDIO_CHANNEL))
  }

  /// Sleeps for the ring on the port as it says to, until `deadline`.
  func sleep(deadline: Int64) throws(Status) {
    defer { ring.endSleep() }
    guard !gone, ring.prepareSleep() else { return }
    let packet = try Port.wait(port, deadline: deadline)
    if packet.key == Self.goneKey { gone = true }
  }

  func ringChild(_ wake: Bool) { if wake { try? Counter.add(childBell, 1) } }

  /// Writes all of `bytes` (a descriptor the child reads), waiting while
  /// its ring is full; `peerClosed` if the child has gone.
  public func write(_ bytes: [UInt8], deadline: Int64 = infiniteDeadline) throws(Status) {
    guard childReads else { throw .badState }
    var done = 0
    while done < bytes.count {
      guard !gone else { throw .peerClosed }
      let (written, wake) = unsafe bytes.withUnsafeBytes {
        unsafe ring.write(bytes: $0.baseAddress! + done, count: bytes.count - done)
      }
      ringChild(wake)
      done += written
      if written == 0 { try sleep(deadline: deadline) }
    }
  }

  /// Its end (a descriptor the child reads): the child reads its end
  /// after what was written.
  public func closeInput(deadline: Int64 = infiniteDeadline) throws(Status) {
    guard childReads else { throw .badState }
    while true {
      guard !gone else { throw .peerClosed }
      let (done, wake) = ring.writeEnd()
      ringChild(wake)
      if done { return }
      try sleep(deadline: deadline)
    }
  }

  /// What the child wrote next (a descriptor it writes), up to `max`
  /// bytes, waiting until some come (`timedOut` at `deadline`): empty at
  /// its end, or once the child has gone and what it wrote has been read.
  public func read(max: Int = 4096, deadline: Int64 = infiniteDeadline) throws(Status) -> [UInt8] {
    guard !childReads else { throw .badState }
    var buffer = [UInt8](repeating: 0, count: max)
    while true {
      let (got, ended, wake) = unsafe buffer.withUnsafeMutableBytes { unsafe ring.read(bytes: $0.baseAddress!, max: max) }
      ringChild(wake)
      if got > 0 || ended || ring.broken { return Array(buffer[..<got]) }
      if gone { return [] }
      try sleep(deadline: deadline)
    }
  }

  /// Everything the child writes to it, until its end.
  public func readAll(deadline: Int64 = infiniteDeadline) throws(Status) -> [UInt8] {
    var out: [UInt8] = []
    while true {
      let chunk = try read(deadline: deadline)
      if chunk.isEmpty { return out }
      out += chunk
    }
  }

  /// This side's end of it: a child writing it sees it gone (its writes
  /// dropped), one reading it its end.
  public func hangUp() { channel = nil }
}

/// A child's descriptors: by default stdin (fd 0, which the child reads)
/// and stdout (fd 1, which it writes; its stderr goes there too).
@safe public final class ChildStdio: @unchecked Sendable {
  public let streams: [ChildStream]

  /// Makes each descriptor in `descriptors` and adds its parts to
  /// `startup`.
  public init(for startup: Startup, descriptors: [(fd: Int32, childReads: Bool)] = [(0, true), (1, false)])
    throws(Status)
  {
    var streams: [ChildStream] = []
    for d in descriptors { streams.append(try ChildStream(fd: d.fd, childReads: d.childReads, for: startup)) }
    self.streams = streams
  }

  /// Descriptor `fd`, if the child was given it.
  public func stream(_ fd: Int32) -> ChildStream? { streams.first { $0.fd == fd } }

  /// The child has gone: its stdout's end of the channel closed (or its
  /// first descriptor's, without one).
  public var gone: Bool { (stream(1) ?? streams.first)?.gone ?? true }

  // stdin's and stdout's, as before descriptors were each their own.

  public func write(_ bytes: [UInt8], deadline: Int64 = infiniteDeadline) throws(Status) {
    guard let s = stream(0) else { throw .badState }
    try s.write(bytes, deadline: deadline)
  }

  public func closeInput(deadline: Int64 = infiniteDeadline) throws(Status) {
    guard let s = stream(0) else { throw .badState }
    try s.closeInput(deadline: deadline)
  }

  public func read(max: Int = 4096, deadline: Int64 = infiniteDeadline) throws(Status) -> [UInt8] {
    guard let s = stream(1) else { throw .badState }
    return try s.read(max: max, deadline: deadline)
  }

  public func readAll(deadline: Int64 = infiniteDeadline) throws(Status) -> [UInt8] {
    guard let s = stream(1) else { throw .badState }
    return try s.readAll(deadline: deadline)
  }
}
