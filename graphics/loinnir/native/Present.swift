// SPDX-License-Identifier: BSD-3-Clause

// Loinnir's window on the device (D121, after todhchai's): a frame is
// rendered into a texture of the window's size, the GPU copies it into a
// host-visible buffer, and once the GPU is done (v0: the CPU waits) the CPU
// copies the pixels into the window's own surface, which is presented to
// Radharc. (todhchai's presents the buffer itself, VK_FUCHSIA_external_memory
// over the SDK's window buffers, which VX's Loop doesn't have yet.)
//
// The GPU is whichever the device offers (D174 section 5): a GPU whose
// driver host offers the `csf` capset gets the native Mali driver (the
// core's mali backend); any other, Venus's, gets the core over Vulkan.

import GPUClient
import GPUCore
import GPUCoreMali
import GPUCoreVulkan
import Sys
import VX

/// Our GPUs are found through the process's namespace (the GPU class
/// connection of the Venus client driver, or of a native driver's).
func loinnirPlatformSetup() {
  if GPUClient.GPUContext.namespace == nil { GPUClient.GPUContext.namespace = processNamespace() }
}

/// The device Loinnir draws with: by what the GPU class offers.
func loinnirOpenDevice() throws(GPUError) -> any GPUDevice {
  if CSFContext.isOffered() { return try MaliDevice() }
  return try VulkanDevice()
}

/// The window, the frame's texture, and the buffers Radharc reads (or the
/// one copy the CPU reads, without the extension).
final class NativePresentation: LoinnirPresentation {
  let window: WindowID
  var target: Texture?
  var shared: [GPUAllocation] = []
  var readback: GPUAllocation?
  init(window: WindowID) { self.window = window }
}

extension Loinnir {
  /// A new handle to `allocation`'s memory, a VMO, for another process
  /// (VK_FUCHSIA_external_memory); nil where the driver can't.
  public func exportVMO(_ allocation: GPUAllocation) -> Handle? {
    guard let raw = core.exportHandle(allocation.memory) else { return nil }
    return Handle(raw: raw)
  }

  /// A new handle to a `scanout` texture's VMO, for a display to show it as it is; nil where the driver can't, or the
  /// texture's rows are not as the display reads them.
  public func exportVMO(_ texture: Texture) -> Handle? {
    guard let image = textures[texture.index], let raw = core.exportHandle(image) else { return nil }
    return Handle(raw: raw)
  }

  /// A GPU for drawing into `window`.
  public static func open(window: WindowID, loop: inout Loop) throws(LoinnirError) -> Loinnir {
    let gpu = try Loinnir(gpu: try GPUContext())
    gpu.presentation = NativePresentation(window: window)
    return gpu
  }

  var native: NativePresentation? { presentation as? NativePresentation }

  /// The window, if there is one.
  public var window: WindowID? { native?.window }

  /// The image to draw this frame into, sized for `config`.
  public func frame(_ loop: inout Loop, _ config: Configure) throws(LoinnirError) -> RenderTarget? {
    guard let p = native else { throw .unsupported("this Loinnir has no window") }
    if p.target == nil || p.target!.width != config.pixelWidth || p.target!.height != config.pixelHeight {
      if p.target != nil { try wait(timelineValue) }
      let (w, h) = (config.pixelWidth, config.pixelHeight)
      p.target = try texture(.bgra8, width: w, height: h, renderTarget: true, sampled: false)
      p.shared = []
      p.readback = try alloc(.readback, bytes: Int(w) * Int(h) * 4)
    }
    guard let target = p.target else { return nil }
    return .texture(target)
  }

  /// Presents the frame once the GPU reaches `value`: copied by the GPU
  /// into the window's free buffer (or out, and by the CPU into it), waited
  /// for, and presented. A frame with no free buffer (both with Radharc)
  /// is dropped.
  public func present(_ loop: inout Loop, _ config: Configure, after value: UInt64) throws(LoinnirError) {
    guard let p = native, let target = p.target, let surface = loop.cpuSurface(p.window) else { return }
    var cmd = try commands()
    guard let into = p.readback else { return }
    cmd.copy(target, to: into)
    try wait(try submit(cmd))
    if p.shared.isEmpty, let source = unsafe into.pointer {
      let width = min(Int(surface.width), Int(target.width)), height = min(Int(surface.height), Int(target.height))
      for y in 0..<height {
        // B, G, R, A bytes: the 0x00RRGGBB little-endian word Radharc reads.
        unsafe (surface.pixels.baseAddress! + y * surface.stride)
          .copyMemory(from: source + y * Int(target.width) * 4, byteCount: width * 4)
      }
    }
    do {
      try loop.present(p.window, surface, configSeq: config.configSeq)
    } catch {
      throw .window("\(error)")
    }
  }

  /// Clears a frame to `color` and presents it.
  @discardableResult
  public func clear(_ color: (Float, Float, Float, Float), loop: inout Loop, config: Configure) throws(LoinnirError)
    -> Bool
  {
    guard let target = try frame(&loop, config) else { return false }
    var cmd = try commands()
    cmd.render(to: target, clear: color) { _ in }
    try present(&loop, config, after: try submit(cmd))
    return true
  }
}
