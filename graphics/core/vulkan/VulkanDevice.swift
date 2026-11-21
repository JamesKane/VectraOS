// SPDX-License-Identifier: BSD-3-Clause

// The core over Vulkan (D174 section 5; gpucore(2)): the backend Venus is reached
// through under QEMU, and the one a host's own Vulkan is. It is Loinnir's
// Vulkan code moved behind the core: the device with the extensions that share
// images as dmabufs and the 1.2/1.3 features dynamic rendering, the bindless
// heap, buffer device addresses and the timeline need, the one pipeline
// layout (the heap, and a root pointer as push constants), the timeline as a
// timeline semaphore, and the layout transitions a recorded list needs.
//
// Nothing outside this module sees a Vulkan type: handles are numbers into
// this device's tables, and a list is replayed into a command buffer at
// `submit` (Replay.swift), which is where each image's layout is tracked.

@_exported import GPUCore
import Vulkan

/// A table of records, whose index (plus one) is the handle a client holds.
struct Slots<T> {
  var items: [T?] = []
  var free: [Int] = []

  mutating func insert(_ t: T) -> UInt64 {
    if let i = free.popLast() {
      items[i] = t
      return UInt64(i + 1)
    }
    items.append(t)
    return UInt64(items.count)
  }

  subscript(handle: UInt64) -> T? {
    guard handle >= 1, Int(handle) <= items.count else { return nil }
    return items[Int(handle) - 1]
  }

  mutating func remove(_ handle: UInt64) -> T? {
    guard handle >= 1, Int(handle) <= items.count, let t = items[Int(handle) - 1] else { return nil }
    items[Int(handle) - 1] = nil
    free.append(Int(handle) - 1)
    return t
  }

  var all: [T] { items.compactMap { $0 } }
}

/// Which Vulkan device to take.
public enum VulkanDeviceChoice {
  /// The one a DRM node names (the compositor's).
  case drm((major: UInt32, minor: UInt32))
  /// The first discrete GPU, else the first one.
  case anyPreferDiscrete
}

@safe public final class VulkanDevice: GPUDevice {
  public let vk: VulkanLibrary
  @safe public let instance: VkInstance
  @safe public let physical: VkPhysicalDevice
  @safe public let device: VkDevice
  @safe public let queue: VkQueue
  public let queueFamily: UInt32
  @safe let commandPool: VkCommandPool
  public let name: String
  public let backend = "vulkan"
  public private(set) var limits = DeviceLimits()

  let heap: Heap
  @safe let pipelineLayout: VkPipelineLayout
  @safe let timeline: VkSemaphore
  var rule = TimelineRule()

  var buffers = Slots<BufferRecord>()
  var images = Slots<ImageRecord>()
  var pipelines = Slots<PipelineRecord>()
  var querySets = Slots<QueryRecord>()
  var samplers: [SamplerRecord?] = []
  /// Command buffers in flight, by the value their submission signals.
  var pending: [(value: UInt64, commands: VkCommandBuffer)] = unsafe []
  /// What was freed, destroyed once the timeline passes the value it was freed at.
  var retired: [(value: UInt64, thing: Retired)] = []

  /// Whether the heap has its storage image array (`limits.features.storageImages`). Off by default: it adds a
  /// binding and two device features that boot-venus has not yet run with; the Vulkan layer turns it on.
  public static let heapStorageImageSlots: UInt32 = 1024

  /// What sharing images with the host's compositor needs (presenting); offscreen, a device without them will do,
  /// and gets those it has. Taken where the device has them: a VkDeviceMemory's VMO, for Radharc (natively).
  static let optionalExtensions: [StaticString] = ["VK_FUCHSIA_external_memory"]

  static let deviceExtensions: [StaticString] = [
    "VK_KHR_external_memory_fd", "VK_EXT_external_memory_dma_buf", "VK_EXT_image_drm_format_modifier",
    "VK_EXT_queue_family_foreign", "VK_EXT_physical_device_drm",
  ]

  /// A device with no window: the first discrete GPU, else the first one (tests and offscreen work).
  public convenience init() throws(GPUError) {
    try self.init(choose: .anyPreferDiscrete, storageImages: false)
  }

