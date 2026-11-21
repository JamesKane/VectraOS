// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan backend's pipelines: graphics from a vertex and a fragment shader (and the geometry and tessellation
// stages, where the device has them), reading everything through the root pointer and the heap, with the fixed
// state the descriptor names; and compute, from one SPIR-V module. Every one uses the device's one pipeline layout.

import GPUCore
import Vulkan

/// Memory for the structures a create call points at, freed with it.
@safe final class Scratch {
  private var blocks: [UnsafeMutableRawPointer] = unsafe []

  func make<T>(_ value: T) -> UnsafeMutablePointer<T> {
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
    unsafe p.initialize(to: value)
    unsafe blocks.append(UnsafeMutableRawPointer(p))
    return unsafe p
  }

  func array<T>(_ values: [T]) -> UnsafeMutablePointer<T>? {
    if values.isEmpty { return nil }
    let p = UnsafeMutablePointer<T>.allocate(capacity: values.count)
    unsafe p.initialize(from: values, count: values.count)
    unsafe blocks.append(UnsafeMutableRawPointer(p))
    return unsafe p
  }

  deinit { for unsafe b in unsafe blocks { unsafe b.deallocate() } }
}

extension VulkanDevice {
  @safe func shaderModule(_ code: [UInt8]) throws(GPUError) -> VkShaderModule {
    guard code.count % 4 == 0, code.count >= 20 else { throw .invalid("not SPIR-V (\(code.count) bytes)") }
    var m: VkShaderModule?
    let c = vk.commands
    let r: VkResult = code.withUnsafeBytes { bytes in
      var info = unsafe VkShaderModuleCreateInfo()
      unsafe info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
      unsafe info.codeSize = code.count
      unsafe info.pCode = unsafe bytes.baseAddress!.assumingMemoryBound(to: UInt32.self)
      return unsafe c.vkCreateShaderModule!(device, &info, nil, &m)
    }
    try vkCheck(r, "vkCreateShaderModule")
    return unsafe m!
  }

  /// The specialization of a stage: each constant's value, as the 32 bits its id names.
  private func specialization(_ constants: [SpecializationConstant], _ s: Scratch) -> UnsafePointer<VkSpecializationInfo>? {
    if constants.isEmpty { return nil }
    var entries: [VkSpecializationMapEntry] = []
    var data: [UInt32] = []
    for k in constants {
      // A value with bits past the 32nd is a 64-bit constant (the core's value is 64 bits and doesn't say); the rest are 32.
      let wide = k.value >> 32 != 0
      entries.append(VkSpecializationMapEntry(constantID: k.id, offset: UInt32(data.count * 4), size: wide ? 8 : 4))
      data.append(UInt32(truncatingIfNeeded: k.value))
      if wide { data.append(UInt32(truncatingIfNeeded: k.value >> 32)) }
    }
    var info = unsafe VkSpecializationInfo()
    unsafe info.mapEntryCount = UInt32(entries.count)
    unsafe info.pMapEntries = unsafe UnsafePointer(s.array(entries))
    unsafe info.dataSize = data.count * 4
    unsafe info.pData = unsafe UnsafeRawPointer(s.array(data))
    return unsafe UnsafePointer(s.make(info))
  }

