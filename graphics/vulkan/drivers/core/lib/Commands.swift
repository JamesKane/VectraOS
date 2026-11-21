// SPDX-License-Identifier: BSD-3-Clause

// Command pools and buffers (D174 step 5, part 3). A command buffer records a `GPUCommandList`. A draw or a
// dispatch writes a root block (RootBlock: the bound sets' addresses, the vertex buffers' addresses, the push
// constants) into the command buffer's arena, 64 KB chunks of `.upload` memory, and names its address. The arena
// is the command buffer's until the timeline passes the value of the last submission that used it.
//
// Vulkan's commands return nothing, so what the layer can't record it remembers (`error`) and says at
// vkEndCommandBuffer; the list's own rules (`GPUCommandList.validate`, against the device's limits and its formats'
// capabilities) are judged there too, so a feature the device lacks fails the end of the buffer with
// VK_ERROR_FEATURE_NOT_PRESENT.
//
// A secondary command buffer is a list of its own, which vkCmdExecuteCommands appends to the primary's; the state a
// pass's commands set (viewport, scissor, blend constants, stencil values, depth bias and bounds, line width) is kept
// by the buffer and sent to the core before the draw that needs it, where it differs from what the core last had.

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
  // The sets bound at each bind point: they are kept apart, as Vulkan keeps them.
  var sets = [UInt64](repeating: 0, count: RootBlock.maxSets)
  var computeSets = [UInt64](repeating: 0, count: RootBlock.maxSets)
  // The dynamic offsets bound with each set, in the set layout's order.
  var dynamicOffsets = [[UInt32]](repeating: [], count: RootBlock.maxSets)
  var computeDynamicOffsets = [[UInt32]](repeating: [], count: RootBlock.maxSets)
  /// The addresses vkCmdBindDescriptorBuffersEXT bound.
  var descriptorBuffers = [UInt64](repeating: 0, count: maxDescriptorBuffers)
  var push = [UInt8](repeating: 0, count: RootBlock.maxPushConstantBytes)
  var vertexBuffers = [UInt64](repeating: 0, count: RootBlock.maxVertexBuffers)
  var index: (memory: GPUMemory, offset: Int, type: IndexType)?
  /// The state the commands set, and what the core has been told in this pass.
  var state = DynamicValues()
  var sent = DynamicValues()
  var inPass = false
  var passIsRenderPass = false
  /// The colour attachments' formats in the pass the core has, for clearAttachments.
  var passColorFormats: [PixelFormat] = []
  /// The render pass being run, its framebuffer, the clear values, the area and the subpass the core has.
  var running: (pass: RenderPassObject, framebuffer: FramebufferObject, clears: [VkClearValue], area: VkRect2D, subpass: Int)?
  /// A secondary buffer: its list is appended to a primary's.
  var secondary = false
  /// The secondary buffers this one executes: their arenas stay until this buffer's work is done.
  var executed: [CommandBufferObject] = []
  /// The events this buffer sets and resets when it is submitted, and whether each is set.
  var eventWrites: [(event: EventObject, set: Bool)] = []

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
    computeSets = [UInt64](repeating: 0, count: RootBlock.maxSets)
    dynamicOffsets = [[UInt32]](repeating: [], count: RootBlock.maxSets)
    computeDynamicOffsets = [[UInt32]](repeating: [], count: RootBlock.maxSets)
    descriptorBuffers = [UInt64](repeating: 0, count: maxDescriptorBuffers)
    push = [UInt8](repeating: 0, count: RootBlock.maxPushConstantBytes)
    vertexBuffers = [UInt64](repeating: 0, count: RootBlock.maxVertexBuffers)
    index = nil
    state = DynamicValues()
    sent = DynamicValues()
    inPass = false
    passIsRenderPass = false
    running = nil
    executed = []
    eventWrites = []
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
  func rootBlock(_ bound: [UInt64], dynamic: [[UInt32]], layout: PipelineLayoutObject?) -> UInt64? {
    guard let a = arena(RootBlock.size), let p = unsafe a.memory.pointer else { return nil }
    let at = unsafe p + a.offset
    unsafe at.initializeMemory(as: UInt8.self, repeating: 0, count: RootBlock.size)
    for i in 0..<RootBlock.maxSets { unsafe at.storeBytes(of: bound[i], toByteOffset: RootBlock.setsOffset + 8 * i, as: UInt64.self) }
    for i in 0..<RootBlock.maxVertexBuffers {
      unsafe at.storeBytes(of: vertexBuffers[i], toByteOffset: RootBlock.vertexBuffersOffset + 8 * i, as: UInt64.self)
    }
    for i in 0..<RootBlock.maxPushConstantBytes {
      unsafe at.storeBytes(of: push[i], toByteOffset: RootBlock.pushConstantsOffset + i, as: UInt8.self)
    }
    // Each set's dynamic offsets go where the lowering reads them: after those of the sets before it in the pipeline layout.
    var next = 0
    if let layout {
      for s in 0..<min(RootBlock.maxSets, layout.sets.count) {
        let count = layout.sets[s]?.layout.dynamicCount ?? 0
        for k in 0..<count where next + k < RootBlock.maxDynamicOffsets && k < dynamic[s].count {
          unsafe at.storeBytes(of: dynamic[s][k], toByteOffset: RootBlock.dynamicOffsetsOffset + 4 * (next + k), as: UInt32.self)
        }
        next += count
      }
    }
    return a.memory.address + UInt64(a.offset)
  }

  /// Emits the state the next draw needs, where it differs from what the pass has: the viewport and scissor, and what the
  /// pipeline leaves to commands.
  func sendState(_ p: PipelineObject) {
    guard inPass else { return }
    if let v = p.viewport ?? state.viewport, sent.viewport == nil || sent.viewport! != v {
      list.setViewport(x: v.0, y: v.1, width: v.2, height: v.3)
      sent.viewport = v
    }
    if let s = p.scissor ?? state.scissor, sent.scissor == nil || sent.scissor! != s {
      list.setScissor(x: s.0, y: s.1, width: s.2, height: s.3)
      sent.scissor = s
    }
    let d = p.dynamic
    if d.contains(.blendConstants), let k = state.blendConstants, sent.blendConstants != k {
      list.setBlendConstants(k)
      sent.blendConstants = k
    }
    if d.contains(.depthBias), let k = state.depthBias, sent.depthBias == nil || sent.depthBias! != k {
      list.setDepthBias(constant: k.0, clamp: k.1, slope: k.2)
      sent.depthBias = k
    }
    if d.contains(.depthBounds), let k = state.depthBounds, sent.depthBounds == nil || sent.depthBounds! != k {
      list.setDepthBounds(min: k.0, max: k.1)
      sent.depthBounds = k
    }
    if d.contains(.lineWidth), let k = state.lineWidth, sent.lineWidth != k {
      list.setLineWidth(k)
      sent.lineWidth = k
    }
    if d.contains(.stencilReference) {
      sendStencil(state.stencilReference, &sent.stencilReference) { list.setStencilReference($0, $1) }
    }
    if d.contains(.stencilCompareMask) {
      sendStencil(state.stencilCompareMask, &sent.stencilCompareMask) { list.setStencilCompareMask($0, $1) }
    }
    if d.contains(.stencilWriteMask) {
      sendStencil(state.stencilWriteMask, &sent.stencilWriteMask) { list.setStencilWriteMask($0, $1) }
    }
  }

  /// A stencil value for each face: sent for both at once where they are the same.
  private func sendStencil(_ want: StencilValues, _ have: inout StencilValues, _ send: (StencilFaces, UInt32) -> Void) {
    if let f = want.front, let b = want.back, f == b {
      if have.front != f || have.back != b { send(.both, f) }
    } else {
      if let f = want.front, have.front != f { send(.front, f) }
      if let b = want.back, have.back != b { send(.back, b) }
    }
    if want.front != nil { have.front = want.front }
    if want.back != nil { have.back = want.back }
  }

  /// A graphics pipeline and a root block for a draw, with the state it needs sent.
  func prepareDraw() -> (pipeline: GPUPipeline, root: UInt64)? {
    guard let p = graphics else {
      fail(VK_ERROR_UNKNOWN, "a draw with no pipeline bound")
      return nil
    }
    sendState(p)
    guard let root = rootBlock(sets, dynamic: dynamicOffsets, layout: p.layout) else { return nil }
    return (p.gpu, root)
  }

  func prepareDispatch() -> (pipeline: GPUPipeline, root: UInt64)? {
    guard let p = compute else {
      fail(VK_ERROR_UNKNOWN, "a dispatch with no pipeline bound")
      return nil
    }
    guard let root = rootBlock(computeSets, dynamic: computeDynamicOffsets, layout: p.layout) else { return nil }
    return (p.gpu, root)
  }

  /// Begins the core's pass: what the pass sets the state to is not what the last pass left.
  func begin(_ info: RenderingInfo, integerClears: [ClearAttachment] = []) {
    list.beginRendering(info)
    inPass = true
    sent = DynamicValues()
    if !integerClears.isEmpty {
      let a = info.area
      list.clearAttachments(integerClears, rects: [ClearRect(x: a.x, y: a.y, width: a.width, height: a.height, baseLayer: 0, layerCount: max(info.layerCount, 1))])
    }
  }

  func end() {
    list.endRendering()
    inPass = false
  }
}

