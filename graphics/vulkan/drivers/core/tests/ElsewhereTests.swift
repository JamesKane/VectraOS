// SPDX-License-Identifier: BSD-3-Clause

// The layer's viewports and sparse resources: more than one viewport and scissor, with their depths, from a pipeline's
// viewport state and from the dynamic commands; and sparse buffers and images, their requirements, and vkQueueBindSparse
// as the core's bindSparse in order on the one timeline. The device is the full-feature fake with these on.

import GPUCore
import Testing
import TDVulkan
@testable import VulkanCoreDriver
import VulkanLowering

/// The full-feature fake, with 16 viewports and the sparse features.
func elsewhereVK(multiViewport: Bool = true, sparse: Bool = true) -> VK {
  var l = FakeGPU.fullLimits()
  l.features.multiViewport = multiViewport
  l.features.shaderOutputViewportIndex = multiViewport
  l.maxViewports = multiViewport ? 16 : 1
  l.maxViewportWidth = 8192
  l.maxViewportHeight = 4096
  l.viewportBoundsMin = -16384
  l.viewportBoundsMax = 16383
  l.viewportSubPixelBits = 8
  if sparse {
    l.features.sparseBinding = true
    l.features.sparseResidencyBuffer = true
    l.features.sparseResidencyImage2D = true
    l.features.sparseResidencyAliased = true
    l.sparseAddressSpaceSize = 1 << 40
    l.sparse.residencyStandard2DBlockShape = true
    l.sparse.residencyNonResidentStrict = true
  }
  return VK(gpu: FakeGPU(limits: l))
}

extension VulkanCoreDriverTests {
  // MARK: Features and limits

