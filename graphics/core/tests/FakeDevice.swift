// SPDX-License-Identifier: BSD-3-Clause

// A fake backend for the core's contract tests (D174 section 1): it runs no
// GPU, it keeps the rules. Memory is host memory whose address is the
// pointer's, the heap is three arrays of what was written, and a queue
// "runs" a list by validating it and recording it, then completing at once.

import GPUCore

final class FakeQueue: GPUQueue {
  unowned let device: FakeDevice
  init(_ device: FakeDevice) { self.device = device }
  func submit(_ list: CommandList, wait: UInt64, signal: UInt64) throws(GPUError) {
    if let e = list.validate(features: device.limits.features) { throw e }
    if let e = device.rule.accept(wait: wait, signal: signal) { throw e }
    device.submitted.append((list, wait, signal))
    device.reached = signal
  }
}

final class FakeDevice: GPUDevice {
  let name = "fake"
  let backend = "fake"
  var limits: DeviceLimits
  var rule = TimelineRule()
  var reached: UInt64 = 0
  var submitted: [(list: CommandList, wait: UInt64, signal: UInt64)] = []
  var nextHandle: UInt64 = 1
  var live: [UInt64] = []
  var textures: [UInt32: GPUImage] = [:]
  var samplers: [UInt32: SamplerDescriptor] = [:]
  var storageImages: [UInt32: GPUImage] = [:]
  var queue: FakeQueue!

  init(features: DeviceFeatures? = nil) {
    var l = DeviceLimits()
    if let features { l.features = features } else {
      l.features.indexedDraw = true
      l.features.indirectDraw = true
      l.features.indirectDispatch = true
      l.features.sampledImages = true
      l.features.storageImages = true
      l.features.timestampQueries = true
      l.features.occlusionQueries = true
      l.features.loadAttachments = true
      l.features.multipleDrawsPerPass = true
    }
    l.heapTextures = 16
    l.heapSamplers = 4
    l.heapStorageImages = 4
    l.maxImageDimension = 4096
    l.timestampPeriodPicoseconds = 1000
    limits = l
    queue = FakeQueue(self)
  }

  var graphicsQueue: any GPUQueue { queue }
  var computeQueue: (any GPUQueue)? { nil }

  func handle() -> UInt64 {
    defer { nextHandle += 1 }
    live.append(nextHandle)
    return nextHandle
  }

  func release(_ h: UInt64) { live.removeAll { $0 == h } }

  func allocate(_ intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory {
    guard bytes > 0 else { throw .invalid("an allocation of no bytes") }
    let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
    p.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    return unsafe GPUMemory(handle: handle(), address: UInt64(UInt(bitPattern: p)), pointer: intent == .device ? nil : p,
                            size: bytes, intent: intent)
  }

  func free(_ memory: GPUMemory) { release(memory.handle) }

  func makeImage(_ d: ImageDescriptor) throws(GPUError) -> GPUImage {
    guard d.width > 0, d.height > 0, d.width <= limits.maxImageDimension, d.height <= limits.maxImageDimension else {
      throw .unsupported("an image of \(d.width) x \(d.height)")
    }
    return GPUImage(handle: handle(), descriptor: d)
  }

  func destroy(_ image: GPUImage) { release(image.handle) }

  func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    guard index < limits.heapTextures else { throw .invalid("texture slot \(index)") }
    guard image.usage.contains(.sampled) else { throw .invalid("a texture that isn't sampled") }
    textures[index] = image
  }

  func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {
    guard index < limits.heapSamplers else { throw .invalid("sampler slot \(index)") }
    samplers[index] = sampler
  }

  func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    guard index < limits.heapStorageImages else { throw .invalid("storage slot \(index)") }
    guard image.usage.contains(.storage) else { throw .invalid("a storage image that isn't") }
    storageImages[index] = image
  }

  func makeGraphicsPipeline(_ d: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
    guard d.vertex.count >= 20, d.vertex.count % 4 == 0, d.fragment.count >= 20, d.fragment.count % 4 == 0 else {
      throw .invalid("not SPIR-V")
    }
    return GPUPipeline(handle: handle(), kind: .graphics)
  }

  func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline {
    guard spirv.count >= 20, spirv.count % 4 == 0 else { throw .invalid("not SPIR-V") }
    return GPUPipeline(handle: handle(), kind: .compute)
  }

  func destroy(_ pipeline: GPUPipeline) { release(pipeline.handle) }

  func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet {
    GPUQuerySet(handle: handle(), kind: kind, count: count)
  }

  func destroy(_ set: GPUQuerySet) { release(set.handle) }

  func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64] {
    guard first >= 0, count >= 0, first + count <= set.count else { throw .invalid("queries past the set") }
    return [UInt64](repeating: 0, count: count)
  }

  var completed: UInt64 { reached }

  func wait(_ value: UInt64) throws(GPUError) {
    guard value <= reached else { throw .invalid("a wait for \(value), the timeline is at \(reached)") }
  }
}