/// A stencil value for each face.
struct StencilValues: Equatable {
  var front: UInt32?
  var back: UInt32?
}

/// The state a pass's commands set.
struct DynamicValues {
  var viewport: (Float, Float, Float, Float)?
  var scissor: (Int32, Int32, UInt32, UInt32)?
  var blendConstants: BlendConstants?
  var depthBias: (Float, Float, Float)?
  var depthBounds: (Float, Float)?
  var lineWidth: Float?
  var stencilReference = StencilValues()
  var stencilCompareMask = StencilValues()
  var stencilWriteMask = StencilValues()
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
  let secondary = unsafe info.pointee.level == VK_COMMAND_BUFFER_LEVEL_SECONDARY
  for i in 0..<Int(unsafe info.pointee.commandBufferCount) {
    let b = CommandBufferObject(device: d)
    b.secondary = secondary
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
  // A secondary buffer that continues a render pass records inside the pass its primary has.
  if b.secondary, let begin = unsafe pBeginInfo, unsafe begin.pointee.flags & VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT.rawValue != 0 {
    b.inPass = true
  }
  return VK_SUCCESS
}

func core_vkEndCommandBuffer(_ commandBuffer: VkCommandBuffer?) -> VkResult {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  b.recording = false
  if let e = b.error { return e }
  // What the device lacks is refused here, by the one place the rules are written. A secondary buffer is judged with the
  // primary that executes it.
  if !b.secondary, let e = b.list.validate(limits: b.device.gpu.limits) { return vkResult(e) }
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
  if Int(firstSet) + Int(descriptorSetCount) > RootBlock.maxSets {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "descriptor sets past \(RootBlock.maxSets)")
    return
  }
  var used = 0
  for i in 0..<Int(descriptorSetCount) {
    guard let s = unsafe Handle.get(pDescriptorSets![i], DescriptorSetObject.self) else { continue }
    // The offsets come in the order of the sets, each set's in its binding order.
    var mine: [UInt32] = []
    for _ in 0..<s.layout.layout.dynamicCount {
      guard used < Int(dynamicOffsetCount), let o = unsafe pDynamicOffsets?[used] else {
        b.fail(VK_ERROR_UNKNOWN, "fewer dynamic offsets than the bound sets' dynamic descriptors")
        return
      }
      mine.append(o)
      used += 1
    }
    if pipelineBindPoint == VK_PIPELINE_BIND_POINT_COMPUTE {
      b.computeSets[Int(firstSet) + i] = s.address
      b.computeDynamicOffsets[Int(firstSet) + i] = mine
    } else {
      b.sets[Int(firstSet) + i] = s.address
      b.dynamicOffsets[Int(firstSet) + i] = mine
    }
  }
  if used != Int(dynamicOffsetCount) { b.fail(VK_ERROR_UNKNOWN, "more dynamic offsets than the bound sets' dynamic descriptors") }
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
  b.state.viewport = unsafe (v[0].x, v[0].y, v[0].width, v[0].height)
}

func core_vkCmdSetScissor(_ commandBuffer: VkCommandBuffer?, _ firstScissor: UInt32, _ scissorCount: UInt32,
                          _ pScissors: UnsafePointer<VkRect2D>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let s = unsafe pScissors else { return }
  if firstScissor != 0 || scissorCount != 1 {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "more than one scissor")
    return
  }
  b.state.scissor = unsafe (s[0].offset.x, s[0].offset.y, s[0].extent.width, s[0].extent.height)
}

func core_vkCmdSetBlendConstants(_ commandBuffer: VkCommandBuffer?, _ blendConstants: UnsafePointer<Float>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let k = unsafe blendConstants else { return }
  b.state.blendConstants = unsafe BlendConstants(red: k[0], green: k[1], blue: k[2], alpha: k[3])
}

