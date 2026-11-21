// SPDX-License-Identifier: BSD-3-Clause

// The core's contract (D174 section 1), checked on a fake backend: the rules
// `GPUCommandList.validate` holds every list to, the timeline's rule, and the
// shape of a device a client sees (memory by intent, the heap by index,
// layouts nowhere).

import Testing

@testable import GPUCore

/// Eight bytes of SPIR-V magic and padding: enough for the fake to take it as a module.
let module: [UInt8] = [3, 2, 35, 7] + [UInt8](repeating: 0, count: 16)

func target(_ gpu: FakeDevice, _ w: Int32 = 8, _ h: Int32 = 8) throws -> GPUImage {
  try gpu.makeImage(ImageDescriptor(format: .rgba8, width: w, height: h, usage: .renderTarget | .copySource | .sampled))
}

@Suite struct ContractTests {
  @Test func memoryHasAnAddressAndAPointerWhereTheIntentAllows() throws {
    let gpu = FakeDevice()
    let up = try gpu.allocate(.upload, bytes: 64)
    let dev = try gpu.allocate(.device, bytes: 64)
    let back = try gpu.allocate(.readback, bytes: 64)
    #expect(up.pointer != nil && back.pointer != nil)
    #expect(dev.pointer == nil)
    #expect(dev.address != 0 && up.address != dev.address)
    gpu.free(up)
    #expect(!gpu.live.contains(up.handle))
  }

  @Test func theHeapIsWrittenByIndex() throws {
    let gpu = FakeDevice()
    let image = try target(gpu)
    try gpu.writeTexture(3, image)
    try gpu.writeSampler(0, SamplerDescriptor())
    #expect(gpu.textures[3]?.image == image && gpu.textures[3]?.isWholeImage == true)
    #expect(throws: GPUError.self) { try gpu.writeTexture(16, image) }
    let plain = try gpu.makeImage(ImageDescriptor(format: .r8, width: 4, height: 4, usage: .copyDestination))
    #expect(throws: GPUError.self) { try gpu.writeTexture(0, plain) }
    #expect(throws: GPUError.self) { try gpu.writeStorageImage(0, image) }
  }

