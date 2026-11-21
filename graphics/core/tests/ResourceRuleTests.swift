// SPDX-License-Identifier: BSD-3-Clause

// The rules for what a device is asked to make (D174 amendment): images, views, samplers and pipelines. Each rule has a
// case that passes and a case that fails, and the failures are of two kinds that stay apart: `.invalid` (the shape is
// wrong everywhere) and `.unsupported` (this device lacks something).

import Testing

@testable import GPUCore

private func desc(_ f: PixelFormat = .rgba8, _ w: Int32 = 16, _ h: Int32 = 16, depth: Int32 = 1, mips: UInt32 = 1, layers: UInt32 = 1,
                  samples: UInt32 = 1, dimension: ImageDimension = .d2, usage: ImageUsage = .sampled) -> ImageDescriptor {
  ImageDescriptor(format: f, width: w, height: h, depth: depth, mipLevels: mips, layers: layers, samples: samples,
                  dimension: dimension, usage: usage)
}

@Suite struct ImageDescriptorRules {
  @Test func everyKindOfImageIsMadeOnTheFullDevice() {
    let l = fullLimits
    #expect(desc().check(limits: l) == nil)
    #expect(desc(mips: 5).check(limits: l) == nil)
    #expect(desc(layers: 4).check(limits: l) == nil)
    #expect(desc(layers: 6, dimension: .cube).check(limits: l) == nil)
    #expect(desc(layers: 12, dimension: .cube).check(limits: l) == nil)
    #expect(desc(depth: 8, dimension: .d3).check(limits: l) == nil)
    #expect(desc(samples: 4, usage: .renderTarget).check(limits: l) == nil)
    #expect(desc(.depth24stencil8, usage: .depthStencilTarget | .sampled).check(limits: l) == nil)
    #expect(desc(.astc(.b6x6)).check(limits: l) == nil)
    #expect(desc(.etc2rgba8).check(limits: l) == nil)
    #expect(desc(.bc7).check(limits: l) == nil)
    #expect(desc(.rgba32float, usage: .storage | .sampled).check(limits: l) == nil)
  }

  @Test func aShapeNoDeviceMakesIsInvalid() {
    let l = fullLimits
    #expect(verdict(desc(.rgba8, 0, 4).check(limits: l)) == "invalid")
    #expect(verdict(desc(depth: 0).check(limits: l)) == "invalid")
    #expect(verdict(desc(layers: 0).check(limits: l)) == "invalid")
    #expect(verdict(desc(mips: 0).check(limits: l)) == "invalid")
    #expect(verdict(desc(.rgba8, 16, 16, mips: 6).check(limits: l)) == "invalid")
    #expect(verdict(desc(samples: 3).check(limits: l)) == "invalid")
    #expect(verdict(desc(samples: 0).check(limits: l)) == "invalid")
    #expect(verdict(desc(depth: 2).check(limits: l)) == "invalid")
    #expect(verdict(desc(layers: 2, dimension: .d3).check(limits: l)) == "invalid")
    #expect(verdict(desc(samples: 2, dimension: .d3).check(limits: l)) == "invalid")
    #expect(verdict(desc(.rgba8, 16, 8, layers: 6, dimension: .cube).check(limits: l)) == "invalid")
    #expect(verdict(desc(layers: 5, dimension: .cube).check(limits: l)) == "invalid")
    #expect(verdict(desc(layers: 6, samples: 2, dimension: .cube).check(limits: l)) == "invalid")
    #expect(verdict(desc(mips: 2, samples: 4).check(limits: l)) == "invalid")
    #expect(verdict(desc(.astc(.b4x4), samples: 4).check(limits: l)) == "invalid")
    #expect(verdict(desc(.depth16, usage: .renderTarget).check(limits: l)) == "invalid")
    #expect(verdict(desc(.astc(.b4x4), usage: .renderTarget).check(limits: l)) == "invalid")
    #expect(verdict(desc(.rgba8, usage: .depthStencilTarget).check(limits: l)) == "invalid")
    #expect(verdict(desc(.depth16, usage: .storage).check(limits: l)) == "invalid")
    #expect(verdict(desc(.bc1rgb, usage: .storage).check(limits: l)) == "invalid")
    #expect(verdict(desc(.r8, usage: .scanout).check(limits: l)) == "invalid")
    #expect(verdict(desc(mips: 2, usage: .scanout).check(limits: l)) == "invalid")
    #expect(verdict(desc(layers: 2, usage: .scanout).check(limits: l)) == "invalid")
    #expect(desc(usage: .scanout | .renderTarget).check(limits: l) == nil)
  }

