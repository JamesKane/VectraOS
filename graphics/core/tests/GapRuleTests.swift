// SPDX-License-Identifier: BSD-3-Clause

// The rules for the five things the core once left out (D174 amendment): 1D images and views, a view's component mapping,
// a sampler's own border colour, texel buffers, and (in the Vulkan layer, over these) input attachments. Each rule has a
// case that passes and a case that fails, in the two kinds that stay apart: `.invalid` (the shape is wrong everywhere) and
// `.unsupported` (this device lacks something).

import Testing

@testable import GPUCore

private func desc1D(_ f: PixelFormat = .rgba8, _ w: Int32 = 16, h: Int32 = 1, depth: Int32 = 1, mips: UInt32 = 1, layers: UInt32 = 1,
                    samples: UInt32 = 1, usage: ImageUsage = .sampled) -> ImageDescriptor {
  ImageDescriptor(format: f, width: w, height: h, depth: depth, mipLevels: mips, layers: layers, samples: samples, dimension: .d1,
                  usage: usage)
}

@Suite struct OneDimensionalImages {
  @Test func aOneDimensionalImageIsMadeOnADeviceThatHasThem() throws {
    let l = fullLimits
    #expect(desc1D().check(limits: l) == nil)
    #expect(desc1D(mips: 5).check(limits: l) == nil)
    #expect(desc1D(layers: 4).check(limits: l) == nil)
    #expect(desc1D(.r32uint, usage: .storage | .sampled).check(limits: l) == nil)
    let gpu = fullDevice()
    let img = try gpu.makeImage(desc1D(mips: 3, layers: 2))
    #expect(img.dimension == .d1 && img.height == 1 && img.layers == 2 && img.mipLevels == 3)
    // Each mip level is half as wide, and one texel high.
    let e = img.descriptor.mipExtent(2)
    #expect(e.width == 4 && e.height == 1 && e.depth == 1)
    #expect(img.descriptor.byteSize(mip: 1) == 8 * 4)
  }

  @Test func aShapeNoDeviceMakesIsInvalid() {
    let l = fullLimits
    #expect(verdict(desc1D(h: 4).check(limits: l)) == "invalid")  // a 1D image is one texel high
    #expect(verdict(desc1D(depth: 2).check(limits: l)) == "invalid")
    #expect(verdict(desc1D(samples: 4).check(limits: l)) == "invalid")
    #expect(verdict(desc1D(.depth16, usage: .sampled).check(limits: l)) == "invalid")
    #expect(verdict(desc1D(.astc(.b6x6), 24).check(limits: l)) == "invalid")
    #expect(verdict(desc1D(usage: .renderTarget).check(limits: l)) == "invalid")  // nothing draws into a 1D image
    #expect(verdict(desc1D(usage: .scanout).check(limits: l)) == "invalid")
    #expect(verdict(desc1D(mips: 6).check(limits: l)) == "invalid")  // 16 texels have five levels
    #expect(verdict(desc1D(layers: 0).check(limits: l)) == "invalid")
  }

  @Test func aDeviceWithoutThemRefusesThem() {
    #expect(verdict(desc1D().check(limits: without { $0.images1D = false })) == "unsupported")
    #expect(verdict(desc1D(layers: 3).check(limits: without { $0.arrayImages = false })) == "unsupported")
    #expect(verdict(desc1D(mips: 3).check(limits: without { $0.mipmaps = false })) == "unsupported")
    #expect(verdict(desc1D(.rgba8, 64).check(limits: { var l = fullLimits; l.maxImageDimension = 32; return l }())) == "unsupported")
    #expect(throws: GPUError.self) { try FakeDevice().makeImage(desc1D()) }
  }

