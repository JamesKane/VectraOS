// SPDX-License-Identifier: BSD-3-Clause

// What the layer's tests stand on: a fake core device whose submissions can be inspected and whose timeline the
// test moves, and `VK`, a small application that reaches the layer the way the loader does, through its
// vkGetInstanceProcAddr.

import GPUCore
import TDVulkan
@testable import VulkanCoreDriver
import VulkanLowering

/// A core device that runs nothing: memory is host memory whose address is the pointer's, a submission is checked
/// against the core's rules and kept, and the timeline reaches a value when the test says (or at once).
final class FakeGPU: GPUDevice {
  let name = "fake gpu"
  let backend = "fake"
  var limits: DeviceLimits
  var rule = TimelineRule()
  var reached: UInt64 = 0
  /// Whether a submission completes as it is made.
  var autoComplete = true
  var submitted: [(list: GPUCommandList, wait: UInt64, signal: UInt64)] = []
  var allocations: [GPUMemory] = []
  var freedMemory: [UInt64] = []
  var nextHandle: UInt64 = 1
  var textures: [UInt32: GPUImage] = [:]
  var samplers: [UInt32: SamplerDescriptor] = [:]
  var storageImages: [UInt32: GPUImage] = [:]
  var images: [GPUImage] = []
  var destroyedImages: [UInt64] = []
  var graphicsPipelines: [GraphicsPipelineDescriptor] = []
  var computePipelines: [[UInt8]] = []
  var querySets: [GPUQuerySet] = []
  var queue: FakeQueue!

  init(features: DeviceFeatures? = nil) {
    var l = DeviceLimits()
    if let features { l.features = features } else {
      l.features.indexedDraw = true
      l.features.indirectDraw = true
      l.features.indirectDispatch = true
      l.features.sampledImages = true
      l.features.storageImages = true
      l.features.timestampQueries = true
      l.features.occlusionQueries = true
      l.features.loadAttachments = true
      l.features.multipleDrawsPerPass = true
    }
    l.heapTextures = 8
    l.heapSamplers = 4
    l.heapStorageImages = 4
    l.maxImageDimension = 4096
    l.timestampPeriodPicoseconds = 40_000
    limits = l
    queue = FakeQueue(self)
  }

  var graphicsQueue: any GPUQueue { queue }
  var computeQueue: (any GPUQueue)? { nil }

  func handle() -> UInt64 {
    defer { nextHandle += 1 }
    return nextHandle
  }

  func allocate(_ intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory {
    guard bytes > 0 else { throw .invalid("an allocation of no bytes") }
    let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
    p.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    let m = unsafe GPUMemory(handle: handle(), address: UInt64(UInt(bitPattern: p)), pointer: intent == .device ? nil : p,
                             size: bytes, intent: intent)
    allocations.append(m)
    return m
  }

  func free(_ memory: GPUMemory) { freedMemory.append(memory.handle) }

  func makeImage(_ d: ImageDescriptor) throws(GPUError) -> GPUImage {
    guard d.width > 0, d.height > 0, d.width <= limits.maxImageDimension, d.height <= limits.maxImageDimension else {
      throw .unsupported("an image of \(d.width) x \(d.height)")
    }
    let i = GPUImage(handle: handle(), descriptor: d)
    images.append(i)
    return i
  }

  func destroy(_ image: GPUImage) { destroyedImages.append(image.handle) }

  func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    guard index < limits.heapTextures else { throw .invalid("texture slot \(index)") }
    textures[index] = image
  }

  func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {
    guard index < limits.heapSamplers else { throw .invalid("sampler slot \(index)") }
    samplers[index] = sampler
  }

