// SPDX-License-Identifier: BSD-3-Clause

// The core's Mali backend over a fake transport (D174 section 5): memory and
// images by intent, the pipelines the compiler makes, the render pass of one
// draw as streams on the render group's two queues, the CPU's clears and
// copies, the timeline, and what it refuses in words.

import GPUCore
import MaliFakeTransport
import ShaderTestKit
import Testing

@testable import GPUCoreMali

func bytes(_ words: [UInt32]) -> [UInt8] {
  var out: [UInt8] = []
  for w in words { for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: w >> UInt32(8 * i))) } }
  return out
}

func device() throws -> (MaliDevice, FakeTransport) {
  let t = FakeTransport()
  return (try MaliDevice(transport: t), t)
}

func trianglePipeline(_ gpu: MaliDevice, _ format: PixelFormat = .rgba8) throws -> GPUPipeline {
  try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(
    vertex: bytes(try assemble(Corpus.varyingVertex)), fragment: bytes(try assemble(Corpus.varyingFragment)), colorFormats: [format]))
}

@Suite struct MaliDeviceTests {
  @Test func memoryIsBoundAtAddressesOfTheVMAndMappedWhereTheIntentAllows() throws {
    let (gpu, t) = try device()
    let up = try gpu.allocate(.upload, bytes: 100)
    let dev = try gpu.allocate(.device, bytes: 5000)
    #expect(up.pointer != nil && dev.pointer == nil)
    #expect(up.address & 4095 == 0 && dev.address & 4095 == 0 && dev.address > up.address)
    #expect(t.bound.contains { $0.address == up.address && $0.buffer.size == 4096 })
    #expect(t.bound.contains { $0.address == dev.address && $0.buffer.size == 8192 })
    gpu.free(up)
    // Freed once the work so far has finished: nothing was submitted, so at once.
    #expect(!t.bound.contains { $0.address == up.address })
  }

  @Test func theAddressSpaceEnds() throws {
    let t = FakeTransport()
    t.userRange = 0x10_0000 + 8192
    let gpu = try MaliDevice(transport: t)
    _ = try gpu.allocate(.upload, bytes: 8192)
    #expect(throws: GPUError.self) { try gpu.allocate(.upload, bytes: 1) }
  }

