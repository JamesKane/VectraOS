// SPDX-License-Identifier: BSD-3-Clause

// A fake backend for the core's contract tests (D174 section 1): it runs no
// GPU, it keeps the rules. Memory is host memory whose address is the
// pointer's, the heap is three arrays of what was written, and a queue
// "runs" a list by validating it and recording it, then completing at once.
//
// `FakeDevice()` is a device with what the core had before its amendment: the
// four formats, no depth, no mips. `FakeDevice(limits: FakeDevice.fullLimits())` has
// every feature, every format and what each can do.

import GPUCore

final class FakeQueue: GPUQueue {
  unowned let device: FakeDevice
  init(_ device: FakeDevice) { self.device = device }
  func submit(_ list: GPUCommandList, wait: UInt64, signal: UInt64) throws(GPUError) {
    if let e = list.validate(limits: device.limits) { throw e }
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
  var submitted: [(list: GPUCommandList, wait: UInt64, signal: UInt64)] = []
  var nextHandle: UInt64 = 1
  var live: [UInt64] = []
  var textures: [UInt32: ImageView] = [:]
  var samplers: [UInt32: SamplerDescriptor] = [:]
  var storageImages: [UInt32: ImageView] = [:]
  var texelBuffers: [UInt32: BufferView] = [:]
  var storageTexelBuffers: [UInt32: BufferView] = [:]
  var imported: [UInt32] = []
  var queue: FakeQueue!

  /// A device with today's features and the four formats the core had, or with `features` where given.
  convenience init(features: DeviceFeatures? = nil) {
    var l = Self.todaysLimits()
    if let features { l.features = features }
    self.init(limits: l)
  }

  init(limits: DeviceLimits) {
    self.limits = limits
    queue = FakeQueue(self)
  }

  /// What the core had before its amendment: its four formats and the features it had.
  static func todaysLimits() -> DeviceLimits {
    var l = DeviceLimits()
    l.features.indexedDraw = true
    l.features.indirectDraw = true
    l.features.indirectDispatch = true
    l.features.sampledImages = true
    l.features.storageImages = true
    l.features.timestampQueries = true
    l.features.occlusionQueries = true
    l.features.loadAttachments = true
    l.features.multipleDrawsPerPass = true
    l.features.multipleColorAttachments = true
    l.heapTextures = 16
    l.heapSamplers = 4
    l.heapStorageImages = 4
    l.maxImageDimension = 4096
    l.maxColorAttachments = 8
    l.timestampPeriodPicoseconds = 1000
    for f in [PixelFormat.rgba8, .bgra8, .bgra8srgb, .r8] {
      var c = FormatCapabilities.colorTarget
      c.storage = f != .bgra8srgb
      l.setFormat(f, c)
    }
    return l
  }

  /// Every feature, every format and what each can do, up to eight samples.
  static func fullLimits() -> DeviceLimits {
    var l = todaysLimits()
    l.features = fullFeatures()
    l.maxImageDimension3D = 2048
    l.maxImageArrayLayers = 256
    l.maxSamples = 8
    l.maxAnisotropy = 16
    l.maxLineWidth = 8
    l.maxMultiviewViews = 4
    l.maxPatchControlPoints = 32
    l.heapTexelBuffers = 8
    l.heapStorageTexelBuffers = 8
    l.maxTexelBufferElements = 65536
    l.subgroupSize = 32
    l.formatTable = []
    for f in PixelFormat.all { l.setFormat(f, capabilities(of: f)) }
    return l
  }

  static func fullFeatures() -> DeviceFeatures {
    var f = DeviceFeatures()
    f.computeQueue = true
    f.indirectDispatch = true
    f.indirectDraw = true
    f.indexedDraw = true
    f.sampledImages = true
    f.storageImages = true
    f.timestampQueries = true
    f.occlusionQueries = true
    f.loadAttachments = true
    f.multipleDrawsPerPass = true
    f.depth = true
    f.stencil = true
    f.mipmaps = true
    f.arrayImages = true
    f.cubeImages = true
    f.volumeImages = true
    f.multisample = true
    f.compressedASTC = true
    f.compressedETC2 = true
    f.compressedBC = true
    f.imageViews = true
    f.samplerAnisotropy = true
    f.samplerCompare = true
    f.samplerBorder = true
    f.unnormalizedCoordinates = true
    f.samplerMinMagFilters = true
    f.samplerAxisAddressModes = true
    f.samplerMirrorClampToEdge = true
    f.cullModes = true
    f.rasterizerDiscard = true
    f.generalBlend = true
    f.independentBlend = true
    f.dualSourceBlend = true
    f.logicOps = true
    f.fillModeNonSolid = true
    f.wideLines = true
    f.depthClamp = true
    f.depthBias = true
    f.depthBounds = true
    f.geometryShader = true
    f.tessellation = true
    f.multiview = true
    f.extendedTopologies = true
    f.primitiveRestart = true
    f.sampleShading = true
    f.alphaToCoverage = true
    f.alphaToOne = true
    f.specializationConstants = true
    f.dynamicState = true
    f.multipleColorAttachments = true
    f.copyImage = true
    f.blitImage = true
    f.resolveImage = true
    f.resolveAttachments = true
    f.depthStencilResolve = true
    f.imageRegionCopies = true
    f.fillBuffer = true
    f.updateBuffer = true
    f.clearImage = true
    f.clearAttachments = true
    f.drawIndirectCount = true
    f.pipelineStatisticsQueries = true
    f.importHandle = true
    f.shaderFloat16 = true
    f.shaderInt8 = true
    f.shaderInt16 = true
    f.shaderInt64 = true
    f.shaderFloat64 = true
    f.subgroupOperations = true
    f.shaderAtomic32 = true
    f.shaderAtomic64 = true
    f.shaderImageAtomics = true
    f.shaderDerivatives = true
    f.shaderStorageImageExtendedFormats = true
    f.shaderStorageImageReadWithoutFormat = true
    f.shaderStorageImageWriteWithoutFormat = true
    f.shaderClipDistance = true
    f.shaderCullDistance = true
    f.shaderImageGatherExtended = true
    f.shaderMinLod = true
    f.shaderDrawParameters = true
    f.shaderDemoteToHelperInvocation = true
    f.shaderViewportIndexLayer = true
    f.shaderStencilExport = true
    f.shaderSampleRateShading = true
    f.shaderFloatControls = true
    f.images1D = true
    f.imageSwizzle = true
    f.customBorderColor = true
    f.uniformTexelBuffers = true
    f.storageTexelBuffers = true
    return f
  }

  /// What a generous device does with each format.
  static func capabilities(of f: PixelFormat) -> FormatCapabilities {
    var c = FormatCapabilities()
    c.sampled = true
    c.sampledSamples = .upToEight
    if f.isDepthStencil {
      c.depthTarget = true
      c.depthSamples = .upToEight
      c.filterable = f.hasDepth && !f.hasStencil
      c.blitSource = true
      c.blitDestination = true
      return c
    }
    c.filterable = f.channelClass == .float && f != .r32float && f != .rg32float && f != .rgba32float
    if f.isCompressed {
      c.blitSource = false
      return c
    }
    c.blitSource = true
    c.blitDestination = f != .rgb9e5 && f != .rg11b10float
    c.storage = !f.isSRGB && f != .rgb9e5 && f != .bgra8
    c.storageSamples = .upToFour
    c.storageAtomic = f == .r32uint || f == .r32sint
    c.texelBuffer = f != .rgb9e5 && !f.isSRGB
    c.storageTexelBuffer = c.storage
    c.storageTexelBufferAtomic = c.storageAtomic
    if f != .rgb9e5 {
      c.renderTarget = true
      c.renderSamples = .upToEight
      c.blendable = f.channelClass == .float
    }
    return c
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
    if let e = d.check(limits: limits) { throw e }
    return GPUImage(handle: handle(), descriptor: d)
  }

  func destroy(_ image: GPUImage) { release(image.handle) }

  func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    try writeTexture(index, ImageView(image))
  }

