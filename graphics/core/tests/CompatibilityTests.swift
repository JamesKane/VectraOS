// SPDX-License-Identifier: BSD-3-Clause

// Source compatibility (D174 amendment): what was written against the core before its amendment still compiles and
// means what it did. This file is the old spelling, on purpose: don't update it to the new one. A backend that
// conforms to `GPUDevice` with only the requirements it had needs nothing more, and is refused what it lacks.

import Testing

@testable import GPUCore

/// A backend written before the amendment: only the requirements `GPUDevice` had.
final class LegacyDevice: GPUDevice {
  var name: String { "legacy" }
  var backend: String { "legacy" }
  var limits: DeviceLimits { DeviceLimits() }
  var graphicsQueue: any GPUQueue { fatalError("no queue") }
  var computeQueue: (any GPUQueue)? { nil }
  var textureWrites: [(UInt32, GPUImage)] = []
  var computeMade = 0
  func allocate(_ intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory { throw .unsupported("memory") }
  func free(_ memory: GPUMemory) {}
  func makeImage(_ descriptor: ImageDescriptor) throws(GPUError) -> GPUImage { GPUImage(handle: 1, descriptor: descriptor) }
  func destroy(_ image: GPUImage) {}
  func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) { textureWrites.append((index, image)) }
  func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {}
  func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) { textureWrites.append((index, image)) }
  func makeGraphicsPipeline(_ descriptor: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
    GPUPipeline(handle: 1, kind: .graphics)
  }
  func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline {
    computeMade += 1
    return GPUPipeline(handle: 2, kind: .compute)
  }
  func destroy(_ pipeline: GPUPipeline) {}
  func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet { GPUQuerySet(handle: 3, kind: kind, count: count) }
  func destroy(_ set: GPUQuerySet) {}
  func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64] { [] }
  var completed: UInt64 { 0 }
  func wait(_ value: UInt64) throws(GPUError) {}
}

