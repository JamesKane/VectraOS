// SPDX-License-Identifier: BSD-3-Clause

// The Mali backend's multisampling, clears inside a pass and kept depth and stencil over the fake transport (D174's amendment,
// step 3): the words of the framebuffer descriptors and the draws a pass is given (valhall 08 sections 8.2, 8.3, 8.4, 8.5 and 8.10).

import GPUCore
import MaliFakeTransport
import ShaderTestKit
import Testing

@testable import GPUCoreMali

/// The blocks the last submissions bound, and the framebuffer parameters of a `width` by `height` pass in them.
struct PassMemory {
  let blocks: [(region: (address: UInt64, size: Int), words: [UInt32])]
  init(_ t: FakeTransport) {
    blocks = zip(t.boundAtSubmit, t.memory.suffix(t.boundAtSubmit.count)).map { ($0.0, $0.1) }
  }
  func word(_ a: UInt64) -> UInt32? {
    for b in blocks where a >= b.region.address && a + 4 <= b.region.address + UInt64(b.region.size) {
      return b.words[Int(a - b.region.address) / 4]
    }
    return nil
  }
  func pair(_ a: UInt64) -> UInt64 { UInt64(word(a) ?? 0) | UInt64(word(a + 4) ?? 0) << 32 }
  /// The address of each framebuffer parameters block of a pass of this size over the whole frame (08 section 8.2.1: words 8 to 10).
  func framebuffers(width: Int, height: Int) -> [UInt64] {
    var out: [UInt64] = []
    let size = UInt32(width - 1) | UInt32(height - 1) << 16
    for b in blocks where b.words.count > 32 {
      for i in 0..<(b.words.count - 32) where b.words[i + 8] == size && b.words[i + 9] == 0 && b.words[i + 10] == size
        && b.words[i + 11] >> 24 != 0 && b.words[i + 14] != 0 {
        out.append(b.region.address + UInt64(i * 4))
      }
    }
    return out
  }
}

