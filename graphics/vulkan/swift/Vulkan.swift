// SPDX-License-Identifier: BSD-3-Clause

// What both builds of the Vulkan bindings share (M5h): errors, the version
// number, and the command table (generated/Commands.swift). The library
// that fills the table is the host's loader on Linux (hosted/Library.swift)
// and ours natively (native/Library.swift).

@_exported import TDVulkan

public enum VulkanError: Error, Equatable {
  /// No Vulkan loader on this host (libvulkan.so.1).
  case noLoader
  /// A call returned an error.
  case failed(String, VkResult)
  /// A command the driver doesn't provide.
  case missing(String)
}

/// Throws unless `result` is VK_SUCCESS.
public func check(_ result: VkResult, _ what: String) throws(VulkanError) {
  guard result == VK_SUCCESS else { throw .failed(what, result) }
}

/// The version number Vulkan uses: variant 0, then major, minor, patch.
public func vulkanVersion(_ major: UInt32, _ minor: UInt32, _ patch: UInt32 = 0) -> UInt32 {
  major << 22 | minor << 12 | patch
}
