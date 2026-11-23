// SPDX-License-Identifier: BSD-3-Clause

// The Venus client driver against the host's renderer (M5e): a
// `virgl_test_server --venus` of the suite's own, and the driver's entry
// points driving it as an application would. Skipped when the server isn't
// installed (`sudo dnf install virglrenderer-test-server`).

import FoundationEssentials
import Glibc
import TDVenus
import Testing
import Venus
import VenusVtest

@testable import VenusDriver

/// One server for the suite, on a short socket path (§1.1: sun_path
/// truncates). A shell keeps it: its output goes to a log (so the test
/// runner's pipes close), and it ends when this process does.
final class Server: @unchecked Sendable {
  static let binary = "/usr/bin/virgl_test_server"
  static let shared = Server()
  let path: String
  var started = false

  init() {
    let dir = getenv("XDG_RUNTIME_DIR").map { String(cString: $0) } ?? "/tmp"
    path = "\(dir)/td-vtest-\(getpid())"
    guard access(Self.binary, X_OK) == 0 else { return }
    unlink(path)
    let script = """
      exec </dev/null >/tmp/td-vtest-\(getpid()).log 2>&1
      \(Self.binary) --venus --socket-path \(path) & s=$!
      while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
      kill -9 $s; rm -f \(path)
      """
    var args: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(script), nil]
    defer { for a in args { free(a) } }
    var p: pid_t = 0
    guard posix_spawn(&p, "/bin/sh", nil, nil, &args, environ) == 0 else { return }
    for _ in 0..<300 where access(path, F_OK) != 0 { usleep(10_000) }
    started = true
  }

  var available: Bool { started && access(path, F_OK) == 0 }
}

func check(_ r: VkResult, _ what: String) throws {
  guard r == VK_SUCCESS else { throw TestFailure("\(what): VkResult \(r.rawValue)") }
}

struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}

/// An instance, its first device with one queue that copies, and a pool.
final class GPU {
  var instance: VkInstance?
  var physical: VkPhysicalDevice?
  var device: VkDevice?
  var queue: VkQueue?
  var family: UInt32 = 0
  var pool: VkCommandPool?
  var memoryProperties = VkPhysicalDeviceMemoryProperties()
  var name = ""
  var apiVersion: UInt32 = 0

