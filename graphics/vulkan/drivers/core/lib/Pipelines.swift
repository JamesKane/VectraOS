// SPDX-License-Identifier: BSD-3-Clause

// Shader modules, pipelines, render passes and framebuffers (D174 step 5, part 3). A pipeline is made by running
// each stage through the lowering against the pipeline layout (and, for the vertex stage, the vertex input
// state) and handing the result to the core. What the core's pipeline can't say is refused here, at creation:
// culling, depth and stencil, blend but off or source-alpha over, more than one sample. Specialization constants are
// the lowering's: each stage is lowered with its stage's VkSpecializationInfo.
// A render pass of one subpass with colour attachments only, or dynamic rendering, is the core's `RenderingInfo`.

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

// MARK: Render passes and framebuffers

struct PassAttachment {
  var format: PixelFormat
  var load: VkAttachmentLoadOp
  var store: StoreAction
}

final class RenderPassObject: CoreObject {
  let attachments: [PassAttachment]
  /// The one subpass's colour attachments, as indices into `attachments`.
  let colors: [Int]
  init(attachments: [PassAttachment], colors: [Int]) {
    self.attachments = attachments
    self.colors = colors
  }
  var colorFormats: [PixelFormat] { colors.map { attachments[$0].format } }
}

func attachmentStore(_ op: VkAttachmentStoreOp) -> StoreAction { op == VK_ATTACHMENT_STORE_OP_STORE ? .store : .discard }

func makeRenderPass(_ attachments: [PassAttachment], colors: [UInt32]) -> RenderPassObject? {
  var c: [Int] = []
  for a in colors {
    if a == ~0 || Int(a) >= attachments.count {
      say("unsupported: a subpass attachment that is unused or out of range")
      return nil
    }
    c.append(Int(a))
  }
  return RenderPassObject(attachments: attachments, colors: c)
}

