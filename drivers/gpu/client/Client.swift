// SPDX-License-Identifier: BSD-3-Clause

// The GPU class's client side (D121, after todhchai's): a context on a
// GPU's capset, over a display host's `gpu` service in /dev (devmgr mounts
// each at /dev/display<n>, D120), with its blobs mapped into this
// process and its syncs as counters of ours. It knows nothing of Vulkan: a
// driver's transport is built on it (the Venus client driver's, in the
// native driver registry, graphics/vulkan/drivers/native).

import GPUDevice
import IPC
import Node
import Sys

public enum GPUClientError: Error {
  case noDevice
  case failed
}

/// A blob's mapping in this process, until it is released.
final class BlobMapping {
  let resource: UInt32
  let mapping: Mapping
  /// Its VMO (the driver host's slice), to hand to other processes.
  let vmo: Handle
  init(resource: UInt32, mapping: consuming Mapping, vmo: consuming Handle) {
    self.resource = resource
    self.mapping = mapping
    self.vmo = vmo
  }
}

public final class GPUContext: @unchecked Sendable {
  /// Where a process's GPUs are: its namespace, set by the program before
  /// a driver connects (natively, the namespace from its Startup).
  public static var namespace: Namespace? {
    get { settings.namespace }
    set { settings.namespace = newValue }
  }
  final class Settings: @unchecked Sendable { var namespace: Namespace? }
  static let settings = Settings()

  var client: GPUDeviceIPC.ContextClient
  /// Guards each call on the channel.
  let io = Lock()
  /// The driver's lock for its own state (`lock`), apart from `io`: the
  /// driver calls us while holding it.
  let state = Lock()
  public let capset: [UInt8]
  public let device: String
  var mappings: [BlobMapping] = []
  var syncs: [(id: UInt32, counter: UInt32)] = []

  /// A context on capset `capset` of the first GPU in /dev that has it.
  public init(capset id: UInt32) throws(GPUClientError) {
    guard let ns = Self.namespace else { throw .noDevice }
    let names = ((try? ns.list("/dev")) ?? []).map { $0.name }.filter { $0.utf8.starts(with: "display".utf8) }
    for name in names {
      guard let channel = try? ns.connect("/dev/\(name)/gpu") else { continue }
      var device = GPUDeviceIPC.DeviceClient(channel: channel)
      guard let sets = try? device.capsets(), sets.contains(id), let context = try? device.open(capset: id) else {
        continue
      }
      client = GPUDeviceIPC.ContextClient(channel: context)
      guard let bytes = try? client.capset() else { throw .failed }
      capset = bytes
      self.device = name
      return
    }
    throw .noDevice
  }

  deinit {
    for s in syncs { close(raw: s.counter) }
  }

  public func lock() { state.lock() }
  public func unlock() { state.unlock() }

  /// A blob, mapped if `flags` says mappable (1): its resource and address.
  public func createBlob(id: UInt64, size: Int, flags: UInt32) throws(GPUClientError)
    -> (resource: UInt32, address: UnsafeMutableRawPointer?)
  {
    try unsafe io.withLock { () throws(GPUClientError) in
      guard let resource = try? client.createBlob(id: id, size: UInt64(size), flags: flags) else { throw .failed }
      guard flags & 1 != 0 else { return (resource, nil) }
      guard let vmo = try? client.map(resource: resource),
        let mapping = try? VMO.map(vmo, length: (size + 4095) & ~4095, writable: true)
      else {
        try? client.release(resource: resource)
        throw .failed
      }
      let address = unsafe mapping.address
      mappings.append(BlobMapping(resource: resource, mapping: mapping, vmo: vmo))
      return unsafe (resource, address)
    }
  }

  /// A new handle to a mapped blob's VMO, to give away; nil if it isn't one.
  public func duplicateVMO(resource: UInt32) -> UInt32? {
    io.withLock { () -> UInt32? in
      guard let m = mappings.first(where: { $0.resource == resource }), let d = try? m.vmo.duplicate() else { return nil }
      return d.release()
    }
  }

