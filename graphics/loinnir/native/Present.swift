// SPDX-License-Identifier: BSD-3-Clause

// Loinnir's window on the device (D121, after todhchai's; D174, "Presentation, as designed"): a window's frames are a ring
// of three GPU images (`GPUDevice.makePresentImage`), each given to the window as one of its images with the SDK's
// `addImage`. A frame is rendered into a free one of them, the GPU copies it where Radharc reads it where the device can't
// share the image's own pages (a copy by the GPU, in the list that presents it), and once the GPU is done the image is
// presented. The CPU copies no pixel and reads none back. (The wait for the GPU is the CPU's: the device's timeline is not
// a counter Radharc can wait on, D174's open items.)
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
  // The heap's storage-image and texel-buffer arrays, where the device has them: the core's cases (loinnir-test) use them.
  return try VulkanDevice(choose: .anyPreferDiscrete, storageImages: true, texelBuffers: true)
}

/// One image of a window's ring: what the GPU draws into, the texture over it, and the window's number for it.
struct PresentSlot {
  let frame: PresentImage
  let texture: Texture
  let image: UInt32
}

/// The window and its ring of frames.
final class NativePresentation: LoinnirPresentation {
  /// Images in the ring: one on the glass, one being read by Radharc's next frame, one to draw.
  static let ringSize = 3
  let window: WindowID
  var ring: [PresentSlot] = []
  /// The ring's slot being drawn into, until it is presented.
  var drawing: Int?
  /// Frames presented, and frames that found no free image or no credit and were dropped.
  var presented = 0
  var dropped = 0
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

  /// Frames presented and frames dropped (no free image in the ring, or no credit from Radharc) so far.
  public var presentCounts: (presented: Int, dropped: Int) { (native?.presented ?? 0, native?.dropped ?? 0) }

  /// Takes the ring's images back from the window and the device, once the GPU is done with them.
  func dropRing(_ p: NativePresentation, _ loop: inout Loop) throws(LoinnirError) {
    if !p.ring.isEmpty { try wait(timelineValue) }
    for s in p.ring {
      loop.removeImage(p.window, image: s.image)
      let staging = s.frame.staging
      free(s.texture)
      if let staging { core.free(staging) }
    }
    p.ring = []
    p.drawing = nil
  }

  /// The ring for a window of `width` by `height` pixels.
  func makeRing(_ p: NativePresentation, _ loop: inout Loop, width: Int32, height: Int32) throws(LoinnirError) {
    for _ in 0..<NativePresentation.ringSize {
      let frame: PresentImage
      do { frame = try core.makePresentImage(format: .bgra8, width: width, height: height, usage: .renderTarget) } catch {
        throw LoinnirError(error)
      }
      guard let raw = frame.exportHandle(core) else { throw .unsupported("the device can't share a frame with a window") }
      let vmo = Handle(raw: raw)
      let image: UInt32
      do {
        image = try loop.addImage(p.window, vmo: vmo, width: width, height: height, stride: frame.stridePixels)
      } catch {
        throw .window("\(error)")
      }
      p.ring.append(PresentSlot(frame: frame, texture: adopt(frame.image, format: .bgra8), image: image))
    }
  }

  /// The image to draw this frame into, sized for `config`: a free one of the window's ring, or nil if Radharc still
  /// reads all of them (the frame is dropped).
  public func frame(_ loop: inout Loop, _ config: Configure) throws(LoinnirError) -> RenderTarget? {
    guard let p = native else { throw .unsupported("this Loinnir has no window") }
    if let s = p.ring.first, s.texture.width != config.pixelWidth || s.texture.height != config.pixelHeight {
      try dropRing(p, &loop)
    }
    if p.ring.isEmpty { try makeRing(p, &loop, width: config.pixelWidth, height: config.pixelHeight) }
    // Not the one drawn into last, if another is free, so the one on the glass and the one next in line stay untouched.
    guard let i = p.ring.indices.first(where: { $0 != p.drawing && loop.imageIsFree(p.window, image: p.ring[$0].image) }) else {
      p.dropped += 1
      return nil
    }
    p.drawing = i
    return .texture(p.ring[i].texture)
  }

  /// Presents the frame once the GPU reaches `value`: the copy for Radharc (where the device can't share the image itself)
  /// is the GPU's, the wait for it the CPU's, and the image is given to the window. A frame the window has no credit for
  /// (its last present is not shown yet) is dropped.
  public func present(_ loop: inout Loop, _ config: Configure, after value: UInt64) throws(LoinnirError) {
    guard let p = native, let i = p.drawing else { return }
    p.drawing = nil
    let slot = p.ring[i]
    if let staging = slot.frame.staging {
      var cmd = try commands()
      cmd.copy(slot.texture, to: GPUAllocation(staging))
      try wait(try submit(cmd))
    } else {
      try wait(value)
    }
    do {
      try loop.presentImage(p.window, image: slot.image, configSeq: config.configSeq)
      p.presented += 1
    } catch {
      if error == .noCredit || error == .staleConfig {
        p.dropped += 1
        return
      }
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