  func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) {
    guard index < limits.heapStorageImages else { throw .invalid("storage slot \(index)") }
    storageImages[index] = image
  }

  func makeGraphicsPipeline(_ d: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline {
    graphicsPipelines.append(d)
    return GPUPipeline(handle: handle(), kind: .graphics)
  }

  func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline {
    computePipelines.append(spirv)
    return GPUPipeline(handle: handle(), kind: .compute)
  }

  func destroy(_ pipeline: GPUPipeline) {}

  func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet {
    let s = GPUQuerySet(handle: handle(), kind: kind, count: count)
    querySets.append(s)
    return s
  }

  func destroy(_ set: GPUQuerySet) {}

  var queryResults: [UInt64] = []
  func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64] {
    (0..<count).map { first + $0 < queryResults.count ? queryResults[first + $0] : 0 }
  }

  var completed: UInt64 { reached }

  /// A wait runs the timeline up to the value, as a real device's wait would, but only to a value it has signalled.
  func wait(_ value: UInt64) throws(GPUError) {
    guard value <= rule.lastSignalled else { throw .invalid("a wait for \(value), which nothing has signalled") }
    reached = max(reached, value)
  }

  func finish(_ value: UInt64) { reached = max(reached, value) }

  /// Bytes of GPU memory at `address`, which is host memory here.
  func read<T>(_ address: UInt64, as type: T.Type = T.self) -> T {
    UnsafeRawPointer(bitPattern: UInt(address))!.loadUnaligned(as: T.self)
  }

  func bytes(_ address: UInt64, count: Int) -> [UInt8] {
    let p = UnsafeRawPointer(bitPattern: UInt(address))!
    return (0..<count).map { p.load(fromByteOffset: $0, as: UInt8.self) }
  }

  /// The allocation that holds `address`.
  func allocation(holding address: UInt64) -> GPUMemory? {
    allocations.first { address >= $0.address && address < $0.address + UInt64($0.size) }
  }
}

final class FakeQueue: GPUQueue {
  unowned let device: FakeGPU
  var failNext: GPUError?
  init(_ device: FakeGPU) { self.device = device }
  func submit(_ list: GPUCommandList, wait: UInt64, signal: UInt64) throws(GPUError) {
    if let e = failNext {
      failNext = nil
      throw e
    }
    if let e = list.validate(features: device.limits.features) { throw e }
    if let e = device.rule.accept(wait: wait, signal: signal) { throw e }
    device.submitted.append((list, wait, signal))
    if device.autoComplete { device.reached = signal }
  }
}

nonisolated(unsafe) var loweredStages: [(stage: ShaderStage, entry: String, layout: LoweringLayout)] = []

/// SPIR-V as the fake takes it: a header and nothing else.
let someSpirv: [UInt32] = [0x0723_0203, 0x0001_0000, 0, 1, 0]

/// An application that reaches the layer the way the loader does.
final class VK {
  let gpu: FakeGPU
  var instance: VkInstance?
  var physical: VkPhysicalDevice?
  var device: VkDevice?
  var queue: VkQueue?
  var messages: [String] = []

  init(gpu: FakeGPU = FakeGPU()) {
    self.gpu = gpu
    CoreDriver.device = { gpu }
    CoreDriver.lowering = { (words, stage, entry, layout) throws(LoweringError) in
      loweredStages.append((stage, entry, layout))
      return words
    }
    loweredStages = []
    CoreDriver.message = { [unowned self] in messages.append($0) }
    var info = VkInstanceCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
    var r = fn("vkCreateInstance", PFN_vkCreateInstance.self)(&info, nil, &instance)
    precondition(r == VK_SUCCESS, "vkCreateInstance \(r)")
    var n: UInt32 = 1
    r = fn("vkEnumeratePhysicalDevices", PFN_vkEnumeratePhysicalDevices.self)(instance, &n, &physical)
    precondition(r == VK_SUCCESS && n == 1)
    var q = VkDeviceQueueCreateInfo()
    q.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    q.queueCount = 1
    var priority: Float = 1
    withUnsafePointer(to: &priority) { p in
      q.pQueuePriorities = p
      var d = VkDeviceCreateInfo()
      d.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
      d.queueCreateInfoCount = 1
      withUnsafePointer(to: &q) { qp in
        d.pQueueCreateInfos = qp
        r = fn("vkCreateDevice", PFN_vkCreateDevice.self)(physical, &d, nil, &device)
      }
    }
    precondition(r == VK_SUCCESS, "vkCreateDevice \(r)")
    fn("vkGetDeviceQueue", PFN_vkGetDeviceQueue.self)(device, 0, 0, &queue)
  }

