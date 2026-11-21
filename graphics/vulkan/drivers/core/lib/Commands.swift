// SPDX-License-Identifier: BSD-3-Clause

// Command pools and buffers (D174 step 5, part 3). A command buffer records a `GPUCommandList`. A draw or a
// dispatch writes a root block (RootBlock: the bound sets' addresses, the vertex buffers' addresses, the push
// constants) into the command buffer's arena, 64 KB chunks of `.upload` memory, and names its address. The arena
// is the command buffer's until the timeline passes the value of the last submission that used it.
//
// Vulkan's commands return nothing, so what the layer can't record it remembers (`error`) and says at
// vkEndCommandBuffer; the list's own rules (`GPUCommandList.validate`, against the device's features) are judged
// there too, so a feature the device lacks fails the end of the buffer with VK_ERROR_FEATURE_NOT_PRESENT.

import GPUCore
import TDVulkan
import VulkanLowering

let arenaChunkBytes = 65536

final class CommandPoolObject: CoreObject {
  let device: DeviceObject
  var buffers: [CommandBufferObject] = []
  init(device: DeviceObject) { self.device = device }
}

@safe final class CommandBufferObject: CoreObject {
  let device: DeviceObject
  var handle: OpaquePointer?
  var list = GPUCommandList()
  /// What recording couldn't do, said at the end.
  var error: VkResult?
  var recording = false
  var chunks: [GPUMemory] = []
  var chunkUsed = 0
  /// The last timeline value a submission of this buffer signals.
  var pendingValue: UInt64 = 0

  // What is bound.
  var graphics: PipelineObject?
  var compute: PipelineObject?
  var sets = [UInt64](repeating: 0, count: RootBlock.maxSets)
  var push = [UInt8](repeating: 0, count: RootBlock.maxPushConstantBytes)
  var vertexBuffers = [UInt64](repeating: 0, count: RootBlock.maxVertexBuffers)
  var index: (memory: GPUMemory, offset: Int, type: IndexType)?
  var viewport: (Float, Float, Float, Float)?
  var scissor: (Int32, Int32, UInt32, UInt32)?
  var sentViewport: (Float, Float, Float, Float)?
  var sentScissor: (Int32, Int32, UInt32, UInt32)?
  var inPass = false
  var passIsRenderPass = false

  init(device: DeviceObject) { self.device = device }

  func fail(_ r: VkResult, _ why: String) {
    say("unsupported: \(why)")
    if error == nil { error = r }
  }

  /// Gives the arena to the device, to free when the timeline passes the last use.
  func releaseArena() {
    for c in chunks { device.retired.append((pendingValue, c)) }
    chunks = []
    chunkUsed = 0
    device.retire()
  }

  func reset() {
    releaseArena()
    list = GPUCommandList()
    error = nil
    graphics = nil
    compute = nil
    sets = [UInt64](repeating: 0, count: RootBlock.maxSets)
    push = [UInt8](repeating: 0, count: RootBlock.maxPushConstantBytes)
    vertexBuffers = [UInt64](repeating: 0, count: RootBlock.maxVertexBuffers)
    index = nil
    viewport = nil
    scissor = nil
    sentViewport = nil
    sentScissor = nil
    inPass = false
  }

  /// `bytes` of arena, aligned to `alignment`: the chunk's memory and the offset in it.
  func arena(_ bytes: Int, alignment: Int = 64) -> (memory: GPUMemory, offset: Int)? {
    if let c = chunks.last {
      let at = (chunkUsed + alignment - 1) & ~(alignment - 1)
      if at + bytes <= c.size {
        chunkUsed = at + bytes
        return (c, at)
      }
    }
    do throws(GPUError) {
      let c = try device.gpu.allocate(.upload, bytes: max(arenaChunkBytes, bytes))
      if unsafe c.pointer == nil { throw GPUError.invalid("upload memory with no CPU pointer") }
      chunks.append(c)
      chunkUsed = bytes
      return (c, 0)
    } catch {
      fail(vkResult(error), "arena memory: \(error)")
      return nil
    }
  }

  /// A root block for the next draw or dispatch, written from what is bound: its GPU address.
  func rootBlock() -> UInt64? {
    guard let a = arena(RootBlock.size), let p = unsafe a.memory.pointer else { return nil }
    let at = unsafe p + a.offset
    unsafe at.initializeMemory(as: UInt8.self, repeating: 0, count: RootBlock.size)
    for i in 0..<RootBlock.maxSets { unsafe at.storeBytes(of: sets[i], toByteOffset: RootBlock.setsOffset + 8 * i, as: UInt64.self) }
    for i in 0..<RootBlock.maxVertexBuffers {
      unsafe at.storeBytes(of: vertexBuffers[i], toByteOffset: RootBlock.vertexBuffersOffset + 8 * i, as: UInt64.self)
    }
    for i in 0..<RootBlock.maxPushConstantBytes {
      unsafe at.storeBytes(of: push[i], toByteOffset: RootBlock.pushConstantsOffset + i, as: UInt8.self)
    }
    return a.memory.address + UInt64(a.offset)
  }

