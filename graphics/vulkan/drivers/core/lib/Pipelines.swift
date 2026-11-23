// SPDX-License-Identifier: BSD-3-Clause

// Shader modules, pipeline caches and pipelines (D174 amendment, step 5). A pipeline is made by running each stage
// through the lowering against the pipeline layout (and, for the vertex stage, the vertex input state) and handing the
// result to the core with all the fixed state Vulkan states: depth and stencil, rasterization, multisampling, blend
// for each attachment, the logic op, and which state the pass's commands set. Specialization constants are the
// lowering's: each stage is lowered with its stage's VkSpecializationInfo. What the core's device lacks, it refuses at
// creation; the layer refuses only what Vulkan has and the core has no word for (adjacency topologies, dynamic state
// beyond the core's).

import GPUCore
import TDVulkan
import VulkanLowering

final class ShaderModuleObject: CoreObject {
  let words: [UInt32]
  init(words: [UInt32]) { self.words = words }
}

func core_vkCreateShaderModule(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkShaderModuleCreateInfo>?,
                               _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                               _ pShaderModule: UnsafeMutablePointer<VkShaderModule?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pShaderModule, let code = unsafe info.pointee.pCode else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let n = unsafe Int(info.pointee.codeSize)
  guard n % 4 == 0, n >= 20 else { return vkErrorInvalidShader }
  var words = [UInt32](repeating: 0, count: n / 4)
  for i in words.indices { words[i] = unsafe code[i] }
  unsafe out.pointee = Handle.make(ShaderModuleObject(words: words))
  return VK_SUCCESS
}

func core_vkDestroyShaderModule(_ device: VkDevice?, _ shaderModule: VkShaderModule?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(shaderModule)
}

// MARK: Pipeline caches

/// A cache that keeps nothing: the core's device caches what it compiles.
final class PipelineCacheObject: CoreObject {}

func core_vkCreatePipelineCache(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkPipelineCacheCreateInfo>?,
                                _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                                _ pPipelineCache: UnsafeMutablePointer<VkPipelineCache?>?) -> VkResult
{
  unsafe pPipelineCache?.pointee = Handle.make(PipelineCacheObject())
  return VK_SUCCESS
}

func core_vkDestroyPipelineCache(_ device: VkDevice?, _ pipelineCache: VkPipelineCache?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(pipelineCache)
}

func core_vkGetPipelineCacheData(_ device: VkDevice?, _ pipelineCache: VkPipelineCache?, _ pDataSize: UnsafeMutablePointer<Int>?,
                                 _ pData: UnsafeMutableRawPointer?) -> VkResult
{
  unsafe pDataSize?.pointee = 0
  return VK_SUCCESS
}

func core_vkMergePipelineCaches(_ device: VkDevice?, _ dstCache: VkPipelineCache?, _ srcCacheCount: UInt32,
                                _ pSrcCaches: UnsafePointer<VkPipelineCache?>?) -> VkResult { VK_SUCCESS }

// MARK: Pipelines

final class PipelineObject: CoreObject {
  let gpu: GPUPipeline
  let layout: PipelineLayoutObject?
  let device: DeviceObject
  /// The viewports and scissors a pipeline states, nil where they are dynamic, and how many it draws with.
  var viewports: [Viewport]?
  var scissors: [RenderArea]?
  var viewportCount: UInt32 = 1
  /// The state a pass's commands set in place of the pipeline's.
  var dynamic = DynamicStates()
  var depthStencil = DepthStencilState()
  init(gpu: GPUPipeline, layout: PipelineLayoutObject?, device: DeviceObject) {
    self.gpu = gpu
    self.layout = layout
    self.device = device
  }
}

/// The first structure of `type` in a `pNext` chain.
func findStructure(_ chain: UnsafeRawPointer?, _ type: VkStructureType) -> UnsafeRawPointer? {
  var p = unsafe chain
  while let q = unsafe p {
    if unsafe q.load(as: VkStructureType.self) == type { return unsafe q }
    unsafe p = unsafe q.load(fromByteOffset: 8, as: UnsafeRawPointer?.self)
  }
  return nil
}