  @Test func theLimitsAreRefusedNotInvalid() {
    let l = fullLimits
    #expect(verdict(desc(.rgba8, 8192, 8).check(limits: l)) == "unsupported")
    #expect(verdict(desc(.rgba8, 4, 4, depth: 4096, dimension: .d3).check(limits: l)) == "unsupported")
    #expect(verdict(desc(layers: 1000).check(limits: l)) == "unsupported")
    #expect(verdict(desc(samples: 16).check(limits: l)) == "unsupported")
    #expect(verdict(desc(.rgba8, 8, 8, samples: 8, usage: .storage).check(limits: l)) == "unsupported")
  }

  @Test func eachFeatureTheDeviceLacksIsRefusedAsUnsupported() {
    #expect(verdict(desc(mips: 3).check(limits: without { $0.mipmaps = false })) == "unsupported")
    #expect(verdict(desc(layers: 3).check(limits: without { $0.arrayImages = false })) == "unsupported")
    #expect(verdict(desc(layers: 6, dimension: .cube).check(limits: without { $0.cubeImages = false })) == "unsupported")
    #expect(verdict(desc(layers: 12, dimension: .cube).check(limits: without { $0.arrayImages = false })) == "unsupported")
    #expect(desc(layers: 6, dimension: .cube).check(limits: without { $0.arrayImages = false }) == nil)
    #expect(verdict(desc(depth: 4, dimension: .d3).check(limits: without { $0.volumeImages = false })) == "unsupported")
    #expect(verdict(desc(samples: 4, usage: .renderTarget).check(limits: without { $0.multisample = false })) == "unsupported")
    #expect(verdict(desc(.astc(.b4x4)).check(limits: without { $0.compressedASTC = false })) == "unsupported")
    #expect(verdict(desc(.etc2rgb8).check(limits: without { $0.compressedETC2 = false })) == "unsupported")
    #expect(verdict(desc(.eacR11).check(limits: without { $0.compressedETC2 = false })) == "unsupported")
    #expect(verdict(desc(.bc3).check(limits: without { $0.compressedBC = false })) == "unsupported")
    #expect(verdict(desc(.depth32f, usage: .depthStencilTarget).check(limits: without { $0.depth = false })) == "unsupported")
    #expect(verdict(desc(.stencil8, usage: .depthStencilTarget).check(limits: without { $0.stencil = false })) == "unsupported")
    #expect(verdict(desc(.depth24stencil8, usage: .depthStencilTarget).check(limits: without { $0.stencil = false })) == "unsupported")
    // The other families and aspects are not refused by one another's missing feature.
    #expect(desc(.bc3).check(limits: without { $0.compressedASTC = false }) == nil)
    #expect(desc(.depth32f, usage: .depthStencilTarget).check(limits: without { $0.stencil = false }) == nil)
  }

  @Test func aFormatTheDeviceDoesNotListOrWontUseThatWayIsRefused() {
    var l = fullLimits
    l.formatTable = []
    #expect(verdict(desc().check(limits: l)) == "unsupported")
    l = fullLimits
    var c = l.formats(.rgba8)
    c.sampled = false
    l.setFormat(.rgba8, c)
    #expect(verdict(desc(usage: .sampled).check(limits: l)) == "unsupported")
    #expect(desc(usage: .copyDestination).check(limits: l) == nil)
    c = l.formats(.rgba8)
    c.renderTarget = false
    l.setFormat(.rgba8, c)
    #expect(verdict(desc(usage: .renderTarget).check(limits: l)) == "unsupported")
    c = l.formats(.rgba8)
    c.storage = false
    l.setFormat(.rgba8, c)
    #expect(verdict(desc(usage: .storage).check(limits: l)) == "unsupported")
    c = l.formats(.depth16)
    c.depthTarget = false
    l.setFormat(.depth16, c)
    #expect(verdict(desc(.depth16, usage: .depthStencilTarget).check(limits: l)) == "unsupported")
    c = l.formats(.bgra8)
    c.renderSamples = .one
    l.setFormat(.bgra8, c)
    #expect(verdict(desc(.bgra8, samples: 4, usage: .renderTarget).check(limits: l)) == "unsupported")
    #expect(desc(.bgra8, usage: .renderTarget).check(limits: l) == nil)
  }

