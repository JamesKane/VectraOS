// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan device Loinnir renders with, on the host: the GPU the
// compositor reads dmabufs from (its feedback names it), with the
// extensions that share images as dmabufs (M1f2) and the 1.2/1.3 features
// Loinnir's API needs (M1f3).

@_exported import Vulkan

public enum LoinnirError: Error, Equatable {
  case vulkan(VulkanError)
  /// The window refused (its error, in words: the SDK is the device's).
  case window(String)
  /// No Vulkan device is the compositor's, or none can render what it takes.
  case unsupported(String)
}

@safe public final class GPUContext {
  public let vk: VulkanLibrary
  public let instance: VkInstance
  public let physical: VkPhysicalDevice
  public let device: VkDevice
  public let queue: VkQueue
  public let queueFamily: UInt32
  public let commandPool: VkCommandPool
  public let name: String

  /// What sharing images with the host's compositor needs (presenting);
  /// offscreen, a device without them will do, and gets those it has.
  /// Taken where the device has them: a VkDeviceMemory's VMO, for
  /// Radharc (natively, M5j).
  static let optionalExtensions: [StaticString] = ["VK_FUCHSIA_external_memory"]

  static let deviceExtensions: [StaticString] = [
    "VK_KHR_external_memory_fd", "VK_EXT_external_memory_dma_buf", "VK_EXT_image_drm_format_modifier",
    "VK_EXT_queue_family_foreign", "VK_EXT_physical_device_drm",
  ]

  /// A device with no window: the first discrete GPU, else the first one
  /// (tests and offscreen work).
  public convenience init() throws(LoinnirError) {
    try self.init(choose: .anyPreferDiscrete)
  }

  enum Choice {
    case drm((major: UInt32, minor: UInt32))
    case anyPreferDiscrete
  }

  init(choose: Choice) throws(LoinnirError) {
    loinnirPlatformSetup()
    do {
      vk = try VulkanLibrary()
    } catch {
      throw .vulkan(error)
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
    guard created == VK_SUCCESS, let inst = unsafe inst else { throw .vulkan(.failed("vkCreateInstance", created)) }
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
      throw .unsupported(major == 0 ? "no usable Vulkan device" : "no Vulkan device is the compositor's (DRM \(major):\(minor))")
    }
    unsafe self.physical = unsafe physical
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

    // The device, with the 1.2 and 1.3 features Loinnir uses.
    var dev: VkDevice?
    var features13 = unsafe VkPhysicalDeviceVulkan13Features()
    unsafe features13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
    unsafe features13.dynamicRendering = 1
    unsafe features13.synchronization2 = 1
    var features12 = unsafe VkPhysicalDeviceVulkan12Features()
    unsafe features12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    unsafe features12.bufferDeviceAddress = 1
    unsafe features12.timelineSemaphore = 1
    // The bindless texture heap (descriptor indexing).
    unsafe features12.descriptorIndexing = 1
    unsafe features12.runtimeDescriptorArray = 1
    unsafe features12.descriptorBindingPartiallyBound = 1
    unsafe features12.descriptorBindingSampledImageUpdateAfterBind = 1
    unsafe features12.shaderSampledImageArrayNonUniformIndexing = 1
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
      throw .vulkan(.failed("vkCreateDevice on \(chosenName)", result))
    }
    unsafe device = dev
    do { unsafe try vk.loadDevice(dev) } catch { throw .vulkan(error) }
    c = vk.commands
    var q: VkQueue?
    unsafe c.vkGetDeviceQueue!(dev, UInt32(graphics), 0, &q)
    unsafe queue = unsafe q!

    var poolInfo = unsafe VkCommandPoolCreateInfo()
    unsafe poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
    unsafe poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue
    unsafe poolInfo.queueFamilyIndex = UInt32(graphics)
    var pool: VkCommandPool?
    _ = unsafe c.vkCreateCommandPool!(dev, &poolInfo, nil, &pool)
    unsafe commandPool = unsafe pool!
  }

  deinit {
    let c = vk.commands
    _ = unsafe c.vkDeviceWaitIdle!(device)
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
}