func entryName(_ p: UnsafePointer<CChar>?) -> String {
  guard let p = unsafe p else { return "main" }
  var n = 0
  while unsafe p[n] != 0 { n += 1 }
  return unsafe String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: n), as: UTF8.self)
}

func spirvBytes(_ words: [UInt32]) -> [UInt8] {
  var out: [UInt8] = []
  out.reserveCapacity(words.count * 4)
  for w in words {
    out.append(UInt8(truncatingIfNeeded: w))
    out.append(UInt8(truncatingIfNeeded: w >> 8))
    out.append(UInt8(truncatingIfNeeded: w >> 16))
    out.append(UInt8(truncatingIfNeeded: w >> 24))
  }
  return out
}

/// A stage's module, entry point and specialization constants.
func stageOf(_ s: VkPipelineShaderStageCreateInfo) -> (module: ShaderModuleObject, entry: String, spec: [SpecConstant])? {
  guard let m = unsafe Handle.get(s.module, ShaderModuleObject.self) else { return nil }
  return unsafe (m, entryName(unsafe s.pName), specConstants(s))
}

/// The stage's VkSpecializationInfo as the lowering takes it: each map entry's bytes, little-endian, in a value.
func specConstants(_ s: VkPipelineShaderStageCreateInfo) -> [SpecConstant] {
  guard let sp = unsafe s.pSpecializationInfo, let data = unsafe sp.pointee.pData else { return [] }
  var out: [SpecConstant] = []
  for i in 0..<Int(unsafe sp.pointee.mapEntryCount) {
    let e = unsafe sp.pointee.pMapEntries[i]
    let dataSize = unsafe sp.pointee.dataSize
    guard e.size >= 1 && e.size <= 8 && Int(e.offset) + e.size <= dataSize else { continue }
    var v: UInt64 = 0
    for k in 0..<e.size { v |= UInt64(unsafe data.load(fromByteOffset: Int(e.offset) + k, as: UInt8.self)) << UInt64(8 * k) }
    out.append(SpecConstant(id: e.constantID, value: v))
  }
  return out
}

func lowerStage(_ module: ShaderModuleObject, _ stage: ShaderStage, _ entry: String, _ layout: LoweringLayout,
                _ spec: [SpecConstant]) throws(LoweringError) -> [UInt8]
{
  let words = unsafe try CoreDriver.lowering(module.words, stage, entry, layout, spec)
  return spirvBytes(words)
}

func core_vkCreateComputePipelines(_ device: VkDevice?, _ pipelineCache: VkPipelineCache?, _ createInfoCount: UInt32,
                                   _ pCreateInfos: UnsafePointer<VkComputePipelineCreateInfo>?,
                                   _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                                   _ pPipelines: UnsafeMutablePointer<VkPipeline?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let infos = unsafe pCreateInfos, let out = unsafe pPipelines else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  var result = VK_SUCCESS
  for i in 0..<Int(createInfoCount) {
    unsafe out[i] = nil
    let c = unsafe infos[i]
    guard unsafe c.stage.stage == VK_SHADER_STAGE_COMPUTE_BIT, let layout = unsafe Handle.get(c.layout, PipelineLayoutObject.self),
      let stage = unsafe stageOf(c.stage)
    else {
      if result == VK_SUCCESS { result = VK_ERROR_INITIALIZATION_FAILED }
      continue
    }
    do throws(LoweringError) {
      let bytes = try lowerStage(stage.module, .compute, stage.entry, layout.lowering, stage.spec)
      do throws(GPUError) {
        let p = try d.gpu.makeComputePipeline(spirv: bytes)
        unsafe out[i] = Handle.make(PipelineObject(gpu: p, layout: layout, device: d))
      } catch {
        if result == VK_SUCCESS { result = vkResult(error) }
      }
    } catch {
      if result == VK_SUCCESS { result = vkResult(error) }
    }
  }
  return result
}

