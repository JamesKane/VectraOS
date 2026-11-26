// SPDX-License-Identifier: BSD-3-Clause

// The Mali backend's transport on the device (D173 section 7): the GPU
// class's `csf` capset, through `CSFContext` (drivers/gpu/client), one
// context on the first GPU in /dev that offers it. It is a thin map: each
// call is the client's, with its failures said as core errors.

import CroiMMIO
import GPUClient
import GPUCore
import GPUDevice
import Sys

final class CSFBufferHandle: MaliBuffer {
  let buffer: CSFBuffer
  init(_ buffer: CSFBuffer) { self.buffer = buffer }
  var size: Int { buffer.size }
  var pointer: UnsafeMutableRawPointer { unsafe buffer.mapping.address }
  func store(_ value: UInt64, at offset: Int) { buffer.store(value, at: offset) }
  var cpuCached: Bool { buffer.cpuCached }
  func cleanInvalidate() { buffer.cleanInvalidate() }
  func exportVMO() -> UInt32? { buffer.exportVMO()?.release() }
  func exportMappableVMO() -> UInt32? { buffer.exportMappableVMO()?.release() }
}

public final class CSFTransport: MaliTransport {
  let context: CSFContext
  public let info: MaliGPUInfo

  public init() throws(GPUError) {
    do throws(CSFClientError) { context = try CSFContext() } catch {
      switch error {
      case .noDevice: throw .noDevice("no GPU in /dev offers the csf capset")
      case .lost: throw .lost
      case .failed(let code): throw .failed("opening a csf context", code: code)
      }
    }
    let i = context.info
    info = MaliGPUInfo(
      gpuID: i.gpuID, workRegisters: Int(i.workRegisters), unpreservedRegisters: Int(i.unpreservedRegisters),
      scoreboards: Int(i.scoreboards), shaderPresent: i.shaderPresent, maxThreads: context.limits?.maxThreads,
      maxWorkgroupSize: context.limits?.maxWorkgroupSize, threadFeatures: context.limits?.threadFeatures,
      name: "Mali (" + context.device + ")", textureFeatures: context.textureFeatures)
  }

  /// Every buffer of this transport is one of its own handles.
  func handle(_ buffer: any MaliBuffer) -> CSFBufferHandle {
    unsafe unsafeDowncast(buffer as AnyObject, to: CSFBufferHandle.self)
  }

  static func core(_ e: CSFClientError, _ what: String) -> GPUError {
    switch e {
    case .noDevice: return .noDevice(what)
    case .lost: return .lost
    case .failed(let code): return .failed(what, code: code)
    }
  }

  public func createVM() throws(GPUError) -> (id: UInt32, userRange: UInt64) {
    do throws(CSFClientError) { return try context.createVM() } catch { throw Self.core(error, "createVM") }
  }

  public func destroyVM(_ vm: UInt32) { try? context.destroyVM(vm) }

  public func createBuffer(size: Int, cpuCached: Bool) throws(GPUError) -> any MaliBuffer {
    do throws(CSFClientError) { return CSFBufferHandle(try context.createBuffer(size: size, cpuCached: cpuCached)) } catch {
      throw Self.core(error, "createBuffer")
    }
  }

  public func importBuffer(vmo: UInt32, size: Int) throws(GPUError) -> any MaliBuffer {
    // The caller keeps its handle: a duplicate is this transport's, and the client makes its own of that.
    let borrowed = Handle(raw: vmo)
    let mine: Handle
    do { mine = try borrowed.duplicate() } catch {
      _ = borrowed.release()
      throw .invalid("a handle that can't be duplicated")
    }
    _ = borrowed.release()
    do throws(CSFClientError) { return CSFBufferHandle(try context.importBuffer(vmo: mine, size: size)) } catch {
      throw Self.core(error, "importBuffer")
    }
  }

  public func destroyBuffer(_ buffer: any MaliBuffer) {
    try? context.destroyBuffer(handle(buffer).buffer)
  }

