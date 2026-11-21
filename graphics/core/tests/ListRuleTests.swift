// SPDX-License-Identifier: BSD-3-Clause

// The rules `GPUCommandList.validate` holds each new command and pass to (D174 amendment). For each rule there is a
// list that breaks it and the verdict it gets; and each optional capability has a device that lacks it and refuses
// `.unsupported`, a list that is the right shape on every device.

import Testing

@testable import GPUCore

private func list(_ body: (inout GPUCommandList) -> Void) -> GPUCommandList {
  var l = GPUCommandList()
  body(&l)
  return l
}

@Suite struct PassRules {
  @Test func aDepthPassIsValid() throws {
    let gpu = fullDevice()
    let c = try image(gpu, usage: .renderTarget)
    let d = try image(gpu, .depth24stencil8, usage: .depthStencilTarget)
    let p = try graphicsPipeline(gpu, depth: .depth24stencil8)
    let l = list { l in
      l.render(RenderingInfo(colors: [Attachment(image: c, load: .clear(0, 0, 0, 1))], depthStencil: DepthStencilAttachment(image: d))) { r in
        r.draw(p, root: 0, vertices: 3)
      }
    }
    #expect(l.validate(limits: fullLimits) == nil)
    try gpu.run(l, signal: 1)
  }

  @Test func aPassWithOnlyADepthAttachmentIsValidAndWithNothingIsNot() throws {
    let gpu = fullDevice()
    let d = try image(gpu, .depth32f, usage: .depthStencilTarget)
    #expect(verdict(list { $0.render(RenderingInfo(colors: [], depthStencil: DepthStencilAttachment(image: d))) { _ in } }) == "ok")
    #expect(list { $0.render(RenderingInfo(colors: [])) { _ in } }.validate(limits: fullLimits) == .invalid("a pass with no attachment"))
  }

  @Test func theAttachmentsAreHeldToTheirUsageAndFormat() throws {
    let gpu = fullDevice()
    let notTarget = try image(gpu, usage: .sampled)
    let depthAsColor = raw(.depth16, usage: .renderTarget)
    let c = try image(gpu, usage: .renderTarget)
    let colorAsDepth = raw(.rgba8, usage: .renderTarget | .depthStencilTarget)
    let d = try image(gpu, .depth16, usage: .depthStencilTarget)
    let notDepthTarget = try image(gpu, .depth16, usage: .sampled)
    let compressed = raw(.astc(.b4x4), usage: .renderTarget)
    #expect(verdict(list { $0.render(colorPass(notTarget)) { _ in } }) == "invalid")
    #expect(list { $0.render(colorPass(notTarget)) { _ in } }.validate(limits: fullLimits) == .invalid("an attachment that isn't a render target"))
    #expect(verdict(list { $0.render(colorPass(depthAsColor)) { _ in } }) == "invalid")
    #expect(verdict(list { $0.render(colorPass(compressed)) { _ in } }) == "invalid")
    #expect(verdict(list { $0.render(RenderingInfo(colors: [Attachment(image: c, load: .dontCare)], depthStencil: DepthStencilAttachment(image: colorAsDepth))) { _ in } }) == "invalid")
    #expect(verdict(list { $0.render(RenderingInfo(colors: [], depthStencil: DepthStencilAttachment(image: notDepthTarget))) { _ in } }) == "invalid")
    #expect(verdict(list { $0.render(RenderingInfo(colors: [], depthStencil: DepthStencilAttachment(image: d))) { _ in } }) == "ok")
  }

  @Test func attachmentsMatchInSizeAndSamples() throws {
    let gpu = fullDevice()
    let a = try image(gpu, 16, 16, usage: .renderTarget)
    let b = try image(gpu, 8, 8, usage: .renderTarget)
    let m = try image(gpu, samples: 4, usage: .renderTarget)
    let d = try image(gpu, .depth16, 16, 16, usage: .depthStencilTarget)
    let dm = try image(gpu, .depth16, 16, 16, samples: 4, usage: .depthStencilTarget)
    #expect(list { $0.render(colorPass(a, b)) { _ in } }.validate(limits: fullLimits) == .invalid("attachments of different sizes"))
    #expect(verdict(list { $0.render(colorPass(a, m)) { _ in } }) == "invalid")
    #expect(verdict(list { $0.render(RenderingInfo(colors: [Attachment(image: m, load: .dontCare)], depthStencil: DepthStencilAttachment(image: d))) { _ in } }) == "invalid")
    #expect(verdict(list { $0.render(RenderingInfo(colors: [Attachment(image: m, load: .dontCare)], depthStencil: DepthStencilAttachment(image: dm))) { _ in } }) == "ok")
    #expect(verdict(list { $0.render(colorPass(a, a)) { _ in } }) == "ok")
  }

  @Test func theViewsOfAttachmentsAreOneMipOfARenderableShape() throws {
    let gpu = fullDevice()
    let mips = try image(gpu, mips: 3, usage: .renderTarget)
    let layers = try image(gpu, layers: 4, usage: .renderTarget)
    func pass(_ v: ImageView, layerCount: UInt32 = 1) -> GPUCommandList {
      list { $0.render(RenderingInfo(colors: [Attachment(view: v, load: .dontCare)], layerCount: layerCount)) { _ in } }
    }
    #expect(verdict(pass(ImageView(mips, baseMip: 1, mipCount: 1))) == "ok")
    #expect(verdict(pass(ImageView(mips, baseMip: 0, mipCount: 2))) == "invalid")
    #expect(verdict(pass(ImageView(layers, baseLayer: 1, layerCount: 1))) == "ok")
    #expect(verdict(pass(ImageView(layers, baseLayer: 0, layerCount: 4), layerCount: 4)) == "ok")
    #expect(verdict(pass(ImageView(layers, baseLayer: 0, layerCount: 2), layerCount: 4)) == "invalid")
    #expect(verdict(pass(ImageView(layers, baseLayer: 0, layerCount: 4), layerCount: 0)) == "invalid")
    #expect(verdict(pass(ImageView(layers, baseMip: 0, mipCount: 1, baseLayer: 0, layerCount: 4), layerCount: 4)) == "ok")
    let cube = try image(gpu, layers: 6, dimension: .cube, usage: .renderTarget)
    #expect(verdict(pass(ImageView(cube, dimension: .cube))) == "invalid")
    #expect(verdict(pass(ImageView(cube, dimension: .d2Array))) == "ok")
    let bad = Attachment(view: ImageView(mips, baseMip: 3), load: .dontCare)
    #expect(verdict(list { $0.render(RenderingInfo(colors: [bad])) { _ in } }) == "invalid")
  }

  @Test func clearingAnIntegerAttachmentTakesAnIntegerClear() throws {
    let gpu = fullDevice()
    let ints = try image(gpu, .rgba8uint, usage: .renderTarget)
    #expect(verdict(list { $0.render(colorPass(ints, load: .clear(0, 0, 0, 1))) { _ in } }) == "invalid")
    #expect(verdict(list { $0.render(colorPass(ints, load: .dontCare)) { _ in } }) == "ok")
  }