  /// Emits the viewport and scissor the next draw needs, where they differ from what the pass has.
  func sendState(_ p: PipelineObject) {
    guard inPass else { return }
    if let v = p.viewport ?? viewport {
      if sentViewport == nil || sentViewport! != v {
        list.setViewport(x: v.0, y: v.1, width: v.2, height: v.3)
        sentViewport = v
      }
    }
    if let s = p.scissor ?? scissor {
      if sentScissor == nil || sentScissor! != s {
        list.setScissor(x: s.0, y: s.1, width: s.2, height: s.3)
        sentScissor = s
      }
    }
  }

  /// A graphics pipeline and a root block for a draw, with the state it needs sent.
  func prepareDraw() -> (pipeline: GPUPipeline, root: UInt64)? {
    guard let p = graphics else {
      fail(VK_ERROR_UNKNOWN, "a draw with no pipeline bound")
      return nil
    }
    sendState(p)
    guard let root = rootBlock() else { return nil }
    return (p.gpu, root)
  }

  func prepareDispatch() -> (pipeline: GPUPipeline, root: UInt64)? {
    guard let p = compute else {
      fail(VK_ERROR_UNKNOWN, "a dispatch with no pipeline bound")
      return nil
    }
    guard let root = rootBlock() else { return nil }
    return (p.gpu, root)
  }

  func begin(_ info: RenderingInfo, area: VkRect2D) {
    list.beginRendering(info)
    inPass = true
    sentViewport = nil
    sentScissor = nil
    let a = area
    if a.offset.x != 0 || a.offset.y != 0 || Int32(a.extent.width) != info.width || Int32(a.extent.height) != info.height {
      let s = (a.offset.x, a.offset.y, a.extent.width, a.extent.height)
      list.setScissor(x: s.0, y: s.1, width: s.2, height: s.3)
      sentScissor = s
    }
  }

  func end() {
    list.endRendering()
    inPass = false
  }
}

// MARK: Pools

func core_vkCreateCommandPool(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkCommandPoolCreateInfo>?,
                              _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                              _ pCommandPool: UnsafeMutablePointer<VkCommandPool?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let out = unsafe pCommandPool else { return VK_ERROR_INITIALIZATION_FAILED }
  unsafe out.pointee = Handle.make(CommandPoolObject(device: d))
  return VK_SUCCESS
}

func freeBuffer(_ b: CommandBufferObject) {
  b.releaseArena()
  unsafe Handle.destroy(b.handle)
  unsafe b.handle = nil
}

func core_vkDestroyCommandPool(_ device: VkDevice?, _ commandPool: VkCommandPool?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let p = unsafe Handle.get(commandPool, CommandPoolObject.self) else { return }
  for b in p.buffers { freeBuffer(b) }
  p.buffers = []
  unsafe Handle.destroy(commandPool)
}

