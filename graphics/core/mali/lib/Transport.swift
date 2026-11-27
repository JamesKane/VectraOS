// SPDX-License-Identifier: BSD-3-Clause

// What the Mali backend needs of a GPU's command-stream interface, as a
// protocol (D174 sections 2 and 5; gpucore(2)): a VM, buffers mapped into this
// process and bound at GPU addresses, groups of queues, syncs as counters,
// and a submit of streams that signal and wait on them. On the device it is
// `CSFTransport` (native/CSFTransport.swift), the GPU class's `csf` capset
// client (drivers/gpu/client); on the host, a fake that runs no GPU, so the
// backend's own logic (addresses, plans, the streams it makes) is tested
// where the GPU isn't.

import GPUCore

/// What the driver reports about the GPU: `GPUCSFIPC.Info` and `Limits`.
public struct MaliGPUInfo: Sendable, Equatable {
  public var gpuID: UInt32
  public var workRegisters: Int
  public var unpreservedRegisters: Int
  public var scoreboards: Int
  public var shaderPresent: UInt64
  /// The thread limits, where the driver reports them (nil: an older driver, and no compute can be sized).
  public var maxThreads: UInt32?
  public var maxWorkgroupSize: UInt32?
  public var threadFeatures: UInt32?
  /// TEXTURE_FEATURES[0] (valhall 05 section 5.4.2): one bit for each compressed texture format the GPU has; nil where the
  /// driver doesn't report it, and no compressed format is then offered.
  public var textureFeatures: UInt32?
  public var name: String

  public init(gpuID: UInt32, workRegisters: Int, unpreservedRegisters: Int, scoreboards: Int, shaderPresent: UInt64,
              maxThreads: UInt32?, maxWorkgroupSize: UInt32?, threadFeatures: UInt32?, name: String,
              textureFeatures: UInt32? = nil) {
    self.textureFeatures = textureFeatures
    self.gpuID = gpuID
    self.workRegisters = workRegisters
    self.unpreservedRegisters = unpreservedRegisters
    self.scoreboards = scoreboards
    self.shaderPresent = shaderPresent
    self.maxThreads = maxThreads
    self.maxWorkgroupSize = maxWorkgroupSize
    self.threadFeatures = threadFeatures
    self.name = name
  }

  /// The architecture major (valhall 17: 12 is the Immortalis-G720's).
  public var arch: Int { Int(gpuID >> 28) }
}

/// A buffer of the context, mapped here.
public protocol MaliBuffer: AnyObject {
  var size: Int { get }
  /// Where it is mapped in this process.
  var pointer: UnsafeMutableRawPointer { get }
  /// Store the 64-bit word at `offset` (a stream's, a descriptor's).
  func store(_ value: UInt64, at offset: Int)
  /// Whether this process maps it cached (the GPU does not see the CPU's caches, nor the CPU the GPU's writes): then
  /// `cleanInvalidate` writes the CPU's dirty lines back and drops them, after the GPU has written it and before the
  /// CPU reads it, and after the CPU has written memory the GPU will write.
  var cpuCached: Bool { get }
  func cleanInvalidate()
  /// A new handle to the buffer's VMO, with the rights to be transferred, read and measured, for another process (a
  /// display) to pin and read; nil where it can't be made.
  func exportVMO() -> UInt32?
  /// A new handle to the buffer's VMO that another process may map and duplicate (to import it into its own device).
  func exportMappableVMO() -> UInt32?
}

extension MaliBuffer {
  public func exportMappableVMO() -> UInt32? { nil }
}

/// A stream to run: the queue of the group, where it is in the GPU's address space, and its bytes.
public struct MaliJob: Sendable, Equatable {
  public var queue: UInt32
  public var address: UInt64
  public var size: UInt32
  /// The flush token of the kernel's flush before the job (0: always flush; panthor 10 `latest_flush`).
  public var flush: UInt32 = 0
  public init(queue: UInt32, address: UInt64, size: UInt32) {
    self.queue = queue
    self.address = address
    self.size = size
  }
}

public protocol MaliTransport: AnyObject {
  var info: MaliGPUInfo { get }