  @Test func layersAndViewMasksAreHeldToTheirRules() throws {
    let gpu = fullDevice()
    let layered = try image(gpu, layers: 4, usage: .renderTarget)
    func pass(layerCount: UInt32, viewMask: UInt32 = 0) -> GPUCommandList {
      list { $0.render(RenderingInfo(colors: [Attachment(image: layered, load: .dontCare)], layerCount: layerCount, viewMask: viewMask)) { _ in } }
    }
    #expect(verdict(pass(layerCount: 4)) == "ok")
    #expect(verdict(pass(layerCount: 1, viewMask: 0b101)) == "ok")
    #expect(verdict(pass(layerCount: 4, viewMask: 1)) == "invalid")  // a multiview pass has one "layer" of views
    #expect(verdict(pass(layerCount: 1, viewMask: 0b10000)) == "invalid")  // a view past the attachment's layers
    #expect(verdict(pass(layerCount: 4), without { $0.arrayImages = false }) == "unsupported")
    #expect(verdict(pass(layerCount: 1, viewMask: 3), without { $0.multiview = false }) == "unsupported")
    var small = fullLimits
    small.maxMultiviewViews = 2
    #expect(verdict(pass(layerCount: 1, viewMask: 0b101), small) == "unsupported")
    #expect(verdict(pass(layerCount: 1, viewMask: 0b11), small) == "ok")
  }

  @Test func theRenderAreaLiesInsideTheAttachments() throws {
    let gpu = fullDevice()
    let a = try image(gpu, 16, 16, usage: .renderTarget)
    func pass(_ area: RenderArea?) -> GPUCommandList {
      list { $0.render(RenderingInfo(colors: [Attachment(image: a, load: .dontCare)], renderArea: area)) { _ in } }
    }
    #expect(verdict(pass(RenderArea(x: 4, y: 4, width: 8, height: 8))) == "ok")
    #expect(verdict(pass(RenderArea(x: 12, y: 0, width: 8, height: 8))) == "invalid")
    #expect(verdict(pass(RenderArea(x: -1, y: 0, width: 8, height: 8))) == "invalid")
    #expect(verdict(pass(RenderArea(width: 0, height: 8))) == "invalid")
  }

  @Test func multisamplePassesNeedTheFeatureTheCountAndTheFormatsCapability() throws {
    let gpu = fullDevice()
    let m = try image(gpu, samples: 4, usage: .renderTarget)
    let l = list { $0.render(colorPass(m)) { _ in } }
    #expect(verdict(l) == "ok")
    #expect(verdict(l, without { $0.multisample = false }) == "unsupported")
    var few = fullLimits
    few.maxSamples = 2
    #expect(verdict(l, few) == "unsupported")
    var caps = fullLimits
    var c = caps.formats(.rgba8)
    c.renderSamples = .upToTwo
    caps.setFormat(.rgba8, c)
    #expect(verdict(l, caps) == "unsupported")
  }

  @Test func resolvingAttachmentsIsHeldToTheirMatch() throws {
    let gpu = fullDevice()
    let m = try image(gpu, samples: 4, usage: .renderTarget)
    let one = try image(gpu, usage: .renderTarget)
    let wrongFormat = try image(gpu, .bgra8, usage: .renderTarget)
    let wrongSize = try image(gpu, 8, 8, usage: .renderTarget)
    let multi = try image(gpu, samples: 4, usage: .renderTarget)
    let notTarget = try image(gpu, usage: .sampled)
    func pass(_ src: GPUImage, _ r: GPUImage) -> GPUCommandList {
      list { $0.render(RenderingInfo(colors: [Attachment(view: ImageView(src), load: .dontCare, resolve: ImageView(r))])) { _ in } }
    }
    #expect(verdict(pass(m, one)) == "ok")
    #expect(verdict(pass(m, wrongFormat)) == "invalid")
    #expect(verdict(pass(m, wrongSize)) == "invalid")
    #expect(verdict(pass(m, multi)) == "invalid")
    #expect(verdict(pass(m, notTarget)) == "invalid")
    #expect(verdict(pass(one, one)) == "invalid")  // nothing to resolve
    #expect(verdict(pass(m, one), without { $0.resolveAttachments = false }) == "unsupported")
  }

  @Test func theDepthAttachmentsFeaturesAndLoads() throws {
    let gpu = fullDevice()
    let d = try image(gpu, .depth24stencil8, usage: .depthStencilTarget)
    let depthOnly = try image(gpu, .depth32f, usage: .depthStencilTarget)
    func pass(_ a: DepthStencilAttachment) -> GPUCommandList { list { $0.render(RenderingInfo(colors: [], depthStencil: a)) { _ in } } }
    #expect(verdict(pass(DepthStencilAttachment(image: d, depthLoad: .load, stencilLoad: .load))) == "ok")
    #expect(verdict(pass(DepthStencilAttachment(image: d, depthLoad: .load)), without { $0.loadAttachments = false }) == "unsupported")
    // A stencil load of a format with no stencil is nothing to load.
    #expect(verdict(pass(DepthStencilAttachment(image: depthOnly, depthLoad: .clear, stencilLoad: .load)), without { $0.loadAttachments = false }) == "ok")
    #expect(verdict(pass(DepthStencilAttachment(image: d)), without { $0.depth = false }) == "unsupported")
    #expect(verdict(pass(DepthStencilAttachment(image: d)), without { $0.stencil = false }) == "unsupported")
    #expect(verdict(pass(DepthStencilAttachment(image: depthOnly)), without { $0.stencil = false }) == "ok")
    let onlyDepth = ImageView(d, aspects: .depth)
    #expect(verdict(pass(DepthStencilAttachment(view: onlyDepth))) == "invalid")  // an attachment is the format's every aspect
    var noDepthTarget = fullLimits
    var c = noDepthTarget.formats(.depth32f)
    c.depthTarget = false
    noDepthTarget.setFormat(.depth32f, c)
    #expect(verdict(pass(DepthStencilAttachment(image: depthOnly)), noDepthTarget) == "unsupported")
  }

  @Test func resolvingDepthNeedsItsOwnFeature() throws {
    let gpu = fullDevice()
    let m = try image(gpu, .depth16, samples: 4, usage: .depthStencilTarget)
    let one = try image(gpu, .depth16, usage: .depthStencilTarget)
    let l = list {
      $0.render(RenderingInfo(colors: [], depthStencil: DepthStencilAttachment(view: ImageView(m), resolve: ImageView(one)))) { _ in }
    }
    #expect(verdict(l) == "ok")
    #expect(verdict(l, without { $0.depthStencilResolve = false }) == "unsupported")
  }

  @Test func theColourAttachmentCountIsAFeatureAndALimit() throws {
    let gpu = fullDevice()
    let a = try image(gpu, usage: .renderTarget)
    let l = list { $0.render(colorPass(a, a, a)) { _ in } }
    #expect(verdict(l) == "ok")
    #expect(verdict(l, without { $0.multipleColorAttachments = false }) == "unsupported")
    var two = fullLimits
    two.maxColorAttachments = 2
    #expect(verdict(l, two) == "unsupported")
    let nine = list { $0.render(colorPass(a, a, a, a, a, a, a, a, a)) { _ in } }
    #expect(nine.validate(limits: fullLimits) == .invalid("a pass with more than eight attachments"))
  }