  @Test func theViewsOfOne() throws {
    let gpu = fullDevice()
    let l = fullLimits
    let plain = try gpu.makeImage(desc1D(usage: .sampled | .storage))
    let array = try gpu.makeImage(desc1D(layers: 4, usage: .sampled | .storage))
    #expect(ImageView(plain).dimension == .d1 && ImageView(array).dimension == .d1Array)
    #expect(ImageView(plain).isWholeImage && ImageView(array).isWholeImage)
    #expect(ImageView(plain).check(for: .texture, limits: l) == nil)
    #expect(ImageView(plain).check(for: .storage, limits: l) == nil)
    #expect(ImageView(array).check(for: .texture, limits: l) == nil)
    #expect(ImageView(array, baseLayer: 1, layerCount: 2).check(for: .texture, limits: l) == nil)
    #expect(ImageView(array, dimension: .d1, baseLayer: 2, layerCount: 1).check(for: .texture, limits: l) == nil)
    #expect(ImageView(plain, dimension: .d1Array).check(for: .texture, limits: l) == nil)
    try gpu.writeTexture(1, ImageView(array))
    #expect(gpu.textures[1]?.dimension == .d1Array)
    try gpu.writeStorageImage(0, ImageView(plain))
    #expect(gpu.storageImages[0]?.dimension == .d1)

    // The shapes no device takes.
    #expect(verdict(ImageView(array, dimension: .d1).check(for: .texture, limits: l)) == "invalid")  // four layers
    #expect(verdict(ImageView(plain, dimension: .d2).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(plain, dimension: .d2Array).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(plain, dimension: .d3).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(plain, dimension: .cube).check(for: .texture, limits: l)) == "invalid")
    let flat = try image(gpu, usage: .sampled)
    #expect(verdict(ImageView(flat, dimension: .d1).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(flat, dimension: .d1Array).check(for: .texture, limits: l)) == "invalid")

    // What a device without them refuses.
    #expect(verdict(ImageView(plain).check(for: .texture, limits: without { $0.images1D = false })) == "unsupported")
    #expect(verdict(ImageView(array).check(for: .texture, limits: without { $0.arrayImages = false })) == "unsupported")
  }

  @Test func noPassDrawsIntoAOneDimensionalView() throws {
    let gpu = fullDevice()
    let plain = try gpu.makeImage(desc1D(usage: .sampled | .storage))
    // Not even a 2D image's 1D view: the view's dimension is judged against the image first.
    let flat = try image(gpu, usage: .renderTarget)
    let bad = Attachment(view: ImageView(flat, dimension: .d1), load: .dontCare)
    var list = GPUCommandList()
    list.beginRendering(RenderingInfo(colors: [bad]))
    list.endRendering()
    #expect(verdict(list) == "invalid")
    _ = plain
  }
}

@Suite struct ViewSwizzle {
  @Test func theDefaultIsTheIdentity() throws {
    let gpu = fullDevice()
    let img = try image(gpu, usage: .sampled)
    #expect(ImageView(img).swizzle == .identity && ImageView(img).swizzle.isIdentity)
    #expect(ComponentMapping(r: .r, g: .g, b: .b, a: .a).isIdentity)
    #expect(!ComponentMapping(r: .b, g: .g, b: .r, a: .a).isIdentity)
    #expect(!ComponentMapping(a: .one).isIdentity)
    #expect(ImageView(img, swizzle: ComponentMapping(r: .b, b: .r)).isWholeImage == false)
  }

  @Test func aMappedViewIsTakenWhereTheDeviceHasThem() throws {
    let gpu = fullDevice()
    let img = try image(gpu, .bgra8, usage: .sampled)
    let m = ComponentMapping(r: .b, g: .g, b: .r, a: .a)
    #expect(ImageView(img, swizzle: m).check(for: .texture, limits: fullLimits) == nil)
    try gpu.writeTexture(3, ImageView(img, swizzle: m))
    #expect(gpu.textures[3]?.swizzle == m)
    #expect(ImageView(img, swizzle: ComponentMapping(r: .one, g: .zero, b: .a, a: .r)).check(for: .texture, limits: fullLimits) == nil)
  }