  @Test func whatItCannotDoYetIsRefusedInWords() throws {
    let (gpu, _) = try device()
    #expect(throws: GPUError.self) { try gpu.makeImage(ImageDescriptor(format: .bgra8srgb, width: 4, height: 4, usage: .storage)) }
    #expect(throws: GPUError.self) { try gpu.makeImage(ImageDescriptor(format: .r8, width: 4, height: 4, usage: .renderTarget)) }
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: .renderTarget | .copySource))
    // A texture is a sampled image; a storage image has no slot.
    #expect(throws: GPUError.self) { try gpu.writeTexture(0, image) }
    #expect(throws: GPUError.self) { try gpu.writeStorageImage(0, image) }
    #expect(gpu.limits.features.storageImages)
    // The same image attached twice is a pass that can't be made, and nine attachments are past the device's.
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: image, load: .dontCare), Attachment(image: image, load: .dontCare)])) { _ in }
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(list, wait: 0, signal: 1) }
  }

  @Test func aComputeShaderWithDescriptorBuffersIsRefused() throws {
    let (gpu, _) = try device()
    // The core's layout is the heap and a root pointer: no set 0, binding 0.
    #expect(throws: GPUError.self) { try gpu.makeComputePipeline(spirv: bytes(try assemble(Corpus.globalID))) }
    #expect(throws: GPUError.self) { try gpu.makeComputePipeline(spirv: [1, 2, 3]) }
  }

  @Test func aClearOnlyPassFillsTheImageInItsChannelOrder() throws {
    let (gpu, _) = try device()
    let bgra = try gpu.makeImage(ImageDescriptor(format: .bgra8, width: 5, height: 3, usage: .renderTarget | .copySource))
    let out = try gpu.allocate(.readback, bytes: 5 * 3 * 4)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: bgra, load: .clear(1, 0.5, 0, 1))])) { _ in }
    list.copy(bgra, to: out)
    try gpu.run(list, signal: 1)
    let p = out.pointer!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<15 { #expect([p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3]] == [0, 128, 255, 255]) }
    #expect(gpu.completed == 1)
  }

  @Test func copiesGoThroughTheRowsStrideOfTheImage() throws {
    let (gpu, _) = try device()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 3, height: 2, usage: .copySource | .copyDestination))
    let up = try gpu.allocate(.upload, bytes: 24)
    let back = try gpu.allocate(.readback, bytes: 24)
    let u = up.pointer!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<24 { u[i] = UInt8(i + 1) }
    var list = GPUCommandList()
    list.copy(up, to: image)
    list.barrier()
    list.copy(image, to: back)
    try gpu.run(list, signal: 1)
    let b = back.pointer!.assumingMemoryBound(to: UInt8.self)
    #expect((0..<24).allSatisfy { b[$0] == UInt8($0 + 1) })
  }

  @Test func aDrawIsARenderPassOnTheTwoQueuesSignallingTheTimeline() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    let verts = try gpu.allocate(.upload, bytes: 96)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))])) { r in
      r.draw(pipeline, root: verts.address, vertices: 3)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 7)
    #expect(t.submits.count == 1)
    let s = t.submits[0]
    #expect(t.groups[s.group] == [4096, 4096])
    #expect(s.jobs.map { $0.queue } == [0, 1])
    #expect(s.signals.count == 1 && s.signals[0].value == 7)
    #expect(gpu.completed == 7)
    // The streams are in memory the VM maps, and say something.
    #expect(t.streams.count == 2 && t.streams.allSatisfy { $0.contains { $0 != 0 } })
    // A second pass on the same queues starts them no more.
    try gpu.graphicsQueue.submit(list, wait: 7, signal: 8)
    #expect(t.submits.count == 2 && t.submits[1].group == s.group)
    #expect(t.groups.count == 1)
  }

  @Test func theRootPointerIsTheDrawsAndNoTableIsMade() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget))
    let verts = try gpu.allocate(.upload, bytes: 96)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .dontCare)])) { r in
      r.draw(pipeline, root: verts.address, vertices: 3)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    // The vertex shader's FAU block holds the root pointer's two words after the viewport's six.
    var found = false
    for words in t.memory {
      for i in 0..<words.count - 1 where UInt64(words[i + 1]) << 32 | UInt64(words[i]) == verts.address { found = true }
    }
    #expect(found)
  }

  @Test func severalDrawsAreOnePassAndTheWrongFormatIsRefusedWithTheTimelineStillMoving() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .dontCare)])) { r in
      r.draw(pipeline, root: 0x1000, vertices: 3)
      r.draw(pipeline, root: 0x1000, vertices: 3)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    #expect(t.submits.count == 1 && t.submits[0].jobs.map { $0.queue } == [0, 1])
    // A pipeline for the wrong format is the caller's mistake, and still raises the value waited for.
    let bgra = try trianglePipeline(gpu, .bgra8)
    var wrong = GPUCommandList()
    wrong.render(RenderingInfo(colors: [Attachment(image: target, load: .dontCare)])) { r in
      r.draw(bgra, root: 0x1000, vertices: 3)
    }
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(wrong, wait: 1, signal: 2) }
    #expect(gpu.completed == 2)
  }

  @Test func anInstancedDrawOfQuadsIsOnePass() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu, .bgra8srgb)
    let target = try gpu.makeImage(ImageDescriptor(format: .bgra8srgb, width: 64, height: 64, usage: .renderTarget))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.draw(pipeline, root: 0x1000, vertices: 6, instances: 500)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    #expect(t.submits.count == 1)
  }

  @Test func ansRGBTargetsClearIsEncodedAndItsBlendDescriptorSaysSo() throws {
    let (gpu, t) = try device()
    let image = try gpu.makeImage(ImageDescriptor(format: .bgra8srgb, width: 3, height: 2, usage: .renderTarget | .copySource))
    let out = try gpu.allocate(.readback, bytes: 3 * 2 * 4)
    var list = GPUCommandList()
    // Linear 0.5 is 188 encoded (08 section 8.7.2, example 4); alpha is never converted.
    list.render(RenderingInfo(colors: [Attachment(image: image, load: .clear(0.5, 0, 1, 0.5))])) { _ in }
    list.copy(image, to: out)
    try gpu.run(list, signal: 1)
    let p = out.pointer!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<6 { #expect([p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3]] == [255, 0, 188, 128]) }
    // A draw into it: the blend descriptor in the pass's memory has the sRGB bits, and with alpha blending the
    // destination is loaded.
    let blended = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(
      vertex: bytes(try assemble(Corpus.varyingVertex)), fragment: bytes(try assemble(Corpus.varyingFragment)),
      colorFormats: [.bgra8srgb], blend: .alpha))
    var draw = GPUCommandList()
    draw.render(RenderingInfo(colors: [Attachment(image: image, load: .clear(0, 0, 0, 1))])) { r in
      r.draw(blended, root: 0x1000, vertices: 3)
    }
    try gpu.graphicsQueue.submit(draw, wait: 1, signal: 2)
    // Word 0 of the blend descriptor, 0x0E01 (09 example 2): load destination, enable, sRGB, round; word 3 has bit 20.
    var found = false
    for words in t.memory {
      for i in 0..<words.count - 3 where words[i] == 0x0000_0E01 && words[i + 3] == 0x001E_D000 { found = true }
    }
    #expect(found)
  }

  @Test func everyPassNamesTheSameTilerMemoryAndNeverMemoryAnEarlierOneLetGo() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu, .bgra8srgb)
    let target = try gpu.makeImage(ImageDescriptor(format: .bgra8srgb, width: 256, height: 256, usage: .renderTarget))
    var heaps: [UInt64] = []
    for n in 1...3 {
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
        r.draw(pipeline, root: 0x1000, vertices: 6, instances: 40)
      }
      try gpu.graphicsQueue.submit(list, wait: UInt64(n - 1), signal: UInt64(n))
      // The heap descriptor's first chunk is in the pass's block; it must be in memory the device still holds.
      let chunk = gpu.tilerHeap!.chunk
      #expect(t.boundAtSubmit.contains { $0.address == chunk.address && $0.size == Int(MaliDevice.tilerChunkBytes) })
      heaps.append(chunk.address)
    }
    #expect(Set(heaps).count == 1)
  }

  @Test func aGroupThatFaultedIsDroppedAndTheNextPassMakesANewOneWithItsQueuesStarted() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    let out = try gpu.allocate(.readback, bytes: 64 * 64 * 4)
    func list() -> GPUCommandList {
      var l = GPUCommandList()
      l.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
        r.draw(pipeline, root: 0x1000, vertices: 3)
      }
      l.copy(target, to: out)
      return l
    }
    try gpu.graphicsQueue.submit(list(), wait: 0, signal: 1)
    t.groupFault = 2
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(list(), wait: 1, signal: 2) }
    // The failed list's value is raised, so what waits for it ends, and a later pass goes past it.
    #expect(gpu.completed == 2)
    t.groupFault = 0
    try gpu.graphicsQueue.submit(list(), wait: 2, signal: 3)
    #expect(t.groups.count == 1 && gpu.completed == 3)
    // The new group's first stream initialises the queues again (its first instruction is not a MOVE of the heap).
    #expect(t.submits.count == 3 && t.submits[2].group != t.submits[0].group)
  }

  @Test func readbackMemoryAndATargetOnlyTheCPUReadsAreCachedAndMaintained() throws {
    let (gpu, t) = try device()
    let up = try gpu.allocate(.upload, bytes: 4096)
    let back = try gpu.allocate(.readback, bytes: 64 * 64 * 4)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    let both = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource | .copyDestination))
    #expect(gpu.memories[up.handle]!.cached == false && gpu.memories[back.handle]!.cached == true)
    #expect(gpu.images[target.handle]!.region.cached == true, "drawn into and copied out of: the CPU only reads it")
    #expect(gpu.images[both.handle]!.region.cached == false, "the CPU writes it too: write-combining")
    func cleans(_ r: Region) -> Int { (r.buffer as! FakeBuffer).maintenance }
    let pipeline = try trianglePipeline(gpu)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))])) { r in
      r.draw(pipeline, root: 0x1000, vertices: 3)
    }
    list.copy(target, to: back)
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    // After the GPU's pass and before the CPU's copy out of it, the target's lines were dropped; once all is done the
    // readback memory the CPU wrote was cleaned for the CPU to read.
    #expect(cleans(gpu.images[target.handle]!.region) >= 1)
    #expect(cleans(gpu.memories[back.handle]!) >= 1)
    #expect(cleans(gpu.memories[up.handle]!) == 0 && cleans(gpu.images[both.handle]!.region) == 0)
    // What is let go is cleaned first, so no dirty line lands on another buffer's pages.
    let before = cleans(gpu.memories[back.handle]!)
    let region = gpu.memories[back.handle]!
    gpu.free(back)
    try gpu.wait(1)
    #expect((region.buffer as! FakeBuffer).maintenance > before || t.destroyed > 0)
  }

  @Test func aScanoutImageIsSharedAsItIsAndNotCachedByTheCPU() throws {
    let (gpu, _) = try device()
    let shown = try gpu.makeImage(ImageDescriptor(format: .bgra8srgb, width: 128, height: 64, usage: .renderTarget | .scanout))
    let plain = try gpu.makeImage(ImageDescriptor(format: .bgra8srgb, width: 128, height: 64, usage: .renderTarget | .copySource))
    // The display's layer reads rows of width times four bytes; 100 pixels are 400, which the image pads to 448.
    let odd = try gpu.makeImage(ImageDescriptor(format: .bgra8srgb, width: 100, height: 64, usage: .renderTarget | .scanout))
    #expect(gpu.images[shown.handle]!.region.cached == false, "the CPU never reads it: the GPU and the display share it")
    #expect(gpu.exportHandle(shown) != nil && gpu.exportHandle(shown) != gpu.exportHandle(shown), "a new handle each time")
    #expect(gpu.exportHandle(plain) == nil, "not a scanout image")
    #expect(gpu.exportHandle(odd) == nil, "rows the display could not read as they are")
    #expect((gpu.images[shown.handle]!.region.buffer as! FakeBuffer).exports == 3)
  }

  @Test func theTimelineRulesHoldAndAnEmptyListSignals() throws {
    let (gpu, _) = try device()
    try gpu.graphicsQueue.submit(GPUCommandList(), wait: 0, signal: 3)
    #expect(gpu.completed == 3)
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(GPUCommandList(), wait: 0, signal: 3) }
    try gpu.wait(3)
  }
}
