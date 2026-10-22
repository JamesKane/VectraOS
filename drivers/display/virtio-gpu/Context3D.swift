// SPDX-License-Identifier: BSD-3-Clause

// virtio-gpu's 3D side in its driver host (D121, after todhchai's): the GPU class
// (`GPUDeviceIPC`) over contexts on the device's capsets. A context's blobs
// are made by the host's renderer; a mappable one is mapped at a window of
// the host-visible region (its own first-fit allocator): a physical VMO
// over that window of the BAR, cached as the host says, of which the
// client gets a slice (croi K13a). A window is reused once its blob is
// released and the parent says it has no children: no slice is left, nor
// any mapping of one (croi can't revoke a VMO, so the client decides).
// Without slices (an older croi), the client gets the window's VMO itself,
// and the window waits for its context to close. Fences go as empty SUBMIT_3D requests
// on the stream's timeline; the device answers them once the work before
// is done, and their syncs (the client's counters) are raised then.

import GPUDevice
import IPC
import Sys
import Virtio
import VirtioGPU

/// A context: its blobs and the client's sync counters.
final class ContextState {
  let id: UInt32
  let capset: UInt32
  var blobs: [(resource: UInt32, size: UInt64, window: (offset: UInt64, size: UInt64)?, watch: UInt64?)] = []
  var quarantine: [(offset: UInt64, size: UInt64)] = []
  var syncs: [(id: UInt32, counter: UInt32)] = []
  var nextSync: UInt32 = 1
  init(id: UInt32, capset: UInt32) {
    self.id = id
    self.capset = capset
  }
  deinit { for s in syncs { close(raw: s.counter) } }
}

/// A fence in flight: what it raises when the device answers it.
struct FenceSlot {
  let context: ContextState
  let syncs: [GPUDeviceIPC.SyncValue]
}

/// A sliced window: freed when its blob is released and its slices are gone.
struct WatchedWindow {
  let key: UInt64
  let window: (offset: UInt64, size: UInt64)
  var released = false
  var unused = false
}

extension GPUDevice {
  /// The window's slices are gone, or its blob was released: free it once both.
  func windowUnused(_ key: UInt64) { settle(key) { $0.unused = true } }
  func windowReleased(_ key: UInt64) { settle(key) { $0.released = true } }

  func settle(_ key: UInt64, _ change: (inout WatchedWindow) -> Void) {
    guard let i = watched.firstIndex(where: { $0.key == key }) else { return }
    change(&watched[i])
    guard watched[i].released && watched[i].unused else { return }
    freeWindow(watched.remove(at: i).window)
  }

  /// The device's host-visible memory: a window of `size` bytes for a blob.
  func allocateWindow(_ size: UInt64) -> UInt64? {
    let need = (size + 4095) & ~4095
    guard let i = windows.firstIndex(where: { $0.size >= need }) else { return nil }
    let offset = windows[i].offset
    if windows[i].size == need { windows.remove(at: i) } else { windows[i] = (offset + need, windows[i].size - need) }
    return offset
  }

  func freeWindow(_ w: (offset: UInt64, size: UInt64)) {
    windows.append(w)
    windows.sort { $0.offset < $1.offset }
    var merged: [(offset: UInt64, size: UInt64)] = []
    for w in windows {
      if let last = merged.last, last.offset + last.size == w.offset {
        merged[merged.count - 1].size += w.size
      } else {
        merged.append(w)
      }
    }
    windows = merged
  }