func core_vkResetCommandPool(_ device: VkDevice?, _ commandPool: VkCommandPool?, _ flags: VkCommandPoolResetFlags) -> VkResult {
  guard let p = unsafe Handle.get(commandPool, CommandPoolObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  for b in p.buffers { b.reset() }
  return VK_SUCCESS
}

func core_vkTrimCommandPool(_ device: VkDevice?, _ commandPool: VkCommandPool?, _ flags: VkCommandPoolTrimFlags) {}

func core_vkAllocateCommandBuffers(_ device: VkDevice?, _ pAllocateInfo: UnsafePointer<VkCommandBufferAllocateInfo>?,
                                   _ pCommandBuffers: UnsafeMutablePointer<VkCommandBuffer?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pAllocateInfo, let out = unsafe pCommandBuffers,
    let pool = unsafe Handle.get(info.pointee.commandPool, CommandPoolObject.self)
  else { return VK_ERROR_INITIALIZATION_FAILED }
  if unsafe info.pointee.level != VK_COMMAND_BUFFER_LEVEL_PRIMARY {
    say("unsupported: secondary command buffers")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  for i in 0..<Int(unsafe info.pointee.commandBufferCount) {
    let b = CommandBufferObject(device: d)
    unsafe b.handle = unsafe Handle.make(b, dispatchable: true)
    pool.buffers.append(b)
    unsafe out[i] = b.handle
  }
  return VK_SUCCESS
}

func core_vkFreeCommandBuffers(_ device: VkDevice?, _ commandPool: VkCommandPool?, _ commandBufferCount: UInt32,
                               _ pCommandBuffers: UnsafePointer<VkCommandBuffer?>?)
{
  guard let pool = unsafe Handle.get(commandPool, CommandPoolObject.self) else { return }
  for i in 0..<Int(commandBufferCount) {
    guard let b = unsafe Handle.get(pCommandBuffers![i], CommandBufferObject.self) else { continue }
    if let at = pool.buffers.firstIndex(where: { $0 === b }) { pool.buffers.remove(at: at) }
    freeBuffer(b)
  }
}

func core_vkResetCommandBuffer(_ commandBuffer: VkCommandBuffer?, _ flags: VkCommandBufferResetFlags) -> VkResult {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  b.reset()
  b.recording = false
  return VK_SUCCESS
}

func core_vkBeginCommandBuffer(_ commandBuffer: VkCommandBuffer?, _ pBeginInfo: UnsafePointer<VkCommandBufferBeginInfo>?) -> VkResult {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  b.reset()
  b.recording = true
  return VK_SUCCESS
}

func core_vkEndCommandBuffer(_ commandBuffer: VkCommandBuffer?) -> VkResult {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  b.recording = false
  if let e = b.error { return e }
  // What the device lacks is refused here, by the one place the rules are written.
  if let e = b.list.validate(features: b.device.features) { return vkResult(e) }
  return VK_SUCCESS
}

// MARK: State

func core_vkCmdBindPipeline(_ commandBuffer: VkCommandBuffer?, _ pipelineBindPoint: VkPipelineBindPoint, _ pipeline: VkPipeline?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let p = unsafe Handle.get(pipeline, PipelineObject.self) else { return }
  if pipelineBindPoint == VK_PIPELINE_BIND_POINT_GRAPHICS && p.gpu.kind == .graphics { b.graphics = p } else if pipelineBindPoint
    == VK_PIPELINE_BIND_POINT_COMPUTE && p.gpu.kind == .compute
  {
    b.compute = p
  } else { b.fail(VK_ERROR_UNKNOWN, "a pipeline bound at the wrong bind point") }
}

func core_vkCmdBindDescriptorSets(_ commandBuffer: VkCommandBuffer?, _ pipelineBindPoint: VkPipelineBindPoint, _ layout: VkPipelineLayout?,
                                  _ firstSet: UInt32, _ descriptorSetCount: UInt32, _ pDescriptorSets: UnsafePointer<VkDescriptorSet?>?,
                                  _ dynamicOffsetCount: UInt32, _ pDynamicOffsets: UnsafePointer<UInt32>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  if dynamicOffsetCount > 0 {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "dynamic descriptor offsets")
    return
  }
  if Int(firstSet) + Int(descriptorSetCount) > RootBlock.maxSets {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "descriptor sets past \(RootBlock.maxSets)")
    return
  }
  for i in 0..<Int(descriptorSetCount) {
    guard let s = unsafe Handle.get(pDescriptorSets![i], DescriptorSetObject.self) else { continue }
    b.sets[Int(firstSet) + i] = s.address
  }
}

func core_vkCmdPushConstants(_ commandBuffer: VkCommandBuffer?, _ layout: VkPipelineLayout?, _ stageFlags: VkShaderStageFlags,
                             _ offset: UInt32, _ size: UInt32, _ pValues: UnsafeRawPointer?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let v = unsafe pValues else { return }
  if Int(offset) + Int(size) > RootBlock.maxPushConstantBytes {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "push constants past \(RootBlock.maxPushConstantBytes) bytes")
    return
  }
  for i in 0..<Int(size) { b.push[Int(offset) + i] = unsafe v.load(fromByteOffset: i, as: UInt8.self) }
}

func core_vkCmdBindVertexBuffers(_ commandBuffer: VkCommandBuffer?, _ firstBinding: UInt32, _ bindingCount: UInt32,
                                 _ pBuffers: UnsafePointer<VkBuffer?>?, _ pOffsets: UnsafePointer<VkDeviceSize>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  if Int(firstBinding) + Int(bindingCount) > RootBlock.maxVertexBuffers {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "vertex buffers past \(RootBlock.maxVertexBuffers)")
    return
  }
  for i in 0..<Int(bindingCount) {
    let buffer = unsafe Handle.get(pBuffers![i], BufferObject.self)
    b.vertexBuffers[Int(firstBinding) + i] = (buffer?.address ?? 0) + (unsafe pOffsets![i])
  }
}

