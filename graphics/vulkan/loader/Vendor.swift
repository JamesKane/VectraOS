// SPDX-License-Identifier: BSD-3-Clause

// VK_VECTRA_window_surface (vulkansurface(2); D174, "Presentation, as designed"): ours, and not in vk.xml, so not
// generated. Three instance commands, given to the first driver that has them, with that driver's instance, as every
// instance-level trampoline does. vulkan_vectra.h declares them.

import TDVulkan

/// A driver's vendor command and its instance, the first driver that gives one out.
func loaderVendorCommand(_ instance: VkInstance?, _ name: StaticString) -> (PFN_vkVoidFunction, VkInstance?)? {
  guard let i = unsafe LoaderInstance.from(instance) else { return nil }
  for unsafe d in unsafe i.drivers {
    if let f = unsafe d.gipa(d.instance, loaderName(name)) { return unsafe (f, d.instance) }
  }
  return nil
}

@c(vkCreateVectraWindowSurface)
public func vkCreateVectraWindowSurface(_ instance: VkInstance?, _ pCreateInfo: UnsafePointer<VkVectraWindowSurfaceCreateInfo>?,
                                        _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                                        _ pSurface: UnsafeMutablePointer<VkSurfaceKHR?>?) -> VkResult
{
  guard let (f, driverInstance) = unsafe loaderVendorCommand(instance, "vkCreateVectraWindowSurface") else {
    return VK_ERROR_EXTENSION_NOT_PRESENT
  }
  return unsafe unsafeBitCast(f, to: PFN_vkCreateVectraWindowSurface.self)(driverInstance, pCreateInfo, pAllocator, pSurface)
}

@c(vkPollVectraWindowEventsVECTRA)
public func vkPollVectraWindowEventsVECTRA(_ instance: VkInstance?, _ surface: VkSurfaceKHR?,
                                           _ pEventCount: UnsafeMutablePointer<UInt32>?,
                                           _ pEvents: UnsafeMutablePointer<VkVectraWindowEventVECTRA>?) -> VkResult
{
  guard let (f, driverInstance) = unsafe loaderVendorCommand(instance, "vkPollVectraWindowEventsVECTRA") else {
    return VK_ERROR_EXTENSION_NOT_PRESENT
  }
  return unsafe unsafeBitCast(f, to: PFN_vkPollVectraWindowEventsVECTRA.self)(driverInstance, surface, pEventCount, pEvents)
}

@c(vkSetVectraWindowFullscreenVECTRA)
public func vkSetVectraWindowFullscreenVECTRA(_ instance: VkInstance?, _ surface: VkSurfaceKHR?, _ fullscreen: VkBool32) -> VkResult {
  guard let (f, driverInstance) = unsafe loaderVendorCommand(instance, "vkSetVectraWindowFullscreenVECTRA") else {
    return VK_ERROR_EXTENSION_NOT_PRESENT
  }
  return unsafe unsafeBitCast(f, to: PFN_vkSetVectraWindowFullscreenVECTRA.self)(driverInstance, surface, fullscreen)
}

/// The vendor commands the loader gives out by name (when a driver has them).
let loaderVendorNames: [StaticString] = [
  "vkCreateVectraWindowSurface", "vkPollVectraWindowEventsVECTRA", "vkSetVectraWindowFullscreenVECTRA",
]

func loaderVendorEntry(_ pName: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
  if unsafe equal(pName, "vkCreateVectraWindowSurface") {
    return unsafe unsafeBitCast(vkCreateVectraWindowSurface as PFN_vkCreateVectraWindowSurface, to: PFN_vkVoidFunction.self)
  }
  if unsafe equal(pName, "vkPollVectraWindowEventsVECTRA") {
    return unsafe unsafeBitCast(vkPollVectraWindowEventsVECTRA as PFN_vkPollVectraWindowEventsVECTRA, to: PFN_vkVoidFunction.self)
  }
  if unsafe equal(pName, "vkSetVectraWindowFullscreenVECTRA") {
    return unsafe unsafeBitCast(vkSetVectraWindowFullscreenVECTRA as PFN_vkSetVectraWindowFullscreenVECTRA, to: PFN_vkVoidFunction.self)
  }
  return nil
}
