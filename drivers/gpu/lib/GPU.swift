// SPDX-License-Identifier: BSD-3-Clause

// The GPU class's protocol (M5g, architecture §10, Magma-shaped): a GPU's
// driver host serves `Device`, and a client opens a `Context` on one of its
// capability sets (Venus's, natively: the client driver's transport, the
// VenusGPU module). A context makes blobs (memory the host's renderer makes
// for the context's objects, or shared memory for command and reply
// streams), maps the mappable ones as VMOs over the device's host-visible
// memory, and runs command streams; a stream's syncs are the client's own
// counters, which the driver raises to their values once the work before
// them is done (timeline 0: the renderer has run the stream; another: the
// GPU has finished what was queued on that timeline's queue).

import IPC
import Node

@IPCLibrary(id: "todhchai.gpu.device", version: 1)
public enum GPUDeviceIPC {
  public enum GPUError: Int32, IPCErrorCode, Sendable {
    case invalid = 1
    case notFound
    case unavailable
    case noMemory
    /// The device or the renderer failed: the context is lost.
    case lost
  }

  /// A sync to raise when a submission is done.
  public struct SyncValue: Equatable, Sendable {
    public var id: UInt32
    public var value: UInt64
    public init(id: UInt32, value: UInt64) {
      self.id = id
      self.value = value
    }
  }

  public protocol Device {
    /// The capability sets the device has (Venus is 4).
    func capsets() -> [UInt32]
    /// A context on capset `capset`: its channel, which speaks Context.
    func open(capset: UInt32) throws(GPUError) -> Handle
  }

  public protocol Context {
    /// The capset's bytes.
    func capset() -> [UInt8]
    /// A blob the renderer makes for the context's object `id` (0: shared
    /// memory), `flags` as virtio-gpu's (1 mappable); its resource id.
    func createBlob(id: UInt64, size: UInt64, flags: UInt32) throws(GPUError) -> UInt32
    /// A mappable blob as a VMO over the device's memory, its cache policy
    /// set as the host asks.
    func map(resource: UInt32) throws(GPUError) -> Handle
    func release(resource: UInt32)
    /// A counter of the client's to raise for submissions; its id.
    func addSync(counter: consuming Handle) throws(GPUError) -> UInt32
    func removeSync(id: UInt32)
    /// A command stream for the context's renderer; when the work before
    /// it on `timeline` is done, each sync is raised to its value.
    func submit(timeline: UInt32, stream: [UInt8], syncs: [SyncValue]) throws(GPUError)
  }
}