  @Test func theFakeMakesWhatTheRuleAllowsAndRefusesTheRest() throws {
    let gpu = fullDevice()
    let a = try gpu.makeImage(desc(mips: 5, layers: 3, usage: .sampled))
    #expect(a.mipLevels == 5 && a.layers == 3 && a.samples == 1 && a.dimension == .d2)
    #expect(throws: GPUError.self) { try gpu.makeImage(desc(layers: 5, dimension: .cube)) }
  }
}

@Suite struct ViewRules {
  @Test func aViewOfTheWholeImageIsTheImageOnly() throws {
    let gpu = fullDevice()
    let img = try image(gpu, mips: 3, layers: 4, usage: .sampled | .storage)
    let v = ImageView(img)
    #expect(v.isWholeImage && v.dimension == .d2Array && v.mipCount == 3 && v.layerCount == 4 && v.format == .rgba8)
    #expect(ImageView(img, baseMip: 1).isWholeImage == false)
    #expect(ImageView(img, format: .rgba8uint).isWholeImage == false)
    #expect(ImageView(img, baseMip: 1, mipCount: 1).width == 8)
    let plain = try image(gpu, usage: .sampled)
    #expect(ImageView(plain).dimension == .d2)
    let cube = try image(gpu, layers: 12, dimension: .cube)
    #expect(ImageView(cube).dimension == .cubeArray && ImageView(cube, baseLayer: 0, layerCount: 6).dimension == .cube)
    let vol = try image(gpu, depth: 4, dimension: .d3)
    #expect(ImageView(vol).dimension == .d3)
  }

  @Test func theHeapTakesViewsThatFit() throws {
    let gpu = fullDevice()
    let img = try image(gpu, mips: 4, layers: 6, usage: .sampled | .storage)
    #expect(ImageView(img).check(for: .texture, limits: fullLimits) == nil)
    #expect(ImageView(img, baseMip: 2, mipCount: 1, baseLayer: 1, layerCount: 2).check(for: .texture, limits: fullLimits) == nil)
    #expect(ImageView(img, baseMip: 1, mipCount: 1).check(for: .storage, limits: fullLimits) == nil)
    #expect(ImageView(img, format: .rgba8uint).check(for: .texture, limits: fullLimits) == nil)
    try gpu.writeTexture(2, ImageView(img, baseMip: 1))
    #expect(gpu.textures[2]?.baseMip == 1)
    try gpu.writeStorageImage(1, ImageView(img, baseMip: 3, mipCount: 1))
    #expect(gpu.storageImages[1]?.baseMip == 3)
  }

  @Test func aViewOfTheWrongShapeIsInvalid() throws {
    let gpu = fullDevice()
    let img = try image(gpu, mips: 4, layers: 6, usage: .sampled | .storage)
    let l = fullLimits
    #expect(verdict(ImageView(img, baseMip: 3, mipCount: 2).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img, baseMip: 4).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img, baseLayer: 5, layerCount: 2).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img, layerCount: 0).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img, format: .rgba16float).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img, format: .depth16, aspects: .depth).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img, dimension: .d2).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img, dimension: .cube, layerCount: 6).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img, dimension: .d3).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img, aspects: .depth).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(img).check(for: .storage, limits: l)) == "invalid")  // three more levels than a storage slot holds
    let cube = try image(gpu, layers: 12, dimension: .cube)
    #expect(verdict(ImageView(cube, dimension: .cube, layerCount: 4).check(for: .texture, limits: l)) == "invalid")
    #expect(verdict(ImageView(cube, dimension: .cubeArray, layerCount: 5).check(for: .texture, limits: l)) == "invalid")
    let vol = try image(gpu, depth: 4, dimension: .d3)
    #expect(verdict(ImageView(vol, dimension: .d2).check(for: .texture, limits: l)) == "invalid")
    let notSampled = try image(gpu, usage: .copyDestination)
    #expect(ImageView(notSampled).check(for: .texture, limits: l) == .invalid("a texture that isn't sampled"))
    #expect(ImageView(notSampled).check(for: .storage, limits: l) == .invalid("a storage image that isn't"))
  }