  @Test func aDrawNeedsAPipelineMadeForTheAttachments() throws {
    let gpu = fullDevice()
    let c = try image(gpu, usage: .renderTarget)
    let d = try image(gpu, .depth16, usage: .depthStencilTarget)
    let m = try image(gpu, samples: 4, usage: .renderTarget)
    let plain = try graphicsPipeline(gpu)
    let withDepth = try graphicsPipeline(gpu, depth: .depth16)
    let other = try graphicsPipeline(gpu, formats: [.bgra8])
    let msaa = try graphicsPipeline(gpu, samples: 4)
    func draw(_ info: RenderingInfo, _ p: GPUPipeline) -> GPUCommandList { list { $0.render(info) { $0.draw(p, root: 0, vertices: 3) } } }
    let colorOnly = colorPass(c)
    let both = RenderingInfo(colors: [Attachment(image: c, load: .dontCare)], depthStencil: DepthStencilAttachment(image: d))
    #expect(verdict(draw(colorOnly, plain)) == "ok")
    #expect(verdict(draw(both, withDepth)) == "ok")
    #expect(verdict(draw(colorOnly, other)) == "invalid")
    #expect(verdict(draw(colorOnly, withDepth)) == "invalid")
    #expect(verdict(draw(both, plain)) == "invalid")
    #expect(verdict(draw(colorPass(m), plain)) == "invalid")
    #expect(verdict(draw(colorPass(m), msaa)) == "ok")
    // A pipeline whose backend didn't say what it draws into isn't held to it.
    #expect(verdict(draw(colorOnly, GPUPipeline(handle: 99, kind: .graphics))) == "ok")
    #expect(draw(colorOnly, other).validate(limits: fullLimits) == .invalid("a draw with a pipeline made for other attachments"))
  }
}

@Suite struct ImageCommandRules {
  @Test func copyingImagesChecksUsageFormatSamplesAndRegions() throws {
    let gpu = fullDevice()
    let a = try image(gpu, mips: 3, layers: 4)
    let b = try image(gpu, mips: 3, layers: 4)
    let ok = list { $0.copyImage(a, to: b, regions: [region(16, 16)]) }
    #expect(verdict(ok) == "ok")
    let sub = ImageSubresourceLayers(mip: 1, baseLayer: 1, layerCount: 3)
    #expect(verdict(list { $0.copyImage(a, to: b, regions: [ImageCopyRegion(srcSubresource: sub, dstSubresource: sub, extent: Extent3D(width: 8, height: 8))]) }) == "ok")
    try gpu.run(ok, signal: 1)
    let noSource = try image(gpu, usage: .copyDestination)
    let noDest = try image(gpu, usage: .copySource)
    #expect(list { $0.copyImage(noSource, to: b, regions: [region()]) }.validate(limits: fullLimits) == .invalid("a copy out of an image that isn't a copy source"))
    #expect(list { $0.copyImage(a, to: noDest, regions: [region()]) }.validate(limits: fullLimits) == .invalid("a copy into an image that isn't a copy destination"))
    #expect(verdict(list { $0.copyImage(a, to: b, regions: []) }) == "invalid")
    #expect(verdict(list { $0.render(colorPass(try! image(gpu, usage: .renderTarget))) { $0.copyImage(a, to: b, regions: [region()]) } }) == "invalid")
  }

  @Test func theFormatsOfACopyMustBeCompatible() throws {
    let gpu = fullDevice()
    let rgba = try image(gpu)
    let bgra = try image(gpu, .bgra8)
    let r32 = try image(gpu, .r32float)
    let float4 = try image(gpu, .rgba16float)
    let depth = try image(gpu, .depth16, usage: .copySource | .copyDestination)
    let depthF = try image(gpu, .depth32f, usage: .copySource | .copyDestination)
    let astc = try image(gpu, .astc(.b4x4))
    let astcSRGB = try image(gpu, .astcSRGB(.b4x4))
    let astc5 = try image(gpu, .astc(.b5x5))
    let bc4 = try image(gpu, .bc4)
    let bc1 = try image(gpu, .bc1rgb)
    func copy(_ s: GPUImage, _ d: GPUImage) -> String { verdict(list { $0.copyImage(s, to: d, regions: [region()]) }) }
    #expect(copy(rgba, bgra) == "ok")  // the same four bytes
    #expect(copy(rgba, r32) == "ok")
    #expect(copy(rgba, float4) == "invalid")
    #expect(copy(rgba, depth) == "invalid")
    #expect(copy(depth, depthF) == "invalid")
    #expect(copy(astc, astcSRGB) == "ok")  // one class
    #expect(copy(astc, astc5) == "invalid")
    #expect(copy(bc4, bc1) == "invalid")  // both eight bytes, different classes
    #expect(copy(astc, rgba) == "invalid")
    let ms = try image(gpu, samples: 4, usage: .renderTarget | .copySource | .copyDestination)
    #expect(copy(rgba, ms) == "invalid")  // samples differ
  }

  @Test func theRegionsOfACopyLieInsideTheirSubresources() throws {
    let gpu = fullDevice()
    let a = try image(gpu, 16, 16, mips: 3, layers: 4)
    let b = try image(gpu, 16, 16, mips: 3, layers: 4)
    let vol = try image(gpu, 8, 8, depth: 8, dimension: .d3)
    func copy(_ r: ImageCopyRegion, from: GPUImage? = nil, to: GPUImage? = nil) -> String {
      verdict(list { $0.copyImage(from ?? a, to: to ?? b, regions: [r]) })
    }
    #expect(copy(region(17, 4)) == "invalid")  // past the image
    #expect(copy(ImageCopyRegion(srcOffset: Offset3D(x: 13), extent: Extent3D(width: 4, height: 4))) == "invalid")
    #expect(copy(ImageCopyRegion(dstOffset: Offset3D(y: -1), extent: Extent3D(width: 4, height: 4))) == "invalid")
    #expect(copy(ImageCopyRegion(extent: Extent3D(width: 0, height: 4))) == "invalid")
    #expect(copy(ImageCopyRegion(srcSubresource: ImageSubresourceLayers(mip: 3), extent: Extent3D(width: 1, height: 1))) == "invalid")
    #expect(copy(ImageCopyRegion(srcSubresource: ImageSubresourceLayers(mip: 2), extent: Extent3D(width: 4, height: 4))) == "ok")
    #expect(copy(ImageCopyRegion(srcSubresource: ImageSubresourceLayers(mip: 2), extent: Extent3D(width: 5, height: 4))) == "invalid")
    #expect(copy(ImageCopyRegion(srcSubresource: ImageSubresourceLayers(baseLayer: 3, layerCount: 2), dstSubresource: ImageSubresourceLayers(layerCount: 2), extent: Extent3D(width: 1, height: 1))) == "invalid")
    #expect(copy(ImageCopyRegion(srcSubresource: ImageSubresourceLayers(layerCount: 0), dstSubresource: ImageSubresourceLayers(layerCount: 0), extent: Extent3D(width: 1, height: 1))) == "invalid")
    #expect(copy(ImageCopyRegion(srcSubresource: ImageSubresourceLayers(layerCount: 2), dstSubresource: ImageSubresourceLayers(layerCount: 1), extent: Extent3D(width: 1, height: 1))) == "invalid")
    #expect(copy(ImageCopyRegion(srcSubresource: ImageSubresourceLayers(aspects: .depth), extent: Extent3D(width: 1, height: 1))) == "invalid")
    #expect(copy(ImageCopyRegion(srcOffset: Offset3D(z: 1), extent: Extent3D(width: 1, height: 1))) == "invalid")  // a 2D image's depth
    #expect(copy(ImageCopyRegion(extent: Extent3D(width: 1, height: 1, depth: 2))) == "invalid")
    let vol2 = try image(gpu, 8, 8, depth: 8, dimension: .d3)
    #expect(copy(ImageCopyRegion(srcOffset: Offset3D(z: 4), extent: Extent3D(width: 8, height: 8, depth: 4)), from: vol, to: vol2) == "ok")
    #expect(copy(ImageCopyRegion(srcOffset: Offset3D(z: 5), extent: Extent3D(width: 8, height: 8, depth: 4)), from: vol, to: vol2) == "invalid")
  }