func core_vkCmdBindIndexBuffer(_ commandBuffer: VkCommandBuffer?, _ buffer: VkBuffer?, _ offset: VkDeviceSize, _ indexType: VkIndexType) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let buf = unsafe Handle.get(buffer, BufferObject.self),
    let place = buf.place
  else { return }
  if indexType == VK_INDEX_TYPE_UINT16 {
    b.index = (place.memory, place.offset + Int(offset), .uint16)
  } else if indexType == VK_INDEX_TYPE_UINT32 {
    b.index = (place.memory, place.offset + Int(offset), .uint32)
  } else { b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "8-bit indices") }
}

func core_vkCmdSetViewport(_ commandBuffer: VkCommandBuffer?, _ firstViewport: UInt32, _ viewportCount: UInt32,
                           _ pViewports: UnsafePointer<VkViewport>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let v = unsafe pViewports else { return }
  if firstViewport != 0 || viewportCount != 1 {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "more than one viewport")
    return
  }
  b.viewport = unsafe (v[0].x, v[0].y, v[0].width, v[0].height)
}

func core_vkCmdSetScissor(_ commandBuffer: VkCommandBuffer?, _ firstScissor: UInt32, _ scissorCount: UInt32,
                          _ pScissors: UnsafePointer<VkRect2D>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let s = unsafe pScissors else { return }
  if firstScissor != 0 || scissorCount != 1 {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "more than one scissor")
    return
  }
  b.scissor = unsafe (s[0].offset.x, s[0].offset.y, s[0].extent.width, s[0].extent.height)
}

// MARK: Passes

/// The clear a load op and a clear value make: nil where the value is an integer's (not here).
func loadAction(_ op: VkAttachmentLoadOp, _ value: VkClearValue) -> LoadAction {
  if op == VK_ATTACHMENT_LOAD_OP_LOAD { return .load }
  if op == VK_ATTACHMENT_LOAD_OP_CLEAR {
    let c = unsafe value.color.float32
    return .clear(c.0, c.1, c.2, c.3)
  }
  return .dontCare
}

func beginRenderPass(_ commandBuffer: VkCommandBuffer?, _ pBegin: UnsafePointer<VkRenderPassBeginInfo>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pBegin,
    let pass = unsafe Handle.get(info.pointee.renderPass, RenderPassObject.self),
    let fb = unsafe Handle.get(info.pointee.framebuffer, FramebufferObject.self)
  else { return }
  var colors: [Attachment] = []
  for a in pass.colors {
    guard a < fb.views.count else {
      b.fail(VK_ERROR_UNKNOWN, "a framebuffer with fewer attachments than its render pass")
      return
    }
    let d = pass.attachments[a]
    let clear = Int(unsafe info.pointee.clearValueCount) > a ? unsafe info.pointee.pClearValues[a] : VkClearValue()
    colors.append(Attachment(image: fb.views[a].image.image, load: loadAction(d.load, clear), store: d.store))
  }
  b.begin(RenderingInfo(colors: colors), area: unsafe info.pointee.renderArea)
  b.passIsRenderPass = true
}

func core_vkCmdBeginRenderPass(_ commandBuffer: VkCommandBuffer?, _ pRenderPassBegin: UnsafePointer<VkRenderPassBeginInfo>?,
                               _ contents: VkSubpassContents)
{
  unsafe beginRenderPass(commandBuffer, pRenderPassBegin)
}

func core_vkCmdBeginRenderPass2(_ commandBuffer: VkCommandBuffer?, _ pRenderPassBegin: UnsafePointer<VkRenderPassBeginInfo>?,
                                _ pSubpassBeginInfo: UnsafePointer<VkSubpassBeginInfo>?)
{
  unsafe beginRenderPass(commandBuffer, pRenderPassBegin)
}

func core_vkCmdEndRenderPass(_ commandBuffer: VkCommandBuffer?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  b.end()
}

func core_vkCmdEndRenderPass2(_ commandBuffer: VkCommandBuffer?, _ pSubpassEndInfo: UnsafePointer<VkSubpassEndInfo>?) {
  unsafe core_vkCmdEndRenderPass(commandBuffer)
}

func core_vkCmdNextSubpass(_ commandBuffer: VkCommandBuffer?, _ contents: VkSubpassContents) {
  unsafe Handle.get(commandBuffer, CommandBufferObject.self)?.fail(VK_ERROR_FEATURE_NOT_PRESENT, "subpasses after the first")
}