  /// A graphics pipeline from SPIR-V: vertex and fragment shaders reading their inputs through the root pointer
  /// and the heap, drawing into the colour targets with the state the descriptor names.
  public func makeGraphicsPipeline(_ descriptor: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
    let c = vk.commands
    if let e = descriptor.check(limits: limits) { throw e }
    let s = Scratch()
    var modules: [VkShaderModule] = unsafe []
    func destroyModules() { for unsafe m in unsafe modules { unsafe c.vkDestroyShaderModule!(device, m, nil) } }
    defer { destroyModules() }

    // The stages.
    var stageCode: [(VkShaderStageFlagBits, [UInt8])] = [(VK_SHADER_STAGE_VERTEX_BIT, descriptor.vertex)]
    if let t = descriptor.tessellationControl { stageCode.append((VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, t)) }
    if let t = descriptor.tessellationEvaluation { stageCode.append((VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT, t)) }
    if let g = descriptor.geometry { stageCode.append((VK_SHADER_STAGE_GEOMETRY_BIT, g)) }
    stageCode.append((VK_SHADER_STAGE_FRAGMENT_BIT, descriptor.fragment))
    let entry = unsafe s.array(Array("main".utf8CString))
    let specialized = unsafe specialization(descriptor.specialization, s)
    var stages: [VkPipelineShaderStageCreateInfo] = unsafe []
    for (stage, code) in stageCode {
      let m = try shaderModule(code)
      unsafe modules.append(unsafe m)
      var info = unsafe VkPipelineShaderStageCreateInfo()
      unsafe info.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
      unsafe info.stage = stage
      unsafe info.module = unsafe m
      unsafe info.pName = unsafe UnsafePointer(entry)
      unsafe info.pSpecializationInfo = unsafe specialized
      unsafe stages.append(unsafe info)
    }

    var vertexInput = unsafe VkPipelineVertexInputStateCreateInfo()
    unsafe vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
    var assembly = unsafe VkPipelineInputAssemblyStateCreateInfo()
    unsafe assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
    unsafe assembly.topology = descriptor.topology.vk
    unsafe assembly.primitiveRestartEnable = descriptor.primitiveRestart ? 1 : 0
    var tessellation = unsafe VkPipelineTessellationStateCreateInfo()
    unsafe tessellation.sType = VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO
    unsafe tessellation.patchControlPoints = descriptor.patchControlPoints
    var viewport = unsafe VkPipelineViewportStateCreateInfo()
    unsafe viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
    unsafe viewport.viewportCount = 1
    unsafe viewport.scissorCount = 1

    let r = descriptor.rasterization
    var raster = unsafe VkPipelineRasterizationStateCreateInfo()
    unsafe raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
    unsafe raster.depthClampEnable = r.depthClamp ? 1 : 0
    unsafe raster.rasterizerDiscardEnable = r.rasterizerDiscard ? 1 : 0
    switch r.polygonMode {
    case .fill: unsafe raster.polygonMode = VK_POLYGON_MODE_FILL
    case .line: unsafe raster.polygonMode = VK_POLYGON_MODE_LINE
    case .point: unsafe raster.polygonMode = VK_POLYGON_MODE_POINT
    }
    switch r.cull {
    case .none: unsafe raster.cullMode = VK_CULL_MODE_NONE.rawValue
    case .front: unsafe raster.cullMode = VK_CULL_MODE_FRONT_BIT.rawValue
    case .back: unsafe raster.cullMode = VK_CULL_MODE_BACK_BIT.rawValue
    case .frontAndBack: unsafe raster.cullMode = VK_CULL_MODE_FRONT_AND_BACK.rawValue
    }
    unsafe raster.frontFace = r.frontFace == .clockwise ? VK_FRONT_FACE_CLOCKWISE : VK_FRONT_FACE_COUNTER_CLOCKWISE
    unsafe raster.depthBiasEnable = r.depthBias ? 1 : 0
    unsafe raster.depthBiasConstantFactor = r.depthBiasConstant
    unsafe raster.depthBiasClamp = r.depthBiasClamp
    unsafe raster.depthBiasSlopeFactor = r.depthBiasSlope
    unsafe raster.lineWidth = r.lineWidth

    let m = descriptor.multisample
    // One 32-bit word of the mask for each 32 samples.
    let maskWords: [UInt32] = m.samples > 32 ? [UInt32(truncatingIfNeeded: m.sampleMask), UInt32(truncatingIfNeeded: m.sampleMask >> 32)]
      : [UInt32(truncatingIfNeeded: m.sampleMask)]
    var multisample = unsafe VkPipelineMultisampleStateCreateInfo()
    unsafe multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
    unsafe multisample.rasterizationSamples = vkSamples(m.samples)
    unsafe multisample.sampleShadingEnable = m.sampleShading ? 1 : 0
    unsafe multisample.minSampleShading = m.minSampleShading
    unsafe multisample.pSampleMask = unsafe UnsafePointer(s.array(maskWords))
    unsafe multisample.alphaToCoverageEnable = m.alphaToCoverage ? 1 : 0
    unsafe multisample.alphaToOneEnable = m.alphaToOne ? 1 : 0

    let ds = descriptor.depthStencil
    var depthStencil = unsafe VkPipelineDepthStencilStateCreateInfo()
    unsafe depthStencil.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
    unsafe depthStencil.depthTestEnable = ds.depthTest ? 1 : 0
    unsafe depthStencil.depthWriteEnable = ds.depthWrite ? 1 : 0
    unsafe depthStencil.depthCompareOp = ds.depthCompare.vk
    unsafe depthStencil.depthBoundsTestEnable = ds.depthBoundsTest ? 1 : 0
    unsafe depthStencil.stencilTestEnable = ds.stencilTest ? 1 : 0
    unsafe depthStencil.front = ds.front.vk
    unsafe depthStencil.back = ds.back.vk
    unsafe depthStencil.minDepthBounds = ds.minDepthBounds
    unsafe depthStencil.maxDepthBounds = ds.maxDepthBounds

    var attachments: [VkPipelineColorBlendAttachmentState] = []
    for b in descriptor.effectiveBlends {
      var a = VkPipelineColorBlendAttachmentState()
      a.blendEnable = b.enabled ? 1 : 0
      a.srcColorBlendFactor = b.srcColor.vk
      a.dstColorBlendFactor = b.dstColor.vk
      a.colorBlendOp = b.colorOp.vk
      a.srcAlphaBlendFactor = b.srcAlpha.vk
      a.dstAlphaBlendFactor = b.dstAlpha.vk
      a.alphaBlendOp = b.alphaOp.vk
      a.colorWriteMask = UInt32(b.writeMask.rawValue)
      attachments.append(a)
    }
    var blend = unsafe VkPipelineColorBlendStateCreateInfo()
    unsafe blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
    if let op = descriptor.logicOp {
      unsafe blend.logicOpEnable = 1
      unsafe blend.logicOp = op.vk
    }
    unsafe blend.attachmentCount = UInt32(attachments.count)
    unsafe blend.pAttachments = unsafe UnsafePointer(s.array(attachments))
    let k = descriptor.blendConstants
    unsafe blend.blendConstants = (k.red, k.green, k.blue, k.alpha)

    var dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
    let d = descriptor.dynamic
    if d.contains(.blendConstants) { dynamicStates.append(VK_DYNAMIC_STATE_BLEND_CONSTANTS) }
    if d.contains(.stencilReference) { dynamicStates.append(VK_DYNAMIC_STATE_STENCIL_REFERENCE) }
    if d.contains(.stencilCompareMask) { dynamicStates.append(VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK) }
    if d.contains(.stencilWriteMask) { dynamicStates.append(VK_DYNAMIC_STATE_STENCIL_WRITE_MASK) }
    if d.contains(.depthBias) { dynamicStates.append(VK_DYNAMIC_STATE_DEPTH_BIAS) }
    if d.contains(.depthBounds) { dynamicStates.append(VK_DYNAMIC_STATE_DEPTH_BOUNDS) }
    if d.contains(.lineWidth) { dynamicStates.append(VK_DYNAMIC_STATE_LINE_WIDTH) }
    var dynamic = unsafe VkPipelineDynamicStateCreateInfo()
    unsafe dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
    unsafe dynamic.dynamicStateCount = UInt32(dynamicStates.count)
    unsafe dynamic.pDynamicStates = unsafe UnsafePointer(s.array(dynamicStates))

    let formats = descriptor.colorFormats.map { $0.vk }
    var rendering = unsafe VkPipelineRenderingCreateInfo()
    unsafe rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO
    unsafe rendering.viewMask = descriptor.viewMask
    unsafe rendering.colorAttachmentCount = UInt32(formats.count)
    unsafe rendering.pColorAttachmentFormats = unsafe UnsafePointer(s.array(formats))
    if let f = descriptor.depthStencilFormat {
      if f.hasDepth { unsafe rendering.depthAttachmentFormat = f.vk }
      if f.hasStencil { unsafe rendering.stencilAttachmentFormat = f.vk }
    }

    var info = unsafe VkGraphicsPipelineCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
    unsafe info.pNext = unsafe UnsafeRawPointer(s.make(rendering))
    unsafe info.stageCount = UInt32(stages.count)
    unsafe info.pStages = unsafe UnsafePointer(s.array(stages))
    unsafe info.pVertexInputState = unsafe UnsafePointer(s.make(vertexInput))
    unsafe info.pInputAssemblyState = unsafe UnsafePointer(s.make(assembly))
    if descriptor.topology == .patchList { unsafe info.pTessellationState = unsafe UnsafePointer(s.make(tessellation)) }
    unsafe info.pViewportState = unsafe UnsafePointer(s.make(viewport))
    unsafe info.pRasterizationState = unsafe UnsafePointer(s.make(raster))
    unsafe info.pMultisampleState = unsafe UnsafePointer(s.make(multisample))
    unsafe info.pDepthStencilState = unsafe UnsafePointer(s.make(depthStencil))
    unsafe info.pColorBlendState = unsafe UnsafePointer(s.make(blend))
    unsafe info.pDynamicState = unsafe UnsafePointer(s.make(dynamic))
    unsafe info.layout = pipelineLayout
    var pipeline: VkPipeline?
    let result = unsafe c.vkCreateGraphicsPipelines!(device, nil, 1, &info, nil, &pipeline)
    try vkCheck(result, "vkCreateGraphicsPipelines")
    return GPUPipeline(handle: pipelines.insert(unsafe PipelineRecord(pipeline!)), kind: .graphics, targets: descriptor.targets)
  }

