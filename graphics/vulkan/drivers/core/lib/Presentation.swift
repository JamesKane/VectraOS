// SPDX-License-Identifier: BSD-3-Clause

// Presentation (D174, "Presentation, as designed"; vulkansurface(2), vulkancore(2)): VK_KHR_surface, VK_KHR_swapchain and
// our own VK_VECTRA_window_surface over the core.
//  - A surface is a window of Radharc's, opened by `vkCreateVectraWindowSurface` through `CoreDriver.windowSystem` (the
//    registry gives the SDK's; a test gives a fake). The layer never touches the SDK or a VMO itself.
//  - A swapchain is a ring of the core's present images (`GPUDevice.makePresentImage`): ordinary images the application
//    renders into, whose pages are given to the window as its images. Presenting one is the GPU's copy for the window (where
//    the device can't share the image's own pages), the wait for the GPU, and a present of that image of the window's.
//  - FIFO is the one present mode: the window's protocol has no way to replace a present Radharc has queued (MAILBOX), and
//    pacing is Radharc's: a present waits for the credit the last one's frame gives back.
//  - A window that changed size makes the swapchain out of date (`VK_ERROR_OUT_OF_DATE_KHR`); the application makes another
//    with `oldSwapchain`. A size is never stretched.

import GPUCore
import TDVulkan

// MARK: The window system the layer is given

/// What happened to a window, for `vkPollVectraWindowEventsVECTRA`.
public enum WindowEvent: Equatable, Sendable {
  case close
  /// The window's size in pixels is now this.
  case resize(width: Int32, height: Int32)
  case key(down: Bool, code: UInt32, character: UInt32, modifiers: UInt32)
  case pointer(x: Int32, y: Int32, button: UInt32, pressed: Bool)
  case wheel(x: Int32, y: Int32)
}

/// What presenting an image of a window came to.
public enum PresentOutcome: Equatable, Sendable {
  /// Taken: it is shown at the next vblank.
  case shown
  /// The window's size is not the image's.
  case outOfDate
  /// The window, or the compositor, is gone.
  case lost
}

/// A window a surface shows: the layer's view of the SDK's window, with the compositor's images in VMOs.
public protocol PresentWindow: AnyObject {
  /// The window's content size in pixels, as of the last `pump`.
  var width: Int32 { get }
  var height: Int32 { get }
  /// Takes what has arrived from the compositor (configures, frames, input), without blocking.
  func pump()
  /// Waits for something to arrive, for at most `nanoseconds`, and takes it.
  func wait(nanoseconds: UInt64)
  /// Gives the window an image of `width` by `height` pixels, `stride` pixels a row, in `vmo` (a handle: the window takes
  /// it, and closes it): the image's number, or nil if the compositor refused it.
  func addImage(vmo: UInt32, width: Int32, height: Int32, stride: Int32, premultiplied: Bool) -> UInt32?
  func removeImage(_ image: UInt32)
  /// Whether the compositor reads the image no more.
  func isFree(_ image: UInt32) -> Bool
  /// Shows the image, whole and drawn by the GPU already, at the next vblank. Waits for the window's credit first (the last
  /// present's frame). An image of another size than the window's is `outOfDate`.
  func present(_ image: UInt32) -> PresentOutcome
  /// The events that arrived and were not taken, oldest first.
  func takeEvents() -> [WindowEvent]
  /// Puts events back at the front (a poll that took fewer than there were, or only counted them).
  func requeue(_ events: [WindowEvent])
  /// The monotonic clock, in nanoseconds.
  func now() -> UInt64
  func setFullscreen(_ on: Bool)
  func close()
}

/// The desktop's windows.
public protocol WindowSystem: AnyObject {
  /// Opens a window `width` by `height` points titled `title`, once its first size is known; nil if there is no compositor.
  func open(title: String, width: Int32, height: Int32) -> (any PresentWindow)?
}

// MARK: Objects

final class SurfaceObject: CoreObject {
  let window: any PresentWindow
  /// The swapchain made last on it (the next `oldSwapchain` is this).
  var current: SwapchainObject?
  init(window: any PresentWindow) { self.window = window }
}

/// One image of a swapchain: the VkImage the application has, the core's frame behind it, and the window's number for it.
@safe struct SwapImage {
  var handle: OpaquePointer?
  var frame: PresentImage
  var window: UInt32
  /// The application holds it (acquired, not yet presented).
  var acquired = false
}