  @Test func aDepthImageIsSampledOneAspectAtATime() throws {
    let gpu = fullDevice()
    let d = try image(gpu, .depth24stencil8, usage: .sampled | .depthStencilTarget)
    #expect(verdict(ImageView(d).check(for: .texture, limits: fullLimits)) == "invalid")
    #expect(ImageView(d, aspects: .depth).check(for: .texture, limits: fullLimits) == nil)
    #expect(ImageView(d, aspects: .stencil).check(for: .texture, limits: fullLimits) == nil)
    #expect(verdict(ImageView(d, aspects: .depth).check(for: .storage, limits: fullLimits)) == "invalid")
  }

  @Test func eachViewFeatureTheDeviceLacksIsRefused() throws {
    let gpu = fullDevice()
    let img = try image(gpu, mips: 4, layers: 12, usage: .sampled)
    let cube = try image(gpu, layers: 12, dimension: .cube)
    let vol = try image(gpu, depth: 4, dimension: .d3)
    let flat = try image(gpu)
    #expect(verdict(ImageView(img, baseMip: 1).check(for: .texture, limits: without { $0.imageViews = false })) == "unsupported")
    #expect(verdict(ImageView(flat, format: .rgba8uint).check(for: .texture, limits: without { $0.imageViews = false })) == "unsupported")
    #expect(ImageView(flat).check(for: .texture, limits: without { $0.imageViews = false }) == nil)
    #expect(verdict(ImageView(img).check(for: .texture, limits: without { $0.arrayImages = false })) == "unsupported")
    #expect(verdict(ImageView(cube, layerCount: 6).check(for: .texture, limits: without { $0.cubeImages = false })) == "unsupported")
    #expect(verdict(ImageView(vol).check(for: .texture, limits: without { $0.volumeImages = false })) == "unsupported")
    var l = fullLimits
    var c = l.formats(.rgba8)
    c.sampled = false
    l.setFormat(.rgba8, c)
    #expect(verdict(ImageView(flat).check(for: .texture, limits: l)) == "unsupported")
    let storage = try image(gpu, usage: .storage)
    c = l.formats(.rgba8)
    c.storage = false
    l.setFormat(.rgba8, c)
    #expect(verdict(ImageView(storage).check(for: .storage, limits: l)) == "unsupported")
  }

  @Test func theFakeRefusesWhatTheViewRuleRefuses() throws {
    let gpu = fullDevice()
    let img = try image(gpu, mips: 4, usage: .sampled)
    #expect(throws: GPUError.self) { try gpu.writeTexture(0, ImageView(img, baseMip: 4)) }
    let plainGPU = FakeDevice()
    let flat = try image(plainGPU)
    try plainGPU.writeTexture(0, ImageView(flat))
    #expect(throws: GPUError.self) { try plainGPU.writeTexture(1, ImageView(flat, format: .rgba8uint)) }
  }
}