  @Test func viewportAndSparseFeaturesAndLimitsAreTheDevices() throws {
    let vk = elsewhereVK()
    var f = VkPhysicalDeviceFeatures()
    vk.fn("vkGetPhysicalDeviceFeatures", PFN_vkGetPhysicalDeviceFeatures.self)(vk.physical, &f)
    #expect(f.multiViewport == 1 && f.sparseBinding == 1 && f.sparseResidencyBuffer == 1 && f.sparseResidencyImage2D == 1)
    #expect(f.sparseResidencyAliased == 1 && f.sparseResidencyImage3D == 0 && f.sparseResidency4Samples == 0)
    var v12 = VkPhysicalDeviceVulkan12Features()
    v12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    withUnsafeMutablePointer(to: &v12) { p in
      var f2 = VkPhysicalDeviceFeatures2()
      f2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
      f2.pNext = UnsafeMutableRawPointer(p)
      vk.fn("vkGetPhysicalDeviceFeatures2", PFN_vkGetPhysicalDeviceFeatures2.self)(vk.physical, &f2)
    }
    #expect(v12.shaderOutputViewportIndex == 1 && v12.shaderOutputLayer == 1)

    var p = VkPhysicalDeviceProperties()
    vk.fn("vkGetPhysicalDeviceProperties", PFN_vkGetPhysicalDeviceProperties.self)(vk.physical, &p)
    #expect(p.limits.maxViewports == 16 && p.limits.maxViewportDimensions.0 == 8192 && p.limits.maxViewportDimensions.1 == 4096)
    #expect(p.limits.viewportBoundsRange.0 == -16384 && p.limits.viewportBoundsRange.1 == 16383 && p.limits.viewportSubPixelBits == 8)
    #expect(p.limits.sparseAddressSpaceSize == 1 << 40)
    #expect(p.sparseProperties.residencyStandard2DBlockShape == 1 && p.sparseProperties.residencyNonResidentStrict == 1)
    #expect(p.sparseProperties.residencyStandard3DBlockShape == 0)

    var q = VkQueueFamilyProperties()
    var n: UInt32 = 1
    vk.fn("vkGetPhysicalDeviceQueueFamilyProperties", PFN_vkGetPhysicalDeviceQueueFamilyProperties.self)(vk.physical, &n, &q)
    #expect(q.queueFlags & VK_QUEUE_SPARSE_BINDING_BIT.rawValue != 0)

    // The device without them says so, and a device asking for them isn't made.
    let old = fullVK()
    old.fn("vkGetPhysicalDeviceProperties", PFN_vkGetPhysicalDeviceProperties.self)(old.physical, &p)
    #expect(p.limits.maxViewports == 1 && p.limits.sparseAddressSpaceSize == 0 && p.sparseProperties.residencyStandard2DBlockShape == 0)
    old.fn("vkGetPhysicalDeviceQueueFamilyProperties", PFN_vkGetPhysicalDeviceQueueFamilyProperties.self)(old.physical, &n, &q)
    #expect(q.queueFlags & VK_QUEUE_SPARSE_BINDING_BIT.rawValue == 0)
    func create(_ vk: VK, _ set: (inout VkPhysicalDeviceFeatures) -> Void) -> VkResult {
      var queue = VkDeviceQueueCreateInfo()
      queue.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
      queue.queueCount = 1
      queue.pQueuePriorities = leak([Float(1)])
      var features = VkPhysicalDeviceFeatures()
      set(&features)
      var d = VkDeviceCreateInfo()
      d.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
      d.queueCreateInfoCount = 1
      d.pQueueCreateInfos = leak([queue])
      d.pEnabledFeatures = leak([features])
      var device: VkDevice?
      return vk.fn("vkCreateDevice", PFN_vkCreateDevice.self)(vk.physical, &d, nil, &device)
    }
    #expect(create(vk) { $0.multiViewport = 1; $0.sparseBinding = 1; $0.sparseResidencyBuffer = 1 } == VK_SUCCESS)
    #expect(create(old) { $0.multiViewport = 1 } == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(create(old) { $0.sparseBinding = 1 } == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  // MARK: Viewports

  /// A render pass of one colour attachment, a framebuffer over an 8 by 8 image, and a command buffer begun inside it.
  func passAndBuffer(_ vk: VK) -> (VkRenderPass?, VkCommandBuffer?) {
    let (_, pass) = makePass(vk, [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)], [SubpassSpec(colors: [0])])
    let image = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, usage: colorUsage).1
    let fb = makeFramebuffer(vk, pass, [vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM).1], 8, 8)
    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    var begin = VkRenderPassBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    begin.renderPass = pass
    begin.framebuffer = fb
    begin.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    var clear = VkClearValue()
    begin.clearValueCount = 1
    withUnsafePointer(to: &clear) { c in
      begin.pClearValues = c
      vk.fn("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(cb, &begin, VK_SUBPASS_CONTENTS_INLINE)
    }
    return (pass, cb)
  }

  @Test func twoDynamicViewportsAndScissorsReachTheCoreWithTheirDepths() throws {
    let vk = elsewhereVK()
    let (pass, cb) = passAndBuffer(vk)
    var p = Pieces()
    p.blendAttachments = [blendAttachment()]
    p.viewportCount = 2
    let (r, pipeline) = buildPipeline(vk, vk.pipelineLayout([]), pass, p)
    #expect(r == VK_SUCCESS)
    #expect(vk.gpu.graphicsPipelines.last?.viewportCount == 2)
    var viewports = [VkViewport(x: 0, y: 0, width: 4, height: 8, minDepth: 0.25, maxDepth: 0.75),
                     VkViewport(x: 4, y: 0, width: 4, height: 8, minDepth: 0, maxDepth: 1)]
    var scissors = [VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 4, height: 8)),
                    VkRect2D(offset: VkOffset2D(x: 5, y: 1), extent: VkExtent2D(width: 3, height: 6))]
    vk.fn("vkCmdSetViewport", PFN_vkCmdSetViewport.self)(cb, 0, 2, &viewports)
    vk.fn("vkCmdSetScissor", PFN_vkCmdSetScissor.self)(cb, 0, 2, &scissors)
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 2, 0, 0)
    // Only the second viewport changes: it alone is sent again.
    var second = VkViewport(x: 4, y: 0, width: 4, height: 8, minDepth: 0.5, maxDepth: 1)
    vk.fn("vkCmdSetViewport", PFN_vkCmdSetViewport.self)(cb, 1, 1, &second)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 2, 0, 0)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    var sets: [(UInt32, [Viewport])] = []
    var rects: [(UInt32, [RenderArea])] = []
    for c in vk.gpu.submitted[0].list.commands {
      switch c {
      case .setViewports(let first, let v): sets.append((first, v))
      case .setScissors(let first, let s): rects.append((first, s))
      case .setViewport, .setScissor: Issue.record("a single viewport or scissor for a pipeline of two")
      default: break
      }
    }
    #expect(sets.count == 2 && rects.count == 1)
    #expect(sets[0].0 == 0 && sets[0].1 == [Viewport(x: 0, y: 0, width: 4, height: 8, minDepth: 0.25, maxDepth: 0.75),
                                             Viewport(x: 4, y: 0, width: 4, height: 8)])
    #expect(sets[1].0 == 1 && sets[1].1 == [Viewport(x: 4, y: 0, width: 4, height: 8, minDepth: 0.5, maxDepth: 1)])
    #expect(rects[0].0 == 0 && rects[0].1 == [RenderArea(x: 0, y: 0, width: 4, height: 8), RenderArea(x: 5, y: 1, width: 3, height: 6)])
  }

  @Test func staticViewportsOfAPipelineAreSentAsCommands() throws {
    let vk = elsewhereVK()
    let (pass, cb) = passAndBuffer(vk)
    var p = Pieces()
    p.blendAttachments = [blendAttachment()]
    p.dynamic = []
    p.viewportCount = 2
    p.viewports = [VkViewport(x: 0, y: 0, width: 4, height: 4, minDepth: 0, maxDepth: 0.5), VkViewport(x: 4, y: 4, width: 4, height: 4, minDepth: 0, maxDepth: 1)]
    p.scissors = [VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 4, height: 4)),
                  VkRect2D(offset: VkOffset2D(x: 4, y: 4), extent: VkExtent2D(width: 4, height: 4))]
    let (r, pipeline) = buildPipeline(vk, vk.pipelineLayout([]), pass, p)
    #expect(r == VK_SUCCESS)
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 1, 0, 0)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    #expect(c.contains(.setViewports(first: 0, [Viewport(x: 0, y: 0, width: 4, height: 4, maxDepth: 0.5), Viewport(x: 4, y: 4, width: 4, height: 4)])))
    #expect(c.contains(.setScissors(first: 0, [RenderArea(x: 0, y: 0, width: 4, height: 4), RenderArea(x: 4, y: 4, width: 4, height: 4)])))
  }

  @Test func oneViewportOfDefaultDepthsIsTheSingleCommandAndMoreAreRefusedWithout() throws {
    // A device of one viewport: a pipeline of two is refused, and so are two set by commands.
    let vk = elsewhereVK(multiViewport: false)
    let (pass, cb) = passAndBuffer(vk)
    var p = Pieces()
    p.blendAttachments = [blendAttachment()]
    p.viewportCount = 2
    #expect(buildPipeline(vk, vk.pipelineLayout([]), pass, p).0 == VK_ERROR_FEATURE_NOT_PRESENT)
    p.viewportCount = 1
    let (r, pipeline) = buildPipeline(vk, vk.pipelineLayout([]), pass, p)
    #expect(r == VK_SUCCESS)
    var viewport = VkViewport(x: 1, y: 2, width: 6, height: 5, minDepth: 0, maxDepth: 1)
    var scissor = VkRect2D(offset: VkOffset2D(x: 1, y: 1), extent: VkExtent2D(width: 6, height: 6))
    vk.fn("vkCmdSetViewport", PFN_vkCmdSetViewport.self)(cb, 0, 1, &viewport)
    vk.fn("vkCmdSetScissor", PFN_vkCmdSetScissor.self)(cb, 0, 1, &scissor)
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 1, 0, 0)
    // A depth range is the device's too: the one viewport with depths goes as `setViewports`.
    var deep = VkViewport(x: 1, y: 2, width: 6, height: 5, minDepth: 0.5, maxDepth: 1)
    vk.fn("vkCmdSetViewport", PFN_vkCmdSetViewport.self)(cb, 0, 1, &deep)
    vk.fn("vkCmdDraw", PFN_vkCmdDraw.self)(cb, 3, 1, 0, 0)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    #expect(c.contains(.setViewport(x: 1, y: 2, width: 6, height: 5)))
    #expect(c.contains(.setScissor(x: 1, y: 1, width: 6, height: 6)))
    #expect(c.contains(.setViewports(first: 0, [Viewport(x: 1, y: 2, width: 6, height: 5, minDepth: 0.5)])))

    let cb2 = vk.commandBuffer(vk.commandPool())
    vk.begin(cb2)
    var two = [viewport, viewport]
    vk.fn("vkCmdSetViewport", PFN_vkCmdSetViewport.self)(cb2, 0, 2, &two)
    #expect(vk.end(cb2) == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  // MARK: Sparse

  func sparseBuffer(_ vk: VK, _ size: Int, flags: UInt32) -> (VkResult, VkBuffer?) {
    var info = VkBufferCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    info.flags = flags
    info.size = UInt64(size)
    info.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue
    var b: VkBuffer?
    let r = vk.fn("vkCreateBuffer", PFN_vkCreateBuffer.self)(vk.device, &info, nil, &b)
    return (r, b)
  }

  @Test func sparseBuffersAreTheCoresAndBoundByTheQueue() throws {
    let vk = elsewhereVK()
    let flags = VK_BUFFER_CREATE_SPARSE_BINDING_BIT.rawValue | VK_BUFFER_CREATE_SPARSE_RESIDENCY_BIT.rawValue
    let (r, buffer) = sparseBuffer(vk, 131_072, flags: flags)
    #expect(r == VK_SUCCESS)
    let sparse = try #require(vk.gpu.sparseBuffers.first)
    #expect(sparse.sparse == SparseFlags.binding | .residency && sparse.size == 131_072)
    // Its address is the sparse buffer's from the start, and its requirements the core's pages of device memory.
    #expect(vk.address(of: buffer) == sparse.address)
    var need = VkMemoryRequirements()
    vk.fn("vkGetBufferMemoryRequirements", PFN_vkGetBufferMemoryRequirements.self)(vk.device, buffer, &need)
    #expect(need.size == 131072 && need.alignment == 65536 && need.memoryTypeBits == 1 << MemoryTypes.device)
    // Memory isn't bound to it as to a plain buffer.
    let memory = vk.allocate(MemoryTypes.device, 65536)
    #expect(vk.fn("vkBindBufferMemory", PFN_vkBindBufferMemory.self)(vk.device, buffer, memory, 0) != VK_SUCCESS)

    // The second page bound, the first bound to nothing; a semaphore signalled after.
    var binds = [VkSparseMemoryBind(resourceOffset: 65536, size: 65536, memory: memory, memoryOffset: 0, flags: 0),
                 VkSparseMemoryBind(resourceOffset: 0, size: 65536, memory: nil, memoryOffset: 0, flags: 0)]
    let semaphore = vk.semaphore()
    var result = VK_SUCCESS
    binds.withUnsafeBufferPointer { bp in
      var bufferBind = VkSparseBufferMemoryBindInfo(buffer: buffer, bindCount: 2, pBinds: bp.baseAddress)
      var signal: VkSemaphore? = semaphore
      withUnsafePointer(to: &bufferBind) { bb in
        withUnsafePointer(to: &signal) { sp in
          var info = VkBindSparseInfo()
          info.sType = VK_STRUCTURE_TYPE_BIND_SPARSE_INFO
          info.bufferBindCount = 1
          info.pBufferBinds = bb
          info.signalSemaphoreCount = 1
          info.pSignalSemaphores = sp
          result = vk.fn("vkQueueBindSparse", PFN_vkQueueBindSparse.self)(vk.queue, 1, &info, nil)
        }
      }
    }
    #expect(result == VK_SUCCESS)
    let bound = try #require(vk.gpu.bound.first)
    let core = vk.gpu.allocations.last!
    #expect(bound.bindings.buffers == [SparseBufferBind(buffer: sparse, offset: 65536, size: 65536, memory: core, memoryOffset: 0),
                                       SparseBufferBind(buffer: sparse, offset: 0, size: 65536, memory: nil)])
    #expect(bound.wait == 0 && bound.signal == 1)
    // A submission waiting on the semaphore waits for the binds' value.
    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb], wait: [semaphore]) == VK_SUCCESS)
    #expect(vk.gpu.submitted.last?.wait == 1 && vk.gpu.submitted.last?.signal == 2)

    // A device without sparse resources refuses the buffer.
    let old = fullVK()
    #expect(sparseBuffer(old, 4096, flags: VK_BUFFER_CREATE_SPARSE_BINDING_BIT.rawValue).0 == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  @Test func sparseImagesTheirRequirementsAndBlockBinds() throws {
    let vk = elsewhereVK()
    let flags = VK_IMAGE_CREATE_SPARSE_BINDING_BIT.rawValue | VK_IMAGE_CREATE_SPARSE_RESIDENCY_BIT.rawValue
    let usage = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
    let (r, image) = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 256, 256, mips: 2, usage: usage, flags: flags)
    #expect(r == VK_SUCCESS)
    let core = try #require(vk.gpu.images.last)
    #expect(core.descriptor.sparse == SparseFlags.binding | .residency)
    var need = VkMemoryRequirements()
    vk.fn("vkGetImageMemoryRequirements", PFN_vkGetImageMemoryRequirements.self)(vk.device, image, &need)
    #expect(need.size == 4 * 65536 && need.alignment == 65536)
    var n: UInt32 = 0
    vk.fn("vkGetImageSparseMemoryRequirements", PFN_vkGetImageSparseMemoryRequirements.self)(vk.device, image, &n, nil)
    #expect(n == 1)
    var req = VkSparseImageMemoryRequirements()
    vk.fn("vkGetImageSparseMemoryRequirements", PFN_vkGetImageSparseMemoryRequirements.self)(vk.device, image, &n, &req)
    #expect(req.formatProperties.aspectMask == VK_IMAGE_ASPECT_COLOR_BIT.rawValue && req.formatProperties.imageGranularity.width == 128)
    #expect(req.formatProperties.flags == VK_SPARSE_IMAGE_FORMAT_SINGLE_MIPTAIL_BIT.rawValue)
    #expect(req.imageMipTailFirstLod == 1 && req.imageMipTailSize == 65536 && req.imageMipTailOffset == 3 * 65536)

    var props = VkSparseImageFormatProperties()
    var count: UInt32 = 1
    vk.fn("vkGetPhysicalDeviceSparseImageFormatProperties", PFN_vkGetPhysicalDeviceSparseImageFormatProperties.self)(
      vk.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_SAMPLE_COUNT_1_BIT, usage, VK_IMAGE_TILING_OPTIMAL, &count, &props)
    #expect(count == 1 && props.imageGranularity.height == 128 && props.flags == VK_SPARSE_IMAGE_FORMAT_NONSTANDARD_BLOCK_SIZE_BIT.rawValue)
    count = 1
    vk.fn("vkGetPhysicalDeviceSparseImageFormatProperties", PFN_vkGetPhysicalDeviceSparseImageFormatProperties.self)(
      vk.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_SAMPLE_COUNT_1_BIT, usage, VK_IMAGE_TILING_LINEAR, &count, &props)
    #expect(count == 0)

    // A block of level 0 bound, and the mip tail by bytes, with its metadata flag kept.
    let memory = vk.allocate(MemoryTypes.device, 2 * 65536)
    var blocks = [VkSparseImageMemoryBind(subresource: VkImageSubresource(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0, arrayLayer: 0),
                                          offset: VkOffset3D(x: 128, y: 0, z: 0), extent: VkExtent3D(width: 128, height: 128, depth: 1),
                                          memory: memory, memoryOffset: 0, flags: 0)]
    var tail = [VkSparseMemoryBind(resourceOffset: 3 * 65536, size: 65536, memory: memory, memoryOffset: 65536, flags: 0)]
    var result = VK_SUCCESS
    blocks.withUnsafeBufferPointer { bp in
      tail.withUnsafeBufferPointer { tp in
        var imageBind = VkSparseImageMemoryBindInfo(image: image, bindCount: 1, pBinds: bp.baseAddress)
        var opaqueBind = VkSparseImageOpaqueMemoryBindInfo(image: image, bindCount: 1, pBinds: tp.baseAddress)
        withUnsafePointer(to: &imageBind) { ib in
          withUnsafePointer(to: &opaqueBind) { ob in
            var info = VkBindSparseInfo()
            info.sType = VK_STRUCTURE_TYPE_BIND_SPARSE_INFO
            info.imageBindCount = 1
            info.pImageBinds = ib
            info.imageOpaqueBindCount = 1
            info.pImageOpaqueBinds = ob
            let fence = vk.fence()
            result = vk.fn("vkQueueBindSparse", PFN_vkQueueBindSparse.self)(vk.queue, 1, &info, fence)
          }
        }
      }
    }
    #expect(result == VK_SUCCESS)
    let bound = try #require(vk.gpu.bound.first)
    let gm = vk.gpu.allocations.last!
    #expect(bound.bindings.images == [SparseImageBind(image: core, aspects: .color, offset: Offset3D(x: 128), extent: Extent3D(width: 128, height: 128),
                                                      memory: gm)])
    #expect(bound.bindings.opaque == [SparseImageOpaqueBind(image: core, offset: 3 * 65536, size: 65536, memory: gm, memoryOffset: 65536)])
  }
}