  @Test func aDeviceWithoutMappingRefusesIt() throws {
    let gpu = fullDevice()
    let img = try image(gpu, usage: .sampled)
    let m = ComponentMapping(r: .b, b: .r)
    #expect(verdict(ImageView(img, swizzle: m).check(for: .texture, limits: without { $0.imageSwizzle = false })) == "unsupported")
    // The identity is taken everywhere.
    #expect(ImageView(img, swizzle: ComponentMapping(r: .r)).check(for: .texture, limits: without { $0.imageSwizzle = false }) == nil)
    // And a device that only has the whole image (the defaults of GPUDevice) refuses a mapped view, which is not the whole.
    let mali = FakeDevice(features: { var f = DeviceFeatures(); f.sampledImages = true; return f }())
    #expect(throws: GPUError.self) { try mali.writeTexture(0, ImageView(img, swizzle: m)) }
  }

  @Test func aMappedViewIsNeverStoredToOrDrawnInto() throws {
    let gpu = fullDevice()
    let img = try image(gpu, usage: .sampled | .storage | .renderTarget)
    let m = ComponentMapping(r: .b, b: .r)
    #expect(verdict(ImageView(img, swizzle: m).check(for: .storage, limits: fullLimits)) == "invalid")
    var list = GPUCommandList()
    list.beginRendering(RenderingInfo(colors: [Attachment(view: ImageView(img, swizzle: m), load: .dontCare)]))
    list.endRendering()
    #expect(verdict(list) == "invalid")
  }
}

@Suite struct CustomBorderColors {
  @Test func aCustomColourIsTakenWhereTheDeviceHasIt() throws {
    let gpu = fullDevice()
    let s = SamplerDescriptor(addressMode: .clampToBorder, customBorderColor: .float(0.25, 0.5, 0.75, 1))
    #expect(s.check(limits: fullLimits) == nil)
    let i = SamplerDescriptor(addressModeU: .clampToBorder, customBorderColor: .int(7, -8, 9, 10))
    #expect(i.check(limits: fullLimits) == nil)
    try gpu.writeSampler(2, s)
    #expect(gpu.samplers[2]?.customBorderColor == .float(0.25, 0.5, 0.75, 1))
    // The default is no custom colour: the six that were there.
    #expect(SamplerDescriptor().customBorderColor == nil)
  }

  @Test func aCustomColourWithNoBorderToReadItIsInvalid() {
    #expect(verdict(SamplerDescriptor(addressMode: .repeat, customBorderColor: .float(1, 1, 1, 1)).check(limits: fullLimits)) == "invalid")
    #expect(verdict(SamplerDescriptor(customBorderColor: .int(1, 2, 3, 4)).check(limits: fullLimits)) == "invalid")
  }

  @Test func aDeviceWithoutItRefusesIt() {
    let s = SamplerDescriptor(addressMode: .clampToBorder, customBorderColor: .float(0.25, 0.5, 0.75, 1))
    #expect(verdict(s.check(limits: without { $0.customBorderColor = false })) == "unsupported")
    // The six colours of the core are not refused for it.
    let plain = SamplerDescriptor(addressMode: .clampToBorder, borderColor: .opaqueWhiteFloat)
    #expect(plain.check(limits: without { $0.customBorderColor = false }) == nil)
    #expect(throws: GPUError.self) { try FakeDevice().writeSampler(0, s) }
  }
}

@Suite struct TexelBuffers {
  private func memory(_ gpu: FakeDevice, _ bytes: Int = 1024) throws -> GPUMemory { try gpu.allocate(.upload, bytes: bytes) }

  @Test func aViewIsMemoryAnOffsetARangeAndAFormat() throws {
    let gpu = fullDevice()
    let m = try memory(gpu)
    let whole = BufferView(m, format: .rgba8)
    #expect(whole.offset == 0 && whole.range == 1024 && whole.elementCount == 256 && whole.texelBytes == 4)
    let part = BufferView(m, format: .rgba32float, offset: 64, range: 256)
    #expect(part.elementCount == 16 && part.texelBytes == 16)
    #expect(BufferView(m, format: .r16uint, offset: 100).range == 924)
  }

