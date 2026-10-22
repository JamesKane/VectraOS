// SPDX-License-Identifier: BSD-3-Clause

import FoundationEssentials
import Glibc
import Testing
import Vulkan
import VulkanGen

let root: String = {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(4)  // graphics/vulkan/tests/VulkanTests.swift
  return parts.joined(separator: "/")
}()

let header = "\(root)/graphics/vulkan/c/include/td_vulkan.h"

@Test func generatedFilesAreInStepWithVkXML() throws {
  let registry = try VulkanRegistry(try String(contentsOfFile: "\(root)/data/vulkan/vk.xml", encoding: .utf8))
  let g = try CHeaderGenerator(registry, loinnirSelection)
  #expect(try g.generate(source: "vk.xml") == (try String(contentsOfFile: header, encoding: .utf8)),
          "regenerate with vkgen (CLAUDE.md, \"Vulkan\")")
  #expect(g.swiftCommands(source: "vk.xml")
          == (try String(contentsOfFile: "\(root)/graphics/vulkan/swift/generated/Commands.swift", encoding: .utf8)))
}

/// Every struct's size and every field's offset, from our header and from
/// Khronos's (the host's vulkan-headers, used only to check against), must
/// agree: Swift sees the layouts the driver expects.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "/usr/include/vulkan/vulkan_core.h")))
func structLayoutsMatchKhronos() throws {
  let text = try String(contentsOfFile: header, encoding: .utf8)
  var checks: [String] = []
  var current: String?
  for line in text.split(separator: "\n") {
    if (line.hasPrefix("struct ") || line.hasPrefix("union ")) && line.hasSuffix(" {") {
      let name = String(line.split(separator: " ")[1])
      current = name
      checks.append("printf(\"\(name) %zu\\n\", sizeof(\(name)));")
    } else if line == "};" {
      current = nil
    } else if let s = current, line.hasSuffix(";"), !line.contains(":") {
      // The member's name: the last identifier before any array bound.
      let decl = line.dropLast().split(separator: "[").first ?? ""
      let field = decl.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).last.map(String.init) ?? ""
      checks.append("printf(\"\(s).\(field) %zu\\n\", offsetof(\(s), \(field)));")
    }
  }
  let dir = "/tmp/todhchai-vklayout-\(getpid())"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  func program(_ include: String) -> String {
    "#include <stdio.h>\n#include <stddef.h>\n\(include)\nint main(void) {\n\(checks.joined(separator: "\n"))\nreturn 0;\n}\n"
  }
  try program("#include \"td_vulkan.h\"").write(toFile: "\(dir)/ours.c", atomically: true, encoding: .utf8)
  // Fuchsia's types (VK_FUCHSIA_external_memory) are behind its platform
  // define, and need Zircon's handle type (zircon/types.h, a stand-in here:
  // a uint32_t, as ours declares it).
  try FileManager.default.createDirectory(atPath: "\(dir)/zircon", withIntermediateDirectories: true)
  try "#include <stdint.h>\ntypedef uint32_t zx_handle_t;\n".write(toFile: "\(dir)/zircon/types.h", atomically: true,
                                                                   encoding: .utf8)
  try program("#define VK_USE_PLATFORM_FUCHSIA\n#include <vulkan/vulkan.h>")
    .write(toFile: "\(dir)/khronos.c", atomically: true, encoding: .utf8)
  let includeDir = "\(root)/graphics/vulkan/c/include"
  #expect(system("clang -w -I '\(includeDir)' \(dir)/ours.c -o \(dir)/ours && \(dir)/ours > \(dir)/ours.txt") == 0)
  #expect(system("clang -w -I '\(dir)' \(dir)/khronos.c -o \(dir)/khronos && \(dir)/khronos > \(dir)/khronos.txt") == 0)
  let ours = try String(contentsOfFile: "\(dir)/ours.txt", encoding: .utf8)
  let theirs = try String(contentsOfFile: "\(dir)/khronos.txt", encoding: .utf8)
  #expect(checks.count > 2000)
  #expect(ours == theirs)
}

/// An instance, the physical devices, a device and its queue, with no
/// window. Skipped where there is no Vulkan loader.
@Test(.enabled(if: dlopen("libvulkan.so.1", RTLD_NOW) != nil))
func aDeviceComesUpHeadless() throws {
  let vk = try VulkanLibrary()
  var instance: VkInstance?
  try "todhchai-test".withCString { name in
    var app = VkApplicationInfo()
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
    app.pApplicationName = name
    app.apiVersion = vulkanVersion(1, 3)
    try withUnsafePointer(to: &app) { appp in
      var info = VkInstanceCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
      info.pApplicationInfo = appp
      try check(vk.commands.vkCreateInstance!(&info, nil, &instance), "vkCreateInstance")
    }
  }
  let inst = try #require(instance)
  vk.loadInstance(inst)
  defer { vk.commands.vkDestroyInstance!(inst, nil) }

  var count: UInt32 = 0
  try check(vk.commands.vkEnumeratePhysicalDevices!(inst, &count, nil), "count devices")
  var physical = [VkPhysicalDevice?](repeating: nil, count: Int(count))
  try check(vk.commands.vkEnumeratePhysicalDevices!(inst, &count, &physical), "enumerate devices")
  #expect(count >= 1)
  let gpu = try #require(physical.first ?? nil)

  var properties = VkPhysicalDeviceProperties()
  vk.commands.vkGetPhysicalDeviceProperties!(gpu, &properties)
  #expect(properties.apiVersion >= vulkanVersion(1, 3))

  var families: UInt32 = 0
  vk.commands.vkGetPhysicalDeviceQueueFamilyProperties!(gpu, &families, nil)
  var familyProps = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(families))
  vk.commands.vkGetPhysicalDeviceQueueFamilyProperties!(gpu, &families, &familyProps)
  let graphics = try #require(familyProps.firstIndex { $0.queueFlags & VK_QUEUE_GRAPHICS_BIT.rawValue != 0 })

  var priority: Float = 1
  var device: VkDevice?
  try withUnsafePointer(to: &priority) { pp in
    var queueInfo = VkDeviceQueueCreateInfo()
    queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    queueInfo.queueFamilyIndex = UInt32(graphics)
    queueInfo.queueCount = 1
    queueInfo.pQueuePriorities = pp
    try withUnsafePointer(to: &queueInfo) { qp in
      var info = VkDeviceCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
      info.queueCreateInfoCount = 1
      info.pQueueCreateInfos = qp
      try check(vk.commands.vkCreateDevice!(gpu, &info, nil, &device), "vkCreateDevice")
    }
  }
  let dev = try #require(device)
  try vk.loadDevice(dev)
  var queue: VkQueue?
  vk.commands.vkGetDeviceQueue!(dev, UInt32(graphics), 0, &queue)
  #expect(queue != nil)
  try check(vk.commands.vkDeviceWaitIdle!(dev), "vkDeviceWaitIdle")
  vk.commands.vkDestroyDevice!(dev, nil)
}