  init() throws {
    var app = VkApplicationInfo()
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
    app.apiVersion = VenusDriver.apiVersion
    var instanceInfo = VkInstanceCreateInfo()
    instanceInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
    try withUnsafePointer(to: &app) { a in
      instanceInfo.pApplicationInfo = a
      try check(venus_vkCreateInstance(&instanceInfo, nil, &instance), "vkCreateInstance")
    }
    var count: UInt32 = 0
    try check(venus_vkEnumeratePhysicalDevices(instance, &count, nil), "count")
    var devices = [VkPhysicalDevice?](repeating: nil, count: Int(count))
    try check(venus_vkEnumeratePhysicalDevices(instance, &count, &devices), "devices")
    physical = try #require(devices.first ?? nil)
    var properties = VkPhysicalDeviceProperties()
    venus_vkGetPhysicalDeviceProperties(physical, &properties)
    name = withUnsafeBytes(of: properties.deviceName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    apiVersion = properties.apiVersion
    venus_vkGetPhysicalDeviceMemoryProperties(physical, &memoryProperties)

    var families: UInt32 = 0
    venus_vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, nil)
    var familyProperties = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(families))
    venus_vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, &familyProperties)
    family = UInt32(try #require(familyProperties.firstIndex { $0.queueFlags & 0x7 != 0 }))  // graphics, compute or transfer
    var priority: Float = 1
    var queueInfo = VkDeviceQueueCreateInfo()
    queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    queueInfo.queueFamilyIndex = family
    queueInfo.queueCount = 1
    try withUnsafePointer(to: &priority) { p in
      queueInfo.pQueuePriorities = p
      try withUnsafePointer(to: &queueInfo) { q in
        var info = VkDeviceCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        info.queueCreateInfoCount = 1
        info.pQueueCreateInfos = q
        try check(venus_vkCreateDevice(physical, &info, nil, &device), "vkCreateDevice")
      }
    }
    venus_vkGetDeviceQueue(device, family, 0, &queue)
    var poolInfo = VkCommandPoolCreateInfo()
    poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
    poolInfo.queueFamilyIndex = family
    try check(venus_vkCreateCommandPool(device, &poolInfo, nil, &pool), "vkCreateCommandPool")
  }

  deinit {
    venus_vkDestroyCommandPool(device, pool, nil)
    venus_vkDestroyDevice(device, nil)
    venus_vkDestroyInstance(instance, nil)
  }

  /// A buffer in host-visible, coherent memory, mapped.
  func buffer(_ size: VkDeviceSize, usage: UInt32) throws -> (VkBuffer?, VkDeviceMemory?, UnsafeMutableRawPointer) {
    var info = VkBufferCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    info.size = size
    info.usage = usage
    var b: VkBuffer?
    try check(venus_vkCreateBuffer(device, &info, nil, &b), "vkCreateBuffer")
    var requirements = VkMemoryRequirements()
    venus_vkGetBufferMemoryRequirements(device, b, &requirements)
    let types = withUnsafeBytes(of: memoryProperties.memoryTypes) { Array($0.bindMemory(to: VkMemoryType.self)) }
    let wanted: UInt32 = 0x2 | 0x4  // HOST_VISIBLE | HOST_COHERENT
    let index = try #require((0..<Int(memoryProperties.memoryTypeCount)).first {
      requirements.memoryTypeBits & (1 << $0) != 0 && types[$0].propertyFlags & wanted == wanted
    })
    var allocate = VkMemoryAllocateInfo()
    allocate.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    allocate.allocationSize = requirements.size
    allocate.memoryTypeIndex = UInt32(index)
    var m: VkDeviceMemory?
    try check(venus_vkAllocateMemory(device, &allocate, nil, &m), "vkAllocateMemory")
    try check(venus_vkBindBufferMemory(device, b, m, 0), "vkBindBufferMemory")
    var data: UnsafeMutableRawPointer?
    try check(venus_vkMapMemory(device, m, 0, size, 0, &data), "vkMapMemory")
    return (b, m, try #require(data))
  }

  /// Records `body` into a fresh command buffer, submits it with a fence
  /// and waits for it.
  func run(_ body: (VkCommandBuffer?) -> Void) throws {
    var allocateInfo = VkCommandBufferAllocateInfo()
    allocateInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    allocateInfo.commandPool = pool
    allocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
    allocateInfo.commandBufferCount = 1
    var commandBuffer: VkCommandBuffer?
    try check(venus_vkAllocateCommandBuffers(device, &allocateInfo, &commandBuffer), "vkAllocateCommandBuffers")
    defer { venus_vkFreeCommandBuffers(device, pool, 1, &commandBuffer) }
    var begin = VkCommandBufferBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    try check(venus_vkBeginCommandBuffer(commandBuffer, &begin), "vkBeginCommandBuffer")
    body(commandBuffer)
    try check(venus_vkEndCommandBuffer(commandBuffer), "vkEndCommandBuffer")
    var fenceInfo = VkFenceCreateInfo()
    fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
    var fence: VkFence?
    try check(venus_vkCreateFence(device, &fenceInfo, nil, &fence), "vkCreateFence")
    defer { venus_vkDestroyFence(device, fence, nil) }
    #expect(venus_vkGetFenceStatus(device, fence) == VK_NOT_READY)
    var submit = VkSubmitInfo()
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
    submit.commandBufferCount = 1
    try withUnsafePointer(to: &commandBuffer) { c in
      submit.pCommandBuffers = c
      try check(venus_vkQueueSubmit(queue, 1, &submit, fence), "vkQueueSubmit")
    }
    try check(venus_vkWaitForFences(device, 1, &fence, 1, 10_000_000_000), "vkWaitForFences")
    #expect(venus_vkGetFenceStatus(device, fence) == VK_SUCCESS)
    try check(venus_vkResetFences(device, 1, &fence), "vkResetFences")
    #expect(venus_vkGetFenceStatus(device, fence) == VK_NOT_READY)
  }
}

@Suite(.serialized) struct VenusDriverTests {
  init() {
    let path = Server.shared.path
    VenusDriver.connect = { try? VtestTransport(socket: path) }
    VenusDriver.useRing = true
  }

  @Test func everyEntryPointHasAName() {
    for name in ["vkCreateInstance", "vkCmdCopyBuffer", "vkQueueSubmit2", "vkGetBufferMemoryRequirements",
                 "vkCreateGraphicsPipelines", "vkGetDeviceQueue", "vkQueueBindSparse"] {
      #expect(name.withCString { VenusDriver.procAddress($0) } != nil, "\(name)")
    }
    #expect("vkNotACommand".withCString { VenusDriver.procAddress($0) } == nil)
    #expect("vkCreateRingMESA".withCString { VenusDriver.procAddress($0) } == nil)  // Venus's own: not Vulkan
  }