  public func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline {
    try makeComputePipeline(spirv: spirv, specialization: [])
  }

  public func makeComputePipeline(spirv: [UInt8], specialization constants: [SpecializationConstant]) throws(GPUError) -> GPUPipeline {
    let c = vk.commands
    if !constants.isEmpty && !limits.features.specializationConstants { throw .unsupported("specialization constants") }
    let module = try shaderModule(spirv)
    defer { unsafe c.vkDestroyShaderModule!(device, module, nil) }
    let s = Scratch()
    let entry = unsafe s.array(Array("main".utf8CString))
    var pipeline: VkPipeline?
    var info = unsafe VkComputePipelineCreateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
    unsafe info.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
    unsafe info.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT
    unsafe info.stage.module = unsafe module
    unsafe info.stage.pName = unsafe UnsafePointer(entry)
    unsafe info.stage.pSpecializationInfo = unsafe specialization(constants, s)
    unsafe info.layout = pipelineLayout
    let r = unsafe c.vkCreateComputePipelines!(device, nil, 1, &info, nil, &pipeline)
    try vkCheck(r, "vkCreateComputePipelines")
    return GPUPipeline(handle: pipelines.insert(unsafe PipelineRecord(pipeline!)), kind: .compute)
  }

  public func destroy(_ pipeline: GPUPipeline) {
    guard let p = pipelines.remove(pipeline.handle) else { return }
    retire(.pipeline(p))
  }
}