  func createVM() throws(GPUError) -> (id: UInt32, userRange: UInt64)
  func destroyVM(_ vm: UInt32)
  /// A buffer of at least `size` bytes: write-combining, or with `cpuCached` mapped cached here, for results the CPU reads.
  func createBuffer(size: Int, cpuCached: Bool) throws(GPUError) -> any MaliBuffer
  func destroyBuffer(_ buffer: any MaliBuffer)
  /// A buffer over the pages of `vmo`, a handle of another process's VMO that the caller still owns (this takes its own
  /// reference), `size` bytes of it, mapped here as the VMO's owner has it mapped (never cached by the CPU).
  func importBuffer(vmo: UInt32, size: Int) throws(GPUError) -> any MaliBuffer
  /// Map the whole buffer at `address` of the VM.
  /// `gpuCacheable`: the GPU maps the buffer cacheable (shader atomics and occlusion counts work in its caches).
  func bind(vm: UInt32, buffer: any MaliBuffer, address: UInt64, gpuCacheable: Bool) throws(GPUError)
  /// Map `size` bytes of the buffer from `offset` at `address` of the VM (multiples of the GPU page), replacing what is mapped
  /// there: a sparse resource's pages (valhall 02 section 2.9.4's MAP).
  func bind(vm: UInt32, buffer: any MaliBuffer, offset: Int, size: Int, address: UInt64, gpuCacheable: Bool) throws(GPUError)
  /// Back `size` bytes at `address` with the client's dummy (panthor 04 section 4.8.3's SPARSE MAP), replacing what is mapped
  /// there: 2 MiB of the driver's that every such range repeats, so reads give what was last written through any of them.
  func bindDummy(vm: UInt32, address: UInt64, size: Int, gpuCacheable: Bool) throws(GPUError)
  func unbind(vm: UInt32, address: UInt64, size: Int)

  /// A group over `vm` with one queue per ring size.
  func createGroup(vm: UInt32, ringSizes: [UInt32]) throws(GPUError) -> UInt32
  func destroyGroup(_ group: UInt32)
  /// Zero while it runs; not zero once a fault or a timeout ended it.
  func groupState(_ group: UInt32) -> UInt32

  /// A sync: a counter at 0 that the driver raises.
  func createSync() throws(GPUError) -> UInt32
  func destroySync(_ sync: UInt32)
  func readSync(_ sync: UInt32) -> UInt64
  func raiseSync(_ sync: UInt32, to value: UInt64)
  /// Until the sync reaches `value`; false on the timeout.
  func wait(sync: UInt32, value: UInt64, timeoutNanoseconds: UInt64) -> Bool
  /// A new handle to the sync's kernel counter that its holder may read and wait on, not add to; nil where it can't be made.
  func syncHandle(_ sync: UInt32) -> UInt32?

  /// The system's monotonic clock, and a pause on it: what the GPU's timestamps are calibrated against (the timestamp counter
  /// runs at the system timer's frequency, which the driver does not report to its clients).
  func nanoseconds() -> UInt64
  func pause(nanoseconds: UInt64)
  /// The frequency of the CPU's architected counter in Hz (CNTFRQ_EL0), which the GPU's timestamp counter runs at; 0 where
  /// it can't be read, and the period is then measured.
  func counterFrequency() -> UInt64
  /// The CPU's architected counter now (CNTVCT_EL0), which the GPU's timestamps count in; 0 where it can't be read.
  func counterTicks() -> UInt64

  /// The streams, once each wait has reached its value; each signal is raised when the last is done.
  func submit(group: UInt32, jobs: [MaliJob], waits: [(sync: UInt32, value: UInt64)],
              signals: [(sync: UInt32, value: UInt64)]) throws(GPUError)
}

extension MaliTransport {
  public func bind(vm: UInt32, buffer: any MaliBuffer, offset: Int, size: Int, address: UInt64, gpuCacheable: Bool) throws(GPUError) {
    throw .unsupported("binding part of a buffer")
  }
  public func bindDummy(vm: UInt32, address: UInt64, size: Int, gpuCacheable: Bool) throws(GPUError) {
    throw .unsupported("sparse binding")
  }
  public func importBuffer(vmo: UInt32, size: Int) throws(GPUError) -> any MaliBuffer { throw .unsupported("importing memory") }
  public func syncHandle(_ sync: UInt32) -> UInt32? { nil }
  public func counterTicks() -> UInt64 { 0 }
}
