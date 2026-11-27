// SPDX-License-Identifier: BSD-3-Clause

// Copies by a draw (gles(2), "Objects"). An image GL only draws into and samples is made with no copy usage, which a
// device may lay out for its passes alone (Mali's AFBC); what GL then copies from it (ReadPixels, CopyTexImage), or a
// texture that must become another image (mipmaps, an upload into a drawn texture), is copied by a pass of the library's
// own: a triangle over the target, each texel fetched from the source's level (graphics/gles/shaders, as SPIR-V
// vx shaders makes into GLESShaders).

import GPUCore
import VulkanLowering

/// What a copy by a draw writes: each texel as it is, or the filtered mean of the four of the level above (a mipmap).
enum DrawCopy: Equatable { case texels, downsample }

extension Frame {
  /// The copy's two stages, lowered once.
  func blitStages(_ kind: DrawCopy) throws(GPUError) -> (vertex: [UInt8], fragment: [UInt8]) {
    if let s = blitLowered.first(where: { $0.kind == kind }) { return (s.vertex, s.fragment) }
    func words(_ b: [UInt8]) -> [UInt32] {
      var w = [UInt32](repeating: 0, count: b.count / 4)
      for i in w.indices {
        w[i] = UInt32(b[4 * i]) | UInt32(b[4 * i + 1]) << 8 | UInt32(b[4 * i + 2]) << 16 | UInt32(b[4 * i + 3]) << 24
      }
      return w
    }
    let layout = LoweringLayout(sets: [SetLayout(bindings: [DescriptorBinding(binding: 1, kind: .combinedImageSampler)])])
    do throws(LoweringError) {
      let v = try lower(spirv: words(GLESShaders.blitVert), stage: .vertex, entryPoint: "main", layout: layout)
      let f = try lower(spirv: words(kind == .texels ? GLESShaders.blitFrag : GLESShaders.downsampleFrag), stage: .fragment,
                        entryPoint: "main", layout: layout)
      blitLowered.append((kind, bytes(v), bytes(f)))
      return (bytes(v), bytes(f))
    } catch { throw .unsupported("the library's copy by a draw: \(error)") }
  }

  /// The copy's pipeline for a target of `format`.
  func blitPipeline(_ format: PixelFormat, _ kind: DrawCopy) throws(GPUError) -> GPUPipeline {
    if let p = blitPipelines.first(where: { $0.format == format && $0.kind == kind }) { return p.pipeline }
    let (v, f) = try blitStages(kind)
    let p = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(vertex: v, fragment: f, colorFormats: [format], blend: .opaque,
                                                                       topology: .triangleList))
    blitPipelines.append((format, kind, p))
    return p
  }

  /// Copies level `source.baseMip`, layer `source.baseLayer` of `source` (sampled) into `target` (a render target view of
  /// one level and layer), `width` by `height` texels from the origin, by a pass of its own.
  func copyByDraw(from source: ImageView, to target: ImageView, width: Int32, height: Int32, sampler: UInt32,
                  kind: DrawCopy = .texels, sourceSlot: UInt32? = nil) throws(GPUError) {
    endPass()
    let pipeline = try blitPipeline(target.format, kind)
    let slot: UInt32
    if let s = sourceSlot {
      slot = s
    } else {
      slot = try heap.takeTextureSlot()
      var view = source
      view.dimension = .d2
      view.mipCount = 1
      view.layerCount = 1
      try device.writeTexture(slot, view)
      heap.releaseTextureSlot(slot)
    }
    let root = try ring.allocate(96 + descriptorSize)
    unsafe root.pointer.initializeMemory(as: UInt8.self, repeating: 0, count: 96 + descriptorSize)
    unsafe root.pointer.storeBytes(of: root.address + 96, toByteOffset: RootBlock.setsOffset, as: UInt64.self)
    unsafe root.pointer.storeBytes(of: slot, toByteOffset: 96, as: UInt32.self)
    unsafe root.pointer.storeBytes(of: sampler, toByteOffset: 100, as: UInt32.self)
    barrier(before: [source.image.handle])
    list.beginRendering(RenderingInfo(colors: [Attachment(view: target, load: .dontCare, store: .store)]))
    list.setViewports([Viewport(width: Float(width), height: Float(height))])
    list.setScissor(x: 0, y: 0, width: UInt32(width), height: UInt32(height))
    list.draw(pipeline, root: root.address, vertices: 3)
    list.endRendering()
    noteWrite(target.image)
    stats.passes += 1
  }

  /// A copyable image of `format` of at least `width` by `height`, for what is copied out of an image that can't be.
  func copyScratch(_ format: PixelFormat, width: Int32, height: Int32) throws(GPUError) -> GPUImage {
    if let s = copyScratches.first(where: { $0.format == format && $0.width >= width && $0.height >= height }) { return s }
    let image = try device.makeImage(ImageDescriptor(format: format, width: width, height: height,
                                                     usage: .renderTarget | .copySource | .sampled))
    copyScratches.append(image)
    return image
  }
}

