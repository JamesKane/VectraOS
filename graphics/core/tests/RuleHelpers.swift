// SPDX-License-Identifier: BSD-3-Clause

// What the rule tests share: a device with every feature, its limits with one feature off, and a short way to say
// what a rule answered.

import Testing

@testable import GPUCore

let fullLimits = FakeDevice.fullLimits()

/// The limits of the full device without one feature (the feature is named by a closure that turns it off).
func without(_ off: (inout DeviceFeatures) -> Void) -> DeviceLimits {
  var l = fullLimits
  off(&l.features)
  return l
}

func fullDevice() -> FakeDevice { FakeDevice(limits: fullLimits) }

/// "ok", "invalid" or "unsupported": the kind of the answer, not its words.
func verdict(_ e: GPUError?) -> String {
  switch e {
  case nil: "ok"
  case .invalid?: "invalid"
  case .unsupported?: "unsupported"
  default: "other"
  }
}

func verdict(_ list: GPUCommandList, _ limits: DeviceLimits = fullLimits) -> String { verdict(list.validate(limits: limits)) }

/// An image on `gpu` with the usage given; sampled and copies are the common ones.
func image(_ gpu: FakeDevice, _ format: PixelFormat = .rgba8, _ w: Int32 = 16, _ h: Int32 = 16, depth: Int32 = 1, mips: UInt32 = 1,
           layers: UInt32 = 1, samples: UInt32 = 1, dimension: ImageDimension = .d2,
           usage: ImageUsage = .copySource | .copyDestination | .sampled) throws -> GPUImage {
  try gpu.makeImage(ImageDescriptor(format: format, width: w, height: h, depth: depth, mipLevels: mips, layers: layers,
                                    samples: samples, dimension: dimension, usage: usage))
}

/// The same, a colour image of rgba8.
func image(_ gpu: FakeDevice, _ w: Int32, _ h: Int32, depth: Int32 = 1, mips: UInt32 = 1, layers: UInt32 = 1, samples: UInt32 = 1,
           dimension: ImageDimension = .d2, usage: ImageUsage = .copySource | .copyDestination | .sampled) throws -> GPUImage {
  try image(gpu, .rgba8, w, h, depth: depth, mips: mips, layers: layers, samples: samples, dimension: dimension, usage: usage)
}

/// An image that was never made by a device, for shapes no device makes.
func raw(_ f: PixelFormat, usage: ImageUsage) -> GPUImage {
  GPUImage(handle: 77, descriptor: ImageDescriptor(format: f, width: 16, height: 16, usage: usage))
}

func graphicsPipeline(_ gpu: FakeDevice, formats: [PixelFormat] = [.rgba8], depth: PixelFormat? = nil,
                      samples: UInt32 = 1) throws -> GPUPipeline {
  try gpu.makeGraphicsPipeline(
    GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: formats, depthStencilFormat: depth,
                               multisample: MultisampleState(samples: samples)))
}

func colorPass(_ images: GPUImage..., load: LoadAction = .dontCare) -> RenderingInfo {
  RenderingInfo(colors: images.map { Attachment(image: $0, load: load) })
}

func region(_ w: UInt32 = 4, _ h: UInt32 = 4) -> ImageCopyRegion { ImageCopyRegion(extent: Extent3D(width: w, height: h)) }
func blitRegion(_ w: Int32 = 4, _ h: Int32 = 4) -> ImageBlitRegion {
  ImageBlitRegion(srcMax: Offset3D(x: w, y: h, z: 1), dstMax: Offset3D(x: w, y: h, z: 1))
}
