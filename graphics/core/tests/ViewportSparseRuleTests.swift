// SPDX-License-Identifier: BSD-3-Clause

// The rules for more than one viewport and for sparse resources (D174 amendment, "Elsewhere"): each has a case that passes
// and cases that fail, `.invalid` (the shape is wrong everywhere) apart from `.unsupported` (this device lacks it).

import Testing

@testable import GPUCore

private func pass(_ gpu: FakeDevice) throws -> RenderingInfo {
  colorPass(try image(gpu, usage: .renderTarget | .copySource))
}

@Suite struct Viewports {
  @Test func severalViewportsAndScissorsInAPass() throws {
    let gpu = fullDevice()
    var list = GPUCommandList()
    list.render(try pass(gpu)) { r in
      r.setViewports([Viewport(width: 8, height: 16), Viewport(x: 8, width: 8, height: 16, minDepth: 0.25, maxDepth: 0.75)])
      r.setScissors(first: 0, [RenderArea(width: 8, height: 16), RenderArea(x: 8, width: 8, height: 16)])
      r.setViewports(first: 15, [Viewport(width: 4, height: -4)])  // the last of 16, flipped
    }
    #expect(verdict(list) == "ok")
    if case .setViewports(let first, let vs) = list.commands[1] { #expect(first == 0 && vs.count == 2 && vs[1].minDepth == 0.25) }
  }

  @Test func aShapeNoDeviceTakesIsInvalid() throws {
    let gpu = fullDevice()
    let info = try pass(gpu)
    func one(_ body: (inout GPUCommandList) -> Void) -> String {
      var list = GPUCommandList()
      list.render(info, body)
      return verdict(list)
    }
    #expect(one { $0.setViewports([]) } == "invalid")
    #expect(one { $0.setScissors([]) } == "invalid")
    #expect(one { $0.setViewports([Viewport(width: 0, height: 4)]) } == "invalid")
    #expect(one { $0.setViewports([Viewport(width: 4, height: 0)]) } == "invalid")
    #expect(one { $0.setViewports([Viewport(width: 4, height: 4, minDepth: -0.5)]) } == "invalid")
    #expect(one { $0.setViewports([Viewport(width: 4, height: 4, maxDepth: 1.5)]) } == "invalid")
    #expect(one { $0.setScissors([RenderArea(x: -1, width: 4, height: 4)]) } == "invalid")
    var outside = GPUCommandList()
    outside.setViewports([Viewport(width: 4, height: 4)])
    #expect(verdict(outside) == "invalid")
    let p = GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8], viewportCount: 0)
    #expect(verdict(p.check(limits: fullLimits)) == "invalid")
  }

  @Test func aDeviceWithOneViewportRefusesMore() throws {
    let one = without { $0.multiViewport = false }
    let gpu = FakeDevice(limits: { var l = one; l.maxViewports = 1; return l }())
    let info = try pass(gpu)
    var list = GPUCommandList()
    list.render(info) { r in r.setViewports([Viewport(width: 4, height: 4)]) }
    #expect(verdict(list, gpu.limits) == "ok")
    list = GPUCommandList()
    list.render(info) { r in r.setViewports([Viewport(width: 4, height: 4), Viewport(width: 4, height: 4)]) }
    #expect(verdict(list, gpu.limits) == "unsupported")
    list = GPUCommandList()
    list.render(info) { r in r.setScissors(first: 1, [RenderArea(width: 4, height: 4)]) }
    #expect(verdict(list, gpu.limits) == "unsupported")
    let p = GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8], viewportCount: 2)
    #expect(verdict(p.check(limits: gpu.limits)) == "unsupported")
    #expect(verdict(p.check(limits: fullLimits)) == "ok")
    // Past the device's count, and past its size or bounds.
    list = GPUCommandList()
    list.render(info) { r in r.setViewports(first: 16, [Viewport(width: 4, height: 4)]) }
    #expect(verdict(list) == "unsupported")
    list = GPUCommandList()
    list.render(info) { r in r.setViewports([Viewport(width: 8192, height: 4)]) }
    #expect(verdict(list) == "unsupported")
    list = GPUCommandList()
    list.render(info) { r in r.setViewports([Viewport(x: 9000, width: 8, height: 4)]) }
    #expect(verdict(list) == "unsupported")
    let many = GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8], viewportCount: 17)
    #expect(verdict(many.check(limits: fullLimits)) == "unsupported")
  }
}

