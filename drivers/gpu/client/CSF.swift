// SPDX-License-Identifier: BSD-3-Clause

// The GPU class's `csf` capset, client side (D173 section 7): a context on a
// command-stream GPU's driver host (mali(3)), with VMs, buffers mapped
// into this process, binds, groups and syncs as counters of ours. A
// user-side driver is built on it. It knows nothing of a stream's
// contents: it takes the bytes the client wrote into a buffer, and the
// address they are bound at.

import GPUDevice
import IPC
import Node
import Sys

public enum CSFClientError: Error, Equatable {
  /// No GPU in /dev offers the capset.
  case noDevice
  /// The driver's answer: `GPUCSFIPC.GPUError`'s code, or 0 for the
  /// channel's failure.
  case failed(Int32)
  /// The context's group ended: it runs nothing more (`groupState` says
  /// why); make another context.
  case lost

  static func of(_ e: IPCError<GPUCSFIPC.GPUError>) -> CSFClientError {
    if case .remote(let r) = e { return r == .lost ? .lost : .failed(r.rawValue) }
    return .failed(0)
  }
}

/// A buffer of the context: pinned write-combining memory mapped here.
public final class CSFBuffer: @unchecked Sendable {
  public let id: UInt32
  public let size: Int
  /// The buffer's mapping in this process (write-combining), whose `address` a user-side driver gives its clients.
  public let mapping: Mapping
  let vmo: Handle
  /// Whether this process maps it cached (made with `cpuCached`): then `cleanInvalidate` is the CPU's to call around the
  /// GPU's work, which doesn't see the CPU's caches.
  public let cpuCached: Bool
  init(id: UInt32, size: Int, mapping: consuming Mapping, vmo: consuming Handle, cpuCached: Bool = false) {
    self.id = id
    self.size = size
    self.mapping = mapping
    self.vmo = vmo
    self.cpuCached = cpuCached
  }

  /// A new handle to the buffer's VMO for another process to be given (a display's driver, which pins it and reads it as
  /// it is): it may be transferred, read, mapped and measured, not written. bti_pin asks MAP of the VMO it pins, as
  /// Zircon's does, so a handle without it can't be pinned.
  public func exportVMO() -> Handle? { try? vmo.duplicate([.transfer, .read, .map, .getProperty]) }

  /// A new handle to the buffer's VMO for another process to map and import (`CSFContext.importBuffer`): it may be transferred,
  /// duplicated, read, written, mapped and measured.
  public func exportMappableVMO() -> Handle? { try? vmo.duplicate([.transfer, .duplicate, .read, .write, .map, .getProperty]) }

  /// Writes the cached lines of the whole buffer back and drops them: after the GPU has written it and before the CPU
  /// reads it, and after the CPU has written memory the GPU will write. A write-combining buffer has none.
  public func cleanInvalidate() {
    guard cpuCached else { return }
    try? VMO.cacheCleanInvalidate(vmo, offset: 0, length: size)
  }

  public func store<T: FixedWidthInteger>(_ value: T, at offset: Int) { mapping.store(value, at: offset) }
  public func load<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T { mapping.load(T.self, at: offset) }
  /// The 64-bit words of a stream written from the start, in order.
  public func write(words: [UInt64], at offset: Int) {
    for (i, w) in words.enumerated() { mapping.store(w, at: offset + i * 8) }
  }
}

public final class CSFContext: @unchecked Sendable {
  var client: GPUCSFIPC.ContextClient
  /// Guards each call on the channel.
  let io = Lock()
  public let info: GPUCSFIPC.Info
  /// The thread limits, or nil from a driver that predates them (protocol version 1).
  public let limits: GPUCSFIPC.Limits?
  /// TEXTURE_FEATURES[0], or nil from a driver that predates it (protocol version 4).
  public let textureFeatures: UInt32?
  /// The GPU's name in /dev.
  public let device: String
  var syncs: [(id: UInt32, counter: UInt32)] = []