  public func bind(vm: UInt32, buffer: any MaliBuffer, address: UInt64, gpuCacheable: Bool) throws(GPUError) {
    let b = handle(buffer)
    do throws(CSFClientError) {
      try context.bind(vm: vm, buffer: b.buffer, size: UInt64(b.size), address: address, flags: gpuCacheable ? 8 : 0)
    } catch {
      throw Self.core(error, "bind of \(b.size) bytes at 0x" + String(address, radix: 16))
    }
  }

  public func bind(vm: UInt32, buffer: any MaliBuffer, offset: Int, size: Int, address: UInt64, gpuCacheable: Bool) throws(GPUError) {
    do throws(CSFClientError) {
      try context.bind(vm: vm, buffer: handle(buffer).buffer, offset: UInt64(offset), size: UInt64(size), address: address,
                       flags: gpuCacheable ? 8 : 0)
    } catch {
      throw Self.core(error, "bind of \(size) bytes at 0x" + String(address, radix: 16))
    }
  }

  public func bindDummy(vm: UInt32, address: UInt64, size: Int, gpuCacheable: Bool) throws(GPUError) {
    do throws(CSFClientError) {
      try context.bindDummy(vm: vm, size: UInt64(size), address: address, flags: gpuCacheable ? 8 : 0)
    } catch {
      throw Self.core(error, "bind (sparse)")
    }
  }

  public func unbind(vm: UInt32, address: UInt64, size: Int) { try? context.unbind(vm: vm, address: address, size: UInt64(size)) }

  public func createGroup(vm: UInt32, ringSizes: [UInt32]) throws(GPUError) -> UInt32 {
    do throws(CSFClientError) { return try context.createGroup(vm: vm, ringSizes: ringSizes) } catch {
      throw Self.core(error, "createGroup")
    }
  }

  public func destroyGroup(_ group: UInt32) { try? context.destroyGroup(group) }

  public func groupState(_ group: UInt32) -> UInt32 { (try? context.groupState(group))?.state ?? 1 }

  public func createSync() throws(GPUError) -> UInt32 {
    do throws(CSFClientError) { return try context.createSync() } catch { throw Self.core(error, "createSync") }
  }

  public func destroySync(_ sync: UInt32) { context.destroySync(sync) }

  public func readSync(_ sync: UInt32) -> UInt64 { context.readSync(sync) ?? 0 }

  public func raiseSync(_ sync: UInt32, to value: UInt64) { context.raiseSync(sync, to: value) }

  public func syncHandle(_ sync: UInt32) -> UInt32? { context.syncHandle(sync) }

  public func wait(sync: UInt32, value: UInt64, timeoutNanoseconds: UInt64) -> Bool {
    context.wait(sync: sync, value: value, timeoutNanoseconds: timeoutNanoseconds)
  }

  public func nanoseconds() -> UInt64 { UInt64(max(Clock.monotonic(), 0)) }

  public func pause(nanoseconds: UInt64) { sleep(until: Clock.monotonic() + Int64(nanoseconds)) }

  public func counterFrequency() -> UInt64 { croi_counter_frequency() }

  public func counterTicks() -> UInt64 { croi_counter_value() }

  public func submit(group: UInt32, jobs: [MaliJob], waits: [(sync: UInt32, value: UInt64)],
                     signals: [(sync: UInt32, value: UInt64)]) throws(GPUError) {
    let list = jobs.map { GPUCSFIPC.Job(queue: $0.queue, stream: $0.address, size: $0.size, flush: 0) }
    // Everything this process stored to the GPU's memory (write-combining: it may sit in a write buffer) is out before
    // the driver, in another process, tells the GPU to look.
    croi_dma_complete()
    do throws(CSFClientError) {
      try context.submit(group: group, jobs: list, waits: waits.map { (id: $0.sync, value: $0.value) },
                         signals: signals.map { (id: $0.sync, value: $0.value) })
    } catch { throw Self.core(error, "submit") }
  }
}

extension MaliDevice {
  /// A device on the first GPU in /dev that offers the `csf` capset.
  public convenience init() throws(GPUError) { try self.init(transport: try CSFTransport()) }
}
