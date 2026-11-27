// SPDX-License-Identifier: BSD-3-Clause

// The `csf` capset's protocol side, in the driver host (D173 section 7):
// `GPUCSFIPC.Context` served from a `CSFService` (Service.swift), one
// context to a client. The host's Device makes one `CSFServer` over its
// backend, serves `server.deviceSession` as the class's Device (capset
// `GPUCapset.csf`), and calls `server.pump()` from the job interrupt's
// thread and at `server.nextWake`. Calls from the dispatcher's thread
// and the pump meet at the server's lock, which is the service's.

import GPUDevice
import IPC
import Node
import Sys

/// A client's counter by its raw handle value, as the service holds it
/// (the host's backend calls these from its `counterValue`, `raiseCounter`
/// and `closeCounter`).
enum CSFCounters {
  static func value(_ raw: UInt32) -> UInt64 {
    let counter = Handle(raw: raw)  // borrowed
    let now = (try? Counter.read(counter)) ?? 0
    _ = counter.release()
    return now < 0 ? 0 : UInt64(now)
  }

  /// Raised by the difference: counters only add (D25).
  static func raise(_ raw: UInt32, to value: UInt64) {
    let counter = Handle(raw: raw)  // borrowed
    if let now = try? Counter.read(counter), now >= 0, UInt64(now) < value {
      try? Counter.add(counter, Int64(value) - now)
    }
    _ = counter.release()
  }

  static func close(_ raw: UInt32) { Sys.close(raw: raw) }
}

func gpuError(_ e: CSFServiceError) -> GPUCSFIPC.GPUError {
  switch e {
  case .invalid: .invalid
  case .notFound: .notFound
  case .unavailable: .unavailable
  case .noMemory: .noMemory
  case .lost: .lost
  }
}

public final class CSFServer<Backend: CSFBackend>: @unchecked Sendable {
  let lock = Lock()
  var service: CSFService<Backend>
  let dispatcher: IPCDispatcher
  /// A VMO over the buffer of a backend key, for a client to map.
  let bufferVMO: (Int) -> Handle?
  /// Pins a client's VMO of `size` bytes as a buffer, and gives its backend key.
  let importVMO: (consuming Handle, UInt64) -> Int?

  public init(service: consuming CSFService<Backend>, dispatcher: IPCDispatcher, bufferVMO: @escaping (Int) -> Handle?,
              importVMO: @escaping (consuming Handle, UInt64) -> Int? = { _, _ in nil }) {
    self.service = service
    self.dispatcher = dispatcher
    self.bufferVMO = bufferVMO
    self.importVMO = importVMO
  }

  /// The class's Device for this GPU.
  public var deviceSession: CSFDeviceSession<Backend> { CSFDeviceSession(server: self) }

  /// What is due (see `CSFService.pump`).
  public func pump() {
    lock.lock()
    service.pump()
    lock.unlock()
  }

  public var nextWake: UInt64? {
    lock.lock()
    defer { lock.unlock() }
    return service.nextWake
  }
}

/// The class's Device over a CSF GPU: the one capset.
public struct CSFDeviceSession<Backend: CSFBackend>: GPUDeviceIPC.DeviceHandler {
  let server: CSFServer<Backend>

  public func capsets() -> [UInt32] { [GPUCapset.csf] }

  public func open(capset: UInt32) throws(GPUDeviceIPC.GPUError) -> Handle {
    guard capset == GPUCapset.csf else { throw .notFound }
    guard let ends = try? Channel.create() else { throw .noMemory }
    server.lock.lock()
    let id = server.service.openContext()
    server.lock.unlock()
    let session = CSFContextSession(server: server, context: id)
    let theirs = ends.b.release()
    guard (try? server.dispatcher.add(GPUCSFIPC.ContextServer(channel: Handle(raw: theirs), impl: session))) != nil
    else { throw .noMemory }
    return ends.a
  }
}

/// One client's context; closing its channel closes the context.
public final class CSFContextSession<Backend: CSFBackend>: GPUCSFIPC.ContextHandler {
  let server: CSFServer<Backend>
  let context: Int

  init(server: CSFServer<Backend>, context: Int) {
    self.server = server
    self.context = context
  }