  @Test func aDeviceTakesViewsThatFit() throws {
    let gpu = fullDevice()
    let m = try memory(gpu)
    let l = fullLimits
    #expect(BufferView(m, format: .rgba8).check(for: .uniform, limits: l) == nil)
    #expect(BufferView(m, format: .r32uint, offset: 16, range: 64).check(for: .storage, limits: l) == nil)
    try gpu.writeTexelBuffer(1, BufferView(m, format: .rgba32float, range: 256))
    #expect(gpu.texelBuffers[1]?.elementCount == 16)
    try gpu.writeStorageTexelBuffer(2, BufferView(m, format: .r32uint))
    #expect(gpu.storageTexelBuffers[2]?.format == .r32uint)
  }

  @Test func aShapeNoDeviceTakesIsInvalid() throws {
    let gpu = fullDevice()
    let m = try memory(gpu)
    let l = fullLimits
    #expect(verdict(BufferView(m, format: .rgba8, range: 0).check(for: .uniform, limits: l)) == "invalid")
    #expect(verdict(BufferView(m, format: .rgba8, range: 10).check(for: .uniform, limits: l)) == "invalid")  // not whole texels
    #expect(verdict(BufferView(m, format: .rgba8, offset: 2, range: 16).check(for: .uniform, limits: l)) == "invalid")
    #expect(verdict(BufferView(m, format: .rgba8, offset: 1020, range: 8).check(for: .uniform, limits: l)) == "invalid")  // past it
    #expect(verdict(BufferView(m, format: .rgba8, offset: -4, range: 8).check(for: .uniform, limits: l)) == "invalid")
    #expect(verdict(BufferView(m, format: .depth16).check(for: .uniform, limits: l)) == "invalid")
    #expect(verdict(BufferView(m, format: .astc(.b6x6)).check(for: .uniform, limits: l)) == "invalid")
    #expect(throws: GPUError.self) { try gpu.writeTexelBuffer(8, BufferView(m, format: .rgba8)) }  // past the heap's slots
  }

  @Test func eachThingTheDeviceLacksIsRefused() throws {
    let gpu = fullDevice()
    let m = try memory(gpu)
    let v = BufferView(m, format: .r32uint)
    #expect(v.check(for: .uniform, limits: fullLimits) == nil && v.check(for: .storage, limits: fullLimits) == nil)
    #expect(verdict(v.check(for: .uniform, limits: without { $0.uniformTexelBuffers = false })) == "unsupported")
    #expect(verdict(v.check(for: .storage, limits: without { $0.storageTexelBuffers = false })) == "unsupported")
    // A feature off for the one kind leaves the other.
    #expect(v.check(for: .storage, limits: without { $0.uniformTexelBuffers = false }) == nil)
    var small = fullLimits
    small.maxTexelBufferElements = 100
    #expect(verdict(v.check(for: .uniform, limits: small)) == "unsupported")  // 256 texels
    // A format's own capability.
    var noFormat = fullLimits
    var c = noFormat.formats(.r32uint)
    c.texelBuffer = false
    noFormat.setFormat(.r32uint, c)
    #expect(verdict(v.check(for: .uniform, limits: noFormat)) == "unsupported")
    #expect(v.check(for: .storage, limits: noFormat) == nil)
    // A device with today's features keeps the default, which refuses.
    #expect(throws: GPUError.self) { try FakeDevice().writeTexelBuffer(0, v) }
    #expect(throws: GPUError.self) { try FakeDevice().writeStorageTexelBuffer(0, v) }
  }

  @Test func theStorageFormatsAreTheFormatsThatStore() {
    // The fake's generous table: the formats that can be storage images are storage texel buffers, and the atomics are on the
    // 32-bit integers.
    let c = FakeDevice.capabilities(of: .r32uint)
    #expect(c.texelBuffer && c.storageTexelBuffer && c.storageTexelBufferAtomic)
    let f = FakeDevice.capabilities(of: .rgba8srgb)
    #expect(!f.texelBuffer && !f.storageTexelBuffer)
    #expect(!FakeDevice.capabilities(of: .rgba8).storageTexelBufferAtomic)
  }
}
