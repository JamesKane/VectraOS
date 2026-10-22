// SPDX-License-Identifier: BSD-3-Clause

// Loinnir (sdk.md §5): the SDK's GPU library over Vulkan, in the "No
// Graphics API" style. One device and queue, one bindless texture heap,
// one pipeline layout (the heap plus a root pointer per draw), memory by
// GPU address, and a 64-bit timeline for every submission.
//
//   let gpu = try Loinnir.open(window: win, loop: &loop)
//   let verts = try gpu.alloc(.upload, bytes: 64 << 10)
//   let pso = try gpu.pipeline(vertex: vs, fragment: fs, target: .bgra8)
//   if let target = try gpu.frame(&loop, config) {
//     var cmd = try gpu.commands()
//     cmd.render(to: target, clear: (0, 0, 0, 1)) { r in r.draw(pso, root: verts.address, vertices: 3) }
//     try gpu.present(&loop, config, after: try gpu.submit(cmd))
//   }


@safe public final class Loinnir {
  public let gpu: GPUContext
  let heap: Heap
  let pipelineLayout: VkPipelineLayout
  let timeline: VkSemaphore
  public private(set) var timelineValue: UInt64 = 0
  var allocations: [GPUAllocation] = []
  var textures = TextureTable()
  var pipelines: [VkPipeline] = unsafe []
  var pending: [(value: UInt64, commands: VkCommandBuffer)] = unsafe []
  /// Freed resources, destroyed once the timeline passes their value.
  var retired: [(value: UInt64, thing: Retired)] = []

  /// How frames reach a window, if there is one (the backend's:
  /// hosted/Present.swift on Linux).
  var presentation: (any LoinnirPresentation)?

  /// A GPU with no window, for offscreen work and tests.
  public static func headless() throws(LoinnirError) -> Loinnir {
    try Loinnir(gpu: try GPUContext())
  }

  init(gpu: GPUContext) throws(LoinnirError) {
    self.gpu = gpu
    let c = gpu.vk.commands
    heap = try Heap(gpu)

    // The one pipeline layout: the heap, and 16 bytes of push constants
    // (the root pointer, and 8 bytes spare).
    var range = VkPushConstantRange(stageFlags: VK_SHADER_STAGE_ALL.rawValue, offset: 0, size: 16)
    var setLayout: VkDescriptorSetLayout? = unsafe heap.layout
    var layout: VkPipelineLayout?
    let r: VkResult = withUnsafePointer(to: &setLayout) { lp in
      withUnsafePointer(to: &range) { rp in
        var info = unsafe VkPipelineLayoutCreateInfo()
        unsafe info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        unsafe info.setLayoutCount = 1
        unsafe info.pSetLayouts = unsafe lp
        unsafe info.pushConstantRangeCount = 1
        unsafe info.pPushConstantRanges = unsafe rp
        return unsafe c.vkCreatePipelineLayout!(gpu.device, &info, nil, &layout)
      }
    }
    try check(r, "vkCreatePipelineLayout")
    unsafe pipelineLayout = unsafe layout!

    // The timeline.
    var typeInfo = unsafe VkSemaphoreTypeCreateInfo()
    unsafe typeInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
    unsafe typeInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE
    var semaphore: VkSemaphore?
    let s: VkResult = withUnsafePointer(to: &typeInfo) { tp in
      var info = unsafe VkSemaphoreCreateInfo()
      unsafe info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
      unsafe info.pNext = unsafe UnsafeRawPointer(tp)
      return unsafe c.vkCreateSemaphore!(gpu.device, &info, nil, &semaphore)
    }
    try check(s, "vkCreateSemaphore (timeline)")
    unsafe timeline = unsafe semaphore!
  }

  deinit {
    let c = gpu.vk.commands
    _ = unsafe c.vkDeviceWaitIdle!(gpu.device)
    presentation = nil
    destroyRetired(UInt64.max)
    for unsafe (_, cb) in unsafe pending {
      var b: VkCommandBuffer? = unsafe cb
      unsafe c.vkFreeCommandBuffers!(gpu.device, gpu.commandPool, 1, &b)
    }
    for unsafe p in unsafe pipelines { unsafe c.vkDestroyPipeline!(gpu.device, p, nil) }
    for t in textures.all {
      unsafe c.vkDestroyImageView!(gpu.device, t.view, nil)
      unsafe c.vkDestroyImage!(gpu.device, t.image, nil)
      if let m = unsafe t.memory { unsafe c.vkFreeMemory!(gpu.device, m, nil) }
    }
    for a in allocations {
      unsafe c.vkDestroyBuffer!(gpu.device, a.buffer, nil)
      unsafe c.vkFreeMemory!(gpu.device, a.memory, nil)
    }
    unsafe c.vkDestroySemaphore!(gpu.device, timeline, nil)
    unsafe c.vkDestroyPipelineLayout!(gpu.device, pipelineLayout, nil)
    heap.destroy(gpu)
  }