func core_vkCmdBeginRendering(_ commandBuffer: VkCommandBuffer?, _ pRenderingInfo: UnsafePointer<VkRenderingInfo>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pRenderingInfo else { return }
  let r = unsafe info.pointee
  if unsafe r.pDepthAttachment != nil || r.pStencilAttachment != nil || r.viewMask != 0 || r.layerCount > 1 {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "depth or stencil attachments, a view mask or layers")
    return
  }
  var colors: [Attachment] = []
  for i in unsafe 0..<Int(r.colorAttachmentCount) {
    let a = unsafe r.pColorAttachments[i]
    guard let v = unsafe Handle.get(a.imageView, ImageViewObject.self) else {
      b.fail(VK_ERROR_UNKNOWN, "a rendering attachment with no view")
      return
    }
    if unsafe a.resolveMode != VK_RESOLVE_MODE_NONE {
      b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "a resolve")
      return
    }
    unsafe colors.append(Attachment(image: v.image.image, load: loadAction(a.loadOp, a.clearValue), store: attachmentStore(a.storeOp)))
  }
  unsafe b.begin(RenderingInfo(colors: colors), area: r.renderArea)
  b.passIsRenderPass = false
}

func core_vkCmdEndRendering(_ commandBuffer: VkCommandBuffer?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  b.end()
}

// MARK: Draws and dispatches

func core_vkCmdDraw(_ commandBuffer: VkCommandBuffer?, _ vertexCount: UInt32, _ instanceCount: UInt32, _ firstVertex: UInt32,
                    _ firstInstance: UInt32)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let d = b.prepareDraw() else { return }
  b.list.draw(d.pipeline, root: d.root, vertices: vertexCount, instances: instanceCount, firstVertex: firstVertex,
              firstInstance: firstInstance)
}

func core_vkCmdDrawIndexed(_ commandBuffer: VkCommandBuffer?, _ indexCount: UInt32, _ instanceCount: UInt32, _ firstIndex: UInt32,
                           _ vertexOffset: Int32, _ firstInstance: UInt32)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  guard let ix = b.index else {
    b.fail(VK_ERROR_UNKNOWN, "an indexed draw with no index buffer bound")
    return
  }
  guard let d = b.prepareDraw() else { return }
  b.list.drawIndexed(d.pipeline, root: d.root, indices: ix.memory, indexOffset: ix.offset, indexType: ix.type, count: indexCount,
                     instances: instanceCount, firstIndex: firstIndex, vertexOffset: vertexOffset, firstInstance: firstInstance)
}

func core_vkCmdDrawIndirect(_ commandBuffer: VkCommandBuffer?, _ buffer: VkBuffer?, _ offset: VkDeviceSize, _ drawCount: UInt32,
                            _ stride: UInt32)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let buf = unsafe Handle.get(buffer, BufferObject.self),
    let place = buf.place
  else { return }
  guard let d = b.prepareDraw() else { return }
  b.list.drawIndirect(d.pipeline, root: d.root, arguments: place.memory, offset: place.offset + Int(offset), drawCount: drawCount,
                      stride: max(stride, 16))
}

func core_vkCmdDrawIndexedIndirect(_ commandBuffer: VkCommandBuffer?, _ buffer: VkBuffer?, _ offset: VkDeviceSize, _ drawCount: UInt32,
                                   _ stride: UInt32)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let buf = unsafe Handle.get(buffer, BufferObject.self),
    let place = buf.place
  else { return }
  guard let ix = b.index else {
    b.fail(VK_ERROR_UNKNOWN, "an indexed draw with no index buffer bound")
    return
  }
  guard let d = b.prepareDraw() else { return }
  b.list.drawIndexedIndirect(d.pipeline, root: d.root, indices: ix.memory, indexOffset: ix.offset, indexType: ix.type,
                             arguments: place.memory, offset: place.offset + Int(offset), drawCount: drawCount, stride: max(stride, 20))
}

func core_vkCmdDispatch(_ commandBuffer: VkCommandBuffer?, _ groupCountX: UInt32, _ groupCountY: UInt32, _ groupCountZ: UInt32) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  // A dispatch of no workgroups does nothing.
  if groupCountX == 0 || groupCountY == 0 || groupCountZ == 0 { return }
  guard let d = b.prepareDispatch() else { return }
  b.list.dispatch(d.pipeline, root: d.root, x: groupCountX, y: groupCountY, z: groupCountZ)
}

func core_vkCmdDispatchIndirect(_ commandBuffer: VkCommandBuffer?, _ buffer: VkBuffer?, _ offset: VkDeviceSize) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let buf = unsafe Handle.get(buffer, BufferObject.self),
    let place = buf.place
  else { return }
  guard let d = b.prepareDispatch() else { return }
  b.list.dispatchIndirect(d.pipeline, root: d.root, arguments: place.memory, offset: place.offset + Int(offset))
}

// MARK: Copies

