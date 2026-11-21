// SPDX-License-Identifier: BSD-3-Clause

// What a window shows (D174, "Presentation, as designed"; gpucore(2)): a frame is a GPU image, and the window is given
// the pages of it as one of its images (the SDK's `addWindowImage`), so Radharc reads what the GPU drew. Loinnir's present
// and the Vulkan layer's swapchain make their frames here, and nothing else does.
//
// There are two ways to the same end, and the device says which it can do:
//  - Direct: the device exports the image's own pages (`exportHandle(image)`, a `scanout` image). The window's image is the
//    GPU's image, and presenting it copies nothing.
//  - Staged: it can't (the image's layout is the host's, as under Venus, where the pages are not the CPU's to read). The
//    frame is copied by the GPU, in the list that presents it, into host-visible memory the device exports
//    (`exportHandle(memory)`) tightly packed, and the window's image is that memory. The copy is the GPU's; the CPU
//    touches no pixel.
// Both leave the window with a VMO of `width * height * 4` bytes, rows of `width` pixels.

/// One frame's image and what carries it to the window.
public final class PresentImage {
  /// What the application or Loinnir draws into.
  public let image: GPUImage
  /// Where the GPU copies the frame for the window, if the image's own pages can't be shared (staged); nil if they can (direct).
  public let staging: GPUMemory?
  public let width: Int32
  public let height: Int32
  /// A handle the device made while finding out whether it could export the image, kept for the first `exportHandle`.
  var first: UInt32?

  init(image: GPUImage, staging: GPUMemory?, first: UInt32?) {
    self.image = image
    self.staging = staging
    self.first = first
    width = image.width
    height = image.height
  }

  /// Whether the window's image is the GPU's own (no copy to present).
  public var isDirect: Bool { staging == nil }

  /// The row length of the window's image in pixels: tight.
  public var stridePixels: Int32 { width }

  /// The bytes the window's image holds.
  public var bytes: Int { Int(width) * Int(height) * 4 }

  /// A new handle to the pages the window is given (a VMO, to hand over: the caller owns it), or nil if the device can't.
  public func exportHandle(_ device: any GPUDevice) -> UInt32? {
    if let f = first {
      first = nil
      return f
    }
    if let staging { return device.exportHandle(staging) }
    return device.exportHandle(image)
  }

  /// What presenting the frame adds to the list that follows the GPU's work on it: the copy, for a staged image.
  public func recordPresent(into list: inout GPUCommandList) {
    if let staging { list.copy(image, to: staging) }
  }
}

extension GPUDevice {
  /// A frame image of `format` (a four-byte colour format) that a window can show, usable as `usage` and exportable:
  /// the device's own pages if it shares them, else an image with a staging buffer for the copy. `usage` gains the copy
  /// source a staged image needs and the `scanout` a direct one does; `direct` allows the first way.
  public func makePresentImage(format: PixelFormat, width: Int32, height: Int32, usage: ImageUsage, direct: Bool = false)
    throws(GPUError) -> PresentImage
  {
    guard format.bytesPerPixel == 4, !format.isDepthStencil, !format.isCompressed else {
      throw .unsupported("a window's image of \(format)")
    }
    // Direct, where the device can and the window's reader can use what it exports: an image it shares as it is. A device's
    // image export is a VMO to pin and read, not to map (Mali's, for a display), and Radharc maps a window's images until
    // its GPU renderer imports them (`importHandle`): so callers say `direct` only when the reader can.
    let wanted = ImageDescriptor(format: format, width: width, height: height, usage: usage | .scanout)
    if direct, wanted.check(limits: limits) == nil, let image = try? makeImage(wanted) {
      if let handle = exportHandle(image) { return PresentImage(image: image, staging: nil, first: handle) }
      destroy(image)
    }
    // Staged: the image the GPU draws, and the memory it is copied into.
    let image = try makeImage(ImageDescriptor(format: format, width: width, height: height, usage: usage | .copySource))
    let memory: GPUMemory
    do { memory = try allocate(.readback, bytes: Int(width) * Int(height) * 4) } catch {
      destroy(image)
      throw error
    }
    guard let handle = exportHandle(memory) else {
      free(memory)
      destroy(image)
      throw .unsupported("sharing a frame with a window: the device exports neither its images nor its memory")
    }
    return PresentImage(image: image, staging: memory, first: handle)
  }

  /// Gives the frame image back (once the timeline is past its last use: the device keeps what was submitted).
  public func destroy(_ frame: PresentImage) {
    if let staging = frame.staging { free(staging) }
    destroy(frame.image)
  }
}