  deinit {
    CoreDriver.device = nil
    CoreDriver.message = nil
  }

  /// A command by name, as the loader gets one from a driver.
  func fn<T>(_ name: String, _ type: T.Type) -> T {
    let p = name.withCString { coreGetInstanceProcAddr(instance, $0) }
    precondition(p != nil, "the layer has no \(name)")
    return unsafeBitCast(p!, to: T.self)
  }

  // MARK: Memory and buffers

  func allocate(_ type: UInt32, _ size: Int) -> VkDeviceMemory? {
    var info = VkMemoryAllocateInfo()
    info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    info.allocationSize = UInt64(size)
    info.memoryTypeIndex = type
    var m: VkDeviceMemory?
    let r = fn("vkAllocateMemory", PFN_vkAllocateMemory.self)(device, &info, nil, &m)
    precondition(r == VK_SUCCESS, "vkAllocateMemory \(r)")
    return m
  }

  func map(_ memory: VkDeviceMemory?) -> UnsafeMutableRawPointer {
    var p: UnsafeMutableRawPointer?
    let r = fn("vkMapMemory", PFN_vkMapMemory.self)(device, memory, 0, ~0, 0, &p)
    precondition(r == VK_SUCCESS, "vkMapMemory \(r)")
    return p!
  }

  func buffer(_ size: Int, usage: UInt32, in memory: VkDeviceMemory?, at offset: UInt64 = 0) -> VkBuffer? {
    var info = VkBufferCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    info.size = UInt64(size)
    info.usage = usage
    var b: VkBuffer?
    var r = fn("vkCreateBuffer", PFN_vkCreateBuffer.self)(device, &info, nil, &b)
    precondition(r == VK_SUCCESS, "vkCreateBuffer \(r)")
    r = fn("vkBindBufferMemory", PFN_vkBindBufferMemory.self)(device, b, memory, offset)
    precondition(r == VK_SUCCESS, "vkBindBufferMemory \(r)")
    return b
  }

  func address(of buffer: VkBuffer?) -> UInt64 {
    var info = VkBufferDeviceAddressInfo()
    info.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO
    info.buffer = buffer
    return fn("vkGetBufferDeviceAddress", PFN_vkGetBufferDeviceAddress.self)(device, &info)
  }

  // MARK: Images

  func image(_ format: VkFormat = VK_FORMAT_R8G8B8A8_UNORM, _ width: UInt32 = 4, _ height: UInt32 = 4, usage: UInt32) -> VkImage? {
    var info = VkImageCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    info.imageType = VK_IMAGE_TYPE_2D
    info.format = format
    info.extent = VkExtent3D(width: width, height: height, depth: 1)
    info.mipLevels = 1
    info.arrayLayers = 1
    info.samples = VK_SAMPLE_COUNT_1_BIT
    info.tiling = VK_IMAGE_TILING_OPTIMAL
    info.usage = usage
    var i: VkImage?
    let r = fn("vkCreateImage", PFN_vkCreateImage.self)(device, &info, nil, &i)
    precondition(r == VK_SUCCESS, "vkCreateImage \(r)")
    return i
  }