@Suite struct SparseResources {
  @Test func aSparseBufferIsBoundByPagesOnTheQueue() throws {
    let gpu = fullDevice()
    let buffer = try gpu.makeSparseBuffer(bytes: 3 * FakeDevice.page, flags: .binding | .residency)
    #expect(buffer.sparse.contains(.residency) && buffer.pointer == nil && buffer.intent == .device)
    let req = try gpu.sparseRequirements(buffer)
    #expect(req.size == 3 * FakeDevice.page && req.pageBytes == FakeDevice.page)
    let pages = try gpu.allocate(.device, bytes: 2 * FakeDevice.page)
    let binds = SparseBindings(buffers: [SparseBufferBind(buffer: buffer, offset: 0, size: FakeDevice.page, memory: pages),
                                         SparseBufferBind(buffer: buffer, offset: 2 * FakeDevice.page, size: FakeDevice.page,
                                                          memory: pages, memoryOffset: FakeDevice.page),
                                         SparseBufferBind(buffer: buffer, offset: FakeDevice.page, size: FakeDevice.page, memory: nil)])
    try gpu.graphicsQueue.bindSparse(binds, wait: 0, signal: 1)
    #expect(gpu.bound.count == 1 && gpu.bound[0].signal == 1 && gpu.bound[0].bindings.buffers.count == 3)
    // The bind is on the timeline: a submission after it signals past it.
    var list = GPUCommandList()
    list.fill(buffer, bytes: 64, value: 7)
    try gpu.graphicsQueue.submit(list, wait: 1, signal: 2)
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.bindSparse(binds, wait: 0, signal: 2) }
  }

  @Test func aSparseBindOfTheWrongShapeIsInvalid() throws {
    let gpu = fullDevice()
    let buffer = try gpu.makeSparseBuffer(bytes: 2 * FakeDevice.page, flags: .binding)
    let plain = try gpu.allocate(.device, bytes: FakeDevice.page)
    func bind(_ b: SparseBufferBind) -> String { verdict(SparseBindings(buffers: [b]).validate(limits: fullLimits)) }
    #expect(bind(SparseBufferBind(buffer: buffer, offset: 0, size: FakeDevice.page, memory: plain)) == "ok")
    #expect(bind(SparseBufferBind(buffer: plain, offset: 0, size: 64, memory: plain)) == "invalid")  // not sparse
    #expect(bind(SparseBufferBind(buffer: buffer, offset: 0, size: FakeDevice.page, memory: buffer)) == "invalid")  // sparse memory
    #expect(bind(SparseBufferBind(buffer: buffer, offset: 2 * FakeDevice.page, size: FakeDevice.page, memory: nil)) == "invalid")
    // Into the last page past the buffer's bytes: the backend's to judge against its pages.
    let odd = try gpu.makeSparseBuffer(bytes: FakeDevice.page + 100, flags: .binding)
    #expect(bind(SparseBufferBind(buffer: odd, offset: FakeDevice.page, size: FakeDevice.page, memory: nil)) == "ok")
    #expect(bind(SparseBufferBind(buffer: buffer, offset: 0, size: FakeDevice.page, memory: plain, memoryOffset: 64)) == "invalid")
    #expect(bind(SparseBufferBind(buffer: buffer, offset: 0, size: 0, memory: nil)) == "invalid")
    // Off the pages: the backend's to judge.
    #expect(throws: GPUError.self) {
      try gpu.graphicsQueue.bindSparse(SparseBindings(buffers: [SparseBufferBind(buffer: buffer, offset: 64, size: FakeDevice.page,
                                                                                 memory: nil)]), wait: 0, signal: 1)
    }
    #expect(verdict(sparseBufferError(bytes: 0, flags: .binding, limits: fullLimits)) == "invalid")
    #expect(verdict(sparseBufferError(bytes: 64, flags: .residency, limits: fullLimits)) == "invalid")  // residency without binding
  }

  @Test func sparseImagesAndTheirBlocks() throws {
    let gpu = fullDevice()
    let d = ImageDescriptor(format: .rgba8, width: 512, height: 512, usage: .sampled | .copyDestination, sparse: .binding | .residency)
    #expect(d.check(limits: fullLimits) == nil)
    let img = try gpu.makeImage(d)
    let pages = try gpu.allocate(.device, bytes: FakeDevice.page)
    let block = SparseImageBind(image: img, extent: Extent3D(width: 128, height: 128), memory: pages)
    #expect(verdict(SparseBindings(images: [block]).validate(limits: fullLimits)) == "ok")
    var past = block
    past.offset = Offset3D(x: 448)
    #expect(verdict(SparseBindings(images: [past]).validate(limits: fullLimits)) == "invalid")
    var level = block
    level.mip = 1
    #expect(verdict(SparseBindings(images: [level]).validate(limits: fullLimits)) == "invalid")
    var depth = block
    depth.aspects = .depth
    #expect(verdict(SparseBindings(images: [depth]).validate(limits: fullLimits)) == "invalid")
    // Blocks need residency; an opaque bind needs only binding.
    let whole = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .sampled, sparse: .binding))
    #expect(verdict(SparseBindings(images: [SparseImageBind(image: whole, extent: Extent3D(width: 64, height: 64), memory: nil)])
      .validate(limits: fullLimits)) == "invalid")
    #expect(verdict(SparseBindings(opaque: [SparseImageOpaqueBind(image: whole, offset: 0, size: FakeDevice.page, memory: pages)])
      .validate(limits: fullLimits)) == "ok")
    let ordinary = try image(gpu)
    #expect(verdict(SparseBindings(opaque: [SparseImageOpaqueBind(image: ordinary, offset: 0, size: 64, memory: nil)])
      .validate(limits: fullLimits)) == "invalid")
    // Shapes no device makes sparse.
    var shown = ImageDescriptor(format: .bgra8, width: 64, height: 64, usage: .scanout, sparse: .binding)
    #expect(verdict(shown.check(limits: fullLimits)) == "invalid")
    shown = ImageDescriptor(format: .rgba8, width: 64, height: 1, dimension: .d1, usage: .sampled, sparse: .binding | .residency)
    #expect(verdict(shown.check(limits: fullLimits)) == "invalid")
    shown = ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .sampled, sparse: .aliased)
    #expect(verdict(shown.check(limits: fullLimits)) == "invalid")
  }

  @Test func aDeviceWithoutThemRefusesThem() throws {
    let d = ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .sampled, sparse: .binding | .residency)
    #expect(verdict(d.check(limits: without { $0.sparseBinding = false })) == "unsupported")
    #expect(verdict(d.check(limits: without { $0.sparseResidencyImage2D = false })) == "unsupported")
    let volume = ImageDescriptor(format: .rgba8, width: 64, height: 64, depth: 64, dimension: .d3, usage: .sampled,
                                 sparse: .binding | .residency)
    #expect(verdict(volume.check(limits: without { $0.sparseResidencyImage3D = false })) == "unsupported")
    let eight = ImageDescriptor(format: .rgba8, width: 64, height: 64, samples: 8, usage: .renderTarget, sparse: .binding | .residency)
    #expect(verdict(eight.check(limits: fullLimits)) == "ok")
    #expect(verdict(eight.check(limits: without { $0.sparseResidency8Samples = false })) == "unsupported")
    let aliased = ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .sampled, sparse: .binding | .aliased)
    #expect(verdict(aliased.check(limits: without { $0.sparseResidencyAliased = false })) == "unsupported")
    #expect(verdict(sparseBufferError(bytes: 64, flags: .binding | .residency, limits: without { $0.sparseResidencyBuffer = false }))
      == "unsupported")
    #expect(verdict(sparseBufferError(bytes: 64, flags: .binding, limits: without { $0.sparseBinding = false })) == "unsupported")
    // A device that keeps the defaults refuses all of it.
    let plain = FakeDevice()
    #expect(throws: GPUError.self) { try plain.makeSparseBuffer(bytes: 64, flags: .binding) }
    #expect(throws: GPUError.self) { try plain.makeImage(d) }
    #expect(plain.sparseImageFormats(.rgba8, dimension: .d2, samples: 1, usage: .sampled).isEmpty)
    let buffer = try fullDevice().makeSparseBuffer(bytes: 64, flags: .binding)
    #expect(verdict(SparseBindings(buffers: [SparseBufferBind(buffer: buffer, offset: 0, size: 64, memory: nil)])
      .validate(limits: FakeDevice.todaysLimits())) == "unsupported")
  }
}