  @Test func aCompressedCopyLandsOnBlocksOrTheImagesEdge() throws {
    let gpu = fullDevice()
    let a = try image(gpu, .astc(.b4x4), 10, 10)
    let b = try image(gpu, .astc(.b4x4), 10, 10)
    func copy(_ r: ImageCopyRegion) -> String { verdict(list { $0.copyImage(a, to: b, regions: [r]) }) }
    #expect(copy(region(8, 8)) == "ok")
    #expect(copy(region(10, 10)) == "ok")  // to the edge, a partial block
    #expect(copy(region(6, 8)) == "invalid")
    #expect(copy(ImageCopyRegion(srcOffset: Offset3D(x: 2), extent: Extent3D(width: 4, height: 4))) == "invalid")
    #expect(copy(ImageCopyRegion(srcOffset: Offset3D(x: 8), dstOffset: Offset3D(x: 8), extent: Extent3D(width: 2, height: 4))) == "ok")
  }

  @Test func copyingAnImageOntoItselfNeedsDisjointRegions() throws {
    let gpu = fullDevice()
    let a = try image(gpu, mips: 2, layers: 2)
    func copy(_ r: ImageCopyRegion) -> String { verdict(list { $0.copyImage(a, to: a, regions: [r]) }) }
    #expect(copy(ImageCopyRegion(dstOffset: Offset3D(x: 8), extent: Extent3D(width: 8, height: 8))) == "ok")
    #expect(copy(ImageCopyRegion(dstOffset: Offset3D(x: 4), extent: Extent3D(width: 8, height: 8))) == "invalid")
    #expect(copy(ImageCopyRegion(dstSubresource: ImageSubresourceLayers(baseLayer: 1), extent: Extent3D(width: 8, height: 8))) == "ok")
    #expect(copy(ImageCopyRegion(dstSubresource: ImageSubresourceLayers(mip: 1), extent: Extent3D(width: 8, height: 8))) == "ok")
  }

  @Test func eachImageCommandIsAFeatureTheDeviceMayLack() throws {
    let gpu = fullDevice()
    let a = try image(gpu, 8, 8)
    let b = try image(gpu, 8, 8)
    let m = try image(gpu, samples: 4, usage: .renderTarget | .copySource | .copyDestination)
    let buf = try gpu.allocate(.upload, bytes: 4096)
    let target = try image(gpu, usage: .copyDestination | .copySource)
    func refused(_ l: GPUCommandList, _ off: (inout DeviceFeatures) -> Void) -> Bool {
      verdict(l) == "ok" && verdict(l, without(off)) == "unsupported"
    }
    #expect(refused(list { $0.copyImage(a, to: b, regions: [region()]) }) { $0.copyImage = false })
    #expect(refused(list { $0.blitImage(a, to: b, regions: [blitRegion()]) }) { $0.blitImage = false })
    #expect(refused(list { $0.resolveImage(m, to: a, regions: [region()]) }) { $0.resolveImage = false })
    #expect(refused(list { $0.copy(buf, to: target, regions: [BufferImageRegion(imageExtent: Extent3D(width: 4, height: 4))]) }) { $0.imageRegionCopies = false })
    #expect(refused(list { $0.copy(target, to: buf, regions: [BufferImageRegion(imageExtent: Extent3D(width: 4, height: 4))]) }) { $0.imageRegionCopies = false })
    #expect(refused(list { $0.fill(buf, bytes: 16, value: 7) }) { $0.fillBuffer = false })
    #expect(refused(list { $0.update(buf, data: [1, 2, 3, 4]) }) { $0.updateBuffer = false })
    #expect(refused(list { $0.clear(a, color: .float(0, 0, 0, 1)) }) { $0.clearImage = false })
    // The same lists, on a device that has what they use, are the right shape.
    #expect(verdict(list { $0.copyImage(a, to: b, regions: [region()]) }, FakeDevice.todaysLimits()) == "unsupported")
  }

  @Test func blittingChecksTheFormatsFiltersAndCorners() throws {
    let gpu = fullDevice()
    let a = try image(gpu, 16, 16)
    let b = try image(gpu, 8, 8)
    let ints = try image(gpu, .rgba8uint)
    let sints = try image(gpu, .rgba8sint)
    let depth = try image(gpu, .depth16, usage: .copySource | .copyDestination)
    let depth2 = try image(gpu, .depth16, usage: .copySource | .copyDestination)
    let astc = try image(gpu, .astc(.b4x4))
    let ms = try image(gpu, samples: 4, usage: .renderTarget | .copySource | .copyDestination)
    func blit(_ s: GPUImage, _ d: GPUImage, _ r: ImageBlitRegion = blitRegion(), _ f: SamplerFilter = .nearest) -> String {
      verdict(list { $0.blitImage(s, to: d, regions: [r], filter: f) })
    }
    #expect(blit(a, b, ImageBlitRegion(srcMax: Offset3D(x: 16, y: 16, z: 1), dstMax: Offset3D(x: 8, y: 8, z: 1))) == "ok")
    #expect(blit(a, b, ImageBlitRegion(srcMax: Offset3D(x: 16, y: 16, z: 1), dstMax: Offset3D(x: 8, y: 8, z: 1)), .linear) == "ok")
    #expect(blit(a, ints) == "invalid")  // float into integer
    #expect(blit(ints, sints) == "invalid")  // unsigned into signed
    #expect(blit(ints, ints) == "ok")
    #expect(blit(ints, ints, blitRegion(), .linear) == "invalid")
    let d = ImageSubresourceLayers(aspects: .depth)
    let depthRegion = ImageBlitRegion(srcSubresource: d, srcMax: Offset3D(x: 4, y: 4, z: 1), dstSubresource: d, dstMax: Offset3D(x: 4, y: 4, z: 1))
    #expect(blit(depth, depth2, depthRegion) == "ok")
    #expect(blit(depth, depth2, depthRegion, .linear) == "invalid")
    #expect(blit(depth, depth2) == "invalid")  // a colour region of a depth image
    #expect(blit(depth, a) == "invalid")
    #expect(blit(astc, a) == "invalid")
    #expect(blit(ms, a) == "invalid")
    // Corners: inside, flipped, equal or outside.
    let flip = ImageBlitRegion(srcMin: Offset3D(x: 8), srcMax: Offset3D(x: 0, y: 8, z: 1), dstMax: Offset3D(x: 8, y: 8, z: 1))
    #expect(blit(a, b, flip) == "ok")
    #expect(blit(a, b, ImageBlitRegion(srcMax: Offset3D(x: 17, y: 4, z: 1), dstMax: Offset3D(x: 4, y: 4, z: 1))) == "invalid")
    #expect(blit(a, b, ImageBlitRegion(srcMax: Offset3D(x: 4, y: 4, z: 1), dstMax: Offset3D(x: 9, y: 4, z: 1))) == "invalid")
    #expect(blit(a, b, ImageBlitRegion(srcMin: Offset3D(x: 4), srcMax: Offset3D(x: 4, y: 4, z: 1), dstMax: Offset3D(x: 4, y: 4, z: 1))) == "invalid")
    #expect(blit(a, b, ImageBlitRegion(srcMax: Offset3D(x: 4, y: 4, z: 2), dstMax: Offset3D(x: 4, y: 4, z: 1))) == "invalid")
    #expect(blit(a, b, ImageBlitRegion(srcMin: Offset3D(x: -1), srcMax: Offset3D(x: 4, y: 4, z: 1), dstMax: Offset3D(x: 4, y: 4, z: 1))) == "invalid")
    #expect(verdict(list { $0.blitImage(a, to: b, regions: [], filter: .nearest) }) == "invalid")
  }