  deinit {
    server.lock.lock()
    server.service.closeContext(context)
    server.lock.unlock()
  }

  public func info() -> GPUCSFIPC.Info {
    server.lock.lock()
    defer { server.lock.unlock() }
    let d = server.service.device
    return GPUCSFIPC.Info(
      gpuID: d.gpuID, csfID: d.csfID, interfaceVersion: d.interfaceVersion, features: d.features,
      shaderPresent: d.shaderPresent, tilerPresent: d.tilerPresent, l2Present: d.l2Present, asPresent: d.asPresent,
      vaBits: UInt32(d.vaBits), pageSizes: 0x0020_1000, groupSlots: UInt32(d.groupSlots),
      queuesPerGroup: UInt32(d.queuesPerGroup), workRegisters: UInt32(d.workRegisters), unpreservedRegisters: 4,
      scoreboards: UInt32(d.scoreboards), priorities: server.service.allowedPriorities)
  }

  public func limits() -> GPUCSFIPC.Limits {
    server.lock.lock()
    defer { server.lock.unlock() }
    let d = server.service.device
    return GPUCSFIPC.Limits(
      maxThreads: d.threadMaxThreads, maxWorkgroupSize: d.threadMaxWorkgroupSize, maxBarrierSize: d.threadMaxBarrierSize,
      threadFeatures: d.threadFeatures)
  }

  public func textureFeatures() -> UInt32 {
    server.lock.lock()
    defer { server.lock.unlock() }
    return server.service.device.textureFeatures0
  }

  public func importBuffer(vmo: consuming Handle, size: UInt64) throws(GPUCSFIPC.GPUError) -> UInt32 {
    server.lock.lock()
    defer { server.lock.unlock() }
    guard let key = server.importVMO(vmo, size) else { throw .noMemory }
    do { return try server.service.adoptBuffer(context, key: key, size: size) } catch { throw gpuError(error) }
  }

  public func createVM(userRange: UInt64) throws(GPUCSFIPC.GPUError) -> GPUCSFIPC.VMInfo {
    server.lock.lock()
    defer { server.lock.unlock() }
    do {
      let vm = try server.service.createVM(context, userRange: userRange)
      return GPUCSFIPC.VMInfo(id: vm.id, userRange: vm.userRange)
    } catch { throw gpuError(error) }
  }

  public func destroyVM(vm: UInt32) throws(GPUCSFIPC.GPUError) {
    server.lock.lock()
    defer { server.lock.unlock() }
    do { try server.service.destroyVM(context, vm) } catch { throw gpuError(error) }
  }

  public func createBuffer(size: UInt64, flags: UInt32) throws(GPUCSFIPC.GPUError) -> GPUCSFIPC.Buffer {
    server.lock.lock()
    defer { server.lock.unlock() }
    let made: (id: UInt32, key: Int, size: UInt64)
    do { made = try server.service.createBuffer(context, size: size, flags: flags) } catch { throw gpuError(error) }
    guard let vmo = server.bufferVMO(made.key) else {
      try? server.service.destroyBuffer(context, made.id)
      throw .noMemory
    }
    return GPUCSFIPC.Buffer(vmo: vmo, id: made.id, size: made.size)
  }

  public func destroyBuffer(id: UInt32) throws(GPUCSFIPC.GPUError) {
    server.lock.lock()
    defer { server.lock.unlock() }
    do { try server.service.destroyBuffer(context, id) } catch { throw gpuError(error) }
  }

  public func bind(vm: UInt32, buffer: UInt32, offset: UInt64, size: UInt64, address: UInt64, flags: UInt32)
    throws(GPUCSFIPC.GPUError)
  {
    server.lock.lock()
    defer { server.lock.unlock() }
    do {
      try server.service.bind(context, vm: vm, buffer: buffer, offset: offset, size: size, address: address, flags: flags)
    } catch { throw gpuError(error) }
  }

  public func unbind(vm: UInt32, address: UInt64, size: UInt64) throws(GPUCSFIPC.GPUError) {
    server.lock.lock()
    defer { server.lock.unlock() }
    do { try server.service.unbind(context, vm: vm, address: address, size: size) } catch { throw gpuError(error) }
  }