final class SwapchainObject: CoreObject {
  let device: DeviceObject
  let surface: SurfaceObject
  let width: Int32
  let height: Int32
  let format: PixelFormat
  var images: [SwapImage] = []
  /// Replaced by another swapchain on the surface, or out of date: it presents nothing more.
  var retired = false

  init(device: DeviceObject, surface: SurfaceObject, width: Int32, height: Int32, format: PixelFormat) {
    self.device = device
    self.surface = surface
    self.width = width
    self.height = height
    self.format = format
  }

  /// Whether the window is still the size this swapchain was made for.
  func matchesWindow() -> Bool {
    surface.window.pump()
    return surface.window.width == width && surface.window.height == height
  }

  /// Gives everything back: the images to the window and the device, once the GPU is past the work submitted.
  func release() {
    _ = device.waitIdle()
    for i in images {
      surface.window.removeImage(i.window)
      device.gpu.destroy(i.frame)
      unsafe Handle.destroy(i.handle)
    }
    images = []
  }
}

// MARK: Extensions

/// The instance extensions the layer has: the surface ones where there is a window system.
func instanceExtensions() -> [(name: String, version: UInt32)] {
  guard unsafe CoreDriver.windowSystem != nil else { return [] }
  return [("VK_KHR_surface", 25), ("VK_VECTRA_window_surface", 1)]
}

// MARK: Surfaces

private let vectraWindowSurfaceCreateInfoType = VkStructureType(rawValue: 1_899_999_000)

func core_vkCreateVectraWindowSurface(_ instance: VkInstance?, _ pCreateInfo: UnsafePointer<VkVectraWindowSurfaceCreateInfo>?,
                                      _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                                      _ pSurface: UnsafeMutablePointer<VkSurfaceKHR?>?) -> VkResult
{
  guard unsafe Handle.get(instance, InstanceObject.self) != nil, let info = unsafe pCreateInfo, let out = unsafe pSurface else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  guard let system = unsafe CoreDriver.windowSystem else { return VK_ERROR_EXTENSION_NOT_PRESENT }
  guard unsafe info.pointee.sType == vectraWindowSurfaceCreateInfoType, unsafe info.pointee.width > 0, unsafe info.pointee.height > 0
  else { return VK_ERROR_INITIALIZATION_FAILED }
  let title = unsafe info.pointee.pTitle.map { unsafe String(cString: $0) } ?? ""
  guard let window = system.open(title: title, width: Int32(truncatingIfNeeded: unsafe info.pointee.width),
                                 height: Int32(truncatingIfNeeded: unsafe info.pointee.height))
  else { return VK_ERROR_INITIALIZATION_FAILED }
  unsafe out.pointee = Handle.make(SurfaceObject(window: window))
  return VK_SUCCESS
}

func core_vkDestroySurfaceKHR(_ instance: VkInstance?, _ surface: VkSurfaceKHR?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let s = unsafe Handle.get(surface, SurfaceObject.self) else { return }
  s.window.close()
  unsafe Handle.destroy(surface)
}

func core_vkPollVectraWindowEventsVECTRA(_ instance: VkInstance?, _ surface: VkSurfaceKHR?, _ pEventCount: UnsafeMutablePointer<UInt32>?,
                                         _ pEvents: UnsafeMutablePointer<VkVectraWindowEventVECTRA>?) -> VkResult
{
  guard let s = unsafe Handle.get(surface, SurfaceObject.self), let count = unsafe pEventCount else { return VK_ERROR_SURFACE_LOST_KHR }
  s.window.pump()
  let events = s.window.takeEvents()
  guard let out = unsafe pEvents else {
    // Only the count: put them back for the call that takes them.
    s.window.requeue(events)
    unsafe count.pointee = UInt32(events.count)
    return VK_SUCCESS
  }
  let n = min(Int(unsafe count.pointee), events.count)
  for i in 0..<n {
    var e = VkVectraWindowEventVECTRA()
    switch events[i] {
    case .close: e.type = 1
    case .resize(let w, let h):
      e.type = 2
      e.x = w
      e.y = h
    case .key(let down, let code, let character, let modifiers):
      e.type = down ? 3 : 4
      e.keyCode = code
      e.character = character
      e.modifiers = modifiers
    case .pointer(let x, let y, let button, let pressed):
      e.type = 5
      e.x = x
      e.y = y
      e.button = button
      e.pressed = pressed ? 1 : 0
    case .wheel(let x, let y):
      e.type = 6
      e.x = x
      e.y = y
    }
    unsafe out[i] = e
  }
  if n < events.count { s.window.requeue(Array(events[n...])) }
  unsafe count.pointee = UInt32(n)
  return n < events.count ? VK_INCOMPLETE : VK_SUCCESS
}