  @Test func aBlitIsHeldToTheFormatsCapabilities() throws {
    let gpu = fullDevice()
    let a = try image(gpu, 16, 16)
    let b = try image(gpu, .rgba32float, 16, 16)
    let l = list { $0.blitImage(a, to: b, regions: [blitRegion()], filter: .nearest) }
    #expect(verdict(l) == "ok")
    var caps = fullLimits
    var c = caps.formats(.rgba8)
    c.blitSource = false
    caps.setFormat(.rgba8, c)
    #expect(verdict(l, caps) == "unsupported")
    caps = fullLimits
    c = caps.formats(.rgba32float)
    c.blitDestination = false
    caps.setFormat(.rgba32float, c)
    #expect(verdict(l, caps) == "unsupported")
    // A linear blit reads the source filtered: rgba32float is not.
    let c32 = try image(gpu, .rgba32float, 16, 16)
    let linear = list { $0.blitImage(c32, to: a, regions: [blitRegion()], filter: .linear) }
    #expect(verdict(linear) == "unsupported")
    #expect(linear.validate(features: fullLimits.features) == nil)  // by the features alone, it's fine
  }

  @Test func resolvingAnImageNeedsMultisampledIntoSingle() throws {
    let gpu = fullDevice()
    let m = try image(gpu, samples: 4, usage: .renderTarget | .copySource | .copyDestination)
    let one = try image(gpu)
    let m2 = try image(gpu, samples: 4, usage: .renderTarget | .copySource | .copyDestination)
    let bgra = try image(gpu, .bgra8)
    let depth = try image(gpu, .depth16, samples: 4, usage: .depthStencilTarget | .copySource | .copyDestination)
    let depth1 = try image(gpu, .depth16, usage: .copySource | .copyDestination)
    func resolve(_ s: GPUImage, _ d: GPUImage, _ r: ImageCopyRegion = region()) -> String {
      verdict(list { $0.resolveImage(s, to: d, regions: [r]) })
    }
    #expect(resolve(m, one) == "ok")
    #expect(resolve(one, m) == "invalid")
    #expect(resolve(one, one) == "invalid")
    #expect(resolve(m, m2) == "invalid")
    #expect(resolve(m, bgra) == "invalid")
    #expect(resolve(depth, depth1) == "invalid")
    #expect(resolve(m, one, region(32, 4)) == "invalid")
    let noSource = try image(gpu, usage: .copyDestination)
    #expect(resolve(m, noSource) == "ok")
  }

  @Test func bufferToImageRegionsFitTheirMemory() throws {
    let gpu = fullDevice()
    let img = try image(gpu, 16, 16, mips: 2, layers: 2)
    let buf = try gpu.allocate(.upload, bytes: 16 * 16 * 4)
    func to(_ r: BufferImageRegion, _ m: GPUMemory? = nil, _ i: GPUImage? = nil) -> String {
      verdict(list { $0.copy(m ?? buf, to: i ?? img, regions: [r]) })
    }
    func from(_ r: BufferImageRegion) -> String { verdict(list { $0.copy(img, to: buf, regions: [r]) }) }
    #expect(to(BufferImageRegion(imageExtent: Extent3D(width: 16, height: 16))) == "ok")
    #expect(from(BufferImageRegion(imageExtent: Extent3D(width: 16, height: 16))) == "ok")
    #expect(to(BufferImageRegion(bufferOffset: 4, imageExtent: Extent3D(width: 16, height: 16))) == "invalid")  // past the end
    #expect(to(BufferImageRegion(bufferOffset: 2, imageExtent: Extent3D(width: 1, height: 1))) == "invalid")  // not a texel multiple
    #expect(to(BufferImageRegion(bufferOffset: -4, imageExtent: Extent3D(width: 1, height: 1))) == "invalid")
    #expect(to(BufferImageRegion(bufferRowLength: 8, imageExtent: Extent3D(width: 16, height: 16))) == "invalid")  // a row shorter than the region
    #expect(to(BufferImageRegion(bufferImageHeight: 8, imageExtent: Extent3D(width: 16, height: 16))) == "invalid")
    #expect(to(BufferImageRegion(bufferRowLength: 32, imageExtent: Extent3D(width: 4, height: 2))) == "ok")  // rows 32 apart: 1 * 128 + 16
    #expect(to(BufferImageRegion(bufferRowLength: 96, imageExtent: Extent3D(width: 4, height: 4))) == "invalid")  // 3 * 384 + 16 > 1024
    #expect(to(BufferImageRegion(subresource: ImageSubresourceLayers(mip: 1, layerCount: 2), imageExtent: Extent3D(width: 8, height: 8))) == "ok")
    #expect(to(BufferImageRegion(subresource: ImageSubresourceLayers(mip: 2), imageExtent: Extent3D(width: 1, height: 1))) == "invalid")
    #expect(to(BufferImageRegion(subresource: ImageSubresourceLayers(layerCount: 3), imageExtent: Extent3D(width: 1, height: 1))) == "invalid")
    #expect(to(BufferImageRegion(imageOffset: Offset3D(x: 9), imageExtent: Extent3D(width: 8, height: 1))) == "invalid")
    #expect(to(BufferImageRegion(subresource: ImageSubresourceLayers(layerCount: 2), imageExtent: Extent3D(width: 16, height: 16))) == "invalid")  // two layers don't fit
    let noDest = try image(gpu, usage: .copySource)
    #expect(list { $0.copy(buf, to: noDest, regions: [BufferImageRegion(imageExtent: Extent3D(width: 1, height: 1))]) }.validate(limits: fullLimits) == .invalid("a copy into an image that isn't a copy destination"))
    let noSource = try image(gpu, usage: .copyDestination)
    #expect(list { $0.copy(noSource, to: buf, regions: [BufferImageRegion(imageExtent: Extent3D(width: 1, height: 1))]) }.validate(limits: fullLimits) == .invalid("a copy out of an image that isn't a copy source"))
    #expect(verdict(list { $0.copy(buf, to: img, regions: []) }) == "invalid")
    let ms = try image(gpu, samples: 4, usage: .renderTarget | .copySource | .copyDestination)
    #expect(to(BufferImageRegion(imageExtent: Extent3D(width: 1, height: 1)), nil, ms) == "invalid")
  }