  /// A fence on `timeline` of `context` raising `syncs` when it signals.
  func fence(_ context: ContextState, timeline: UInt32, syncs: [GPUDeviceIPC.SyncValue]) throws(GPUDeviceIPC.GPUError) {
    var free = lock.withLock { fences.firstIndex { $0 == nil } }
    while free == nil {  // all in flight: wait for one
      guard waitForInterrupt(deadline: Clock.monotonic() + 1_000_000_000) else { throw .lost }
      free = lock.withLock { fences.firstIndex { $0 == nil } }
    }
    guard let i = free else { throw .lost }
    let request = GPU.submit3D(context.id, stream: [], fence: nextFence, ring: UInt8(timeline))
    nextFence += 1
    let at = unsafe UnsafeMutableRawPointer(bitPattern: slab.address + UInt(i * Self.slotSize))!
    request.withUnsafeBytes { unsafe at.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    let bus = slab.bus + UInt64(i * Self.slotSize)
    // Its slot is taken before the device can answer it.
    lock.withLock { fences[i] = FenceSlot(context: context, syncs: syncs) }
    guard submit([Buffer(address: bus, length: UInt32(request.count), deviceWrites: false),
                  Buffer(address: bus + 64, length: UInt32(GPU.headerSize), deviceWrites: true)])
    else {
      lock.withLock { fences[i] = nil }
      throw .lost
    }
  }

  /// A fence's answer: its syncs raised (never lowered). Under the lock.
  func completeFence(_ i: Int) {
    guard i >= 0, i < fences.count, let slot = fences[i] else { return }
    fences[i] = nil
    let response = unsafe UnsafeRawPointer(bitPattern: slab.address + UInt(i * Self.slotSize + 64))!
    let type = unsafe response.load(as: UInt32.self)
    if type >= GPU.Response.errorBase { failures += 1 }
    for s in slot.syncs {
      guard let c = slot.context.syncs.first(where: { $0.id == s.id }) else { continue }
      let counter = Handle(raw: c.counter)  // borrowed
      // (Counters only add, D25: raised by the difference.)
      if let now = try? Counter.read(counter), now < Int64(s.value) { try? Counter.add(counter, Int64(s.value) - now) }
      _ = counter.release()
    }
  }

  /// Opens a context on `capset`.
  func openContext(capset: UInt32) throws(GPUDeviceIPC.GPUError) -> ContextState {
    guard has3D, capsets.contains(where: { $0.id == capset }) else { throw .notFound }
    let context = ContextState(id: nextContext, capset: capset)
    nextContext += 1
    try command3D(GPU.contextCreate(context.id, capset: capset, name: Array("todhchai".utf8)))
    contexts += 1
    return context
  }

  /// Its blobs released, then it.
  func closeContext(_ c: ContextState) {
    for b in c.blobs { releaseBlob(c, b.resource) }
    for w in c.quarantine { freeWindow(w) }
    c.quarantine = []
    try? command3D(GPU.contextDestroy(c.id))
    contexts -= 1
  }

  func releaseBlob(_ c: ContextState, _ resource: UInt32) {
    guard let i = c.blobs.firstIndex(where: { $0.resource == resource }) else { return }
    let b = c.blobs.remove(at: i)
    if let w = b.window {
      try? command3D(GPU.unmapBlob(c.id, resource: resource))
      if let key = b.watch { windowReleased(key) } else { c.quarantine.append(w) }
    }
    try? command3D(GPU.contextDetach(c.id, resource: resource))
    try? command3D(GPU.unref(id: resource))
  }

  func command3D(_ bytes: [UInt8]) throws(GPUDeviceIPC.GPUError) {
    guard let r = try? send(bytes, response: GPU.headerSize), GPU.responseType(r) == GPU.Response.okNoData else {
      failures += 1
      throw .unavailable
    }
  }
}

/// The class's Device: the capsets, and contexts on them.
struct GPUDeviceSession: GPUDeviceIPC.DeviceHandler {
  let gpu: GPUDevice

  func capsets() -> [UInt32] { gpu.capsets.map { $0.id } }

  func open(capset: UInt32) throws(GPUDeviceIPC.GPUError) -> Handle {
    guard let ends = try? Channel.create(), let dispatcher = gpu.dispatcher else { throw .noMemory }
    let context = try gpu.openContext(capset: capset)
    let theirs = ends.b.release()
    let session = ContextSession(gpu: gpu, context: context)
    guard (try? dispatcher.add(GPUDeviceIPC.ContextServer(channel: Handle(raw: theirs), impl: session))) != nil else {
      throw .noMemory
    }
    return ends.a
  }
}

/// One client's context; closing its channel closes the context.
final class ContextSession: GPUDeviceIPC.ContextHandler {
  let gpu: GPUDevice
  let context: ContextState

