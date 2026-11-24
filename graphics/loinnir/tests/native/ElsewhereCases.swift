// SPDX-License-Identifier: BSD-3-Clause

// loinnir-test's cases for more than one viewport and for sparse resources (D174's amendment; gpucore(2)): each draws, copies or
// samples through the device and judges what it reads back exactly. A case the device lacks the feature for is skipped, with
// the reason.

import GPUCore
import Sys

extension CoreCases {
  /// Two viewports, each with its own scissor, in one pass of 16 x 16: one rectangle over the whole of clip space drawn twice,
  /// instance i with viewport i (ViewportIndex from the vertex stage). The first viewport is the left half, its scissor the
  /// top-left quarter (red there); the second the right half, its scissor rows 4 on (green there); the rest stays black.
  func viewports() throws(GPUError) {
    let l = d.limits
    guard f.multiViewport, l.maxViewports >= 2, f.shaderOutputViewportIndex, rgbaTarget else {
      return skip("viewports", "no second viewport chosen by the vertex stage (multiViewport \(f.multiViewport), viewports \(l.maxViewports), ViewportIndex \(f.shaderOutputViewportIndex))")
    }
    let w = 16, h = 16
    let mesh = try meshBuffer([Rect(x0: 0, y0: 0, x1: 16, y1: 16, color: [1, 0, 0, 1])], width: Float(w), height: Float(h))
    let pso = try d.makeGraphicsPipeline(GraphicsPipelineDescriptor(
      vertex: LoinnirShaders.viewportVert, fragment: LoinnirShaders.meshFrag, colorFormats: [.rgba8], blend: .opaque, viewportCount: 2))
    let target = try colorTarget(Int32(w), Int32(h))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.setViewports([Viewport(x: 0, y: 0, width: 8, height: 16), Viewport(x: 8, y: 0, width: 8, height: 16)])
      r.setScissors([RenderArea(x: 0, y: 0, width: 8, height: 8), RenderArea(x: 8, y: 4, width: 8, height: 12)])
      r.draw(pso, root: mesh.address, vertices: 6, instances: 2)
    }
    let px = try readBack(list, target)
    let n = judge("viewports", px, w, h) { x, y in
      if x < 8 && y < 8 { return [255, 0, 0, 255] }
      if x >= 8 && y >= 4 { return [0, 255, 0, 255] }
      return [0, 0, 0, 255]
    }
    ok("viewports: two viewports picked by ViewportIndex, each cut by its own scissor, \(n) pixels exact")
  }

  /// A sparse buffer of three pages, its pages moved between binds: with residency, pages 0 and 2 bound (to the second and the
  /// first page of memory) and page 1 left unbound, each bound page filled with its own word; then page 0 unbound and page 1
  /// bound to the memory page 0 had, and the buffer copied out: page 1 reads page 0's word, page 2 its own, and (where the device
  /// reads unbound pages as zero) page 0 zero. Without residency, all three bound and filled, then pages 0 and 2 swap their
  /// memory pages. The memory is reached only through the sparse buffer: aliasing it through another buffer is undefined.
  func sparseBuffer() throws(GPUError) {
    guard f.sparseBinding else { return skip("sparse buffer", "no sparse binding") }
    let partly = f.sparseResidencyBuffer
    let probe = try d.makeSparseBuffer(bytes: 1, flags: .binding)
    let page = try d.sparseRequirements(probe).pageBytes
    d.free(probe)
    guard page > 0, page % 4 == 0, page <= 1 << 20 else { return skip("sparse buffer", "a page of \(page) bytes") }
    let buffer = try d.makeSparseBuffer(bytes: 3 * page, flags: partly ? .binding | .residency : .binding)
    let memory = try d.allocate(.device, bytes: 3 * page)
    func bind(_ p: Int, _ m: Int?) -> SparseBufferBind {
      SparseBufferBind(buffer: buffer, offset: p * page, size: page, memory: m == nil ? nil : memory, memoryOffset: (m ?? 0) * page)
    }
    // Buffer page -> memory page: 0 -> 1, 2 -> 0, and (bound only without residency) 1 -> 2.
    var first = [bind(0, 1), bind(2, 0)]
    if !partly { first.append(bind(1, 2)) }
    timeline += 1
    try d.graphicsQueue.bindSparse(SparseBindings(buffers: first), wait: 0, signal: timeline)
    let words: [UInt32] = [0x1111_1111, 0x2222_2222, 0x3333_3333]
    var fill = GPUCommandList()
    for p in 0..<3 where p != 1 || !partly { fill.fill(buffer, offset: p * page, bytes: page, value: words[p]) }
    try run(fill)
    // The pages move: what each buffer page reads after, by the word it was filled with (nil: unbound).
    let second = partly ? [bind(0, nil), bind(1, 1)] : [bind(0, 0), bind(2, 1)]
    let want: [UInt32?] = partly ? [nil, words[0], words[2]] : [words[2], words[1], words[0]]
    timeline += 1
    try d.graphicsQueue.bindSparse(SparseBindings(buffers: second), wait: 0, signal: timeline)
    let out = try d.allocate(.readback, bytes: 3 * page)
    var copy = GPUCommandList()
    copy.copy(buffer, to: out, bytes: 3 * page)
    try run(copy)
    let strict = d.limits.sparse.residencyNonResidentStrict
    let o = unsafe out.pointer!.assumingMemoryBound(to: UInt32.self)
    let perPage = page / 4
    for p in 0..<3 {
      for i in stride(from: 0, to: perPage, by: 61) {
        let got = unsafe o[p * perPage + i]
        if let w = want[p] {
          if got != w { fail("sparse buffer: page \(p) word \(i) reads \(got), not \(w)") }
        } else if strict && got != 0 {
          fail("sparse buffer: unbound page \(p) word \(i) reads \(got), not 0")
        }
      }
    }
    ok("sparse buffer: 3 pages of \(page) bytes, \(partly ? "two bound and filled, then one unbound\(strict ? " (reading zero)" : "") and its memory bound at another" : "all bound and filled, then two swapping their memory"), each page's word where its memory went")
  }

  /// A sparse rgba8 image of four blocks used partly bound: its top-left and bottom-right blocks bound to two pages of memory and
  /// filled (red and green) by copies, the others unbound; sampled with the nearest filter into an 8 x 8 target, each quarter is
  /// its block's colour, and (where the device reads unbound blocks as zero) the unbound ones are zero.
  func sparseImage() throws(GPUError) {
    guard f.sparseBinding, f.sparseResidencyImage2D, f.sampledImages, rgbaTarget, f.imageRegionCopies else {
      return skip("sparse image", "no 2D images used partly bound")
    }
    let usage: ImageUsage = .sampled | .copyDestination
    let shapes = d.sparseImageFormats(.rgba8, dimension: .d2, samples: 1, usage: usage)
    guard let shape = shapes.first(where: { $0.aspects.contains(.color) }) else { return skip("sparse image", "no sparse rgba8 images") }
    let bw = Int(shape.blockShape.width), bh = Int(shape.blockShape.height)
    guard bw > 0, bh > 0, bw <= 1024, bh <= 1024 else { return skip("sparse image", "a block of \(bw) x \(bh)") }
    let w = 2 * bw, h = 2 * bh
    let image = try d.makeImage(ImageDescriptor(format: .rgba8, width: Int32(w), height: Int32(h), usage: usage, sparse: .binding | .residency))
    let req = try d.sparseRequirements(image)
    let tails = try d.sparseImageRequirements(image)
    guard let colour = tails.first(where: { $0.format.aspects.contains(.color) }), colour.mipTailFirstLevel >= 1 else {
      return skip("sparse image", "level 0 of a \(w) x \(h) image is in its mip tail")
    }
    let page = req.pageBytes
    let memory = try d.allocate(.device, bytes: 2 * page)
    let binds = [SparseImageBind(image: image, offset: Offset3D(), extent: Extent3D(width: UInt32(bw), height: UInt32(bh)), memory: memory),
                 SparseImageBind(image: image, offset: Offset3D(x: Int32(bw), y: Int32(bh)), extent: Extent3D(width: UInt32(bw), height: UInt32(bh)),
                                 memory: memory, memoryOffset: page)]
    timeline += 1
    try d.graphicsQueue.bindSparse(SparseBindings(images: binds), wait: 0, signal: timeline)
    // A block of red, and a block of green, copied into the two bound blocks.
    let upload = try d.allocate(.upload, bytes: 2 * bw * bh * 4)
    let u = unsafe upload.pointer!.assumingMemoryBound(to: UInt32.self)
    for i in 0..<(bw * bh) {
      unsafe u[i] = 0xFF00_00FF  // red, alpha 1 (little-endian rgba)
      unsafe u[bw * bh + i] = 0xFF00_FF00
    }
    var list = GPUCommandList()
    list.copy(upload, to: image, regions: [
      BufferImageRegion(imageExtent: Extent3D(width: UInt32(bw), height: UInt32(bh))),
      BufferImageRegion(bufferOffset: bw * bh * 4, imageOffset: Offset3D(x: Int32(bw), y: Int32(bh)),
                        imageExtent: Extent3D(width: UInt32(bw), height: UInt32(bh)))])
    let slot = textureBase + 6
    try d.writeTexture(slot, ImageView(image))
    try d.writeSampler(3, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge))
    let table = try d.allocate(.upload, bytes: 32)
    params(table, 0, texture: slot, sampler: 3)
    let pso = try quadPipeline(LoinnirShaders.lodFrag)
    let px = try drawTiles(pso, table, count: 1, before: list)
    let strict = d.limits.sparse.residencyNonResidentStrict
    let n = judge("sparse image", px, 8, 8) { x, y in
      if x < 4 && y < 4 { return [255, 0, 0, 255] }
      if x >= 4 && y >= 4 { return [0, 255, 0, 255] }
      return strict ? [0, 0, 0, 0] : nil
    }
    ok("sparse image: \(w) x \(h) rgba8 in blocks of \(bw) x \(bh), two bound and copied into, sampled, \(n) pixels exact\(strict ? " (the unbound blocks zero)" : "")")
  }

  func elsewhereCases() {
    do throws(GPUError) { try viewports() } catch { caught("viewports", error) }
    do throws(GPUError) { try sparseBuffer() } catch { caught("sparse buffer", error) }
    do throws(GPUError) { try sparseImage() } catch { caught("sparse image", error) }
  }
}