  /// The renderer's extensions the driver forwards: those its device offers and its protocol carries (the capset's mask, or
  /// every one where the mask isn't given), with the renderer's spec version.
  @Test func forwardedExtensionsAreOfferedAndCarried() {
    let name = Array("VK_EXT_custom_border_color".utf8)
    let offered: [(name: [UInt8], specVersion: UInt32)] = [(Array("VK_KHR_swapchain".utf8), 70), (name, 12)]
    var mask = [UInt32](repeating: 0, count: 32)
    // No mask: every extension is carried.
    var f = forwardable(offered: offered, mask: mask)
    #expect(f.count == 1 && f.first?.index == 0 && f.first?.specVersion == 12)
    // A mask without 288 (bit 0 of word 9): not forwarded; with it, forwarded.
    mask[0] = 1
    #expect(forwardable(offered: offered, mask: mask).isEmpty)
    mask[9] = 1
    f = forwardable(offered: offered, mask: mask)
    #expect(f.count == 1 && f.first?.specVersion == 12)
    // Not offered: not forwarded, and a prefix of the name is another name.
    #expect(forwardable(offered: [(Array("VK_EXT_custom_border".utf8), 1)], mask: mask).isEmpty)
    #expect(VenusContext.carries(mask, extension: 288) && !VenusContext.carries(mask, extension: 289))
  }