func core_vkCmdCopyBuffer(_ commandBuffer: VkCommandBuffer?, _ srcBuffer: VkBuffer?, _ dstBuffer: VkBuffer?, _ regionCount: UInt32,
                          _ pRegions: UnsafePointer<VkBufferCopy>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let s = unsafe Handle.get(srcBuffer, BufferObject.self),
    let d = unsafe Handle.get(dstBuffer, BufferObject.self), let from = s.place, let to = d.place
  else { return }
  for i in 0..<Int(regionCount) {
    let r = unsafe pRegions![i]
    b.list.copy(from.memory, fromOffset: from.offset + Int(r.srcOffset), to: to.memory, toOffset: to.offset + Int(r.dstOffset),
                bytes: Int(r.size))
  }
}

/// Fills `bytes` of the arena from `fill`, and copies them into `buffer` at `offset`.
func uploadToBuffer(_ b: CommandBufferObject, _ dst: BufferObject, _ offset: UInt64, _ bytes: Int, _ fill: (UnsafeMutableRawPointer) -> Void) {
  guard let to = dst.place, bytes > 0 else { return }
  guard let a = b.arena(bytes, alignment: 16), let p = unsafe a.memory.pointer else { return }
  unsafe fill(unsafe p + a.offset)
  b.list.copy(a.memory, fromOffset: a.offset, to: to.memory, toOffset: to.offset + Int(offset), bytes: bytes)
}

func core_vkCmdUpdateBuffer(_ commandBuffer: VkCommandBuffer?, _ dstBuffer: VkBuffer?, _ dstOffset: VkDeviceSize, _ dataSize: VkDeviceSize,
                            _ pData: UnsafeRawPointer?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let d = unsafe Handle.get(dstBuffer, BufferObject.self),
    let data = unsafe pData
  else { return }
  unsafe uploadToBuffer(b, d, dstOffset, Int(dataSize)) { p in unsafe p.copyMemory(from: data, byteCount: Int(dataSize)) }
}

func core_vkCmdFillBuffer(_ commandBuffer: VkCommandBuffer?, _ dstBuffer: VkBuffer?, _ dstOffset: VkDeviceSize, _ size: VkDeviceSize,
                          _ data: UInt32)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let d = unsafe Handle.get(dstBuffer, BufferObject.self) else { return }
  let bytes = Int(size == ~0 ? d.size - dstOffset : size) & ~3
  unsafe uploadToBuffer(b, d, dstOffset, bytes) { p in
    for i in 0..<(bytes / 4) { unsafe p.storeBytes(of: data, toByteOffset: i * 4, as: UInt32.self) }
  }
}

/// Whether a buffer-image copy region is the whole image, packed tightly (what the core copies).
func wholeImageRegion(_ r: VkBufferImageCopy, _ image: GPUImage) -> Bool {
  r.imageSubresource.aspectMask == VK_IMAGE_ASPECT_COLOR_BIT.rawValue && r.imageSubresource.mipLevel == 0
    && r.imageSubresource.baseArrayLayer == 0 && r.imageSubresource.layerCount == 1 && r.imageOffset.x == 0 && r.imageOffset.y == 0
    && r.imageOffset.z == 0 && r.imageExtent.width == UInt32(image.width) && r.imageExtent.height == UInt32(image.height)
    && r.imageExtent.depth == 1 && (r.bufferRowLength == 0 || r.bufferRowLength == UInt32(image.width))
    && (r.bufferImageHeight == 0 || r.bufferImageHeight == UInt32(image.height))
}

func core_vkCmdCopyBufferToImage(_ commandBuffer: VkCommandBuffer?, _ srcBuffer: VkBuffer?, _ dstImage: VkImage?,
                                 _ dstImageLayout: VkImageLayout, _ regionCount: UInt32, _ pRegions: UnsafePointer<VkBufferImageCopy>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let s = unsafe Handle.get(srcBuffer, BufferObject.self),
    let i = unsafe Handle.get(dstImage, ImageObject.self), let from = s.place
  else { return }
  for k in 0..<Int(regionCount) {
    let r = unsafe pRegions![k]
    guard wholeImageRegion(r, i.image) else {
      b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "a copy of part of an image")
      return
    }
    b.list.copy(from.memory, offset: from.offset + Int(r.bufferOffset), to: i.image)
  }
}

func core_vkCmdCopyImageToBuffer(_ commandBuffer: VkCommandBuffer?, _ srcImage: VkImage?, _ srcImageLayout: VkImageLayout,
                                 _ dstBuffer: VkBuffer?, _ regionCount: UInt32, _ pRegions: UnsafePointer<VkBufferImageCopy>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let d = unsafe Handle.get(dstBuffer, BufferObject.self),
    let i = unsafe Handle.get(srcImage, ImageObject.self), let to = d.place
  else { return }
  for k in 0..<Int(regionCount) {
    let r = unsafe pRegions![k]
    guard wholeImageRegion(r, i.image) else {
      b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "a copy of part of an image")
      return
    }
    b.list.copy(i.image, to: to.memory, offset: to.offset + Int(r.bufferOffset))
  }
}

