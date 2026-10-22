// SPDX-License-Identifier: BSD-3-Clause

// Recording (sdk.md §5): render passes with draws, and copies. Layout
// transitions are Loinnir's: it knows each image's layout and moves it to
// what the next command needs.

@safe public struct CommandList: ~Copyable {
  let owner: Loinnir
  let cb: VkCommandBuffer

  var c: VulkanCommands { owner.gpu.vk.commands }

  /// Draws into `target`, cleared to `clear` first if given.
  public mutating func render(to target: RenderTarget, clear: (Float, Float, Float, Float)? = nil,
                              _ body: (inout RenderPass) -> Void) {
    let (record, foreign) = resolve(target)
    if foreign {
      // The window's image: acquire it from the compositor's queue family.
      transition(record, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, from: VK_IMAGE_LAYOUT_UNDEFINED,
                 srcFamily: VK_QUEUE_FAMILY_FOREIGN_EXT, dstFamily: owner.gpu.queueFamily)
    } else {
      transition(record, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    }
    var attachment = unsafe VkRenderingAttachmentInfo()
    unsafe attachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
    unsafe attachment.imageView = unsafe record.view
    unsafe attachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
    unsafe attachment.loadOp = clear == nil ? VK_ATTACHMENT_LOAD_OP_LOAD : VK_ATTACHMENT_LOAD_OP_CLEAR
    unsafe attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE
    if let clear { unsafe attachment.clearValue.color.float32 = clear }
    let area = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: UInt32(record.width), height: UInt32(record.height)))
    withUnsafePointer(to: &attachment) { ap in
      var info = unsafe VkRenderingInfo()
      unsafe info.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
      unsafe info.renderArea = area
      unsafe info.layerCount = 1
      unsafe info.colorAttachmentCount = 1
      unsafe info.pColorAttachments = unsafe ap
      unsafe c.vkCmdBeginRendering!(cb, &info)
    }
    var viewport = VkViewport(x: 0, y: 0, width: Float(record.width), height: Float(record.height), minDepth: 0, maxDepth: 1)
    var scissor = area
    unsafe c.vkCmdSetViewport!(cb, 0, 1, &viewport)
    unsafe c.vkCmdSetScissor!(cb, 0, 1, &scissor)
    var pass = unsafe RenderPass(c: c, cb: cb, layout: owner.pipelineLayout)
    body(&pass)
    unsafe c.vkCmdEndRendering!(cb)
    if foreign {
      // Hand it back to the compositor.
      transition(record, to: VK_IMAGE_LAYOUT_GENERAL, srcFamily: owner.gpu.queueFamily, dstFamily: VK_QUEUE_FAMILY_FOREIGN_EXT)
    }
  }

  /// Copies `from` (tightly packed pixels) into `texture`.
  public mutating func copy(_ from: GPUAllocation, to texture: Texture) {
    guard let record = owner.textures[texture.index] else { return }
    transition(record, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
    var region = bufferImageCopy(texture)
    unsafe c.vkCmdCopyBufferToImage!(cb, from.buffer, record.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
    transition(record, to: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
  }

  /// Copies `texture`'s pixels into `to` (tightly packed), to read back.
  public mutating func copy(_ texture: Texture, to: GPUAllocation) {
    guard let record = owner.textures[texture.index] else { return }
    transition(record, to: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
    var region = bufferImageCopy(texture)
    unsafe c.vkCmdCopyImageToBuffer!(cb, record.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, to.buffer, 1, &region)
    transition(record, to: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
  }

  func bufferImageCopy(_ t: Texture) -> VkBufferImageCopy {
    var region = VkBufferImageCopy()
    region.imageSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0,
                                                       baseArrayLayer: 0, layerCount: 1)
    region.imageExtent = VkExtent3D(width: UInt32(t.width), height: UInt32(t.height), depth: 1)
    return region
  }

  func resolve(_ target: RenderTarget) -> (ImageRecord, foreign: Bool) {
    switch target {
    case .texture(let t): return (owner.textures[t.index]!, false)
    case .backbuffer(let r): return (r, true)
    }
  }

  /// Moves `record` to `layout`, waiting for all earlier work (v0: simple
  /// and safe; finer barriers when a budget asks).
  func transition(_ record: ImageRecord, to layout: VkImageLayout, from: VkImageLayout? = nil,
                  srcFamily: UInt32 = VK_QUEUE_FAMILY_IGNORED, dstFamily: UInt32 = VK_QUEUE_FAMILY_IGNORED) {
    var b = unsafe VkImageMemoryBarrier()
    unsafe b.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
    unsafe b.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT.rawValue
    unsafe b.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue
    unsafe b.oldLayout = from ?? record.layout
    unsafe b.newLayout = layout
    unsafe b.srcQueueFamilyIndex = srcFamily
    unsafe b.dstQueueFamilyIndex = dstFamily
    unsafe b.image = unsafe record.image
    unsafe b.subresourceRange = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0,
                                                 levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    unsafe c.vkCmdPipelineBarrier!(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue,
                            0, 0, nil, 0, nil, 1, &b)
    record.layout = layout
  }
}

/// Draws inside a render pass.
@safe public struct RenderPass {
  let c: VulkanCommands
  let cb: VkCommandBuffer
  let layout: VkPipelineLayout
  var bound: VkPipeline?

  /// Draws `vertices` (× `instances`) with `pipeline`. `root` is the one
  /// pointer the shaders get: the GPU address of whatever they read.
  /// Instances `firstInstance` on: a range of a batch (the UI Kit draws
  /// each clip's range under its own scissor).
  public mutating func draw(_ pipeline: Pipeline, root: UInt64, vertices: UInt32, instances: UInt32 = 1,
                            firstInstance: UInt32 = 0)
  {
    if unsafe bound != pipeline.pipeline {
      unsafe c.vkCmdBindPipeline!(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline)
      unsafe bound = unsafe pipeline.pipeline
    }
    var r = root
    unsafe c.vkCmdPushConstants!(cb, layout, VK_SHADER_STAGE_ALL.rawValue, 0, 8, &r)
    unsafe c.vkCmdDraw!(cb, vertices, instances, 0, firstInstance)
  }

  /// Draws from here on only within the rectangle (pixels; the render
  /// pass sets the whole target).
  public mutating func scissor(x: Int32, y: Int32, width: UInt32, height: UInt32) {
    var r = VkRect2D(offset: VkOffset2D(x: x, y: y), extent: VkExtent2D(width: width, height: height))
    unsafe c.vkCmdSetScissor!(cb, 0, 1, &r)
  }
}
