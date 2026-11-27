// SPDX-License-Identifier: BSD-3-Clause

// The Mali backend's transfers on the GPU (gpucore(2), Transfers.swift): every copy, blit, clear, fill, update and resolve is a
// compute dispatch of the device's, in order with the list's passes and with no CPU step between them, and each kernel, run on
// the interpreter over the fake transport's memory (KernelRunner.swift), writes exactly the bytes a CPU reference says.

import GPUCore
import MaliCore
import MaliFakeTransport
import Testing
import ValhallInterp

@testable import GPUCoreMali

private func upload(_ gpu: MaliDevice, _ data: [UInt8]) throws -> GPUMemory {
  let m = try gpu.allocate(.upload, bytes: max(data.count, 16))
  for (i, b) in data.enumerated() { m.pointer!.storeBytes(of: b, toByteOffset: i, as: UInt8.self) }
  return m
}

private func read(_ m: GPUMemory, _ count: Int) -> [UInt8] {
  (0..<count).map { m.pointer!.load(fromByteOffset: $0, as: UInt8.self) }
}

private func byte(_ x: Int, _ y: Int, _ l: Int, _ c: Int) -> UInt8 { UInt8(truncatingIfNeeded: x * 17 + y * 5 + l * 61 + c * 29 + 3) }

