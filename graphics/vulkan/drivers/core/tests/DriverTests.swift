// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan layer, driven through its vkGetInstanceProcAddr as the loader would, over a fake core device
// (Harness.swift): what it hands the core for the compute and the triangle sequences, the descriptor records,
// the timeline, what it refuses and when its memory goes.

import GPUCore
import Testing
import TDVulkan
@testable import VulkanCoreDriver
import VulkanLowering

@Suite(.serialized) struct VulkanCoreDriverTests {
  // MARK: The compute sequence

  @Test func computeSequence() throws {
    let vk = VK()
    // Two storage buffers in upload memory, and a set that names them.
    let memory = vk.allocate(MemoryTypes.upload, 4096)
    let usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.rawValue
    let a = vk.buffer(256, usage: usage, in: memory, at: 0)
    let b = vk.buffer(256, usage: usage, in: memory, at: 1024)
    let layout = vk.setLayout([(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1), (1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1)])
    let pipelineLayout = vk.pipelineLayout([layout], push: 8)
    let (made, pipeline) = vk.computePipeline(pipelineLayout)
    #expect(made == VK_SUCCESS)
    let pool = vk.descriptorPool(sets: 1, sizes: [(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2)])
    let (allocated, set) = vk.allocateSet(pool, layout)
    #expect(allocated == VK_SUCCESS)
    vk.writeBuffers(set, binding: 0, type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, [VkDescriptorBufferInfo(buffer: a, offset: 0, range: 256)])
    // B from 16 bytes in, to the end.
    vk.writeBuffers(set, binding: 1, type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, [VkDescriptorBufferInfo(buffer: b, offset: 16, range: ~0)])

    // The lowering saw the pipeline layout: two buffers at 0 and 16, 8 bytes of push constants.
    #expect(loweredStages.count == 1)
    #expect(loweredStages[0].stage == .compute)
    #expect(loweredStages[0].entry == "main")
    #expect(loweredStages[0].layout.pushConstantBytes == 8)
    #expect(loweredStages[0].layout.sets.count == 1)
    #expect(loweredStages[0].layout.sets[0]?.offsets == [0, 16])
    #expect(vk.gpu.computePipelines.count == 1)

    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    var sets: [VkDescriptorSet?] = [set]
    var push: [UInt32] = [0x1111_1111, 0xDEAD_BEEF]
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
    vk.fn("vkCmdBindDescriptorSets", PFN_vkCmdBindDescriptorSets.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, &sets, 0, nil)
    vk.fn("vkCmdPushConstants", PFN_vkCmdPushConstants.self)(cb, pipelineLayout, VK_SHADER_STAGE_ALL.rawValue, 0, 8, &push)
    vk.fn("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb, 4, 2, 1)
    #expect(vk.end(cb) == VK_SUCCESS)

    let fence = vk.fence()
    #expect(vk.submit([cb], fence: fence) == VK_SUCCESS)
    #expect(vk.gpu.submitted.count == 1)
    let sent = vk.gpu.submitted[0]
    #expect(sent.wait == 0)
    #expect(sent.signal == 1)
    // The list is the dispatch, and nothing else.
    #expect(sent.list.commands.count == 1)
    let d = try #require(sent.list.dispatches.first)
    #expect(d.x == 4 && d.y == 2 && d.z == 1)
    #expect(d.pipeline.kind == .compute)

    // The root block: the set's address, no vertex buffers, the push constants at 96.
    let setAddress = vk.gpu.read(d.root + UInt64(RootBlock.setsOffset), as: UInt64.self)
    let poolMemory = try #require(vk.gpu.allocations.first { $0.size == 48 })
    #expect(setAddress == poolMemory.address)
    for i in 1..<RootBlock.maxSets { #expect(vk.gpu.read(d.root + UInt64(8 * i), as: UInt64.self) == 0) }
    for i in 0..<RootBlock.maxVertexBuffers {
      #expect(vk.gpu.read(d.root + UInt64(RootBlock.vertexBuffersOffset + 8 * i), as: UInt64.self) == 0)
    }
    #expect(vk.gpu.read(d.root + UInt64(RootBlock.pushConstantsOffset), as: UInt32.self) == 0x1111_1111)
    #expect(vk.gpu.read(d.root + UInt64(RootBlock.pushConstantsOffset + 4), as: UInt32.self) == 0xDEAD_BEEF)
    #expect(vk.gpu.read(d.root + UInt64(RootBlock.pushConstantsOffset + 8), as: UInt32.self) == 0)

    // The set record: the buffers' address and range, 16 bytes each.
    let addressA = vk.address(of: a)
    let addressB = vk.address(of: b)
    #expect(addressA == vk.gpu.allocations.first { $0.size == 4096 }!.address)
    #expect(addressB == addressA + 1024)
    #expect(vk.gpu.read(setAddress, as: UInt64.self) == addressA)
    #expect(vk.gpu.read(setAddress + 8, as: UInt64.self) == 256)
    #expect(vk.gpu.read(setAddress + 16, as: UInt64.self) == addressB + 16)
    #expect(vk.gpu.read(setAddress + 24, as: UInt64.self) == 240)

    // The fence is the submission's value, and the memory is the application's to read.
    #expect(vk.fn("vkGetFenceStatus", PFN_vkGetFenceStatus.self)(vk.device, fence) == VK_SUCCESS)
    _ = memory
  }

  // MARK: Descriptors

  @Test func descriptorRecords() throws {
    let vk = VK()
    let layout = vk.setLayout([
      (0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1), (1, VK_DESCRIPTOR_TYPE_SAMPLER, 1), (2, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2),
      (3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1), (4, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2),
    ])
    let pool = vk.descriptorPool(sets: 2, sizes: [(VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 8), (VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2)])
    let (_, set) = vk.allocateSet(pool, layout)

    // A heap slot belongs to the view and the sampler that took it.
    let both = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_STORAGE_BIT.rawValue
    let image = vk.image(usage: both)
    let first = vk.view(image)
    let second = vk.view(image)
    let sampler0 = vk.sampler()
    let sampler1 = vk.sampler()
    #expect(vk.gpu.textures[0]?.handle == vk.gpu.images[0].handle)
    #expect(vk.gpu.textures[1] != nil)
    #expect(vk.gpu.storageImages[0] != nil && vk.gpu.storageImages[1] != nil)
    #expect(vk.gpu.samplers[0]?.filter == .nearest)
    #expect(vk.gpu.samplers[0]?.addressMode == .repeat)

    vk.writeImages(set, binding: 0, type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, [VkDescriptorImageInfo(sampler: nil, imageView: second, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)])
    vk.writeImages(set, binding: 1, type: VK_DESCRIPTOR_TYPE_SAMPLER, [VkDescriptorImageInfo(sampler: sampler1, imageView: nil, imageLayout: VK_IMAGE_LAYOUT_UNDEFINED)])
    vk.writeImages(set, binding: 2, type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, element: 0, [
      VkDescriptorImageInfo(sampler: sampler0, imageView: first, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL),
      VkDescriptorImageInfo(sampler: sampler1, imageView: second, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL),
    ])
    vk.writeImages(set, binding: 3, type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, [VkDescriptorImageInfo(sampler: nil, imageView: second, imageLayout: VK_IMAGE_LAYOUT_GENERAL)])
    let memory = vk.allocate(MemoryTypes.upload, 1024)
    let buffer = vk.buffer(512, usage: VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue, in: memory, at: 64)
    vk.writeBuffers(set, binding: 4, type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, element: 1, [VkDescriptorBufferInfo(buffer: buffer, offset: 8, range: 100)])

    // The record: binding b's element i at offset(b) + 16 * i (offsets 0, 16, 32, 64, 80; element 1 of binding 4 at 96).
    let record = vk.gpu.allocations.first { $0.size == 192 }!.address
    #expect(vk.gpu.read(record + 0, as: UInt32.self) == 1)
    #expect(vk.gpu.read(record + 16, as: UInt32.self) == 1)
    #expect(vk.gpu.read(record + 32, as: UInt32.self) == 0)
    #expect(vk.gpu.read(record + 36, as: UInt32.self) == 0)
    #expect(vk.gpu.read(record + 48, as: UInt32.self) == 1)
    #expect(vk.gpu.read(record + 52, as: UInt32.self) == 1)
    #expect(vk.gpu.read(record + 64, as: UInt32.self) == 1)
    #expect(vk.gpu.read(record + 80, as: UInt64.self) == 0)
    // Element 1 of the uniform buffers, past binding 3's one descriptor.
    #expect(vk.gpu.read(record + 96, as: UInt64.self) == vk.address(of: buffer) + 8)
    #expect(vk.gpu.read(record + 104, as: UInt64.self) == 100)

    // Destroying a view or a sampler gives its slot back, and the lowest free one is taken next.
    vk.fn("vkDestroyImageView", PFN_vkDestroyImageView.self)(vk.device, first, nil)
    vk.fn("vkDestroySampler", PFN_vkDestroySampler.self)(vk.device, sampler0, nil)
    let third = vk.view(image)
    let sampler2 = vk.sampler()
    #expect(vk.gpu.textures[0] != nil)
    _ = (third, sampler2)
    #expect(vk.gpu.samplers[0] != nil)

    // Out of heap: the samplers are four.
    var more: [VkSampler?] = []
    var out = VK_SUCCESS
    var info = VkSamplerCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    for _ in 0..<4 {
      var s: VkSampler?
      out = vk.fn("vkCreateSampler", PFN_vkCreateSampler.self)(vk.device, &info, nil, &s)
      more.append(s)
    }
    #expect(out == VK_ERROR_OUT_OF_DEVICE_MEMORY)
  }

  @Test func descriptorPools() throws {
    let vk = VK()
    let layout = vk.setLayout([(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2)])
    let pool = vk.descriptorPool(sets: 2, sizes: [(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 4)], flags: VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT.rawValue)
    let (r1, one) = vk.allocateSet(pool, layout)
    let (r2, two) = vk.allocateSet(pool, layout)
    let (r3, _) = vk.allocateSet(pool, layout)
    #expect(r1 == VK_SUCCESS && r2 == VK_SUCCESS)
    #expect(r3 == VK_ERROR_OUT_OF_POOL_MEMORY)
    // A freed set's place is the next one's.
    var sets: [VkDescriptorSet?] = [one]
    #expect(vk.fn("vkFreeDescriptorSets", PFN_vkFreeDescriptorSets.self)(vk.device, pool, 1, &sets) == VK_SUCCESS)
    let (r4, _) = vk.allocateSet(pool, layout)
    #expect(r4 == VK_SUCCESS)
    #expect(vk.fn("vkResetDescriptorPool", PFN_vkResetDescriptorPool.self)(vk.device, pool, 0) == VK_SUCCESS)
    let (r5, _) = vk.allocateSet(pool, layout)
    #expect(r5 == VK_SUCCESS)
    _ = two
  }

  // MARK: The triangle sequence

  /// A pass of one colour attachment, cleared at its start and stored, over a view of `image`.
  func renderPass(_ vk: VK, load: VkAttachmentLoadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                  format: VkFormat = VK_FORMAT_R8G8B8A8_UNORM) -> VkRenderPass?
  {
    var attachment = VkAttachmentDescription(flags: 0, format: format, samples: VK_SAMPLE_COUNT_1_BIT, loadOp: load,
                                             storeOp: VK_ATTACHMENT_STORE_OP_STORE, stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                             stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE, initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                                             finalLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
    var ref = VkAttachmentReference(attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    var out: VkRenderPass?
    withUnsafePointer(to: &ref) { rp in
      var subpass = VkSubpassDescription()
      subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
      subpass.colorAttachmentCount = 1
      subpass.pColorAttachments = rp
      var info = VkRenderPassCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
      info.attachmentCount = 1
      info.subpassCount = 1
      withUnsafePointer(to: &attachment) { ap in
        info.pAttachments = ap
        withUnsafePointer(to: &subpass) { sp in
          info.pSubpasses = sp
          let r = vk.fn("vkCreateRenderPass", PFN_vkCreateRenderPass.self)(vk.device, &info, nil, &out)
          precondition(r == VK_SUCCESS, "vkCreateRenderPass \(r)")
        }
      }
    }
    return out
  }

  func framebuffer(_ vk: VK, _ pass: VkRenderPass?, _ view: VkImageView?, _ size: UInt32) -> VkFramebuffer? {
    var v = view
    var out: VkFramebuffer?
    withUnsafePointer(to: &v) { vp in
      var info = VkFramebufferCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
      info.renderPass = pass
      info.attachmentCount = 1
      info.pAttachments = vp
      info.width = size
      info.height = size
      info.layers = 1
      let r = vk.fn("vkCreateFramebuffer", PFN_vkCreateFramebuffer.self)(vk.device, &info, nil, &out)
      precondition(r == VK_SUCCESS)
    }
    return out
  }

  struct PipelineOptions {
    var cull: VkCullModeFlags = 0
    var depthTest = false
    var blend = false
    var blendFactor = VK_BLEND_FACTOR_SRC_ALPHA
    var topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    var dynamicViewport = true
    var attributeFormat = VK_FORMAT_R32G32_SFLOAT
    var samples = VK_SAMPLE_COUNT_1_BIT
    var vertexSpecialization: [(id: UInt32, size: Int, value: UInt64)] = []
    var fragmentSpecialization: [(id: UInt32, size: Int, value: UInt64)] = []
  }

  func graphicsPipeline(_ vk: VK, _ layout: VkPipelineLayout?, _ pass: VkRenderPass?, _ o: PipelineOptions = PipelineOptions()) -> (VkResult, VkPipeline?) {
    let vs = vk.shaderModule()
    let fs = vk.shaderModule()
    var out: VkPipeline?
    var result = VK_SUCCESS
    "main".withCString { name in
      vk.withSpecialization(o.vertexSpecialization) { vsp in vk.withSpecialization(o.fragmentSpecialization) { fsp in
        var stages = [
          VkPipelineShaderStageCreateInfo(sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, pNext: nil, flags: 0,
                                          stage: VK_SHADER_STAGE_VERTEX_BIT, module: vs, pName: name,
                                          pSpecializationInfo: vsp),
          VkPipelineShaderStageCreateInfo(sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, pNext: nil, flags: 0,
                                          stage: VK_SHADER_STAGE_FRAGMENT_BIT, module: fs, pName: name, pSpecializationInfo: fsp),
        ]
        var binding = VkVertexInputBindingDescription(binding: 0, stride: 8, inputRate: VK_VERTEX_INPUT_RATE_VERTEX)
        var attribute = VkVertexInputAttributeDescription(location: 0, binding: 0, format: o.attributeFormat, offset: 0)
        var vertex = VkPipelineVertexInputStateCreateInfo()
        vertex.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
        vertex.vertexBindingDescriptionCount = 1
        vertex.vertexAttributeDescriptionCount = 1
        var assembly = VkPipelineInputAssemblyStateCreateInfo()
        assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        assembly.topology = o.topology
        var viewport = VkViewport(x: 1, y: 2, width: 30, height: 40, minDepth: 0, maxDepth: 1)
        var scissor = VkRect2D(offset: VkOffset2D(x: 3, y: 4), extent: VkExtent2D(width: 20, height: 10))
        var viewportState = VkPipelineViewportStateCreateInfo()
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        viewportState.viewportCount = 1
        viewportState.scissorCount = 1
        var raster = VkPipelineRasterizationStateCreateInfo()
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        raster.polygonMode = VK_POLYGON_MODE_FILL
        raster.cullMode = o.cull
        raster.lineWidth = 1
        var multi = VkPipelineMultisampleStateCreateInfo()
        multi.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        multi.rasterizationSamples = o.samples
        var depth = VkPipelineDepthStencilStateCreateInfo()
        depth.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
        depth.depthTestEnable = o.depthTest ? 1 : 0
        var blendState = VkPipelineColorBlendAttachmentState(
          blendEnable: o.blend ? 1 : 0, srcColorBlendFactor: o.blendFactor, dstColorBlendFactor: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
          colorBlendOp: VK_BLEND_OP_ADD, srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE, dstAlphaBlendFactor: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
          alphaBlendOp: VK_BLEND_OP_ADD,
          colorWriteMask: VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue | VK_COLOR_COMPONENT_B_BIT.rawValue
            | VK_COLOR_COMPONENT_A_BIT.rawValue)
        var blend = VkPipelineColorBlendStateCreateInfo()
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        blend.attachmentCount = 1
        var dynamics: [VkDynamicState] = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
        var dynamic = VkPipelineDynamicStateCreateInfo()
        dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
        dynamic.dynamicStateCount = o.dynamicViewport ? 2 : 0
        withUnsafePointer(to: &binding) { bp in
          withUnsafePointer(to: &attribute) { ap in
            vertex.pVertexBindingDescriptions = bp
            vertex.pVertexAttributeDescriptions = ap
            withUnsafePointer(to: &viewport) { vp in
              withUnsafePointer(to: &scissor) { sp in
                viewportState.pViewports = vp
                viewportState.pScissors = sp
                withUnsafePointer(to: &blendState) { bsp in
                  blend.pAttachments = bsp
                  dynamics.withUnsafeBufferPointer { dp in
                    dynamic.pDynamicStates = dp.baseAddress
                    var info = VkGraphicsPipelineCreateInfo()
                    info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
                    info.stageCount = 2
                    info.layout = layout
                    info.renderPass = pass
                    stages.withUnsafeBufferPointer { st in
                      info.pStages = st.baseAddress
                      withUnsafePointer(to: &vertex) { info.pVertexInputState = $0 }
                      withUnsafePointer(to: &assembly) { info.pInputAssemblyState = $0 }
                      withUnsafePointer(to: &viewportState) { info.pViewportState = $0 }
                      withUnsafePointer(to: &raster) { info.pRasterizationState = $0 }
                      withUnsafePointer(to: &multi) { info.pMultisampleState = $0 }
                      withUnsafePointer(to: &depth) { info.pDepthStencilState = $0 }
                      withUnsafePointer(to: &blend) { info.pColorBlendState = $0 }
                      withUnsafePointer(to: &dynamic) { info.pDynamicState = $0 }
                      result = vk.fn("vkCreateGraphicsPipelines", PFN_vkCreateGraphicsPipelines.self)(vk.device, nil, 1, &info, nil, &out)
                    }
                  }
                }
              }
            }
          }
        }
      } }
    }
    return (result, out)
  }

  func beginPass(_ vk: VK, _ cb: VkCommandBuffer?, _ pass: VkRenderPass?, _ fb: VkFramebuffer?, size: UInt32, clear: [Float]) {
    var value = VkClearValue()
    unsafe value.color.float32 = (clear[0], clear[1], clear[2], clear[3])
    var info = VkRenderPassBeginInfo()
    info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    info.renderPass = pass
    info.framebuffer = fb
    info.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: size, height: size))
    info.clearValueCount = 1
    withUnsafePointer(to: &value) { vp in
      info.pClearValues = vp
      vk.fn("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(cb, &info, VK_SUBPASS_CONTENTS_INLINE)
    }
  }

  @Test func triangleSequence() throws {
    let vk = VK()
    let pass = renderPass(vk)
    let colorUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
    let image = vk.image(usage: colorUsage)
    let view = vk.view(image)
    let fb = framebuffer(vk, pass, view, 4)
    let layout = vk.pipelineLayout([])
    let (made, pipeline) = graphicsPipeline(vk, layout, pass)
    #expect(made == VK_SUCCESS)

    // What the core's pipeline is: the colour format and blend, and both stages lowered, the vertex stage against its input.
    #expect(vk.gpu.graphicsPipelines.count == 1)
    #expect(vk.gpu.graphicsPipelines[0].colorFormats == [.rgba8])
    #expect(vk.gpu.graphicsPipelines[0].blend == .opaque)
    #expect(vk.gpu.graphicsPipelines[0].topology == .triangleList)
    #expect(loweredStages.map { $0.stage } == [.vertex, .fragment])
    #expect(loweredStages[0].layout.vertexBindings == [VertexBinding(binding: 0, stride: 8)])
    #expect(loweredStages[0].layout.vertexAttributes == [VertexAttribute(location: 0, binding: 0, format: .rg32Float, offset: 0)])
    #expect(loweredStages[1].layout.vertexAttributes.isEmpty)

    let memory = vk.allocate(MemoryTypes.upload, 4096)
    let vertices = vk.buffer(24, usage: VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue, in: memory, at: 128)
    let readbackMemory = vk.allocate(MemoryTypes.readback, 256)
    let readback = vk.buffer(64, usage: VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue, in: readbackMemory)

    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    beginPass(vk, cb, pass, fb, size: 4, clear: [0.25, 0.5, 0.75, 1])
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    var vb: [VkBuffer?] = [vertices]
    var offsets: [UInt64] = [8]
    vk.fn("vkCmdBindVertexBuffers", PFN_vkCmdBindVertexBuffers.self)(cb, 0, 1, &vb, &offsets)
    var viewport = VkViewport(x: 0, y: 0, width: 4, height: 4, minDepth: 0, maxDepth: 1)
    var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 4, height: 4))
    vk.fn("vkCmdSetViewport", PFN_vkCmdSetViewport.self)(cb, 0, 1, &viewport)
    vk.fn("vkCmdSetScissor", PFN_vkCmdSetScissor.self)(cb, 0, 1, &scissor)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 1, 0, 0)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    // Pass to copy: the pass's writes to the transfer.
    var barrier = VkMemoryBarrier()
    barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
    vk.fn("vkCmdPipelineBarrier", PFN_vkCmdPipelineBarrier.self)(
      cb, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, 0, 1, &barrier, 0, nil, 0, nil)
    var region = VkBufferImageCopy(bufferOffset: 16, bufferRowLength: 0, bufferImageHeight: 0,
                                   imageSubresource: VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0, baseArrayLayer: 0, layerCount: 1),
                                   imageOffset: VkOffset3D(x: 0, y: 0, z: 0), imageExtent: VkExtent3D(width: 4, height: 4, depth: 1))
    vk.fn("vkCmdCopyImageToBuffer", PFN_vkCmdCopyImageToBuffer.self)(cb, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &region)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)

    let list = vk.gpu.submitted[0].list
    let gpuImage = vk.gpu.images[0]
    // The pass: cleared and stored, the viewport and scissor the application set, one draw, its end, the barrier and the copy.
    guard list.commands.count == 7 else {
      Issue.record("the list is \(list.commands)")
      return
    }
    #expect(list.commands[0] == .beginRendering(RenderingInfo(colors: [Attachment(image: gpuImage, load: .clear(0.25, 0.5, 0.75, 1), store: .store)])))
    #expect(list.commands[1] == .setViewport(x: 0, y: 0, width: 4, height: 4))
    #expect(list.commands[2] == .setScissor(x: 0, y: 0, width: 4, height: 4))
    let d = try #require(list.draws.first)
    #expect(d.vertices == 3 && d.instances == 1 && d.firstVertex == 0 && d.firstInstance == 0)
    #expect(d.pipeline.kind == .graphics)
    #expect(list.commands[4] == .endRendering)
    #expect(list.commands[5] == .barrier(from: .fragment, to: .transfer))
    let readbackMem = try #require(vk.gpu.allocations.first { $0.size == 256 })
    #expect(list.commands[6] == .copyImageToBuffer(gpuImage, readbackMem, offset: 16))
    // The vertex buffer: the buffer's address (its memory's plus 128) and the bound offset.
    let vertexAddress = vk.gpu.read(d.root + UInt64(RootBlock.vertexBuffersOffset), as: UInt64.self)
    #expect(vertexAddress == vk.address(of: vertices) + 8)
    #expect(vertexAddress == vk.gpu.allocations.first { $0.size == 4096 }!.address + 136)
    _ = memory
  }

  @Test func staticStateAndDynamicRendering() throws {
    let vk = VK()
    let layout = vk.pipelineLayout([])
    let pass = renderPass(vk)
    // A pipeline that states its viewport and scissor sends them before its draws, once.
    var options = PipelineOptions()
    options.dynamicViewport = false
    let (made, pipeline) = graphicsPipeline(vk, layout, pass, options)
    #expect(made == VK_SUCCESS)

    let image = vk.image(usage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue)
    let view = vk.view(image)
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    var color = VkRenderingAttachmentInfo()
    color.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
    color.imageView = view
    color.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
    color.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
    withUnsafePointer(to: &color) { cp in
      var info = VkRenderingInfo()
      info.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
      info.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 2, height: 4))
      info.layerCount = 1
      info.colorAttachmentCount = 1
      info.pColorAttachments = cp
      vk.fn("vkCmdBeginRendering", PFN_vkCmdBeginRendering.self)(cb, &info)
    }
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 2, 1, 5)
    vk.fn("vkCmdEndRendering", PFN_vkCmdEndRendering.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let list = vk.gpu.submitted[0].list
    let gpuImage = vk.gpu.images[0]
    // A render area short of the target scissors the pass; the pipeline's own state follows; the discards are what the pass says.
    #expect(list.commands.count == 6)
    #expect(list.commands[0] == .beginRendering(RenderingInfo(colors: [Attachment(image: gpuImage, load: .dontCare, store: .discard)])))
    #expect(list.commands[1] == .setScissor(x: 0, y: 0, width: 2, height: 4))
    #expect(list.commands[2] == .setViewport(x: 1, y: 2, width: 30, height: 40))
    #expect(list.commands[3] == .setScissor(x: 3, y: 4, width: 20, height: 10))
    let d = try #require(list.draws.first)
    #expect(d.vertices == 3 && d.instances == 2 && d.firstVertex == 1 && d.firstInstance == 5)
    #expect(list.commands[5] == .endRendering)
  }

  @Test func blendAndTopology() throws {
    let vk = VK()
    let layout = vk.pipelineLayout([])
    let pass = renderPass(vk, format: VK_FORMAT_B8G8R8A8_SRGB)
    var o = PipelineOptions()
    o.blend = true
    o.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
    #expect(graphicsPipeline(vk, layout, pass, o).0 == VK_SUCCESS)
    let made = vk.gpu.graphicsPipelines[0]
    #expect(made.blend == .alpha)
    #expect(made.topology == .triangleStrip)
    #expect(made.colorFormats == [.bgra8srgb])
  }

  // MARK: Copies, updates and clears

  @Test func bufferWritesAndClears() throws {
    let vk = VK()
    let memory = vk.allocate(MemoryTypes.upload, 4096)
    let usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue
    let a = vk.buffer(256, usage: usage, in: memory, at: 0)
    let b = vk.buffer(256, usage: usage, in: memory, at: 512)
    let image = vk.image(VK_FORMAT_B8G8R8A8_UNORM, 8, 2, usage: VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    var data: [UInt8] = Array(0..<32)
    vk.fn("vkCmdUpdateBuffer", PFN_vkCmdUpdateBuffer.self)(cb, a, 16, 32, &data)
    vk.fn("vkCmdFillBuffer", PFN_vkCmdFillBuffer.self)(cb, b, 8, 16, 0xA5A5_5A5A)
    var copy = VkBufferCopy(srcOffset: 4, dstOffset: 20, size: 40)
    vk.fn("vkCmdCopyBuffer", PFN_vkCmdCopyBuffer.self)(cb, a, b, 1, &copy)
    var clear = VkClearColorValue()
    unsafe clear.float32 = (1, 0, 0.5, 0.25)
    var range = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0, levelCount: ~0, baseArrayLayer: 0, layerCount: ~0)
    vk.fn("vkCmdClearColorImage", PFN_vkCmdClearColorImage.self)(cb, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1, &range)
    var region = VkBufferImageCopy(bufferOffset: 64, bufferRowLength: 8, bufferImageHeight: 2,
                                   imageSubresource: VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0, baseArrayLayer: 0, layerCount: 1),
                                   imageOffset: VkOffset3D(x: 0, y: 0, z: 0), imageExtent: VkExtent3D(width: 8, height: 2, depth: 1))
    vk.fn("vkCmdCopyBufferToImage", PFN_vkCmdCopyBufferToImage.self)(cb, a, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)

    let list = vk.gpu.submitted[0].list
    let base = vk.gpu.allocations.first { $0.size == 4096 }!
    #expect(list.commands.count == 6)
    // The update is a copy from the arena, whose bytes are the data.
    guard case .copyBuffer(let updateFrom, let updateOffset, let updateTo, let updateAt, let updateBytes) = list.commands[0] else {
      Issue.record("not a copy: \(list.commands[0])")
      return
    }
    #expect(updateFrom.intent == .upload && updateFrom.handle != base.handle)
    #expect(updateTo == base && updateAt == 16 && updateBytes == 32)
    #expect(vk.gpu.bytes(updateFrom.address + UInt64(updateOffset), count: 32) == data)
    // The fill, a copy of the pattern.
    guard case .copyBuffer(let fillFrom, let fillOffset, let fillTo, let fillAt, let fillBytes) = list.commands[1] else {
      Issue.record("not a copy: \(list.commands[1])")
      return
    }
    #expect(fillTo == base && fillAt == 512 + 8 && fillBytes == 16)
    let word = vk.gpu.read(fillFrom.address + UInt64(fillOffset) + 12, as: UInt32.self)
    #expect(word == 0xA5A5_5A5A)
    #expect(list.commands[2] == .copyBuffer(from: base, fromOffset: 4, to: base, toOffset: 512 + 20, bytes: 40))
    // The clear is a pass that draws nothing.
    let gpuImage = vk.gpu.images[0]
    #expect(list.commands[3] == .beginRendering(RenderingInfo(colors: [Attachment(image: gpuImage, load: .clear(1, 0, 0.5, 0.25), store: .store)])))
    #expect(list.commands[4] == .endRendering)
    #expect(list.commands[5] == .copyBufferToImage(base, offset: 64, gpuImage))
    #expect(gpuImage.usage.contains(.copyDestination) && gpuImage.usage.contains(.renderTarget))
  }

  @Test func indexedAndIndirect() throws {
    let vk = VK()
    let layout = vk.pipelineLayout([])
    let pass = renderPass(vk)
    let (_, pipeline) = graphicsPipeline(vk, layout, pass)
    let (_, compute) = vk.computePipeline(layout)
    let image = vk.image(usage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue)
    let fb = framebuffer(vk, pass, vk.view(image), 4)
    let memory = vk.allocate(MemoryTypes.upload, 4096)
    let usage = VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT.rawValue
    let buffer = vk.buffer(1024, usage: usage, in: memory, at: 256)
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    vk.fn("vkCmdBindIndexBuffer", PFN_vkCmdBindIndexBuffer.self)(cb, buffer, 32, VK_INDEX_TYPE_UINT16)
    beginPass(vk, cb, pass, fb, size: 4, clear: [0, 0, 0, 0])
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    vk.fn("vkCmdDrawIndexed", PFN_vkCmdDrawIndexed.self)(cb, 6, 1, 2, -1, 0)
    vk.fn("vkCmdDrawIndirect", PFN_vkCmdDrawIndirect.self)(cb, buffer, 64, 1, 0)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, compute)
    vk.fn("vkCmdDispatchIndirect", PFN_vkCmdDispatchIndirect.self)(cb, buffer, 128)
    // No groups, no dispatch.
    vk.fn("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb, 0, 4, 4)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let base = vk.gpu.allocations.first { $0.size == 4096 }!
    let list = vk.gpu.submitted[0].list
    guard case .drawIndexed(_, _, let indices, let indexOffset, let type, let count, _, let first, let vertexOffset, _) = list.commands[1] else {
      Issue.record("not an indexed draw: \(list.commands)")
      return
    }
    #expect(indices == base && indexOffset == 256 + 32 && type == .uint16 && count == 6 && first == 2 && vertexOffset == -1)
    guard case .drawIndirect(_, _, let args, let argsOffset, let drawCount, let stride) = list.commands[2] else {
      Issue.record("not an indirect draw: \(list.commands)")
      return
    }
    #expect(args == base && argsOffset == 256 + 64 && drawCount == 1 && stride == 16)
    guard case .dispatchIndirect(_, _, let dargs, let dOffset) = list.commands[4] else {
      Issue.record("not an indirect dispatch: \(list.commands)")
      return
    }
    #expect(dargs == base && dOffset == 256 + 128)
    #expect(list.commands.count == 5)
  }

  // MARK: Queries, barriers and the second synchronisation

  @Test func queriesAndBarriers() throws {
    let vk = VK()
    var info = VkQueryPoolCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO
    info.queryType = VK_QUERY_TYPE_TIMESTAMP
    info.queryCount = 4
    var pool: VkQueryPool?
    #expect(vk.fn("vkCreateQueryPool", PFN_vkCreateQueryPool.self)(vk.device, &info, nil, &pool) == VK_SUCCESS)
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    vk.fn("vkCmdResetQueryPool", PFN_vkCmdResetQueryPool.self)(cb, pool, 0, 4)
    vk.fn("vkCmdWriteTimestamp", PFN_vkCmdWriteTimestamp.self)(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, pool, 0)
    // The second barrier names compute then fragment, in three kinds of barrier.
    var memoryBarrier = VkMemoryBarrier2()
    memoryBarrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2
    memoryBarrier.srcStageMask = VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT
    memoryBarrier.dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT
    var dependency = VkDependencyInfo()
    dependency.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO
    dependency.memoryBarrierCount = 1
    withUnsafePointer(to: &memoryBarrier) { mp in
      dependency.pMemoryBarriers = mp
      vk.fn("vkCmdPipelineBarrier2", PFN_vkCmdPipelineBarrier2.self)(cb, &dependency)
    }
    vk.fn("vkCmdWriteTimestamp2", PFN_vkCmdWriteTimestamp2.self)(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, pool, 1)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let list = vk.gpu.submitted[0].list
    let set = vk.gpu.querySets[0]
    #expect(list.commands == [
      .writeTimestamp(set, index: 0, after: .all), .barrier(from: .compute, to: .fragment), .writeTimestamp(set, index: 1, after: .all),
    ])
    vk.gpu.queryResults = [11, 22]
    var results = [UInt64](repeating: 0, count: 2)
    #expect(vk.fn("vkGetQueryPoolResults", PFN_vkGetQueryPoolResults.self)(
      vk.device, pool, 0, 2, 16, &results, 8, VK_QUERY_RESULT_64_BIT.rawValue) == VK_SUCCESS)
    #expect(results == [11, 22])
    var props = VkPhysicalDeviceProperties()
    vk.fn("vkGetPhysicalDeviceProperties", PFN_vkGetPhysicalDeviceProperties.self)(vk.physical, &props)
    #expect(props.limits.timestampPeriod == 40)
  }

  // MARK: The timeline

  @Test func fencesAreTimelineValues() throws {
    let vk = VK()
    vk.gpu.autoComplete = false
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    let status = vk.fn("vkGetFenceStatus", PFN_vkGetFenceStatus.self)
    let fence = vk.fence()
    let created = vk.fence(signaled: true)
    #expect(status(vk.device, fence) == VK_NOT_READY)
    #expect(status(vk.device, created) == VK_SUCCESS)
    #expect(vk.submit([cb], fence: fence) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    // Each submission signals the next value; the fence is the first.
    #expect(vk.gpu.submitted.map { $0.signal } == [1, 2])
    #expect(status(vk.device, fence) == VK_NOT_READY)
    vk.gpu.finish(1)
    #expect(status(vk.device, fence) == VK_SUCCESS)
    var fences: [VkFence?] = [fence]
    #expect(vk.fn("vkResetFences", PFN_vkResetFences.self)(vk.device, 1, &fences) == VK_SUCCESS)
    #expect(status(vk.device, fence) == VK_NOT_READY)
    // A fence nothing signals can't be waited for.
    let wait = vk.fn("vkWaitForFences", PFN_vkWaitForFences.self)
    #expect(wait(vk.device, 1, &fences, 1, 1000) == VK_TIMEOUT)
    // A fence for a value not reached: no time, no wait; some time, the device's wait.
    #expect(vk.submit([cb], fence: fence) == VK_SUCCESS)
    #expect(vk.gpu.submitted.last!.signal == 3)
    #expect(wait(vk.device, 1, &fences, 1, 0) == VK_TIMEOUT)
    #expect(vk.gpu.completed == 1)
    #expect(wait(vk.device, 1, &fences, 1, ~0) == VK_SUCCESS)
    #expect(vk.gpu.completed == 3)
    #expect(status(vk.device, fence) == VK_SUCCESS)
    // Any of two.
    var two: [VkFence?] = [created, fence]
    #expect(wait(vk.device, 2, &two, 0, 0) == VK_SUCCESS)
    // Idle: the last value.
    #expect(vk.submit([cb]) == VK_SUCCESS)
    #expect(vk.fn("vkQueueWaitIdle", PFN_vkQueueWaitIdle.self)(vk.queue) == VK_SUCCESS)
    #expect(vk.gpu.completed == 4)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    #expect(vk.fn("vkDeviceWaitIdle", PFN_vkDeviceWaitIdle.self)(vk.device) == VK_SUCCESS)
    #expect(vk.gpu.completed == 5)
  }

  @Test func binarySemaphores() throws {
    let vk = VK()
    vk.gpu.autoComplete = false
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    let s = vk.semaphore()
    #expect(vk.submit([cb]) == VK_SUCCESS)
    #expect(vk.submit([cb], signal: [s]) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    // The waiter waits for the submission that signalled, the second.
    #expect(vk.submit([cb], wait: [s]) == VK_SUCCESS)
    #expect(vk.gpu.submitted.map { $0.signal } == [1, 2, 3, 4])
    #expect(vk.gpu.submitted.map { $0.wait } == [0, 0, 0, 2])
    // The wait took the signal: a second waiter has nothing to wait for.
    #expect(vk.submit([cb], wait: [s]) == VK_SUCCESS)
    #expect(vk.gpu.submitted.last!.wait == 0)
    // Two waits, and the greater value is the one.
    let t = vk.semaphore()
    #expect(vk.submit([cb], signal: [t]) == VK_SUCCESS)
    #expect(vk.submit([cb], signal: [s]) == VK_SUCCESS)
    #expect(vk.submit([cb], wait: [s, t]) == VK_SUCCESS)
    #expect(vk.gpu.submitted.last!.wait == 7)
  }

  @Test func timelineSemaphores() throws {
    let vk = VK()
    vk.gpu.autoComplete = false
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    let s = vk.semaphore(timeline: 5)
    #expect(vk.counter(s) == 5)
    // Semaphore values 7 and 9 are device values 1 and 2.
    #expect(vk.submit([cb], signal: [s], signalValues: [7]) == VK_SUCCESS)
    #expect(vk.submit([cb], signal: [s], signalValues: [9]) == VK_SUCCESS)
    #expect(vk.counter(s) == 5)
    vk.gpu.finish(1)
    #expect(vk.counter(s) == 7)
    // A wait for 3 is satisfied; for 8, by the submission that signalled 9; neither is a wait for the host.
    #expect(vk.submit([cb], wait: [s], waitValues: [3]) == VK_SUCCESS)
    #expect(vk.submit([cb], wait: [s], waitValues: [8]) == VK_SUCCESS)
    #expect(vk.gpu.submitted.map { $0.wait } == [0, 0, 0, 2])
    // A value nobody signals can't be waited for.
    #expect(vk.submit([cb], wait: [s], waitValues: [20]) == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(vk.gpu.submitted.count == 4)
    // The host signals at once, and then 20 is reached.
    var signal = VkSemaphoreSignalInfo()
    signal.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO
    signal.semaphore = s
    signal.value = 20
    #expect(vk.fn("vkSignalSemaphore", PFN_vkSignalSemaphore.self)(vk.device, &signal) == VK_SUCCESS)
    #expect(vk.counter(s) == 20)
    #expect(vk.submit([cb], wait: [s], waitValues: [20]) == VK_SUCCESS)
    #expect(vk.gpu.submitted.last!.wait == 0)

    // Waiting on the host: for the 9 the device has to reach 2, and the wait takes the timeline there.
    let t = vk.semaphore(timeline: 0)
    #expect(vk.submit([cb], signal: [t], signalValues: [4]) == VK_SUCCESS)
    let last = vk.gpu.submitted.last!.signal
    var sems: [VkSemaphore?] = [t]
    var values: [UInt64] = [4]
    var info = VkSemaphoreWaitInfo()
    info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO
    info.semaphoreCount = 1
    let wait = vk.fn("vkWaitSemaphores", PFN_vkWaitSemaphores.self)
    var r = VK_SUCCESS
    sems.withUnsafeBufferPointer { sp in
      values.withUnsafeBufferPointer { vp in
        info.pSemaphores = sp.baseAddress
        info.pValues = vp.baseAddress
        #expect(wait(vk.device, &info, 0) == VK_TIMEOUT)
        r = wait(vk.device, &info, 1_000_000)
      }
    }
    #expect(r == VK_SUCCESS)
    #expect(vk.gpu.completed == last)
    #expect(vk.counter(t) == 4)
  }

  @Test func submitTwo() throws {
    let vk = VK()
    vk.gpu.autoComplete = false
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    let s = vk.semaphore(timeline: 0)
    var signalInfo = VkSemaphoreSubmitInfo()
    signalInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO
    signalInfo.semaphore = s
    signalInfo.value = 3
    var commandInfo = VkCommandBufferSubmitInfo()
    commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO
    commandInfo.commandBuffer = cb
    var waitInfo = signalInfo
    waitInfo.value = 3
    var submit = VkSubmitInfo2()
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2
    submit.commandBufferInfoCount = 1
    submit.signalSemaphoreInfoCount = 1
    let fence = vk.fence()
    withUnsafePointer(to: &commandInfo) { cip in
      withUnsafePointer(to: &signalInfo) { sip in
        submit.pCommandBufferInfos = cip
        submit.pSignalSemaphoreInfos = sip
        #expect(vk.fn("vkQueueSubmit2", PFN_vkQueueSubmit2.self)(vk.queue, 1, &submit, fence) == VK_SUCCESS)
      }
    }
    submit.signalSemaphoreInfoCount = 0
    submit.waitSemaphoreInfoCount = 1
    withUnsafePointer(to: &commandInfo) { cip in
      withUnsafePointer(to: &waitInfo) { wip in
        submit.pCommandBufferInfos = cip
        submit.pWaitSemaphoreInfos = wip
        #expect(vk.fn("vkQueueSubmit2", PFN_vkQueueSubmit2.self)(vk.queue, 1, &submit, nil) == VK_SUCCESS)
      }
    }
    #expect(vk.gpu.submitted.map { $0.wait } == [0, 1])
    #expect(vk.fn("vkGetFenceStatus", PFN_vkGetFenceStatus.self)(vk.device, fence) == VK_NOT_READY)
    vk.gpu.finish(1)
    #expect(vk.fn("vkGetFenceStatus", PFN_vkGetFenceStatus.self)(vk.device, fence) == VK_SUCCESS)
    #expect(vk.counter(s) == 3)
    // A fence with nothing to submit is an empty submission's.
    let lone = vk.fence()
    #expect(vk.fn("vkQueueSubmit", PFN_vkQueueSubmit.self)(vk.queue, 0, nil, lone) == VK_SUCCESS)
    #expect(vk.gpu.submitted.last!.list.isEmpty)
    #expect(vk.gpu.submitted.last!.signal == 3)
  }

  // MARK: Refusals

  @Test func missingFeaturesFailTheEndOfTheBuffer() throws {
    // A device that has none of the optional features.
    let vk = VK(gpu: FakeGPU(features: DeviceFeatures()))
    let layout = vk.pipelineLayout([])
    let pass = renderPass(vk)
    let (_, pipeline) = graphicsPipeline(vk, layout, pass)
    let (_, compute) = vk.computePipeline(layout)
    let image = vk.image(usage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue)
    let fb = framebuffer(vk, pass, vk.view(image), 4)
    let memory = vk.allocate(MemoryTypes.upload, 4096)
    let buffer = vk.buffer(1024, usage: VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT.rawValue, in: memory)
    let cp = vk.commandPool()

    func record(_ body: (VkCommandBuffer?) -> Void) -> VkResult {
      let cb = vk.commandBuffer(cp)
      vk.begin(cb)
      body(cb)
      return vk.end(cb)
    }
    func draw(_ cb: VkCommandBuffer?) { vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 1, 0, 0) }
    func inPass(_ cb: VkCommandBuffer?, load: Bool = false, _ body: () -> Void) {
      beginPass(vk, cb, pass, fb, size: 4, clear: [0, 0, 0, 0])
      vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
      body()
      vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    }

    // One draw in a pass is fine; the second is what the device lacks.
    #expect(record { cb in inPass(cb) { draw(cb) } } == VK_SUCCESS)
    vk.messages = []
    #expect(record { cb in inPass(cb) { draw(cb); draw(cb) } } == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(vk.messages.contains { $0.contains("more than one draw in a pass") })
    #expect(record { cb in
      vk.fn("vkCmdBindIndexBuffer", PFN_vkCmdBindIndexBuffer.self)(cb, buffer, 0, VK_INDEX_TYPE_UINT16)
      inPass(cb) { vk.fn("vkCmdDrawIndexed", PFN_vkCmdDrawIndexed.self)(cb, 3, 1, 0, 0, 0) }
    } == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(vk.messages.contains { $0.contains("indexed draws") })
    #expect(record { cb in inPass(cb) { vk.fn("vkCmdDrawIndirect", PFN_vkCmdDrawIndirect.self)(cb, buffer, 0, 1, 16) } } == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(record { cb in
      vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, compute)
      vk.fn("vkCmdDispatchIndirect", PFN_vkCmdDispatchIndirect.self)(cb, buffer, 0)
    } == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(vk.messages.contains { $0.contains("indirect dispatch") })

    // Timestamps, and a pass that loads its attachment.
    var info = VkQueryPoolCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO
    info.queryType = VK_QUERY_TYPE_TIMESTAMP
    info.queryCount = 1
    var pool: VkQueryPool?
    _ = vk.fn("vkCreateQueryPool", PFN_vkCreateQueryPool.self)(vk.device, &info, nil, &pool)
    if pool != nil {
      #expect(record { cb in vk.fn("vkCmdWriteTimestamp", PFN_vkCmdWriteTimestamp.self)(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, pool, 0) } == VK_ERROR_FEATURE_NOT_PRESENT)
    }
    let loading = renderPass(vk, load: VK_ATTACHMENT_LOAD_OP_LOAD)
    #expect(record { cb in
      beginPass(vk, cb, loading, framebuffer(vk, loading, vk.view(image), 4), size: 4, clear: [0, 0, 0, 0])
      vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    } == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(vk.messages.contains { $0.contains("loads its attachment") })
    // Nothing was submitted by any of this.
    #expect(vk.gpu.submitted.isEmpty)
  }

  @Test func whatTheLayerLeavesOut() throws {
    let vk = VK()
    let layout = vk.pipelineLayout([])
    let pass = renderPass(vk)
    func made(_ o: PipelineOptions) -> VkResult { graphicsPipeline(vk, layout, pass, o).0 }

    var o = PipelineOptions()
    #expect(made(o) == VK_SUCCESS)
    o = PipelineOptions()
    o.cull = VK_CULL_MODE_BACK_BIT.rawValue
    #expect(made(o) == VK_ERROR_FEATURE_NOT_PRESENT)
    o = PipelineOptions()
    o.depthTest = true
    #expect(made(o) == VK_ERROR_FEATURE_NOT_PRESENT)
    o = PipelineOptions()
    o.blend = true
    o.blendFactor = VK_BLEND_FACTOR_ONE
    #expect(made(o) == VK_ERROR_FEATURE_NOT_PRESENT)
    o = PipelineOptions()
    o.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN
    #expect(made(o) == VK_ERROR_FEATURE_NOT_PRESENT)
    o = PipelineOptions()
    o.samples = VK_SAMPLE_COUNT_4_BIT
    #expect(made(o) == VK_ERROR_FEATURE_NOT_PRESENT)
    o = PipelineOptions()
    o.attributeFormat = VK_FORMAT_R16G16_SFLOAT
    #expect(made(o) == VK_ERROR_FEATURE_NOT_PRESENT)
    // Nothing the refusals touched reached the core.
    #expect(vk.gpu.graphicsPipelines.count == 1)

    // Images: 3D, mip levels, layers, formats, and a view of another format.
    var info = VkImageCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    info.imageType = VK_IMAGE_TYPE_2D
    info.format = VK_FORMAT_R8G8B8A8_UNORM
    info.extent = VkExtent3D(width: 4, height: 4, depth: 1)
    info.mipLevels = 1
    info.arrayLayers = 1
    info.samples = VK_SAMPLE_COUNT_1_BIT
    info.usage = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
    var out: VkImage?
    let create = vk.fn("vkCreateImage", PFN_vkCreateImage.self)
    #expect(create(vk.device, &info, nil, &out) == VK_SUCCESS)
    var bad = info
    bad.mipLevels = 2
    #expect(create(vk.device, &bad, nil, &out) == VK_ERROR_FEATURE_NOT_PRESENT)
    bad = info
    bad.arrayLayers = 2
    #expect(create(vk.device, &bad, nil, &out) == VK_ERROR_FEATURE_NOT_PRESENT)
    bad = info
    bad.imageType = VK_IMAGE_TYPE_3D
    bad.extent.depth = 4
    #expect(create(vk.device, &bad, nil, &out) == VK_ERROR_FEATURE_NOT_PRESENT)
    bad = info
    bad.format = VK_FORMAT_R16G16B16A16_SFLOAT
    #expect(create(vk.device, &bad, nil, &out) == VK_ERROR_FORMAT_NOT_SUPPORTED)
    bad = info
    bad.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue
    #expect(create(vk.device, &bad, nil, &out) == VK_ERROR_FEATURE_NOT_PRESENT)
    var viewInfo = VkImageViewCreateInfo()
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    viewInfo.image = vk.image(usage: VK_IMAGE_USAGE_SAMPLED_BIT.rawValue)
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
    viewInfo.format = VK_FORMAT_B8G8R8A8_UNORM
    viewInfo.subresourceRange = VkImageSubresourceRange(aspectMask: 1, baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    var v: VkImageView?
    #expect(vk.fn("vkCreateImageView", PFN_vkCreateImageView.self)(vk.device, &viewInfo, nil, &v) == VK_ERROR_FEATURE_NOT_PRESENT)
    viewInfo.format = VK_FORMAT_R8G8B8A8_UNORM
    viewInfo.subresourceRange.baseMipLevel = 1
    #expect(vk.fn("vkCreateImageView", PFN_vkCreateImageView.self)(vk.device, &viewInfo, nil, &v) == VK_ERROR_FEATURE_NOT_PRESENT)

    // Sampler modes the core has no word for.
    var sampler = VkSamplerCreateInfo()
    sampler.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    sampler.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
    sampler.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
    sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
    var s: VkSampler?
    #expect(vk.fn("vkCreateSampler", PFN_vkCreateSampler.self)(vk.device, &sampler, nil, &s) == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(vk.gpu.samplers.isEmpty)

    // Subpasses after the first, and secondary command buffers.
    var attachment = VkAttachmentDescription()
    attachment.format = VK_FORMAT_R8G8B8A8_UNORM
    attachment.samples = VK_SAMPLE_COUNT_1_BIT
    var subpasses = [VkSubpassDescription(), VkSubpassDescription()]
    var rp = VkRenderPassCreateInfo()
    rp.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
    rp.attachmentCount = 1
    rp.subpassCount = 2
    var passOut: VkRenderPass?
    withUnsafePointer(to: &attachment) { ap in
      subpasses.withUnsafeBufferPointer { sp in
        rp.pAttachments = ap
        rp.pSubpasses = sp.baseAddress
        #expect(vk.fn("vkCreateRenderPass", PFN_vkCreateRenderPass.self)(vk.device, &rp, nil, &passOut) == VK_ERROR_FEATURE_NOT_PRESENT)
      }
    }
    let cp = vk.commandPool()
    var alloc = VkCommandBufferAllocateInfo()
    alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    alloc.commandPool = cp
    alloc.level = VK_COMMAND_BUFFER_LEVEL_SECONDARY
    alloc.commandBufferCount = 1
    var secondary: VkCommandBuffer?
    #expect(vk.fn("vkAllocateCommandBuffers", PFN_vkAllocateCommandBuffers.self)(vk.device, &alloc, &secondary) == VK_ERROR_FEATURE_NOT_PRESENT)

    // A partial image copy, and push constants past the root block's.
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    let memory = vk.allocate(MemoryTypes.upload, 1024)
    let buffer = vk.buffer(512, usage: VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue, in: memory)
    let target = vk.image(usage: VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue)
    var region = VkBufferImageCopy(bufferOffset: 0, bufferRowLength: 0, bufferImageHeight: 0,
                                   imageSubresource: VkImageSubresourceLayers(aspectMask: 1, mipLevel: 0, baseArrayLayer: 0, layerCount: 1),
                                   imageOffset: VkOffset3D(x: 1, y: 0, z: 0), imageExtent: VkExtent3D(width: 2, height: 2, depth: 1))
    vk.fn("vkCmdCopyBufferToImage", PFN_vkCmdCopyBufferToImage.self)(cb, buffer, target, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
    #expect(vk.end(cb) == VK_ERROR_FEATURE_NOT_PRESENT)
    // A failed buffer is not run: the core never sees it.
    #expect(vk.gpu.submitted.isEmpty)

    // Push constants and pipeline layouts past what the root block holds.
    var range = VkPushConstantRange(stageFlags: 0xFFFF, offset: 0, size: 132)
    var plInfo = VkPipelineLayoutCreateInfo()
    plInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
    plInfo.pushConstantRangeCount = 1
    var pl: VkPipelineLayout?
    withUnsafePointer(to: &range) { rp in
      plInfo.pPushConstantRanges = rp
      #expect(vk.fn("vkCreatePipelineLayout", PFN_vkCreatePipelineLayout.self)(vk.device, &plInfo, nil, &pl) == VK_ERROR_FEATURE_NOT_PRESENT)
    }
    let five = (0..<5).map { _ in vk.setLayout([(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1)]) }
    #expect(five.count == 5)
    var fiveInfo = VkPipelineLayoutCreateInfo()
    fiveInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
    fiveInfo.setLayoutCount = 5
    five.withUnsafeBufferPointer { fp in
      fiveInfo.pSetLayouts = fp.baseAddress
      #expect(vk.fn("vkCreatePipelineLayout", PFN_vkCreatePipelineLayout.self)(vk.device, &fiveInfo, nil, &pl) == VK_ERROR_FEATURE_NOT_PRESENT)
    }
  }

  @Test func lowering() throws {
    let vk = VK()
    // A lowering that refuses a program's feature fails the pipeline with the feature's words.
    CoreDriver.lowering = { (_, _, _, _, _) throws(LoweringError) in throw .unsupported("a 3D image") }
    let layout = vk.pipelineLayout([])
    let (r, p) = vk.computePipeline(layout)
    #expect(r == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(p == nil)
    #expect(vk.messages.contains { $0.contains("a 3D image") })
    #expect(vk.gpu.computePipelines.isEmpty)
    CoreDriver.lowering = { (_, _, _, _, _) throws(LoweringError) in throw .malformed("not words") }
    #expect(vk.computePipeline(layout).0 == VkResult(rawValue: -1000012000))
    // What the lowering returns is what the core gets, as bytes, little end first.
    CoreDriver.lowering = { (_, _, _, _, _) throws(LoweringError) in [0x0403_0201, 0x0807_0605, 0, 0, 0] }
    #expect(vk.computePipeline(layout).0 == VK_SUCCESS)
    #expect(Array(vk.gpu.computePipelines[0].prefix(8)) == [1, 2, 3, 4, 5, 6, 7, 8])
  }

  // MARK: Memory

  @Test func arenaMemoryLivesUntilTheTimelinePasses() throws {
    let vk = VK()
    vk.gpu.autoComplete = false
    let layout = vk.pipelineLayout([])
    let (_, pipeline) = vk.computePipeline(layout)
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    func record() {
      vk.begin(cb)
      vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
      vk.fn("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb, 1, 1, 1)
      #expect(vk.end(cb) == VK_SUCCESS)
    }
    func arenas() -> [GPUMemory] { vk.gpu.allocations.filter { $0.size == 65536 } }

    // A buffer reset before it ever ran gives its arena back at once.
    record()
    #expect(arenas().count == 1)
    let first = arenas()[0]
    record()
    #expect(vk.gpu.freedMemory == [first.handle])
    #expect(arenas().count == 2)
    let arena = arenas()[1]

    // Submitted, it is the timeline's: freeing the buffer and its pool doesn't free the memory.
    #expect(vk.submit([cb]) == VK_SUCCESS)
    var cbs: [VkCommandBuffer?] = [cb]
    vk.fn("vkFreeCommandBuffers", PFN_vkFreeCommandBuffers.self)(vk.device, cp, 1, &cbs)
    vk.fn("vkDestroyCommandPool", PFN_vkDestroyCommandPool.self)(vk.device, cp, nil)
    #expect(!vk.gpu.freedMemory.contains(arena.handle))
    // And the timeline reaching it frees it at the next call that looks.
    vk.gpu.finish(1)
    #expect(!vk.gpu.freedMemory.contains(arena.handle))
    #expect(vk.fn("vkDeviceWaitIdle", PFN_vkDeviceWaitIdle.self)(vk.device) == VK_SUCCESS)
    #expect(vk.gpu.freedMemory.contains(arena.handle))
    #expect(vk.gpu.freedMemory.filter { $0 == arena.handle }.count == 1)
  }

  @Test func arenaOutlivesSeveralSubmissions() throws {
    let vk = VK()
    vk.gpu.autoComplete = false
    let layout = vk.pipelineLayout([])
    let (_, pipeline) = vk.computePipeline(layout)
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
    // Enough dispatches to fill a chunk and begin another: 256 blocks of 224 bytes, each on a 64-byte boundary, fit in 64 KB.
    for _ in 0..<300 { vk.fn("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb, 1, 1, 1) }
    #expect(vk.end(cb) == VK_SUCCESS)
    let chunks = vk.gpu.allocations.filter { $0.size == 65536 }
    #expect(chunks.count == 2)
    // Every root block is its own, and in a chunk.
    #expect(vk.submit([cb]) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let dispatches = vk.gpu.submitted[0].list.dispatches
    #expect(dispatches.count == 300)
    #expect(Set(dispatches.map { $0.root }).count == 300)
    for d in dispatches { #expect(chunks.contains { d.root >= $0.address && d.root + 224 <= $0.address + 65536 }) }
    // Two submissions of one buffer: its memory is held to the later.
    vk.fn("vkDestroyCommandPool", PFN_vkDestroyCommandPool.self)(vk.device, cp, nil)
    vk.gpu.finish(1)
    _ = vk.fn("vkGetFenceStatus", PFN_vkGetFenceStatus.self)(vk.device, vk.fence())
    #expect(vk.gpu.freedMemory.isEmpty)
    vk.gpu.finish(2)
    _ = vk.fn("vkGetFenceStatus", PFN_vkGetFenceStatus.self)(vk.device, vk.fence())
    #expect(Set(vk.gpu.freedMemory) == Set(chunks.map { $0.handle }))
  }

  @Test func memoryTypesAndMapping() throws {
    let vk = VK()
    var props = VkPhysicalDeviceMemoryProperties()
    vk.fn("vkGetPhysicalDeviceMemoryProperties", PFN_vkGetPhysicalDeviceMemoryProperties.self)(vk.physical, &props)
    #expect(props.memoryTypeCount == 3)
    let types = withUnsafeBytes(of: props.memoryTypes) { Array($0.bindMemory(to: VkMemoryType.self).prefix(3)) }
    #expect(types[0].propertyFlags == VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
    let visible = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
    #expect(types[1].propertyFlags & visible == visible)
    #expect(types[1].propertyFlags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT.rawValue == 0)
    #expect(types[2].propertyFlags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT.rawValue != 0)
    // One type per intent.
    _ = vk.allocate(0, 100)
    _ = vk.allocate(1, 200)
    _ = vk.allocate(2, 300)
    #expect(vk.gpu.allocations.map { $0.intent } == [.device, .upload, .readback])

    // Mapping gives the CPU pointer, offset; device memory has none.
    let up = vk.allocate(1, 256)
    var p: UnsafeMutableRawPointer?
    #expect(vk.fn("vkMapMemory", PFN_vkMapMemory.self)(vk.device, up, 16, ~0, 0, &p) == VK_SUCCESS)
    #expect(UInt(bitPattern: p) == UInt(bitPattern: vk.gpu.allocations[3].pointer) + 16)
    let local = vk.allocate(0, 64)
    #expect(vk.fn("vkMapMemory", PFN_vkMapMemory.self)(vk.device, local, 0, ~0, 0, &p) == VK_ERROR_MEMORY_MAP_FAILED)
    var bad = VkMemoryAllocateInfo()
    bad.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    bad.allocationSize = 16
    bad.memoryTypeIndex = 3
    var m: VkDeviceMemory?
    #expect(vk.fn("vkAllocateMemory", PFN_vkAllocateMemory.self)(vk.device, &bad, nil, &m) == VK_ERROR_FEATURE_NOT_PRESENT)

    // Requirements: any type, and a buffer's device address is its memory's plus where it is bound.
    let buffer = vk.buffer(100, usage: VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.rawValue, in: up, at: 32)
    var req = VkMemoryRequirements()
    vk.fn("vkGetBufferMemoryRequirements", PFN_vkGetBufferMemoryRequirements.self)(vk.device, buffer, &req)
    #expect(req.memoryTypeBits == 7 && req.size >= 100 && req.alignment > 0)
    #expect(vk.address(of: buffer) == vk.gpu.allocations[3].address + 32)
    // Freeing hands the memory back.
    vk.fn("vkFreeMemory", PFN_vkFreeMemory.self)(vk.device, up, nil)
    #expect(vk.gpu.freedMemory == [vk.gpu.allocations[3].handle])
  }

  // MARK: The physical device

  @Test func physicalDevice() throws {
    let vk = VK()
    var props = VkPhysicalDeviceProperties()
    vk.fn("vkGetPhysicalDeviceProperties", PFN_vkGetPhysicalDeviceProperties.self)(vk.physical, &props)
    #expect(props.apiVersion == 1 << 22 | 3 << 12)
    let name = withUnsafeBytes(of: props.deviceName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    #expect(name == "fake gpu")
    // The limits are the device's.
    #expect(props.limits.maxImageDimension2D == 4096)
    #expect(props.limits.maxPushConstantsSize == 128)
    #expect(props.limits.maxBoundDescriptorSets == 4)
    #expect(props.limits.maxPerStageDescriptorSampledImages == 8)
    #expect(props.limits.maxPerStageDescriptorSamplers == 4)
    #expect(props.limits.maxPerStageDescriptorStorageImages == 4)

    var count: UInt32 = 0
    let families = vk.fn("vkGetPhysicalDeviceQueueFamilyProperties", PFN_vkGetPhysicalDeviceQueueFamilyProperties.self)
    families(vk.physical, &count, nil)
    #expect(count == 1)
    var family = VkQueueFamilyProperties()
    families(vk.physical, &count, &family)
    #expect(family.queueFlags == VK_QUEUE_GRAPHICS_BIT.rawValue | VK_QUEUE_COMPUTE_BIT.rawValue | VK_QUEUE_TRANSFER_BIT.rawValue)
    #expect(family.queueCount == 1 && family.timestampValidBits == 64)

    // The features: buffer device address, timeline semaphores, dynamic rendering and synchronization 2, and what is chained gets them.
    var v12 = VkPhysicalDeviceVulkan12Features()
    v12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    var v13 = VkPhysicalDeviceVulkan13Features()
    v13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
    withUnsafeMutablePointer(to: &v13) { p13 in
      v12.pNext = UnsafeMutableRawPointer(p13)
      withUnsafeMutablePointer(to: &v12) { p12 in
        var f2 = VkPhysicalDeviceFeatures2()
        f2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
        f2.pNext = UnsafeMutableRawPointer(p12)
        vk.fn("vkGetPhysicalDeviceFeatures2", PFN_vkGetPhysicalDeviceFeatures2.self)(vk.physical, &f2)
        #expect(f2.features.fullDrawIndexUint32 == 1)
        #expect(f2.features.geometryShader == 0)
        #expect(p12.pointee.bufferDeviceAddress == 1 && p12.pointee.timelineSemaphore == 1)
        #expect(p12.pointee.descriptorIndexing == 0)
        #expect(p13.pointee.dynamicRendering == 1 && p13.pointee.synchronization2 == 1)
        #expect(p13.pointee.maintenance4 == 0)
      }
    }

    // A device that asks for a feature it hasn't fails.
    var asked = VkPhysicalDeviceFeatures()
    asked.geometryShader = 1
    var q = VkDeviceQueueCreateInfo()
    q.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    q.queueCount = 1
    var info = VkDeviceCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
    info.queueCreateInfoCount = 1
    var out: VkDevice?
    withUnsafePointer(to: &q) { qp in
      withUnsafePointer(to: &asked) { ap in
        info.pQueueCreateInfos = qp
        info.pEnabledFeatures = ap
        #expect(vk.fn("vkCreateDevice", PFN_vkCreateDevice.self)(vk.physical, &info, nil, &out) == VK_ERROR_FEATURE_NOT_PRESENT)
      }
    }
    #expect(out == nil)
  }

  @Test func instanceNeedsADevice() throws {
    let vk = VK()
    var info = VkInstanceCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
    var out: VkInstance?
    let create = vk.fn("vkCreateInstance", PFN_vkCreateInstance.self)
    CoreDriver.device = nil
    #expect(create(&info, nil, &out) == VK_ERROR_INCOMPATIBLE_DRIVER)
    CoreDriver.device = { () throws(GPUError) in throw GPUError.noDevice("none") }
    #expect(create(&info, nil, &out) == VK_ERROR_INCOMPATIBLE_DRIVER)
    #expect(out == nil)
    // The commands are given out by name, and a name that isn't one is nil.
    #expect("vkCmdDraw".withCString { coreGetInstanceProcAddr(nil, $0) } != nil)
    #expect("vkCmdDraw".withCString { coreGetDeviceProcAddr(vk.device, $0) } != nil)
    // The loader reads vkGetDeviceProcAddr and the layer's own vkGetInstanceProcAddr from its table, by name.
    let gdpa = vk.fn("vkGetDeviceProcAddr", PFN_vkGetDeviceProcAddr.self)
    let gipa = vk.fn("vkGetInstanceProcAddr", PFN_vkGetInstanceProcAddr.self)
    let viaTable = "vkCmdDraw".withCString { unsafeBitCast(gdpa(vk.device, $0), to: UnsafeRawPointer?.self) }
    #expect(viaTable != nil && viaTable == "vkCmdDraw".withCString { coreGetDeviceProcAddr(vk.device, $0) })
    #expect("vkCreateBuffer".withCString { gipa(vk.instance, $0) } != nil)
    #expect("vkCmdTraceRaysKHR".withCString { coreGetInstanceProcAddr(nil, $0) } == nil)
  }

  @Test func dispatchableObjectsLeaveTheLoaderItsWord() throws {
    let vk = VK()
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    for h in [UnsafeRawPointer(vk.instance), UnsafeRawPointer(vk.physical), UnsafeRawPointer(vk.device), UnsafeRawPointer(vk.queue),
              UnsafeRawPointer(cb)] {
      #expect(h!.load(as: UInt64.self) == 0x01CD_C0DE)
    }
    // The loader puts its table there; the layer keeps working.
    for h in [UnsafeMutableRawPointer(vk.instance!), UnsafeMutableRawPointer(vk.device!), UnsafeMutableRawPointer(vk.queue!)] {
      h.storeBytes(of: 0x1234, as: UInt64.self)
    }
    vk.begin(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
  }
}
