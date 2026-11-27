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
//  - A headless surface (VK_EXT_headless_surface) has no window: its swapchain is a ring of plain images of any size, shown
//    nowhere, an image free again once the GPU is past the work its present waited for; FIFO, MAILBOX and IMMEDIATE are one.

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
  /// it, and closes it): the image's number, or nil if the compositor refused it. `acquire`: a counter that tracks the
  /// device's timeline (`GPUDevice.timelineHandle`, which the window takes too), read as the image's acquire counter; nil,
  /// and the window keeps its own.
  func addImage(vmo: UInt32, width: Int32, height: Int32, stride: Int32, premultiplied: Bool, acquire: UInt32?) -> UInt32?
  func removeImage(_ image: UInt32)
  /// Whether the compositor reads the image no more.
  func isFree(_ image: UInt32) -> Bool
  /// Shows the image at the next vblank at which it is drawn: drawn by the GPU already, or (an image given `acquire`) once
  /// the device's timeline reaches `drawnAt`. Waits for the window's credit first (the last present's frame). An image of
  /// another size than the window's is `outOfDate`.
  func present(_ image: UInt32, drawnAt: UInt64?) -> PresentOutcome
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
  /// The window it shows; nil for a headless surface (VK_EXT_headless_surface), whose images are drawn and never shown.
  let window: (any PresentWindow)?
  /// The swapchain made last on it (the next `oldSwapchain` is this).
  var current: SwapchainObject?
  init(window: (any PresentWindow)?) { self.window = window }
}

/// One image of a swapchain: the VkImage the application has, the core's image behind it, and, for a window, the frame that
/// carries it there and the window's number for it.
@safe struct SwapImage {
  var handle: OpaquePointer?
  var image: GPUImage
  /// Nil on a headless surface: the image is the core's alone.
  var frame: PresentImage?
  var window: UInt32
  /// The window reads the device's timeline as its acquire counter: a present names the value, and nothing waits for it.
  var timeline = false
  /// The application holds it (acquired, not yet presented).
  var acquired = false
  /// The timeline value of the work its last present waited for (a headless surface's): it is free once the timeline is there.
  var drawn: UInt64 = 0
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

  /// Whether the window is still the size this swapchain was made for (a headless surface's always is).
  func matchesWindow() -> Bool {
    guard let window = surface.window else { return true }
    window.pump()
    return window.width == width && window.height == height
  }

  /// Gives everything back: the images to the window and the device, once the GPU is past the work submitted.
  func release() {
    _ = device.waitIdle()
    for i in images {
      surface.window?.removeImage(i.window)
      if let frame = i.frame { device.gpu.destroy(frame) } else { device.gpu.destroy(i.image) }
      unsafe Handle.destroy(i.handle)
    }
    images = []
  }
}

// MARK: Extensions

