// SPDX-License-Identifier: BSD-3-Clause

// The Venus client driver's core (M5e): a Venus context over a transport,
// the objects behind Vulkan handles, and the commands that run through it.
// The transport is vtest's socket hosted (VenusVtest), and croi's GPU class
// natively (M5g). docs/research/venus-protocol.md is the protocol.

import TDVenus
import Venus

/// The transport is gone, or the renderer stopped decoding: the device is lost.
public struct VenusLost: Error {
  public init() {}
}

/// What the driver needs from below: virtio-gpu's 3D context, as vtest
/// gives it (venus-protocol.md §1).
public protocol VenusTransport: AnyObject {
  /// The Venus capset (§1.5, GET_CAPSET).
  var capset: [UInt8] { get }
  /// One lock for the driver's state and the transport's requests.
  func lock()
  func unlock()
  /// Shared memory for reply streams and rings, mapped (blob id 0).
  func createSharedMemory(size: Int) throws(VenusLost) -> (resource: UInt32, address: UnsafeMutableRawPointer)
  /// A blob for device memory `id` (§13.2), mapped if `flags` has MAPPABLE.
  func createBlob(id: UInt64, size: Int, flags: UInt32) throws(VenusLost)
    -> (resource: UInt32, address: UnsafeMutableRawPointer?)
  /// Unmaps and drops a resource.
  func release(resource: UInt32, address: UnsafeMutableRawPointer?, size: Int)
  func createSync(_ initial: UInt64) throws(VenusLost) -> UInt32
  func destroySync(_ id: UInt32)
  func readSync(_ id: UInt32) throws(VenusLost) -> UInt64
  func writeSync(_ id: UInt32, _ value: UInt64) throws(VenusLost)
  /// A command stream for the context's decoder; once it has run (timeline
  /// 0) or the GPU work on `timeline`'s queue before it has, each sync is
  /// set to its value.
  func submit(_ stream: [UInt8], timeline: UInt32, syncs: [(id: UInt32, value: UInt64)]) throws(VenusLost)
  /// Until the syncs reach their values (any or all), or the timeout;
  /// false on the timeout.
  func wait(_ syncs: [(id: UInt32, value: UInt64)], any: Bool, timeoutNanoseconds: UInt64) throws(VenusLost) -> Bool
  /// Sleeps a little (polling the ring).
  func pause(nanoseconds: UInt64)
  /// A handle to a mappable blob's memory, a VMO, for another process
  /// (VK_FUCHSIA_external_memory, natively); nil where there is none (vtest).
  func exportVMO(resource: UInt32) -> UInt32?
  /// Whether `exportVMO` can give anything.
  var canExportVMOs: Bool { get }
}

/// The blob flags (§1.5).
public enum VenusBlob {
  public static let mappable: UInt32 = 1
  public static let shareable: UInt32 = 2
  public static let crossDevice: UInt32 = 4
}

/// One Venus context: object ids, the reply stream, and the CPU timeline.
@safe public final class VenusContext {
  public let transport: any VenusTransport
  /// The renderer's vk.xml version (capset), which bounds what we report.
  public let rendererVersion: UInt32
  /// Whether the renderer runs blocking fence waits itself (capset's
  /// allow_vk_wait_syncs, §14.4): fences are then waited on there, and
  /// answered through the ring, not through the transport's syncs, which
  /// virtio-gpu signals only when QEMU next polls (every 10 ms).
  public let rendererWaits: Bool
  /// Whether its blobs' memory can be handed out as VMOs.
  public let canExportVMOs: Bool
  var nextObjectID: UInt64 = 1
  /// The reply stream's shared memory.
  var replyResource: UInt32
  var replyAddress: UnsafeMutableRawPointer
  var replySize: Int
  let cpuSync: UInt32
  var cpuValue: UInt64 = 0
  /// Queue timelines handed out (1-63; 0 is the CPU's).
  var nextTimeline: UInt32 = 1
  public private(set) var lost = false
  /// The ring commands go through (§10), unless the context was made
  /// without one (`direct`): then each is a transport submission.
  let ring: VenusRing?
  /// How long a call waits for its reply.
  static let callTimeout: UInt64 = 60_000_000_000

  public init(_ transport: any VenusTransport, direct: Bool = false) throws(VenusLost) {
    self.transport = transport
    let c = transport.capset
    func u32(_ at: Int) -> UInt32 {
      guard at + 4 <= c.count else { return 0 }
      return UInt32(c[at]) | UInt32(c[at + 1]) << 8 | UInt32(c[at + 2]) << 16 | UInt32(c[at + 3]) << 24
    }
    // §1.5: wire format 1, and a renderer of at least Vulkan 1.1.
    guard u32(0) == 1, u32(4) >= (1 << 22 | 1 << 12) else { throw VenusLost() }
    rendererVersion = u32(4)
    rendererWaits = u32(148) != 0
    canExportVMOs = transport.canExportVMOs
    let r = try unsafe transport.createSharedMemory(size: 1 << 20)
    replyResource = unsafe r.resource
    unsafe replyAddress = r.address
    replySize = 1 << 20
    cpuSync = try transport.createSync(0)
    ring = direct ? nil : try VenusRing(transport)
  }