extension GLContext {
  /// The heap slot of a view of one level of one face of the texture's image, written once while the image lives: what
  /// a mipmap's pass reads, frame after frame, with no heap write.
  func levelSlot(_ t: GLTexture, level: Int, face: Int) throws(GPUError) -> UInt32 {
    guard let image = t.image else { throw .invalid("a texture with no image") }
    let key = face * 32 + level
    if let s = t.levelSlots.first(where: { $0.key == key }) { return s.slot }
    let slot = try frame.heap.takeTextureSlot()
    try device.writeTexture(slot, ImageView(image, dimension: .d2, baseMip: UInt32(level), mipCount: 1, baseLayer: UInt32(face),
                                            layerCount: 1))
    t.levelSlots.append((key, slot))
    frame.stats.textureWrites += 1
    return slot
  }

  /// A view of `view`'s image that can be copied from: the view itself, or a scratch image it was drawn into.
  func copyable(_ view: ImageView, width: Int32, height: Int32) throws(GPUError) -> ImageView {
    if view.image.usage.contains(.copySource) { return view }
    let scratch = try frame.copyScratch(view.format, width: width, height: height)
    try frame.copyByDraw(from: view, to: ImageView(scratch), width: width, height: height,
                         sampler: try sampler(for: SamplerDescriptor(filter: .nearest)))
    return ImageView(scratch)
  }

  /// Gives the texture an image that has `usage` and `mips` levels as well as what it had, its texels kept: copied where both
  /// can be, else level 0 of each face drawn into the new one.
  func promote(_ t: GLTexture, usage: ImageUsage, mips: UInt32) throws(GPUError) {
    guard let old = t.image else { return }
    if old.usage.contains(usage) && old.mipLevels >= mips { return }
    let d = old.descriptor
    let newUsage = old.usage | usage
    let image = try device.makeImage(ImageDescriptor(format: d.format, width: d.width, height: d.height, mipLevels: max(mips, d.mipLevels),
                                                     layers: d.layers, dimension: d.dimension, usage: newUsage))
    endPassUsing(old)
    frame.endPass()
    if old.usage.contains(.copySource) && newUsage.contains(.copyDestination) {
      frame.barrier(before: [old.handle])
      var regions: [ImageCopyRegion] = []
      for l in 0..<d.mipLevels {
        let e = d.mipExtent(l)
        let layers = ImageSubresourceLayers(aspects: d.format.aspects, mip: l, baseLayer: 0, layerCount: d.layers)
        regions.append(ImageCopyRegion(srcSubresource: layers, dstSubresource: layers,
                                       extent: Extent3D(width: UInt32(e.width), height: UInt32(e.height))))
      }
      frame.list.copyImage(old, to: image, regions: regions)
      frame.noteWrite(image)
    } else if old.usage.contains(.sampled) && newUsage.contains(.renderTarget) && !d.format.isDepthStencil {
      let s = try sampler(for: SamplerDescriptor(filter: .nearest))
      for face in 0..<Int(d.layers) {
        try frame.copyByDraw(from: ImageView(old, baseMip: 0, mipCount: 1, baseLayer: UInt32(face), layerCount: 1),
                             to: ImageView(image, dimension: .d2, baseMip: 0, mipCount: 1, baseLayer: UInt32(face), layerCount: 1),
                             width: d.width, height: d.height, sampler: s)
      }
    } else {
      say("a texture's image made again with what it holds lost (its usage: \(old.usage.rawValue) to \(newUsage.rawValue))")
    }
    let kind = t.kind
    dropImage(t)
    t.image = image
    t.kind = kind
    let slot = try frame.heap.takeTextureSlot()
    try device.writeTexture(slot, image)
    t.slot = slot
    frame.stats.textureWrites += 1
    frame.stats.images += 1
  }
}
