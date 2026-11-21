// SPDX-License-Identifier: BSD-3-Clause

// Running a list on Vulkan: `submit` validates it (the core's rules), replays
// it into a command buffer, and submits that with the timeline's wait and
// signal values. The replay is where image layouts are tracked: each command
// moves the images it names to the layout it needs, and sampled images go
// back to resting ready to sample (ImageRecord.restLayout). Barriers are the
// simple and safe ones (all earlier work, all later work), as before; finer
// when a budget asks.

import GPUCore
import Vulkan

/// Where a replay stands.
struct ReplayState {
  var boundGraphics: UInt64 = 0
  var boundCompute: UInt64 = 0
  var pass: [ImageRecord] = []
}

extension VulkanDevice: GPUQueue {
  public func submit(_ list: GPUCommandList, wait: UInt64, signal: UInt64) throws(GPUError) {
    if let e = list.validate(features: limits.features) { throw e }
    if let e = rule.check(wait: wait, signal: signal) { throw e }
    reclaim()
    let c = vk.commands
    var info = unsafe VkCommandBufferAllocateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    unsafe info.commandPool = commandPool
    unsafe info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
    unsafe info.commandBufferCount = 1
    var allocated: VkCommandBuffer?
    unsafe try vkCheck(c.vkAllocateCommandBuffers!(device, &info, &allocated), "vkAllocateCommandBuffers")
    let cb = unsafe allocated!
    var begin = unsafe VkCommandBufferBeginInfo()
    unsafe begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    unsafe begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue
    _ = unsafe c.vkBeginCommandBuffer!(cb, &begin)
    do {
      try replay(list, into: cb)
    } catch {
      var b: VkCommandBuffer? = unsafe cb
      unsafe c.vkFreeCommandBuffers!(device, commandPool, 1, &b)
      throw error
    }
    _ = unsafe c.vkEndCommandBuffer!(cb)
    // Only a list that replayed moves the timeline's rule: a refused one leaves the value for the next.
    _ = rule.accept(wait: wait, signal: signal)

    var waitValue = wait
    var signalValue = signal
    var semaphore: VkSemaphore? = timeline
    var buffer: VkCommandBuffer? = unsafe cb
    var waitStage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue
    let r: VkResult = withUnsafePointer(to: &signalValue) { sv in
      withUnsafePointer(to: &waitValue) { wv in
        var timelineInfo = unsafe VkTimelineSemaphoreSubmitInfo()
        unsafe timelineInfo.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO
        unsafe timelineInfo.signalSemaphoreValueCount = 1
        unsafe timelineInfo.pSignalSemaphoreValues = unsafe sv
        unsafe timelineInfo.waitSemaphoreValueCount = wait == 0 ? 0 : 1
        unsafe timelineInfo.pWaitSemaphoreValues = wait == 0 ? nil : unsafe wv
        return withUnsafePointer(to: &timelineInfo) { tp in
          withUnsafePointer(to: &semaphore) { sp in
            withUnsafePointer(to: &buffer) { bp in
              withUnsafePointer(to: &waitStage) { wsp in
                var submit = unsafe VkSubmitInfo()
                unsafe submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                unsafe submit.pNext = unsafe UnsafeRawPointer(tp)
                unsafe submit.waitSemaphoreCount = wait == 0 ? 0 : 1
                unsafe submit.pWaitSemaphores = wait == 0 ? nil : unsafe sp
                unsafe submit.pWaitDstStageMask = wait == 0 ? nil : unsafe wsp
                unsafe submit.commandBufferCount = 1
                unsafe submit.pCommandBuffers = unsafe bp
                unsafe submit.signalSemaphoreCount = 1
                unsafe submit.pSignalSemaphores = unsafe sp
                return unsafe c.vkQueueSubmit!(queue, 1, &submit, nil)
              }
            }
          }
        }
      }
    }
    try vkCheck(r, "vkQueueSubmit")
    unsafe pending.append((signal, cb))
  }