  @Test func aPassWithADrawIsValid() throws {
    let gpu = FakeDevice()
    let pipeline = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8]))
    let image = try target(gpu)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: image, load: .clear(0, 0, 1, 1))])) { r in
      r.draw(pipeline, root: 0x1000, vertices: 3)
    }
    #expect(list.validate(features: gpu.limits.features) == nil)
    try gpu.run(list, signal: 1)
    #expect(gpu.completed == 1)
    #expect(gpu.submitted.count == 1)
  }

  @Test func aDrawOutsideAPassIsInvalid() throws {
    let gpu = FakeDevice()
    let pipeline = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8]))
    var list = GPUCommandList()
    list.draw(pipeline, root: 0, vertices: 3)
    #expect(list.validate(features: gpu.limits.features) == .invalid("a draw outside a pass"))
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(list, wait: 0, signal: 1) }
    #expect(gpu.submitted.isEmpty)
  }

  @Test func passesMustNestNoDeeperThanOne() throws {
    let gpu = FakeDevice()
    let a = try target(gpu)
    let info = RenderingInfo(colors: [Attachment(image: a, load: .dontCare)])
    var open = GPUCommandList()
    open.beginRendering(info)
    #expect(open.validate(features: gpu.limits.features) == .invalid("a pass that never ends"))
    open.beginRendering(info)
    #expect(open.validate(features: gpu.limits.features) == .invalid("a pass begins inside a pass"))
    var stray = GPUCommandList()
    stray.endRendering()
    #expect(stray.validate(features: gpu.limits.features) != nil)
  }

  @Test func aDispatchBelongsOutsideAPassAndToAComputePipeline() throws {
    let gpu = FakeDevice()
    let compute = try gpu.makeComputePipeline(spirv: module)
    let graphics = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8]))
    var ok = GPUCommandList()
    ok.dispatch(compute, root: 0x2000, x: 4)
    ok.barrier(from: .compute, to: .compute | .transfer)
    #expect(ok.validate(features: gpu.limits.features) == nil)
    var wrong = GPUCommandList()
    wrong.dispatch(graphics, root: 0, x: 1)
    #expect(wrong.validate(features: gpu.limits.features) == .invalid("a dispatch of a graphics pipeline"))
    var empty = GPUCommandList()
    empty.dispatch(compute, root: 0, x: 0)
    #expect(empty.validate(features: gpu.limits.features) != nil)
    let a = try target(gpu)
    var inside = GPUCommandList()
    inside.render(RenderingInfo(colors: [Attachment(image: a, load: .dontCare)])) { r in r.dispatch(compute, root: 0, x: 1) }
    #expect(inside.validate(features: gpu.limits.features) == .invalid("a dispatch inside a pass"))
  }

  @Test func copiesCheckUsageAndBounds() throws {
    let gpu = FakeDevice()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: .copyDestination | .sampled))
    let small = try gpu.allocate(.upload, bytes: 32)
    let big = try gpu.allocate(.upload, bytes: 64)
    var list = GPUCommandList()
    list.copy(small, to: image)
    #expect(list.validate(features: gpu.limits.features) == .invalid("a copy past its memory"))
    var good = GPUCommandList()
    good.copy(big, to: image)
    #expect(good.validate(features: gpu.limits.features) == nil)
    var out = GPUCommandList()
    out.copy(image, to: big)
    #expect(out.validate(features: gpu.limits.features) == .invalid("a copy out of an image that isn't a copy source"))
  }

  @Test func aDeviceWithoutAFeatureRefusesItNotTheShape() throws {
    var features = DeviceFeatures()
    features.sampledImages = true
    let gpu = FakeDevice(features: features)
    let pipeline = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8]))
    let compute = try gpu.makeComputePipeline(spirv: module)
    let image = try target(gpu)
    let memory = try gpu.allocate(.upload, bytes: 64)
    var load = GPUCommandList()
    load.render(RenderingInfo(colors: [Attachment(image: image, load: .load)])) { _ in }
    #expect(load.validate(features: features) == .unsupported("a pass that loads its attachment's contents"))
    var two = GPUCommandList()
    two.render(RenderingInfo(colors: [Attachment(image: image, load: .dontCare)])) { r in
      r.draw(pipeline, root: 0, vertices: 3)
      r.draw(pipeline, root: 0, vertices: 3)
    }
    #expect(two.validate(features: features) == .unsupported("more than one draw in a pass"))
    var indirect = GPUCommandList()
    indirect.dispatchIndirect(compute, root: 0, arguments: memory)
    #expect(indirect.validate(features: features) == .unsupported("indirect dispatch"))
    var stamps = GPUCommandList()
    stamps.writeTimestamp(GPUQuerySet(handle: 1, kind: .timestamp, count: 2), index: 0)
    #expect(stamps.validate(features: features) == .unsupported("timestamp queries"))
  }

  @Test func indirectAndIndexedWorkChecksItsArguments() throws {
    let gpu = FakeDevice()
    let pipeline = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(vertex: module, fragment: module, colorFormats: [.rgba8]))
    let compute = try gpu.makeComputePipeline(spirv: module)
    let image = try target(gpu)
    let args = try gpu.allocate(.device, bytes: 32)
    let indices = try gpu.allocate(.upload, bytes: 12)
    var list = GPUCommandList()
    list.dispatchIndirect(compute, root: 0, arguments: args, offset: 20)
    #expect(list.validate(features: gpu.limits.features) == nil)
    list.dispatchIndirect(compute, root: 0, arguments: args, offset: 24)
    #expect(list.validate(features: gpu.limits.features) == .invalid("indirect arguments past their memory"))
    var draws = GPUCommandList()
    draws.render(RenderingInfo(colors: [Attachment(image: image, load: .dontCare)])) { r in
      r.drawIndexed(pipeline, root: 0, indices: indices, indexType: .uint16, count: 6)
      r.drawIndirect(pipeline, root: 0, arguments: args, drawCount: 2)
    }
    #expect(draws.validate(features: gpu.limits.features) == nil)
    var past = GPUCommandList()
    past.render(RenderingInfo(colors: [Attachment(image: image, load: .dontCare)])) { r in
      r.drawIndexed(pipeline, root: 0, indices: indices, indexType: .uint32, count: 4)
    }
    #expect(past.validate(features: gpu.limits.features) == .invalid("indices past their memory"))
  }

  @Test func theTimelineOnlyGoesUp() throws {
    let gpu = FakeDevice()
    var list = GPUCommandList()
    list.barrier()
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 5)
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(list, wait: 0, signal: 5) }
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(list, wait: 0, signal: 0) }
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(list, wait: 9, signal: 6) }
    try gpu.graphicsQueue.submit(list, wait: 5, signal: 6)
    #expect(gpu.completed == 6)
    #expect(gpu.submitted.map { $0.wait } == [0, 5])
  }

  @Test func queriesNameTheirKindAndIndex() throws {
    let gpu = FakeDevice()
    let stamps = try gpu.makeQuerySet(.timestamp, count: 2)
    let image = try target(gpu)
    var list = GPUCommandList()
    list.writeTimestamp(stamps, index: 0)
    list.writeTimestamp(stamps, index: 1, after: .compute)
    #expect(list.validate(features: gpu.limits.features) == nil)
    list.writeTimestamp(stamps, index: 2)
    #expect(list.validate(features: gpu.limits.features) == .invalid("a query past its set"))
    let counts = try gpu.makeQuerySet(.occlusion, count: 1)
    var occlusion = GPUCommandList()
    occlusion.render(RenderingInfo(colors: [Attachment(image: image, load: .dontCare)])) { r in
      r.beginQuery(counts, index: 0)
      r.endQuery(counts, index: 0)
    }
    #expect(occlusion.validate(features: gpu.limits.features) == nil)
    #expect(try gpu.results(stamps, first: 0, count: 2).count == 2)
  }
}