func core_vkCmdSetDepthBias(_ commandBuffer: VkCommandBuffer?, _ depthBiasConstantFactor: Float, _ depthBiasClamp: Float,
                            _ depthBiasSlopeFactor: Float)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  b.state.depthBias = (depthBiasConstantFactor, depthBiasClamp, depthBiasSlopeFactor)
}

func core_vkCmdSetDepthBounds(_ commandBuffer: VkCommandBuffer?, _ minDepthBounds: Float, _ maxDepthBounds: Float) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  b.state.depthBounds = (minDepthBounds, maxDepthBounds)
}

func core_vkCmdSetLineWidth(_ commandBuffer: VkCommandBuffer?, _ lineWidth: Float) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  b.state.lineWidth = lineWidth
}

private func setStencil(_ v: inout StencilValues, _ faceMask: UInt32, _ value: UInt32) {
  if faceMask & VK_STENCIL_FACE_FRONT_BIT.rawValue != 0 { v.front = value }
  if faceMask & VK_STENCIL_FACE_BACK_BIT.rawValue != 0 { v.back = value }
}

func core_vkCmdSetStencilCompareMask(_ commandBuffer: VkCommandBuffer?, _ faceMask: VkStencilFaceFlags, _ compareMask: UInt32) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  setStencil(&b.state.stencilCompareMask, faceMask, compareMask)
}

func core_vkCmdSetStencilWriteMask(_ commandBuffer: VkCommandBuffer?, _ faceMask: VkStencilFaceFlags, _ writeMask: UInt32) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  setStencil(&b.state.stencilWriteMask, faceMask, writeMask)
}

func core_vkCmdSetStencilReference(_ commandBuffer: VkCommandBuffer?, _ faceMask: VkStencilFaceFlags, _ reference: UInt32) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  setStencil(&b.state.stencilReference, faceMask, reference)
}

// MARK: Passes

/// Begins subpass `index` of the render pass being run, as a core pass.
func beginSubpass(_ b: CommandBufferObject, _ index: Int) {
  guard let r = b.running else { return }
  let made = r.clears.withUnsafeBufferPointer { cp in
    unsafe subpassRendering(r.pass, index, r.framebuffer, clears: cp.baseAddress, clearCount: cp.count, area: r.area)
  }
  guard let made else {
    b.fail(VK_ERROR_UNKNOWN, "a framebuffer with fewer attachments than its render pass")
    return
  }
  b.passColorFormats = made.info.colors.map { $0.view.format }
  b.begin(made.info, integerClears: made.integerClears)
}

func beginRenderPass(_ commandBuffer: VkCommandBuffer?, _ pBegin: UnsafePointer<VkRenderPassBeginInfo>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pBegin,
    let pass = unsafe Handle.get(info.pointee.renderPass, RenderPassObject.self),
    let fb = unsafe Handle.get(info.pointee.framebuffer, FramebufferObject.self), !pass.subpasses.isEmpty
  else { return }
  var clears: [VkClearValue] = []
  for i in 0..<Int(unsafe info.pointee.clearValueCount) { clears.append(unsafe info.pointee.pClearValues[i]) }
  b.running = (pass, fb, clears, unsafe info.pointee.renderArea, 0)
  b.passIsRenderPass = true
  beginSubpass(b, 0)
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

func core_vkCmdNextSubpass(_ commandBuffer: VkCommandBuffer?, _ contents: VkSubpassContents) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), var r = b.running else { return }
  // The core's pass ends and the next subpass's begins, loading what this one stored.
  b.end()
  r.subpass += 1
  guard r.subpass < r.pass.subpasses.count else {
    b.fail(VK_ERROR_UNKNOWN, "a next subpass past the render pass's last")
    b.running = nil
    return
  }
  b.running = r
  beginSubpass(b, r.subpass)
}

func core_vkCmdNextSubpass2(_ commandBuffer: VkCommandBuffer?, _ pSubpassBeginInfo: UnsafePointer<VkSubpassBeginInfo>?,
                            _ pSubpassEndInfo: UnsafePointer<VkSubpassEndInfo>?)
{
  unsafe core_vkCmdNextSubpass(commandBuffer, VK_SUBPASS_CONTENTS_INLINE)
}

func core_vkCmdEndRenderPass(_ commandBuffer: VkCommandBuffer?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  if b.running != nil { b.end() }
  b.running = nil
}

func core_vkCmdEndRenderPass2(_ commandBuffer: VkCommandBuffer?, _ pSubpassEndInfo: UnsafePointer<VkSubpassEndInfo>?) {
  unsafe core_vkCmdEndRenderPass(commandBuffer)
}

