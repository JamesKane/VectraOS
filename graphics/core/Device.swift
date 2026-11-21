// SPDX-License-Identifier: BSD-3-Clause

// The contract a native GPU driver implements (D174 section 1; gpucore(2)).
// A backend is a class that conforms to `GPUDevice` and hands out its queues.
// Loinnir and the Vulkan layer (D174 section 4) are written on these two
// protocols and nothing beside them.
//
// The rules a backend keeps:
//
//  - Memory is by intent. `allocate` gives 64-bit GPU addresses valid for the
//    allocation's life, and a CPU pointer where the intent says so. The bytes
//    behind a pointer of `.upload` memory are the GPU's to read from the next
//    `submit` on; a `.readback` allocation's are the CPU's to read once the
//    timeline has reached the value that submission signalled.
//  - There is one bindless heap per device, three arrays: textures (sampled
//    images), samplers and storage images. The caller owns the indices: it
//    writes a slot, and a shader names the slot. A slot may be rewritten at
//    any time; work already submitted keeps the descriptor it was submitted
//    with. Slots the device's limits give; past them a write is `.invalid`.
//  - Every pipeline has the one layout: the heap, and 16 bytes of root
//    pointer (the first 8 bytes of push constants, as a SPIR-V
//    `PushConstant` block of one buffer reference). Compute and graphics
//    pipelines alike.
//  - Image layouts are the device's. It moves an image to what each command
//    needs and back to what rests it: sampled images rest ready to sample.
//  - A device has one timeline: a counter that only goes up, which the GPU
//    class's counters (D121, D25) are. `submit` waits for `wait` (0: no wait)
//    and signals `signal`, which must be greater than any value this device
//    has signalled. `completed` is the highest value reached.
//  - Destroying or freeing is always safe: the device keeps the resource
//    until everything submitted before the call has finished.
//  - A list is judged by `GPUCommandList.validate` first; a refusal of a feature
//    is `.unsupported`, a list of the wrong shape `.invalid`.

public protocol GPUQueue: AnyObject {
  /// Runs `list` once the timeline reaches `wait` (0 for no wait), and sets the timeline to `signal` when
  /// it is done. Lists on one queue run in the order submitted.
  func submit(_ list: GPUCommandList, wait: UInt64, signal: UInt64) throws(GPUError)
}

public protocol GPUDevice: AnyObject {
  /// The GPU's name, and the backend that drives it ("vulkan", "mali").
  var name: String { get }
  var backend: String { get }
  var limits: DeviceLimits { get }

  /// The queue that draws and computes, and a queue for compute alone where the GPU has one
  /// (`limits.features.computeQueue`).
  var graphicsQueue: any GPUQueue { get }
  var computeQueue: (any GPUQueue)? { get }

  // Memory.
  func allocate(_ intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory
  func free(_ memory: GPUMemory)

  // Images and the heap.
  func makeImage(_ descriptor: ImageDescriptor) throws(GPUError) -> GPUImage
  func destroy(_ image: GPUImage)
  /// Puts a sampled image in texture slot `index`.
  func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError)
  func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError)
  /// Puts a storage image in slot `index`.
  func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError)

  // Pipelines, made from SPIR-V by the device's compiler.
  func makeGraphicsPipeline(_ descriptor: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline
  func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline
  func destroy(_ pipeline: GPUPipeline)

  // Queries.
  func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet
  func destroy(_ set: GPUQuerySet)
  /// The results of `count` queries from `first`, once the work that wrote them has completed.
  func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64]

  // The timeline.
  /// The highest value the timeline has reached.
  var completed: UInt64 { get }
  /// Until the timeline reaches `value`.
  func wait(_ value: UInt64) throws(GPUError)

  /// A new handle (a system handle: a VMO) to `memory`'s pages, to give another process; nil where the device
  /// can't share memory that way (the default).
  func exportHandle(_ memory: GPUMemory) -> UInt32?

  /// A new handle (a VMO, with the rights to be transferred, read and measured, not mapped) to a `scanout` image's
  /// pages, for a display to show them; nil where the device can't (the default), or the image is not laid out as the
  /// display reads it.
  func exportHandle(_ image: GPUImage) -> UInt32?
}

extension GPUDevice {
  public func exportHandle(_ memory: GPUMemory) -> UInt32? { nil }
  public func exportHandle(_ image: GPUImage) -> UInt32? { nil }

  /// Submits on the graphics queue and waits for it: the shape of a test and of a one-off upload.
  public func run(_ list: GPUCommandList, signal: UInt64) throws(GPUError) {
    try graphicsQueue.submit(list, wait: 0, signal: signal)
    try wait(signal)
  }
}

/// What a backend owes the contract's checks at the top of `submit`: the list's rules, and the timeline's.
public struct TimelineRule {
  public private(set) var lastSignalled: UInt64 = 0
  public init() {}

  /// The error, if `signal` doesn't go up or `wait` is for a value nothing has signalled.
  public func check(wait: UInt64, signal: UInt64) -> GPUError? {
    if signal == 0 || signal <= lastSignalled { return .invalid("a signal of \(signal) after \(lastSignalled)") }
    if wait > lastSignalled { return .invalid("a wait for \(wait), which nothing has signalled (\(lastSignalled) is the last)") }
    return nil
  }

  /// `check`, and if it passes, records `signal` as the last.
  public mutating func accept(wait: UInt64, signal: UInt64) -> GPUError? {
    if let e = check(wait: wait, signal: signal) { return e }
    lastSignalled = signal
    return nil
  }
}
