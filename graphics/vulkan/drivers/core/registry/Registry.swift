// SPDX-License-Identifier: BSD-3-Clause

// The loader's driver registry with the Vulkan layer (D174 step 5), in place of the native registry's raw Venus:
// the one driver it gives the loader is VulkanCoreDriver, over the core of the GPU there is.
//   - Where the GPU class offers the Mali capset (`csf`): `MaliDevice()`, the core's Mali backend.
//   - Otherwise (QEMU, a host GPU): `VulkanDevice` over Venus, given Venus's vkGetInstanceProcAddr directly
//     (`VulkanLibrary(getInstanceProcAddr:)`), not through the loader, which would find this driver again.
// Built into vulkan-test where VulkanCoreDriver exists (cmake/Tier1.cmake); the native registry (VulkanDriversNative's
// td_vulkan_driver) is the other one, and a program links one of them.
//
// This file assumes VulkanCoreDriver's hook is VenusDriver's shape: a `connect` closure, set before the first
// instance, that makes the device the driver is written on (`GPUDevice`), and `procAddress(_:)`, the driver's
// vkGetInstanceProcAddr by name. Where it differs, this file changes, nothing else.

import GPUClient
import GPUCore
import GPUCoreMali
import GPUCoreVulkan
import Node
import Sys
import Vulkan
import VulkanCoreDriver
import VenusClient

final class CoreRegistered: @unchecked Sendable {
  let lock = Lock()
  var tried = false
}
let coreRegistered = CoreRegistered()

/// The device the layer is written on: Mali where offered, else Vulkan over Venus.
func openCoreDevice() -> (any GPUDevice)? {
  if CSFContext.isOffered() { return try? MaliDevice() }
  let venus = unsafe unsafeBitCast(connectVenus(), to: PFN_vkGetInstanceProcAddr.self)
  return try? VulkanDevice(choose: .anyPreferDiscrete, storageImages: true, library: VulkanLibrary(getInstanceProcAddr: venus))
}

let coreGetInstanceProcAddr: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer? = {
  instance, name in unsafe unsafeBitCast(VulkanCoreDriver.procAddress(name), to: UnsafeRawPointer?.self)
}

@_silgen_name("td_vulkan_driver")
public func tdVulkanDriver(_ index: Int) -> (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?)? {
  guard index == 0 else { return nil }
  coreRegistered.lock.withLock {
    guard !coreRegistered.tried else { return }
    coreRegistered.tried = true
    if GPUContext.namespace == nil { GPUContext.namespace = Namespace.process }
    VulkanCoreDriver.connect = { openCoreDevice() }
  }
  return unsafe coreGetInstanceProcAddr
}