  /// A context on the first GPU in /dev that offers `csf`. `GPUContext.namespace`
  /// says where /dev is.
  public init() throws(CSFClientError) {
    guard let ns = GPUContext.namespace else { throw .noDevice }
    let names = ((try? ns.list("/dev")) ?? []).map { $0.name }.filter {
      $0.utf8.starts(with: "display".utf8) || $0.utf8.starts(with: "gpu".utf8)
    }
    for name in names {
      guard let channel = try? ns.connect("/dev/\(name)/gpu") else { continue }
      var device = GPUDeviceIPC.DeviceClient(channel: channel)
      guard let sets = try? device.capsets(), sets.contains(GPUCapset.csf),
        let context = try? device.open(capset: GPUCapset.csf)
      else { continue }
      client = GPUCSFIPC.ContextClient(channel: context)
      guard let info = try? client.info() else { throw .failed(0) }
      self.info = info
      self.limits = try? client.limits()
      self.textureFeatures = try? client.textureFeatures()
      self.device = name
      return
    }
    throw .noDevice
  }

  deinit {
    for s in syncs { close(raw: s.counter) }
  }

  /// Whether some GPU in /dev offers `csf`, without opening a context.
  public static func isOffered() -> Bool {
    guard let ns = GPUContext.namespace else { return false }
    for e in (try? ns.list("/dev")) ?? [] {
      guard e.name.utf8.starts(with: "display".utf8) || e.name.utf8.starts(with: "gpu".utf8),
        let channel = try? ns.connect("/dev/\(e.name)/gpu")
      else { continue }
      var device = GPUDeviceIPC.DeviceClient(channel: channel)
      if let sets = try? device.capsets(), sets.contains(GPUCapset.csf) { return true }
    }
    return false
  }

  // MARK: VMs and buffers