func core_vkCmdBeginRendering(_ commandBuffer: VkCommandBuffer?, _ pRenderingInfo: UnsafePointer<VkRenderingInfo>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pRenderingInfo else { return }
  let r = unsafe info.pointee
  var colors: [Attachment] = []
  var integer: [ClearAttachment] = []
  for i in unsafe 0..<Int(r.colorAttachmentCount) {
    let a = unsafe r.pColorAttachments[i]
    guard let v = unsafe Handle.get(a.imageView, ImageViewObject.self) else {
      b.fail(VK_ERROR_UNKNOWN, "a rendering attachment with no view")
      return
    }
    var resolve: ImageView?
    if unsafe a.resolveMode != VK_RESOLVE_MODE_NONE, let rv = unsafe Handle.get(a.resolveImageView, ImageViewObject.self) { resolve = rv.view }
    let format = v.view.format
    let load = unsafe loadAction(a.loadOp, a.clearValue, format: format)
    if unsafe a.loadOp == VK_ATTACHMENT_LOAD_OP_CLEAR && format.channelClass != .float {
      integer.append(.color(index: i, unsafe clearColor(a.clearValue.color, format)))
    }
    unsafe colors.append(Attachment(view: v.view, load: load, store: attachmentStore(a.storeOp), resolve: resolve))
  }
  var depthStencil: DepthStencilAttachment?
  let depth = unsafe r.pDepthAttachment
  let stencil = unsafe r.pStencilAttachment
  if unsafe depth != nil || stencil != nil {
    let view = unsafe depth.flatMap { unsafe Handle.get($0.pointee.imageView, ImageViewObject.self) }
      ?? stencil.flatMap { unsafe Handle.get($0.pointee.imageView, ImageViewObject.self) }
    guard let view else {
      b.fail(VK_ERROR_UNKNOWN, "a rendering attachment with no view")
      return
    }
    var resolve: ImageView?
    if let d = unsafe depth, unsafe d.pointee.resolveMode != VK_RESOLVE_MODE_NONE,
      let rv = unsafe Handle.get(d.pointee.resolveImageView, ImageViewObject.self)
    {
      resolve = rv.view
    } else if let s = unsafe stencil, unsafe s.pointee.resolveMode != VK_RESOLVE_MODE_NONE,
      let rv = unsafe Handle.get(s.pointee.resolveImageView, ImageViewObject.self)
    {
      resolve = rv.view
    }
    depthStencil = unsafe DepthStencilAttachment(
      view: view.view, depthLoad: depth.map { unsafe aspectLoad($0.pointee.loadOp) } ?? .dontCare,
      stencilLoad: stencil.map { unsafe aspectLoad($0.pointee.loadOp) } ?? .dontCare,
      depthStore: depth.map { unsafe attachmentStore($0.pointee.storeOp) } ?? .store,
      stencilStore: stencil.map { unsafe attachmentStore($0.pointee.storeOp) } ?? .store,
      clearDepth: depth?.pointee.clearValue.depthStencil.depth ?? 1, clearStencil: stencil?.pointee.clearValue.depthStencil.stencil ?? 0,
      resolve: resolve)
  }
  let first = colors.first?.view ?? depthStencil?.view
  var area: RenderArea?
  if let v = first {
    let a = unsafe r.renderArea
    if a.offset.x != 0 || a.offset.y != 0 || Int32(a.extent.width) != v.width || Int32(a.extent.height) != v.height {
      area = RenderArea(x: a.offset.x, y: a.offset.y, width: a.extent.width, height: a.extent.height)
    }
  }
  let rendering = unsafe RenderingInfo(colors: colors, depthStencil: depthStencil, layerCount: r.viewMask != 0 ? 1 : max(r.layerCount, 1),
                                       viewMask: r.viewMask, renderArea: area)
  b.passColorFormats = colors.map { $0.view.format }
  b.begin(rendering, integerClears: integer)
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

func core_vkCmdDrawIndirectCount(_ commandBuffer: VkCommandBuffer?, _ buffer: VkBuffer?, _ offset: VkDeviceSize,
                                 _ countBuffer: VkBuffer?, _ countBufferOffset: VkDeviceSize, _ maxDrawCount: UInt32, _ stride: UInt32)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let buf = unsafe Handle.get(buffer, BufferObject.self),
    let count = unsafe Handle.get(countBuffer, BufferObject.self), let place = buf.place, let counts = count.place
  else { return }
  guard let d = b.prepareDraw() else { return }
  b.list.drawIndirectCount(d.pipeline, root: d.root, arguments: place.memory, offset: place.offset + Int(offset), countBuffer: counts.memory,
                           countOffset: counts.offset + Int(countBufferOffset), maxDrawCount: maxDrawCount, stride: max(stride, 16))
}

func core_vkCmdDrawIndexedIndirectCount(_ commandBuffer: VkCommandBuffer?, _ buffer: VkBuffer?, _ offset: VkDeviceSize,
                                        _ countBuffer: VkBuffer?, _ countBufferOffset: VkDeviceSize, _ maxDrawCount: UInt32,
                                        _ stride: UInt32)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let buf = unsafe Handle.get(buffer, BufferObject.self),
    let count = unsafe Handle.get(countBuffer, BufferObject.self), let place = buf.place, let counts = count.place
  else { return }
  guard let ix = b.index else {
    b.fail(VK_ERROR_UNKNOWN, "an indexed draw with no index buffer bound")
    return
  }
  guard let d = b.prepareDraw() else { return }
  b.list.drawIndexedIndirectCount(d.pipeline, root: d.root, indices: ix.memory, indexOffset: ix.offset, indexType: ix.type,
                                  arguments: place.memory, offset: place.offset + Int(offset), countBuffer: counts.memory,
                                  countOffset: counts.offset + Int(countBufferOffset), maxDrawCount: maxDrawCount, stride: max(stride, 20))
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

// MARK: Buffer copies

func copyBuffer(_ b: CommandBufferObject, _ src: BufferObject?, _ dst: BufferObject?, _ regions: [(UInt64, UInt64, UInt64)]) {
  guard let s = src, let d = dst, let from = s.place, let to = d.place else { return }
  for r in regions {
    b.list.copy(from.memory, fromOffset: from.offset + Int(r.0), to: to.memory, toOffset: to.offset + Int(r.1), bytes: Int(r.2))
  }
}

func core_vkCmdCopyBuffer(_ commandBuffer: VkCommandBuffer?, _ srcBuffer: VkBuffer?, _ dstBuffer: VkBuffer?, _ regionCount: UInt32,
                          _ pRegions: UnsafePointer<VkBufferCopy>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  var regions: [(UInt64, UInt64, UInt64)] = []
  for i in 0..<Int(regionCount) {
    let r = unsafe pRegions![i]
    regions.append((r.srcOffset, r.dstOffset, r.size))
  }
  copyBuffer(b, unsafe Handle.get(srcBuffer, BufferObject.self), unsafe Handle.get(dstBuffer, BufferObject.self), regions)
}

func core_vkCmdCopyBuffer2(_ commandBuffer: VkCommandBuffer?, _ pCopyBufferInfo: UnsafePointer<VkCopyBufferInfo2>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pCopyBufferInfo else { return }
  var regions: [(UInt64, UInt64, UInt64)] = []
  for i in 0..<Int(unsafe info.pointee.regionCount) {
    let r = unsafe info.pointee.pRegions[i]
    regions.append(unsafe (r.srcOffset, r.dstOffset, r.size))
  }
  copyBuffer(b, unsafe Handle.get(info.pointee.srcBuffer, BufferObject.self), unsafe Handle.get(info.pointee.dstBuffer, BufferObject.self), regions)
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
  if b.device.features.updateBuffer, let to = d.place {
    var bytes = [UInt8](repeating: 0, count: Int(dataSize))
    for i in bytes.indices { bytes[i] = unsafe data.load(fromByteOffset: i, as: UInt8.self) }
    b.list.update(to.memory, offset: to.offset + Int(dstOffset), data: bytes)
    return
  }
  unsafe uploadToBuffer(b, d, dstOffset, Int(dataSize)) { p in unsafe p.copyMemory(from: data, byteCount: Int(dataSize)) }
}

func core_vkCmdFillBuffer(_ commandBuffer: VkCommandBuffer?, _ dstBuffer: VkBuffer?, _ dstOffset: VkDeviceSize, _ size: VkDeviceSize,
                          _ data: UInt32)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let d = unsafe Handle.get(dstBuffer, BufferObject.self) else { return }
  let bytes = Int(size == ~0 ? d.size - dstOffset : size) & ~3
  if b.device.features.fillBuffer, let to = d.place, bytes > 0 {
    b.list.fill(to.memory, offset: to.offset + Int(dstOffset), bytes: bytes, value: data)
    return
  }
  unsafe uploadToBuffer(b, d, dstOffset, bytes) { p in
    for i in 0..<(bytes / 4) { unsafe p.storeBytes(of: data, toByteOffset: i * 4, as: UInt32.self) }
  }
}

