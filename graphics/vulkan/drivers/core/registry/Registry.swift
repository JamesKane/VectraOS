// SPDX-License-Identifier: BSD-3-Clause

// The loader's driver registry with the Vulkan layer (D174 step 5), in place of the native registry's raw Venus:
// the one driver it gives the loader is VulkanCoreDriver (vulkancore(2)), over the core of the GPU there is.
//   - Where the GPU class offers the Mali capset (`csf`): `MaliDevice()`, the core's Mali backend.
//   - Otherwise (QEMU, a host GPU): `VulkanDevice` over Venus, given Venus's vkGetInstanceProcAddr directly
//     (`VulkanLibrary(getInstanceProcAddr:)`), not through the loader, which would find this driver again.
// Built into vulkan-test where the layer is built (cmake/Tier1.cmake); the native registry (VulkanDriversNative's
// td_vulkan_driver) is the other one, and a program links one of them.

import GPUClient
import GPUCore
import GPUCoreMali
import GPUCoreVulkan
import Node
import Sys
import Vulkan
import VulkanCoreDriver

/// VenusClient's connection (graphics/vulkan/drivers/venus), by its symbol: Venus's C types and Vulkan's differ, and no
/// file imports both, so this module doesn't import it.
@_silgen_name("td_venus_connect")
func connectVenus() -> @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?

final class CoreRegistered: @unchecked Sendable {
  let lock = Lock()
  var tried = false
}
let coreRegistered = CoreRegistered()

/// The device the layer is written on: Mali where offered, else Vulkan over Venus. It says which, so a log shows
/// that the program went through the layer and on what.
func openCoreDevice() throws(GPUError) -> any GPUDevice {
  let device: any GPUDevice
  if CSFContext.isOffered() {
    device = try MaliDevice()
  } else {
    let venus = unsafe unsafeBitCast(connectVenus(), to: PFN_vkGetInstanceProcAddr.self)
    device = try VulkanDevice(choose: .anyPreferDiscrete, storageImages: true,
                              library: VulkanLibrary(getInstanceProcAddr: venus))
  }
  print("vulkan-core: the Vulkan layer over the core's \(device.backend) backend, on \(device.name)")
  return device
}

@_silgen_name("td_vulkan_driver")
public func tdVulkanDriver(_ index: Int) -> (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?)? {
  guard index == 0 else { return nil }
  coreRegistered.lock.withLock {
    guard !coreRegistered.tried else { return }
    coreRegistered.tried = true
    if GPUContext.namespace == nil { GPUContext.namespace = Namespace.process }
    CoreDriver.device = { () throws(GPUError) -> any GPUDevice in try openCoreDevice() }
    CoreDriver.message = { text in print("vulkan-core: " + text) }
  }
  return unsafe coreGetInstanceProcAddr
}