func vertexFormat(_ f: VkFormat) -> VertexFormat? {
  if f == VK_FORMAT_R32_SFLOAT { return .r32Float }
  if f == VK_FORMAT_R32G32_SFLOAT { return .rg32Float }
  if f == VK_FORMAT_R32G32B32_SFLOAT { return .rgb32Float }
  if f == VK_FORMAT_R32G32B32A32_SFLOAT { return .rgba32Float }
  if f == VK_FORMAT_R32_UINT { return .r32Uint }
  if f == VK_FORMAT_R32G32_UINT { return .rg32Uint }
  if f == VK_FORMAT_R32G32B32_UINT { return .rgb32Uint }
  if f == VK_FORMAT_R32G32B32A32_UINT { return .rgba32Uint }
  if f == VK_FORMAT_R32_SINT { return .r32Sint }
  if f == VK_FORMAT_R32G32_SINT { return .rg32Sint }
  if f == VK_FORMAT_R32G32B32_SINT { return .rgb32Sint }
  if f == VK_FORMAT_R32G32B32A32_SINT { return .rgba32Sint }
  if f == VK_FORMAT_R8G8B8A8_UNORM { return .rgba8Unorm }
  return nil
}

// Mapped state.

private let blendFactors: [BlendingFactor] = [
  .zero, .one, .srcColor, .oneMinusSrcColor, .dstColor, .oneMinusDstColor, .srcAlpha, .oneMinusSrcAlpha, .dstAlpha, .oneMinusDstAlpha,
  .constantColor, .oneMinusConstantColor, .constantAlpha, .oneMinusConstantAlpha, .srcAlphaSaturate, .src1Color, .oneMinusSrc1Color,
  .src1Alpha, .oneMinusSrc1Alpha,
]
private let blendOps: [BlendOp] = [.add, .subtract, .reverseSubtract, .min, .max]
private let stencilOps: [StencilOp] = [
  .keep, .zero, .replace, .incrementClamp, .decrementClamp, .invert, .incrementWrap, .decrementWrap,
]
private let logicOps: [LogicOp] = [
  .clear, .and, .andReverse, .copy, .andInverted, .noop, .xor, .or, .nor, .equivalent, .invert, .orReverse, .copyInverted, .orInverted,
  .nand, .set,
]

func blendFactor(_ f: VkBlendFactor) -> BlendingFactor? { Int(f.rawValue) < blendFactors.count ? blendFactors[Int(f.rawValue)] : nil }
func blendOperation(_ o: VkBlendOp) -> BlendOp? { Int(o.rawValue) < blendOps.count ? blendOps[Int(o.rawValue)] : nil }
func stencilOperation(_ o: VkStencilOp) -> StencilOp { Int(o.rawValue) < stencilOps.count ? stencilOps[Int(o.rawValue)] : .keep }

func stencilFace(_ s: VkStencilOpState) -> StencilFaceState {
  StencilFaceState(failOp: stencilOperation(s.failOp), passOp: stencilOperation(s.passOp), depthFailOp: stencilOperation(s.depthFailOp),
                   compare: compareOp(s.compareOp), compareMask: s.compareMask, writeMask: s.writeMask, reference: s.reference)
}

/// The core's blend of one attachment: the state as stated, or (where the device has no general blend) source alpha over
/// when only the alpha's source factor is the colour's, which is what a device without general blends has always drawn.
func colorBlend(_ a: VkPipelineColorBlendAttachmentState, general: Bool) -> ColorBlendAttachment? {
  var mask = ColorMask(rawValue: 0)
  if a.colorWriteMask & VK_COLOR_COMPONENT_R_BIT.rawValue != 0 { mask = mask | .red }
  if a.colorWriteMask & VK_COLOR_COMPONENT_G_BIT.rawValue != 0 { mask = mask | .green }
  if a.colorWriteMask & VK_COLOR_COMPONENT_B_BIT.rawValue != 0 { mask = mask | .blue }
  if a.colorWriteMask & VK_COLOR_COMPONENT_A_BIT.rawValue != 0 { mask = mask | .alpha }
  if a.blendEnable == 0 { return ColorBlendAttachment(writeMask: mask) }
  guard let sc = blendFactor(a.srcColorBlendFactor), let dc = blendFactor(a.dstColorBlendFactor), let co = blendOperation(a.colorBlendOp),
    let sa = blendFactor(a.srcAlphaBlendFactor), let da = blendFactor(a.dstAlphaBlendFactor), let ao = blendOperation(a.alphaBlendOp)
  else { return nil }
  var b = ColorBlendAttachment(enabled: true, srcColor: sc, dstColor: dc, colorOp: co, srcAlpha: sa, dstAlpha: da, alphaOp: ao, writeMask: mask)
  if !general && b.srcColor == .srcAlpha && b.dstColor == .oneMinusSrcAlpha && b.colorOp == .add && b.srcAlpha == .srcAlpha
    && b.dstAlpha == .oneMinusSrcAlpha && b.alphaOp == .add && mask == .all
  {
    b = .alphaOver
  }
  return b
}