// MARK: Image copies

/// A Vulkan subresource's layers as the core's: a count of "all the rest" is the image's layers from the base.
func subresourceLayers(_ s: VkImageSubresourceLayers, _ image: GPUImage) -> ImageSubresourceLayers {
  let count = s.layerCount == ~0 ? (image.layers > s.baseArrayLayer ? image.layers - s.baseArrayLayer : 0) : s.layerCount
  return ImageSubresourceLayers(aspects: imageAspects(s.aspectMask), mip: s.mipLevel, baseLayer: s.baseArrayLayer, layerCount: count)
}

func subresourceRange(_ r: VkImageSubresourceRange, _ image: GPUImage) -> ImageSubresourceRange {
  let levels = r.levelCount == ~0 ? (image.mipLevels > r.baseMipLevel ? image.mipLevels - r.baseMipLevel : 0) : r.levelCount
  let layers = r.layerCount == ~0 ? (image.layers > r.baseArrayLayer ? image.layers - r.baseArrayLayer : 0) : r.layerCount
  return ImageSubresourceRange(aspects: imageAspects(r.aspectMask), baseMip: r.baseMipLevel, mipCount: levels, baseLayer: r.baseArrayLayer,
                               layerCount: layers)
}

func offset3D(_ o: VkOffset3D) -> Offset3D { Offset3D(x: o.x, y: o.y, z: o.z) }
func extent3D(_ e: VkExtent3D) -> Extent3D { Extent3D(width: e.width, height: e.height, depth: e.depth) }

func imageCopyRegion(_ r: VkImageCopy, _ src: GPUImage, _ dst: GPUImage) -> ImageCopyRegion {
  ImageCopyRegion(srcSubresource: subresourceLayers(r.srcSubresource, src), srcOffset: offset3D(r.srcOffset),
                  dstSubresource: subresourceLayers(r.dstSubresource, dst), dstOffset: offset3D(r.dstOffset), extent: extent3D(r.extent))
}

func imageBlitRegion(_ r: VkImageBlit, _ src: GPUImage, _ dst: GPUImage) -> ImageBlitRegion {
  ImageBlitRegion(srcSubresource: subresourceLayers(r.srcSubresource, src), srcMin: offset3D(r.srcOffsets.0), srcMax: offset3D(r.srcOffsets.1),
                  dstSubresource: subresourceLayers(r.dstSubresource, dst), dstMin: offset3D(r.dstOffsets.0), dstMax: offset3D(r.dstOffsets.1))
}

func imageResolveRegion(_ r: VkImageResolve, _ src: GPUImage, _ dst: GPUImage) -> ImageCopyRegion {
  ImageCopyRegion(srcSubresource: subresourceLayers(r.srcSubresource, src), srcOffset: offset3D(r.srcOffset),
                  dstSubresource: subresourceLayers(r.dstSubresource, dst), dstOffset: offset3D(r.dstOffset), extent: extent3D(r.extent))
}

func core_vkCmdCopyImage(_ commandBuffer: VkCommandBuffer?, _ srcImage: VkImage?, _ srcImageLayout: VkImageLayout, _ dstImage: VkImage?,
                         _ dstImageLayout: VkImageLayout, _ regionCount: UInt32, _ pRegions: UnsafePointer<VkImageCopy>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let s = unsafe Handle.get(srcImage, ImageObject.self),
    let d = unsafe Handle.get(dstImage, ImageObject.self)
  else { return }
  var regions: [ImageCopyRegion] = []
  for i in 0..<Int(regionCount) { regions.append(unsafe imageCopyRegion(pRegions![i], s.image, d.image)) }
  b.list.copyImage(s.image, to: d.image, regions: regions)
}

func core_vkCmdCopyImage2(_ commandBuffer: VkCommandBuffer?, _ pCopyImageInfo: UnsafePointer<VkCopyImageInfo2>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pCopyImageInfo,
    let s = unsafe Handle.get(info.pointee.srcImage, ImageObject.self), let d = unsafe Handle.get(info.pointee.dstImage, ImageObject.self)
  else { return }
  var regions: [ImageCopyRegion] = []
  for i in 0..<Int(unsafe info.pointee.regionCount) {
    let r = unsafe info.pointee.pRegions[i]
    regions.append(unsafe imageCopyRegion(VkImageCopy(srcSubresource: r.srcSubresource, srcOffset: r.srcOffset, dstSubresource: r.dstSubresource,
                                               dstOffset: r.dstOffset, extent: r.extent), s.image, d.image))
  }
  b.list.copyImage(s.image, to: d.image, regions: regions)
}

func filter(_ f: VkFilter) -> SamplerFilter { f == VK_FILTER_NEAREST ? .nearest : .linear }

func core_vkCmdBlitImage(_ commandBuffer: VkCommandBuffer?, _ srcImage: VkImage?, _ srcImageLayout: VkImageLayout, _ dstImage: VkImage?,
                         _ dstImageLayout: VkImageLayout, _ regionCount: UInt32, _ pRegions: UnsafePointer<VkImageBlit>?, _ f: VkFilter)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let s = unsafe Handle.get(srcImage, ImageObject.self),
    let d = unsafe Handle.get(dstImage, ImageObject.self)
  else { return }
  var regions: [ImageBlitRegion] = []
  for i in 0..<Int(regionCount) { regions.append(unsafe imageBlitRegion(pRegions![i], s.image, d.image)) }
  b.list.blitImage(s.image, to: d.image, regions: regions, filter: filter(f))
}

func core_vkCmdBlitImage2(_ commandBuffer: VkCommandBuffer?, _ pBlitImageInfo: UnsafePointer<VkBlitImageInfo2>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pBlitImageInfo,
    let s = unsafe Handle.get(info.pointee.srcImage, ImageObject.self), let d = unsafe Handle.get(info.pointee.dstImage, ImageObject.self)
  else { return }
  var regions: [ImageBlitRegion] = []
  for i in 0..<Int(unsafe info.pointee.regionCount) {
    let r = unsafe info.pointee.pRegions[i]
    regions.append(unsafe imageBlitRegion(VkImageBlit(srcSubresource: r.srcSubresource, srcOffsets: r.srcOffsets, dstSubresource: r.dstSubresource,
                                               dstOffsets: r.dstOffsets), s.image, d.image))
  }
  b.list.blitImage(s.image, to: d.image, regions: regions, filter: filter(unsafe info.pointee.filter))
}