  // MARK: Pipelines

  /// A graphics pipeline from SPIR-V: vertex and fragment shaders reading
  /// their inputs through the root pointer and the heap, drawing triangles
  /// into one color target with alpha blending.
  public func pipeline(vertex: [UInt8], fragment: [UInt8], target: TextureFormat) throws(LoinnirError) -> Pipeline {
    let c = gpu.vk.commands
    func module(_ code: [UInt8]) throws(LoinnirError) -> VkShaderModule {
      guard code.count % 4 == 0, code.count >= 20 else { throw .unsupported("not SPIR-V (\(code.count) bytes)") }
      var m: VkShaderModule?
      let r: VkResult = code.withUnsafeBytes { bytes in
        var info = unsafe VkShaderModuleCreateInfo()
        unsafe info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
        unsafe info.codeSize = code.count
        unsafe info.pCode = unsafe bytes.baseAddress!.assumingMemoryBound(to: UInt32.self)
        return unsafe c.vkCreateShaderModule!(gpu.device, &info, nil, &m)
      }
      try check(r, "vkCreateShaderModule")
      return unsafe m!
    }
    let vs = unsafe try module(vertex), fs = unsafe try module(fragment)
    defer {
      unsafe c.vkDestroyShaderModule!(gpu.device, vs, nil)
      unsafe c.vkDestroyShaderModule!(gpu.device, fs, nil)
    }
    var pipeline: VkPipeline?
    var format = target.vk
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
      unsafe assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
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
      var attachment = VkPipelineColorBlendAttachmentState()
      attachment.blendEnable = 1
      attachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA
      attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
      attachment.colorBlendOp = VK_BLEND_OP_ADD
      attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
      attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
      attachment.alphaBlendOp = VK_BLEND_OP_ADD
      attachment.colorWriteMask = 0xf
      var dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
      return withUnsafePointer(to: &attachment) { ap in
        var blend = unsafe VkPipelineColorBlendStateCreateInfo()
        unsafe blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        unsafe blend.attachmentCount = 1
        unsafe blend.pAttachments = unsafe ap
        return dynamicStates.withUnsafeMutableBufferPointer { dp in
          var dynamic = unsafe VkPipelineDynamicStateCreateInfo()
          unsafe dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
          unsafe dynamic.dynamicStateCount = 2
          unsafe dynamic.pDynamicStates = unsafe UnsafePointer(dp.baseAddress)
          return withUnsafePointer(to: &format) { fp in
            var rendering = unsafe VkPipelineRenderingCreateInfo()
            unsafe rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO
            unsafe rendering.colorAttachmentCount = 1
            unsafe rendering.pColorAttachmentFormats = unsafe fp
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
                              unsafe info.layout = unsafe pipelineLayout
                              return unsafe c.vkCreateGraphicsPipelines!(gpu.device, nil, 1, &info, nil, &pipeline)
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
    try check(r, "vkCreateGraphicsPipelines")
    unsafe pipelines.append(pipeline!)
    return unsafe Pipeline(pipeline: pipeline!)
  }

  // MARK: Commands and the timeline

  /// A command list to record into.
  public func commands() throws(LoinnirError) -> CommandList {
    reclaim()
    let c = gpu.vk.commands
    var info = unsafe VkCommandBufferAllocateInfo()
    unsafe info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    unsafe info.commandPool = unsafe gpu.commandPool
    unsafe info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
    unsafe info.commandBufferCount = 1
    var cb: VkCommandBuffer?
    unsafe try check(c.vkAllocateCommandBuffers!(gpu.device, &info, &cb), "vkAllocateCommandBuffers")
    var begin = unsafe VkCommandBufferBeginInfo()
    unsafe begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    unsafe begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue
    _ = unsafe c.vkBeginCommandBuffer!(cb, &begin)
    var heapSet: VkDescriptorSet? = unsafe heap.set
    for point in [VK_PIPELINE_BIND_POINT_GRAPHICS, VK_PIPELINE_BIND_POINT_COMPUTE] {
      unsafe c.vkCmdBindDescriptorSets!(cb, point, pipelineLayout, 0, 1, &heapSet, 0, nil)
    }
    return unsafe CommandList(owner: self, cb: cb!)
  }

  /// Submits a recorded list. The GPU signals the returned timeline value
  /// when it's done.
  @discardableResult
  public func submit(_ list: consuming CommandList) throws(LoinnirError) -> UInt64 {
    let c = gpu.vk.commands
    let cb = unsafe list.cb
    _ = unsafe c.vkEndCommandBuffer!(cb)
    timelineValue += 1
    var value = timelineValue
    var signal: VkSemaphore? = unsafe timeline
    var buffer: VkCommandBuffer? = unsafe cb
    let r: VkResult = withUnsafePointer(to: &value) { vp in
      var timelineInfo = unsafe VkTimelineSemaphoreSubmitInfo()
      unsafe timelineInfo.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO
      unsafe timelineInfo.signalSemaphoreValueCount = 1
      unsafe timelineInfo.pSignalSemaphoreValues = unsafe vp
      return withUnsafePointer(to: &timelineInfo) { tp in
        withUnsafePointer(to: &signal) { sp in
          withUnsafePointer(to: &buffer) { bp in
            var submit = unsafe VkSubmitInfo()
            unsafe submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
            unsafe submit.pNext = unsafe UnsafeRawPointer(tp)
            unsafe submit.commandBufferCount = 1
            unsafe submit.pCommandBuffers = unsafe bp
            unsafe submit.signalSemaphoreCount = 1
            unsafe submit.pSignalSemaphores = unsafe sp
            return unsafe c.vkQueueSubmit!(gpu.queue, 1, &submit, nil)
          }
        }
      }
    }
    try check(r, "vkQueueSubmit")
    unsafe pending.append((timelineValue, cb))
    return timelineValue
  }

  /// Waits until the GPU has reached `value` on the timeline.
  public func wait(_ value: UInt64) throws(LoinnirError) {
    let c = gpu.vk.commands
    var semaphore: VkSemaphore? = unsafe timeline
    var v = value
    let r: VkResult = withUnsafePointer(to: &semaphore) { sp in
      withUnsafePointer(to: &v) { vp in
        var info = unsafe VkSemaphoreWaitInfo()
        unsafe info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO
        unsafe info.semaphoreCount = 1
        unsafe info.pSemaphores = unsafe sp
        unsafe info.pValues = unsafe vp
        return unsafe c.vkWaitSemaphores!(gpu.device, &info, UInt64.max)
      }
    }
    try check(r, "vkWaitSemaphores")
    reclaim()
  }

  /// The timeline value the GPU has finished.
  public var completed: UInt64 {
    var v: UInt64 = 0
    _ = unsafe gpu.vk.commands.vkGetSemaphoreCounterValue!(gpu.device, timeline, &v)
    return v
  }

  /// Frees command buffers the GPU is done with.
  func reclaim() {
    let done = completed
    destroyRetired(done)
    let c = gpu.vk.commands
    unsafe pending.removeAll { p in
      guard unsafe p.value <= done else { return false }
      var b: VkCommandBuffer? = unsafe p.commands
      unsafe c.vkFreeCommandBuffers!(gpu.device, gpu.commandPool, 1, &b)
      return true
    }
  }
}

/// Something freed, until the GPU is done with it.
enum Retired {
  case texture(ImageRecord, UInt32)
  case allocation(GPUAllocation)
}

/// A window's presentation, as a backend does it.
protocol LoinnirPresentation: AnyObject {}

/// The textures, by heap index (an array: tier 0 has no hashed collections).
struct TextureTable {
  var records: [ImageRecord?] = []
  subscript(index: UInt32) -> ImageRecord? {
    get { Int(index) < records.count ? records[Int(index)] : nil }
    set {
      while records.count <= Int(index) { records.append(nil) }
      records[Int(index)] = newValue
    }
  }
  var all: [ImageRecord] { records.compactMap { $0 } }
}

/// A compiled pipeline.
@safe public struct Pipeline: @unchecked Sendable {
  let pipeline: VkPipeline
}

/// What a render pass draws into.
public enum RenderTarget {
  case texture(Texture)
  /// The window's image for this frame (from `frame`).
  case backbuffer(ImageRecord)
}
