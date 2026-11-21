// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan backend's pipelines: graphics from a vertex and a fragment
// shader, reading everything through the root pointer and the heap, drawing
// triangles into colour targets with the blend the descriptor names; and
// compute, from one SPIR-V module. Every one uses the device's one pipeline
// layout.

import GPUCore
import Vulkan

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

  /// A graphics pipeline from SPIR-V: vertex and fragment shaders reading their inputs through the root pointer
  /// and the heap, drawing into the colour targets with the blend the descriptor names.
  public func makeGraphicsPipeline(_ descriptor: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
    let c = vk.commands
    if let e = descriptor.check(limits: limits) { throw e }
    guard !descriptor.colorFormats.isEmpty, descriptor.colorFormats.count <= 8 else {
      throw .invalid("a pipeline with \(descriptor.colorFormats.count) colour targets")
    }
    let vs = try shaderModule(descriptor.vertex)
    let fs: VkShaderModule
    do { unsafe fs = try shaderModule(descriptor.fragment) } catch {
      unsafe c.vkDestroyShaderModule!(device, vs, nil)
      throw error
    }
    defer {
      unsafe c.vkDestroyShaderModule!(device, vs, nil)
      unsafe c.vkDestroyShaderModule!(device, fs, nil)
    }
    var pipeline: VkPipeline?
    var formats = descriptor.colorFormats.map { $0.vk }
    let topology: VkPrimitiveTopology = switch descriptor.topology {
    case .triangleList: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    case .triangleStrip: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
    case .lineList: VK_PRIMITIVE_TOPOLOGY_LINE_LIST
    case .pointList: VK_PRIMITIVE_TOPOLOGY_POINT_LIST
    default: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST  // never reached: `check` refuses them
    }
    var attachment = VkPipelineColorBlendAttachmentState()
    if descriptor.blend == .alpha {
      attachment.blendEnable = 1
      attachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA
      attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
      attachment.colorBlendOp = VK_BLEND_OP_ADD
      attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
      attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
      attachment.alphaBlendOp = VK_BLEND_OP_ADD
    }
    attachment.colorWriteMask = 0xf
    var attachments = [VkPipelineColorBlendAttachmentState](repeating: attachment, count: formats.count)
    let r: VkResult = "main".withCString { entry in
      var stages = unsafe [VkPipelineShaderStageCreateInfo](repeating: VkPipelineShaderStageCreateInfo(), count: 2)
      for unsafe (i, (stage, m)) in unsafe [(VK_SHADER_STAGE_VERTEX_BIT, vs), (VK_SHADER_STAGE_FRAGMENT_BIT, fs)].enumerated() {
        unsafe stages[i].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        unsafe stages[i].stage = stage
        unsafe stages[i].module = unsafe m
        unsafe stages[i].pName = unsafe entry
      }
      var vertexInput = unsafe VkPipelineVertexInputStateCreateInfo()
      unsafe vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
      var assembly = unsafe VkPipelineInputAssemblyStateCreateInfo()
      unsafe assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
      unsafe assembly.topology = topology
      var viewport = unsafe VkPipelineViewportStateCreateInfo()
      unsafe viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
      unsafe viewport.viewportCount = 1
      unsafe viewport.scissorCount = 1
      var raster = unsafe VkPipelineRasterizationStateCreateInfo()
      unsafe raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
      unsafe raster.polygonMode = VK_POLYGON_MODE_FILL
      unsafe raster.cullMode = VK_CULL_MODE_NONE.rawValue
      unsafe raster.lineWidth = 1
      var multisample = unsafe VkPipelineMultisampleStateCreateInfo()
      unsafe multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
      unsafe multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
      var dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
      return attachments.withUnsafeMutableBufferPointer { ap in
        var blend = unsafe VkPipelineColorBlendStateCreateInfo()
        unsafe blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        unsafe blend.attachmentCount = UInt32(ap.count)
        unsafe blend.pAttachments = unsafe UnsafePointer(ap.baseAddress)
        return dynamicStates.withUnsafeMutableBufferPointer { dp in
          var dynamic = unsafe VkPipelineDynamicStateCreateInfo()
          unsafe dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
          unsafe dynamic.dynamicStateCount = 2
          unsafe dynamic.pDynamicStates = unsafe UnsafePointer(dp.baseAddress)
          return formats.withUnsafeMutableBufferPointer { fp in
            var rendering = unsafe VkPipelineRenderingCreateInfo()
            unsafe rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO
            unsafe rendering.colorAttachmentCount = UInt32(fp.count)
            unsafe rendering.pColorAttachmentFormats = unsafe UnsafePointer(fp.baseAddress)
            return withUnsafePointer(to: &rendering) { rp in
              stages.withUnsafeBufferPointer { sp in
                var info = unsafe VkGraphicsPipelineCreateInfo()
                unsafe info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
                unsafe info.pNext = unsafe UnsafeRawPointer(rp)
                unsafe info.stageCount = 2
                unsafe info.pStages = sp.baseAddress
                return withUnsafePointer(to: &vertexInput) { vi in
                  withUnsafePointer(to: &assembly) { ia in
                    withUnsafePointer(to: &viewport) { vp in
                      withUnsafePointer(to: &raster) { ra in
                        withUnsafePointer(to: &multisample) { ms in
                          withUnsafePointer(to: &blend) { bl in
                            withUnsafePointer(to: &dynamic) { dy in
                              unsafe info.pVertexInputState = unsafe vi
                              unsafe info.pInputAssemblyState = unsafe ia
                              unsafe info.pViewportState = unsafe vp
                              unsafe info.pRasterizationState = unsafe ra
                              unsafe info.pMultisampleState = unsafe ms
                              unsafe info.pColorBlendState = unsafe bl
                              unsafe info.pDynamicState = unsafe dy
                              unsafe info.layout = pipelineLayout
                              return unsafe c.vkCreateGraphicsPipelines!(device, nil, 1, &info, nil, &pipeline)
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    try vkCheck(r, "vkCreateGraphicsPipelines")
    return GPUPipeline(handle: pipelines.insert(unsafe PipelineRecord(pipeline!)), kind: .graphics)
  }

  public func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline {
    let c = vk.commands
    let module = try shaderModule(spirv)
    defer { unsafe c.vkDestroyShaderModule!(device, module, nil) }
    var pipeline: VkPipeline?
    let r: VkResult = "main".withCString { entry in
      var info = unsafe VkComputePipelineCreateInfo()
      unsafe info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
      unsafe info.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
      unsafe info.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT
      unsafe info.stage.module = unsafe module
      unsafe info.stage.pName = unsafe entry
      unsafe info.layout = pipelineLayout
      return unsafe c.vkCreateComputePipelines!(device, nil, 1, &info, nil, &pipeline)
    }
    try vkCheck(r, "vkCreateComputePipelines")
    return GPUPipeline(handle: pipelines.insert(unsafe PipelineRecord(pipeline!)), kind: .compute)
  }

  public func destroy(_ pipeline: GPUPipeline) {
    guard let p = pipelines.remove(pipeline.handle) else { return }
    retire(.pipeline(p))
  }
}