func core_vkCmdResolveImage(_ commandBuffer: VkCommandBuffer?, _ srcImage: VkImage?, _ srcImageLayout: VkImageLayout, _ dstImage: VkImage?,
                            _ dstImageLayout: VkImageLayout, _ regionCount: UInt32, _ pRegions: UnsafePointer<VkImageResolve>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let s = unsafe Handle.get(srcImage, ImageObject.self),
    let d = unsafe Handle.get(dstImage, ImageObject.self)
  else { return }
  var regions: [ImageCopyRegion] = []
  for i in 0..<Int(regionCount) { regions.append(unsafe imageResolveRegion(pRegions![i], s.image, d.image)) }
  b.list.resolveImage(s.image, to: d.image, regions: regions)
}

func core_vkCmdResolveImage2(_ commandBuffer: VkCommandBuffer?, _ pResolveImageInfo: UnsafePointer<VkResolveImageInfo2>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pResolveImageInfo,
    let s = unsafe Handle.get(info.pointee.srcImage, ImageObject.self), let d = unsafe Handle.get(info.pointee.dstImage, ImageObject.self)
  else { return }
  var regions: [ImageCopyRegion] = []
  for i in 0..<Int(unsafe info.pointee.regionCount) {
    let r = unsafe info.pointee.pRegions[i]
    regions.append(unsafe imageResolveRegion(VkImageResolve(srcSubresource: r.srcSubresource, srcOffset: r.srcOffset, dstSubresource: r.dstSubresource,
                                                     dstOffset: r.dstOffset, extent: r.extent), s.image, d.image))
  }
  b.list.resolveImage(s.image, to: d.image, regions: regions)
}

/// Whether a buffer-image copy region is the whole image, packed tightly (what a device without region copies has).
func wholeImageRegion(_ r: VkBufferImageCopy, _ image: GPUImage) -> Bool {
  r.imageSubresource.aspectMask == VK_IMAGE_ASPECT_COLOR_BIT.rawValue && r.imageSubresource.mipLevel == 0
    && r.imageSubresource.baseArrayLayer == 0 && r.imageSubresource.layerCount == 1 && r.imageOffset.x == 0 && r.imageOffset.y == 0
    && r.imageOffset.z == 0 && r.imageExtent.width == UInt32(image.width) && r.imageExtent.height == UInt32(image.height)
    && r.imageExtent.depth == 1 && (r.bufferRowLength == 0 || r.bufferRowLength == UInt32(image.width))
    && (r.bufferImageHeight == 0 || r.bufferImageHeight == UInt32(image.height))
}

func bufferImageRegion(_ r: VkBufferImageCopy, base: Int, _ image: GPUImage) -> BufferImageRegion {
  BufferImageRegion(bufferOffset: base + Int(r.bufferOffset), bufferRowLength: r.bufferRowLength, bufferImageHeight: r.bufferImageHeight,
                    subresource: subresourceLayers(r.imageSubresource, image), imageOffset: offset3D(r.imageOffset),
                    imageExtent: extent3D(r.imageExtent))
}

/// Buffer to image: the core's region copy where the device has them, else the whole-image copy it has always had.
func copyToImage(_ b: CommandBufferObject, _ src: BufferObject?, _ dst: ImageObject?, _ regions: [VkBufferImageCopy]) {
  guard let s = src, let i = dst, let from = s.place else { return }
  if b.device.features.imageRegionCopies {
    b.list.copy(from.memory, to: i.image, regions: regions.map { bufferImageRegion($0, base: from.offset, i.image) })
    return
  }
  for r in regions {
    guard wholeImageRegion(r, i.image) else {
      b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "a copy of part of an image")
      return
    }
    b.list.copy(from.memory, offset: from.offset + Int(r.bufferOffset), to: i.image)
  }
}

func copyFromImage(_ b: CommandBufferObject, _ src: ImageObject?, _ dst: BufferObject?, _ regions: [VkBufferImageCopy]) {
  guard let i = src, let d = dst, let to = d.place else { return }
  if b.device.features.imageRegionCopies {
    b.list.copy(i.image, to: to.memory, regions: regions.map { bufferImageRegion($0, base: to.offset, i.image) })
    return
  }
  for r in regions {
    guard wholeImageRegion(r, i.image) else {
      b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "a copy of part of an image")
      return
    }
    b.list.copy(i.image, to: to.memory, offset: to.offset + Int(r.bufferOffset))
  }
}

func core_vkCmdCopyBufferToImage(_ commandBuffer: VkCommandBuffer?, _ srcBuffer: VkBuffer?, _ dstImage: VkImage?,
                                 _ dstImageLayout: VkImageLayout, _ regionCount: UInt32, _ pRegions: UnsafePointer<VkBufferImageCopy>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  var regions: [VkBufferImageCopy] = []
  for k in 0..<Int(regionCount) { regions.append(unsafe pRegions![k]) }
  copyToImage(b, unsafe Handle.get(srcBuffer, BufferObject.self), unsafe Handle.get(dstImage, ImageObject.self), regions)
}

func core_vkCmdCopyImageToBuffer(_ commandBuffer: VkCommandBuffer?, _ srcImage: VkImage?, _ srcImageLayout: VkImageLayout,
                                 _ dstBuffer: VkBuffer?, _ regionCount: UInt32, _ pRegions: UnsafePointer<VkBufferImageCopy>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  var regions: [VkBufferImageCopy] = []
  for k in 0..<Int(regionCount) { regions.append(unsafe pRegions![k]) }
  copyFromImage(b, unsafe Handle.get(srcImage, ImageObject.self), unsafe Handle.get(dstBuffer, BufferObject.self), regions)
}

private func plainRegion(_ r: VkBufferImageCopy2) -> VkBufferImageCopy {
  unsafe VkBufferImageCopy(bufferOffset: r.bufferOffset, bufferRowLength: r.bufferRowLength, bufferImageHeight: r.bufferImageHeight,
                    imageSubresource: r.imageSubresource, imageOffset: r.imageOffset, imageExtent: r.imageExtent)
}

func core_vkCmdCopyBufferToImage2(_ commandBuffer: VkCommandBuffer?, _ pCopyBufferToImageInfo: UnsafePointer<VkCopyBufferToImageInfo2>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pCopyBufferToImageInfo else { return }
  var regions: [VkBufferImageCopy] = []
  for k in 0..<Int(unsafe info.pointee.regionCount) { regions.append(unsafe plainRegion(info.pointee.pRegions[k])) }
  copyToImage(b, unsafe Handle.get(info.pointee.srcBuffer, BufferObject.self), unsafe Handle.get(info.pointee.dstImage, ImageObject.self), regions)
}