  /// `library` is the commands to use: another driver's, reached directly (`VulkanLibrary(getInstanceProcAddr:)`); by
  /// default our loader's.
  public init(choose: VulkanDeviceChoice, storageImages: Bool = false, library: VulkanLibrary? = nil) throws(GPUError) {
    if let library = library {
      vk = library
    } else {
      do {
        vk = try VulkanLibrary()
      } catch {
        switch error {
        case .noLoader: throw .noDevice("no Vulkan loader")
        case .missing(let what): throw .unsupported("no " + what)
        case .failed(let call, let result): throw .failed(call, code: result.rawValue)
        }
      }
    }
    var c = vk.commands

    // The instance.
    var inst: VkInstance?
    let created: VkResult = "todhchai".withCString { name in
      var app = unsafe VkApplicationInfo()
      unsafe app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
      unsafe app.pApplicationName = unsafe name
      unsafe app.pEngineName = unsafe name
      unsafe app.apiVersion = vulkanVersion(1, 3)
      return withUnsafePointer(to: &app) { appp in
        var info = unsafe VkInstanceCreateInfo()
        unsafe info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        unsafe info.pApplicationInfo = unsafe appp
        return unsafe c.vkCreateInstance!(&info, nil, &inst)
      }
    }
    guard created == VK_SUCCESS, let inst = unsafe inst else { throw .failed("vkCreateInstance", code: created.rawValue) }
    unsafe instance = inst
    unsafe vk.loadInstance(inst)
    c = vk.commands

    // The physical device: the compositor's (by DRM node), or any.
    var count: UInt32 = 0
    _ = unsafe c.vkEnumeratePhysicalDevices!(inst, &count, nil)
    var all = unsafe [VkPhysicalDevice?](repeating: nil, count: Int(count))
    _ = unsafe c.vkEnumeratePhysicalDevices!(inst, &count, &all)
    var chosen: VkPhysicalDevice?
    var chosenName = ""
    if case .anyPreferDiscrete = choose {
      let usable = unsafe all.compactMap { unsafe $0 }
      func props(_ p: VkPhysicalDevice) -> VkPhysicalDeviceProperties {
        var v = VkPhysicalDeviceProperties()
        unsafe c.vkGetPhysicalDeviceProperties!(p, &v)
        return v
      }
      unsafe chosen = usable.first { unsafe props($0).deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU } ?? usable.first
      if let p = unsafe chosen {
        chosenName = unsafe withUnsafeBytes(of: props(p).deviceName) { unsafe String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      }
    }
    let (major, minor): (UInt32, UInt32) = if case .drm(let d) = choose { (d.major, d.minor) } else { (0, 0) }
    for unsafe case let p? in unsafe all where unsafe chosen == nil {
      guard unsafe Self.supports(c, p, Self.deviceExtensions) else { continue }
      var drm = unsafe VkPhysicalDeviceDrmPropertiesEXT()
      unsafe drm.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT
      var props = unsafe VkPhysicalDeviceProperties2()
      unsafe props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
      withUnsafeMutablePointer(to: &drm) { d in
        unsafe props.pNext = UnsafeMutableRawPointer(d)
        unsafe c.vkGetPhysicalDeviceProperties2!(p, &props)
      }
      let primary = unsafe drm.hasPrimary != 0 && UInt32(drm.primaryMajor) == major && UInt32(drm.primaryMinor) == minor
      let render = unsafe drm.hasRender != 0 && UInt32(drm.renderMajor) == major && UInt32(drm.renderMinor) == minor
      if primary || render {
        unsafe chosen = unsafe p
        chosenName = unsafe withUnsafeBytes(of: props.properties.deviceName) { unsafe String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        break
      }
    }
    guard let physical = unsafe chosen else {
      unsafe c.vkDestroyInstance!(inst, nil)
      throw .noDevice(major == 0 ? "no usable Vulkan device" : "no Vulkan device is the compositor's (DRM \(major):\(minor))")
    }
    self.physical = unsafe physical
    name = chosenName

    // A graphics queue.
    var families: UInt32 = 0
    unsafe c.vkGetPhysicalDeviceQueueFamilyProperties!(physical, &families, nil)
    var familyProps = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(families))
    unsafe c.vkGetPhysicalDeviceQueueFamilyProperties!(physical, &families, &familyProps)
    guard let graphics = familyProps.firstIndex(where: { $0.queueFlags & VK_QUEUE_GRAPHICS_BIT.rawValue != 0 }) else {
      unsafe c.vkDestroyInstance!(inst, nil)
      throw .unsupported("\(chosenName) has no graphics queue")
    }
    queueFamily = UInt32(graphics)
    let timestampBits = familyProps[graphics].timestampValidBits

    // Storage images in the heap need two more features; asked of the device only when wanted and offered.
    var storageOK = false
    if storageImages {
      var have12 = unsafe VkPhysicalDeviceVulkan12Features()
      unsafe have12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
      var haveAll = unsafe VkPhysicalDeviceFeatures2()
      unsafe haveAll.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
      withUnsafeMutablePointer(to: &have12) { p in
        unsafe haveAll.pNext = UnsafeMutableRawPointer(p)
        unsafe c.vkGetPhysicalDeviceFeatures2!(physical, &haveAll)
      }
      storageOK = unsafe have12.descriptorBindingStorageImageUpdateAfterBind != 0
        && have12.shaderStorageImageArrayNonUniformIndexing != 0
    }

    // The device, with the 1.2 and 1.3 features the core uses.
    var dev: VkDevice?
    var features13 = unsafe VkPhysicalDeviceVulkan13Features()
    unsafe features13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
    unsafe features13.dynamicRendering = 1
    unsafe features13.synchronization2 = 1
    var features12 = unsafe VkPhysicalDeviceVulkan12Features()
    unsafe features12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    unsafe features12.bufferDeviceAddress = 1
    unsafe features12.timelineSemaphore = 1
    // The bindless heap (descriptor indexing).
    unsafe features12.descriptorIndexing = 1
    unsafe features12.runtimeDescriptorArray = 1
    unsafe features12.descriptorBindingPartiallyBound = 1
    unsafe features12.descriptorBindingSampledImageUpdateAfterBind = 1
    unsafe features12.shaderSampledImageArrayNonUniformIndexing = 1
    if storageOK {
      unsafe features12.descriptorBindingStorageImageUpdateAfterBind = 1
      unsafe features12.shaderStorageImageArrayNonUniformIndexing = 1
    }
    let required = if case .drm = choose { Self.deviceExtensions } else {
      Self.deviceExtensions.filter { unsafe Self.supports(c, physical, [$0]) }
    }
    let wanted = required + Self.optionalExtensions.filter { unsafe Self.supports(c, physical, [$0]) }
    let extensionNames = unsafe wanted.map { unsafe UnsafeRawPointer($0.utf8Start).assumingMemoryBound(to: CChar.self) }
    var priority: Float = 1
    let result: VkResult = withUnsafeMutablePointer(to: &features13) { f13 in
      unsafe features12.pNext = UnsafeMutableRawPointer(f13)
      return withUnsafeMutablePointer(to: &features12) { f12 in
        withUnsafePointer(to: &priority) { pp in
          var queueInfo = unsafe VkDeviceQueueCreateInfo()
          unsafe queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
          unsafe queueInfo.queueFamilyIndex = UInt32(graphics)
          unsafe queueInfo.queueCount = 1
          unsafe queueInfo.pQueuePriorities = unsafe pp
          return withUnsafePointer(to: &queueInfo) { qp in
            unsafe extensionNames.map { unsafe Optional($0) }.withUnsafeBufferPointer { names in
              var info = unsafe VkDeviceCreateInfo()
              unsafe info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
              unsafe info.pNext = UnsafeRawPointer(f12)
              unsafe info.queueCreateInfoCount = 1
              unsafe info.pQueueCreateInfos = unsafe qp
              unsafe info.enabledExtensionCount = UInt32(names.count)
              unsafe info.ppEnabledExtensionNames = names.baseAddress
              return unsafe c.vkCreateDevice!(physical, &info, nil, &dev)
            }
          }
        }
      }
    }
    guard result == VK_SUCCESS, let dev = unsafe dev else {
      unsafe c.vkDestroyInstance!(inst, nil)
      throw .failed("vkCreateDevice on \(chosenName)", code: result.rawValue)
    }
    unsafe device = dev
    do { unsafe try vk.loadDevice(dev) } catch { throw .failed("loading the device's commands", code: 0) }
    c = vk.commands
    var q: VkQueue?
    unsafe c.vkGetDeviceQueue!(dev, UInt32(graphics), 0, &q)
    queue = unsafe q!

    var poolInfo = unsafe VkCommandPoolCreateInfo()
    unsafe poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
    unsafe poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue
    unsafe poolInfo.queueFamilyIndex = UInt32(graphics)
    var pool: VkCommandPool?
    _ = unsafe c.vkCreateCommandPool!(dev, &poolInfo, nil, &pool)
    commandPool = unsafe pool!

    // The heap, the one pipeline layout (the heap, and 16 bytes of push constants: the root pointer and 8 spare),
    // and the timeline.
    heap = try Heap(c, dev, storageImages: storageOK)
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
        return unsafe c.vkCreatePipelineLayout!(dev, &info, nil, &layout)
      }
    }
    try vkCheck(r, "vkCreatePipelineLayout")
    pipelineLayout = unsafe layout!

