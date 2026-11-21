// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan layer whole (D174 step 5): VulkanCoreDriver, reached through its vkGetInstanceProcAddr as the loader
// reaches it, with the real lowering, over the Mali backend on a fake transport. The lowering's own SPIR-V
// (saxpy.comp, geometry.vert, textured.frag) makes a compute and a graphics pipeline, so the Valhall compile runs;
// a dispatch and a draw in a render pass are submitted, and the root blocks the layer wrote are read back to see
// the push constants and the set records where the lowered shaders read them.

import Foundation
import GPUCore
import GPUCoreMali
import MaliFakeTransport
import TDVulkan
import Testing
import VulkanLowering

@testable import VulkanCoreDriver

private let shaders = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("drivers/core/lowering/tests/shaders").path

private func spirv(_ name: String) -> [UInt32] {
  let data = FileManager.default.contents(atPath: shaders + "/" + name)!
  return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
}

private func call<T>(_ name: String, _ type: T.Type) -> T {
  let p = name.withCString { coreGetInstanceProcAddr(nil, $0) }
  return unsafeBitCast(p!, to: T.self)
}

@Suite(.serialized) struct VulkanLayerTests {
  let transport = FakeTransport()
  var device: VkDevice?
  var queue: VkQueue?

  init() throws {
    let mali = try MaliDevice(transport: transport)
    CoreDriver.device = { mali }
    // The real lowering.
    CoreDriver.lowering = { (s, st, e, l) throws(LoweringError) in try lower(spirv: s, stage: st, entryPoint: e, layout: l) }
    CoreDriver.message = nil
    var info = VkInstanceCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
    var instance: VkInstance?
    #expect(call("vkCreateInstance", PFN_vkCreateInstance.self)(&info, nil, &instance) == VK_SUCCESS)
    var n: UInt32 = 1
    var physical: VkPhysicalDevice?
    #expect(call("vkEnumeratePhysicalDevices", PFN_vkEnumeratePhysicalDevices.self)(instance, &n, &physical) == VK_SUCCESS)
    var q = VkDeviceQueueCreateInfo()
    q.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    q.queueCount = 1
    var d = VkDeviceCreateInfo()
    d.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
    d.queueCreateInfoCount = 1
    withUnsafePointer(to: &q) { qp in
      d.pQueueCreateInfos = qp
      #expect(call("vkCreateDevice", PFN_vkCreateDevice.self)(physical, &d, nil, &device) == VK_SUCCESS)
    }
    call("vkGetDeviceQueue", PFN_vkGetDeviceQueue.self)(device, 0, 0, &queue)
  }

  /// Host memory of GPU `address`, in the buffers the fake transport has bound.
  func cpu(_ address: UInt64) -> UnsafeMutableRawPointer {
    for (base, buffer) in transport.bound where address >= base && address < base + UInt64(buffer.size) {
      return buffer.pointer + Int(address - base)
    }
    fatalError("no buffer holds \(address)")
  }

  func memory(_ type: UInt32, _ size: UInt64) -> VkDeviceMemory? {
    var info = VkMemoryAllocateInfo()
    info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    info.allocationSize = size
    info.memoryTypeIndex = type
    var m: VkDeviceMemory?
    #expect(call("vkAllocateMemory", PFN_vkAllocateMemory.self)(device, &info, nil, &m) == VK_SUCCESS)
    return m
  }

  func buffer(_ size: UInt64, _ usage: VkBufferUsageFlagBits, in mem: VkDeviceMemory?, at offset: UInt64) -> VkBuffer? {
    var info = VkBufferCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    info.size = size
    info.usage = usage.rawValue
    var b: VkBuffer?
    #expect(call("vkCreateBuffer", PFN_vkCreateBuffer.self)(device, &info, nil, &b) == VK_SUCCESS)
    #expect(call("vkBindBufferMemory", PFN_vkBindBufferMemory.self)(device, b, mem, offset) == VK_SUCCESS)
    return b
  }

  func address(_ b: VkBuffer?) -> UInt64 {
    var info = VkBufferDeviceAddressInfo()
    info.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO
    info.buffer = b
    return call("vkGetBufferDeviceAddress", PFN_vkGetBufferDeviceAddress.self)(device, &info)
  }

