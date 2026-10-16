// SPDX-License-Identifier: BSD-3-Clause

// A child's stdio, its parent's side (D46, td_stdio.h): two byte-stream
// rings in one VMO (the child's stdin, which this side writes, and its
// stdout, which this side reads), a doorbell each way, and a channel whose
// closing is the end of both. Made for a child's Startup, whose floor
// attaches the other side (stdio.c). One writer per ring: whoever shares a
// terminal relays (rc, the pty).

import Ring
import TDNative

@safe public final class ChildStdio: @unchecked Sendable {
  let mapping: Mapping
  var input: NativeRing
  var output: NativeRing
  let childBell: Handle
  let parentBell: Handle
  let channel: Handle
  /// Waits for this side's doorbell or the child's end.
  let port: Handle
  /// The child has gone (its end of the channel closed).
  public private(set) var gone = false

  static let bellKey: UInt64 = 1, goneKey: UInt64 = 2

  /// Makes the rings, doorbells and channel, and adds the child's parts
  /// to `startup` (CROI_PA_STDIO).
  public init(for startup: Startup) throws(Status) {
    let size = Int(TD_STDIO_SIZE), inAt = Int(TD_STDIO_IN), outAt = Int(TD_STDIO_OUT)
    let slotSize = Int(TD_STDIO_SLOT_SIZE), slots = Int(TD_STDIO_SLOTS)
    let vmo = try VMO.create(size: size)
    mapping = try VMO.map(vmo, length: size)
    let base = unsafe mapping.address
    guard unsafe NativeRing.create(base + inAt, size: outAt - inAt, slotSize: slotSize, count: slots,
                                   format: TD_STDIO_FORMAT, flags: RingLayout.byteStream),
      unsafe NativeRing.create(base + outAt, size: size - outAt, slotSize: slotSize, count: slots,
                               format: TD_STDIO_FORMAT, flags: RingLayout.byteStream),
      let input = unsafe NativeRing(attaching: base + inAt, size: outAt - inAt, producer: true, slotSize: slotSize,
                                    format: TD_STDIO_FORMAT, flags: RingLayout.byteStream),
      let output = unsafe NativeRing(attaching: base + outAt, size: size - outAt, producer: false,
                                     slotSize: slotSize, format: TD_STDIO_FORMAT, flags: RingLayout.byteStream)
    else { throw .internal }
    self.input = input
    self.output = output
    childBell = try Counter.create()
    parentBell = try Counter.create()
    let ends = try Channel.create()
    channel = ends.a
    port = try Port.create()
    var bindings = [Binding.changes(parentBell.raw, key: Self.bellKey),
                    Binding.signals(channel.raw, Signals.peerClosed, key: Self.goneKey)]
    guard try Port.bind(port, &bindings) == 2 else { throw .internal }
    func part(_ p: UInt32) -> UInt32 { HandleType.info(CROI_PA_STDIO, p) }
    startup.add(vmo, info: part(TD_STDIO_VMO))
    startup.add(try childBell.duplicate(), info: part(TD_STDIO_CHILD_BELL))
    startup.add(try parentBell.duplicate(), info: part(TD_STDIO_PARENT_BELL))
    startup.add(ends.b, info: part(TD_STDIO_CHANNEL))
  }

  /// Sleeps for `ring` as it says to, until `deadline`.
  func sleep(_ ring: inout NativeRing, deadline: Int64) throws(Status) {
    defer { ring.endSleep() }
    guard !gone, ring.prepareSleep() else { return }
    let packet = try Port.wait(port, deadline: deadline)
    if packet.key == Self.goneKey { gone = true }
  }

  func ringChild(_ wake: Bool) { if wake { try? Counter.add(childBell, 1) } }

  /// Writes all of `bytes` to the child's stdin, waiting while it is full;
  /// `peerClosed` if the child has gone.
  public func write(_ bytes: [UInt8], deadline: Int64 = infiniteDeadline) throws(Status) {
    var done = 0
    while done < bytes.count {
      guard !gone else { throw .peerClosed }
      let (written, wake) = unsafe bytes.withUnsafeBytes {
        unsafe input.write(bytes: $0.baseAddress! + done, count: bytes.count - done)
      }
      ringChild(wake)
      done += written
      if written == 0 { try sleep(&input, deadline: deadline) }
    }
  }

  /// The end of the child's stdin.
  public func closeInput(deadline: Int64 = infiniteDeadline) throws(Status) {
    while true {
      guard !gone else { throw .peerClosed }
      let (done, wake) = input.writeEnd()
      ringChild(wake)
      if done { return }
      try sleep(&input, deadline: deadline)
    }
  }

  /// The child's next stdout, up to `max` bytes, waiting until some come
  /// (`timedOut` at `deadline`): empty at its end, or once the child has
  /// gone and what it wrote has been read.
  public func read(max: Int = 4096, deadline: Int64 = infiniteDeadline) throws(Status) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: max)
    while true {
      let (got, ended, wake) = unsafe buffer.withUnsafeMutableBytes { unsafe output.read(bytes: $0.baseAddress!, max: max) }
      ringChild(wake)
      if got > 0 || ended || output.broken { return Array(buffer[..<got]) }
      if gone { return [] }
      try sleep(&output, deadline: deadline)
    }
  }

  /// Everything the child writes to stdout, until its end.
  public func readAll(deadline: Int64 = infiniteDeadline) throws(Status) -> [UInt8] {
    var out: [UInt8] = []
    while true {
      let chunk = try read(deadline: deadline)
      if chunk.isEmpty { return out }
      out += chunk
    }
  }
}
