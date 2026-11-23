// SPDX-License-Identifier: BSD-3-Clause

// The layer's presentation (D174, "Presentation, as designed"): VK_KHR_surface, VK_KHR_swapchain and the window surface,
// over the fake core device and a fake window system that keeps the order of what the layer does to a window: the images it
// is given, its presents, the credits it waits for, and what it takes back. What the real window system does with the same
// calls is boot-venus's vulkan-present.

import GPUCore
import Testing
import TDVulkan
@testable import VulkanCoreDriver

/// A window that models the compositor's side: one present may be queued, a vblank shows it (and frees the image it
/// replaces), and a present made while one is queued waits for that vblank first (Radharc's credit).
final class FakeWindow: PresentWindow {
  var width: Int32
  var height: Int32
  var images: [UInt32: (vmo: UInt32, width: Int32, height: Int32, stride: Int32, premultiplied: Bool)] = [:]
  /// The timeline counters images were given as acquire counters, and the values presents named.
  var acquires: [UInt32: UInt32] = [:]
  var drawnAts: [UInt64] = []
  var nextImage: UInt32 = 1
  var pending: UInt32?
  var shown: UInt32?
  var log: [String] = []
  var creditWaits = 0
  var waits = 0
  var events: [WindowEvent] = []
  var closed = false
  var fullscreen = false
  var clock: UInt64 = 0
  /// A size to take at the next `pump`: a resize the user made.
  var resizeTo: (Int32, Int32)?
  var refuse = false
  /// The compositor shows nothing (a window nobody can see: Radharc latches a hidden window's presents about once a second).
  var stall = false

  init(width: Int32, height: Int32) {
    self.width = width
    self.height = height
  }

  func pump() {
    if let (w, h) = resizeTo {
      resizeTo = nil
      width = w
      height = h
      events.append(.resize(width: w, height: h))
    }
  }

  /// The vblank: the queued present is on the glass, and the one it replaced is free.
  func vblank() {
    guard let p = pending else { return }
    log.append("shown \(p)")
    shown = p
    pending = nil
  }

  func wait(nanoseconds: UInt64) {
    waits += 1
    clock += nanoseconds
    if !stall { vblank() }
  }

  func addImage(vmo: UInt32, width: Int32, height: Int32, stride: Int32, premultiplied: Bool, acquire: UInt32?) -> UInt32? {
    if refuse { return nil }
    let n = nextImage
    nextImage += 1
    images[n] = (vmo, width, height, stride, premultiplied)
    if let acquire { acquires[n] = acquire }
    log.append("add \(n)")
    return n
  }

  func removeImage(_ image: UInt32) {
    images[image] = nil
    log.append("remove \(image)")
  }

  func isFree(_ image: UInt32) -> Bool { image != pending && image != shown }

  func present(_ image: UInt32, drawnAt: UInt64?) -> PresentOutcome {
    if let drawnAt { drawnAts.append(drawnAt) }
    if pending != nil {
      creditWaits += 1
      vblank()
    }
    pending = image
    log.append("present \(image)")
    return .shown
  }

  func takeEvents() -> [WindowEvent] {
    defer { events = [] }
    return events
  }

  func requeue(_ e: [WindowEvent]) { events = e + events }
  func now() -> UInt64 { clock }
  func setFullscreen(_ on: Bool) {
    fullscreen = on
    resizeTo = on ? (1920, 1080) : (640, 480)
  }
  func close() { closed = true }
}

final class FakeWindowSystem: WindowSystem {
  var windows: [FakeWindow] = []
  var opened: [(title: String, width: Int32, height: Int32)] = []
  var width: Int32 = 640, height: Int32 = 480
  var none = false
  func open(title: String, width: Int32, height: Int32) -> (any PresentWindow)? {
    if none { return nil }
    opened.append((title, width, height))
    let w = FakeWindow(width: self.width, height: self.height)
    windows.append(w)
    return w
  }
}

/// An application with a window of the fake system.
final class Presenter {
  let vk: VK
  let system = FakeWindowSystem()
  var surface: VkSurfaceKHR?
  var window: FakeWindow { system.windows[0] }