@Suite struct SamplerRules {
  @Test func theOldSamplerIsStillOne() {
    let s = SamplerDescriptor(filter: .nearest, addressMode: .repeat)
    #expect(s.minFilter == .nearest && s.magFilter == .nearest && s.addressModeW == .repeat)
    #expect(s.filter == .nearest && s.addressMode == .repeat)
    #expect(SamplerDescriptor().filter == .linear && SamplerDescriptor().addressMode == .clampToEdge)
    var t = SamplerDescriptor()
    t.filter = .nearest
    t.addressMode = .mirroredRepeat
    #expect(t.minFilter == .nearest && t.magFilter == .nearest && t.addressModeV == .mirroredRepeat)
    for l in [fullLimits, FakeDevice.todaysLimits()] { #expect(s.check(limits: l) == nil && SamplerDescriptor().check(limits: l) == nil) }
  }

  @Test func contradictoryFieldsAreInvalid() {
    let l = fullLimits
    #expect(verdict(SamplerDescriptor(maxAnisotropy: 0.5).check(limits: l)) == "invalid")
    #expect(verdict(SamplerDescriptor(minLod: 4, maxLod: 2).check(limits: l)) == "invalid")
    func unnormalized(_ s: SamplerDescriptor) -> String { verdict(s.check(limits: l)) }
    #expect(unnormalized(SamplerDescriptor(minLod: 0, maxLod: 0, unnormalizedCoordinates: true)) == "ok")
    #expect(unnormalized(SamplerDescriptor(unnormalizedCoordinates: true)) == "invalid")  // maxLod isn't 0
    #expect(unnormalized(SamplerDescriptor(mipmapMode: .linear, maxLod: 0, unnormalizedCoordinates: true)) == "invalid")
    #expect(unnormalized(SamplerDescriptor(addressMode: .repeat, maxLod: 0, unnormalizedCoordinates: true)) == "invalid")
    #expect(unnormalized(SamplerDescriptor(maxLod: 0, maxAnisotropy: 4, unnormalizedCoordinates: true)) == "invalid")
    #expect(unnormalized(SamplerDescriptor(maxLod: 0, compare: .less, unnormalizedCoordinates: true)) == "invalid")
    #expect(unnormalized(SamplerDescriptor(minFilter: .nearest, magFilter: .linear, maxLod: 0, unnormalizedCoordinates: true)) == "invalid")
  }

  @Test func eachSamplerFeatureTheDeviceLacksIsRefused() {
    func refused(_ s: SamplerDescriptor, _ off: (inout DeviceFeatures) -> Void) -> Bool {
      s.check(limits: fullLimits) == nil && verdict(s.check(limits: without(off))) == "unsupported"
    }
    #expect(refused(SamplerDescriptor(minFilter: .nearest, magFilter: .linear)) { $0.samplerMinMagFilters = false })
    #expect(refused(SamplerDescriptor(addressModeU: .repeat)) { $0.samplerAxisAddressModes = false })
    #expect(refused(SamplerDescriptor(addressMode: .clampToBorder, borderColor: .opaqueWhiteFloat)) { $0.samplerBorder = false })
    #expect(refused(SamplerDescriptor(addressMode: .mirrorClampToEdge)) { $0.samplerMirrorClampToEdge = false })
    #expect(refused(SamplerDescriptor(mipmapMode: .linear)) { $0.mipmaps = false })
    #expect(refused(SamplerDescriptor(mipLodBias: 0.5)) { $0.mipmaps = false })
    #expect(refused(SamplerDescriptor(minLod: 1)) { $0.mipmaps = false })
    #expect(refused(SamplerDescriptor(maxAnisotropy: 8)) { $0.samplerAnisotropy = false })
    #expect(refused(SamplerDescriptor(compare: .lessOrEqual)) { $0.samplerCompare = false })
    #expect(refused(SamplerDescriptor(maxLod: 0, unnormalizedCoordinates: true)) { $0.unnormalizedCoordinates = false })
    #expect(verdict(SamplerDescriptor(maxAnisotropy: 32).check(limits: fullLimits)) == "unsupported")  // the device's limit is 16
  }

  @Test func theFakeKeepsTheSamplerItWasGiven() throws {
    let gpu = fullDevice()
    let s = SamplerDescriptor(addressMode: .repeat, minFilter: .linear, magFilter: .nearest, mipmapMode: .linear, maxAnisotropy: 4,
                              compare: .less)
    try gpu.writeSampler(1, s)
    #expect(gpu.samplers[1] == s)
    #expect(throws: GPUError.self) { try FakeDevice().writeSampler(0, s) }
  }
}

@Suite struct PipelineRules {
  private func pipeline(_ f: [PixelFormat] = [.rgba8], blend: BlendMode = .alpha, depth: PixelFormat? = nil,
                        depthStencil: DepthStencilState = DepthStencilState(), raster: RasterizationState = RasterizationState(),
                        multisample: MultisampleState = MultisampleState(), blends: [ColorBlendAttachment]? = nil,
                        logic: LogicOp? = nil, constants: BlendConstants = BlendConstants(), dynamic: DynamicStates = DynamicStates(),
                        topology: PrimitiveTopology = .triangleList, restart: Bool = false, patch: UInt32 = 0,
                        geometry: Bool = false, tess: Bool = false, spec: [SpecializationConstant] = [], viewMask: UInt32 = 0)
    -> GraphicsPipelineDescriptor {
    GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: f, blend: blend, topology: topology,
                               depthStencilFormat: depth, depthStencil: depthStencil, rasterization: raster, multisample: multisample,
                               attachmentBlends: blends, logicOp: logic, blendConstants: constants, dynamic: dynamic,
                               primitiveRestart: restart, patchControlPoints: patch, geometry: geometry ? module : nil,
                               tessellationControl: tess ? module : nil, tessellationEvaluation: tess ? module : nil,
                               specialization: spec, viewMask: viewMask)
  }