  func view(_ image: VkImage?, _ format: VkFormat = VK_FORMAT_R8G8B8A8_UNORM) -> VkImageView? {
    var info = VkImageViewCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    info.image = image
    info.viewType = VK_IMAGE_VIEW_TYPE_2D
    info.format = format
    info.subresourceRange = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0, levelCount: 1,
                                                    baseArrayLayer: 0, layerCount: 1)
    var v: VkImageView?
    let r = fn("vkCreateImageView", PFN_vkCreateImageView.self)(device, &info, nil, &v)
    precondition(r == VK_SUCCESS, "vkCreateImageView \(r)")
    return v
  }

  func sampler() -> VkSampler? {
    var info = VkSamplerCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    info.magFilter = VK_FILTER_NEAREST
    info.minFilter = VK_FILTER_NEAREST
    info.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT
    info.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT
    info.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT
    var s: VkSampler?
    let r = fn("vkCreateSampler", PFN_vkCreateSampler.self)(device, &info, nil, &s)
    precondition(r == VK_SUCCESS, "vkCreateSampler \(r)")
    return s
  }

  // MARK: Descriptors and pipelines

  func setLayout(_ bindings: [(UInt32, VkDescriptorType, UInt32)]) -> VkDescriptorSetLayout? {
    let b = bindings.map {
      VkDescriptorSetLayoutBinding(binding: $0.0, descriptorType: $0.1, descriptorCount: $0.2,
                                   stageFlags: VK_SHADER_STAGE_ALL.rawValue, pImmutableSamplers: nil)
    }
    var out: VkDescriptorSetLayout?
    b.withUnsafeBufferPointer { bp in
      var info = VkDescriptorSetLayoutCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
      info.bindingCount = UInt32(b.count)
      info.pBindings = bp.baseAddress
      let r = fn("vkCreateDescriptorSetLayout", PFN_vkCreateDescriptorSetLayout.self)(device, &info, nil, &out)
      precondition(r == VK_SUCCESS, "vkCreateDescriptorSetLayout \(r)")
    }
    return out
  }

  func pipelineLayout(_ sets: [VkDescriptorSetLayout?], push: UInt32 = 0) -> VkPipelineLayout? {
    var out: VkPipelineLayout?
    var range = VkPushConstantRange(stageFlags: VK_SHADER_STAGE_ALL.rawValue, offset: 0, size: push)
    sets.withUnsafeBufferPointer { sp in
      var info = VkPipelineLayoutCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
      info.setLayoutCount = UInt32(sets.count)
      info.pSetLayouts = sp.baseAddress
      withUnsafePointer(to: &range) { rp in
        info.pushConstantRangeCount = push > 0 ? 1 : 0
        info.pPushConstantRanges = push > 0 ? rp : nil
        let r = fn("vkCreatePipelineLayout", PFN_vkCreatePipelineLayout.self)(device, &info, nil, &out)
        precondition(r == VK_SUCCESS, "vkCreatePipelineLayout \(r)")
      }
    }
    return out
  }

  func shaderModule(_ words: [UInt32] = someSpirv) -> VkShaderModule? {
    var out: VkShaderModule?
    words.withUnsafeBufferPointer { wp in
      var info = VkShaderModuleCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
      info.codeSize = words.count * 4
      info.pCode = wp.baseAddress
      let r = fn("vkCreateShaderModule", PFN_vkCreateShaderModule.self)(device, &info, nil, &out)
      precondition(r == VK_SUCCESS, "vkCreateShaderModule \(r)")
    }
    return out
  }

  func computePipeline(_ layout: VkPipelineLayout?) -> (VkResult, VkPipeline?) {
    let module = shaderModule()
    var out: VkPipeline?
    var r = VK_SUCCESS
    "main".withCString { name in
      var info = VkComputePipelineCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
      info.stage = VkPipelineShaderStageCreateInfo(sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, pNext: nil, flags: 0,
                                                   stage: VK_SHADER_STAGE_COMPUTE_BIT, module: module, pName: name,
                                                   pSpecializationInfo: nil)
      info.layout = layout
      r = fn("vkCreateComputePipelines", PFN_vkCreateComputePipelines.self)(device, nil, 1, &info, nil, &out)
    }
    return (r, out)
  }

  func descriptorPool(sets: UInt32, sizes: [(VkDescriptorType, UInt32)], flags: UInt32 = 0) -> VkDescriptorPool? {
    let s = sizes.map { VkDescriptorPoolSize(type: $0.0, descriptorCount: $0.1) }
    var out: VkDescriptorPool?
    s.withUnsafeBufferPointer { sp in
      var info = VkDescriptorPoolCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
      info.flags = flags
      info.maxSets = sets
      info.poolSizeCount = UInt32(s.count)
      info.pPoolSizes = sp.baseAddress
      let r = fn("vkCreateDescriptorPool", PFN_vkCreateDescriptorPool.self)(device, &info, nil, &out)
      precondition(r == VK_SUCCESS, "vkCreateDescriptorPool \(r)")
    }
    return out
  }

  func allocateSet(_ pool: VkDescriptorPool?, _ layout: VkDescriptorSetLayout?) -> (VkResult, VkDescriptorSet?) {
    var l = layout
    var out: VkDescriptorSet?
    var r = VK_SUCCESS
    withUnsafePointer(to: &l) { lp in
      var info = VkDescriptorSetAllocateInfo()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
      info.descriptorPool = pool
      info.descriptorSetCount = 1
      info.pSetLayouts = lp
      r = fn("vkAllocateDescriptorSets", PFN_vkAllocateDescriptorSets.self)(device, &info, &out)
    }
    return (r, out)
  }

  func writeBuffers(_ set: VkDescriptorSet?, binding: UInt32, type: VkDescriptorType, element: UInt32 = 0,
                    _ infos: [VkDescriptorBufferInfo])
  {
    infos.withUnsafeBufferPointer { ip in
      var w = VkWriteDescriptorSet()
      w.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
      w.dstSet = set
      w.dstBinding = binding
      w.dstArrayElement = element
      w.descriptorCount = UInt32(infos.count)
      w.descriptorType = type
      w.pBufferInfo = ip.baseAddress
      fn("vkUpdateDescriptorSets", PFN_vkUpdateDescriptorSets.self)(device, 1, &w, 0, nil)
    }
  }

  func writeImages(_ set: VkDescriptorSet?, binding: UInt32, type: VkDescriptorType, element: UInt32 = 0, _ infos: [VkDescriptorImageInfo]) {
    infos.withUnsafeBufferPointer { ip in
      var w = VkWriteDescriptorSet()
      w.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
      w.dstSet = set
      w.dstBinding = binding
      w.dstArrayElement = element
      w.descriptorCount = UInt32(infos.count)
      w.descriptorType = type
      w.pImageInfo = ip.baseAddress
      fn("vkUpdateDescriptorSets", PFN_vkUpdateDescriptorSets.self)(device, 1, &w, 0, nil)
    }
  }

  // MARK: Commands

  func commandPool() -> VkCommandPool? {
    var info = VkCommandPoolCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
    var p: VkCommandPool?
    let r = fn("vkCreateCommandPool", PFN_vkCreateCommandPool.self)(device, &info, nil, &p)
    precondition(r == VK_SUCCESS)
    return p
  }

  func commandBuffer(_ pool: VkCommandPool?) -> VkCommandBuffer? {
    var info = VkCommandBufferAllocateInfo()
    info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    info.commandPool = pool
    info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
    info.commandBufferCount = 1
    var c: VkCommandBuffer?
    let r = fn("vkAllocateCommandBuffers", PFN_vkAllocateCommandBuffers.self)(device, &info, &c)
    precondition(r == VK_SUCCESS)
    return c
  }

  func begin(_ cb: VkCommandBuffer?) {
    var info = VkCommandBufferBeginInfo()
    info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    let r = fn("vkBeginCommandBuffer", PFN_vkBeginCommandBuffer.self)(cb, &info)
    precondition(r == VK_SUCCESS)
  }

  func end(_ cb: VkCommandBuffer?) -> VkResult { fn("vkEndCommandBuffer", PFN_vkEndCommandBuffer.self)(cb) }

  func submit(_ cbs: [VkCommandBuffer?], wait: [VkSemaphore?] = [], waitValues: [UInt64] = [], signal: [VkSemaphore?] = [],
              signalValues: [UInt64] = [], fence: VkFence? = nil) -> VkResult
  {
    var r = VK_SUCCESS
    var timeline = VkTimelineSemaphoreSubmitInfo()
    timeline.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO
    cbs.withUnsafeBufferPointer { cp in
      wait.withUnsafeBufferPointer { wp in
        signal.withUnsafeBufferPointer { sp in
          waitValues.withUnsafeBufferPointer { wv in
            signalValues.withUnsafeBufferPointer { sv in
              timeline.waitSemaphoreValueCount = UInt32(waitValues.count)
              timeline.pWaitSemaphoreValues = wv.baseAddress
              timeline.signalSemaphoreValueCount = UInt32(signalValues.count)
              timeline.pSignalSemaphoreValues = sv.baseAddress
              withUnsafePointer(to: &timeline) { tp in
                var info = VkSubmitInfo()
                info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                info.pNext = (waitValues.isEmpty && signalValues.isEmpty) ? nil : UnsafeRawPointer(tp)
                info.waitSemaphoreCount = UInt32(wait.count)
                info.pWaitSemaphores = wp.baseAddress
                info.commandBufferCount = UInt32(cbs.count)
                info.pCommandBuffers = cp.baseAddress
                info.signalSemaphoreCount = UInt32(signal.count)
                info.pSignalSemaphores = sp.baseAddress
                r = fn("vkQueueSubmit", PFN_vkQueueSubmit.self)(queue, 1, &info, fence)
              }
            }
          }
        }
      }
    }
    return r
  }

  // MARK: Synchronisation

  func fence(signaled: Bool = false) -> VkFence? {
    var info = VkFenceCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
    info.flags = signaled ? VK_FENCE_CREATE_SIGNALED_BIT.rawValue : 0
    var f: VkFence?
    let r = fn("vkCreateFence", PFN_vkCreateFence.self)(device, &info, nil, &f)
    precondition(r == VK_SUCCESS)
    return f
  }

  func semaphore(timeline initial: UInt64? = nil) -> VkSemaphore? {
    var type = VkSemaphoreTypeCreateInfo()
    type.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
    type.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE
    type.initialValue = initial ?? 0
    var s: VkSemaphore?
    withUnsafePointer(to: &type) { tp in
      var info = VkSemaphoreCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
      info.pNext = initial == nil ? nil : UnsafeRawPointer(tp)
      let r = fn("vkCreateSemaphore", PFN_vkCreateSemaphore.self)(device, &info, nil, &s)
      precondition(r == VK_SUCCESS)
    }
    return s
  }

  func counter(_ s: VkSemaphore?) -> UInt64 {
    var v: UInt64 = 0
    _ = fn("vkGetSemaphoreCounterValue", PFN_vkGetSemaphoreCounterValue.self)(device, s, &v)
    return v
  }
}

// MARK: Reading what the fake saw

extension GPUCommandList {
  var dispatches: [(pipeline: GPUPipeline, root: UInt64, x: UInt32, y: UInt32, z: UInt32)] {
    commands.compactMap {
      if case .dispatch(let p, let r, let x, let y, let z) = $0 { return (p, r, x, y, z) }
      return nil
    }
  }

  var draws: [(pipeline: GPUPipeline, root: UInt64, vertices: UInt32, instances: UInt32, firstVertex: UInt32, firstInstance: UInt32)] {
    commands.compactMap {
      if case .draw(let p, let r, let v, let i, let fv, let fi) = $0 { return (p, r, v, i, fv, fi) }
      return nil
    }
  }
}