@Suite struct MaliTransfers {
  @Test func everyTransferIsADispatchInOrderWithThePassesAndNoCPUStep() throws {
    let (gpu, t, runner) = try kernelDevice()
    let usage: ImageUsage = .copySource | .copyDestination
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, usage: .renderTarget | usage))
    let other = try gpu.makeImage(ImageDescriptor(format: .bgra8, width: 8, height: 8, usage: usage))
    let ms = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, samples: 4, usage: .renderTarget | usage))
    let ds = try gpu.makeImage(ImageDescriptor(format: .depth32f, width: 8, height: 8, usage: usage))
    let m = try gpu.allocate(.device, bytes: 256)
    let back = try gpu.allocate(.readback, bytes: 256)
    runner.textures[0] = unormTexture([UInt8](repeating: 0, count: 256), width: 8, height: 8)
    let pipeline = try trianglePipeline(gpu)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 1, 1))])) { r in r.draw(pipeline, root: 0x1000, vertices: 3) }
    list.copyImage(target, to: target, regions: [ImageCopyRegion(dstOffset: Offset3D(x: 4), extent: Extent3D(width: 4, height: 4))])
    list.blitImage(target, to: other, regions: [ImageBlitRegion(srcMax: Offset3D(x: 8, y: 8, z: 1), dstMax: Offset3D(x: 8, y: 8, z: 1))], filter: .linear)
    list.fill(m, bytes: 256, value: 7)
    list.update(m, offset: 4, data: [1, 2, 3, 4])
    list.copy(m, to: back, bytes: 256)
    list.clear(other, color: .float(1, 0, 0, 1))
    list.clear(ds, depth: 0.5)
    list.resolveImage(ms, to: target, regions: [ImageCopyRegion(extent: Extent3D(width: 8, height: 8))])
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .load)])) { r in r.draw(pipeline, root: 0x1000, vertices: 3) }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    // One submit: two passes on the tiler's and the fragment's queues, between them eight kernels on the compute queue, one a
    // command, each step waiting on the GPU for the one before it.
    #expect(t.submits.count == 1)
    #expect(t.submits[0].jobs.map { $0.queue } == [0, 1, 2] + [0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 0, 1])
    #expect(runner.ran.map { $0.kernel } == [.copy, .blit, .copy, .copy, .copy, .copy, .copy, .copy])
    // It signals the timeline; nothing the CPU maps was maintained between the steps.
    #expect(t.submits[0].signals.count == 1 && t.submits[0].signals[0].sync == gpu.timeline)
    #expect(t.bound.allSatisfy { $0.buffer.maintenance == 0 })
    #expect(read(back, 8) == [7, 0, 0, 0, 1, 2, 3, 4])
  }

  @Test func aWholeClearOfARenderTargetIsAPassThatDrawsIt() throws {
    let (gpu, t, runner) = try kernelDevice()
    let target = try gpu.makeImage(ImageDescriptor(format: .bgra8srgb, width: 64, height: 64, usage: .renderTarget | .copyDestination))
    let levels = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, mipLevels: 2, usage: .renderTarget | .copyDestination))
    var list = GPUCommandList()
    list.clear(target, color: .float(0.25, 0.5, 0.75, 1))
    list.clear(levels, color: .float(1, 0, 0, 1))
    var held: [Region] = []
    let steps = try gpu.plan(list, held: &held)
    // The one-level render target: a pass whose fragment work clears it and draws the clear; the image of two levels: the kernel.
    #expect(steps.count == 2)
    guard case .render(let pass) = steps[0] else {
      Issue.record("the clear of a render target is not a pass")
      return
    }
    #expect(pass.target.descriptor.format == .bgra8srgb && pass.clear == [0.25, 0.5, 0.75, 1] && pass.draws.count == 1 && !pass.load)
    guard case .dispatch(_, _, _, _, _, _, let kernel) = steps[1] else {
      Issue.record("the clear of an image of two levels is not a kernel")
      return
    }
    #expect(kernel == .copy)
    gpu.retire(held)
    _ = (t, runner)
  }

  @Test func bufferRegionsMoveRowsOfOneTwoFourEightAndSixteenBytes() throws {
    let (gpu, _, _) = try kernelDevice()
    let usage: ImageUsage = .copySource | .copyDestination
    for (format, bytes) in [(PixelFormat.r8, 1), (.r16float, 2), (.rgba8, 4), (.rgba16float, 8), (.rgba32uint, 16)] {
      // A 5x3 region at (1, 2) of level 1 of layers 1 and 2; rows of 13 texels and slices of 5 rows in the buffer.
      let image = try gpu.makeImage(ImageDescriptor(format: format, width: 16, height: 16, mipLevels: 2, layers: 3, usage: usage))
      var data = [UInt8](repeating: 0xEE, count: 13 * 5 * 2 * bytes)
      for l in 0..<2 { for y in 0..<3 { for x in 0..<5 { for c in 0..<bytes { data[((l * 5 + y) * 13 + x) * bytes + c] = byte(x, y, l, c) } } } }
      let up = try upload(gpu, data)
      let out = try gpu.allocate(.readback, bytes: 8 * 8 * 2 * bytes)
      let level = ImageSubresourceLayers(aspects: .color, mip: 1, baseLayer: 1, layerCount: 2)
      var list = GPUCommandList()
      list.clear(image, color: format.channelClass == .uint ? .uint(0, 0, 0, 0) : .float(0, 0, 0, 0))
      list.copy(up, to: image, regions: [BufferImageRegion(bufferRowLength: 13, bufferImageHeight: 5, subresource: level, imageOffset: Offset3D(x: 1, y: 2),
                                                           imageExtent: Extent3D(width: 5, height: 3))])
      list.copy(image, to: out, regions: [BufferImageRegion(subresource: level, imageExtent: Extent3D(width: 8, height: 8))])
      try gpu.run(list, signal: gpu.rule.lastSignalled + 1)
      let got = read(out, 8 * 8 * 2 * bytes)
      var wrong = 0
      for l in 0..<2 { for y in 0..<8 { for x in 0..<8 { for c in 0..<bytes {
        let inside = x >= 1 && x < 6 && y >= 2 && y < 5
        if got[((l * 8 + y) * 8 + x) * bytes + c] != (inside ? byte(x - 1, y - 2, l, c) : 0) { wrong += 1 }
      } } } }
      #expect(wrong == 0, "\(format)")
    }
  }

  @Test func depthAndStencilAspectsAreClearedByRangesAndCopiedAsBytes() throws {
    let (gpu, _, _) = try kernelDevice()
    let usage: ImageUsage = .copySource | .copyDestination
    let a = try gpu.makeImage(ImageDescriptor(format: .depth24stencil8, width: 4, height: 4, layers: 2, usage: usage))
    let b = try gpu.makeImage(ImageDescriptor(format: .depth24stencil8, width: 4, height: 4, usage: usage))
    let c = try gpu.makeImage(ImageDescriptor(format: .depth24stencil8, width: 8, height: 8, usage: usage))
    let depthIn = try upload(gpu, (0..<16).flatMap { k -> [UInt8] in [UInt8(k), UInt8(k + 100), 0x55, 0] })
    let stencilIn = try upload(gpu, (0..<16).map { UInt8($0 * 9 + 1) })
    let depthOut = try gpu.allocate(.readback, bytes: 256)
    let stencilOut = try gpu.allocate(.readback, bytes: 64)
    var list = GPUCommandList()
    list.clear(a, depth: 1, stencil: 3, ranges: [ImageSubresourceRange(aspects: .depth | .stencil, layerCount: 2)])
    list.clear(a, depth: 0, stencil: 77, ranges: [ImageSubresourceRange(aspects: .stencil, baseLayer: 1, layerCount: 1)])
    list.copy(depthIn, to: a, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .depth, baseLayer: 1), imageOffset: Offset3D(x: 2, y: 2),
                                                          imageExtent: Extent3D(width: 2, height: 2))])
    list.copy(stencilIn, to: a, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .stencil, baseLayer: 1),
                                                            imageExtent: Extent3D(width: 2, height: 1))])
    list.copyImage(a, to: b, regions: [ImageCopyRegion(srcSubresource: ImageSubresourceLayers(aspects: .depth | .stencil, baseLayer: 1),
                                                       dstSubresource: ImageSubresourceLayers(aspects: .depth | .stencil), extent: Extent3D(width: 4, height: 4))])
    // b blitted to twice the size, flipped across: the nearest texel's bytes.
    list.blitImage(b, to: c, regions: [ImageBlitRegion(srcSubresource: ImageSubresourceLayers(aspects: .depth | .stencil), srcMax: Offset3D(x: 4, y: 4, z: 1),
                                                       dstSubresource: ImageSubresourceLayers(aspects: .depth | .stencil), dstMin: Offset3D(x: 8, y: 0, z: 0),
                                                       dstMax: Offset3D(x: 0, y: 8, z: 1))], filter: .nearest)
    list.copy(c, to: depthOut, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .depth), imageExtent: Extent3D(width: 8, height: 8))])
    list.copy(c, to: stencilOut, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .stencil), imageExtent: Extent3D(width: 8, height: 8))])
    try gpu.run(list, signal: 1)
    let depths = read(depthOut, 256), stencils = read(stencilOut, 64)
    var wrong = 0
    for y in 0..<8 {
      for x in 0..<8 {
        let sx = (7 - x) / 2, sy = y / 2
        let k = (sy - 2) * 2 + (sx - 2)
        let depth: [UInt8] = sx >= 2 && sy >= 2 ? [UInt8(k), UInt8(k + 100), 0x55] : [0xFF, 0xFF, 0xFF]
        let stencil: UInt8 = sy == 0 && sx < 2 ? UInt8(sx * 9 + 1) : 77
        let got = Array(depths[((y * 8 + x) * 4)..<((y * 8 + x) * 4 + 3)])
        if got != depth || stencils[y * 8 + x] != stencil {
          wrong += 1
          if wrong < 4 { Issue.record("(\(x), \(y)): depth \(got) stencil \(stencils[y * 8 + x]), expected \(depth) \(stencil)") }
        }
      }
    }
    #expect(wrong == 0)
  }

  @Test func compressedBlocksAreCopiedAtBlockOffsetsIntoALevel() throws {
    let t = FakeTransport()
    t.info.textureFeatures = 1 << 22
    let gpu = try MaliDevice(transport: t)
    gpu.probeEnableResources()
    _ = KernelRunner(gpu, t)
    let usage: ImageUsage = .copySource | .copyDestination
    let a = try gpu.makeImage(ImageDescriptor(format: .astc(.b4x4), width: 16, height: 16, usage: usage))
    let b = try gpu.makeImage(ImageDescriptor(format: .astc(.b4x4), width: 16, height: 16, mipLevels: 2, usage: usage))
    let blocks = (0..<256).map { UInt8(truncatingIfNeeded: $0 * 7 + 5) }
    let up = try upload(gpu, blocks)
    let out = try gpu.allocate(.readback, bytes: 64)
    var list = GPUCommandList()
    list.copy(up, to: a, regions: [BufferImageRegion(imageExtent: Extent3D(width: 16, height: 16))])
    list.copyImage(a, to: b, regions: [ImageCopyRegion(srcOffset: Offset3D(x: 4, y: 8), dstSubresource: ImageSubresourceLayers(aspects: .color, mip: 1),
                                                       dstOffset: Offset3D(x: 4, y: 0), extent: Extent3D(width: 4, height: 8))])
    list.copy(b, to: out, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .color, mip: 1), imageExtent: Extent3D(width: 8, height: 8))])
    try gpu.run(list, signal: 1)
    let got = read(out, 64)
    // Level 1 is 2x2 blocks: blocks (1, 0) and (1, 1) are a's (1, 2) and (1, 3).
    #expect(Array(got[16..<32]) == Array(blocks[(2 * 4 + 1) * 16..<((2 * 4 + 1) * 16 + 16)]))
    #expect(Array(got[48..<64]) == Array(blocks[(3 * 4 + 1) * 16..<((3 * 4 + 1) * 16 + 16)]))
    #expect(Array(got[0..<16]) == [UInt8](repeating: 0, count: 16))
  }

  @Test func aResolveIsEachBytesMeanOfTheSamplesRounded() throws {
    let (gpu, _, _) = try kernelDevice()
    let ms = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, samples: 4, usage: .renderTarget | .copySource))
    let single = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: .renderTarget | .copySource | .copyDestination))
    let record = gpu.images[ms.handle]!
    // Sample s of every texel: (10 s, 255 - s, 2 s + 1, 64 s).
    for s in 0..<4 {
      for y in 0..<4 {
        for x in 0..<4 {
          let at = record.layout.texelOffset(x: x, y: y, sample: s)
          for (c, v) in [10 * s, 255 - s, 2 * s + 1, 64 * s].enumerated() {
            record.region.buffer.pointer.storeBytes(of: UInt8(v), toByteOffset: at + c, as: UInt8.self)
          }
        }
      }
    }
    let out = try gpu.allocate(.readback, bytes: 64)
    var list = GPUCommandList()
    list.clear(single, color: .float(0, 0, 0, 0))
    list.resolveImage(ms, to: single, regions: [ImageCopyRegion(srcOffset: Offset3D(x: 1, y: 1), dstOffset: Offset3D(x: 0, y: 2), extent: Extent3D(width: 2, height: 2))])
    list.copy(single, to: out)
    try gpu.run(list, signal: 1)
    let got = read(out, 64)
    // The means of (0, 10, 20, 30), (255, 254, 253, 252), (1, 3, 5, 7) and (0, 64, 128, 192), rounded: 15, 254 (253.5 up), 4, 96.
    #expect(Array(got[32..<36]) == [15, 254, 4, 96] && Array(got[52..<56]) == [15, 254, 4, 96])
    #expect(Array(got[0..<4]) == [0, 0, 0, 0] && Array(got[40..<44]) == [0, 0, 0, 0])
  }

  @Test func aLinearBlitConvertsThroughTheTextureUnitAndAFlippedOneMirrors() throws {
    let (gpu, _, runner) = try kernelDevice()
    let usage: ImageUsage = .copySource | .copyDestination
    let a = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 2, height: 1, usage: usage))
    let h = try gpu.makeImage(ImageDescriptor(format: .rgba16float, width: 4, height: 1, usage: usage))
    let texels: [UInt8] = [0, 0, 0, 255, 255, 51, 102, 255]
    runner.textures[0] = unormTexture(texels, width: 2, height: 1)
    let up = try upload(gpu, texels)
    let out = try gpu.allocate(.readback, bytes: 32)
    var list = GPUCommandList()
    list.copy(up, to: a)
    list.blitImage(a, to: h, regions: [ImageBlitRegion(srcMax: Offset3D(x: 2, y: 1, z: 1), dstMin: Offset3D(x: 4, y: 0, z: 0), dstMax: Offset3D(x: 0, y: 1, z: 1))],
                   filter: .linear)
    list.copy(h, to: out)
    try gpu.run(list, signal: 1)
    let got = read(out, 32)
    func red(_ x: Int) -> UInt16 { UInt16(got[x * 8]) | UInt16(got[x * 8 + 1]) << 8 }
    // Flipped: texel 0 samples the source at 1.75 (clamped: texel 1, 1.0), texel 3 at 0.25 (texel 0, 0.0), texels 1 and 2 at
    // 1.25 and 0.75 (0.75 and 0.25 of the way): 1.0, 0.75, 0.25, 0.0 as halves.
    #expect([red(0), red(1), red(2), red(3)] == [0x3C00, 0x3A00, 0x3400, 0])
    #expect(got[6] == 0x00 && got[7] == 0x3C, "alpha 1")
  }
}