func primitiveTopology(_ t: VkPrimitiveTopology) -> PrimitiveTopology? {
  if t == VK_PRIMITIVE_TOPOLOGY_POINT_LIST { return .pointList }
  if t == VK_PRIMITIVE_TOPOLOGY_LINE_LIST { return .lineList }
  if t == VK_PRIMITIVE_TOPOLOGY_LINE_STRIP { return .lineStrip }
  if t == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST { return .triangleList }
  if t == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP { return .triangleStrip }
  if t == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN { return .triangleFan }
  if t == VK_PRIMITIVE_TOPOLOGY_PATCH_LIST { return .patchList }
  return nil
}

func core_vkCreateGraphicsPipelines(_ device: VkDevice?, _ pipelineCache: VkPipelineCache?, _ createInfoCount: UInt32,
                                    _ pCreateInfos: UnsafePointer<VkGraphicsPipelineCreateInfo>?,
                                    _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                                    _ pPipelines: UnsafeMutablePointer<VkPipeline?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let infos = unsafe pCreateInfos, let out = unsafe pPipelines else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  var result = VK_SUCCESS
  for i in 0..<Int(createInfoCount) {
    unsafe out[i] = nil
    let r = unsafe makeGraphicsPipeline(d, infos + i, out + i)
    if r != VK_SUCCESS && result == VK_SUCCESS { result = r }
  }
  return result
}

typealias LoweredStage = (module: ShaderModuleObject, entry: String, spec: [SpecConstant])