    var typeInfo = unsafe VkSemaphoreTypeCreateInfo()
    unsafe typeInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
    unsafe typeInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE
    var semaphore: VkSemaphore?
    let s: VkResult = withUnsafePointer(to: &typeInfo) { tp in
      var info = unsafe VkSemaphoreCreateInfo()
      unsafe info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
      unsafe info.pNext = unsafe UnsafeRawPointer(tp)
      return unsafe c.vkCreateSemaphore!(dev, &info, nil, &semaphore)
    }
    try vkCheck(s, "vkCreateSemaphore (timeline)")
    timeline = unsafe semaphore!

    var l = DeviceLimits()
    l.features.indexedDraw = true
    l.features.indirectDraw = true
    l.features.indirectDispatch = true
    l.features.sampledImages = true
    l.features.storageImages = storageOK
    l.features.timestampQueries = timestampBits > 0
    l.features.occlusionQueries = true
    l.features.loadAttachments = true
    l.features.multipleDrawsPerPass = true
    l.features.multipleColorAttachments = true
    l.maxColorAttachments = 8
    // Its four formats: sampled, filtered, drawn into and blended; stored to where the heap has storage images, but for sRGB.
    for f in [PixelFormat.rgba8, .bgra8, .bgra8srgb, .r8] {
      var caps = FormatCapabilities.colorTarget
      caps.storage = storageOK && f != .bgra8srgb
      l.setFormat(f, caps)
    }
    l.heapTextures = Heap.textureCapacity
    l.heapSamplers = Heap.samplerCapacity
    l.heapStorageImages = storageOK ? Self.heapStorageImageSlots : 0
    l.maxImageDimension = 4096
    var deviceProps = VkPhysicalDeviceProperties()
    unsafe c.vkGetPhysicalDeviceProperties!(physical, &deviceProps)
    l.maxImageDimension = Int32(truncatingIfNeeded: deviceProps.limits.maxImageDimension2D)
    // The period is in nanoseconds a tick (a float); kept in picoseconds.
    l.timestampPeriodPicoseconds = timestampBits > 0 ? UInt64(deviceProps.limits.timestampPeriod * 1000) : 0
    limits = l
    samplers = [SamplerRecord?](repeating: nil, count: Int(Heap.samplerCapacity))
  }

  deinit {
    let c = vk.commands
    _ = unsafe c.vkDeviceWaitIdle!(device)
    destroyRetired(UInt64.max)
    for unsafe (_, cb) in unsafe pending {
      var b: VkCommandBuffer? = unsafe cb
      unsafe c.vkFreeCommandBuffers!(device, commandPool, 1, &b)
    }
    for p in pipelines.all { unsafe c.vkDestroyPipeline!(device, p.pipeline, nil) }
    for i in images.all { i.destroy(c, device) }
    for b in buffers.all { b.destroy(c, device) }
    for q in querySets.all { unsafe c.vkDestroyQueryPool!(device, q.pool, nil) }
    for case let s? in samplers { unsafe c.vkDestroySampler!(device, s.sampler, nil) }
    unsafe c.vkDestroySemaphore!(device, timeline, nil)
    unsafe c.vkDestroyPipelineLayout!(device, pipelineLayout, nil)
    heap.destroy(c, device)
    unsafe c.vkDestroyCommandPool!(device, commandPool, nil)
    unsafe c.vkDestroyDevice!(device, nil)
    unsafe c.vkDestroyInstance!(instance, nil)
  }

  /// Whether `device` has every extension in `names`.
  static func supports(_ c: VulkanCommands, _ device: VkPhysicalDevice, _ names: [StaticString]) -> Bool {
    var count: UInt32 = 0
    _ = unsafe c.vkEnumerateDeviceExtensionProperties!(device, nil, &count, nil)
    var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
    _ = unsafe c.vkEnumerateDeviceExtensionProperties!(device, nil, &count, &props)
    let have = props.prefix(Int(count)).map { p in
      withUnsafeBytes(of: p.extensionName) { unsafe Array($0.prefix { $0 != 0 }) }
    }
    return names.allSatisfy { n in
      let bytes = unsafe Array(UnsafeBufferPointer(start: n.utf8Start, count: n.utf8CodeUnitCount))
      return have.contains(bytes)
    }
  }

  // MARK: Queues and the timeline

  public var graphicsQueue: any GPUQueue { self }
  public var computeQueue: (any GPUQueue)? { nil }

  public var completed: UInt64 {
    var v: UInt64 = 0
    _ = unsafe vk.commands.vkGetSemaphoreCounterValue!(device, timeline, &v)
    return v
  }

  public func wait(_ value: UInt64) throws(GPUError) {
    let c = vk.commands
    var semaphore: VkSemaphore? = timeline
    var v = value
    let r: VkResult = withUnsafePointer(to: &semaphore) { sp in
      withUnsafePointer(to: &v) { vp in
        var info = unsafe VkSemaphoreWaitInfo()
        unsafe info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO
        unsafe info.semaphoreCount = 1
        unsafe info.pSemaphores = unsafe sp
        unsafe info.pValues = unsafe vp
        return unsafe c.vkWaitSemaphores!(device, &info, UInt64.max)
      }
    }
    try vkCheck(r, "vkWaitSemaphores")
    reclaim()
  }

  /// Frees what the GPU is done with: command buffers, and what was freed.
  func reclaim() {
    let done = completed
    destroyRetired(done)
    let c = vk.commands
    unsafe pending.removeAll { p in
      guard unsafe p.value <= done else { return false }
      var b: VkCommandBuffer? = unsafe p.commands
      unsafe c.vkFreeCommandBuffers!(device, commandPool, 1, &b)
      return true
    }
  }

  /// Something to destroy once the work submitted so far has finished.
  func retire(_ thing: Retired) {
    retired.append((rule.lastSignalled, thing))
    reclaim()
  }

  func destroyRetired(_ done: UInt64) {
    let c = vk.commands
    retired.removeAll { r in
      guard r.value <= done else { return false }
      switch r.thing {
      case .buffer(let b): b.destroy(c, device)
      case .image(let i): i.destroy(c, device)
      case .pipeline(let p): unsafe c.vkDestroyPipeline!(device, p.pipeline, nil)
      case .sampler(let s): unsafe c.vkDestroySampler!(device, s.sampler, nil)
      case .queries(let q): unsafe c.vkDestroyQueryPool!(device, q.pool, nil)
      }
      return true
    }
  }
}

/// Something freed, until the GPU is done with it.
@safe enum Retired {
  case buffer(BufferRecord)
  case image(ImageRecord)
  case pipeline(PipelineRecord)
  case sampler(SamplerRecord)
  case queries(QueryRecord)
}

/// Throws a Vulkan failure as a core error.
func vkCheck(_ r: VkResult, _ what: String) throws(GPUError) {
  guard r == VK_SUCCESS else { throw .failed(what, code: r.rawValue) }
}