  public func createHeap(vm: UInt32, initialChunks: UInt32, chunkSize: UInt32, maxChunks: UInt32, targetInFlight: UInt32)
    throws(GPUCSFIPC.GPUError) -> GPUCSFIPC.HeapInfo
  {
    server.lock.lock()
    defer { server.lock.unlock() }
    do {
      let h = try server.service.createHeap(context, vm: vm, initialChunks: initialChunks, chunkSize: chunkSize,
                                            maxChunks: maxChunks, targetInFlight: targetInFlight)
      return GPUCSFIPC.HeapInfo(handle: h.handle, contextAddress: h.contextVA, firstChunk: h.firstChunk)
    } catch { throw gpuError(error) }
  }

  public func destroyHeap(handle: UInt32) throws(GPUCSFIPC.GPUError) {
    server.lock.lock()
    defer { server.lock.unlock() }
    do { try server.service.destroyHeap(context, heap: handle) } catch { throw gpuError(error) }
  }

  public func createGroup(vm: UInt32, queues: [GPUCSFIPC.QueueConfig], priority: UInt32) throws(GPUCSFIPC.GPUError)
    -> UInt32
  {
    var configs: [(ringSize: UInt32, priority: UInt32)] = []
    for q in queues { configs.append((q.ringSize, q.priority)) }
    server.lock.lock()
    defer { server.lock.unlock() }
    do { return try server.service.createGroup(context, vm: vm, queues: configs, priority: priority) } catch {
      throw gpuError(error)
    }
  }

  public func destroyGroup(group: UInt32) throws(GPUCSFIPC.GPUError) {
    server.lock.lock()
    defer { server.lock.unlock() }
    do { try server.service.destroyGroup(context, group) } catch { throw gpuError(error) }
  }

  public func groupState(group: UInt32) throws(GPUCSFIPC.GPUError) -> GPUCSFIPC.GroupState {
    server.lock.lock()
    defer { server.lock.unlock() }
    do {
      let s = try server.service.groupState(context, group)
      return GPUCSFIPC.GroupState(state: s.state, fatalQueues: s.fatalQueues, resident: s.resident)
    } catch { throw gpuError(error) }
  }

  public func addSync(counter: consuming Handle) throws(GPUCSFIPC.GPUError) -> UInt32 {
    let raw = counter.release()
    server.lock.lock()
    defer { server.lock.unlock() }
    do { return try server.service.addSync(context, counter: raw) } catch {
      CSFCounters.close(raw)
      throw gpuError(error)
    }
  }

  public func removeSync(id: UInt32) {
    server.lock.lock()
    server.service.removeSync(context, id)
    server.lock.unlock()
  }

  public func post(group: UInt32, jobs: [GPUCSFIPC.Job], waits: [GPUCSFIPC.SyncValue], signals: [GPUCSFIPC.SyncValue]) {
    var js: [CSFJob] = []
    for j in jobs { js.append(CSFJob(queue: j.queue, stream: j.stream, size: j.size, flush: j.flush)) }
    var ws: [CSFSync] = []
    for w in waits { ws.append(CSFSync(id: w.id, value: w.value)) }
    var ss: [CSFSync] = []
    for s in signals { ss.append(CSFSync(id: s.id, value: s.value)) }
    server.lock.lock()
    defer { server.lock.unlock() }
    server.service.post(context, group: group, jobs: js, waits: ws, signals: ss)
  }

  public func submit(group: UInt32, jobs: [GPUCSFIPC.Job], waits: [GPUCSFIPC.SyncValue],
                     signals: [GPUCSFIPC.SyncValue]) throws(GPUCSFIPC.GPUError) {
    var js: [CSFJob] = []
    for j in jobs { js.append(CSFJob(queue: j.queue, stream: j.stream, size: j.size, flush: j.flush)) }
    var ws: [CSFSync] = []
    for w in waits { ws.append(CSFSync(id: w.id, value: w.value)) }
    var ss: [CSFSync] = []
    for s in signals { ss.append(CSFSync(id: s.id, value: s.value)) }
    server.lock.lock()
    defer { server.lock.unlock() }
    do { try server.service.submit(context, group: group, jobs: js, waits: ws, signals: ss) } catch {
      throw gpuError(error)
    }
  }
}