func makeGraphicsPipeline(_ d: DeviceObject, _ pInfo: UnsafePointer<VkGraphicsPipelineCreateInfo>,
                          _ pOut: UnsafeMutablePointer<VkPipeline?>) -> VkResult
{
  let c = unsafe pInfo.pointee
  guard let layout = unsafe Handle.get(c.layout, PipelineLayoutObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  let features = d.gpu.limits.features

  // The stages: vertex and fragment, and the tessellation and geometry stages where the core has them.
  var vertex: LoweredStage?
  var fragment: LoweredStage?
  var geometry: LoweredStage?
  var tessControl: LoweredStage?
  var tessEval: LoweredStage?
  for k in unsafe 0..<Int(c.stageCount) {
    let s = unsafe c.pStages[k]
    if unsafe s.stage == VK_SHADER_STAGE_VERTEX_BIT { vertex = unsafe stageOf(s) } else if unsafe s.stage == VK_SHADER_STAGE_FRAGMENT_BIT {
      fragment = unsafe stageOf(s)
    } else if unsafe s.stage == VK_SHADER_STAGE_GEOMETRY_BIT { geometry = unsafe stageOf(s) } else if unsafe s.stage
      == VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT
    {
      tessControl = unsafe stageOf(s)
    } else if unsafe s.stage == VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT { tessEval = unsafe stageOf(s) } else {
      say("unsupported: a pipeline stage but vertex, fragment, geometry and tessellation")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
  }
  guard let vertex, let fragment else {
    say("unsupported: a graphics pipeline without both a vertex and a fragment stage")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }

  // The vertex input state becomes the lowering's vertex bindings and attributes.
  var lowering = layout.lowering
  if let vi = unsafe c.pVertexInputState {
    for k in 0..<Int(unsafe vi.pointee.vertexBindingDescriptionCount) {
      let b = unsafe vi.pointee.pVertexBindingDescriptions[k]
      if b.binding >= UInt32(RootBlockLimits.vertexBuffers) || b.stride % 4 != 0 {
        say("unsupported: a vertex binding past \(RootBlockLimits.vertexBuffers) or with a stride that isn't a multiple of 4")
        return VK_ERROR_FEATURE_NOT_PRESENT
      }
      lowering.vertexBindings.append(VertexBinding(binding: b.binding, stride: b.stride,
                                                    perInstance: b.inputRate == VK_VERTEX_INPUT_RATE_INSTANCE))
    }
    for k in 0..<Int(unsafe vi.pointee.vertexAttributeDescriptionCount) {
      let a = unsafe vi.pointee.pVertexAttributeDescriptions[k]
      guard let f = vertexFormat(a.format), a.offset % 4 == 0 else {
        say("unsupported: a vertex attribute of format \(a.format.rawValue) or at an offset that isn't a multiple of 4")
        return VK_ERROR_FEATURE_NOT_PRESENT
      }
      lowering.vertexAttributes.append(VertexAttribute(location: a.location, binding: a.binding, format: f, offset: a.offset))
    }
  }

  // Input assembly and tessellation.
  var topology = PrimitiveTopology.triangleList
  var restart = false
  if let ia = unsafe c.pInputAssemblyState {
    guard let t = unsafe primitiveTopology(ia.pointee.topology) else {
      say("unsupported: a primitive topology of \(unsafe ia.pointee.topology.rawValue)")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    topology = t
    restart = unsafe ia.pointee.primitiveRestartEnable != 0
  }
  var patchPoints: UInt32 = 0
  if topology == .patchList, let ts = unsafe c.pTessellationState { patchPoints = unsafe ts.pointee.patchControlPoints }

  // Rasterization.
  var raster = RasterizationState()
  if let r = unsafe c.pRasterizationState {
    let s = unsafe r.pointee
    raster.cull = unsafe s.cullMode == VK_CULL_MODE_NONE.rawValue ? .none
      : s.cullMode == VK_CULL_MODE_FRONT_BIT.rawValue ? .front : s.cullMode == VK_CULL_MODE_BACK_BIT.rawValue ? .back : .frontAndBack
    raster.frontFace = unsafe s.frontFace == VK_FRONT_FACE_CLOCKWISE ? .clockwise : .counterClockwise
    raster.polygonMode = unsafe s.polygonMode == VK_POLYGON_MODE_FILL ? .fill : s.polygonMode == VK_POLYGON_MODE_LINE ? .line : .point
    raster.depthBias = unsafe s.depthBiasEnable != 0
    raster.depthBiasConstant = unsafe s.depthBiasConstantFactor
    raster.depthBiasClamp = unsafe s.depthBiasClamp
    raster.depthBiasSlope = unsafe s.depthBiasSlopeFactor
    raster.depthClamp = unsafe s.depthClampEnable != 0
    raster.lineWidth = unsafe s.lineWidth
    raster.rasterizerDiscard = unsafe s.rasterizerDiscardEnable != 0
  }

  // Multisampling.
  var multisample = MultisampleState()
  if let ms = unsafe c.pMultisampleState {
    let s = unsafe ms.pointee
    multisample.samples = unsafe s.rasterizationSamples.rawValue
    multisample.alphaToCoverage = unsafe s.alphaToCoverageEnable != 0
    multisample.alphaToOne = unsafe s.alphaToOneEnable != 0
    multisample.sampleShading = unsafe s.sampleShadingEnable != 0
    multisample.minSampleShading = unsafe s.minSampleShading
    if let mask = unsafe s.pSampleMask {
      multisample.sampleMask = unsafe UInt64(mask[0]) | (s.rasterizationSamples.rawValue > 32 ? UInt64(mask[1]) << 32 : 0)
      if multisample.samples < 64 { multisample.sampleMask &= (1 << UInt64(multisample.samples)) - 1 }
    } else if multisample.samples < 64 {
      multisample.sampleMask = (1 << UInt64(multisample.samples)) - 1
    }
  }

  // Dynamic state, and the viewport and scissor a pipeline states.
  var dynamicViewport = false
  var dynamicScissor = false
  var dynamic = DynamicStates()
  if let dy = unsafe c.pDynamicState {
    for k in 0..<Int(unsafe dy.pointee.dynamicStateCount) {
      let s = unsafe dy.pointee.pDynamicStates[k]
      if s == VK_DYNAMIC_STATE_VIEWPORT { dynamicViewport = true } else if s == VK_DYNAMIC_STATE_SCISSOR { dynamicScissor = true } else if s
        == VK_DYNAMIC_STATE_LINE_WIDTH
      {
        dynamic = dynamic | .lineWidth
      } else if s == VK_DYNAMIC_STATE_DEPTH_BIAS { dynamic = dynamic | .depthBias } else if s == VK_DYNAMIC_STATE_BLEND_CONSTANTS {
        dynamic = dynamic | .blendConstants
      } else if s == VK_DYNAMIC_STATE_DEPTH_BOUNDS { dynamic = dynamic | .depthBounds } else if s == VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK {
        dynamic = dynamic | .stencilCompareMask
      } else if s == VK_DYNAMIC_STATE_STENCIL_WRITE_MASK { dynamic = dynamic | .stencilWriteMask } else if s
        == VK_DYNAMIC_STATE_STENCIL_REFERENCE
      {
        dynamic = dynamic | .stencilReference
      } else {
        say("unsupported: the dynamic state \(s.rawValue)")
        return VK_ERROR_FEATURE_NOT_PRESENT
      }
    }
  }
  var viewports: [Viewport]?
  var scissors: [RenderArea]?
  var viewportCount: UInt32 = 1
  if let vs = unsafe c.pViewportState {
    // The core's device refuses more viewports than it has, at creation.
    viewportCount = unsafe max(vs.pointee.viewportCount, 1)
    if !dynamicViewport, let v = unsafe vs.pointee.pViewports {
      viewports = unsafe (0..<Int(vs.pointee.viewportCount)).map { unsafe viewport(v[$0]) }
    }
    if !dynamicScissor, let s = unsafe vs.pointee.pScissors {
      scissors = unsafe (0..<Int(vs.pointee.scissorCount)).map { unsafe renderArea(s[$0]) }
    }
  }

  // The targets: the render pass's subpass, or dynamic rendering's.
  var formats: [PixelFormat] = []
  var depthFormat: PixelFormat?
  var viewMask: UInt32 = 0
  if let pass = unsafe Handle.get(c.renderPass, RenderPassObject.self) {
    guard let t = pass.targets(Int(unsafe c.subpass)) else { return VK_ERROR_INITIALIZATION_FAILED }
    formats = t.colorFormats
    depthFormat = t.depthStencilFormat
    viewMask = t.viewMask
  } else if let ri = unsafe findStructure(c.pNext, VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO) {
    let info = unsafe ri.load(as: VkPipelineRenderingCreateInfo.self)
    viewMask = unsafe info.viewMask
    for k in unsafe 0..<Int(info.colorAttachmentCount) {
      guard let f = pixelFormat(unsafe info.pColorAttachmentFormats[k]) else {
        say("unsupported: a colour attachment of format \(unsafe info.pColorAttachmentFormats[k].rawValue)")
        return VK_ERROR_FORMAT_NOT_SUPPORTED
      }
      formats.append(f)
    }
    if unsafe info.depthAttachmentFormat != VK_FORMAT_UNDEFINED { depthFormat = unsafe pixelFormat(info.depthAttachmentFormat) } else if unsafe info
      .stencilAttachmentFormat != VK_FORMAT_UNDEFINED
    {
      depthFormat = unsafe pixelFormat(info.stencilAttachmentFormat)
    }
  } else { return VK_ERROR_INITIALIZATION_FAILED }

  // Depth and stencil: only where the pass has the attachment.
  var depthStencil = DepthStencilState()
  if depthFormat != nil, let ds = unsafe c.pDepthStencilState {
    let s = unsafe ds.pointee
    depthStencil = unsafe DepthStencilState(
      depthTest: s.depthTestEnable != 0, depthWrite: s.depthWriteEnable != 0, depthCompare: compareOp(s.depthCompareOp),
      depthBoundsTest: s.depthBoundsTestEnable != 0, minDepthBounds: s.minDepthBounds, maxDepthBounds: s.maxDepthBounds,
      stencilTest: s.stencilTestEnable != 0, front: stencilFace(s.front), back: stencilFace(s.back))
  }

  // Blend: each attachment's, the logic op and the constants.
  var blends: [ColorBlendAttachment]?
  var logic: LogicOp?
  var constants = BlendConstants()
  if let cb = unsafe c.pColorBlendState {
    if unsafe cb.pointee.logicOpEnable != 0 { logic = unsafe Int(cb.pointee.logicOp.rawValue) < logicOps.count ? logicOps[Int(cb.pointee.logicOp.rawValue)] : .copy }
    var list: [ColorBlendAttachment] = []
    for k in 0..<Int(unsafe cb.pointee.attachmentCount) {
      guard let b = unsafe colorBlend(cb.pointee.pAttachments[k], general: features.generalBlend) else {
        say("unsupported: a blend factor or operation")
        return VK_ERROR_FEATURE_NOT_PRESENT
      }
      list.append(b)
    }
    blends = list.isEmpty ? nil : list
    let k = unsafe cb.pointee.blendConstants
    constants = BlendConstants(red: k.0, green: k.1, blue: k.2, alpha: k.3)
  }

  // The stages, lowered. The fragment stage reads no vertex input.
  do throws(LoweringError) {
    let v = try lowerStage(vertex.module, .vertex, vertex.entry, lowering, vertex.spec)
    var forLater = lowering
    forLater.vertexBindings = []
    forLater.vertexAttributes = []
    let f = try lowerStage(fragment.module, .fragment, fragment.entry, forLater, fragment.spec)
    var g: [UInt8]?
    var tc: [UInt8]?
    var te: [UInt8]?
    if let geometry { g = try lowerStage(geometry.module, .geometry, geometry.entry, forLater, geometry.spec) }
    if let tessControl { tc = try lowerStage(tessControl.module, .tessellationControl, tessControl.entry, forLater, tessControl.spec) }
    if let tessEval { te = try lowerStage(tessEval.module, .tessellationEvaluation, tessEval.entry, forLater, tessEval.spec) }
    var descriptor = GraphicsPipelineDescriptor(
      vertex: v, fragment: f, colorFormats: formats, blend: .opaque, topology: topology, depthStencilFormat: depthFormat,
      depthStencil: depthStencil, rasterization: raster, multisample: multisample, attachmentBlends: blends, logicOp: logic,
      blendConstants: constants, dynamic: dynamic, primitiveRestart: restart, patchControlPoints: patchPoints, geometry: g,
      tessellationControl: tc, tessellationEvaluation: te, viewMask: viewMask, viewportCount: viewportCount)
    // One attachment's blend states every attachment, as Vulkan's own count does for all but a pipeline of one.
    if let b = descriptor.attachmentBlends, b.count != formats.count && b.count != 1 { descriptor.attachmentBlends = nil }
    do throws(GPUError) {
      let p = try d.gpu.makeGraphicsPipeline(descriptor)
      let o = PipelineObject(gpu: p, layout: layout, device: d)
      o.viewports = viewports
      o.scissors = scissors
      o.viewportCount = viewportCount
      o.dynamic = dynamic
      o.depthStencil = depthStencil
      unsafe pOut.pointee = Handle.make(o)
    } catch { return vkResult(error) }
  } catch { return vkResult(error) }
  return VK_SUCCESS
}

func core_vkDestroyPipeline(_ device: VkDevice?, _ pipeline: VkPipeline?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let p = unsafe Handle.get(pipeline, PipelineObject.self) else { return }
  p.device.gpu.destroy(p.gpu)
  unsafe Handle.destroy(pipeline)
}