  /// A VM: its handle, and where the client's addresses end.
  public func createVM(userRange: UInt64 = 0) throws(CSFClientError) -> (id: UInt32, userRange: UInt64) {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) {
        let vm = try client.createVM(userRange: userRange)
        return (vm.id, vm.userRange)
      } catch { throw CSFClientError.of(error) }
    }
  }

  public func destroyVM(_ vm: UInt32) throws(CSFClientError) {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) { try client.destroyVM(vm: vm) } catch { throw CSFClientError.of(error) }
    }
  }

  /// A buffer of at least `size` bytes, mapped here (written by the CPU
  /// through write-combining memory, and so not cached; with `cpuCached`, cached, for the results the CPU reads, and
  /// then `CSFBuffer.cleanInvalidate` is the CPU's to call around the GPU's work).
  public func createBuffer(size: Int, cpuCached: Bool = false) throws(CSFClientError) -> CSFBuffer {
    try io.withLock { () throws(CSFClientError) in
      let made: GPUCSFIPC.Buffer
      do throws(IPCError<GPUCSFIPC.GPUError>) { made = try client.createBuffer(size: UInt64(size), flags: cpuCached ? 1 : 0) } catch {
        throw CSFClientError.of(error)
      }
      let length = Int(made.size)
      let id = made.id
      let vmo = made.takeVMO()
      guard let mapping = try? VMO.map(vmo, length: length, writable: true) else {
        try? client.destroyBuffer(id: id)
        throw CSFClientError.failed(0)
      }
      let buffer = CSFBuffer(id: id, size: length, mapping: mapping, vmo: vmo, cpuCached: cpuCached)
      // The zeroing's lines are dirty in this CPU's cache: written back and dropped before the GPU stores to the memory.
      buffer.cleanInvalidate()
      return buffer
    }
  }

  /// A buffer over the pages of `vmo` (another process's, a duplicate of whose handle the caller gives): `size` bytes of it
  /// from its start, pinned for the GPU by the driver and mapped here as the VMO's own cache policy has it.
  public func importBuffer(vmo: consuming Handle, size: Int) throws(CSFClientError) -> CSFBuffer {
    var keep: Handle?
    do { keep = try vmo.duplicate() } catch { throw CSFClientError.failed(0) }
    var give: Handle? = vmo
    return try io.withLock { () throws(CSFClientError) in
      let length = (size + 4095) & ~4095
      let id: UInt32
      guard let sent = give.take(), let mine = keep.take() else { throw CSFClientError.failed(0) }
      do throws(IPCError<GPUCSFIPC.GPUError>) { id = try client.importBuffer(vmo: sent, size: UInt64(length)) } catch {
        throw CSFClientError.of(error)
      }
      guard let mapping = try? VMO.map(mine, length: length, writable: true) else {
        try? client.destroyBuffer(id: id)
        throw CSFClientError.failed(0)
      }
      return CSFBuffer(id: id, size: length, mapping: mapping, vmo: mine, cpuCached: false)
    }
  }

  public func destroyBuffer(_ buffer: CSFBuffer) throws(CSFClientError) {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) { try client.destroyBuffer(id: buffer.id) } catch {
        throw CSFClientError.of(error)
      }
    }
  }

  /// Map `size` bytes of `buffer` from `offset` at `address` of the VM. `flags`: 1 read-only
  /// for the GPU, 2 not executable, 4 uncached, 8 cacheable in the GPU's caches (for shader atomics and the occlusion counter).
  public func bind(vm: UInt32, buffer: CSFBuffer, offset: UInt64 = 0, size: UInt64, address: UInt64, flags: UInt32 = 0)
    throws(CSFClientError)
  {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) {
        try client.bind(vm: vm, buffer: buffer.id, offset: offset, size: size, address: address, flags: flags)
      } catch { throw CSFClientError.of(error) }
    }
  }

  /// Back the range with the client's dummy (the bind's sparse flag, 16): 2 MiB of the driver's that every such range of the
  /// client repeats, which reads what was last written through any of them.
  public func bindDummy(vm: UInt32, size: UInt64, address: UInt64, flags: UInt32 = 0) throws(CSFClientError) {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) {
        try client.bind(vm: vm, buffer: 0, offset: 0, size: size, address: address, flags: flags | 16)
      } catch { throw CSFClientError.of(error) }
    }
  }

  public func unbind(vm: UInt32, address: UInt64, size: UInt64) throws(CSFClientError) {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) { try client.unbind(vm: vm, address: address, size: size) } catch {
        throw CSFClientError.of(error)
      }
    }
  }

  // MARK: Tiler heaps

  /// A tiler heap in `vm` (protocol version 3; an older driver answers with a failure): `initialChunks` chunks of
  /// `chunkSize` bytes (a multiple of 4 KiB, 128 KiB to 8 MiB), at most `maxChunks`, and `targetInFlight` render passes
  /// in flight before the driver stops growing it. The handle, the GPU address of the heap context and of the first
  /// chunk, which a stream passes to the tiler.
  public func createHeap(vm: UInt32, initialChunks: UInt32, chunkSize: UInt32, maxChunks: UInt32, targetInFlight: UInt32)
    throws(CSFClientError) -> (handle: UInt32, contextAddress: UInt64, firstChunk: UInt64)
  {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) {
        let h = try client.createHeap(vm: vm, initialChunks: initialChunks, chunkSize: chunkSize, maxChunks: maxChunks,
                                      targetInFlight: targetInFlight)
        return (h.handle, h.contextAddress, h.firstChunk)
      } catch { throw CSFClientError.of(error) }
    }
  }

  /// The heap's memory goes at once: nothing that uses it may be queued or running.
  public func destroyHeap(_ handle: UInt32) throws(CSFClientError) {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) { try client.destroyHeap(handle: handle) } catch {
        throw CSFClientError.of(error)
      }
    }
  }

  // MARK: Groups

  /// A group over `vm` with a queue for each ring size (a power of two, 4
  /// KiB to 64 KiB).
  public func createGroup(vm: UInt32, ringSizes: [UInt32], priority: UInt32 = 1) throws(CSFClientError) -> UInt32 {
    try io.withLock { () throws(CSFClientError) in
      let queues = ringSizes.map { GPUCSFIPC.QueueConfig(ringSize: $0, priority: 0) }
      do throws(IPCError<GPUCSFIPC.GPUError>) { return try client.createGroup(vm: vm, queues: queues, priority: priority) }
      catch { throw CSFClientError.of(error) }
    }
  }

  public func destroyGroup(_ group: UInt32) throws(CSFClientError) {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) { try client.destroyGroup(group: group) } catch {
        throw CSFClientError.of(error)
      }
    }
  }

  /// A group's state: bit 0 timed out, bit 1 a fatal fault (`fatalQueues`),
  /// bit 2 innocent of a reset.
  public func groupState(_ group: UInt32) throws(CSFClientError) -> (state: UInt32, fatalQueues: UInt32, resident: Bool) {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) {
        let s = try client.groupState(group: group)
        return (s.state, s.fatalQueues, s.resident)
      } catch { throw CSFClientError.of(error) }
    }
  }

  // MARK: Syncs and submissions

  /// A sync: a counter of ours at 0, which the driver raises.
  public func createSync() throws(CSFClientError) -> UInt32 {
    try io.withLock { () throws(CSFClientError) -> UInt32 in
      guard let counter = try? Counter.create(), let theirs = try? counter.duplicate() else { throw .failed(0) }
      let id: UInt32
      do throws(IPCError<GPUCSFIPC.GPUError>) { id = try client.addSync(counter: theirs) } catch {
        throw CSFClientError.of(error)
      }
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

  /// A new handle to a sync's counter that reads and waits, never adds: for another process to see the sync reach a value
  /// (a window's acquire counter). The caller owns it.
  public func syncHandle(_ id: UInt32) -> UInt32? {
    guard let raw = counter(id) else { return nil }
    let c = Handle(raw: raw)  // borrowed
    let d = try? c.duplicate([.basic, .read])
    _ = c.release()
    guard let d else { return nil }
    return d.release()
  }

  public func readSync(_ id: UInt32) -> UInt64? {
    guard let raw = counter(id) else { return nil }
    let c = Handle(raw: raw)  // borrowed
    let value = try? Counter.read(c)
    _ = c.release()
    return value.map { UInt64($0) }
  }

  /// Add to a sync's counter ourselves, as a wait of a job's would see it.
  public func raiseSync(_ id: UInt32, to value: UInt64) {
    guard let raw = counter(id) else { return }
    let c = Handle(raw: raw)
    if let now = try? Counter.read(c), UInt64(now) < value { try? Counter.add(c, Int64(value) - now) }
    _ = c.release()
  }

  /// Until the sync reaches `value`, or the timeout; false on the timeout.
  public func wait(sync id: UInt32, value: UInt64, timeoutNanoseconds: UInt64) -> Bool {
    guard let raw = counter(id) else { return false }
    let deadline = timeoutNanoseconds >= UInt64(Int64.max) - UInt64(Clock.monotonic()) ? infiniteDeadline
      : Clock.monotonic() + Int64(timeoutNanoseconds)
    let c = Handle(raw: raw)
    let r = Result { () throws(Status) in try Counter.wait(c, until: Int64(value), deadline: deadline) }
    _ = c.release()
    if case .failure = r { return false }
    return true
  }

  /// The jobs, once each wait has reached its value; each signal is raised when the last is done, well
  /// or not. `lost` if a group of this context ended.
  /// `submit` with no answer (`post`, protocol version 5): it returns once the request is sent; a submission the driver
  /// refuses raises its signals and sets bit 3 of its group's state.
  public func post(group: UInt32, jobs: [GPUCSFIPC.Job], waits: [(id: UInt32, value: UInt64)] = [],
                   signals: [(id: UInt32, value: UInt64)] = []) throws(CSFClientError) {
    try io.withLock { () throws(CSFClientError) in
      let w = waits.map { GPUCSFIPC.SyncValue(id: $0.id, value: $0.value) }
      let s = signals.map { GPUCSFIPC.SyncValue(id: $0.id, value: $0.value) }
      do { try client.post(group: group, jobs: jobs, waits: w, signals: s) } catch { throw CSFClientError.failed(0) }
    }
  }

  public func submit(group: UInt32, jobs: [GPUCSFIPC.Job], waits: [(id: UInt32, value: UInt64)] = [],
                     signals: [(id: UInt32, value: UInt64)] = []) throws(CSFClientError) {
    try io.withLock { () throws(CSFClientError) in
      let w = waits.map { GPUCSFIPC.SyncValue(id: $0.id, value: $0.value) }
      let s = signals.map { GPUCSFIPC.SyncValue(id: $0.id, value: $0.value) }
      do throws(IPCError<GPUCSFIPC.GPUError>) { try client.submit(group: group, jobs: jobs, waits: w, signals: s) }
      catch { throw CSFClientError.of(error) }
    }
  }
}