func core_vkCmdClearColorImage(_ commandBuffer: VkCommandBuffer?, _ image: VkImage?, _ imageLayout: VkImageLayout,
                               _ pColor: UnsafePointer<VkClearColorValue>?, _ rangeCount: UInt32,
                               _ pRanges: UnsafePointer<VkImageSubresourceRange>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let i = unsafe Handle.get(image, ImageObject.self),
    let color = unsafe pColor
  else { return }
  for k in 0..<Int(rangeCount) {
    let r = unsafe pRanges![k]
    if r.baseMipLevel != 0 || r.baseArrayLayer != 0 || (r.levelCount != 1 && r.levelCount != ~0) || (r.layerCount != 1 && r.layerCount != ~0) {
      b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "a clear of part of an image")
      return
    }
  }
  guard i.image.usage.contains(.renderTarget) else {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "a clear of an image that can't be drawn into")
    return
  }
  let c = unsafe color.pointee.float32
  // A pass that clears and draws nothing.
  b.list.render(RenderingInfo(colors: [Attachment(image: i.image, load: .clear(c.0, c.1, c.2, c.3), store: .store)])) { _ in }
}

// MARK: Barriers and queries

/// The core's stages for a Vulkan stage mask (either width): all of them where the mask names the ends of the pipe, the host
/// or everything, which only need to be conservative.
func stages(_ m: UInt64) -> PipelineStages {
  let all: UInt64 = 0x10000 | 0x8000 | 0x4000
  if m & all != 0 { return .all }
  var s = PipelineStages(rawValue: 0)
  if m & 0x800 != 0 { s = s | .compute }
  if m & (0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40) != 0 { s = s | .vertex }
  if m & (0x80 | 0x100 | 0x200 | 0x400) != 0 { s = s | .fragment }
  if m & (0x1000 | 0xF_0000_0000) != 0 { s = s | .transfer }
  return s.rawValue == 0 ? .all : s
}

func emitBarrier(_ b: CommandBufferObject, from: UInt64, to: UInt64) {
  // Inside a pass a barrier is a dependency the pass itself keeps.
  if b.inPass { return }
  b.list.barrier(from: stages(from), to: stages(to))
}

func core_vkCmdPipelineBarrier(_ commandBuffer: VkCommandBuffer?, _ srcStageMask: VkPipelineStageFlags, _ dstStageMask: VkPipelineStageFlags,
                               _ dependencyFlags: VkDependencyFlags, _ memoryBarrierCount: UInt32,
                               _ pMemoryBarriers: UnsafePointer<VkMemoryBarrier>?, _ bufferMemoryBarrierCount: UInt32,
                               _ pBufferMemoryBarriers: UnsafePointer<VkBufferMemoryBarrier>?, _ imageMemoryBarrierCount: UInt32,
                               _ pImageMemoryBarriers: UnsafePointer<VkImageMemoryBarrier>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  emitBarrier(b, from: UInt64(srcStageMask), to: UInt64(dstStageMask))
}

func core_vkCmdPipelineBarrier2(_ commandBuffer: VkCommandBuffer?, _ pDependencyInfo: UnsafePointer<VkDependencyInfo>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pDependencyInfo else { return }
  var from: UInt64 = 0
  var to: UInt64 = 0
  var any = false
  for i in 0..<Int(unsafe info.pointee.memoryBarrierCount) {
    let m = unsafe info.pointee.pMemoryBarriers[i]
    unsafe from |= m.srcStageMask
    unsafe to |= m.dstStageMask
    any = true
  }
  for i in 0..<Int(unsafe info.pointee.bufferMemoryBarrierCount) {
    let m = unsafe info.pointee.pBufferMemoryBarriers[i]
    unsafe from |= m.srcStageMask
    unsafe to |= m.dstStageMask
    any = true
  }
  for i in 0..<Int(unsafe info.pointee.imageMemoryBarrierCount) {
    let m = unsafe info.pointee.pImageMemoryBarriers[i]
    unsafe from |= m.srcStageMask
    unsafe to |= m.dstStageMask
    any = true
  }
  if any { emitBarrier(b, from: from, to: to) }
}

final class QueryPoolObject: CoreObject {
  let set: GPUQuerySet
  let device: DeviceObject
  init(set: GPUQuerySet, device: DeviceObject) {
    self.set = set
    self.device = device
  }
}