  init(gpu: GPUDevice, context: ContextState) {
    self.gpu = gpu
    self.context = context
  }

  deinit { gpu.closeContext(context) }

  func capset() -> [UInt8] { gpu.capsets.first { $0.id == context.capset }?.bytes ?? [] }

  func createBlob(id: UInt64, size: UInt64, flags: UInt32) throws(GPUDeviceIPC.GPUError) -> UInt32 {
    guard size > 0, size <= 1 << 32 else { throw .invalid }
    let resource = gpu.nextID
    gpu.nextID += 1
    try gpu.command3D(GPU.createBlob(context.id, resource: resource, flags: flags, blobID: id, size: size))
    try? gpu.command3D(GPU.contextAttach(context.id, resource: resource))  // the host may have attached it already
    context.blobs.append((resource, size, nil, nil))
    gpu.blobs += 1
    return resource
  }

  func map(resource: UInt32) throws(GPUDeviceIPC.GPUError) -> Handle {
    guard let i = context.blobs.firstIndex(where: { $0.resource == resource }), context.blobs[i].window == nil,
      let region = gpu.region
    else { throw .invalid }
    // A window the size the blob was made, in pages.
    let size = (context.blobs[i].size + 4095) & ~4095
    guard let offset = gpu.allocateWindow(size) else { throw .noMemory }
    let window = (offset: offset, size: size)
    guard let r = try? gpu.send(GPU.mapBlob(context.id, resource: resource, offset: offset), response: GPU.mapInfoSize),
      let cache = GPU.mapInfo(r)
    else {
      gpu.freeWindow(window)
      gpu.failures += 1
      throw .unavailable
    }
    let bar = Handle(raw: gpu.barRaw)  // borrowed
    let made = try? VMO.physical(resource: bar, address: region.base + offset, size: Int(window.size))
    _ = bar.release()
    guard let vmo = made else { throw .noMemory }
    let policy: VMO.CachePolicy = cache == GPU.MapCache.cached ? .cached : cache == GPU.MapCache.writeCombined
      ? .writeCombining : .uncached
    try? VMO.setCachePolicy(vmo, policy)
    context.blobs[i].window = window
    // The client's slice, and the window watched until no slice is left.
    guard let slice = try? VMO.child(vmo, options: VMO.ChildOptions.slice, offset: 0, size: Int(window.size)),
      let dispatcher = gpu.dispatcher
    else { return vmo }
    let key = gpu.nextWatch
    gpu.nextWatch += 1
    gpu.watched.append(WatchedWindow(key: key, window: window))
    let device = gpu
    guard (try? dispatcher.watch(vmo, signals: VMO.zeroChildren, { _ in
      device.windowUnused(key)
      return false
    })) != nil else {
      gpu.watched.removeAll { $0.key == key }
      return slice
    }
    context.blobs[i].watch = key
    return slice
  }

  func release(resource: UInt32) {
    gpu.releaseBlob(context, resource)
  }

  // (A context's syncs are read by fences answered on the interrupt's
  // thread: under the device's lock.)
  func addSync(counter: consuming Handle) throws(GPUDeviceIPC.GPUError) -> UInt32 {
    let raw = counter.release()
    return gpu.lock.withLock {
      let id = context.nextSync
      context.nextSync += 1
      context.syncs.append((id, raw))
      return id
    }
  }

  func removeSync(id: UInt32) {
    let raw = gpu.lock.withLock { () -> UInt32? in
      guard let i = context.syncs.firstIndex(where: { $0.id == id }) else { return nil }
      return context.syncs.remove(at: i).counter
    }
    if let raw { close(raw: raw) }
  }

  func submit(timeline: UInt32, stream: [UInt8], syncs: [GPUDeviceIPC.SyncValue]) throws(GPUDeviceIPC.GPUError) {
    guard timeline < 64, stream.count % 4 == 0 else { throw .invalid }
    if !stream.isEmpty { try gpu.command3D(GPU.submit3D(context.id, stream: stream)) }
    if !syncs.isEmpty { try gpu.fence(context, timeline: timeline, syncs: syncs) }
    gpu.submits += 1
  }
}
