// SPDX-License-Identifier: BSD-3-Clause

// The Mali backend's resources over a fake transport (gpucore(2)): images of every shape and format, the views and samplers the heap
// holds, and the copies, blits and clears the CPU does in order with the GPU's passes, judged by the bytes in the image's memory.

import GPUCore
import MaliCore
import MaliFakeTransport
import Testing

@testable import GPUCoreMali

/// The copies, blits and clears are the GPU's kernels: they run on the interpreter (KernelRunner.swift).
private func resourceDevice() throws -> (MaliDevice, FakeTransport) {
  let (gpu, t, _) = try kernelDevice()
  return (gpu, t)
}

private func upload(_ gpu: MaliDevice, _ data: [UInt8]) throws -> GPUMemory {
  let m = try gpu.allocate(.upload, bytes: max(data.count, 16))
  for (i, b) in data.enumerated() { m.pointer!.storeBytes(of: b, toByteOffset: i, as: UInt8.self) }
  return m
}

private func read(_ m: GPUMemory, _ count: Int) -> [UInt8] {
  (0..<count).map { m.pointer!.load(fromByteOffset: $0, as: UInt8.self) }
}

@Suite struct MaliResources {
  @Test func anImageKeepsAPlanePerAspectOverAllItsLevelsAndLayers() throws {
    let (gpu, _) = try resourceDevice()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, mipLevels: 4, layers: 3, usage: .sampled | .copyDestination))
    let record = gpu.images[image.handle]!
    #expect(record.planes.count == 1 && record.planes[0].layout.levels.count == 4 && record.planes[0].layout.layers == 3)
    // The plane descriptors of the whole image follow the texels: one for each layer and level.
    #expect(record.planeAt == record.planes[0].layout.arrayStride * 3)
    let depth = try gpu.makeImage(ImageDescriptor(format: .depth24stencil8, width: 4, height: 4, usage: .sampled | .copyDestination))
    let d = gpu.images[depth.handle]!
    #expect(d.planes.map { $0.aspect } == [.depth, .stencil])
    #expect(d.planes[0].texel.bytesPerTexel == 4 && d.planes[1].texel.bytesPerTexel == 1 && d.planes[1].offset > d.planes[0].offset)
  }

  @Test func aViewOfALayerAndALevelHasAnArrayOfItsOwn() throws {
    let (gpu, _) = try resourceDevice()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, mipLevels: 3, layers: 4, usage: .sampled))
    try gpu.writeTexture(3, ImageView(image, dimension: .d2, baseMip: 1, mipCount: 1, baseLayer: 2, layerCount: 1))
    let w = Array(gpu.textureWords[(3 * Heap.entryWords)..<(4 * Heap.entryWords)])
    // Dimension 2D [6:4]; the first level of the view is 4 by 4; one level; array of one.
    #expect(w[0] >> 4 & 7 == 2 && w[1] == 3 | 3 << 16 && w[2] >> 16 & 31 == 0 && w[6] == 0)
    // Its array is its own: one plane descriptor, at layer 2 level 1 of the image.
    let array = gpu.textureArrays[3]!
    let record = gpu.images[image.handle]!
    let l = record.planes[0].layout
    let at = record.region.address + UInt64(2 * l.arrayStride + l.levels[1].offset)
    #expect(UInt64(w[4]) | UInt64(w[5]) << 32 == array.address)
    #expect(array.buffer.pointer.load(fromByteOffset: 8, as: UInt32.self) == UInt32(truncatingIfNeeded: at))
    // A cube view of six layers has dimension 0 and an array size of cubes.
    let cube = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, layers: 12, dimension: .cube, usage: .sampled))
    try gpu.writeTexture(4, ImageView(cube, baseLayer: 6, layerCount: 6))
    let c = Array(gpu.textureWords[(4 * Heap.entryWords)..<(5 * Heap.entryWords)])
    #expect(c[0] >> 4 & 7 == 0 && c[6] == 0)
  }

  @Test func aDepthViewReadsTheValueAndConstants() throws {
    let (gpu, _) = try resourceDevice()
    let image = try gpu.makeImage(ImageDescriptor(format: .depth32f, width: 4, height: 4, usage: .sampled))
    try gpu.writeTexture(0, ImageView(image))
    let w = gpu.textureWords[2]
    // (depth, 0, 0, 1): the first component, constant zero twice, constant one.
    #expect(w & 0xFFF == TextureSwizzle.make(r: 0, g: 4, b: 4, a: 5))
    // A colour image's swizzle composes with the view's: red and blue exchanged.
    let color = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: .sampled))
    try gpu.writeTexture(1, ImageView(color, swizzle: ComponentMapping(r: .b, b: .r)))
    #expect(gpu.textureWords[Heap.entryWords + 2] & 0xFFF == TextureSwizzle.make(r: 2, g: 1, b: 0, a: 3))
  }

  @Test func aSamplersWholeStateIsInItsWords() throws {
    let (gpu, _) = try resourceDevice()
    try gpu.writeSampler(1, SamplerDescriptor(
      minFilter: .nearest, magFilter: .linear, mipmapMode: .linear, addressModeU: .repeat, addressModeV: .mirrorClampToEdge,
      addressModeW: .clampToBorder, mipLodBias: 1.5, minLod: 1, maxLod: 4, maxAnisotropy: 8, compare: .less,
      customBorderColor: .float(0.25, 0.5, 0.75, 1)))
    let w = Array(gpu.samplerWords[8..<16])
    #expect(w[0] >> 16 & 15 == 8 && w[0] >> 12 & 15 == 13 && w[0] >> 8 & 15 == 11)
    // Minify nearest, magnify linear, performance trilinear with anisotropy (03 section 3.7.1).
    #expect(w[0] >> 27 & 1 == 1 && w[0] >> 28 & 1 == 0 && w[0] >> 30 == 2)
    // Vulkan's less is field 4: the hardware compares the texel with the reference, so the function is mirrored (03 section 3.7.4).
    #expect(w[1] >> 13 & 7 == 4 && w[1] & 0x1FFF == 256 && w[1] >> 16 & 0x1FFF == 1024)
    #expect(w[2] & 0xFFFF == 384 && w[2] >> 16 & 31 == 7 && w[2] >> 24 & 3 == 3)
    #expect(w[4] == Float(0.25).bitPattern && w[7] == Float(1).bitPattern)
    try gpu.writeSampler(2, SamplerDescriptor(filter: .nearest, minLod: 0, maxLod: 0, unnormalizedCoordinates: true))
    let u = Array(gpu.samplerWords[16..<24])
    #expect(u[0] >> 25 & 1 == 0)
  }

  @Test func clearsWriteTheBytesOfTheirFormats() throws {
    let (gpu, _) = try resourceDevice()
    let cases: [(PixelFormat, ClearColor, [UInt8])] = [
      (.rg8, .float(0.2, 0.8, 0, 0), [51, 204]),
      (.rgba8snorm, .float(0.5, -0.5, 1, -1), [64, 192, 127, 129]),
      (.r32uint, .uint(0xDEAD_BEEF, 0, 0, 0), [0xEF, 0xBE, 0xAD, 0xDE]),
      (.rgba16float, .float(0.25, 0.5, 0.75, 1), [0, 0x34, 0, 0x38, 0, 0x3A, 0, 0x3C]),
    ]
    for (format, value, texel) in cases {
      let image = try gpu.makeImage(ImageDescriptor(format: format, width: 2, height: 2, usage: .copySource | .copyDestination))
      let out = try gpu.allocate(.readback, bytes: 4 * texel.count)
      var list = GPUCommandList()
      list.clear(image, color: value)
      list.copy(image, to: out, regions: [BufferImageRegion(imageExtent: Extent3D(width: 2, height: 2))])
      try gpu.run(list, signal: gpu.rule.lastSignalled + 1)
      #expect(read(out, 4 * texel.count) == texel + texel + texel + texel, "\(format)")
    }
    // The packed ones: 0.5, 0.25, 0.75, 1 as 10, 10, 10 and 2 bits; 0.5 as the 11 and 10-bit floats.
    let packed = try gpu.makeImage(ImageDescriptor(format: .rgb10a2unorm, width: 1, height: 1, usage: .copySource | .copyDestination))
    let out = try gpu.allocate(.readback, bytes: 4)
    var list = GPUCommandList()
    list.clear(packed, color: .float(0.5, 0.25, 0.75, 1))
    list.copy(packed, to: out, regions: [BufferImageRegion(imageExtent: Extent3D(width: 1, height: 1))])
    try gpu.run(list, signal: gpu.rule.lastSignalled + 1)
    let word = out.pointer!.load(as: UInt32.self)
    #expect(word == 512 | 256 << 10 | 767 << 20 | 3 << 30)
  }

  @Test func regionsPlaceBlocksInLevelsLayersAndSlices() throws {
    let (gpu, _) = try resourceDevice()
    let usage: ImageUsage = .copySource | .copyDestination
    let volume = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, depth: 4, dimension: .d3, usage: usage))
    var data = [UInt8](repeating: 0xEE, count: 6 * 3 * 2 * 4)
    for z in 0..<2 { for y in 0..<2 { for x in 0..<4 { let o = ((z * 3 + y) * 6 + x) * 4; data[o] = UInt8(x + 1); data[o + 1] = UInt8(y + 1); data[o + 2] = UInt8(z + 1); data[o + 3] = 255 } } }
    let up = try upload(gpu, data)
    let out = try gpu.allocate(.readback, bytes: 8 * 8 * 4 * 4)
    var list = GPUCommandList()
    list.clear(volume, color: .float(0, 0, 0, 0))
    list.copy(up, to: volume, regions: [BufferImageRegion(bufferRowLength: 6, bufferImageHeight: 3, imageOffset: Offset3D(x: 1, y: 2, z: 1), imageExtent: Extent3D(width: 4, height: 2, depth: 2))])
    list.copy(volume, to: out, regions: [BufferImageRegion(imageExtent: Extent3D(width: 8, height: 8, depth: 4))])
    try gpu.run(list, signal: 1)
    let got = read(out, 8 * 8 * 4 * 4)
    var wrong = 0
    for z in 0..<4 { for y in 0..<8 { for x in 0..<8 {
      let inside = x >= 1 && x < 5 && y >= 2 && y < 4 && z >= 1 && z < 3
      let want: [UInt8] = inside ? [UInt8(x), UInt8(y - 1), UInt8(z), 255] : [0, 0, 0, 0]
      let o = ((z * 8 + y) * 8 + x) * 4
      if Array(got[o..<(o + 4)]) != want { wrong += 1 }
    } } }
    #expect(wrong == 0)
  }

  @Test func aBlitScalesFlipsAndConverts() throws {
    let (gpu, _, runner) = try kernelDevice()
    let usage: ImageUsage = .copySource | .copyDestination
    let small = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 2, height: 2, usage: usage))
    let big = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: usage))
    let flipped = try gpu.makeImage(ImageDescriptor(format: .bgra8, width: 2, height: 2, usage: usage))
    let texels: [UInt8] = [10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255, 100, 110, 120, 255]
    // The same format with the nearest filter is a raw move; into bgra8, the texture unit reads the source (modelled here).
    runner.textures[0] = unormTexture(texels, width: 2, height: 2)
    let up = try upload(gpu, texels)
    let a = try gpu.allocate(.readback, bytes: 64)
    let b = try gpu.allocate(.readback, bytes: 16)
    var list = GPUCommandList()
    list.copy(up, to: small)
    list.blitImage(small, to: big, regions: [ImageBlitRegion(srcMax: Offset3D(x: 2, y: 2, z: 1), dstMax: Offset3D(x: 4, y: 4, z: 1))], filter: .nearest)
    list.blitImage(small, to: flipped, regions: [ImageBlitRegion(srcMax: Offset3D(x: 2, y: 2, z: 1), dstMin: Offset3D(x: 2, y: 0, z: 0), dstMax: Offset3D(x: 0, y: 2, z: 1))], filter: .nearest)
    list.copy(big, to: a)
    list.copy(flipped, to: b)
    try gpu.run(list, signal: 1)
    let g = read(a, 64)
    // Each texel of the source is a 2 by 2 block.
    #expect(Array(g[0..<4]) == [10, 20, 30, 255] && Array(g[4..<8]) == [10, 20, 30, 255] && Array(g[8..<12]) == [40, 50, 60, 255])
    // Flipped horizontally into BGRA: texel (0, 0) is the source's (1, 0) with red and blue exchanged.
    let f = read(b, 16)
    #expect(Array(f[0..<4]) == [60, 50, 40, 255] && Array(f[4..<8]) == [30, 20, 10, 255])
  }

  @Test func fillsAndUpdatesWriteTheirBytes() throws {
    let (gpu, _) = try resourceDevice()
    let m = try gpu.allocate(.readback, bytes: 32)
    var list = GPUCommandList()
    list.fill(m, bytes: 32, value: 0xAABB_CCDD)
    list.update(m, offset: 8, data: [1, 2, 3, 4, 5, 6, 7, 8])
    try gpu.run(list, signal: 1)
    let g = read(m, 32)
    #expect(Array(g[0..<4]) == [0xDD, 0xCC, 0xBB, 0xAA] && Array(g[8..<16]) == [1, 2, 3, 4, 5, 6, 7, 8] && g[16] == 0xDD)
  }

  @Test func theFeaturesTheBoardHasNotJudgedAreOffUntilProbed() throws {
    let (gpu, _) = try device()
    #expect(gpu.limits.features.mipmaps && gpu.limits.features.copyImage && gpu.limits.features.compressedASTC == false)
    #expect(gpu.limits.features.importHandle && !gpu.limits.features.samplerMinMagFilters)
    gpu.probeEnableResources()
    #expect(gpu.limits.features.importHandle && gpu.limits.features.samplerMinMagFilters)
    #expect(gpu.limits.formats(.rgba16float).sampled && gpu.limits.formats(.depth32f).sampled && gpu.limits.formats(.depth32f).depthTarget && !gpu.limits.formats(.depth24stencil8).depthTarget)
  }

  @Test func compressedFormatsFollowTextureFeatures() throws {
    let t = FakeTransport()
    t.info.textureFeatures = 0b1_0000_0000_0000_0000_0000_0000 << 0 | 1 << 22 | 0b1001_1110
    let gpu = try MaliDevice(transport: t)
    gpu.probeEnableResources()
    // ASTC LDR (bit 22) and every ETC2 and EAC format would be needed for ETC2: bits 1 to 4 here, not 17 to 19.
    #expect(gpu.limits.features.compressedASTC && !gpu.limits.features.compressedETC2 && !gpu.limits.features.compressedBC)
    #expect(gpu.limits.formats(.astc(.b6x6)).sampled && !gpu.limits.formats(.etc2rgb8).sampled)
    let image = try gpu.makeImage(ImageDescriptor(format: .astc(.b6x6), width: 12, height: 12, usage: .sampled | .copyDestination))
    let l = gpu.images[image.handle]!.planes[0].layout
    #expect(l.levels[0].width == 12 && l.format.blockWidth == 6 && l.levels[0].rowStride == 64)
  }
}