  func image(_ i: GPUImage) throws(GPUError) -> ImageRecord {
    guard let r = images[i.handle] else { throw .invalid("an image that isn't this device's") }
    return r
  }

  func buffer(_ m: GPUMemory) throws(GPUError) -> BufferRecord {
    guard let r = buffers[m.handle] else { throw .invalid("memory that isn't this device's") }
    return r
  }

  @safe func pipeline(_ p: GPUPipeline) throws(GPUError) -> VkPipeline {
    guard let r = pipelines[p.handle] else { throw .invalid("a pipeline that isn't this device's") }
    return unsafe r.pipeline
  }

  func queries(_ q: GPUQuerySet) throws(GPUError) -> QueryRecord {
    guard let r = querySets[q.handle] else { throw .invalid("a query set that isn't this device's") }
    return r
  }

  @safe func replay(_ list: GPUCommandList, into cb: VkCommandBuffer) throws(GPUError) {
    let c = vk.commands
    var state = ReplayState()
    // The heap, bound for both kinds of pipeline; queries to be counted are reset before any pass.
    var heapSet: VkDescriptorSet? = unsafe heap.set
    for point in [VK_PIPELINE_BIND_POINT_GRAPHICS, VK_PIPELINE_BIND_POINT_COMPUTE] {
      unsafe c.vkCmdBindDescriptorSets!(cb, point, pipelineLayout, 0, 1, &heapSet, 0, nil)
    }
    for command in list.commands {
      if case .beginQuery(let set, let index) = command {
        let q = try queries(set)
        unsafe c.vkCmdResetQueryPool!(cb, q.pool, UInt32(index), 1)
      }
    }
    // Earlier submissions' writes are visible to this one's reads.
    var memory = unsafe VkMemoryBarrier()
    unsafe memory.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
    unsafe memory.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT.rawValue
    unsafe memory.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue
    unsafe c.vkCmdPipelineBarrier!(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue,
                                   0, 1, &memory, 0, nil, 0, nil)

    for command in list.commands {
      switch command {
      case .beginRendering(let info):
        try begin(info, into: cb, &state)
      case .endRendering:
        unsafe c.vkCmdEndRendering!(cb)
        for record in state.pass where record.descriptor.usage.contains(.sampled) {
          transition(cb, record, to: record.restLayout)
        }
        state.pass = []
      case .setViewport(let x, let y, let w, let h):
        var v = VkViewport(x: x, y: y, width: w, height: h, minDepth: 0, maxDepth: 1)
        unsafe c.vkCmdSetViewport!(cb, 0, 1, &v)
      case .setScissor(let x, let y, let w, let h):
        var s = VkRect2D(offset: VkOffset2D(x: x, y: y), extent: VkExtent2D(width: w, height: h))
        unsafe c.vkCmdSetScissor!(cb, 0, 1, &s)
      case .draw(let p, let root, let vertices, let instances, let firstVertex, let firstInstance):
        try bindGraphics(p, root: root, cb, &state)
        unsafe c.vkCmdDraw!(cb, vertices, instances, firstVertex, firstInstance)
      case .drawIndexed(let p, let root, let indices, let indexOffset, let type, let count, let instances, let first, let vertexOffset,
                        let firstInstance):
        try bindGraphics(p, root: root, cb, &state)
        let b = try buffer(indices)
        unsafe c.vkCmdBindIndexBuffer!(cb, b.buffer, VkDeviceSize(indexOffset), type == .uint16 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32)
        unsafe c.vkCmdDrawIndexed!(cb, count, instances, first, vertexOffset, firstInstance)
      case .drawIndirect(let p, let root, let args, let offset, let drawCount, let stride):
        try bindGraphics(p, root: root, cb, &state)
        let b = try buffer(args)
        // One call a draw: a count above one needs a feature the Venus renderer needn't have.
        for i in 0..<Int(drawCount) {
          unsafe c.vkCmdDrawIndirect!(cb, b.buffer, VkDeviceSize(offset + i * Int(stride)), 1, stride)
        }
      case .drawIndexedIndirect(let p, let root, let indices, let indexOffset, let type, let args, let offset, let drawCount, let stride):
        try bindGraphics(p, root: root, cb, &state)
        let ib = try buffer(indices)
        let b = try buffer(args)
        unsafe c.vkCmdBindIndexBuffer!(cb, ib.buffer, VkDeviceSize(indexOffset), type == .uint16 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32)
        for i in 0..<Int(drawCount) {
          unsafe c.vkCmdDrawIndexedIndirect!(cb, b.buffer, VkDeviceSize(offset + i * Int(stride)), 1, stride)
        }
      case .dispatch(let p, let root, let x, let y, let z):
        try bindCompute(p, root: root, cb, &state)
        unsafe c.vkCmdDispatch!(cb, x, y, z)
      case .dispatchIndirect(let p, let root, let args, let offset):
        try bindCompute(p, root: root, cb, &state)
        let b = try buffer(args)
        unsafe c.vkCmdDispatchIndirect!(cb, b.buffer, VkDeviceSize(offset))
      case .copyBuffer(let from, let fromOffset, let to, let toOffset, let bytes):
        let src = try buffer(from), dst = try buffer(to)
        var region = VkBufferCopy(srcOffset: VkDeviceSize(fromOffset), dstOffset: VkDeviceSize(toOffset), size: VkDeviceSize(bytes))
        unsafe c.vkCmdCopyBuffer!(cb, src.buffer, dst.buffer, 1, &region)
      case .copyBufferToImage(let m, let offset, let image):
        let b = try buffer(m)
        let record = try self.image(image)
        transition(cb, record, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
        var region = bufferImageCopy(image, offset: offset)
        unsafe c.vkCmdCopyBufferToImage!(cb, b.buffer, record.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
        transition(cb, record, to: record.restLayout)
      case .copyImageToBuffer(let image, let m, let offset):
        let b = try buffer(m)
        let record = try self.image(image)
        transition(cb, record, to: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
        var region = bufferImageCopy(image, offset: offset)
        unsafe c.vkCmdCopyImageToBuffer!(cb, record.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b.buffer, 1, &region)
        transition(cb, record, to: record.restLayout)
      case .barrier(let from, let to):
        var memory = unsafe VkMemoryBarrier()
        unsafe memory.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
        unsafe memory.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT.rawValue
        unsafe memory.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue
        unsafe c.vkCmdPipelineBarrier!(cb, stageMask(from), stageMask(to), 0, 1, &memory, 0, nil, 0, nil)
      case .writeTimestamp(let set, let index, let after):
        let q = try queries(set)
        unsafe c.vkCmdResetQueryPool!(cb, q.pool, UInt32(index), 1)
        unsafe c.vkCmdWriteTimestamp!(cb, VkPipelineStageFlagBits(rawValue: stageMask(after)), q.pool, UInt32(index))
      case .beginQuery(let set, let index):
        unsafe c.vkCmdBeginQuery!(cb, try queries(set).pool, UInt32(index), 0)
      case .endQuery(let set, let index):
        unsafe c.vkCmdEndQuery!(cb, try queries(set).pool, UInt32(index))
      }
    }
  }

  @safe private func begin(_ info: RenderingInfo, into cb: VkCommandBuffer, _ state: inout ReplayState) throws(GPUError) {
    let c = vk.commands
    var attachments = unsafe [VkRenderingAttachmentInfo]()
    for a in info.colors {
      let record = try image(a.image)
      transition(cb, record, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
      state.pass.append(record)
      var attachment = unsafe VkRenderingAttachmentInfo()
      unsafe attachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
      unsafe attachment.imageView = unsafe record.view
      unsafe attachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      switch a.load {
      case .load: unsafe attachment.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD
      case .dontCare: unsafe attachment.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
      case .clear(let r, let g, let b, let alpha):
        unsafe attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
        unsafe attachment.clearValue.color.float32 = (r, g, b, alpha)
      }
      unsafe attachment.storeOp = a.store == .store ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE
      unsafe attachments.append(attachment)
    }
    let area = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: UInt32(info.width), height: UInt32(info.height)))
    attachments.withUnsafeBufferPointer { ap in
      var rendering = unsafe VkRenderingInfo()
      unsafe rendering.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
      unsafe rendering.renderArea = area
      unsafe rendering.layerCount = 1
      unsafe rendering.colorAttachmentCount = UInt32(ap.count)
      unsafe rendering.pColorAttachments = ap.baseAddress
      unsafe c.vkCmdBeginRendering!(cb, &rendering)
    }
    var viewport = VkViewport(x: 0, y: 0, width: Float(info.width), height: Float(info.height), minDepth: 0, maxDepth: 1)
    var scissor = area
    unsafe c.vkCmdSetViewport!(cb, 0, 1, &viewport)
    unsafe c.vkCmdSetScissor!(cb, 0, 1, &scissor)
    state.boundGraphics = 0
  }

  @safe private func bindGraphics(_ p: GPUPipeline, root: UInt64, _ cb: VkCommandBuffer, _ state: inout ReplayState) throws(GPUError) {
    let c = vk.commands
    if state.boundGraphics != p.handle {
      unsafe c.vkCmdBindPipeline!(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, try pipeline(p))
      state.boundGraphics = p.handle
    }
    var r = root
    unsafe c.vkCmdPushConstants!(cb, pipelineLayout, VK_SHADER_STAGE_ALL.rawValue, 0, 8, &r)
  }

  @safe private func bindCompute(_ p: GPUPipeline, root: UInt64, _ cb: VkCommandBuffer, _ state: inout ReplayState) throws(GPUError) {
    let c = vk.commands
    if state.boundCompute != p.handle {
      unsafe c.vkCmdBindPipeline!(cb, VK_PIPELINE_BIND_POINT_COMPUTE, try pipeline(p))
      state.boundCompute = p.handle
    }
    var r = root
    unsafe c.vkCmdPushConstants!(cb, pipelineLayout, VK_SHADER_STAGE_ALL.rawValue, 0, 8, &r)
  }

  private func bufferImageCopy(_ image: GPUImage, offset: Int) -> VkBufferImageCopy {
    var region = VkBufferImageCopy()
    region.bufferOffset = VkDeviceSize(offset)
    region.imageSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0,
                                                       baseArrayLayer: 0, layerCount: 1)
    region.imageExtent = VkExtent3D(width: UInt32(image.width), height: UInt32(image.height), depth: 1)
    return region
  }

  private func stageMask(_ s: PipelineStages) -> VkPipelineStageFlags {
    var m: UInt32 = 0
    if s.contains(.compute) { m |= VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT.rawValue }
    if s.contains(.vertex) { m |= VK_PIPELINE_STAGE_VERTEX_INPUT_BIT.rawValue | VK_PIPELINE_STAGE_VERTEX_SHADER_BIT.rawValue }
    if s.contains(.fragment) {
      m |= VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT.rawValue | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue
    }
    if s.contains(.transfer) { m |= VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue }
    return m == 0 ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT.rawValue : m
  }

  /// Moves `record` to `layout`, waiting for all earlier work (v0: simple and safe; finer barriers when a budget asks).
  @safe private func transition(_ cb: VkCommandBuffer, _ record: ImageRecord, to layout: VkImageLayout) {
    let c = vk.commands
    var b = unsafe VkImageMemoryBarrier()
    unsafe b.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
    unsafe b.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT.rawValue
    unsafe b.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue
    unsafe b.oldLayout = record.layout
    unsafe b.newLayout = layout
    unsafe b.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    unsafe b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    unsafe b.image = unsafe record.image
    unsafe b.subresourceRange = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0,
                                                        levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    unsafe c.vkCmdPipelineBarrier!(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue,
                                   0, 0, nil, 0, nil, 1, &b)
    record.layout = layout
  }
}