  /// Unmaps a blob and lets it go.
  public func release(resource: UInt32) {
    io.withLock {
      mappings.removeAll { $0.resource == resource }
      try? client.release(resource: resource)
    }
  }

  /// A sync: a counter of ours at `initial`, which the driver raises.
  public func createSync(_ initial: UInt64) throws(GPUClientError) -> UInt32 {
    try io.withLock { () throws(GPUClientError) -> UInt32 in
      // (Counters only add, D25: an initial value is added to 0.)
      guard let counter = try? Counter.create(), initial == 0 || (try? Counter.add(counter, Int64(initial))) != nil,
        let theirs = try? counter.duplicate(), let id = try? client.addSync(counter: theirs)
      else { throw .failed }
      syncs.append((id, counter.release()))
      return id
    }
  }

  public func destroySync(_ id: UInt32) {
    io.withLock {
      guard let i = syncs.firstIndex(where: { $0.id == id }) else { return }
      close(raw: syncs.remove(at: i).counter)
      try? client.removeSync(id: id)
    }
  }

  func counter(_ id: UInt32) -> UInt32? { io.withLock { syncs.first { $0.id == id }?.counter } }

  public func readSync(_ id: UInt32) throws(GPUClientError) -> UInt64 {
    guard let raw = counter(id) else { throw .failed }
    let c = Handle(raw: raw)  // borrowed
    let value = try? Counter.read(c)
    _ = c.release()
    guard let value else { throw .failed }
    return UInt64(value)
  }

  public func writeSync(_ id: UInt32, _ value: UInt64) throws(GPUClientError) {
    guard let raw = counter(id) else { throw .failed }
    let c = Handle(raw: raw)
    // A timeline only goes up: raised by the difference (counters only add).
    let now = (try? Counter.read(c)) ?? 0
    let ok = Int64(value) <= now || (try? Counter.add(c, Int64(value) - now)) != nil
    _ = c.release()
    guard ok else { throw .failed }
  }

  public func submit(_ stream: [UInt8], timeline: UInt32, syncs: [(id: UInt32, value: UInt64)]) throws(GPUClientError) {
    try io.withLock { () throws(GPUClientError) in
      let values = syncs.map { GPUDeviceIPC.SyncValue(id: $0.id, value: $0.value) }
      guard (try? client.submit(timeline: timeline, stream: stream, syncs: values)) != nil else { throw .failed }
    }
  }

  /// Until the syncs reach their values (each, or any), or the timeout;
  /// false on the timeout.
  public func wait(_ syncs: [(id: UInt32, value: UInt64)], any: Bool, timeoutNanoseconds: UInt64) throws(GPUClientError)
    -> Bool
  {
    let deadline = timeoutNanoseconds >= UInt64(Int64.max) - UInt64(Clock.monotonic()) ? infiniteDeadline
      : Clock.monotonic() + Int64(timeoutNanoseconds)
    func reached(_ s: (id: UInt32, value: UInt64)) throws(GPUClientError) -> Bool { try readSync(s.id) >= s.value }
    if !any {
      for s in syncs {
        guard let raw = counter(s.id) else { throw .failed }
        let c = Handle(raw: raw)
        let r = Result { () throws(Status) in try Counter.wait(c, until: Int64(s.value), deadline: deadline) }
        _ = c.release()
        if case .failure(let e) = r { if e == .timedOut { return false } else { throw .failed } }
      }
      return true
    }
    while true {
      for s in syncs where try reached(s) { return true }
      guard Clock.monotonic() < deadline else { return false }
      sleep(until: min(deadline, Clock.monotonic() + 100_000))
    }
  }

  public func pause(nanoseconds: UInt64) { sleep(until: Clock.monotonic() + Int64(nanoseconds)) }
}