  private func refused(_ d: GraphicsPipelineDescriptor, _ off: (inout DeviceFeatures) -> Void) -> Bool {
    d.check(limits: fullLimits) == nil && verdict(d.check(limits: without(off))) == "unsupported"
  }

  @Test func theOldPipelineIsTheOneItWas() {
    let d = GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.bgra8srgb], blend: .opaque,
                                       topology: .triangleStrip)
    #expect(d.check(limits: fullLimits) == nil && d.check(limits: FakeDevice.todaysLimits()) == nil)
    #expect(d.effectiveBlends == [.opaque])
    #expect(GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8, .rgba8]).effectiveBlends
      == [.alphaOver, .alphaOver])
    #expect(d.targets == PipelineTargets(colorFormats: [.bgra8srgb]))
    #expect(!DepthStencilState().isEnabled && DepthStencilState(depthTest: true).isEnabled)
  }

  @Test func contradictoryStateIsInvalid() {
    let l = fullLimits
    func invalid(_ d: GraphicsPipelineDescriptor) -> Bool { verdict(d.check(limits: l)) == "invalid" }
    #expect(invalid(pipeline([])))
    #expect(invalid(pipeline([PixelFormat](repeating: .rgba8, count: 9))))
    #expect(invalid(pipeline([.depth16])))
    #expect(invalid(pipeline([.astc(.b4x4)])))
    #expect(invalid(pipeline(depth: .rgba8)))
    #expect(invalid(pipeline([.rgba8, .rgba8], blends: [.opaque, .opaque, .opaque])))
    #expect(invalid(pipeline(multisample: MultisampleState(samples: 5))))
    #expect(invalid(pipeline(multisample: MultisampleState(sampleMask: 0))))
    #expect(invalid(pipeline(multisample: MultisampleState(sampleShading: true, minSampleShading: 2))))
    #expect(invalid(pipeline(raster: RasterizationState(lineWidth: 0))))
    #expect(invalid(pipeline(depth: .depth32f, depthStencil: DepthStencilState(depthBoundsTest: true, minDepthBounds: 0.8, maxDepthBounds: 0.2))))
    #expect(invalid(pipeline(depthStencil: DepthStencilState(depthTest: true))))  // no depth attachment
    #expect(invalid(pipeline(depth: .depth32f, depthStencil: DepthStencilState(stencilTest: true))))  // no stencil aspect
    #expect(invalid(pipeline(depthStencil: DepthStencilState(depthBoundsTest: true))))
    #expect(invalid(pipeline(topology: .patchList, patch: 0, tess: true)))
    #expect(invalid(pipeline(topology: .patchList, patch: 3)))  // no tessellation stages
    #expect(invalid(pipeline(tess: true)))  // stages without a patch list
    #expect(invalid(pipeline(restart: true)))  // a list
    #expect(invalid(pipeline(topology: .lineList, restart: true)))
    #expect(invalid(pipeline(spec: [SpecializationConstant(id: 1, value: 2), SpecializationConstant(id: 1, value: 3)])))
    var half = pipeline(topology: .patchList, patch: 3, tess: true)
    half.tessellationEvaluation = nil
    #expect(invalid(half))
  }

  @Test func eachFeatureTheDeviceLacksIsRefusedAsUnsupported() {
    let stencilFormat = PixelFormat.depth24stencil8
    #expect(refused(pipeline(depth: .depth32f, depthStencil: DepthStencilState(depthTest: true, depthWrite: true))) { $0.depth = false })
    #expect(refused(pipeline(depth: stencilFormat, depthStencil: DepthStencilState(stencilTest: true))) { $0.stencil = false })
    #expect(refused(pipeline(depth: .depth32f, depthStencil: DepthStencilState(depthBoundsTest: true))) { $0.depthBounds = false })
    #expect(refused(pipeline(raster: RasterizationState(cull: .back))) { $0.cullModes = false })
    #expect(refused(pipeline(raster: RasterizationState(polygonMode: .line))) { $0.fillModeNonSolid = false })
    #expect(refused(pipeline(raster: RasterizationState(polygonMode: .point))) { $0.fillModeNonSolid = false })
    #expect(refused(pipeline(raster: RasterizationState(depthBias: true))) { $0.depthBias = false })
    #expect(refused(pipeline(raster: RasterizationState(depthClamp: true))) { $0.depthClamp = false })
    #expect(refused(pipeline(raster: RasterizationState(rasterizerDiscard: true))) { $0.rasterizerDiscard = false })
    #expect(refused(pipeline(raster: RasterizationState(lineWidth: 3))) { $0.wideLines = false })
    #expect(refused(pipeline(multisample: MultisampleState(samples: 4))) { $0.multisample = false })
    #expect(refused(pipeline(multisample: MultisampleState(alphaToCoverage: true))) { $0.alphaToCoverage = false })
    #expect(refused(pipeline(multisample: MultisampleState(alphaToOne: true))) { $0.alphaToOne = false })
    #expect(refused(pipeline(multisample: MultisampleState(sampleShading: true, minSampleShading: 0.5))) { $0.sampleShading = false })
    let weird = ColorBlendAttachment(enabled: true, srcColor: .dstColor, dstColor: .zero, colorOp: .max)
    #expect(refused(pipeline(blends: [weird])) { $0.generalBlend = false })
    #expect(refused(pipeline(blends: [ColorBlendAttachment(writeMask: .red | .alpha)])) { $0.generalBlend = false })
    #expect(refused(pipeline(constants: BlendConstants(red: 1))) { $0.generalBlend = false })
    #expect(refused(pipeline([.rgba8, .rgba8], blends: [.opaque, .alphaOver])) { $0.independentBlend = false })
    let dual = ColorBlendAttachment(enabled: true, srcColor: .src1Color, dstColor: .oneMinusSrc1Color, srcAlpha: .src1Alpha, dstAlpha: .zero)
    #expect(refused(pipeline(blends: [dual])) { $0.dualSourceBlend = false })
    #expect(refused(pipeline(logic: .xor)) { $0.logicOps = false })
    #expect(refused(pipeline(dynamic: .depthBias)) { $0.dynamicState = false })
    #expect(refused(pipeline(topology: .lineStrip)) { $0.extendedTopologies = false })
    #expect(refused(pipeline(topology: .triangleFan)) { $0.extendedTopologies = false })
    #expect(refused(pipeline(topology: .triangleStrip, restart: true)) { $0.primitiveRestart = false })
    #expect(refused(pipeline(topology: .patchList, patch: 4, tess: true)) { $0.tessellation = false })
    #expect(refused(pipeline(geometry: true)) { $0.geometryShader = false })
    #expect(refused(pipeline(spec: [SpecializationConstant(id: 0, bool: true)])) { $0.specializationConstants = false })
    #expect(refused(pipeline(viewMask: 3)) { $0.multiview = false })
    #expect(refused(pipeline([.rgba8, .rgba8])) { $0.multipleColorAttachments = false })
  }

  @Test func theLimitsAndTheFormatsCapabilitiesAreRefused() {
    let l = fullLimits
    #expect(verdict(pipeline(raster: RasterizationState(lineWidth: 64)).check(limits: l)) == "unsupported")
    #expect(pipeline(raster: RasterizationState(lineWidth: 64), dynamic: .lineWidth).check(limits: l) == nil)
    #expect(verdict(pipeline(multisample: MultisampleState(samples: 16)).check(limits: l)) == "unsupported")
    #expect(verdict(pipeline(topology: .patchList, patch: 64, tess: true).check(limits: l)) == "unsupported")
    #expect(verdict(pipeline(viewMask: 0x100).check(limits: l)) == "unsupported")
    var limited = l
    var c = limited.formats(.rgba8)
    c.renderTarget = false
    limited.setFormat(.rgba8, c)
    #expect(verdict(pipeline().check(limits: limited)) == "unsupported")
    c = l.formats(.rgba8)
    c.blendable = false
    limited.setFormat(.rgba8, c)
    #expect(verdict(pipeline(blend: .alpha).check(limits: limited)) == "unsupported")
    #expect(pipeline(blend: .opaque).check(limits: limited) == nil)
    limited = l
    c = l.formats(.depth16)
    c.depthTarget = false
    limited.setFormat(.depth16, c)
    #expect(verdict(pipeline(depth: .depth16).check(limits: limited)) == "unsupported")
  }

  @Test func theFullDeviceTakesTheFullState() throws {
    let gpu = fullDevice()
    let d = pipeline([.rgba8, .rgba16float], depth: .depth24stencil8,
                     depthStencil: DepthStencilState(depthTest: true, depthWrite: true, depthCompare: .lessOrEqual, stencilTest: true,
                                                      front: StencilFaceState(failOp: .keep, passOp: .incrementClamp, compare: .always)),
                     raster: RasterizationState(cull: .back, frontFace: .clockwise, depthBias: true, depthBiasSlope: 1.5),
                     multisample: MultisampleState(samples: 4, alphaToCoverage: true), blends: [.alphaOver, .opaque],
                     dynamic: .stencilReference | .blendConstants, spec: [SpecializationConstant(id: 7, float32: 0.5)])
    let p = try gpu.makeGraphicsPipeline(d)
    #expect(p.targets == PipelineTargets(colorFormats: [.rgba8, .rgba16float], depthStencilFormat: .depth24stencil8, samples: 4))
  }

  @Test func theDeviceThatHadNoneOfItRefusesEachNewThing() {
    let l = FakeDevice.todaysLimits()
    func refused(_ d: GraphicsPipelineDescriptor) -> Bool { verdict(d.check(limits: l)) == "unsupported" }
    #expect(refused(pipeline(depth: .depth32f)))
    #expect(refused(pipeline(raster: RasterizationState(cull: .back))))
    #expect(refused(pipeline(multisample: MultisampleState(samples: 4))))
    #expect(refused(pipeline(topology: .lineStrip)))
    #expect(refused(pipeline([.rgba16float])))
    #expect(refused(pipeline(blends: [ColorBlendAttachment(enabled: true, srcColor: .one, dstColor: .one)])))
    #expect(pipeline(blend: .alpha, topology: .triangleStrip).check(limits: l) == nil)
  }

  @Test func theBlendFactorsKnowWhichReadTheSecondOutput() {
    #expect(BlendingFactor.src1Alpha.usesSecondOutput && BlendingFactor.oneMinusSrc1Color.usesSecondOutput)
    #expect(!BlendingFactor.srcAlpha.usesSecondOutput && !BlendingFactor.constantColor.usesSecondOutput)
    #expect(!ColorBlendAttachment(enabled: false, srcColor: .src1Color).usesDualSource)
    #expect(ColorBlendAttachment(enabled: true, srcColor: .src1Color).usesDualSource)
  }
}