  @Test func depthAndStencilCopiesNameOneAspect() throws {
    let gpu = fullDevice()
    let img = try image(gpu, .depth32fstencil8, 8, 8, usage: .copySource | .copyDestination)
    let buf = try gpu.allocate(.upload, bytes: 8 * 8 * 4)
    func to(_ aspects: ImageAspects) -> String {
      verdict(list { $0.copy(buf, to: img, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: aspects), imageExtent: Extent3D(width: 8, height: 8))]) })
    }
    #expect(to(.depth) == "ok")  // four bytes a texel
    #expect(to(.stencil) == "ok")  // one byte a texel
    #expect(to(.depthStencil) == "invalid")
    #expect(to(.color) == "invalid")
    let small = try gpu.allocate(.upload, bytes: 8 * 8 * 4 - 1)
    #expect(verdict(list { $0.copy(small, to: img, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .depth), imageExtent: Extent3D(width: 8, height: 8))]) }) == "invalid")
    let color = try image(gpu, 8, 8)
    #expect(verdict(list { $0.copy(buf, to: color, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .depth), imageExtent: Extent3D(width: 8, height: 8))]) }) == "invalid")
  }

  @Test func aCompressedBufferCopyCountsBlocks() throws {
    let gpu = fullDevice()
    let img = try image(gpu, .astc(.b4x4), 12, 8)
    let exact = try gpu.allocate(.upload, bytes: 3 * 2 * 16)
    let short = try gpu.allocate(.upload, bytes: 3 * 2 * 16 - 1)
    func to(_ m: GPUMemory, _ r: BufferImageRegion) -> String { verdict(list { $0.copy(m, to: img, regions: [r]) }) }
    let whole = BufferImageRegion(imageExtent: Extent3D(width: 12, height: 8))
    #expect(to(exact, whole) == "ok")
    #expect(to(short, whole) == "invalid")
    #expect(to(exact, BufferImageRegion(bufferOffset: 8, imageExtent: Extent3D(width: 4, height: 4))) == "invalid")  // not a block multiple
    #expect(to(exact, BufferImageRegion(bufferRowLength: 6, imageExtent: Extent3D(width: 4, height: 4))) == "invalid")  // not whole blocks
    #expect(to(exact, BufferImageRegion(imageOffset: Offset3D(x: 2), imageExtent: Extent3D(width: 4, height: 4))) == "invalid")
  }

  @Test func theOldWholeImageCopyKeepsItsMeaningForTheNewImages() throws {
    let gpu = fullDevice()
    let mips = try image(gpu, 16, 16, mips: 3, layers: 2)
    let big = try gpu.allocate(.upload, bytes: 16 * 16 * 4)
    let small = try gpu.allocate(.upload, bytes: 16 * 16 * 4 - 1)
    #expect(verdict(list { $0.copy(big, to: mips) }) == "ok")  // mip 0 of layer 0
    #expect(verdict(list { $0.copy(small, to: mips) }) == "invalid")
    #expect(verdict(list { $0.copy(mips, to: big) }) == "ok")
    let astc = try image(gpu, .astc(.b4x4), 16, 16)
    let blocks = try gpu.allocate(.upload, bytes: 16 * 16)
    #expect(verdict(list { $0.copy(blocks, to: astc) }) == "ok")
    let depth = try image(gpu, .depth16, usage: .copyDestination | .copySource)
    #expect(verdict(list { $0.copy(big, to: depth) }) == "invalid")
    let vol = try image(gpu, 4, 4, depth: 4, dimension: .d3)
    let volBytes = try gpu.allocate(.upload, bytes: 4 * 4 * 4 * 4)
    #expect(verdict(list { $0.copy(volBytes, to: vol) }) == "ok")
    let ms = try image(gpu, samples: 4, usage: .renderTarget | .copySource | .copyDestination)
    #expect(verdict(list { $0.copy(big, to: ms) }) == "invalid")
  }

  @Test func clearsNameTheTypeOfTheFormat() throws {
    let gpu = fullDevice()
    let f = try image(gpu, mips: 2, layers: 2)
    let u = try image(gpu, .rgba8uint)
    let s = try image(gpu, .rgba16sint)
    let d = try image(gpu, .depth24stencil8, usage: .copyDestination)
    let astc = try image(gpu, .astc(.b4x4))
    #expect(verdict(list { $0.clear(f, color: .float(1, 0, 0, 1)) }) == "ok")
    #expect(verdict(list { $0.clear(f, color: .uint(1, 0, 0, 1)) }) == "invalid")
    #expect(verdict(list { $0.clear(u, color: .uint(1, 0, 0, 1)) }) == "ok")
    #expect(verdict(list { $0.clear(u, color: .sint(1, 0, 0, 1)) }) == "invalid")
    #expect(verdict(list { $0.clear(s, color: .sint(-1, 0, 0, 1)) }) == "ok")
    #expect(verdict(list { $0.clear(d, color: .float(1, 0, 0, 1)) }) == "invalid")
    #expect(verdict(list { $0.clear(astc, color: .float(1, 0, 0, 1)) }) == "invalid")
    #expect(verdict(list { $0.clear(f, color: .float(0, 0, 0, 0), ranges: [ImageSubresourceRange(baseMip: 1, mipCount: 2)]) }) == "invalid")
    #expect(verdict(list { $0.clear(f, color: .float(0, 0, 0, 0), ranges: [ImageSubresourceRange(baseLayer: 1, layerCount: 2)]) }) == "invalid")
    #expect(verdict(list { $0.clear(f, color: .float(0, 0, 0, 0), ranges: [ImageSubresourceRange(mipCount: 0)]) }) == "invalid")
    #expect(verdict(list { $0.clear(f, color: .float(0, 0, 0, 0), ranges: [ImageSubresourceRange(aspects: .depth)]) }) == "invalid")
    #expect(verdict(list { $0.clear(f, color: .float(0, 0, 0, 0), ranges: []) }) == "invalid")
    #expect(verdict(list { $0.clear(f, color: .float(0, 0, 0, 0), ranges: [ImageSubresourceRange(baseMip: 1, mipCount: 1, baseLayer: 1, layerCount: 1)]) }) == "ok")
    let noDest = try image(gpu, usage: .sampled)
    #expect(list { $0.clear(noDest, color: .float(0, 0, 0, 0)) }.validate(limits: fullLimits) == .invalid("a clear of an image that isn't a copy destination"))
    #expect(verdict(list { $0.render(colorPass(try! image(gpu, usage: .renderTarget))) { $0.clear(f, color: .float(0, 0, 0, 0)) } }) == "invalid")
  }

  @Test func clearingDepthAndStencilNeedsAFormatWithThem() throws {
    let gpu = fullDevice()
    let d = try image(gpu, .depth24stencil8, usage: .copyDestination | .depthStencilTarget)
    let c = try image(gpu)
    #expect(verdict(list { $0.clear(d, depth: 1, stencil: 0) }) == "ok")
    #expect(verdict(list { $0.clear(d, depth: 1, ranges: [ImageSubresourceRange(aspects: .depth)]) }) == "ok")
    #expect(verdict(list { $0.clear(d, depth: 1, ranges: [ImageSubresourceRange(aspects: .color)]) }) == "invalid")
    #expect(verdict(list { $0.clear(c, depth: 1) }) == "invalid")
    let depthOnly = try image(gpu, .depth16, usage: .copyDestination)
    #expect(verdict(list { $0.clear(depthOnly, depth: 1, ranges: [ImageSubresourceRange(aspects: .stencil)]) }) == "invalid")
    #expect(verdict(list { $0.clear(d, depth: 1) }, without { $0.clearImage = false }) == "unsupported")
  }

  @Test func clearingAttachmentsInAPassIsHeldToThePass() throws {
    let gpu = fullDevice()
    let c = try image(gpu, 16, 16, usage: .renderTarget)
    let ints = try image(gpu, .rgba8uint, 16, 16, usage: .renderTarget)
    let d = try image(gpu, .depth16, 16, 16, usage: .depthStencilTarget)
    let layered = try image(gpu, 16, 16, layers: 4, usage: .renderTarget)
    func clear(_ info: RenderingInfo, _ a: [ClearAttachment], _ r: [ClearRect] = [ClearRect(width: 16, height: 16)]) -> String {
      verdict(list { $0.render(info) { $0.clearAttachments(a, rects: r) } })
    }
    let two = RenderingInfo(colors: [Attachment(image: c, load: .dontCare), Attachment(image: ints, load: .dontCare)],
                            depthStencil: DepthStencilAttachment(image: d))
    #expect(clear(two, [.color(index: 0, .float(0, 0, 0, 1)), .color(index: 1, .uint(1, 2, 3, 4)), .depthStencil(aspects: .depth, depth: 1, stencil: 0)]) == "ok")
    #expect(clear(two, [.color(index: 2, .float(0, 0, 0, 1))]) == "invalid")
    #expect(clear(two, [.color(index: -1, .float(0, 0, 0, 1))]) == "invalid")
    #expect(clear(two, [.color(index: 1, .float(0, 0, 0, 1))]) == "invalid")  // a float clear of an integer attachment
    #expect(clear(two, [.depthStencil(aspects: .stencil, depth: 0, stencil: 1)]) == "invalid")  // depth16 has no stencil
    #expect(clear(two, [.depthStencil(aspects: .color, depth: 0, stencil: 1)]) == "invalid")
    #expect(clear(colorPass(c), [.depthStencil(aspects: .depth, depth: 0, stencil: 0)]) == "invalid")  // no depth attachment
    #expect(clear(colorPass(c), []) == "invalid")
    #expect(clear(colorPass(c), [.color(index: 0, .float(0, 0, 0, 0))], []) == "invalid")
    #expect(clear(colorPass(c), [.color(index: 0, .float(0, 0, 0, 0))], [ClearRect(x: 8, width: 16, height: 16)]) == "invalid")
    #expect(clear(colorPass(c), [.color(index: 0, .float(0, 0, 0, 0))], [ClearRect(width: 0, height: 16)]) == "invalid")
    #expect(clear(colorPass(c), [.color(index: 0, .float(0, 0, 0, 0))], [ClearRect(width: 4, height: 4, layerCount: 0)]) == "invalid")
    #expect(clear(colorPass(c), [.color(index: 0, .float(0, 0, 0, 0))], [ClearRect(width: 4, height: 4, baseLayer: 0, layerCount: 2)]) == "invalid")
    let layers = RenderingInfo(colors: [Attachment(image: layered, load: .dontCare)], layerCount: 4)
    #expect(clear(layers, [.color(index: 0, .float(0, 0, 0, 0))], [ClearRect(width: 4, height: 4, baseLayer: 2, layerCount: 2)]) == "ok")
    #expect(clear(layers, [.color(index: 0, .float(0, 0, 0, 0))], [ClearRect(width: 4, height: 4, baseLayer: 3, layerCount: 2)]) == "invalid")
    let area = RenderingInfo(colors: [Attachment(image: c, load: .dontCare)], renderArea: RenderArea(x: 4, y: 4, width: 8, height: 8))
    #expect(clear(area, [.color(index: 0, .float(0, 0, 0, 0))], [ClearRect(x: 4, y: 4, width: 8, height: 8)]) == "ok")
    #expect(clear(area, [.color(index: 0, .float(0, 0, 0, 0))], [ClearRect(x: 0, y: 0, width: 8, height: 8)]) == "invalid")
    #expect(verdict(list { $0.clearAttachments([.color(index: 0, .float(0, 0, 0, 0))], rects: [ClearRect(width: 1, height: 1)]) }) == "invalid")
    #expect(clear(colorPass(c), [.color(index: 0, .float(0, 0, 0, 0))]) == "ok")
    #expect(verdict(list { $0.render(colorPass(c)) { $0.clearAttachments([.color(index: 0, .float(0, 0, 0, 0))], rects: [ClearRect(width: 4, height: 4)]) } },
                    without { $0.clearAttachments = false }) == "unsupported")
  }
}