  init(gpu: FakeGPU = FakeGPU()) {
    CoreDriver.windowSystem = system
    vk = VK(gpu: gpu)
    var title = Array("present test".utf8CString)
    title.withUnsafeMutableBufferPointer { t in
      var info = VkVectraWindowSurfaceCreateInfo()
      info.sType = VkStructureType(rawValue: 1_899_999_000)
      info.pTitle = UnsafePointer(t.baseAddress)
      info.width = 640
      info.height = 480
      let r = vk.fn("vkCreateVectraWindowSurface", PFN_vkCreateVectraWindowSurface.self)(vk.instance, &info, nil, &surface)
      precondition(r == VK_SUCCESS, "vkCreateVectraWindowSurface \(r)")
    }
  }

  deinit { CoreDriver.windowSystem = nil }

  func swapchain(format: VkFormat = VK_FORMAT_B8G8R8A8_SRGB, count: UInt32 = 3, extent: (UInt32, UInt32)? = nil,
                 old: VkSwapchainKHR? = nil, alpha: VkCompositeAlphaFlagBitsKHR = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
                 mode: VkPresentModeKHR = VK_PRESENT_MODE_FIFO_KHR) -> (VkResult, VkSwapchainKHR?) {
    var info = VkSwapchainCreateInfoKHR()
    info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
    info.surface = surface
    info.minImageCount = count
    info.imageFormat = format
    info.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
    info.imageExtent = VkExtent2D(width: extent?.0 ?? UInt32(window.width), height: extent?.1 ?? UInt32(window.height))
    info.imageArrayLayers = 1
    info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
    info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
    info.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR
    info.compositeAlpha = alpha
    info.presentMode = mode
    info.oldSwapchain = old
    var s: VkSwapchainKHR?
    let r = vk.fn("vkCreateSwapchainKHR", PFN_vkCreateSwapchainKHR.self)(vk.device, &info, nil, &s)
    return (r, s)
  }

  func acquire(_ s: VkSwapchainKHR?, timeout: UInt64 = 0, semaphore: VkSemaphore? = nil, fence: VkFence? = nil) -> (VkResult, UInt32) {
    var i: UInt32 = 99
    let r = vk.fn("vkAcquireNextImageKHR", PFN_vkAcquireNextImageKHR.self)(vk.device, s, timeout, semaphore, fence, &i)
    return (r, i)
  }

  func present(_ s: VkSwapchainKHR?, _ index: UInt32, wait: [VkSemaphore?] = []) -> VkResult {
    var sc: [VkSwapchainKHR?] = [s]
    var idx = [index]
    var result = VK_SUCCESS
    var w = wait
    var info = VkPresentInfoKHR()
    info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
    info.waitSemaphoreCount = UInt32(w.count)
    info.swapchainCount = 1
    return withUnsafeMutablePointer(to: &result) { rp in
      info.pResults = rp
      return w.withUnsafeMutableBufferPointer { wp in
        info.pWaitSemaphores = UnsafePointer(wp.baseAddress)
        return sc.withUnsafeMutableBufferPointer { sp in
          info.pSwapchains = UnsafePointer(sp.baseAddress)
          return idx.withUnsafeMutableBufferPointer { ip in
            info.pImageIndices = UnsafePointer(ip.baseAddress)
            let r = vk.fn("vkQueuePresentKHR", PFN_vkQueuePresentKHR.self)(vk.queue, &info)
            precondition(rp.pointee == r || r != VK_SUCCESS, "pResults")
            return r
          }
        }
      }
    }
  }

  func images(_ s: VkSwapchainKHR?) -> [VkImage?] {
    var n: UInt32 = 0
    _ = vk.fn("vkGetSwapchainImagesKHR", PFN_vkGetSwapchainImagesKHR.self)(vk.device, s, &n, nil)
    var out = [VkImage?](repeating: nil, count: Int(n))
    _ = vk.fn("vkGetSwapchainImagesKHR", PFN_vkGetSwapchainImagesKHR.self)(vk.device, s, &n, &out)
    return out
  }

  func destroy(_ s: VkSwapchainKHR?) { vk.fn("vkDestroySwapchainKHR", PFN_vkDestroySwapchainKHR.self)(vk.device, s, nil) }
}