  deinit {
    ring?.destroy(cpuSync: cpuSync, value: cpuValue + 1)
    unsafe transport.release(resource: replyResource, address: replyAddress, size: replySize)
    transport.destroySync(cpuSync)
  }

  /// A fresh object id (§9: one namespace, never reused). Under the lock.
  func newID() -> UInt64 {
    defer { nextObjectID += 1 }
    return nextObjectID
  }

  /// A queue timeline. Under the lock.
  func newTimeline() -> UInt32? {
    guard nextTimeline < 64 else { return nil }
    defer { nextTimeline += 1 }
    return nextTimeline
  }

  /// Runs `body` under the transport's lock.
  public func locked<R>(_ body: () throws(VenusLost) -> R) throws(VenusLost) -> R {
    transport.lock()
    defer { transport.unlock() }
    return try body()
  }

  /// A command with a reply: the reply stream set to fit it (`size`
  /// bytes), the command, then the CPU timeline waited on and the reply
  /// decoded. Under the lock.
  func call<R>(_ size: Int, _ encode: (inout VenusEncoder) -> Void,
               _ decode: (inout VenusDecoder) throws(VenusError) -> R) throws(VenusLost) -> R
  {
    guard !lost else { throw VenusLost() }
    if size > replySize {
      var bigger = replySize
      while bigger < size { bigger *= 2 }
      let r = try unsafe transport.createSharedMemory(size: bigger)
      unsafe transport.release(resource: replyResource, address: replyAddress, size: replySize)
      replyResource = unsafe r.resource
      unsafe replyAddress = r.address
      replySize = bigger
    }
    var e = VenusEncoder()
    var stream = VkCommandStreamDescriptionMESA(resourceId: replyResource, offset: 0, size: size)
    unsafe Venus.vkSetReplyCommandStreamMESA(&e, reply: false, &stream)
    encode(&e)
    if let ring {
      do throws(VenusLost) {
        guard ring.wait(try ring.write(e.bytes)) else { throw VenusLost() }
      } catch {
        lost = true
        throw error
      }
    } else {
      try direct(e.bytes)
    }
    var d = unsafe VenusDecoder(UnsafeRawBufferPointer(start: replyAddress, count: size))
    do throws(VenusError) {
      return try decode(&d)
    } catch {
      lost = true  // a reply we can't read: we and the renderer disagree
      throw VenusLost()
    }
  }

  /// A stream run directly, and waited for on the CPU timeline.
  func direct(_ stream: [UInt8]) throws(VenusLost) {
    cpuValue += 1
    do throws(VenusLost) {
      try transport.submit(stream, timeline: 0, syncs: [(cpuSync, cpuValue)])
      guard try transport.wait([(cpuSync, cpuValue)], any: false, timeoutNanoseconds: Self.callTimeout) else {
        throw VenusLost()
      }
    } catch {
      lost = true
      throw error
    }
  }

  /// Commands without replies, in order with everything else. Under the lock.
  func send(_ encode: (inout VenusEncoder) -> Void) throws(VenusLost) {
    guard !lost else { throw VenusLost() }
    var e = VenusEncoder()
    encode(&e)
    try send(e.bytes)
  }

  /// A stream, and when `syncs` are given, a batch on `timeline` that
  /// sets them once it has run: through the ring, the batch first waits
  /// for the ring to reach the stream (§12.6, §14.3).
  func send(_ stream: [UInt8], timeline: UInt32 = 0, syncs: [(id: UInt32, value: UInt64)] = []) throws(VenusLost) {
    guard !lost else { throw VenusLost() }
    do throws(VenusLost) {
      guard let ring else { return try transport.submit(stream, timeline: timeline, syncs: syncs) }
      let seqno = try ring.write(stream)
      guard !syncs.isEmpty else { return }
      var e = VenusEncoder()
      Venus.vkWaitRingSeqnoMESA(&e, reply: false, VenusRing.id, UInt64(seqno))
      try transport.submit(e.bytes, timeline: timeline, syncs: syncs)
    } catch {
      lost = true
      throw error
    }
  }

  /// Until everything sent before has run. Under the lock.
  func flush() throws(VenusLost) {
    if let ring {
      guard ring.wait(ring.tail) else {
        lost = true
        throw VenusLost()
      }
      return
    }
    try direct([])
  }
}