@Suite struct StateCommandRules {
  @Test func stateCommandsBelongInAPassAndNeedTheirFeatures() throws {
    let gpu = fullDevice()
    let c = try image(gpu, usage: .renderTarget)
    func inPass(_ body: @escaping (inout GPUCommandList) -> Void) -> GPUCommandList { list { $0.render(colorPass(c), body) } }
    let all: [(String, (inout GPUCommandList) -> Void, (inout DeviceFeatures) -> Void)] = [
      ("blend constants", { $0.setBlendConstants(BlendConstants(red: 1)) }, { $0.dynamicState = false }),
      ("stencil reference", { $0.setStencilReference(.front, 3) }, { $0.stencil = false }),
      ("stencil compare mask", { $0.setStencilCompareMask(.both, 0xF) }, { $0.stencil = false }),
      ("stencil write mask", { $0.setStencilWriteMask(.back, 0xF) }, { $0.dynamicState = false }),
      ("depth bias", { $0.setDepthBias(constant: 1, slope: 2) }, { $0.depthBias = false }),
      ("depth bounds", { $0.setDepthBounds(min: 0.1, max: 0.9) }, { $0.depthBounds = false }),
      ("line width", { $0.setLineWidth(2) }, { $0.wideLines = false }),
    ]
    for (name, body, off) in all {
      #expect(verdict(inPass(body)) == "ok", "\(name) in a pass")
      #expect(verdict(list { body(&$0) }) == "invalid", "\(name) outside a pass")
      #expect(verdict(inPass(body), without(off)) == "unsupported", "\(name) without its feature")
      #expect(verdict(inPass(body), without { $0.dynamicState = false }) == "unsupported", "\(name) without dynamic state")
    }
  }

  @Test func theValuesOfStateCommandsAreChecked() throws {
    let gpu = fullDevice()
    let c = try image(gpu, usage: .renderTarget)
    func inPass(_ body: @escaping (inout GPUCommandList) -> Void, _ l: DeviceLimits = fullLimits) -> String {
      verdict(list { $0.render(colorPass(c), body) }, l)
    }
    #expect(inPass { $0.setDepthBounds(min: 0.9, max: 0.1) } == "invalid")
    #expect(inPass { $0.setLineWidth(0) } == "invalid")
    #expect(inPass { $0.setLineWidth(-1) } == "invalid")
    #expect(inPass { $0.setLineWidth(1) } == "ok")
    #expect(inPass { $0.setLineWidth(64) } == "unsupported")  // past the device's widest
    var narrow = fullLimits
    narrow.features.wideLines = false
    #expect(inPass({ $0.setLineWidth(1) }, narrow) == "ok")
    #expect(inPass({ $0.setLineWidth(2) }, narrow) == "unsupported")
  }