extension VulkanCoreDriverTests {
  @Test func theSurfaceIsTheWindowsAndSaysWhatItCan() throws {
    let p = Presenter()
    #expect(p.system.opened.count == 1 && p.system.opened[0].title == "present test")
    #expect(p.system.opened[0].width == 640 && p.system.opened[0].height == 480)
    var caps = VkSurfaceCapabilitiesKHR()
    #expect(p.vk.fn("vkGetPhysicalDeviceSurfaceCapabilitiesKHR", PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR.self)(p.vk.physical, p.surface, &caps) == VK_SUCCESS)
    #expect(caps.currentExtent.width == 640 && caps.currentExtent.height == 480)
    #expect(caps.minImageCount == 2 && caps.maxImageCount == 3)
    #expect(caps.supportedCompositeAlpha == VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR.rawValue | VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR.rawValue)
    #expect(caps.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue != 0)
    var n: UInt32 = 0
    #expect(p.vk.fn("vkGetPhysicalDeviceSurfaceFormatsKHR", PFN_vkGetPhysicalDeviceSurfaceFormatsKHR.self)(p.vk.physical, p.surface, &n, nil) == VK_SUCCESS)
    var formats = [VkSurfaceFormatKHR](repeating: VkSurfaceFormatKHR(), count: Int(n))
    _ = p.vk.fn("vkGetPhysicalDeviceSurfaceFormatsKHR", PFN_vkGetPhysicalDeviceSurfaceFormatsKHR.self)(p.vk.physical, p.surface, &n, &formats)
    #expect(formats.map { $0.format } == [VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_SRGB])
    var modes = 0 as UInt32
    #expect(p.vk.fn("vkGetPhysicalDeviceSurfacePresentModesKHR", PFN_vkGetPhysicalDeviceSurfacePresentModesKHR.self)(p.vk.physical, p.surface, &modes, nil) == VK_SUCCESS)
    var mode = VK_PRESENT_MODE_IMMEDIATE_KHR
    modes = 1
    _ = p.vk.fn("vkGetPhysicalDeviceSurfacePresentModesKHR", PFN_vkGetPhysicalDeviceSurfacePresentModesKHR.self)(p.vk.physical, p.surface, &modes, &mode)
    #expect(modes == 1 && mode == VK_PRESENT_MODE_FIFO_KHR)
    var supported: VkBool32 = 0
    _ = p.vk.fn("vkGetPhysicalDeviceSurfaceSupportKHR", PFN_vkGetPhysicalDeviceSurfaceSupportKHR.self)(p.vk.physical, 0, p.surface, &supported)
    #expect(supported == 1)
  }