func core_vkSetVectraWindowFullscreenVECTRA(_ instance: VkInstance?, _ surface: VkSurfaceKHR?, _ fullscreen: VkBool32) -> VkResult {
  guard let s = unsafe Handle.get(surface, SurfaceObject.self) else { return VK_ERROR_SURFACE_LOST_KHR }
  s.window.setFullscreen(fullscreen != 0)
  return VK_SUCCESS
}

// MARK: Surface queries

func core_vkGetPhysicalDeviceSurfaceSupportKHR(_ physicalDevice: VkPhysicalDevice?, _ queueFamilyIndex: UInt32, _ surface: VkSurfaceKHR?,
                                               _ pSupported: UnsafeMutablePointer<VkBool32>?) -> VkResult
{
  guard unsafe Handle.get(surface, SurfaceObject.self) != nil else { return VK_ERROR_SURFACE_LOST_KHR }
  unsafe pSupported?.pointee = queueFamilyIndex == 0 ? 1 : 0
  return VK_SUCCESS
}

func core_vkGetPhysicalDeviceSurfaceCapabilitiesKHR(_ physicalDevice: VkPhysicalDevice?, _ surface: VkSurfaceKHR?,
                                                    _ pSurfaceCapabilities: UnsafeMutablePointer<VkSurfaceCapabilitiesKHR>?) -> VkResult
{
  guard let s = unsafe Handle.get(surface, SurfaceObject.self), let phys = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self),
    let out = unsafe pSurfaceCapabilities
  else { return VK_ERROR_SURFACE_LOST_KHR }
  s.window.pump()
  let extent = VkExtent2D(width: UInt32(max(s.window.width, 1)), height: UInt32(max(s.window.height, 1)))
  var c = VkSurfaceCapabilitiesKHR()
  c.minImageCount = 2
  c.maxImageCount = UInt32(maxSwapchainImages)
  c.currentExtent = extent
  c.minImageExtent = VkExtent2D(width: 1, height: 1)
  c.maxImageExtent = VkExtent2D(width: UInt32(max(phys.gpu.limits.maxImageDimension, 1)), height: UInt32(max(phys.gpu.limits.maxImageDimension, 1)))
  c.maxImageArrayLayers = 1
  c.supportedTransforms = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR.rawValue
  c.currentTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR
  c.supportedCompositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR.rawValue | VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR.rawValue
  c.supportedUsageFlags = swapchainUsages(phys.gpu)
  unsafe out.pointee = c
  return VK_SUCCESS
}

/// What a swapchain's image may be used for: drawn into, sampled where the device can, and copied from and to.
func swapchainUsages(_ gpu: any GPUDevice) -> UInt32 {
  var u = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
  if gpu.limits.features.sampledImages { u |= VK_IMAGE_USAGE_SAMPLED_BIT.rawValue }
  return u
}

let maxSwapchainImages = 3

/// The surface's formats: the four-byte blue-first ones the window reads, where the device draws into them.
func surfaceFormats(_ gpu: any GPUDevice) -> [VkSurfaceFormatKHR] {
  var out: [VkSurfaceFormatKHR] = []
  if gpu.limits.formats(.bgra8).renderTarget { out.append(VkSurfaceFormatKHR(format: VK_FORMAT_B8G8R8A8_UNORM, colorSpace: VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)) }
  if gpu.limits.formats(.bgra8srgb).renderTarget { out.append(VkSurfaceFormatKHR(format: VK_FORMAT_B8G8R8A8_SRGB, colorSpace: VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)) }
  return out
}