  func writeTexture(_ index: UInt32, _ view: ImageView) throws(GPUError) {
    guard index < limits.heapTextures else { throw .invalid("texture slot \(index)") }
    if let e = view.check(for: .texture, limits: limits) { throw e }
    textures[index] = view
  }

  func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {
    guard index < limits.heapSamplers else { throw .invalid("sampler slot \(index)") }
    if let e = sampler.check(limits: limits) { throw e }
    samplers[index] = sampler
  }

  func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    try writeStorageImage(index, ImageView(image))
  }

  func writeStorageImage(_ index: UInt32, _ view: ImageView) throws(GPUError) {
    guard index < limits.heapStorageImages else { throw .invalid("storage slot \(index)") }
    if let e = view.check(for: .storage, limits: limits) { throw e }
    storageImages[index] = view
  }

  func writeTexelBuffer(_ index: UInt32, _ view: BufferView) throws(GPUError) {
    guard index < limits.heapTexelBuffers else { throw .invalid("texel buffer slot \(index)") }
    if let e = view.check(for: .uniform, limits: limits) { throw e }
    texelBuffers[index] = view
  }

  func writeStorageTexelBuffer(_ index: UInt32, _ view: BufferView) throws(GPUError) {
    guard index < limits.heapStorageTexelBuffers else { throw .invalid("storage texel buffer slot \(index)") }
    if let e = view.check(for: .storage, limits: limits) { throw e }
    storageTexelBuffers[index] = view
  }

  func makeGraphicsPipeline(_ d: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
    guard d.vertex.count >= 20, d.vertex.count % 4 == 0, d.fragment.count >= 20, d.fragment.count % 4 == 0 else {
      throw .invalid("not SPIR-V")
    }
    if let e = d.check(limits: limits) { throw e }
    return GPUPipeline(handle: handle(), kind: .graphics, targets: d.targets)
  }

  func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline {
    guard spirv.count >= 20, spirv.count % 4 == 0 else { throw .invalid("not SPIR-V") }
    return GPUPipeline(handle: handle(), kind: .compute)
  }

  func makeComputePipeline(spirv: [UInt8], specialization: [SpecializationConstant]) throws(GPUError) -> GPUPipeline {
    if !specialization.isEmpty && !limits.features.specializationConstants { throw .unsupported("specialization constants") }
    return try makeComputePipeline(spirv: spirv)
  }

  func destroy(_ pipeline: GPUPipeline) { release(pipeline.handle) }

  func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet {
    if case .pipelineStatistics = kind, !limits.features.pipelineStatisticsQueries {
      throw .unsupported("pipeline statistics queries")
    }
    return GPUQuerySet(handle: handle(), kind: kind, count: count)
  }

  func destroy(_ set: GPUQuerySet) { release(set.handle) }

  func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64] {
    guard first >= 0, count >= 0, first + count <= set.count else { throw .invalid("queries past the set") }
    var per = 1
    if case .pipelineStatistics(let s) = set.kind { per = s.count }
    return [UInt64](repeating: 0, count: count * per)
  }

  func importHandle(_ vmo: UInt32, intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory {
    guard limits.features.importHandle else { throw .unsupported("importing a handle as memory") }
    guard bytes > 0 else { throw .invalid("an import of no bytes") }
    imported.append(vmo)
    return try allocate(intent, bytes: bytes)
  }

  func importHandle(_ vmo: UInt32, as descriptor: ImageDescriptor) throws(GPUError) -> GPUImage {
    guard limits.features.importHandle else { throw .unsupported("importing a handle as an image") }
    imported.append(vmo)
    return try makeImage(descriptor)
  }

  var completed: UInt64 { reached }

  func wait(_ value: UInt64) throws(GPUError) {
    guard value <= reached else { throw .invalid("a wait for \(value), the timeline is at \(reached)") }
  }
}
