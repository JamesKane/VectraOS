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
  let mapping: Mapping
  let vmo: Handle
  init(id: UInt32, size: Int, mapping: consuming Mapping, vmo: consuming Handle) {
    self.id = id
    self.size = size
    self.mapping = mapping
    self.vmo = vmo
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
  /// through write-combining memory, and so not cached).
  public func createBuffer(size: Int) throws(CSFClientError) -> CSFBuffer {
    try io.withLock { () throws(CSFClientError) in
      let made: GPUCSFIPC.Buffer
      do throws(IPCError<GPUCSFIPC.GPUError>) { made = try client.createBuffer(size: UInt64(size), flags: 0) } catch {
        throw CSFClientError.of(error)
      }
      let length = Int(made.size)
      guard let mapping = try? VMO.map(made.vmo, length: length, writable: true) else {
        try? client.destroyBuffer(id: made.id)
        throw CSFClientError.failed(0)
      }
      return CSFBuffer(id: made.id, size: length, mapping: mapping, vmo: made.vmo)
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
  /// for the GPU, 2 not executable, 4 uncached.
  public func bind(vm: UInt32, buffer: CSFBuffer, offset: UInt64 = 0, size: UInt64, address: UInt64, flags: UInt32 = 0)
    throws(CSFClientError)
  {
    try io.withLock { () throws(CSFClientError) in
      do throws(IPCError<GPUCSFIPC.GPUError>) {
        try client.bind(vm: vm, buffer: buffer.id, offset: offset, size: size, address: address, flags: flags)
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
