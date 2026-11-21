// SPDX-License-Identifier: BSD-3-Clause

// The loader's driver registry on the device (D121): Venus, linked in
// (graphics/vulkan/drivers/venus), connected the first time the loader asks
// to the process's GPUs (GPUContext's namespace, else the process's own).
// Statically linked, as tier 0 is: no dlopen. The Vulkan layer's registry
// (graphics/vulkan/drivers/core/registry) is the other one a program links.

#if canImport(VenusClient)
import VenusClient
#endif

@_silgen_name("td_vulkan_driver")
public func tdVulkanDriver(_ index: Int) -> (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?)? {
  guard index == 0 else { return nil }
  return unsafe connectVenus()
}