func core_vkCreateQueryPool(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkQueryPoolCreateInfo>?,
                            _ pAllocator: UnsafePointer<VkAllocationCallbacks>?, _ pQueryPool: UnsafeMutablePointer<VkQueryPool?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pCreateInfo, let out = unsafe pQueryPool else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let kind: QueryKind
  if unsafe info.pointee.queryType == VK_QUERY_TYPE_TIMESTAMP { kind = .timestamp } else if unsafe info.pointee.queryType
    == VK_QUERY_TYPE_OCCLUSION
  {
    kind = .occlusion
  } else {
    say("unsupported: a query pool of type \(unsafe info.pointee.queryType.rawValue)")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  do throws(GPUError) {
    let set = try d.gpu.makeQuerySet(kind, count: Int(unsafe info.pointee.queryCount))
    unsafe out.pointee = Handle.make(QueryPoolObject(set: set, device: d))
  } catch { return vkResult(error) }
  return VK_SUCCESS
}

func core_vkDestroyQueryPool(_ device: VkDevice?, _ queryPool: VkQueryPool?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let q = unsafe Handle.get(queryPool, QueryPoolObject.self) else { return }
  q.device.gpu.destroy(q.set)
  unsafe Handle.destroy(queryPool)
}

/// Queries start fresh when the pool is made and each write replaces its slot: there is nothing to reset.
func core_vkCmdResetQueryPool(_ commandBuffer: VkCommandBuffer?, _ queryPool: VkQueryPool?, _ firstQuery: UInt32, _ queryCount: UInt32) {}

func core_vkCmdWriteTimestamp(_ commandBuffer: VkCommandBuffer?, _ pipelineStage: VkPipelineStageFlagBits, _ queryPool: VkQueryPool?,
                              _ query: UInt32)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let q = unsafe Handle.get(queryPool, QueryPoolObject.self) else { return }
  b.list.writeTimestamp(q.set, index: Int(query), after: stages(UInt64(pipelineStage.rawValue)))
}

func core_vkCmdWriteTimestamp2(_ commandBuffer: VkCommandBuffer?, _ stage: VkPipelineStageFlags2, _ queryPool: VkQueryPool?, _ query: UInt32) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let q = unsafe Handle.get(queryPool, QueryPoolObject.self) else { return }
  b.list.writeTimestamp(q.set, index: Int(query), after: stages(stage))
}

func core_vkCmdBeginQuery(_ commandBuffer: VkCommandBuffer?, _ queryPool: VkQueryPool?, _ query: UInt32, _ flags: VkQueryControlFlags) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let q = unsafe Handle.get(queryPool, QueryPoolObject.self) else { return }
  b.list.beginQuery(q.set, index: Int(query))
}

func core_vkCmdEndQuery(_ commandBuffer: VkCommandBuffer?, _ queryPool: VkQueryPool?, _ query: UInt32) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let q = unsafe Handle.get(queryPool, QueryPoolObject.self) else { return }
  b.list.endQuery(q.set, index: Int(query))
}

func core_vkGetQueryPoolResults(_ device: VkDevice?, _ queryPool: VkQueryPool?, _ firstQuery: UInt32, _ queryCount: UInt32, _ dataSize: Int,
                                _ pData: UnsafeMutableRawPointer?, _ stride: VkDeviceSize, _ flags: VkQueryResultFlags) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let q = unsafe Handle.get(queryPool, QueryPoolObject.self), let out = unsafe pData else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  // The core gives results once the work that wrote them is done.
  if d.lastSubmitted > d.gpu.completed {
    if flags & VK_QUERY_RESULT_WAIT_BIT.rawValue != 0 {
      let r = d.waitIdle()
      if r != VK_SUCCESS { return r }
    } else { return VK_NOT_READY }
  }
  do throws(GPUError) {
    let values = try d.gpu.results(q.set, first: Int(firstQuery), count: Int(queryCount))
    let wide = flags & VK_QUERY_RESULT_64_BIT.rawValue != 0
    let availability = flags & VK_QUERY_RESULT_WITH_AVAILABILITY_BIT.rawValue != 0
    for i in 0..<Int(queryCount) {
      let at = unsafe out + i * Int(stride)
      if wide {
        unsafe at.storeBytes(of: values[i], as: UInt64.self)
        if availability { unsafe at.storeBytes(of: 1, toByteOffset: 8, as: UInt64.self) }
      } else {
        unsafe at.storeBytes(of: UInt32(truncatingIfNeeded: values[i]), as: UInt32.self)
        if availability { unsafe at.storeBytes(of: 1, toByteOffset: 4, as: UInt32.self) }
      }
    }
  } catch { return vkResult(error) }
  return VK_SUCCESS
}