@Suite struct SourceCompatibility {
  @Test func theOldInitializersAndFieldsStillCompileAndMeanWhatTheyDid() throws {
    let d = ImageDescriptor(format: .bgra8srgb, width: 8, height: 4, usage: .renderTarget | .copySource)
    #expect(d.format == .bgra8srgb && d.width == 8 && d.height == 4)
    #expect(d.depth == 1 && d.mipLevels == 1 && d.layers == 1 && d.samples == 1 && d.dimension == .d2)
    let image = GPUImage(handle: 5, descriptor: d)
    #expect(image.width == 8 && image.height == 4 && image.format == .bgra8srgb && image.usage.contains(.copySource))
    #expect(PixelFormat.rgba8.bytesPerPixel == 4 && PixelFormat.r8.bytesPerPixel == 1)
    let attachment = Attachment(image: image, load: .clear(0, 0, 0, 1))
    #expect(attachment.image == image && attachment.store == .store && attachment.resolve == nil)
    var info = RenderingInfo(colors: [attachment])
    #expect(info.width == 8 && info.height == 4 && info.depthStencil == nil && info.layerCount == 1 && info.viewMask == 0)
    info.colors[0].image = GPUImage(handle: 6, descriptor: d)
    #expect(info.colors[0].view.isWholeImage)
    let sampler = SamplerDescriptor(filter: .nearest, addressMode: .repeat)
    #expect(sampler.filter == .nearest && sampler.addressMode == .repeat)
    let p = GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.bgra8], blend: .opaque, topology: .lineList)
    #expect(p.blend == .opaque && p.topology == .lineList && p.colorFormats == [.bgra8])
    let q = GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8])
    #expect(q.blend == .alpha && q.topology == .triangleList)
    #expect(q.depthStencilFormat == nil && !q.depthStencil.isEnabled && q.rasterization.cull == .none)
    #expect(q.rasterization.polygonMode == .fill && q.multisample.samples == 1 && q.attachmentBlends == nil && q.logicOp == nil)
    #expect(q.dynamic.isEmpty && q.specialization.isEmpty && q.geometry == nil && !q.primitiveRestart)
    let pipeline = GPUPipeline(handle: 1, kind: .compute)
    #expect(pipeline.kind == .compute && pipeline.targets == nil)
    #expect(GPUQuerySet(handle: 2, kind: .timestamp, count: 3).kind == .timestamp)
    #expect(DeviceFeatures().multipleDrawsPerPass == false)
    var limits = DeviceLimits()
    limits.features.sampledImages = true
    limits.maxImageDimension = 8
    #expect(limits.timestampPeriodPicoseconds == 0 && limits.formatTable.isEmpty)
  }

  @Test func theOldCommandsAreMatchedAsTheyWere() throws {
    let gpu = FakeDevice()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 2, height: 2, usage: .copyDestination | .copySource))
    let m = try gpu.allocate(.upload, bytes: 64)
    var list = GPUCommandList()
    list.copy(m, to: image)
    list.copy(image, to: m)
    list.copy(m, to: m, bytes: 8)
    list.barrier()
    var seen = 0
    for c in list.commands {
      switch c {
      case .copyBufferToImage(let memory, let offset, let target): seen += memory == m && offset == 0 && target == image ? 1 : 0
      case .copyImageToBuffer(let source, let memory, let offset): seen += source == image && memory == m && offset == 0 ? 1 : 0
      case .copyBuffer(_, let from, _, let to, let bytes): seen += from == 0 && to == 0 && bytes == 8 ? 1 : 0
      case .barrier(let from, let to): seen += from == .all && to == .all ? 1 : 0
      default: break
      }
    }
    #expect(seen == 4)
    #expect(list.validate(features: gpu.limits.features) == nil)
    #expect(list.validate(limits: gpu.limits) == nil)
  }

  @Test func aWholeImageCopyIsStillTheImagesRowsInBytes() throws {
    let gpu = FakeDevice()
    let image = try gpu.makeImage(ImageDescriptor(format: .r8, width: 5, height: 3, usage: .copyDestination))
    let exact = try gpu.allocate(.upload, bytes: 15)
    let short = try gpu.allocate(.upload, bytes: 14)
    var ok = GPUCommandList()
    ok.copy(exact, to: image)
    #expect(ok.validate(features: gpu.limits.features) == nil)
    var bad = GPUCommandList()
    bad.copy(short, to: image)
    #expect(bad.validate(features: gpu.limits.features) == .invalid("a copy past its memory"))
  }

  @Test func theOldDeviceModelRefusesWhatItNeverHad() throws {
    let gpu = FakeDevice()  // today's features and the four formats
    for f in [PixelFormat.depth16, .rg8, .rgba16float, .astc(.b4x4), .bc1rgb] {
      let refusal = ImageDescriptor(format: f, width: 4, height: 4, usage: .sampled).check(limits: gpu.limits)
      #expect(verdict(refusal) == "unsupported", "\(f)")
      #expect(throws: GPUError.self) { try gpu.makeImage(ImageDescriptor(format: f, width: 4, height: 4, usage: .sampled)) }
    }
    #expect(verdict(ImageDescriptor(format: .rgba8, width: 8, height: 8, mipLevels: 2, usage: .sampled).check(limits: gpu.limits)) == "unsupported")
    #expect(verdict(ImageDescriptor(format: .rgba8, width: 8, height: 8, layers: 2, usage: .sampled).check(limits: gpu.limits)) == "unsupported")
    #expect(verdict(ImageDescriptor(format: .rgba8, width: 8, height: 8, samples: 4, usage: .renderTarget).check(limits: gpu.limits)) == "unsupported")
    #expect(ImageDescriptor(format: .rgba8, width: 8, height: 8, usage: .sampled | .renderTarget | .copySource | .copyDestination).check(limits: gpu.limits) == nil)
    #expect(SamplerDescriptor().check(limits: gpu.limits) == nil)
    #expect(verdict(SamplerDescriptor(maxAnisotropy: 2).check(limits: gpu.limits)) == "unsupported")
  }

  @Test func aBackendThatNeverHeardOfTheAmendmentIsRefusedWhatItLacks() throws {
    let gpu = LegacyDevice()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: .sampled | .storage))
    // Whole-image views go through the old calls.
    try gpu.writeTexture(1, ImageView(image))
    try gpu.writeStorageImage(2, ImageView(image))
    #expect(gpu.textureWrites.count == 2 && gpu.textureWrites[0].0 == 1 && gpu.textureWrites[1].0 == 2)
    // Anything else of a view isn't there.
    #expect(throws: GPUError.self) { try gpu.writeTexture(1, ImageView(image, format: .rgba8uint)) }
    #expect(throws: GPUError.unsupported("a texture view that isn't the whole image")) { try gpu.writeTexture(1, ImageView(image, baseMip: 1)) }
    #expect(throws: GPUError.unsupported("a storage view that isn't the whole image")) { try gpu.writeStorageImage(1, ImageView(image, baseMip: 1)) }
    #expect(gpu.textureWrites.count == 2)
    // Import is refused, whatever the handle.
    #expect(throws: GPUError.unsupported("importing a handle as memory")) { try gpu.importHandle(7, intent: .upload, bytes: 64) }
    #expect(throws: GPUError.unsupported("importing a handle as an image")) {
      try gpu.importHandle(7, as: ImageDescriptor(format: .bgra8, width: 4, height: 4, usage: .scanout))
    }
    // Specialization constants go to the old call when there are none, and are refused when there are.
    _ = try gpu.makeComputePipeline(spirv: module, specialization: [])
    #expect(gpu.computeMade == 1)
    #expect(throws: GPUError.unsupported("specialization constants")) {
      try gpu.makeComputePipeline(spirv: module, specialization: [SpecializationConstant(id: 0, uint32: 1)])
    }
    #expect(gpu.computeMade == 1)
    // The device's own exports are as they were: none.
    #expect(gpu.exportHandle(GPUImage(handle: 1, descriptor: ImageDescriptor(format: .rgba8, width: 1, height: 1, usage: .scanout))) == nil)
  }

  @Test func theFakeImportsWhenItsFeaturesSayItCan() throws {
    let on = fullDevice()
    let memory = try on.importHandle(11, intent: .upload, bytes: 128)
    #expect(memory.size == 128 && on.imported == [11])
    let image = try on.importHandle(12, as: ImageDescriptor(format: .bgra8srgb, width: 8, height: 8, usage: .sampled | .scanout))
    #expect(image.width == 8 && on.imported == [11, 12])
    #expect(throws: GPUError.self) { try on.importHandle(13, intent: .upload, bytes: 0) }
    #expect(throws: GPUError.unsupported("importing a handle as memory")) { try FakeDevice().importHandle(11, intent: .upload, bytes: 128) }
    // A pass can't use pipelines with state the device has none of, but the old device's computes pass through.
    let compute = try FakeDevice().makeComputePipeline(spirv: module, specialization: [])
    #expect(compute.kind == .compute)
    #expect(throws: GPUError.self) { try FakeDevice().makeComputePipeline(spirv: module, specialization: [SpecializationConstant(id: 0, bool: true)]) }
    _ = try on.makeComputePipeline(spirv: module, specialization: [SpecializationConstant(id: 0, bool: true)])
  }

  @Test func theOldValidateStillJudgesByFeaturesAlone() throws {
    let gpu = FakeDevice()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, usage: .renderTarget))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: image, load: .clear(0, 0, 0, 1))])) { _ in }
    #expect(list.validate(features: gpu.limits.features) == nil)
    var none = DeviceFeatures()
    none.sampledImages = true
    #expect(list.validate(features: none) == nil)
    var fills = GPUCommandList()
    fills.fill(try gpu.allocate(.upload, bytes: 16), bytes: 16, value: 0)
    #expect(fills.validate(features: gpu.limits.features) == .unsupported("buffer fills"))
  }
}