/// The instance extensions the layer has: a surface, headless always and a window's where there is a window system.
func instanceExtensions() -> [(name: String, version: UInt32)] {
  var out: [(name: String, version: UInt32)] = [("VK_KHR_surface", 25)]
  if unsafe CoreDriver.windowSystem != nil { out.append(("VK_VECTRA_window_surface", 1)) }
  out.append(("VK_EXT_headless_surface", 1))
  return out
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

/// A surface with no window (VK_EXT_headless_surface): its swapchains' images are drawn, presented and never shown, and
/// need no compositor.
func core_vkCreateHeadlessSurfaceEXT(_ instance: VkInstance?, _ pCreateInfo: UnsafePointer<VkHeadlessSurfaceCreateInfoEXT>?,
                                     _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                                     _ pSurface: UnsafeMutablePointer<VkSurfaceKHR?>?) -> VkResult
{
  guard unsafe Handle.get(instance, InstanceObject.self) != nil, let info = unsafe pCreateInfo, let out = unsafe pSurface,
    unsafe info.pointee.sType == VK_STRUCTURE_TYPE_HEADLESS_SURFACE_CREATE_INFO_EXT
  else { return VK_ERROR_INITIALIZATION_FAILED }
  unsafe out.pointee = Handle.make(SurfaceObject(window: nil))
  return VK_SUCCESS
}

func core_vkDestroySurfaceKHR(_ instance: VkInstance?, _ surface: VkSurfaceKHR?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  guard let s = unsafe Handle.get(surface, SurfaceObject.self) else { return }
  s.window?.close()
  unsafe Handle.destroy(surface)
}

func core_vkPollVectraWindowEventsVECTRA(_ instance: VkInstance?, _ surface: VkSurfaceKHR?, _ pEventCount: UnsafeMutablePointer<UInt32>?,
                                         _ pEvents: UnsafeMutablePointer<VkVectraWindowEventVECTRA>?) -> VkResult
{
  guard let s = unsafe Handle.get(surface, SurfaceObject.self), let count = unsafe pEventCount else { return VK_ERROR_SURFACE_LOST_KHR }
  // A headless surface has no events.
  guard let window = s.window else {
    unsafe count.pointee = 0
    return VK_SUCCESS
  }
  window.pump()
  let events = window.takeEvents()
  guard let out = unsafe pEvents else {
    // Only the count: put them back for the call that takes them.
    window.requeue(events)
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
  if n < events.count { window.requeue(Array(events[n...])) }
  unsafe count.pointee = UInt32(n)
  return n < events.count ? VK_INCOMPLETE : VK_SUCCESS
}

func core_vkSetVectraWindowFullscreenVECTRA(_ instance: VkInstance?, _ surface: VkSurfaceKHR?, _ fullscreen: VkBool32) -> VkResult {
  guard let s = unsafe Handle.get(surface, SurfaceObject.self) else { return VK_ERROR_SURFACE_LOST_KHR }
  s.window?.setFullscreen(fullscreen != 0)
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
  // A window's size; a headless surface has none, and its swapchain's extent is its size (the special value).
  var extent = VkExtent2D(width: UInt32.max, height: UInt32.max)
  if let window = s.window {
    window.pump()
    extent = VkExtent2D(width: UInt32(max(window.width, 1)), height: UInt32(max(window.height, 1)))
  }
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
  guard let s = unsafe Handle.get(surface, SurfaceObject.self), let count = unsafe pPresentModeCount else { return VK_ERROR_SURFACE_LOST_KHR }
  let modes = presentModes(s)
  guard let out = unsafe pPresentModes else {
    unsafe count.pointee = UInt32(modes.count)
    return VK_SUCCESS
  }
  let n = min(Int(unsafe count.pointee), modes.count)
  for i in 0..<n { unsafe out[i] = modes[i] }
  unsafe count.pointee = UInt32(n)
  return n < modes.count ? VK_INCOMPLETE : VK_SUCCESS
}

/// A window's one present mode is FIFO, paced by Radharc. A headless surface shows nothing, so nothing waits for a display:
/// FIFO, MAILBOX and IMMEDIATE are the same there, and a present only marks the image free once the GPU is done with it.
func presentModes(_ s: SurfaceObject) -> [VkPresentModeKHR] {
  if s.window == nil { return [VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_IMMEDIATE_KHR] }
  return [VK_PRESENT_MODE_FIFO_KHR]
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
  guard layers == 1, presentModes(surface).contains(mode),
    alpha == VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR || alpha == VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
    transform == VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR || transform.rawValue == 0, flags == 0
  else {
    say("unsupported: a swapchain's layers, present mode (a window's is FIFO only), composite alpha, transform or flags")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  guard usageBits & ~swapchainUsages(d.gpu) == 0, let appUsage = imageUsage(usageBits, format: format, d.gpu) else {
    say("unsupported: a swapchain's image usage")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  // The window's size now; an extent of another size is the application's stale one. A headless surface takes any.
  let width = Int32(truncatingIfNeeded: extent.width), height = Int32(truncatingIfNeeded: extent.height)
  guard width > 0, height > 0, width <= d.gpu.limits.maxImageDimension, height <= d.gpu.limits.maxImageDimension else {
    return VK_ERROR_INITIALIZATION_FAILED
  }
  if let window = surface.window {
    window.pump()
    guard width == window.width, height == window.height else {
      // The window changed size since the application asked: nothing to make, and the surface says what it is now.
      return VK_ERROR_INITIALIZATION_FAILED
    }
  }
  let count = Int(min(max(minCount, 2), UInt32(maxSwapchainImages)))
  let premultiplied = alpha == VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR
  let usage = appUsage | .renderTarget | .copySource | (d.gpu.limits.features.sampledImages ? .sampled : ImageUsage(rawValue: 0))

  // The old swapchain stops presenting; its images stay with the window until it is destroyed.
  if let old = unsafe Handle.get(oldSwapchain, SwapchainObject.self) { old.retired = true }
  let swapchain = SwapchainObject(device: d, surface: surface, width: width, height: height, format: format)
  for _ in 0..<count {
    guard let window = surface.window else {
      // Headless: an ordinary image of the core's, shown nowhere.
      let image: GPUImage
      do throws(GPUError) {
        image = try d.gpu.makeImage(ImageDescriptor(format: format, width: width, height: height, usage: usage))
      } catch {
        swapchain.release()
        return vkResult(error)
      }
      let handle = unsafe Handle.make(ImageObject(image: image, device: d))
      swapchain.images.append(unsafe SwapImage(handle: handle, image: image, frame: nil, window: 0))
      continue
    }
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
    let timeline = d.gpu.timelineHandle()
    guard let number = window.addImage(vmo: vmo, width: width, height: height, stride: frame.stridePixels,
                                       premultiplied: premultiplied, acquire: timeline)
    else {
      d.gpu.destroy(frame)
      swapchain.release()
      return VK_ERROR_INITIALIZATION_FAILED
    }
    let handle = unsafe Handle.make(ImageObject(image: frame.image, device: d))
    swapchain.images.append(unsafe SwapImage(handle: handle, image: frame.image, frame: frame, window: number, timeline: timeline != nil))
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
  guard let window = s.surface.window else { return unsafe acquireHeadless(s, semaphore: semaphore, fence: fence, index: index) }
  let start = window.now()
  while true {
    if let i = s.images.indices.first(where: { !s.images[$0].acquired && window.isFree(s.images[$0].window) }) {
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
    let elapsed = window.now() &- start
    if timeout != UInt64.max && elapsed >= timeout { return VK_TIMEOUT }
    window.wait(nanoseconds: min(timeout == UInt64.max ? 4_000_000 : timeout - elapsed, 4_000_000))
    if !s.matchesWindow() {
      s.retired = true
      return VK_ERROR_OUT_OF_DATE_KHR
    }
  }
}

/// A headless swapchain's next image: of those the application doesn't hold, the one presented longest ago. Nothing reads it
/// but the GPU, so it is acquired at once, and the semaphore and fence are signalled when the timeline reaches the work its
/// last present waited for: the next frame's work waits for it on the GPU, and the application's fence, on the CPU.
func acquireHeadless(_ s: SwapchainObject, semaphore: VkSemaphore?, fence: VkFence?, index: UnsafeMutablePointer<UInt32>?) -> VkResult {
  guard let i = s.images.indices.filter({ !s.images[$0].acquired }).min(by: { s.images[$0].drawn < s.images[$1].drawn }) else {
    return VK_NOT_READY
  }
  s.images[i].acquired = true
  let drawn = s.images[i].drawn
  let done = drawn == 0 || s.device.gpu.completed >= drawn
  if let sem = unsafe Handle.get(semaphore, SemaphoreObject.self) { sem.value = done ? 0 : drawn }
  if let f = unsafe Handle.get(fence, FenceObject.self) {
    f.signaled = done
    f.value = done ? 0 : drawn
  }
  unsafe index?.pointee = UInt32(i)
  return VK_SUCCESS
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
  // Headless: shown nowhere, and nothing waits. The image is free again once the timeline reaches the work presented (all
  // submitted so far, if the present waited for no semaphore).
  guard let window = s.surface.window, let frame = s.images[index].frame else {
    s.images[index].drawn = wait > 0 ? wait : d.lastSubmitted
    s.images[index].acquired = false
    d.retire()
    return VK_SUCCESS
  }
  // A window that changed size since the image was acquired still takes it, shown at its own size and never stretched; the
  // application is told to make another swapchain.
  let stale = !s.matchesWindow()
  let timeline = s.images[index].timeline
  // The GPU's work, and the copy that puts the frame where Radharc reads it; the CPU waits for them only where the window
  // can't read the device's timeline as the image's acquire counter.
  var drawn = wait
  do throws(GPUError) {
    var list = GPUCommandList()
    frame.recordPresent(into: &list)
    if !list.commands.isEmpty {
      let signal = d.nextValue()
      try d.gpu.graphicsQueue.submit(list, wait: wait, signal: signal)
      d.lastSubmitted = signal
      drawn = signal
    }
    if !timeline && drawn > 0 { try d.gpu.wait(drawn) }
  } catch { return vkResult(error) }
  d.retire()
  s.images[index].acquired = false
  let outcome = window.present(s.images[index].window, drawnAt: timeline ? drawn : nil)
  // An image the window did not take is free at once: the GPU must be done with it first.
  if outcome != .shown, timeline, drawn > 0 { try? d.gpu.wait(drawn) }
  switch outcome {
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
