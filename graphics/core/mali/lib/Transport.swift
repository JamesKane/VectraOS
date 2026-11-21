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
  public var name: String

  public init(gpuID: UInt32, workRegisters: Int, unpreservedRegisters: Int, scoreboards: Int, shaderPresent: UInt64,
              maxThreads: UInt32?, maxWorkgroupSize: UInt32?, threadFeatures: UInt32?, name: String) {
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
}

/// A stream to run: the queue of the group, where it is in the GPU's address space, and its bytes.
public struct MaliJob: Sendable, Equatable {
  public var queue: UInt32
  public var address: UInt64
  public var size: UInt32
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
  func createBuffer(size: Int) throws(GPUError) -> any MaliBuffer
  func destroyBuffer(_ buffer: any MaliBuffer)
  /// Map the whole buffer at `address` of the VM.
  func bind(vm: UInt32, buffer: any MaliBuffer, address: UInt64) throws(GPUError)
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

  /// The streams, once each wait has reached its value; each signal is raised when the last is done.
  func submit(group: UInt32, jobs: [MaliJob], waits: [(sync: UInt32, value: UInt64)],
              signals: [(sync: UInt32, value: UInt64)]) throws(GPUError)
}