  @Test func countedIndirectDrawsCheckTheirArgumentsAndCounts() throws {
    let gpu = fullDevice()
    let c = try image(gpu, usage: .renderTarget)
    let p = try graphicsPipeline(gpu)
    let args = try gpu.allocate(.device, bytes: 16 * 4)
    let indexed = try gpu.allocate(.device, bytes: 20 * 4)
    let counts = try gpu.allocate(.device, bytes: 16)
    let indices = try gpu.allocate(.upload, bytes: 64)
    func draw(_ body: @escaping (inout GPUCommandList) -> Void, _ l: DeviceLimits = fullLimits) -> String {
      verdict(list { $0.render(colorPass(c), body) }, l)
    }
    #expect(draw { $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, maxDrawCount: 4) } == "ok")
    #expect(draw { $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, maxDrawCount: 5) } == "invalid")
    #expect(draw { $0.drawIndirectCount(p, root: 0, arguments: args, offset: 2, countBuffer: counts, maxDrawCount: 1) } == "invalid")
    #expect(draw { $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, maxDrawCount: 1, stride: 8) } == "invalid")
    #expect(draw { $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, maxDrawCount: 1, stride: 18) } == "invalid")
    #expect(draw { $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, countOffset: 16, maxDrawCount: 1) } == "invalid")
    #expect(draw { $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, countOffset: 12, maxDrawCount: 1) } == "ok")
    #expect(draw { $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, countOffset: 2, maxDrawCount: 1) } == "invalid")
    #expect(draw { $0.drawIndexedIndirectCount(p, root: 0, indices: indices, indexType: .uint16, arguments: indexed, countBuffer: counts, maxDrawCount: 4) } == "ok")
    #expect(draw { $0.drawIndexedIndirectCount(p, root: 0, indices: indices, indexType: .uint16, arguments: indexed, countBuffer: counts, maxDrawCount: 5) } == "invalid")
    #expect(draw { $0.drawIndexedIndirectCount(p, root: 0, indices: indices, indexOffset: 65, indexType: .uint16, arguments: indexed, countBuffer: counts, maxDrawCount: 1) } == "invalid")
    #expect(verdict(list { $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, maxDrawCount: 1) }) == "invalid")  // outside a pass
    let compute = try gpu.makeComputePipeline(spirv: module)
    #expect(draw { $0.drawIndirectCount(compute, root: 0, arguments: args, countBuffer: counts, maxDrawCount: 1) } == "invalid")
    #expect(draw({ $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, maxDrawCount: 1) }, without { $0.drawIndirectCount = false }) == "unsupported")
    #expect(draw({ $0.drawIndirectCount(p, root: 0, arguments: args, countBuffer: counts, maxDrawCount: 1) }, without { $0.indirectDraw = false }) == "unsupported")
    #expect(draw({ $0.drawIndexedIndirectCount(p, root: 0, indices: indices, indexType: .uint16, arguments: indexed, countBuffer: counts, maxDrawCount: 1) }, without { $0.indexedDraw = false }) == "unsupported")
  }

  @Test func pipelineStatisticsQueriesNeedTheirFeatureAndAnIndex() throws {
    let gpu = fullDevice()
    let c = try image(gpu, usage: .renderTarget)
    let stats = try gpu.makeQuerySet(.pipelineStatistics(.fragmentShaderInvocations | .inputAssemblyVertices), count: 2)
    func inPass(_ index: Int = 0, _ l: DeviceLimits = fullLimits) -> String {
      verdict(list { $0.render(colorPass(c)) { r in
        r.beginQuery(stats, index: index)
        r.endQuery(stats, index: index)
      } }, l)
    }
    #expect(inPass() == "ok")
    #expect(inPass(2) == "invalid")
    #expect(inPass(0, without { $0.pipelineStatisticsQueries = false }) == "unsupported")
    #expect(verdict(list { $0.beginQuery(stats, index: 0) }) == "ok")  // outside a pass: compute's counters
    let empty = GPUQuerySet(handle: 90, kind: .pipelineStatistics(PipelineStatistics(rawValue: 0)), count: 1)
    #expect(verdict(list { $0.beginQuery(empty, index: 0) }) == "invalid")
    let timestamps = try gpu.makeQuerySet(.timestamp, count: 1)
    #expect(verdict(list { $0.beginQuery(timestamps, index: 0) }) == "invalid")
    #expect(try gpu.results(stats, first: 0, count: 2).count == 4)  // two counters each
    #expect(PipelineStatistics.computeShaderInvocations.count == 1 && (PipelineStatistics.clippingPrimitives | .clippingInvocations).count == 2)
    #expect(throws: GPUError.self) { try FakeDevice().makeQuerySet(.pipelineStatistics(.fragmentShaderInvocations), count: 1) }
  }

  @Test func bufferFillsAndUpdatesAreAlignedAndInsideTheirMemory() throws {
    let gpu = fullDevice()
    let m = try gpu.allocate(.device, bytes: 64)
    let c = try image(gpu, usage: .renderTarget)
    #expect(verdict(list { $0.fill(m, offset: 16, bytes: 48, value: 0xFF) }) == "ok")
    #expect(verdict(list { $0.fill(m, offset: 16, bytes: 52, value: 0) }) == "invalid")
    #expect(verdict(list { $0.fill(m, offset: 2, bytes: 8, value: 0) }) == "invalid")
    #expect(verdict(list { $0.fill(m, offset: 0, bytes: 6, value: 0) }) == "invalid")
    #expect(verdict(list { $0.fill(m, offset: 0, bytes: 0, value: 0) }) == "invalid")
    #expect(verdict(list { $0.fill(m, offset: -4, bytes: 8, value: 0) }) == "invalid")
    #expect(verdict(list { $0.render(colorPass(c)) { $0.fill(m, bytes: 4, value: 0) } }) == "invalid")
    #expect(verdict(list { $0.update(m, offset: 8, data: [UInt8](repeating: 1, count: 56)) }) == "ok")
    #expect(verdict(list { $0.update(m, offset: 8, data: [UInt8](repeating: 1, count: 60)) }) == "invalid")
    #expect(verdict(list { $0.update(m, data: []) }) == "invalid")
    #expect(verdict(list { $0.update(m, data: [1, 2, 3]) }) == "invalid")
    #expect(verdict(list { $0.update(m, offset: 1, data: [1, 2, 3, 4]) }) == "invalid")
    let big = try gpu.allocate(.device, bytes: 1 << 20)
    #expect(verdict(list { $0.update(big, data: [UInt8](repeating: 0, count: 65536)) }) == "ok")
    #expect(verdict(list { $0.update(big, data: [UInt8](repeating: 0, count: 65540)) }) == "invalid")
    #expect(verdict(list { $0.render(colorPass(c)) { $0.update(m, data: [1, 2, 3, 4]) } }) == "invalid")
  }

  @Test func anImageBarrierNamesSubresourcesInsideTheImageAndNoPass() throws {
    let gpu = fullDevice()
    let a = try image(gpu, mips: 3, layers: 2)
    let c = try image(gpu, usage: .renderTarget)
    #expect(verdict(list { $0.barrier(image: a) }) == "ok")
    #expect(verdict(list { $0.barrier(image: a, range: ImageSubresourceRange(baseMip: 1, mipCount: 2, baseLayer: 1, layerCount: 1), from: .fragment, to: .compute) }) == "ok")
    #expect(verdict(list { $0.barrier(image: a, range: ImageSubresourceRange(baseMip: 2, mipCount: 2)) }) == "invalid")
    #expect(verdict(list { $0.barrier(image: a, range: ImageSubresourceRange(baseLayer: 2)) }) == "invalid")
    #expect(verdict(list { $0.barrier(image: a, range: ImageSubresourceRange(aspects: .depth)) }) == "invalid")
    #expect(verdict(list { $0.render(colorPass(c)) { $0.barrier(image: a) } }) == "invalid")
    // Accepted, never refused, by a device that can't use the range.
    #expect(verdict(list { $0.barrier(image: a) }, FakeDevice.todaysLimits()) == "ok")
  }
}