func core_vkGetPhysicalDeviceSurfaceFormatsKHR(_ physicalDevice: VkPhysicalDevice?, _ surface: VkSurfaceKHR?,
                                               _ pSurfaceFormatCount: UnsafeMutablePointer<UInt32>?,
                                               _ pSurfaceFormats: UnsafeMutablePointer<VkSurfaceFormatKHR>?) -> VkResult
{
  guard unsafe Handle.get(surface, SurfaceObject.self) != nil, let phys = unsafe Handle.get(physicalDevice, PhysicalDeviceObject.self),
    let count = unsafe pSurfaceFormatCount
  else { return VK_ERROR_SURFACE_LOST_KHR }
  let formats = surfaceFormats(phys.gpu)
  guard let out = unsafe pSurfaceFormats else {
    unsafe count.pointee = UInt32(formats.count)
    return VK_SUCCESS
  }
  let n = min(Int(unsafe count.pointee), formats.count)
  for i in 0..<n { unsafe out[i] = formats[i] }
  unsafe count.pointee = UInt32(n)
  return n < formats.count ? VK_INCOMPLETE : VK_SUCCESS
}

func core_vkGetPhysicalDeviceSurfacePresentModesKHR(_ physicalDevice: VkPhysicalDevice?, _ surface: VkSurfaceKHR?,
                                                    _ pPresentModeCount: UnsafeMutablePointer<UInt32>?,
                                                    _ pPresentModes: UnsafeMutablePointer<VkPresentModeKHR>?) -> VkResult
{
  guard unsafe Handle.get(surface, SurfaceObject.self) != nil, let count = unsafe pPresentModeCount else { return VK_ERROR_SURFACE_LOST_KHR }
  guard let out = unsafe pPresentModes else {
    unsafe count.pointee = 1
    return VK_SUCCESS
  }
  if unsafe count.pointee == 0 { return VK_INCOMPLETE }
  unsafe out[0] = VK_PRESENT_MODE_FIFO_KHR
  unsafe count.pointee = 1
  return VK_SUCCESS
}

// MARK: Swapchains

