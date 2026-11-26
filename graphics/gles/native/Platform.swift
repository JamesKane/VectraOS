// SPDX-License-Identifier: BSD-3-Clause

// The device's platform (tier 1): the GPU's core device, opened as the Vulkan layer's registry opens it (the Mali backend
// where the GPU class offers the `csf` capset, else the core over Venus), and windows of Radharc's through the SDK (VX),
// on a loop of the process's that EGL's calls drive. As graphics/vulkan/drivers/core/registry does for the Vulkan layer.

import GPUClient
import GPUCore
import GPUCoreMali
import GPUCoreVulkan
import Node
import Sys
import Vulkan
import VX

/// VenusClient's connection (graphics/vulkan/drivers/venus), by its symbol, as the registry has it.
@_silgen_name("td_venus_connect")
func connectVenus() -> @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer?

func defaultPlatform() -> (any GLPlatform)? { NativePlatform() }

/// The process's loop, made when the first window opens.
final class LoopBox {
  var loop: Loop
  init() throws(LoopError) { loop = try Loop() }
}

final class NativePlatform: GLPlatform {
  var box: LoopBox?
  var windows: [WindowID: NativeWindow] = [:]

  func openDevice() throws(GPUError) -> any GPUDevice {
    if GPUContext.namespace == nil { GPUContext.namespace = Namespace.process }
    let device: any GPUDevice
    if CSFContext.isOffered() {
      device = try MaliDevice()
    } else {
      let venus = unsafe unsafeBitCast(connectVenus(), to: PFN_vkGetInstanceProcAddr.self)
      device = try VulkanDevice(choose: .anyPreferDiscrete, storageImages: false, texelBuffers: false,
                                library: VulkanLibrary(getInstanceProcAddr: venus))
    }
    print("gles: OpenGL ES over the core's \(device.backend) backend, on \(device.name)")
    return device
  }

  func openWindow(title: String, width: Int32, height: Int32) -> (any GLWindow)? {
    if box == nil { box = try? LoopBox() }
    guard let box else { return nil }
    let id: WindowID
    do { id = try box.loop.openWindow(title, width: width, height: height) } catch { return nil }
    let window = NativeWindow(platform: self, id: id)
    windows[id] = window
    // Its first configure is the size it has.
    window.pump()
    var waited: UInt64 = 0
    while !window.configured && waited < 5_000_000_000 {
      window.wait(nanoseconds: 10_000_000)
      waited += 10_000_000
    }
    guard window.configured else {
      box.loop.closeWindow(id)
      windows[id] = nil
      return nil
    }
    return window
  }

  func dispatch(_ events: Events) {
    for e in events { windows[e.window]?.take(e) }
  }
}

/// What a present waits for the compositor, in all, before it says the window is lost: a hidden window's frames come
/// about once a second.
private let presentGiveUp: UInt64 = 20_000_000_000

final class NativeWindow: GLWindow {
  unowned let platform: NativePlatform
  let id: WindowID
  var configured = false
  var closed = false
  var pixelWidth: Int32 = 0
  var pixelHeight: Int32 = 0

  init(platform: NativePlatform, id: WindowID) {
    self.platform = platform
    self.id = id
  }

  var loop: LoopBox { platform.box! }
  var width: Int32 { pixelWidth }
  var height: Int32 { pixelHeight }

  func take(_ e: Event) {
    switch e.payload {
    case .configure(let c):
      configured = true
      pixelWidth = c.pixelWidth
      pixelHeight = c.pixelHeight
    case .close: closed = true
    default: break
    }
  }

  func pump() { platform.dispatch(loop.loop.poll()) }

  func wait(nanoseconds: UInt64) {
    platform.dispatch(loop.loop.wait(until: Deadline(ns: Deadline.now.ns &+ nanoseconds)))
  }

  func addImage(vmo: UInt32, width: Int32, height: Int32, stride: Int32, acquire: UInt32?) -> UInt32? {
    let handle = Handle(raw: vmo)
    guard let acquire else { return try? loop.loop.addImage(id, vmo: handle, width: width, height: height, stride: stride) }
    return try? loop.loop.addImage(id, vmo: handle, width: width, height: height, stride: stride, acquire: Handle(raw: acquire))
  }

  func removeImage(_ image: UInt32) { loop.loop.removeImage(id, image: image) }

  func isFree(_ image: UInt32) -> Bool { loop.loop.imageIsFree(id, image: image) }

  func present(_ image: UInt32, drawnAt: UInt64?, wait: Bool) -> WindowPresent {
    var waited: UInt64 = 0
    while true {
      pump()
      if closed { return .lost }
      if loop.loop.canPresent(id) {
        guard let config = loop.loop.windowConfiguration(id) else { return .lost }
        do {
          try loop.loop.presentImage(id, image: image, configSeq: config.configSeq, drawnAt: drawnAt)
          return .shown
        } catch {
          switch error {
          case .noCredit, .staleConfig: break  // a frame, or the next configure, is on its way
          default: return .lost
          }
        }
      }
      // A swap interval of 0: the compositor takes this frame or none.
      guard wait else {
        // Its credit comes back with a frame, if one is asked for.
        loop.loop.requestFrame(id)
        return .notTaken
      }
      guard waited < presentGiveUp else { return .lost }
      loop.loop.requestFrame(id)
      self.wait(nanoseconds: 2_000_000)
      waited += 2_000_000
    }
  }

  func close() {
    closed = true
    loop.loop.closeWindow(id)
    platform.windows[id] = nil
  }
}
