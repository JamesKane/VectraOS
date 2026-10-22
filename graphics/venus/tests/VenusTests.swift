// SPDX-License-Identifier: BSD-3-Clause

// Venus's generated encoders and decoders (M5d): the encodings
// docs/research/venus-protocol.md §4, §5 and §8 give byte for byte (checked
// there against the 1.3.0 renderer), replies round-tripped through the
// renderer's side, and the committed outputs regenerated from data/venus.

import FoundationEssentials
import TDVenus
import Testing
import VenusGen

@testable import Venus

/// An object as the client driver lays it out: its id at offset 8.
final class FakeObject {
  let memory = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
  init(_ id: UInt64) {
    memory.storeBytes(of: 0, toByteOffset: 0, as: UInt64.self)
    memory.storeBytes(of: id, toByteOffset: 8, as: UInt64.self)
  }
  var handle: OpaquePointer { OpaquePointer(memory) }
  deinit { memory.deallocate() }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String($0, radix: 16).leftPad(2) }.joined(separator: " ") }

extension String {
  func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}

/// Bytes from a hex listing ("01 00 00 00 …").
func bytes(_ text: String) -> [UInt8] { text.split(separator: " ").map { UInt8($0, radix: 16)! } }

@Suite struct VenusTests {
  @Test func setReplyCommandStream() {
    var stream = VkCommandStreamDescriptionMESA(resourceId: 1, offset: 0x80000, size: 0x10000)
    var e = VenusEncoder()
    Venus.vkSetReplyCommandStreamMESA(&e, reply: false, &stream)
    #expect(hex(e.bytes) == hex(bytes("""
      b2 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00 00 08 00 00 00 00 00 00 00 01 00 00 00 00 00
      """)))
  }

  @Test func createInstance() {
    let instance = FakeObject(1)
    "todhchai-probe".withCString { name in
      var app = VkApplicationInfo(sType: VK_STRUCTURE_TYPE_APPLICATION_INFO, pNext: nil, pApplicationName: name,
                                  applicationVersion: 1, pEngineName: nil, engineVersion: 0, apiVersion: 0x0040_1000)
      withUnsafePointer(to: &app) { app in
        var info = VkInstanceCreateInfo(sType: VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, pNext: nil, flags: 0,
                                        pApplicationInfo: app, enabledLayerCount: 0, ppEnabledLayerNames: nil,
                                        enabledExtensionCount: 0, ppEnabledExtensionNames: nil)
        var handle: VkInstance? = instance.handle
        var e = VenusEncoder()
        Venus.vkCreateInstance(&e, reply: true, &info, nil, &handle)
        #expect(e.count == 144)
        // §5's table, offset by offset.
        let b = e.bytes
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[at + $1]) << (8 * $1) } }
        func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
        #expect(u32(0) == 0 && u32(4) == 1)  // type 0, flags REPLY
        #expect(u64(8) == 1 && u32(16) == 1 && u64(20) == 0 && u32(28) == 0)  // pCreateInfo, sType, pNext, flags
        #expect(u64(32) == 1 && u32(40) == 0 && u64(44) == 0)  // pApplicationInfo, its sType, pNext
        #expect(u64(52) == 15 && Array(b[60..<76]) == Array("todhchai-probe".utf8) + [0, 0])
        #expect(u32(76) == 1 && u64(80) == 0 && u32(88) == 0 && u32(92) == 0x0040_1000)
        #expect(u32(96) == 0 && u64(100) == 0 && u32(108) == 0 && u64(112) == 0)  // no layers, no extensions
        #expect(u64(120) == 0 && u64(128) == 1 && u64(136) == 1)  // pAllocator, pInstance, the id
        #expect(Venus.vkCreateInstance_replySize(&info, nil, &handle) == 24)
      }
    }
  }

  @Test func enumeratePhysicalDevicesCount() throws {
    let instance = FakeObject(1)
    var count: UInt32 = 0
    var e = VenusEncoder()
    Venus.vkEnumeratePhysicalDevices(&e, reply: true, instance.handle, &count, nil)
    #expect(hex(e.bytes) == hex(bytes("""
      02 00 00 00 01 00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
      """)))
    #expect(Venus.vkEnumeratePhysicalDevices_replySize(instance.handle, &count, nil) == 28)

    // The renderer's reply with three devices, then their ids.
    let devices = [FakeObject(2), FakeObject(3), FakeObject(4)]
    var three: UInt32 = 3
    var handles: [VkPhysicalDevice?] = devices.map { $0.handle }
    var r = VenusEncoder()
    Venus.vkEnumeratePhysicalDevices_encodeReply(&r, VK_SUCCESS, instance.handle, &three, &handles)
    #expect(r.count == 28 + 3 * 8)
    var got: UInt32 = 3
    var slots = [VkPhysicalDevice?](repeating: nil, count: 3)
    let result = try r.bytes.withUnsafeBytes { b in
      var d = VenusDecoder(b)
      return try Venus.vkEnumeratePhysicalDevices_reply(&d, instance.handle, &got, &slots)
    }
    #expect(result == VK_SUCCESS)
    #expect(got == 3)
  }

  @Test func physicalDeviceProperties() throws {
    let device = FakeObject(2)
    var blank = VkPhysicalDeviceProperties()
    var e = VenusEncoder()
    Venus.vkGetPhysicalDeviceProperties(&e, reply: true, device.handle, &blank)
    #expect(e.count == 24)  // §4.12: the struct encodes to nothing partly
    #expect(Venus.vkGetPhysicalDeviceProperties_replySize(device.handle, &blank) == 880)

    var properties = VkPhysicalDeviceProperties()
    properties.apiVersion = 0x0040_3000
    properties.vendorID = 0x10DE
    properties.deviceType = VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
    withUnsafeMutableBytes(of: &properties.deviceName) { b in
      for (i, c) in "NVIDIA GeForce RTX 5070 Ti".utf8.enumerated() { b[i] = c }
    }
    properties.limits.maxImageDimension2D = 32768
    properties.limits.maxComputeWorkGroupCount = (65535, 65535, 65535)
    properties.limits.minMemoryMapAlignment = 64
    properties.limits.nonCoherentAtomSize = 256
    properties.sparseProperties.residencyStandard2DBlockShape = 1
    var r = VenusEncoder()
    Venus.vkGetPhysicalDeviceProperties_encodeReply(&r, device.handle, &properties)
    #expect(r.count == 880)
    #expect(Array(r.bytes[40..<66]) == Array("NVIDIA GeForce RTX 5070 Ti".utf8))  // §8: deviceName at 40

    var back = VkPhysicalDeviceProperties()
    try r.bytes.withUnsafeBytes { b in
      var d = VenusDecoder(b)
      try Venus.vkGetPhysicalDeviceProperties_reply(&d, device.handle, &back)
      #expect(d.at == d.end)
    }
    let same = withUnsafeBytes(of: properties) { a in withUnsafeBytes(of: back) { b in a.elementsEqual(b) } }
    #expect(same)
  }

  @Test func memoryProperties() {
    let device = FakeObject(2)
    var blank = VkPhysicalDeviceMemoryProperties()
    var e = VenusEncoder()
    Venus.vkGetPhysicalDeviceMemoryProperties(&e, reply: true, device.handle, &blank)
    // §4.12: the fixed arrays' sizes, 32 and 16, and nothing else.
    #expect(hex(Array(e.bytes[24...])) == hex(bytes("20 00 00 00 00 00 00 00 10 00 00 00 00 00 00 00")))
    #expect(Venus.vkGetPhysicalDeviceMemoryProperties_replySize(device.handle, &blank) == 484)
  }

  @Test func deviceQueueWithTimeline() {
    let device = FakeObject(5), queue = FakeObject(6)
    var timeline = VkDeviceQueueTimelineInfoMESA(sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_TIMELINE_INFO_MESA, pNext: nil,
                                                 ringIdx: 1)
    withUnsafePointer(to: &timeline) { t in
      var info = VkDeviceQueueInfo2(sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2, pNext: UnsafeRawPointer(t), flags: 0,
                                    queueFamilyIndex: 0, queueIndex: 0)
      var handle: VkQueue? = queue.handle
      var e = VenusEncoder()
      Venus.vkGetDeviceQueue2(&e, reply: false, device.handle, &info, &handle)
      // Type, flags, the device's id, a marker, then §4.10's example, then the queue's id.
      let chain = bytes("""
        6b 00 9d 3b 01 00 00 00 00 00 00 00 05 a6 a0 3b 00 00 00 00 00 00 00 00 01 00 00 00 \
        00 00 00 00 00 00 00 00 00 00 00 00
        """)
      #expect(hex(Array(e.bytes[24..<(24 + chain.count)])) == hex(chain))
      #expect(Array(e.bytes[(24 + chain.count)...]) == bytes("01 00 00 00 00 00 00 00 06 00 00 00 00 00 00 00"))
    }
  }

  @Test func featuresThroughAChain() throws {
    let device = FakeObject(2)
    var v13 = VkPhysicalDeviceVulkan13Features()
    v13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
    var v12 = VkPhysicalDeviceVulkan12Features()
    v12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    var features = VkPhysicalDeviceFeatures2()
    features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
    try withUnsafeMutablePointer(to: &v13) { p13 in
      try withUnsafeMutablePointer(to: &v12) { p12 in
        p12.pointee.pNext = UnsafeMutableRawPointer(p13)
        features.pNext = UnsafeMutableRawPointer(p12)

        // Partly: the chain's markers and sTypes, nothing of the features.
        var e = VenusEncoder()
        Venus.vkGetPhysicalDeviceFeatures2(&e, reply: true, device.handle, &features)
        #expect(e.count == 24 + 4 + (8 + 4) * 2 + 8)

        // The renderer fills them; the reply decodes into the same chain.
        p13.pointee.dynamicRendering = 1
        p13.pointee.synchronization2 = 1
        p12.pointee.timelineSemaphore = 1
        p12.pointee.bufferDeviceAddress = 1
        features.features.samplerAnisotropy = 1
        var r = VenusEncoder()
        Venus.vkGetPhysicalDeviceFeatures2_encodeReply(&r, device.handle, &features)
        #expect(r.count == Venus.vkGetPhysicalDeviceFeatures2_replySize(device.handle, &features))
        p13.pointee.dynamicRendering = 0
        p13.pointee.synchronization2 = 0
        p12.pointee.timelineSemaphore = 0
        p12.pointee.bufferDeviceAddress = 0
        features.features.samplerAnisotropy = 0
        try r.bytes.withUnsafeBytes { b in
          var d = VenusDecoder(b)
          try Venus.vkGetPhysicalDeviceFeatures2_reply(&d, device.handle, &features)
        }
        #expect(p13.pointee.dynamicRendering == 1 && p13.pointee.synchronization2 == 1)
        #expect(p12.pointee.timelineSemaphore == 1 && p12.pointee.bufferDeviceAddress == 1)
        #expect(features.features.samplerAnisotropy == 1)
        #expect(p12.pointee.pNext == UnsafeMutableRawPointer(p13))  // the chain itself untouched
      }
    }
  }

  @Test func aReplyForAnotherCommandIsRefused() throws {
    let device = FakeObject(2)
    var count: UInt32 = 0
    var r = VenusEncoder()
    Venus.vkEnumeratePhysicalDevices_encodeReply(&r, VK_SUCCESS, device.handle, &count, nil)
    var blank = VkPhysicalDeviceProperties()
    let error = r.bytes.withUnsafeBytes { b -> VenusError? in
      var d = VenusDecoder(b)
      do throws(VenusError) { try Venus.vkGetPhysicalDeviceProperties_reply(&d, device.handle, &blank) } catch { return error }
      return nil
    }
    #expect(error == .wrongCommand(2))
  }

  @Test func committedOutputsMatchTheData() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func read(_ path: String) throws -> String {
      try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
    let (header, swift, entries) = try venusOutputs(vk: read("data/venus/vk.xml"),
                                           serialization: read("data/venus/VK_EXT_command_serialization.xml"),
                                           protocol: read("data/venus/VK_MESA_venus_protocol.xml"))
    #expect(header == (try read("graphics/venus/c/include/td_venus.h")), "regenerate: vkgen --venus (CLAUDE.md, \"Venus\")")
    #expect(swift == (try read("graphics/venus/lib/generated/Protocol.swift")), "regenerate: vkgen --venus")
    #expect(entries == (try read("graphics/venus/driver/generated/Entries.swift")), "regenerate: vkgen --venus")
  }
}
