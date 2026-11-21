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
    if let e = list.validate(limits: limits) { throw e }
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
        for record in state.pass where record.restLayout != record.layout {
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
      case .drawIndirectCount(let p, let root, let args, let offset, let counts, let countOffset, let maxCount, let stride):
        try bindGraphics(p, root: root, cb, &state)
        unsafe c.vkCmdDrawIndirectCount!(cb, try buffer(args).buffer, VkDeviceSize(offset), try buffer(counts).buffer,
                                         VkDeviceSize(countOffset), maxCount, stride)
      case .drawIndexedIndirectCount(let p, let root, let indices, let indexOffset, let type, let args, let offset, let counts,
                                     let countOffset, let maxCount, let stride):
        try bindGraphics(p, root: root, cb, &state)
        unsafe c.vkCmdBindIndexBuffer!(cb, try buffer(indices).buffer, VkDeviceSize(indexOffset),
                                       type == .uint16 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32)
        unsafe c.vkCmdDrawIndexedIndirectCount!(cb, try buffer(args).buffer, VkDeviceSize(offset), try buffer(counts).buffer,
                                                VkDeviceSize(countOffset), maxCount, stride)
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
        try copyBufferImage(cb, m, image, [wholeImageRegion(image, offset: offset)], toImage: true)
      case .copyImageToBuffer(let image, let m, let offset):
        try copyBufferImage(cb, m, image, [wholeImageRegion(image, offset: offset)], toImage: false)
      case .copyBufferToImageRegions(let m, let image, let regions):
        try copyBufferImage(cb, m, image, regions, toImage: true)
      case .copyImageToBufferRegions(let image, let m, let regions):
        try copyBufferImage(cb, m, image, regions, toImage: false)
      case .copyImage(let src, let dst, let regions):
        let s = try image(src), d = try image(dst)
        let (sl, dl) = prepare(cb, s, d)
        let list = regions.map { r in
          VkImageCopy(srcSubresource: vkLayers(r.srcSubresource), srcOffset: vkOffset(r.srcOffset),
                      dstSubresource: vkLayers(r.dstSubresource), dstOffset: vkOffset(r.dstOffset), extent: vkExtent(r.extent))
        }
        list.withUnsafeBufferPointer { unsafe c.vkCmdCopyImage!(cb, s.image, sl, d.image, dl, UInt32($0.count), $0.baseAddress) }
        finish(cb, s, d)
      case .blitImage(let src, let dst, let regions, let filter):
        let s = try image(src), d = try image(dst)
        let (sl, dl) = prepare(cb, s, d)
        let list = regions.map { r in
          VkImageBlit(srcSubresource: vkLayers(r.srcSubresource), srcOffsets: (vkOffset(r.srcMin), vkOffset(r.srcMax)),
                      dstSubresource: vkLayers(r.dstSubresource), dstOffsets: (vkOffset(r.dstMin), vkOffset(r.dstMax)))
        }
        list.withUnsafeBufferPointer { unsafe c.vkCmdBlitImage!(cb, s.image, sl, d.image, dl, UInt32($0.count), $0.baseAddress, filter.vk) }
        finish(cb, s, d)
      case .resolveImage(let src, let dst, let regions):
        let s = try image(src), d = try image(dst)
        let (sl, dl) = prepare(cb, s, d)
        let list = regions.map { r in
          VkImageResolve(srcSubresource: vkLayers(r.srcSubresource), srcOffset: vkOffset(r.srcOffset),
                         dstSubresource: vkLayers(r.dstSubresource), dstOffset: vkOffset(r.dstOffset), extent: vkExtent(r.extent))
        }
        list.withUnsafeBufferPointer { unsafe c.vkCmdResolveImage!(cb, s.image, sl, d.image, dl, UInt32($0.count), $0.baseAddress) }
        finish(cb, s, d)
      case .fillBuffer(let m, let offset, let bytes, let value):
        unsafe c.vkCmdFillBuffer!(cb, try buffer(m).buffer, VkDeviceSize(offset), VkDeviceSize(bytes), value)
      case .updateBuffer(let m, let offset, let data):
        let b = try buffer(m)
        data.withUnsafeBytes { unsafe c.vkCmdUpdateBuffer!(cb, b.buffer, VkDeviceSize(offset), VkDeviceSize(data.count), $0.baseAddress) }
      case .clearColorImage(let image, let color, let ranges):
        let record = try self.image(image)
        transition(cb, record, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
        var value = VkClearColorValue()
        switch color {
        case .float(let r, let g, let b, let a): unsafe value.float32 = (r, g, b, a)
        case .uint(let r, let g, let b, let a): unsafe value.uint32 = (r, g, b, a)
        case .sint(let r, let g, let b, let a): unsafe value.int32 = (r, g, b, a)
        }
        let list = ranges.map { vkRange($0) }
        list.withUnsafeBufferPointer {
          unsafe c.vkCmdClearColorImage!(cb, record.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &value, UInt32($0.count), $0.baseAddress)
        }
        transition(cb, record, to: record.restLayout)
      case .clearDepthStencilImage(let image, let depth, let stencil, let ranges):
        let record = try self.image(image)
        transition(cb, record, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
        var value = VkClearDepthStencilValue(depth: depth, stencil: stencil)
        let list = ranges.map { vkRange($0) }
        list.withUnsafeBufferPointer {
          unsafe c.vkCmdClearDepthStencilImage!(cb, record.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &value, UInt32($0.count),
                                                $0.baseAddress)
        }
        transition(cb, record, to: record.restLayout)
      case .clearAttachments(let attachments, let rects):
        var list: [VkClearAttachment] = []
        for a in attachments {
          var v = VkClearAttachment()
          switch a {
          case .color(let index, let color):
            v.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT.rawValue
            v.colorAttachment = UInt32(index)
            switch color {
            case .float(let r, let g, let b, let a): unsafe v.clearValue.color.float32 = (r, g, b, a)
            case .uint(let r, let g, let b, let a): unsafe v.clearValue.color.uint32 = (r, g, b, a)
            case .sint(let r, let g, let b, let a): unsafe v.clearValue.color.int32 = (r, g, b, a)
            }
          case .depthStencil(let aspects, let depth, let stencil):
            v.aspectMask = vkAspects(aspects)
            unsafe v.clearValue.depthStencil = VkClearDepthStencilValue(depth: depth, stencil: stencil)
          }
          list.append(v)
        }
        let areas = rects.map { r in
          VkClearRect(rect: VkRect2D(offset: VkOffset2D(x: r.x, y: r.y), extent: VkExtent2D(width: r.width, height: r.height)),
                      baseArrayLayer: r.baseLayer, layerCount: r.layerCount)
        }
        list.withUnsafeBufferPointer { lp in
          areas.withUnsafeBufferPointer { rp in
            unsafe c.vkCmdClearAttachments!(cb, UInt32(lp.count), lp.baseAddress, UInt32(rp.count), rp.baseAddress)
          }
        }
      case .setBlendConstants(let k):
        let values: [Float] = [k.red, k.green, k.blue, k.alpha]
        values.withUnsafeBufferPointer { unsafe c.vkCmdSetBlendConstants!(cb, $0.baseAddress) }
      case .setStencilReference(let faces, let value):
        unsafe c.vkCmdSetStencilReference!(cb, UInt32(faces.rawValue), value)
      case .setStencilCompareMask(let faces, let value):
        unsafe c.vkCmdSetStencilCompareMask!(cb, UInt32(faces.rawValue), value)
      case .setStencilWriteMask(let faces, let value):
        unsafe c.vkCmdSetStencilWriteMask!(cb, UInt32(faces.rawValue), value)
      case .setDepthBias(let constant, let clamp, let slope):
        unsafe c.vkCmdSetDepthBias!(cb, constant, clamp, slope)
      case .setDepthBounds(let lo, let hi):
        unsafe c.vkCmdSetDepthBounds!(cb, lo, hi)
      case .setLineWidth(let w):
        unsafe c.vkCmdSetLineWidth!(cb, w)
      case .barrier(let from, let to), .imageBarrier(let from, let to, _, _):
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

  /// A whole-image copy: mip 0 of layer 0, tightly packed.
  private func wholeImageRegion(_ image: GPUImage, offset: Int) -> BufferImageRegion {
    BufferImageRegion(bufferOffset: offset, imageExtent: Extent3D(width: UInt32(image.width), height: UInt32(image.height),
                                                                 depth: UInt32(image.depth)))
  }

  private func copyBufferImage(_ cb: VkCommandBuffer, _ m: GPUMemory, _ image: GPUImage, _ regions: [BufferImageRegion],
                               toImage: Bool) throws(GPUError) {
    let c = vk.commands
    let b = try buffer(m)
    let record = try self.image(image)
    let layout = toImage ? VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
    transition(cb, record, to: layout)
    let list = regions.map { r in
      VkBufferImageCopy(bufferOffset: VkDeviceSize(r.bufferOffset), bufferRowLength: r.bufferRowLength,
                        bufferImageHeight: r.bufferImageHeight, imageSubresource: vkLayers(r.subresource),
                        imageOffset: vkOffset(r.imageOffset), imageExtent: vkExtent(r.imageExtent))
    }
    list.withUnsafeBufferPointer {
      if toImage {
        unsafe c.vkCmdCopyBufferToImage!(cb, b.buffer, record.image, layout, UInt32($0.count), $0.baseAddress)
      } else {
        unsafe c.vkCmdCopyImageToBuffer!(cb, record.image, layout, b.buffer, UInt32($0.count), $0.baseAddress)
      }
    }
    transition(cb, record, to: record.restLayout)
  }

  /// Moves a copy's, blit's or resolve's two images to the layouts it needs: the source to transfer source, the destination
  /// to transfer destination (both to general where they are one image).
  private func prepare(_ cb: VkCommandBuffer, _ s: ImageRecord, _ d: ImageRecord) -> (VkImageLayout, VkImageLayout) {
    if s === d {
      transition(cb, s, to: VK_IMAGE_LAYOUT_GENERAL)
      return (VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_GENERAL)
    }
    transition(cb, s, to: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
    transition(cb, d, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
    return (VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
  }

  private func finish(_ cb: VkCommandBuffer, _ s: ImageRecord, _ d: ImageRecord) {
    transition(cb, s, to: s.restLayout)
    if d !== s { transition(cb, d, to: d.restLayout) }
  }

  @safe private func begin(_ info: RenderingInfo, into cb: VkCommandBuffer, _ state: inout ReplayState) throws(GPUError) {
    let c = vk.commands
    var attachments = unsafe [VkRenderingAttachmentInfo]()
    for a in info.colors {
      let record = try image(a.view.image)
      transition(cb, record, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
      state.pass.append(record)
      var attachment = unsafe VkRenderingAttachmentInfo()
      unsafe attachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
      unsafe attachment.imageView = unsafe try vkView(record, a.view)
      unsafe attachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      if let r = a.resolve {
        let target = try image(r.image)
        transition(cb, target, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        state.pass.append(target)
        unsafe attachment.resolveMode = a.view.format.channelClass == .float ? VK_RESOLVE_MODE_AVERAGE_BIT : VK_RESOLVE_MODE_SAMPLE_ZERO_BIT
        unsafe attachment.resolveImageView = unsafe try vkView(target, r)
        unsafe attachment.resolveImageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      }
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

    // The depth and stencil attachment: one view, named by the depth attachment and the stencil one where the format has them.
    var depth = unsafe VkRenderingAttachmentInfo()
    var stencil = unsafe VkRenderingAttachmentInfo()
    var hasDepth = false, hasStencil = false
    if let d = info.depthStencil {
      let record = try image(d.view.image)
      transition(cb, record, to: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
      state.pass.append(record)
      let handle = unsafe try vkView(record, d.view)
      func load(_ l: AspectLoad) -> VkAttachmentLoadOp {
        switch l {
        case .load: VK_ATTACHMENT_LOAD_OP_LOAD
        case .clear: VK_ATTACHMENT_LOAD_OP_CLEAR
        case .dontCare: VK_ATTACHMENT_LOAD_OP_DONT_CARE
        }
      }
      for aspect in [ImageAspects.depth, .stencil] where d.view.format.aspects.contains(aspect) {
        var a = unsafe VkRenderingAttachmentInfo()
        unsafe a.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
        unsafe a.imageView = unsafe handle
        unsafe a.imageLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        unsafe a.clearValue.depthStencil = VkClearDepthStencilValue(depth: d.clearDepth, stencil: d.clearStencil)
        if aspect == .depth {
          unsafe a.loadOp = load(d.depthLoad)
          unsafe a.storeOp = d.depthStore == .store ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE
          depth = unsafe a
          hasDepth = true
        } else {
          unsafe a.loadOp = load(d.stencilLoad)
          unsafe a.storeOp = d.stencilStore == .store ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE
          stencil = unsafe a
          hasStencil = true
        }
      }
    }

    let a = info.area
    let area = VkRect2D(offset: VkOffset2D(x: a.x, y: a.y), extent: VkExtent2D(width: a.width, height: a.height))
    attachments.withUnsafeBufferPointer { ap in
      var rendering = unsafe VkRenderingInfo()
      unsafe rendering.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
      unsafe rendering.renderArea = area
      unsafe rendering.layerCount = info.viewMask != 0 ? 1 : info.layerCount
      unsafe rendering.viewMask = info.viewMask
      unsafe rendering.colorAttachmentCount = UInt32(ap.count)
      unsafe rendering.pColorAttachments = ap.baseAddress
      withUnsafePointer(to: &depth) { dp in
        withUnsafePointer(to: &stencil) { sp in
          unsafe rendering.pDepthAttachment = hasDepth ? unsafe dp : nil
          unsafe rendering.pStencilAttachment = hasStencil ? unsafe sp : nil
          unsafe c.vkCmdBeginRendering!(cb, &rendering)
        }
      }
    }
    var viewport = VkViewport(x: 0, y: 0, width: Float(info.width), height: Float(info.height), minDepth: 0, maxDepth: 1)
    var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: UInt32(info.width), height: UInt32(info.height)))
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
    unsafe b.subresourceRange = record.fullRange
    unsafe c.vkCmdPipelineBarrier!(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue,
                                   0, 0, nil, 0, nil, 1, &b)
    record.layout = layout
  }
}