func core_vkCmdCopyImageToBuffer2(_ commandBuffer: VkCommandBuffer?, _ pCopyImageToBufferInfo: UnsafePointer<VkCopyImageToBufferInfo2>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pCopyImageToBufferInfo else { return }
  var regions: [VkBufferImageCopy] = []
  for k in 0..<Int(unsafe info.pointee.regionCount) { regions.append(unsafe plainRegion(info.pointee.pRegions[k])) }
  copyFromImage(b, unsafe Handle.get(info.pointee.srcImage, ImageObject.self), unsafe Handle.get(info.pointee.dstBuffer, BufferObject.self), regions)
}

// MARK: Clears

/// The value a clear writes into a format, as its channels are read: floats, unsigned or signed integers.
func clearColor(_ v: VkClearColorValue, _ format: PixelFormat) -> ClearColor {
  switch format.channelClass {
  case .float:
    let c = unsafe v.float32
    return .float(c.0, c.1, c.2, c.3)
  case .uint:
    let c = unsafe v.uint32
    return .uint(c.0, c.1, c.2, c.3)
  case .sint:
    let c = unsafe v.int32
    return .sint(c.0, c.1, c.2, c.3)
  }
}

func core_vkCmdClearColorImage(_ commandBuffer: VkCommandBuffer?, _ image: VkImage?, _ imageLayout: VkImageLayout,
                               _ pColor: UnsafePointer<VkClearColorValue>?, _ rangeCount: UInt32,
                               _ pRanges: UnsafePointer<VkImageSubresourceRange>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let i = unsafe Handle.get(image, ImageObject.self),
    let color = unsafe pColor
  else { return }
  var ranges: [ImageSubresourceRange] = []
  for k in 0..<Int(rangeCount) { ranges.append(unsafe subresourceRange(pRanges![k], i.image)) }
  if b.device.features.clearImage {
    b.list.clear(i.image, color: unsafe clearColor(color.pointee, i.image.format), ranges: ranges)
    return
  }
  // A device without clears has a pass that clears and draws nothing, for the whole of a one-level, one-layer image.
  for r in ranges where r.baseMip != 0 || r.baseLayer != 0 || r.mipCount != 1 || r.layerCount != 1 {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "a clear of part of an image")
    return
  }
  guard i.image.usage.contains(.renderTarget) else {
    b.fail(VK_ERROR_FEATURE_NOT_PRESENT, "a clear of an image that can't be drawn into")
    return
  }
  let c = unsafe color.pointee.float32
  b.list.render(RenderingInfo(colors: [Attachment(image: i.image, load: .clear(c.0, c.1, c.2, c.3), store: .store)])) { _ in }
}

func core_vkCmdClearDepthStencilImage(_ commandBuffer: VkCommandBuffer?, _ image: VkImage?, _ imageLayout: VkImageLayout,
                                      _ pDepthStencil: UnsafePointer<VkClearDepthStencilValue>?, _ rangeCount: UInt32,
                                      _ pRanges: UnsafePointer<VkImageSubresourceRange>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let i = unsafe Handle.get(image, ImageObject.self),
    let v = unsafe pDepthStencil
  else { return }
  var ranges: [ImageSubresourceRange] = []
  for k in 0..<Int(rangeCount) { ranges.append(unsafe subresourceRange(pRanges![k], i.image)) }
  b.list.clear(i.image, depth: unsafe v.pointee.depth, stencil: unsafe v.pointee.stencil, ranges: ranges)
}

func core_vkCmdClearAttachments(_ commandBuffer: VkCommandBuffer?, _ attachmentCount: UInt32, _ pAttachments: UnsafePointer<VkClearAttachment>?,
                                _ rectCount: UInt32, _ pRects: UnsafePointer<VkClearRect>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  var attachments: [ClearAttachment] = []
  for k in 0..<Int(attachmentCount) {
    let a = unsafe pAttachments![k]
    if a.aspectMask & VK_IMAGE_ASPECT_COLOR_BIT.rawValue != 0 {
      let index = Int(a.colorAttachment)
      guard index < b.passColorFormats.count else {
        b.fail(VK_ERROR_UNKNOWN, "a clear of a colour attachment the pass doesn't have")
        return
      }
      attachments.append(.color(index: index, unsafe clearColor(a.clearValue.color, b.passColorFormats[index])))
    } else {
      let aspects = imageAspects(a.aspectMask)
      attachments.append(.depthStencil(aspects: aspects, depth: unsafe a.clearValue.depthStencil.depth, stencil: unsafe a.clearValue.depthStencil.stencil))
    }
  }
  var rects: [ClearRect] = []
  for k in 0..<Int(rectCount) {
    let r = unsafe pRects![k]
    rects.append(ClearRect(x: r.rect.offset.x, y: r.rect.offset.y, width: r.rect.extent.width, height: r.rect.extent.height,
                           baseLayer: r.baseArrayLayer, layerCount: r.layerCount))
  }
  b.list.clearAttachments(attachments, rects: rects)
}

// MARK: Barriers, events and queries

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

/// A barrier that names an image's subresources, outside a pass.
func emitImageBarrier(_ b: CommandBufferObject, from: UInt64, to: UInt64, _ image: VkImage?, _ range: VkImageSubresourceRange) {
  if b.inPass { return }
  guard let i = unsafe Handle.get(image, ImageObject.self) else { return }
  b.list.barrier(image: i.image, range: subresourceRange(range, i.image), from: stages(from), to: stages(to))
}

func core_vkCmdPipelineBarrier(_ commandBuffer: VkCommandBuffer?, _ srcStageMask: VkPipelineStageFlags, _ dstStageMask: VkPipelineStageFlags,
                               _ dependencyFlags: VkDependencyFlags, _ memoryBarrierCount: UInt32,
                               _ pMemoryBarriers: UnsafePointer<VkMemoryBarrier>?, _ bufferMemoryBarrierCount: UInt32,
                               _ pBufferMemoryBarriers: UnsafePointer<VkBufferMemoryBarrier>?, _ imageMemoryBarrierCount: UInt32,
                               _ pImageMemoryBarriers: UnsafePointer<VkImageMemoryBarrier>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  emitBarrier(b, from: UInt64(srcStageMask), to: UInt64(dstStageMask))
  for i in 0..<Int(imageMemoryBarrierCount) {
    let m = unsafe pImageMemoryBarriers![i]
    unsafe emitImageBarrier(b, from: UInt64(srcStageMask), to: UInt64(dstStageMask), m.image, m.subresourceRange)
  }
}