  func setLayout(_ bindings: [(UInt32, VkDescriptorType)]) -> VkDescriptorSetLayout? {
    let b = bindings.map {
      VkDescriptorSetLayoutBinding(binding: $0.0, descriptorType: $0.1, descriptorCount: 1, stageFlags: VK_SHADER_STAGE_ALL.rawValue,
                                   pImmutableSamplers: nil)
    }
    var out: VkDescriptorSetLayout?
    b.withUnsafeBufferPointer { bp in
      var info = VkDescriptorSetLayoutCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
      info.bindingCount = UInt32(b.count)
      info.pBindings = bp.baseAddress
      #expect(call("vkCreateDescriptorSetLayout", PFN_vkCreateDescriptorSetLayout.self)(device, &info, nil, &out) == VK_SUCCESS)
    }
    return out
  }

  func pipelineLayout(_ sets: [VkDescriptorSetLayout?], push: UInt32) -> VkPipelineLayout? {
    var out: VkPipelineLayout?
    var range = VkPushConstantRange(stageFlags: VK_SHADER_STAGE_ALL.rawValue, offset: 0, size: push)
    sets.withUnsafeBufferPointer { sp in
      withUnsafePointer(to: &range) { rp in
        var info = VkPipelineLayoutCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        info.setLayoutCount = UInt32(sets.count)
        info.pSetLayouts = sp.baseAddress
        info.pushConstantRangeCount = push > 0 ? 1 : 0
        info.pPushConstantRanges = push > 0 ? rp : nil
        #expect(call("vkCreatePipelineLayout", PFN_vkCreatePipelineLayout.self)(device, &info, nil, &out) == VK_SUCCESS)
      }
    }
    return out
  }

  func module(_ name: String) -> VkShaderModule? {
    let words = spirv(name)
    var out: VkShaderModule?
    words.withUnsafeBufferPointer { wp in
      var info = VkShaderModuleCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
      info.codeSize = words.count * 4
      info.pCode = wp.baseAddress
      #expect(call("vkCreateShaderModule", PFN_vkCreateShaderModule.self)(device, &info, nil, &out) == VK_SUCCESS)
    }
    return out
  }

  func pool(sets: UInt32, _ sizes: [(VkDescriptorType, UInt32)]) -> VkDescriptorPool? {
    let s = sizes.map { VkDescriptorPoolSize(type: $0.0, descriptorCount: $0.1) }
    var out: VkDescriptorPool?
    s.withUnsafeBufferPointer { sp in
      var info = VkDescriptorPoolCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
      info.maxSets = sets
      info.poolSizeCount = UInt32(s.count)
      info.pPoolSizes = sp.baseAddress
      #expect(call("vkCreateDescriptorPool", PFN_vkCreateDescriptorPool.self)(device, &info, nil, &out) == VK_SUCCESS)
    }
    return out
  }

  func allocate(_ pool: VkDescriptorPool?, _ layout: VkDescriptorSetLayout?) -> VkDescriptorSet? {
    var l = layout
    var out: VkDescriptorSet?
    withUnsafePointer(to: &l) { lp in
      var info = VkDescriptorSetAllocateInfo()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
      info.descriptorPool = pool
      info.descriptorSetCount = 1
      info.pSetLayouts = lp
      #expect(call("vkAllocateDescriptorSets", PFN_vkAllocateDescriptorSets.self)(device, &info, &out) == VK_SUCCESS)
    }
    return out
  }

  func stage(_ s: VkShaderStageFlagBits, _ m: VkShaderModule?, _ name: UnsafePointer<CChar>) -> VkPipelineShaderStageCreateInfo {
    VkPipelineShaderStageCreateInfo(sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, pNext: nil, flags: 0, stage: s,
                                    module: m, pName: name, pSpecializationInfo: nil)
  }