func core_vkCreateSwapchainKHR(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkSwapchainCreateInfoKHR>?,
                               _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                               _ pSwapchain: UnsafeMutablePointer<VkSwapchainKHR?>?) -> VkResult
{
  guard let d = unsafe Handle.get(device, DeviceObject.self), let info = unsafe pCreateInfo, let out = unsafe pSwapchain,
    let surface = unsafe Handle.get(info.pointee.surface, SurfaceObject.self)
  else { return VK_ERROR_INITIALIZATION_FAILED }
  let imageFormat = unsafe info.pointee.imageFormat, colorSpace = unsafe info.pointee.imageColorSpace
  let layers = unsafe info.pointee.imageArrayLayers, mode = unsafe info.pointee.presentMode
  let alpha = unsafe info.pointee.compositeAlpha, transform = unsafe info.pointee.preTransform, flags = unsafe info.pointee.flags
  let usageBits = unsafe info.pointee.imageUsage, minCount = unsafe info.pointee.minImageCount
  let extent = unsafe info.pointee.imageExtent, oldSwapchain = unsafe info.pointee.oldSwapchain
  guard let format = pixelFormat(imageFormat), format == .bgra8 || format == .bgra8srgb,
    colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR, d.gpu.limits.formats(format).renderTarget
  else {
    say("unsupported: a swapchain of format \(imageFormat.rawValue)")
    return VK_ERROR_FORMAT_NOT_SUPPORTED
  }
  guard layers == 1, mode == VK_PRESENT_MODE_FIFO_KHR,
    alpha == VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR || alpha == VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
    transform == VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR || transform.rawValue == 0, flags == 0
  else {
    say("unsupported: a swapchain's layers, present mode (only FIFO), composite alpha, transform or flags")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  guard usageBits & ~swapchainUsages(d.gpu) == 0, let appUsage = imageUsage(usageBits, format: format, d.gpu) else {
    say("unsupported: a swapchain's image usage")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  // The window's size now; an extent of another size is the application's stale one.
  surface.window.pump()
  let width = Int32(truncatingIfNeeded: extent.width), height = Int32(truncatingIfNeeded: extent.height)
  guard width > 0, height > 0, width == surface.window.width, height == surface.window.height else {
    // The window changed size since the application asked: nothing to make, and the surface says what it is now.
    return VK_ERROR_INITIALIZATION_FAILED
  }
  let count = Int(min(max(minCount, 2), UInt32(maxSwapchainImages)))
  let premultiplied = alpha == VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR
  let usage = appUsage | .renderTarget | .copySource | (d.gpu.limits.features.sampledImages ? .sampled : ImageUsage(rawValue: 0))

  // The old swapchain stops presenting; its images stay with the window until it is destroyed.
  if let old = unsafe Handle.get(oldSwapchain, SwapchainObject.self) { old.retired = true }
  let swapchain = SwapchainObject(device: d, surface: surface, width: width, height: height, format: format)
  for _ in 0..<count {
    let frame: PresentImage
    do throws(GPUError) { frame = try d.gpu.makePresentImage(format: format, width: width, height: height, usage: usage) } catch {
      swapchain.release()
      return vkResult(error)
    }
    guard let vmo = frame.exportHandle(d.gpu) else {
      d.gpu.destroy(frame)
      swapchain.release()
      return VK_ERROR_INITIALIZATION_FAILED
    }
    guard let number = surface.window.addImage(vmo: vmo, width: width, height: height, stride: frame.stridePixels, premultiplied: premultiplied)
    else {
      d.gpu.destroy(frame)
      swapchain.release()
      return VK_ERROR_INITIALIZATION_FAILED
    }
    let handle = unsafe Handle.make(ImageObject(image: frame.image, device: d))
    swapchain.images.append(unsafe SwapImage(handle: handle, frame: frame, window: number))
  }
  surface.current = swapchain
  unsafe out.pointee = Handle.make(swapchain)
  return VK_SUCCESS
}

func core_vkDestroySwapchainKHR(_ device: VkDevice?, _ swapchain: VkSwapchainKHR?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let s = unsafe Handle.get(swapchain, SwapchainObject.self) else { return }
  s.release()
  if s.surface.current === s { s.surface.current = nil }
  unsafe Handle.destroy(swapchain)
}

func core_vkGetSwapchainImagesKHR(_ device: VkDevice?, _ swapchain: VkSwapchainKHR?, _ pSwapchainImageCount: UnsafeMutablePointer<UInt32>?,
                                  _ pSwapchainImages: UnsafeMutablePointer<VkImage?>?) -> VkResult
{
  guard let s = unsafe Handle.get(swapchain, SwapchainObject.self), let count = unsafe pSwapchainImageCount else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  guard let out = unsafe pSwapchainImages else {
    unsafe count.pointee = UInt32(s.images.count)
    return VK_SUCCESS
  }
  let n = min(Int(unsafe count.pointee), s.images.count)
  for i in 0..<n { unsafe out[i] = s.images[i].handle }
  unsafe count.pointee = UInt32(n)
  return n < s.images.count ? VK_INCOMPLETE : VK_SUCCESS
}

/// The next image the application may draw: one it doesn't hold that the compositor reads no more. A timeout of 0 only looks.
func acquireNext(_ s: SwapchainObject, timeout: UInt64, semaphore: VkSemaphore?, fence: VkFence?, index: UnsafeMutablePointer<UInt32>?) -> VkResult {
  if s.retired { return VK_ERROR_OUT_OF_DATE_KHR }
  if !s.matchesWindow() {
    s.retired = true
    return VK_ERROR_OUT_OF_DATE_KHR
  }
  let start = s.surface.window.now()
  while true {
    if let i = s.images.indices.first(where: { !s.images[$0].acquired && s.surface.window.isFree(s.images[$0].window) }) {
      s.images[i].acquired = true
      // Nothing of the GPU's is outstanding on a free image (a present waited for its copy): signalled already.
      if let sem = unsafe Handle.get(semaphore, SemaphoreObject.self) { sem.value = 0 }
      if let f = unsafe Handle.get(fence, FenceObject.self) {
        f.signaled = true
        f.value = 0
      }
      unsafe index?.pointee = UInt32(i)
      return VK_SUCCESS
    }
    if timeout == 0 { return VK_NOT_READY }
    let elapsed = s.surface.window.now() &- start
    if timeout != UInt64.max && elapsed >= timeout { return VK_TIMEOUT }
    s.surface.window.wait(nanoseconds: min(timeout == UInt64.max ? 4_000_000 : timeout - elapsed, 4_000_000))
    if !s.matchesWindow() {
      s.retired = true
      return VK_ERROR_OUT_OF_DATE_KHR
    }
  }
}

func core_vkAcquireNextImageKHR(_ device: VkDevice?, _ swapchain: VkSwapchainKHR?, _ timeout: UInt64, _ semaphore: VkSemaphore?,
                                _ fence: VkFence?, _ pImageIndex: UnsafeMutablePointer<UInt32>?) -> VkResult
{
  guard let s = unsafe Handle.get(swapchain, SwapchainObject.self) else { return VK_ERROR_SURFACE_LOST_KHR }
  return unsafe acquireNext(s, timeout: timeout, semaphore: semaphore, fence: fence, index: pImageIndex)
}

func core_vkAcquireNextImage2KHR(_ device: VkDevice?, _ pAcquireInfo: UnsafePointer<VkAcquireNextImageInfoKHR>?,
                                 _ pImageIndex: UnsafeMutablePointer<UInt32>?) -> VkResult
{
  guard let info = unsafe pAcquireInfo, let s = unsafe Handle.get(info.pointee.swapchain, SwapchainObject.self) else {
    return VK_ERROR_SURFACE_LOST_KHR
  }
  return unsafe acquireNext(s, timeout: info.pointee.timeout, semaphore: info.pointee.semaphore, fence: info.pointee.fence, index: pImageIndex)
}

/// Presents image `index`: the GPU's copy for the window if the device needs one, the wait for it, and the window's present.
func presentImage(_ q: QueueObject, _ s: SwapchainObject, index: Int, wait: UInt64) -> VkResult {
  let d = q.device
  if s.retired { return VK_ERROR_OUT_OF_DATE_KHR }
  guard index < s.images.count, s.images[index].acquired else { return VK_ERROR_INITIALIZATION_FAILED }
  // A window that changed size since the image was acquired still takes it, shown at its own size and never stretched; the
  // application is told to make another swapchain.
  let stale = !s.matchesWindow()
  let frame = s.images[index].frame
  // The GPU's work, and the copy that puts the frame where Radharc reads it.
  do throws(GPUError) {
    var list = GPUCommandList()
    frame.recordPresent(into: &list)
    if list.commands.isEmpty {
      if wait > 0 { try d.gpu.wait(wait) }
    } else {
      let signal = d.nextValue()
      try d.gpu.graphicsQueue.submit(list, wait: wait, signal: signal)
      d.lastSubmitted = signal
      try d.gpu.wait(signal)
    }
  } catch { return vkResult(error) }
  d.retire()
  s.images[index].acquired = false
  switch s.surface.window.present(s.images[index].window) {
  case .shown: return stale ? VK_SUBOPTIMAL_KHR : VK_SUCCESS
  case .outOfDate:
    s.retired = true
    return VK_ERROR_OUT_OF_DATE_KHR
  case .lost: return VK_ERROR_SURFACE_LOST_KHR
  }
}

func core_vkQueuePresentKHR(_ queue: VkQueue?, _ pPresentInfo: UnsafePointer<VkPresentInfoKHR>?) -> VkResult {
  guard let q = unsafe Handle.get(queue, QueueObject.self), let info = unsafe pPresentInfo else { return VK_ERROR_DEVICE_LOST }
  // What the images were drawn after: the device value of the latest semaphore.
  var wait: UInt64 = 0
  for k in 0..<Int(unsafe info.pointee.waitSemaphoreCount) {
    guard let sem = unsafe Handle.get(info.pointee.pWaitSemaphores[k], SemaphoreObject.self), !sem.timeline else {
      return VK_ERROR_INITIALIZATION_FAILED
    }
    wait = max(wait, sem.value)
    sem.value = 0
  }
  var overall = VK_SUCCESS
  for i in 0..<Int(unsafe info.pointee.swapchainCount) {
    guard let s = unsafe Handle.get(info.pointee.pSwapchains[i], SwapchainObject.self) else { return VK_ERROR_SURFACE_LOST_KHR }
    let r = presentImage(q, s, index: Int(unsafe info.pointee.pImageIndices[i]), wait: wait)
    if let results = unsafe info.pointee.pResults { unsafe results[i] = r }
    if r.rawValue < 0, overall.rawValue >= 0 { overall = r } else if r == VK_SUBOPTIMAL_KHR, overall == VK_SUCCESS { overall = r }
  }
  return overall
}
