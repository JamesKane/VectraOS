// SPDX-License-Identifier: BSD-3-Clause

// What a window shows (D174, "Presentation, as designed"; gpucore(2)): a frame is a GPU image, and the window is given
// the pages of it as one of its images (the SDK's `addWindowImage`), so Radharc reads what the GPU drew. Loinnir's present
// and the Vulkan layer's swapchain make their frames here, and nothing else does.
//
// There are two ways to the same end, and the device says which it takes (`DeviceFeatures.presentDirect`):
//  - Direct: the device exports the image's own pages for a window (`exportWindowHandle`: a `scanout` image in a VMO the
//    window's reader maps, reads and may import, with its rows as the device laid them out, padded to the device's linear row
//    alignment). The window's image is the GPU's image, and presenting it copies nothing. A device that presents direct
//    never stages: a frame it can't share so is refused.
//  - Staged: it can't (the image's layout is the host's, as under Venus, where the pages are not the CPU's to read). The
//    frame is copied by the GPU, in the list that presents it, into host-visible memory the device exports
//    (`exportHandle(memory)`), in rows of `width` pixels as the core's copy into memory writes them, and the window's image
//    is that memory. The copy is the GPU's; the CPU touches no pixel.
// Either way the window is told the row stride (`stridePixels`, the SDK's `addImage`'s `stride`), and reads rows that far apart.
//
// The window's image is drawn once the timeline reaches the value of the work on it. Where the device gives a counter that
// tracks its timeline (`timelineHandle`), that is the image's acquire counter and a present names the value; elsewhere the
// CPU waits for the value first, and the SDK raises the image's own counter.

/// One frame's image and what carries it to the window.
public final class PresentImage {
  /// What the application or Loinnir draws into.
  public let image: GPUImage
  /// Where the GPU copies the frame for the window, if the image's own pages can't be shared (staged); nil if they can (direct).
  public let staging: GPUMemory?
  public let width: Int32
  public let height: Int32
  /// The distance from one row of the window's image to the next, in pixels: the device's own rows (direct), or `width`
  /// (staged).
  public let stridePixels: Int32
  /// A handle the device made while finding out whether it could export the image, kept for the first `exportHandle`.
  var first: UInt32?

  init(image: GPUImage, staging: GPUMemory?, first: UInt32?, stridePixels: Int32) {
    self.image = image
    self.staging = staging
    self.first = first
    self.stridePixels = stridePixels
    width = image.width
    height = image.height
  }

  /// Whether the window's image is the GPU's own (no copy to present).
  public var isDirect: Bool { staging == nil }

  /// The bytes the window's image covers: `stridePixels * height * 4`.
  public var bytes: Int { Int(stridePixels) * Int(height) * 4 }

  /// A new handle to the pages the window is given (a VMO, to hand over: the caller owns it), or nil if the device can't.
  public func exportHandle(_ device: any GPUDevice) -> UInt32? {
    if let f = first {
      first = nil
      return f
    }
    if let staging { return device.exportHandle(staging) }
    return device.exportWindowHandle(image)?.handle
  }

  /// What presenting the frame adds to the list that follows the GPU's work on it: the copy, for a staged image.
  public func recordPresent(into list: inout GPUCommandList) {
    if let staging { list.copy(image, to: staging) }
  }
}

extension GPUDevice {
  /// A frame image of `format` (a four-byte colour format) that a window can show, usable as `usage` and exportable: the
  /// device's own pages where it presents direct (`DeviceFeatures.presentDirect`; `usage` gains `scanout`), else an image
  /// with a staging buffer for the copy (`usage` gains the copy source).
  public func makePresentImage(format: PixelFormat, width: Int32, height: Int32, usage: ImageUsage) throws(GPUError)
    -> PresentImage
  {
    guard format.bytesPerPixel == 4, !format.isDepthStencil, !format.isCompressed else {
      throw .unsupported("a window's image of \(format)")
    }
    if limits.features.presentDirect {
      // Direct: the image the GPU draws is the window's, so its export is one the window maps and reads (and may import).
      let image = try makeImage(ImageDescriptor(format: format, width: width, height: height, usage: usage | .scanout))
      guard let shared = exportWindowHandle(image), shared.rowBytes % 4 == 0, shared.rowBytes >= Int(width) * 4 else {
        destroy(image)
        throw .unsupported("a window's image of \(width) x \(height): the device can't share it with a window")
      }
      return PresentImage(image: image, staging: nil, first: shared.handle, stridePixels: Int32(shared.rowBytes / 4))
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
    return PresentImage(image: image, staging: memory, first: handle, stridePixels: width)
  }

  /// Gives the frame image back (once the timeline is past its last use: the device keeps what was submitted).
  public func destroy(_ frame: PresentImage) {
    if let staging = frame.staging { free(staging) }
    destroy(frame.image)
  }
}