  /// Against the host's renderer: VK_EXT_custom_border_color is listed where the renderer offers it, and a device made with it
  /// enabled takes a sampler with a colour of its own; an extension the driver doesn't forward is refused.
  @Test(.enabled(if: Server.shared.available)) func aForwardedExtensionReachesTheRenderer() throws {
    let gpu = try GPU()
    var count: UInt32 = 0
    try check(venus_vkEnumerateDeviceExtensionProperties(gpu.physical, nil, &count, nil), "count")
    var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
    try check(venus_vkEnumerateDeviceExtensionProperties(gpu.physical, nil, &count, &props), "extensions")
    let names = props.map { p in withUnsafeBytes(of: p.extensionName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
    var priority: Float = 1
    var queueInfo = VkDeviceQueueCreateInfo()
    queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    queueInfo.queueFamilyIndex = gpu.family
    queueInfo.queueCount = 1
    func make(_ extensions: [String]) -> (VkResult, VkDevice?) {
      var device: VkDevice?
      let strings = extensions.map { strdup($0) }
      defer { for s in strings { free(s) } }
      var pointers = strings.map { UnsafePointer<CChar>($0) }
      return withUnsafePointer(to: &priority) { p in
        queueInfo.pQueuePriorities = p
        return withUnsafePointer(to: &queueInfo) { q in
          pointers.withUnsafeMutableBufferPointer { e in
            var info = VkDeviceCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
            info.queueCreateInfoCount = 1
            info.pQueueCreateInfos = q
            info.enabledExtensionCount = UInt32(e.count)
            info.ppEnabledExtensionNames = UnsafePointer(e.baseAddress)
            return (venus_vkCreateDevice(gpu.physical, &info, nil, &device), device)
          }
        }
      }
    }
    #expect(make(["VK_KHR_swapchain"]).0 == VK_ERROR_EXTENSION_NOT_PRESENT)
    guard names.contains("VK_EXT_custom_border_color") else { return }  // the renderer's device doesn't offer it
    let (r, device) = make(["VK_EXT_custom_border_color"])
    try check(r, "vkCreateDevice with VK_EXT_custom_border_color")
    defer { venus_vkDestroyDevice(device, nil) }
    var custom = VkSamplerCustomBorderColorCreateInfoEXT()
    custom.sType = VK_STRUCTURE_TYPE_SAMPLER_CUSTOM_BORDER_COLOR_CREATE_INFO_EXT
    custom.customBorderColor.float32 = (0.25, 0.5, 0.75, 1)
    custom.format = VK_FORMAT_R8G8B8A8_UNORM
    try withUnsafePointer(to: &custom) { c in
      var info = VkSamplerCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
      info.pNext = UnsafeRawPointer(c)
      info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
      info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
      info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
      info.borderColor = VK_BORDER_COLOR_FLOAT_CUSTOM_EXT
      var sampler: VkSampler?
      try check(venus_vkCreateSampler(device, &info, nil, &sampler), "vkCreateSampler (custom border)")
      venus_vkDestroySampler(device, sampler, nil)
    }
  }

  /// vkQueueBindSparse of no binds goes in order with the queue's submissions, and its fence is signalled by the renderer.
  @Test(.enabled(if: Server.shared.available)) func anEmptyBindSparseSignalsItsFence() throws {
    let gpu = try GPU()
    var fenceInfo = VkFenceCreateInfo()
    fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
    var fence: VkFence?
    try check(venus_vkCreateFence(gpu.device, &fenceInfo, nil, &fence), "vkCreateFence")
    defer { venus_vkDestroyFence(gpu.device, fence, nil) }
    try check(venus_vkQueueBindSparse(gpu.queue, 0, nil, fence), "vkQueueBindSparse")
    try check(venus_vkWaitForFences(gpu.device, 1, &fence, 1, 10_000_000_000), "vkWaitForFences")
    #expect(venus_vkGetFenceStatus(gpu.device, fence) == VK_SUCCESS)
  }

  @Test(.enabled(if: Server.shared.available)) func aBufferCopiedOnTheHostsGPU() throws {
    let gpu = try GPU()
    #expect(!gpu.name.isEmpty)
    #expect(gpu.apiVersion <= VenusDriver.apiVersion && gpu.apiVersion >= 1 << 22 | 1 << 12)
    let size: VkDeviceSize = 64 * 1024
    let (source, sourceMemory, sourceData) = try gpu.buffer(size, usage: 0x1)  // TRANSFER_SRC
    let (destination, destinationMemory, destinationData) = try gpu.buffer(size, usage: 0x2)  // TRANSFER_DST
    defer {
      venus_vkDestroyBuffer(gpu.device, source, nil)
      venus_vkDestroyBuffer(gpu.device, destination, nil)
      venus_vkFreeMemory(gpu.device, sourceMemory, nil)
      venus_vkFreeMemory(gpu.device, destinationMemory, nil)
    }
    let words = Int(size) / 4
    for i in 0..<words { sourceData.storeBytes(of: UInt32(i) &* 2_654_435_761, toByteOffset: 4 * i, as: UInt32.self) }
    memset(destinationData, 0, Int(size))
    try gpu.run { cb in
      var region = VkBufferCopy(srcOffset: 0, dstOffset: 0, size: size)
      venus_vkCmdCopyBuffer(cb, source, destination, 1, &region)
    }
    let copied = (0..<words).allSatisfy {
      destinationData.load(fromByteOffset: 4 * $0, as: UInt32.self) == UInt32($0) &* 2_654_435_761
    }
    #expect(copied, "the destination holds the source's words")
    try check(venus_vkQueueWaitIdle(gpu.queue), "vkQueueWaitIdle")
    try check(venus_vkDeviceWaitIdle(gpu.device), "vkDeviceWaitIdle")
  }

  /// 3000 fills, about 120 KiB of commands: more than a sixteenth of the
  /// ring, so the command buffer runs from staging (§7.3).
  @Test(.enabled(if: Server.shared.available)) func aLargeCommandBufferRunsFromStaging() throws {
    let gpu = try GPU()
    let words = 3000
    let (buffer, memory, data) = try gpu.buffer(VkDeviceSize(words * 4), usage: 0x2)
    defer {
      venus_vkDestroyBuffer(gpu.device, buffer, nil)
      venus_vkFreeMemory(gpu.device, memory, nil)
    }
    memset(data, 0, words * 4)
    try gpu.run { cb in
      for i in 0..<words { venus_vkCmdFillBuffer(cb, buffer, VkDeviceSize(4 * i), 4, UInt32(i) ^ 0xA5A5_0000) }
    }
    #expect((0..<words).allSatisfy { data.load(fromByteOffset: 4 * $0, as: UInt32.self) == UInt32($0) ^ 0xA5A5_0000 })
  }

  /// A call's round trip through the ring, and directly (printed: the ring
  /// needs no transport request for it).
  @Test(.enabled(if: Server.shared.available)) func callsThroughTheRingAndDirect() throws {
    func time(ring: Bool) throws -> Double {
      VenusDriver.useRing = ring
      defer { VenusDriver.useRing = true }
      let gpu = try GPU()
      var info = VkBufferCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
      info.size = 4096
      info.usage = 0x1
      var b: VkBuffer?
      try check(venus_vkCreateBuffer(gpu.device, &info, nil, &b), "vkCreateBuffer")
      defer { venus_vkDestroyBuffer(gpu.device, b, nil) }
      var requirements = VkMemoryRequirements()
      let n = 500
      var start = timespec(), end = timespec()
      clock_gettime(CLOCK_MONOTONIC, &start)
      for _ in 0..<n { venus_vkGetBufferMemoryRequirements(gpu.device, b, &requirements) }
      clock_gettime(CLOCK_MONOTONIC, &end)
      #expect(requirements.size >= 4096)
      return (Double(end.tv_sec - start.tv_sec) * 1e9 + Double(end.tv_nsec - start.tv_nsec)) / Double(n)
    }
    let ring = try time(ring: true), direct = try time(ring: false)
    print("venus: a call takes \(Int(ring / 1000)) µs through the ring, \(Int(direct / 1000)) µs directly")
  }
}