  @Test func computeAndTriangleThroughTheRealLoweringAndTheMaliBackend() throws {
    let device = device
    let t = transport

    // MARK: Compute: saxpy.comp
    let upload = memory(1, 8192)
    let usage = VkBufferUsageFlagBits(rawValue: VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue)
    let input = buffer(256, usage, in: upload, at: 0)
    let output = buffer(256, usage, in: upload, at: 512)
    let computeSet = setLayout([(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER), (1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER)])
    let computeLayout = pipelineLayout([computeSet], push: 8)
    var computePipeline: VkPipeline?
    "main".withCString { name in
      var info = VkComputePipelineCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
      info.stage = stage(VK_SHADER_STAGE_COMPUTE_BIT, module("saxpy.comp.spv"), name)
      info.layout = computeLayout
      #expect(call("vkCreateComputePipelines", PFN_vkCreateComputePipelines.self)(device, nil, 1, &info, nil, &computePipeline) == VK_SUCCESS)
    }
    #expect(computePipeline != nil)

    let storagePool = pool(sets: 1, [(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2)])
    let storageSet = allocate(storagePool, computeSet)
    var buffers = [VkDescriptorBufferInfo(buffer: input, offset: 0, range: 256), VkDescriptorBufferInfo(buffer: output, offset: 0, range: ~0)]
    var writes = [VkWriteDescriptorSet(), VkWriteDescriptorSet()]
    buffers.withUnsafeMutableBufferPointer { bp in
      for i in 0..<2 {
        writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
        writes[i].dstSet = storageSet
        writes[i].dstBinding = UInt32(i)
        writes[i].descriptorCount = 1
        writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
        writes[i].pBufferInfo = UnsafePointer(bp.baseAddress! + i)
      }
      call("vkUpdateDescriptorSets", PFN_vkUpdateDescriptorSets.self)(device, 2, &writes, 0, nil)
    }

    // MARK: Graphics: geometry.vert and textured.frag, with the texture in set 1
    let image = {
      var info = VkImageCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
      info.imageType = VK_IMAGE_TYPE_2D
      info.format = VK_FORMAT_R8G8B8A8_UNORM
      info.extent = VkExtent3D(width: 8, height: 8, depth: 1)
      info.mipLevels = 1
      info.arrayLayers = 1
      info.samples = VK_SAMPLE_COUNT_1_BIT
      info.usage = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
      var i: VkImage?
      #expect(call("vkCreateImage", PFN_vkCreateImage.self)(device, &info, nil, &i) == VK_SUCCESS)
      return i
    }()
    let target = {
      var info = VkImageCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
      info.imageType = VK_IMAGE_TYPE_2D
      info.format = VK_FORMAT_R8G8B8A8_UNORM
      info.extent = VkExtent3D(width: 16, height: 16, depth: 1)
      info.mipLevels = 1
      info.arrayLayers = 1
      info.samples = VK_SAMPLE_COUNT_1_BIT
      info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
      var i: VkImage?
      #expect(call("vkCreateImage", PFN_vkCreateImage.self)(device, &info, nil, &i) == VK_SUCCESS)
      return i
    }()
    func view(_ i: VkImage?) -> VkImageView? {
      var info = VkImageViewCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
      info.image = i
      info.viewType = VK_IMAGE_VIEW_TYPE_2D
      info.format = VK_FORMAT_R8G8B8A8_UNORM
      info.subresourceRange = VkImageSubresourceRange(aspectMask: 1, baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
      var v: VkImageView?
      #expect(call("vkCreateImageView", PFN_vkCreateImageView.self)(device, &info, nil, &v) == VK_SUCCESS)
      return v
    }
    let textureView = view(image)
    let targetView = view(target)
    var samplerInfo = VkSamplerCreateInfo()
    samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    samplerInfo.magFilter = VK_FILTER_LINEAR
    samplerInfo.minFilter = VK_FILTER_LINEAR
    samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    var sampler: VkSampler?
    #expect(call("vkCreateSampler", PFN_vkCreateSampler.self)(device, &samplerInfo, nil, &sampler) == VK_SUCCESS)

    let paramsBuffer = buffer(32, VkBufferUsageFlagBits(rawValue: VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue), in: upload, at: 1024)
    let vertices = buffer(48, VkBufferUsageFlagBits(rawValue: VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue), in: upload, at: 2048)
    let instances = buffer(8, VkBufferUsageFlagBits(rawValue: VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue), in: upload, at: 3072)
    let graphicsSet = setLayout([(0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER), (1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)])
    // Set 0 isn't used by these shaders: the layout has none there.
    let graphicsLayout = pipelineLayout([nil, graphicsSet], push: 0)

    var attachment = VkAttachmentDescription(
      flags: 0, format: VK_FORMAT_R8G8B8A8_UNORM, samples: VK_SAMPLE_COUNT_1_BIT, loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
      storeOp: VK_ATTACHMENT_STORE_OP_STORE, stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
      stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE, initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
      finalLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
    var reference = VkAttachmentReference(attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    var renderPass: VkRenderPass?
    withUnsafePointer(to: &reference) { rp in
      var subpass = VkSubpassDescription()
      subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
      subpass.colorAttachmentCount = 1
      subpass.pColorAttachments = rp
      withUnsafePointer(to: &attachment) { ap in
        withUnsafePointer(to: &subpass) { sp in
          var info = VkRenderPassCreateInfo()
          info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
          info.attachmentCount = 1
          info.pAttachments = ap
          info.subpassCount = 1
          info.pSubpasses = sp
          #expect(call("vkCreateRenderPass", PFN_vkCreateRenderPass.self)(device, &info, nil, &renderPass) == VK_SUCCESS)
        }
      }
    }
    var framebuffer: VkFramebuffer?
    var tv = targetView
    withUnsafePointer(to: &tv) { vp in
      var info = VkFramebufferCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
      info.renderPass = renderPass
      info.attachmentCount = 1
      info.pAttachments = vp
      info.width = 16
      info.height = 16
      info.layers = 1
      #expect(call("vkCreateFramebuffer", PFN_vkCreateFramebuffer.self)(device, &info, nil, &framebuffer) == VK_SUCCESS)
    }

    var graphicsPipeline: VkPipeline?
    "main".withCString { name in
      var stages = [stage(VK_SHADER_STAGE_VERTEX_BIT, module("geometry.vert.spv"), name),
                    stage(VK_SHADER_STAGE_FRAGMENT_BIT, module("textured.frag.spv"), name)]
      var bindings = [VkVertexInputBindingDescription(binding: 0, stride: 16, inputRate: VK_VERTEX_INPUT_RATE_VERTEX),
                      VkVertexInputBindingDescription(binding: 1, stride: 8, inputRate: VK_VERTEX_INPUT_RATE_INSTANCE)]
      var attributes = [VkVertexInputAttributeDescription(location: 0, binding: 0, format: VK_FORMAT_R32G32B32_SFLOAT, offset: 0),
                        VkVertexInputAttributeDescription(location: 1, binding: 0, format: VK_FORMAT_R8G8B8A8_UNORM, offset: 12),
                        VkVertexInputAttributeDescription(location: 2, binding: 1, format: VK_FORMAT_R32G32_SFLOAT, offset: 0)]
      var vertexState = VkPipelineVertexInputStateCreateInfo()
      vertexState.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
      vertexState.vertexBindingDescriptionCount = 2
      vertexState.vertexAttributeDescriptionCount = 3
      var assembly = VkPipelineInputAssemblyStateCreateInfo()
      assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
      assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
      var raster = VkPipelineRasterizationStateCreateInfo()
      raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
      raster.polygonMode = VK_POLYGON_MODE_FILL
      raster.lineWidth = 1
      var blendAttachment = VkPipelineColorBlendAttachmentState()
      blendAttachment.colorWriteMask = 15
      var blend = VkPipelineColorBlendStateCreateInfo()
      blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
      blend.attachmentCount = 1
      var info = VkGraphicsPipelineCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
      info.stageCount = 2
      info.layout = graphicsLayout
      info.renderPass = renderPass
      var result = VK_ERROR_UNKNOWN
      stages.withUnsafeBufferPointer { st in
        bindings.withUnsafeBufferPointer { bp in
          attributes.withUnsafeBufferPointer { ap in
            withUnsafePointer(to: &blendAttachment) { bap in
              info.pStages = st.baseAddress
              vertexState.pVertexBindingDescriptions = bp.baseAddress
              vertexState.pVertexAttributeDescriptions = ap.baseAddress
              blend.pAttachments = bap
              withUnsafePointer(to: &vertexState) { info.pVertexInputState = $0 }
              withUnsafePointer(to: &assembly) { info.pInputAssemblyState = $0 }
              withUnsafePointer(to: &raster) { info.pRasterizationState = $0 }
              withUnsafePointer(to: &blend) { info.pColorBlendState = $0 }
              result = call("vkCreateGraphicsPipelines", PFN_vkCreateGraphicsPipelines.self)(device, nil, 1, &info, nil, &graphicsPipeline)
            }
          }
        }
      }
      #expect(result == VK_SUCCESS)
    }
    #expect(graphicsPipeline != nil)
    let compiled = t.created

    let graphicsPool = pool(sets: 1, [(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1), (VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1)])
    let texSet = allocate(graphicsPool, graphicsSet)
    var uniform = VkDescriptorBufferInfo(buffer: paramsBuffer, offset: 0, range: 32)
    var combined = VkDescriptorImageInfo(sampler: sampler, imageView: textureView, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    var gw = [VkWriteDescriptorSet(), VkWriteDescriptorSet()]
    withUnsafePointer(to: &uniform) { up in
      withUnsafePointer(to: &combined) { cp in
        gw[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
        gw[0].dstSet = texSet
        gw[0].dstBinding = 0
        gw[0].descriptorCount = 1
        gw[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        gw[0].pBufferInfo = up
        gw[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
        gw[1].dstSet = texSet
        gw[1].dstBinding = 1
        gw[1].descriptorCount = 1
        gw[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
        gw[1].pImageInfo = cp
        call("vkUpdateDescriptorSets", PFN_vkUpdateDescriptorSets.self)(device, 2, &gw, 0, nil)
      }
    }

    // MARK: Record: a dispatch, then a draw in a pass
    var poolInfo = VkCommandPoolCreateInfo()
    poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
    var commandPool: VkCommandPool?
    #expect(call("vkCreateCommandPool", PFN_vkCreateCommandPool.self)(device, &poolInfo, nil, &commandPool) == VK_SUCCESS)
    var alloc = VkCommandBufferAllocateInfo()
    alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    alloc.commandPool = commandPool
    alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
    alloc.commandBufferCount = 1
    var cb: VkCommandBuffer?
    #expect(call("vkAllocateCommandBuffers", PFN_vkAllocateCommandBuffers.self)(device, &alloc, &cb) == VK_SUCCESS)
    var begin = VkCommandBufferBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    #expect(call("vkBeginCommandBuffer", PFN_vkBeginCommandBuffer.self)(cb, &begin) == VK_SUCCESS)

    call("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, computePipeline)
    var sets: [VkDescriptorSet?] = [storageSet]
    call("vkCmdBindDescriptorSets", PFN_vkCmdBindDescriptorSets.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, computeLayout, 0, 1, &sets, 0, nil)
    var push: [UInt32] = [Float(2.5).bitPattern, 100]
    call("vkCmdPushConstants", PFN_vkCmdPushConstants.self)(cb, computeLayout, VK_SHADER_STAGE_ALL.rawValue, 0, 8, &push)
    call("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb, 2, 1, 1)
    call("vkCmdPipelineBarrier", PFN_vkCmdPipelineBarrier.self)(
      cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT.rawValue, VK_PIPELINE_STAGE_VERTEX_INPUT_BIT.rawValue, 0, 0, nil, 0, nil, 0, nil)

    var clear = VkClearValue()
    unsafe clear.color.float32 = (0, 0, 0, 1)
    var begin2 = VkRenderPassBeginInfo()
    begin2.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    begin2.renderPass = renderPass
    begin2.framebuffer = framebuffer
    begin2.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 16, height: 16))
    begin2.clearValueCount = 1
    withUnsafePointer(to: &clear) { cv in
      begin2.pClearValues = cv
      call("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(cb, &begin2, VK_SUBPASS_CONTENTS_INLINE)
    }
    call("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, graphicsPipeline)
    var texSets: [VkDescriptorSet?] = [texSet]
    call("vkCmdBindDescriptorSets", PFN_vkCmdBindDescriptorSets.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, graphicsLayout, 1, 1, &texSets, 0, nil)
    var vbs: [VkBuffer?] = [vertices, instances]
    var vbOffsets: [UInt64] = [0, 0]
    call("vkCmdBindVertexBuffers", PFN_vkCmdBindVertexBuffers.self)(cb, 0, 2, &vbs, &vbOffsets)
    call("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 1, 0, 0)
    call("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(call("vkEndCommandBuffer", PFN_vkEndCommandBuffer.self)(cb) == VK_SUCCESS)

    // MARK: Submit
    var fenceInfo = VkFenceCreateInfo()
    fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
    var fence: VkFence?
    #expect(call("vkCreateFence", PFN_vkCreateFence.self)(device, &fenceInfo, nil, &fence) == VK_SUCCESS)
    var submit = VkSubmitInfo()
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
    submit.commandBufferCount = 1
    var submitted = cb
    withUnsafePointer(to: &submitted) { cp in
      submit.pCommandBuffers = cp
      #expect(call("vkQueueSubmit", PFN_vkQueueSubmit.self)(queue, 1, &submit, fence) == VK_SUCCESS)
    }
    #expect(call("vkWaitForFences", PFN_vkWaitForFences.self)(device, 1, &fence, 1, 1_000_000_000) == VK_SUCCESS)
    #expect(call("vkGetFenceStatus", PFN_vkGetFenceStatus.self)(device, fence) == VK_SUCCESS)

    // The backend ran work and signalled the timeline: the jobs of the dispatch and of the pass.
    #expect(!t.submits.isEmpty)
    #expect(t.submits.contains { !$0.signals.isEmpty })
    #expect(t.syncs.values.contains { $0 >= 1 })
    #expect(compiled >= 1)

    // MARK: The root blocks
    // The arena's chunk is the 64 KB buffer bound last; the dispatch's block is first in it and the draw's next, 256 bytes on.
    let chunk = try #require(t.bound.first { $0.buffer.size == 65536 })
    let dispatchRoot = chunk.address
    let drawRoot = chunk.address + 256
    func word64(_ a: UInt64) -> UInt64 { cpu(a).loadUnaligned(as: UInt64.self) }
    func word32(_ a: UInt64) -> UInt32 { cpu(a).loadUnaligned(as: UInt32.self) }

    // Compute: set 0's record, then the push constants where the lowered shader reads them (96 and 100).
    let record0 = word64(dispatchRoot + UInt64(RootBlock.setsOffset))
    #expect(record0 != 0)
    #expect(word64(dispatchRoot + UInt64(RootBlock.setsOffset + 8)) == 0)
    #expect(word64(record0) == address(input))
    #expect(word64(record0 + 8) == 256)
    #expect(word64(record0 + 16) == address(output))
    #expect(word64(record0 + 24) == 256)
    #expect(word32(dispatchRoot + UInt64(RootBlock.pushConstantsOffset)) == Float(2.5).bitPattern)
    #expect(word32(dispatchRoot + UInt64(RootBlock.pushConstantsOffset + 4)) == 100)

    // Graphics: set 0 unbound, set 1 the texture's record (the uniform buffer, then slot 0 and sampler 0), the vertex buffers.
    #expect(word64(drawRoot + UInt64(RootBlock.setsOffset)) == 0)
    let record1 = word64(drawRoot + UInt64(RootBlock.setsOffset + 8))
    #expect(record1 != 0)
    #expect(word64(record1) == address(paramsBuffer))
    #expect(word64(record1 + 8) == 32)
    #expect(word32(record1 + 16) == 0)
    #expect(word32(record1 + 20) == 0)
    #expect(word64(drawRoot + UInt64(RootBlock.vertexBuffersOffset)) == address(vertices))
    #expect(word64(drawRoot + UInt64(RootBlock.vertexBuffersOffset + 8)) == address(instances))
    #expect(word64(drawRoot + UInt64(RootBlock.vertexBuffersOffset + 16)) == 0)
  }
}
