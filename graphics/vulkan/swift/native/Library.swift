// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan bindings natively (M5h): our loader (VulkanLoader), linked
// in, with the drivers its registry gives; the same VulkanLibrary the
// hosted build opens the host's loader for.

import VulkanLoader

/// Our loader and the commands loaded from it.
@safe public final class VulkanLibrary: @unchecked Sendable {
  public let getInstanceProcAddr: PFN_vkGetInstanceProcAddr
  public var commands = VulkanCommands()

  public init() throws(VulkanError) {
    unsafe getInstanceProcAddr = unsafe vkGetInstanceProcAddr
    unsafe commands.loadGlobal(getInstanceProcAddr)
  }

  public func loadInstance(_ instance: VkInstance) { unsafe commands.loadInstance(getInstanceProcAddr, instance) }

  public func loadDevice(_ device: VkDevice) throws(VulkanError) {
    guard let get = unsafe commands.vkGetDeviceProcAddr else { throw .missing("vkGetDeviceProcAddr") }
    unsafe commands.loadDevice(get, device)
  }
}
