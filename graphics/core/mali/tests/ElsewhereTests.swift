// SPDX-License-Identifier: BSD-3-Clause

// More than one viewport and sparse resources on Mali (gpucore(2), Sparse.swift; valhall 02 section 2.9.4, 05 section 5.7, 06 section
// 6.2, 14 section 14.3.7, 16 section 16.8.6): what the device reports, the driver calls a bind makes, the 64 KiB layout a sparse image
// used partly bound has, and the transfer kernels, run on the interpreter (KernelRunner.swift), reaching memory through the binds.

import GPUCore
import MaliCore
import MaliFakeTransport
import Testing

@testable import GPUCoreMali

private func buffer(_ t: FakeTransport, at address: UInt64) -> FakeBuffer? {
  t.bound.first { $0.address == address }?.buffer
}

private func word(_ b: FakeBuffer, _ offset: Int) -> UInt32 { b.pointer.load(fromByteOffset: offset, as: UInt32.self) }

@Suite struct MaliElsewhere {
  @Test func theSparseFeaturesAndPropertiesAreTheReferencesAndOneViewport() throws {
    let gpu = try MaliDevice(transport: FakeTransport())
    let l = gpu.limits
    let f = l.features
    // One viewport: the scissor array raised DATA_INVALID_FAULT on the board.
    #expect(!f.multiViewport && !f.shaderOutputViewportIndex && l.maxViewports == 1)
    #expect(f.sparseBinding && f.sparseResidencyBuffer && f.sparseResidencyImage2D && f.sparseResidencyImage3D)
    #expect(!f.sparseResidency2Samples && !f.sparseResidency4Samples && !f.sparseResidency8Samples && !f.sparseResidency16Samples)
    #expect(!f.sparseResidencyAliased && !f.shaderResourceResidency)
    #expect(l.sparse.residencyStandard2DBlockShape && !l.sparse.residencyStandard2DMultisampleBlockShape)
    #expect(!l.sparse.residencyStandard3DBlockShape && !l.sparse.residencyAlignedMipSize && !l.sparse.residencyNonResidentStrict)
    #expect(l.sparseAddressSpaceSize > 0)
    // The blocks are 64 KiB tiles; a volume's one slice deep and not the standard shape; no multisampled or depth-target blocks.
    let usage: ImageUsage = .sampled | .copyDestination
    #expect(gpu.sparseImageFormats(.rgba8, dimension: .d2, samples: 1, usage: usage)
      == [SparseImageFormatProperties(aspects: .color, blockShape: Extent3D(width: 128, height: 128, depth: 1))])
    #expect(gpu.sparseImageFormats(.r8, dimension: .d2, samples: 1, usage: usage).first?.blockShape == Extent3D(width: 256, height: 256, depth: 1))
    #expect(gpu.sparseImageFormats(.rgba32float, dimension: .d3, samples: 1, usage: usage)
      == [SparseImageFormatProperties(aspects: .color, blockShape: Extent3D(width: 64, height: 64, depth: 1), nonStandardBlockSize: true)])
    #expect(gpu.sparseImageFormats(.rgba8, dimension: .d2, samples: 4, usage: usage).isEmpty)
    #expect(gpu.sparseImageFormats(.depth32f, dimension: .d2, samples: 1, usage: .depthStencilTarget).isEmpty)
    #expect(gpu.sparseImageFormats(.etc2rgb8, dimension: .d2, samples: 1, usage: usage).isEmpty)
  }

  @Test func aSparseBufferIsTheDummyUntilBoundAndAnUnbindIsTheDummyAgain() throws {
    let (gpu, t, _) = try kernelDevice()
    let page = 4096
    let b = try gpu.makeSparseBuffer(bytes: 3 * page, flags: .binding | .residency)
    #expect(try gpu.sparseRequirements(b) == SparseMemoryRequirements(size: 3 * page, pageBytes: page))
    #expect(t.rangeCalls.map { $0.kind } == ["dummy"] && t.rangeCalls[0].address == b.address && t.rangeCalls[0].size == 3 * page)
    // Bound only as a whole: no mapping until a bind.
    let whole = try gpu.makeSparseBuffer(bytes: page, flags: .binding)
    #expect(t.rangeCalls.count == 1 && whole.address % UInt64(page) == 0)
    let memory = try gpu.allocate(.device, bytes: 3 * page)
    func bind(_ p: Int, _ m: Int?) -> SparseBufferBind {
      SparseBufferBind(buffer: b, offset: p * page, size: page, memory: m == nil ? nil : memory, memoryOffset: (m ?? 0) * page)
    }
    try gpu.graphicsQueue.bindSparse(SparseBindings(buffers: [bind(0, 1), bind(2, 0)]), wait: 0, signal: 1)
    #expect(gpu.completed == 1)
    let own = try #require(buffer(t, at: memory.address))
    #expect(t.ranges.contains { $0.address == b.address && $0.buffer === own && $0.offset == page && $0.size == page })
    #expect(t.ranges.contains { $0.address == b.address + UInt64(2 * page) && $0.buffer === own && $0.offset == 0 })
    #expect(t.ranges.contains { $0.address == b.address + UInt64(page) && $0.buffer === t.dummy })
    // Filled through the sparse buffer, the words land in the memory's pages.
    var fill = GPUCommandList()
    fill.fill(b, offset: 0, bytes: page, value: 0x1111_1111)
    fill.fill(b, offset: 2 * page, bytes: page, value: 0x3333_3333)
    try gpu.graphicsQueue.submit(fill, wait: 1, signal: 2)
    #expect(word(own, page + 8) == 0x1111_1111 && word(own, 8) == 0x3333_3333)
    // Page 0 back to the dummy, page 1 to the memory page 0 had: a copy out reads page 0's word at page 1.
    try gpu.graphicsQueue.bindSparse(SparseBindings(buffers: [bind(0, nil), bind(1, 1)]), wait: 2, signal: 3)
    #expect(t.rangeCalls.suffix(2).map { $0.kind } == ["dummy", "map"])
    let out = try gpu.allocate(.readback, bytes: 3 * page)
    var copy = GPUCommandList()
    copy.copy(b, to: out, bytes: 3 * page)
    try gpu.graphicsQueue.submit(copy, wait: 3, signal: 4)
    let o = out.pointer!
    #expect(o.load(fromByteOffset: page + 64, as: UInt32.self) == 0x1111_1111)
    #expect(o.load(fromByteOffset: 2 * page + 64, as: UInt32.self) == 0x3333_3333)
    // Off the pages, of sparse memory, or of a buffer that isn't sparse: refused.
    #expect(throws: GPUError.self) {
      try gpu.graphicsQueue.bindSparse(SparseBindings(buffers: [SparseBufferBind(buffer: b, offset: 100, size: page, memory: memory)]), wait: 0, signal: 5)
    }
    #expect(throws: GPUError.self) {
      try gpu.graphicsQueue.bindSparse(SparseBindings(buffers: [SparseBufferBind(buffer: b, offset: 0, size: page, memory: whole)]), wait: 0, signal: 5)
    }
    // Freed, the range is unmapped.
    gpu.free(b)
    try gpu.wait(4)
    gpu.reclaim()
    #expect(t.rangeCalls.last?.kind == "unmap" && t.rangeCalls.last?.address == b.address)
  }

  @Test func aSparseImageIsInTheTiledLayoutBoundByTilesWithItsLastLevelTheTail() throws {
    let (gpu, t, _) = try kernelDevice()
    // rgba32uint: 16-byte texels, 64 x 64 blocks. 128 x 128 with two levels: level 0 four tiles, level 1 one (the tail).
    let usage: ImageUsage = .sampled | .copySource | .copyDestination
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba32uint, width: 128, height: 128, mipLevels: 2, usage: usage,
                                                  sparse: .binding | .residency))
    let tile = 65536
    #expect(try gpu.sparseRequirements(image) == SparseMemoryRequirements(size: 5 * tile, pageBytes: tile))
    let reqs = try gpu.sparseImageRequirements(image)
    #expect(reqs == [SparseImageRequirements(
      format: SparseImageFormatProperties(aspects: .color, blockShape: Extent3D(width: 64, height: 64, depth: 1)), mipTailFirstLevel: 1,
      mipTailSize: tile, mipTailOffset: 4 * tile, mipTailStride: 5 * tile)])
    let record = try #require(gpu.images[image.handle])
    #expect(record.layout.kind == .interleaved64K && record.layout.levels[0].rowStride == 2 * tile && record.layout.levels[1].offset == 4 * tile)
    #expect(t.rangeCalls.last?.kind == "dummy" && t.rangeCalls.last?.size == 5 * tile)
    // Its plane descriptors (in a region of their own) name the 64 KiB layout, and a view's texture descriptor its texel interleave.
    let planes = try #require(record.planeRegion)
    #expect((word(planes.buffer as! FakeBuffer, 0) >> 8) & 15 == 8)
    try gpu.writeTexture(3, ImageView(image))
    #expect((gpu.textureWords[3 * 8 + 2] >> 12) & 1 == 1)
    // Blocks (0, 0) and (1, 1) of level 0, to the memory's two tiles, x then y; level 1 can't be bound by blocks.
    let memory = try gpu.allocate(.device, bytes: 2 * tile)
    let binds = [SparseImageBind(image: image, extent: Extent3D(width: 64, height: 64), memory: memory),
                 SparseImageBind(image: image, offset: Offset3D(x: 64, y: 64), extent: Extent3D(width: 64, height: 64), memory: memory,
                                 memoryOffset: tile)]
    try gpu.graphicsQueue.bindSparse(SparseBindings(images: binds), wait: 0, signal: 1)
    #expect(t.rangeCalls.suffix(2).map { $0.address } == [record.region.address, record.region.address + UInt64(3 * tile)])
    #expect(throws: GPUError.self) {
      try gpu.graphicsQueue.bindSparse(SparseBindings(images: [SparseImageBind(image: image, mip: 1, extent: Extent3D(width: 64, height: 64),
                                                                               memory: memory)]), wait: 0, signal: 2)
    }
    #expect(throws: GPUError.self) {
      try gpu.graphicsQueue.bindSparse(SparseBindings(images: [SparseImageBind(image: image, offset: Offset3D(x: 32), extent: Extent3D(width: 32, height: 64),
                                                                               memory: memory)]), wait: 0, signal: 2)
    }
    // Two rows of texels copied into each bound block: in memory they are where 05 section 5.7.2 puts them, and a copy out reads them.
    let texels = 64 * 2
    let up = try gpu.allocate(.upload, bytes: 2 * texels * 16)
    for i in 0..<(2 * texels * 4) { up.pointer!.storeBytes(of: UInt32(i), toByteOffset: 4 * i, as: UInt32.self) }
    var list = GPUCommandList()
    list.copy(up, to: image, regions: [
      BufferImageRegion(imageOffset: Offset3D(x: 0, y: 5), imageExtent: Extent3D(width: 64, height: 2)),
      BufferImageRegion(bufferOffset: texels * 16, imageOffset: Offset3D(x: 64, y: 100), imageExtent: Extent3D(width: 64, height: 2))])
    let out = try gpu.allocate(.readback, bytes: 2 * texels * 16)
    list.copy(image, to: out, regions: [
      BufferImageRegion(imageOffset: Offset3D(x: 0, y: 5), imageExtent: Extent3D(width: 64, height: 2)),
      BufferImageRegion(bufferOffset: texels * 16, imageOffset: Offset3D(x: 64, y: 100), imageExtent: Extent3D(width: 64, height: 2))])
    try gpu.graphicsQueue.submit(list, wait: 1, signal: 2)
    let own = try #require(buffer(t, at: memory.address))
    for (k, (x, y)) in [(0, 5), (63, 6), (64, 100), (127, 101)].enumerated() {
      let n = (y - (k >= 2 ? 100 : 5)) * 64 + x % 64 + (k >= 2 ? texels : 0)
      let at = (k >= 2 ? tile : 0) + ImageLayout.offset64K(x: x % 64, y: y % 64, bytes: 16, rowStride: 2 * tile)
      #expect(word(own, at) == UInt32(4 * n), "texel (\(x), \(y)) in memory")
    }
    var wrong = 0
    for i in 0..<(2 * texels * 4) where out.pointer!.load(fromByteOffset: 4 * i, as: UInt32.self) != UInt32(i) { wrong += 1 }
    #expect(wrong == 0)
  }
}