func core_vkCreateRenderPass(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkRenderPassCreateInfo>?,
                             _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                             _ pRenderPass: UnsafeMutablePointer<VkRenderPass?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pRenderPass else { return VK_ERROR_INITIALIZATION_FAILED }
  guard unsafe info.pointee.subpassCount == 1 else {
    say("unsupported: a render pass of \(unsafe info.pointee.subpassCount) subpasses")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  var attachments: [PassAttachment] = []
  for i in 0..<Int(unsafe info.pointee.attachmentCount) {
    let a = unsafe info.pointee.pAttachments[i]
    guard let f = pixelFormat(a.format), a.samples == VK_SAMPLE_COUNT_1_BIT else {
      say("unsupported: a render pass attachment of format \(a.format.rawValue) or with samples")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    attachments.append(PassAttachment(format: f, load: a.loadOp, store: attachmentStore(a.storeOp)))
  }
  let s = unsafe info.pointee.pSubpasses[0]
  guard unsafe s.pipelineBindPoint == VK_PIPELINE_BIND_POINT_GRAPHICS, unsafe s.inputAttachmentCount == 0, unsafe s.pResolveAttachments == nil,
    unsafe s.pDepthStencilAttachment == nil
  else {
    say("unsupported: a subpass with input, resolve or depth and stencil attachments")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  var colors: [UInt32] = []
  for i in unsafe 0..<Int(s.colorAttachmentCount) { colors.append(unsafe s.pColorAttachments[i].attachment) }
  guard let pass = makeRenderPass(attachments, colors: colors) else { return VK_ERROR_FEATURE_NOT_PRESENT }
  unsafe out.pointee = Handle.make(pass)
  return VK_SUCCESS
}

func core_vkCreateRenderPass2(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkRenderPassCreateInfo2>?,
                              _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                              _ pRenderPass: UnsafeMutablePointer<VkRenderPass?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pRenderPass else { return VK_ERROR_INITIALIZATION_FAILED }
  guard unsafe info.pointee.subpassCount == 1 else {
    say("unsupported: a render pass of \(unsafe info.pointee.subpassCount) subpasses")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  var attachments: [PassAttachment] = []
  for i in 0..<Int(unsafe info.pointee.attachmentCount) {
    let a = unsafe info.pointee.pAttachments[i]
    guard let f = unsafe pixelFormat(a.format), unsafe a.samples == VK_SAMPLE_COUNT_1_BIT else {
      say(unsafe "unsupported: a render pass attachment of format \(a.format.rawValue) or with samples")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    unsafe attachments.append(PassAttachment(format: f, load: a.loadOp, store: attachmentStore(a.storeOp)))
  }
  let s = unsafe info.pointee.pSubpasses[0]
  guard unsafe s.pipelineBindPoint == VK_PIPELINE_BIND_POINT_GRAPHICS, unsafe s.inputAttachmentCount == 0, unsafe s.pResolveAttachments == nil,
    unsafe s.pDepthStencilAttachment == nil, unsafe s.viewMask == 0
  else {
    say("unsupported: a subpass with input, resolve or depth and stencil attachments, or a view mask")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  var colors: [UInt32] = []
  for i in unsafe 0..<Int(s.colorAttachmentCount) { colors.append(unsafe s.pColorAttachments[i].attachment) }
  guard let pass = makeRenderPass(attachments, colors: colors) else { return VK_ERROR_FEATURE_NOT_PRESENT }
  unsafe out.pointee = Handle.make(pass)
  return VK_SUCCESS
}

func core_vkDestroyRenderPass(_ device: VkDevice?, _ renderPass: VkRenderPass?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(renderPass)
}

final class FramebufferObject: CoreObject {
  let views: [ImageViewObject]
  let width: UInt32
  let height: UInt32
  init(views: [ImageViewObject], width: UInt32, height: UInt32) {
    self.views = views
    self.width = width
    self.height = height
  }
}

func core_vkCreateFramebuffer(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkFramebufferCreateInfo>?,
                              _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                              _ pFramebuffer: UnsafeMutablePointer<VkFramebuffer?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pFramebuffer else { return VK_ERROR_INITIALIZATION_FAILED }
  guard unsafe info.pointee.flags == 0, unsafe info.pointee.layers == 1 else {
    say("unsupported: an imageless or layered framebuffer")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  var views: [ImageViewObject] = []
  for i in 0..<Int(unsafe info.pointee.attachmentCount) {
    guard let v = unsafe Handle.get(info.pointee.pAttachments[i], ImageViewObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
    views.append(v)
  }
  unsafe out.pointee = Handle.make(FramebufferObject(views: views, width: unsafe info.pointee.width, height: unsafe info.pointee.height))
  return VK_SUCCESS
}

func core_vkDestroyFramebuffer(_ device: VkDevice?, _ framebuffer: VkFramebuffer?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(framebuffer)
}

// MARK: Pipelines

final class PipelineObject: CoreObject {
  let gpu: GPUPipeline
  let layout: PipelineLayoutObject?
  let device: DeviceObject
  /// The viewport and scissor a pipeline states (x, y, width, height), nil where they are dynamic.
  var viewport: (Float, Float, Float, Float)?
  var scissor: (Int32, Int32, UInt32, UInt32)?
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

func isBlendFactor(_ f: VkBlendFactor, _ names: [VkBlendFactor]) -> Bool { names.contains { $0 == f } }

/// The core's blend for one attachment's state, or nil with the reason said.
func blendMode(_ a: VkPipelineColorBlendAttachmentState) -> BlendMode? {
  let rgba = VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue | VK_COLOR_COMPONENT_B_BIT.rawValue
    | VK_COLOR_COMPONENT_A_BIT.rawValue
  if a.colorWriteMask != rgba {
    say("unsupported: a colour write mask but all four channels")
    return nil
  }
  if a.blendEnable == 0 { return .opaque }
  let colorOver = a.srcColorBlendFactor == VK_BLEND_FACTOR_SRC_ALPHA && a.dstColorBlendFactor == VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
    && a.colorBlendOp == VK_BLEND_OP_ADD
  let alphaOver = isBlendFactor(a.srcAlphaBlendFactor, [VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_SRC_ALPHA])
    && a.dstAlphaBlendFactor == VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA && a.alphaBlendOp == VK_BLEND_OP_ADD
  if colorOver && alphaOver { return .alpha }
  say("unsupported: a blend but source alpha over")
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

func makeGraphicsPipeline(_ d: DeviceObject, _ pInfo: UnsafePointer<VkGraphicsPipelineCreateInfo>,
                          _ pOut: UnsafeMutablePointer<VkPipeline?>) -> VkResult
{
  let c = unsafe pInfo.pointee
  guard let layout = unsafe Handle.get(c.layout, PipelineLayoutObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }

  // The stages: a vertex and a fragment shader, as the core has them.
  var vertex: (module: ShaderModuleObject, entry: String, spec: [SpecConstant])?
  var fragment: (module: ShaderModuleObject, entry: String, spec: [SpecConstant])?
  for k in unsafe 0..<Int(c.stageCount) {
    let s = unsafe c.pStages[k]
    if unsafe s.stage == VK_SHADER_STAGE_VERTEX_BIT { vertex = unsafe stageOf(s) } else if unsafe s.stage == VK_SHADER_STAGE_FRAGMENT_BIT {
      fragment = unsafe stageOf(s)
    } else {
      say("unsupported: a pipeline stage but vertex and fragment")
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
      if b.binding >= UInt32(RootBlock.maxVertexBuffers) || b.stride % 4 != 0 {
        say("unsupported: a vertex binding past \(RootBlock.maxVertexBuffers) or with a stride that isn't a multiple of 4")
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

  // Input assembly.
  let topology: PrimitiveTopology
  if let ia = unsafe c.pInputAssemblyState {
    let t = unsafe ia.pointee.topology
    if t == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST { topology = .triangleList } else if t == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP {
      topology = .triangleStrip
    } else if t == VK_PRIMITIVE_TOPOLOGY_LINE_LIST { topology = .lineList } else if t == VK_PRIMITIVE_TOPOLOGY_POINT_LIST {
      topology = .pointList
    } else {
      say("unsupported: a primitive topology of \(t.rawValue)")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    if unsafe ia.pointee.primitiveRestartEnable != 0 {
      say("unsupported: primitive restart")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
  } else { topology = .triangleList }

  // Rasterization: filled, uncut, uncalled.
  guard let rs = unsafe c.pRasterizationState else { return VK_ERROR_INITIALIZATION_FAILED }
  let r = unsafe rs.pointee
  if unsafe r.polygonMode != VK_POLYGON_MODE_FILL || r.cullMode != 0 || r.rasterizerDiscardEnable != 0 || r.depthBiasEnable != 0 {
    say("unsupported: culling, a polygon mode but fill, rasterizer discard or depth bias")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  if let ds = unsafe c.pDepthStencilState {
    let s = unsafe ds.pointee
    if unsafe s.depthTestEnable != 0 || s.depthWriteEnable != 0 || s.stencilTestEnable != 0 || s.depthBoundsTestEnable != 0 {
      say("unsupported: depth and stencil")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
  }
  if let ms = unsafe c.pMultisampleState {
    let s = unsafe ms.pointee
    if unsafe s.rasterizationSamples != VK_SAMPLE_COUNT_1_BIT || s.sampleShadingEnable != 0 || s.alphaToCoverageEnable != 0
      || s.alphaToOneEnable != 0
    {
      say("unsupported: more than one sample")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
  }

  // Dynamic state, and the viewport and scissor a pipeline states.
  var dynamicViewport = false
  var dynamicScissor = false
  if let dy = unsafe c.pDynamicState {
    for k in 0..<Int(unsafe dy.pointee.dynamicStateCount) {
      let s = unsafe dy.pointee.pDynamicStates[k]
      if s == VK_DYNAMIC_STATE_VIEWPORT { dynamicViewport = true }
      if s == VK_DYNAMIC_STATE_SCISSOR { dynamicScissor = true }
    }
  }
  var viewport: (Float, Float, Float, Float)?
  var scissor: (Int32, Int32, UInt32, UInt32)?
  if let vs = unsafe c.pViewportState {
    if unsafe vs.pointee.viewportCount > 1 || vs.pointee.scissorCount > 1 {
      say("unsupported: more than one viewport")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    if !dynamicViewport, let v = unsafe vs.pointee.pViewports { viewport = unsafe (v[0].x, v[0].y, v[0].width, v[0].height) }
    if !dynamicScissor, let s = unsafe vs.pointee.pScissors {
      scissor = unsafe (s[0].offset.x, s[0].offset.y, s[0].extent.width, s[0].extent.height)
    }
  }

  // The colour targets: the render pass's, or dynamic rendering's.
  var formats: [PixelFormat] = []
  if let pass = unsafe Handle.get(c.renderPass, RenderPassObject.self) {
    formats = pass.colorFormats
  } else if let ri = unsafe findStructure(c.pNext, VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO) {
    let info = unsafe ri.load(as: VkPipelineRenderingCreateInfo.self)
    if unsafe info.viewMask != 0 || info.depthAttachmentFormat != VK_FORMAT_UNDEFINED || info.stencilAttachmentFormat != VK_FORMAT_UNDEFINED {
      say("unsupported: a view mask, or a depth or stencil attachment")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    for k in unsafe 0..<Int(info.colorAttachmentCount) {
      guard let f = pixelFormat(unsafe info.pColorAttachmentFormats[k]) else {
        say("unsupported: a colour attachment of format \(unsafe info.pColorAttachmentFormats[k].rawValue)")
        return VK_ERROR_FEATURE_NOT_PRESENT
      }
      formats.append(f)
    }
  } else { return VK_ERROR_INITIALIZATION_FAILED }

  // Blend: every attachment alike, off or source alpha over.
  var blend = BlendMode.opaque
  if let cb = unsafe c.pColorBlendState {
    if unsafe cb.pointee.logicOpEnable != 0 {
      say("unsupported: logic ops")
      return VK_ERROR_FEATURE_NOT_PRESENT
    }
    for k in 0..<Int(unsafe cb.pointee.attachmentCount) {
      guard let m = blendMode(unsafe cb.pointee.pAttachments[k]) else { return VK_ERROR_FEATURE_NOT_PRESENT }
      if k == 0 { blend = m } else if m != blend {
        say("unsupported: attachments with different blends")
        return VK_ERROR_FEATURE_NOT_PRESENT
      }
    }
  }

  // The stages, lowered. The fragment stage reads no vertex input.
  do throws(LoweringError) {
    let v = try lowerStage(vertex.module, .vertex, vertex.entry, lowering, vertex.spec)
    var forFragment = lowering
    forFragment.vertexBindings = []
    forFragment.vertexAttributes = []
    let f = try lowerStage(fragment.module, .fragment, fragment.entry, forFragment, fragment.spec)
    do throws(GPUError) {
      let p = try d.gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(vertex: v, fragment: f, colorFormats: formats, blend: blend,
                                                                         topology: topology))
      let o = PipelineObject(gpu: p, layout: layout, device: d)
      o.viewport = viewport
      o.scissor = scissor
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