@Suite struct MultisampleTests {
  @Test func multisamplingIsOnWithTheHardwaresSampleCounts() throws {
    let (gpu, _) = try device()
    let l = gpu.limits
    #expect(l.features.multisample && l.features.resolveAttachments && l.features.resolveImage)
    #expect(l.features.sampleShading && l.features.alphaToCoverage && l.features.alphaToOne)
    #expect(l.maxSamples == 16)
    for f in [PixelFormat.rgba8, .bgra8, .bgra8srgb] { #expect(l.formats(f).renderSamples.rawValue == 31) }
    for f in [PixelFormat.depth16, .depth32f, .stencil8] { #expect(l.formats(f).depthSamples.rawValue == 31) }
    #expect(!l.features.fillModeNonSolid, "no polygon modes: the hardware has none (valhall 06 section 6.4.6)")
  }

  @Test func aMultisampledImageHasASamplePlaneEach() throws {
    let (gpu, _) = try device()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 16, height: 16, samples: 4, usage: .renderTarget | .sampled))
    let record = try #require(gpu.images[image.handle])
    #expect(record.layout.samples == 4)
    #expect(record.layout.levels[0].levelSize == 4 * record.layout.levels[0].surfaceStride)
    #expect(record.layout.texelOffset(x: 0, y: 0, sample: 3) == 3 * record.layout.levels[0].surfaceStride)
    #expect(throws: GPUError.self) {
      try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 16, height: 16, samples: 32, usage: .renderTarget))
    }
  }

  func pipeline(_ gpu: MaliDevice, samples: UInt32, mask: UInt64 = ~0) throws -> GPUPipeline {
    try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(
      vertex: bytes(try assemble(Corpus.varyingVertex)), fragment: bytes(try assemble(Corpus.varyingFragment)), colorFormats: [.rgba8],
      multisample: MultisampleState(samples: samples, sampleMask: mask)))
  }

  @Test func aPassResolvedAsItEndsWritesTheAverageToTheResolveImage() throws {
    let (gpu, t) = try device()
    let pso = try pipeline(gpu, samples: 4, mask: 0b0101)
    let ms = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, samples: 4, usage: .renderTarget))
    let resolved = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(view: ImageView(ms), load: .clear(0, 0, 0, 1), store: .discard, resolve: ImageView(resolved))])) { r in
      r.draw(pso, root: 0x1000, vertices: 3)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let m = PassMemory(t)
    let fbd = try #require(m.framebuffers(width: 64, height: 64).last)
    let w11 = try #require(m.word(fbd + 44))
    #expect(w11 & 7 == 2 && w11 >> 3 & 7 == 2, "4 samples, the rotated 4x pattern")
    #expect(w11 >> 19 & 15 == 0, "one render target")
    // The target's writeback is the average, into the resolve image.
    let rt = fbd + 128
    #expect(m.word(rt + 4)! >> 12 & 3 == 1)
    #expect(m.pair(rt + 32) == gpu.images[resolved.handle]!.region.address)
    // The draw: multisample enabled (flags 0 `[19]`) and the sample mask in flags 1.
    let draw = try #require(runs(t.streams.last(where: { runs($0).count > 0 }) ?? []).last)
    #expect(draw.registers[57] >> 19 & 1 == 1)
    #expect(draw.registers[58] & 0xFFFF == 0b0101)
  }

  @Test func aTargetStoredAndResolvedHasASecondDescriptorOverTheSameTile() throws {
    let (gpu, t) = try device()
    let pso = try pipeline(gpu, samples: 8)
    let ms = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, samples: 8, usage: .renderTarget))
    let resolved = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(view: ImageView(ms), load: .clear(0, 0, 0, 1), store: .store, resolve: ImageView(resolved))])) { r in
      r.draw(pso, root: 0x1000, vertices: 3)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let m = PassMemory(t)
    let fbd = try #require(m.framebuffers(width: 64, height: 64).last)
    let w11 = try #require(m.word(fbd + 44))
    #expect(w11 & 7 == 3 && w11 >> 3 & 7 == 3, "8 samples, the D3D 8x pattern")
    #expect(w11 >> 19 & 15 == 1, "two descriptors")
    let record = gpu.images[ms.handle]!
    #expect(m.word(fbd + 128 + 4)! >> 12 & 3 == 3, "every sample to its surface")
    #expect(m.pair(fbd + 128 + 32) == record.region.address)
    #expect(m.word(fbd + 128 + 44) == UInt32(record.layout.levels[0].surfaceStride))
    #expect(m.word(fbd + 192 + 4)! >> 12 & 3 == 1, "the average")
    #expect(m.word(fbd + 192)! & 0xFFF0 == m.word(fbd + 128)! & 0xFFF0, "the same internal buffer offset")
    #expect(m.pair(fbd + 192 + 32) == gpu.images[resolved.handle]!.region.address)
  }

  @Test func aClearInsideAPassIsADrawOfItsRectangle() throws {
    let (gpu, t) = try device()
    #expect(gpu.limits.features.clearAttachments)
    let pso = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.draw(pso, root: 0x1000, vertices: 3)
      r.clearAttachments([.color(index: 0, .float(1, 0, 0, 1))], rects: [ClearRect(x: 2, y: 3, width: 4, height: 5)])
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let draws = runs(t.streams.last(where: { runs($0).count > 0 }) ?? [])
    #expect(draws.count == 2)
    // The second draw's scissor (registers 42 and 43) is the rectangle.
    let clear = try #require(draws.last)
    #expect(clear.registers[42] == 2 | 3 << 16)
    #expect(clear.registers[43] == 5 | 7 << 16)
  }

  @Test func aKeptDepthIsLoadedByTheSecondPreFrameShader() throws {
    let (gpu, t) = try device()
    let pso = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(
      vertex: bytes(try assemble(Corpus.varyingVertex)), fragment: bytes(try assemble(Corpus.varyingFragment)), colorFormats: [.rgba8],
      depthStencilFormat: .depth32f, depthStencil: DepthStencilState(depthTest: true, depthWrite: true, depthCompare: .less)))
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    let depth = try gpu.makeImage(ImageDescriptor(format: .depth32f, width: 64, height: 64, usage: .depthStencilTarget))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))],
                              depthStencil: DepthStencilAttachment(image: depth, depthLoad: .load))) { r in
      r.draw(pso, root: 0x1000, vertices: 3)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let m = PassMemory(t)
    let fbd = try #require(m.framebuffers(width: 64, height: 64).last)
    let w0 = try #require(m.word(fbd))
    #expect(w0 & 7 == 0 && w0 >> 3 & 7 == 3, "no colour load; the depth load Early ZS Always")
    let dcd = m.pair(fbd + 24) + 128
    let flags0 = try #require(m.word(dcd))
    #expect(flags0 >> 2 & 3 == 3 && flags0 >> 4 & 3 == 3 && flags0 & 1 == 0 && flags0 >> 9 & 1 == 1, "late, no kill, a clean write")
    // Its depth/stencil descriptor: Always, written, the depth from the shader.
    let zsd = m.pair(dcd + 40)
    let w4 = try #require(m.word(zsd + 16))
    #expect(w4 >> 29 == 7 && w4 >> 27 & 1 == 1 && w4 >> 25 & 3 == 3)
  }
}