  @Test func theExtensionsAreThereOnlyWhereThereIsAWindowSystem() throws {
    do {
      let p = Presenter()
      var n: UInt32 = 0
      _ = p.vk.fn("vkEnumerateInstanceExtensionProperties", PFN_vkEnumerateInstanceExtensionProperties.self)(nil, &n, nil)
      #expect(n == 2)
      var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(n))
      _ = p.vk.fn("vkEnumerateInstanceExtensionProperties", PFN_vkEnumerateInstanceExtensionProperties.self)(nil, &n, &props)
      let names = props.map { e in withUnsafeBytes(of: e.extensionName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
      #expect(names == ["VK_KHR_surface", "VK_VECTRA_window_surface"])
      var d: UInt32 = 0
      _ = p.vk.fn("vkEnumerateDeviceExtensionProperties", PFN_vkEnumerateDeviceExtensionProperties.self)(p.vk.physical, nil, &d, nil)
      var dev = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(d))
      _ = p.vk.fn("vkEnumerateDeviceExtensionProperties", PFN_vkEnumerateDeviceExtensionProperties.self)(p.vk.physical, nil, &d, &dev)
      let devNames = dev.map { e in withUnsafeBytes(of: e.extensionName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
      #expect(devNames.contains("VK_KHR_swapchain"))
    }
    let vk = VK()
    var n: UInt32 = 7
    _ = vk.fn("vkEnumerateInstanceExtensionProperties", PFN_vkEnumerateInstanceExtensionProperties.self)(nil, &n, nil)
    #expect(n == 0)
    var surface: VkSurfaceKHR?
    var info = VkVectraWindowSurfaceCreateInfo()
    info.sType = VkStructureType(rawValue: 1_899_999_000)
    info.width = 8
    info.height = 8
    #expect(vk.fn("vkCreateVectraWindowSurface", PFN_vkCreateVectraWindowSurface.self)(vk.instance, &info, nil, &surface) == VK_ERROR_EXTENSION_NOT_PRESENT)
  }

  @Test func noCompositorIsAFailureToInitialize() throws {
    let system = FakeWindowSystem()
    system.none = true
    CoreDriver.windowSystem = system
    defer { CoreDriver.windowSystem = nil }
    let vk = VK()
    var surface: VkSurfaceKHR?
    var info = VkVectraWindowSurfaceCreateInfo()
    info.sType = VkStructureType(rawValue: 1_899_999_000)
    info.width = 8
    info.height = 8
    #expect(vk.fn("vkCreateVectraWindowSurface", PFN_vkCreateVectraWindowSurface.self)(vk.instance, &info, nil, &surface) == VK_ERROR_INITIALIZATION_FAILED)
  }

  @Test func aSwapchainIsTheCoresPresentImagesGivenToTheWindow() throws {
    let p = Presenter()
    let (r, s) = p.swapchain(count: 3)
    #expect(r == VK_SUCCESS)
    let images = p.images(s)
    #expect(images.count == 3)
    // The window was given three images of the window's size, tightly packed, each the VMO of the device's staging memory
    // (the fake exports memory, not images), one handle apiece.
    #expect(p.window.images.count == 3)
    #expect(p.window.images.values.allSatisfy { $0.width == 640 && $0.height == 480 && $0.stride == 640 && !$0.premultiplied })
    #expect(Set(p.window.images.values.map { $0.vmo }).count == 3)
    #expect(p.vk.gpu.exportedHandles.count == 3)
    // Each image is an ordinary core image to draw into and copy from; the staging buffer holds a frame.
    let made = p.vk.gpu.images
    #expect(made.count == 3 && made.allSatisfy { $0.descriptor.format == .bgra8srgb })
    #expect(made.allSatisfy { $0.descriptor.usage.contains(.renderTarget) && $0.descriptor.usage.contains(.copySource) })
    #expect(p.vk.gpu.allocations.filter { $0.size == 640 * 480 * 4 }.count == 3)
    p.destroy(s)
    #expect(p.window.images.isEmpty)
    #expect(p.vk.gpu.destroyedImages.count == 3 && p.vk.gpu.freedMemory.count == 3)
  }

  @Test func aSwapchainWithPremultipliedAlphaTagsItsImages() throws {
    let p = Presenter()
    let (r, s) = p.swapchain(alpha: VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR)
    #expect(r == VK_SUCCESS)
    #expect(p.window.images.values.allSatisfy { $0.premultiplied })
    p.destroy(s)
  }

  @Test func whatTheSwapchainCantDoIsRefused() throws {
    let p = Presenter()
    #expect(p.swapchain(format: VK_FORMAT_R8G8B8A8_UNORM).0 == VK_ERROR_FORMAT_NOT_SUPPORTED)
    #expect(p.swapchain(mode: VK_PRESENT_MODE_MAILBOX_KHR).0 == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(p.swapchain(mode: VK_PRESENT_MODE_IMMEDIATE_KHR).0 == VK_ERROR_FEATURE_NOT_PRESENT)
    #expect(p.swapchain(extent: (100, 100)).0 == VK_ERROR_INITIALIZATION_FAILED)
    p.window.refuse = true
    #expect(p.swapchain().0 == VK_ERROR_INITIALIZATION_FAILED)
    // Nothing was kept of the failed ones.
    #expect(p.window.images.isEmpty)
    // A device that can share neither images nor memory can't present.
    let gpu = FakeGPU()
    gpu.exportsMemory = false
    let q = Presenter(gpu: gpu)
    #expect(q.swapchain().0 == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  @Test func acquirePresentAndReleaseKeepTheirOrder() throws {
    let p = Presenter()
    let (_, s) = p.swapchain(count: 3)
    // Three images to draw, then none: the compositor holds nothing, but the application does.
    let a = p.acquire(s), b = p.acquire(s), c = p.acquire(s)
    #expect(a.0 == VK_SUCCESS && b.0 == VK_SUCCESS && c.0 == VK_SUCCESS)
    #expect(Set([a.1, b.1, c.1]) == [0, 1, 2])
    #expect(p.acquire(s).0 == VK_NOT_READY)
    // The first image is drawn after a submission whose semaphore the present waits for: the copy for the window waits
    // for that device value, and signals the next.
    let draw = p.vk.semaphore()
    let cp = p.vk.commandPool()
    let cb = p.vk.commandBuffer(cp)
    p.vk.begin(cb)
    _ = p.vk.end(cb)
    #expect(p.vk.submit([cb], signal: [draw]) == VK_SUCCESS)
    let drawn = p.vk.gpu.submitted.last!.signal
    let before = p.vk.gpu.submitted.count
    #expect(p.present(s, a.1, wait: [draw]) == VK_SUCCESS)
    #expect(p.vk.gpu.submitted.count == before + 1)
    let copy = p.vk.gpu.submitted.last!
    #expect(copy.wait == drawn && copy.signal > drawn)
    #expect(copy.list.commands.count == 1)
    if case .copyImageToBuffer(let image, let memory, offset: 0) = copy.list.commands[0] {
      #expect(image.handle == p.vk.gpu.images[Int(a.1)].handle && memory.size == 640 * 480 * 4)
    } else {
      Issue.record("the present's list is not one copy out of the image")
    }
    #expect(p.vk.gpu.completed >= copy.signal)
    #expect(p.window.log.last == "present \(p.window.images.keys.sorted()[Int(a.1)])")
    // The image is the compositor's until a later present replaces it; the next present takes a credit first.
    #expect(p.acquire(s).0 == VK_NOT_READY)
    #expect(p.present(s, b.1) == VK_SUCCESS)
    #expect(p.window.creditWaits == 1)
    #expect(p.present(s, c.1) == VK_SUCCESS)
    #expect(p.window.creditWaits == 2)
    // The vblank shows c's predecessor and frees the first: that is the one acquired next.
    let d = p.acquire(s, timeout: 1_000_000)
    #expect(d.0 == VK_SUCCESS && d.1 == a.1)
    // And a timeout is a timeout, where the compositor shows nothing.
    p.window.stall = true
    #expect(p.acquire(s, timeout: 3_000_000).0 == VK_TIMEOUT)
    p.destroy(s)
  }

  @Test func acquireSignalsItsSemaphoreAndFence() throws {
    let p = Presenter()
    let (_, s) = p.swapchain()
    let sem = p.vk.semaphore(), fence = p.vk.fence()
    #expect(p.acquire(s, semaphore: sem, fence: fence).0 == VK_SUCCESS)
    #expect(p.vk.fn("vkGetFenceStatus", PFN_vkGetFenceStatus.self)(p.vk.device, fence) == VK_SUCCESS)
    p.destroy(s)
  }

  @Test func fifoIsPacedByTheCompositorsFrames() throws {
    let p = Presenter()
    let (_, s) = p.swapchain(count: 3)
    var shownBefore = 0
    for frame in 0..<12 {
      let (r, i) = p.acquire(s, timeout: UInt64.max)
      #expect(r == VK_SUCCESS)
      #expect(p.present(s, i) == VK_SUCCESS)
      if frame > 0 { #expect(p.window.log.filter { $0.hasPrefix("shown") }.count >= shownBefore) }
      shownBefore = p.window.log.filter { $0.hasPrefix("shown") }.count
    }
    // Every present but the first waited for the one before it to be shown, and no present was lost or doubled.
    #expect(p.window.log.filter { $0.hasPrefix("present") }.count == 12)
    #expect(p.window.creditWaits == 11)
    p.destroy(s)
  }

  @Test func aResizeMakesTheSwapchainOutOfDateAndANewOneReplacesIt() throws {
    let p = Presenter()
    let (_, s) = p.swapchain(count: 3)
    let (_, held) = p.acquire(s)
    #expect(p.present(s, held) == VK_SUCCESS)
    let (_, drawing) = p.acquire(s)
    // The user resizes the window while the application draws.
    p.window.resizeTo = (800, 600)
    // The frame in hand is shown at its own size and the application is told.
    #expect(p.present(s, drawing) == VK_SUBOPTIMAL_KHR)
    // The next acquire says the swapchain is out of date, and so does every one after.
    #expect(p.acquire(s).0 == VK_ERROR_OUT_OF_DATE_KHR)
    #expect(p.acquire(s, timeout: UInt64.max).0 == VK_ERROR_OUT_OF_DATE_KHR)
    // The resize arrives as an event, once.
    var n: UInt32 = 4
    var events = [VkVectraWindowEventVECTRA](repeating: VkVectraWindowEventVECTRA(), count: 4)
    #expect(p.vk.fn("vkPollVectraWindowEventsVECTRA", PFN_vkPollVectraWindowEventsVECTRA.self)(p.vk.instance, p.surface, &n, &events) == VK_SUCCESS)
    #expect(n == 1 && events[0].type == 2 && events[0].x == 800 && events[0].y == 600)
    // The application makes another with the new size, naming the old; the old stops presenting but keeps its images
    // until it is destroyed.
    #expect(p.swapchain(extent: (640, 480), old: s).0 == VK_ERROR_INITIALIZATION_FAILED)
    let (r, t) = p.swapchain(old: s)
    #expect(r == VK_SUCCESS)
    #expect(p.window.images.count == 6)
    #expect(p.window.images.values.filter { $0.width == 800 && $0.height == 600 }.count == 3)
    #expect(p.present(s, held) == VK_ERROR_OUT_OF_DATE_KHR)
    p.destroy(s)
    #expect(p.window.images.count == 3)
    let (r2, i2) = p.acquire(t)
    #expect(r2 == VK_SUCCESS)
    #expect(p.present(t, i2) == VK_SUCCESS)
    p.destroy(t)
    #expect(p.window.images.isEmpty)
  }

  @Test func presentingAnImageNotAcquiredIsRefused() throws {
    let p = Presenter()
    let (_, s) = p.swapchain()
    #expect(p.present(s, 0) != VK_SUCCESS)
    #expect(p.present(s, 7) != VK_SUCCESS)
    p.destroy(s)
  }

  @Test func windowEventsArePolledNotWaitedFor() throws {
    let p = Presenter()
    p.window.events = [
      .key(down: true, code: 0x29, character: 0, modifiers: 0), .key(down: false, code: 0x29, character: 0, modifiers: 0),
      .pointer(x: 10, y: 20, button: 1, pressed: true), .close,
    ]
    let poll = p.vk.fn("vkPollVectraWindowEventsVECTRA", PFN_vkPollVectraWindowEventsVECTRA.self)
    var n: UInt32 = 0
    // The count alone takes nothing.
    #expect(poll(p.vk.instance, p.surface, &n, nil) == VK_SUCCESS && n == 4)
    n = 2
    var events = [VkVectraWindowEventVECTRA](repeating: VkVectraWindowEventVECTRA(), count: 4)
    #expect(poll(p.vk.instance, p.surface, &n, &events) == VK_INCOMPLETE && n == 2)
    #expect(events[0].type == 3 && events[0].keyCode == 0x29)
    #expect(events[1].type == 4 && events[1].keyCode == 0x29)
    n = 4
    #expect(poll(p.vk.instance, p.surface, &n, &events) == VK_SUCCESS && n == 2)
    #expect(events[0].type == 5 && events[0].x == 10 && events[0].y == 20 && events[0].button == 1 && events[0].pressed == 1)
    #expect(events[1].type == 1)
    n = 4
    #expect(poll(p.vk.instance, p.surface, &n, &events) == VK_SUCCESS && n == 0)
    #expect(p.window.waits == 0)
  }

  @Test func fullscreenIsAResize() throws {
    let p = Presenter()
    let (_, s) = p.swapchain()
    #expect(p.vk.fn("vkSetVectraWindowFullscreenVECTRA", PFN_vkSetVectraWindowFullscreenVECTRA.self)(p.vk.instance, p.surface, 1) == VK_SUCCESS)
    #expect(p.window.fullscreen)
    #expect(p.acquire(s).0 == VK_ERROR_OUT_OF_DATE_KHR)
    p.destroy(s)
  }

  @Test func destroyingTheSurfaceClosesTheWindow() throws {
    let p = Presenter()
    p.vk.fn("vkDestroySurfaceKHR", PFN_vkDestroySurfaceKHR.self)(p.vk.instance, p.surface, nil)
    #expect(p.window.closed)
  }

  @Test func aDeviceThatPresentsDirectAddsNothingAndNeverStages() throws {
    // The core's direct way: the window's image is the device's own (`exportWindowHandle`), so nothing is added to the list
    // that presents, and a frame the device can't share so is refused rather than staged.
    let gpu = FakeGPU()
    gpu.presentsDirect = true
    let direct = try gpu.makePresentImage(format: .bgra8, width: 8, height: 8, usage: .renderTarget)
    #expect(direct.isDirect && direct.staging == nil && direct.stridePixels == 8 && direct.bytes == 256)
    #expect(direct.image.descriptor.usage.contains(.scanout))
    var list = GPUCommandList()
    direct.recordPresent(into: &list)
    #expect(list.isEmpty)
    #expect(direct.exportHandle(gpu) != nil && direct.exportHandle(gpu) != nil)
    // The display's export is not the window's: a direct frame never takes it.
    #expect(gpu.exportHandle(direct.image) == nil)
    // A device that presents direct and can't share a frame refuses it.
    gpu.refusesWindowExport = true
    #expect(throws: GPUError.self) { try gpu.makePresentImage(format: .bgra8, width: 8, height: 8, usage: .renderTarget) }
    #expect(gpu.allocations.isEmpty, "no staging memory was made")
    gpu.refusesWindowExport = false
    // The staged one copies out, into memory of exactly the frame.
    gpu.presentsDirect = false
    let staged = try gpu.makePresentImage(format: .bgra8, width: 8, height: 8, usage: .renderTarget)
    #expect(!staged.isDirect && staged.staging?.size == 256)
    staged.recordPresent(into: &list)
    #expect(list.commands.count == 1)
    // Neither: refused.
    gpu.exportsMemory = false
    #expect(throws: GPUError.self) { try gpu.makePresentImage(format: .bgra8, width: 8, height: 8, usage: .renderTarget) }
    #expect(throws: GPUError.self) { try gpu.makePresentImage(format: .r8, width: 8, height: 8, usage: .renderTarget) }
  }

  @Test func aSwapchainOnADeviceThatPresentsDirectCopiesNothing() throws {
    let gpu = FakeGPU()
    gpu.presentsDirect = true
    let p = Presenter(gpu: gpu)
    let (r, s) = p.swapchain(count: 2)
    #expect(r == VK_SUCCESS && p.window.images.count == 2 && p.window.acquires.isEmpty)
    for _ in 0..<4 {
      let (a, i) = p.acquire(s, timeout: UInt64.max)
      #expect(a == VK_SUCCESS)
      #expect(p.present(s, i) == VK_SUCCESS)
    }
    // Nothing was submitted for a present: the window's image is the one the application drew.
    #expect(gpu.submitted.isEmpty)
    p.destroy(s)
  }

  @Test func theTimelineIsTheAcquireCounterAndNoCPUWaits() throws {
    // A device whose timeline is a counter it hands out: each window image takes it as its acquire counter, and a present
    // names the value of the work on the image instead of the CPU waiting for it.
    for direct in [true, false] {
      let gpu = FakeGPU()
      gpu.presentsDirect = direct
      gpu.givesTimeline = true
      let p = Presenter(gpu: gpu)
      let (_, s) = p.swapchain(count: 2)
      #expect(p.window.acquires.values.sorted() == [701, 702])
      let (_, i) = p.acquire(s, timeout: UInt64.max)
      #expect(p.present(s, i) == VK_SUCCESS)
      if direct {
        // No semaphore: drawn as soon as the window looks.
        #expect(p.window.drawnAts == [0] && gpu.submitted.isEmpty)
      } else {
        // Staged: the copy's value, which nothing on the CPU waited for.
        #expect(gpu.submitted.count == 1 && p.window.drawnAts == gpu.submitted.map { $0.signal })
      }
      #expect(gpu.waited.isEmpty, "the CPU waited for \(gpu.waited)")
      p.destroy(s)
    }
    // Without it, the CPU waits for the copy and the window is named no value.
    let gpu = FakeGPU()
    let p = Presenter(gpu: gpu)
    let (_, s) = p.swapchain(count: 2)
    let (_, i) = p.acquire(s, timeout: UInt64.max)
    #expect(p.present(s, i) == VK_SUCCESS)
    #expect(p.window.acquires.isEmpty && p.window.drawnAts.isEmpty && gpu.waited == gpu.submitted.map { $0.signal })
    p.destroy(s)
  }
}