/// A dependency's stages, and each image barrier it names.
func emitDependency(_ b: CommandBufferObject, _ info: UnsafePointer<VkDependencyInfo>) {
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
  for i in 0..<Int(unsafe info.pointee.imageMemoryBarrierCount) {
    let m = unsafe info.pointee.pImageMemoryBarriers[i]
    unsafe emitImageBarrier(b, from: m.srcStageMask, to: m.dstStageMask, m.image, m.subresourceRange)
  }
}

func core_vkCmdPipelineBarrier2(_ commandBuffer: VkCommandBuffer?, _ pDependencyInfo: UnsafePointer<VkDependencyInfo>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let info = unsafe pDependencyInfo else { return }
  unsafe emitDependency(b, info)
}

final class EventObject: CoreObject {
  var isSet = false
}

func core_vkCreateEvent(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkEventCreateInfo>?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                        _ pEvent: UnsafeMutablePointer<VkEvent?>?) -> VkResult
{
  guard let out = unsafe pEvent else { return VK_ERROR_INITIALIZATION_FAILED }
  unsafe out.pointee = Handle.make(EventObject())
  return VK_SUCCESS
}

func core_vkDestroyEvent(_ device: VkDevice?, _ event: VkEvent?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(event)
}

func core_vkGetEventStatus(_ device: VkDevice?, _ event: VkEvent?) -> VkResult {
  guard let e = unsafe Handle.get(event, EventObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  return e.isSet ? VK_EVENT_SET : VK_EVENT_RESET
}

func core_vkSetEvent(_ device: VkDevice?, _ event: VkEvent?) -> VkResult {
  guard let e = unsafe Handle.get(event, EventObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  e.isSet = true
  return VK_SUCCESS
}

func core_vkResetEvent(_ device: VkDevice?, _ event: VkEvent?) -> VkResult {
  guard let e = unsafe Handle.get(event, EventObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
  e.isSet = false
  return VK_SUCCESS
}

/// The core runs a list in order, so an event is set when the submission that sets it is made, and waiting for one is the
/// barrier of its stages.
func core_vkCmdSetEvent(_ commandBuffer: VkCommandBuffer?, _ event: VkEvent?, _ stageMask: VkPipelineStageFlags) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let e = unsafe Handle.get(event, EventObject.self) else { return }
  b.eventWrites.append((e, true))
}

func core_vkCmdResetEvent(_ commandBuffer: VkCommandBuffer?, _ event: VkEvent?, _ stageMask: VkPipelineStageFlags) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let e = unsafe Handle.get(event, EventObject.self) else { return }
  b.eventWrites.append((e, false))
}

func core_vkCmdSetEvent2(_ commandBuffer: VkCommandBuffer?, _ event: VkEvent?, _ pDependencyInfo: UnsafePointer<VkDependencyInfo>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let e = unsafe Handle.get(event, EventObject.self) else { return }
  b.eventWrites.append((e, true))
}

func core_vkCmdResetEvent2(_ commandBuffer: VkCommandBuffer?, _ event: VkEvent?, _ stageMask: VkPipelineStageFlags2) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let e = unsafe Handle.get(event, EventObject.self) else { return }
  b.eventWrites.append((e, false))
}

func core_vkCmdWaitEvents(_ commandBuffer: VkCommandBuffer?, _ eventCount: UInt32, _ pEvents: UnsafePointer<VkEvent?>?,
                          _ srcStageMask: VkPipelineStageFlags, _ dstStageMask: VkPipelineStageFlags, _ memoryBarrierCount: UInt32,
                          _ pMemoryBarriers: UnsafePointer<VkMemoryBarrier>?, _ bufferMemoryBarrierCount: UInt32,
                          _ pBufferMemoryBarriers: UnsafePointer<VkBufferMemoryBarrier>?, _ imageMemoryBarrierCount: UInt32,
                          _ pImageMemoryBarriers: UnsafePointer<VkImageMemoryBarrier>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  emitBarrier(b, from: UInt64(srcStageMask), to: UInt64(dstStageMask))
  for i in 0..<Int(imageMemoryBarrierCount) {
    let m = unsafe pImageMemoryBarriers![i]
    unsafe emitImageBarrier(b, from: UInt64(srcStageMask), to: UInt64(dstStageMask), m.image, m.subresourceRange)
  }
}

func core_vkCmdWaitEvents2(_ commandBuffer: VkCommandBuffer?, _ eventCount: UInt32, _ pEvents: UnsafePointer<VkEvent?>?,
                           _ pDependencyInfos: UnsafePointer<VkDependencyInfo>?)
{
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self), let infos = unsafe pDependencyInfos else { return }
  for i in 0..<Int(eventCount) { unsafe emitDependency(b, infos + i) }
}

func core_vkCmdExecuteCommands(_ commandBuffer: VkCommandBuffer?, _ commandBufferCount: UInt32, _ pCommandBuffers: UnsafePointer<VkCommandBuffer?>?) {
  guard let b = unsafe Handle.get(commandBuffer, CommandBufferObject.self) else { return }
  for i in 0..<Int(commandBufferCount) {
    guard let s = unsafe Handle.get(pCommandBuffers![i], CommandBufferObject.self) else { continue }
    if let e = s.error {
      b.fail(e, "a secondary command buffer that failed")
      continue
    }
    b.list.append(contentsOf: s.list)
    b.executed.append(s)
    b.eventWrites.append(contentsOf: s.eventWrites)
  }
  // What a secondary buffer sets is not what this one's state says the core has.
  b.sent = DynamicValues()
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
  } else if unsafe info.pointee.queryType == VK_QUERY_TYPE_PIPELINE_STATISTICS {
    // The counters' bits are the core's.
    kind = unsafe .pipelineStatistics(PipelineStatistics(rawValue: info.pointee.pipelineStatistics))
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
    // A pipeline-statistics query has one value for each counter it counts.
    var per = 1
    if case .pipelineStatistics(let s) = q.set.kind { per = max(s.count, 1) }
    let width = wide ? 8 : 4
    for i in 0..<Int(queryCount) {
      let at = unsafe out + i * Int(stride)
      for k in 0..<per {
        let v = i * per + k < values.count ? values[i * per + k] : 0
        if wide { unsafe at.storeBytes(of: v, toByteOffset: k * width, as: UInt64.self) } else {
          unsafe at.storeBytes(of: UInt32(truncatingIfNeeded: v), toByteOffset: k * width, as: UInt32.self)
        }
      }
      if availability {
        if wide { unsafe at.storeBytes(of: 1, toByteOffset: per * width, as: UInt64.self) } else {
          unsafe at.storeBytes(of: 1, toByteOffset: per * width, as: UInt32.self)
        }
      }
    }
  } catch { return vkResult(error) }
  return VK_SUCCESS
}
